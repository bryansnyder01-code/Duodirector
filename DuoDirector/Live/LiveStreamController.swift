import AVFoundation
import Observation

// =====================================================================================
//  LiveStreamController (Phase 8): Go Live to YouTube / Twitch / any RTMP(S) server
//
//  • Destinations (name, kind, server) persist in UserDefaults as JSON. Stream KEYS never
//    do: they live in the Keychain (StreamKeyStore) and are never logged or bannered.
//  • Frames come from the capture session's existing video/audio data outputs via
//    CaptureSessionController.setLiveSampleSink, so recording and streaming share one
//    capture pipeline. Recording a take while live works; both run at once.
//  • Solo mode only. AVCaptureMultiCamSession in DuoDirector has no data outputs
//    (both movie outputs own the hardware budget), so Dual-Cam is blocked while live.
//  • Drops reconnect automatically with StreamPolicy backoff (1, 2, 4, 8, 15 s…).
//  • Heat costs bitrate first (StreamPolicy.videoBitrate); critical heat also ends a
//    stream that would otherwise drop frames, unless a take is recording (the take wins).
// =====================================================================================

@MainActor
@Observable
final class LiveStreamController {

    private let state: StudioSessionState
    private let engine: CameraEngine
    private let defaults: UserDefaults

    private(set) var destinations: [StreamDestination] = []
    var selectedDestinationID: StreamDestination.ID? {
        get { access(keyPath: \.selectedDestinationID); return _selected }
        set { withMutation(keyPath: \.selectedDestinationID) { _selected = newValue }; persist() }
    }
    @ObservationIgnored private var _selected: StreamDestination.ID?
    var quality: LiveQuality {
        get { access(keyPath: \.quality); return _quality }
        set { withMutation(keyPath: \.quality) { _quality = newValue }; persist() }
    }
    @ObservationIgnored private var _quality: LiveQuality = .p1080_30

    @ObservationIgnored private var transport: LiveStreamTransport?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var thermalTask: Task<Void, Never>?
    @ObservationIgnored private var userEnded = false

    private static let destinationsKey = "live.destinations"
    private static let selectedKey = "live.selectedDestination"
    private static let qualityKey = "live.quality"

    init(state: StudioSessionState, engine: CameraEngine, defaults: UserDefaults = .standard) {
        self.state = state
        self.engine = engine
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.destinationsKey),
           let saved = try? JSONDecoder().decode([StreamDestination].self, from: data) {
            destinations = saved
        }
        if let raw = defaults.string(forKey: Self.selectedKey) { _selected = UUID(uuidString: raw) }
        if let raw = defaults.string(forKey: Self.qualityKey), let q = LiveQuality(rawValue: raw) { _quality = q }
        if _selected == nil || !destinations.contains(where: { $0.id == _selected }) { _selected = destinations.first?.id }
    }

    var selectedDestination: StreamDestination? { destinations.first { $0.id == selectedDestinationID } }

    // MARK: Destinations

    @discardableResult
    func addDestination(_ kind: StreamDestination.Kind) -> StreamDestination {
        let d = StreamDestination.preset(kind)
        destinations.append(d)
        selectedDestinationID = d.id
        persist()
        return d
    }

    func update(_ destination: StreamDestination) {
        guard let i = destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        destinations[i] = destination
        persist()
    }

    func remove(_ destination: StreamDestination) {
        guard !(state.liveState.isActive && destination.id == selectedDestinationID) else { return }
        StreamKeyStore.delete(for: destination.id)
        destinations.removeAll { $0.id == destination.id }
        if selectedDestinationID == destination.id { selectedDestinationID = destinations.first?.id }
        persist()
    }

    func hasKey(for destination: StreamDestination) -> Bool { StreamKeyStore.load(for: destination.id)?.isEmpty == false }
    func redactedKey(for destination: StreamDestination) -> String? {
        StreamKeyStore.load(for: destination.id).map(StreamPolicy.redacted)
    }

    func setKey(_ key: String, for destination: StreamDestination) {
        do { try StreamKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: destination.id) }
        catch { state.showBanner("Couldn't save the stream key to the Keychain.") }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(destinations) { defaults.set(data, forKey: Self.destinationsKey) }
        defaults.set(_selected?.uuidString, forKey: Self.selectedKey)
        defaults.set(_quality.rawValue, forKey: Self.qualityKey)
    }

    // MARK: Go live / end

    /// A readable reason Go Live is unavailable right now, or nil.
    var blockReason: String? {
        guard let d = selectedDestination else { return String(localized: "Add a destination first.") }
        let key = StreamKeyStore.load(for: d.id) ?? ""
        switch StreamPolicy.validate(server: d.serverURL, key: key, isDualCam: state.isDualCam) {
        case .dualCamUnsupported: return String(localized: "Streaming works in Solo mode. Switch off Dual-Cam to go live.")
        case .srtNotOffered: return String(localized: "SRT isn't supported. Use an rtmp:// or rtmps:// server.")
        case .badScheme: return String(localized: "The server must start with rtmp:// or rtmps://.")
        case .missingHost: return String(localized: "The server address is missing a host name.")
        case .missingKey: return String(localized: "Paste the stream key from your platform's dashboard.")
        case nil: return nil
        }
    }

    func goLive() {
        guard !state.liveState.isActive else { return }
        if let reason = blockReason { state.showBanner(reason); return }
        guard let destination = selectedDestination, let key = StreamKeyStore.load(for: destination.id) else { return }
        userEnded = false
        state.liveState = .connecting
        Task { await connect(destination: destination, key: key, attempt: 0) }
    }

    func endLive() {
        userEnded = true
        reconnectTask?.cancel(); reconnectTask = nil
        tearDown()
        let wasActive = state.liveState.isActive
        state.liveState = .idle
        if wasActive { state.showBanner("Stream ended.") }
    }

    // MARK: Pipeline

    private func connect(destination: StreamDestination, key: String, attempt: Int) async {
        let mock = engine.isMock || state.isDemoMode
        if !mock {
            let canFeed = await engine.liveCanFeed()
            guard canFeed else {
                fail("The camera isn't delivering frames for streaming. Try again after the preview starts.")
                return
            }
        }
        let transport = LiveTransportFactory.make(mock: mock)
        let quality = quality
        let base = StreamPolicy.videoBitrate(base: quality.videoBitrate, thermal: state.thermalState)
        transport.onDisconnect = { [weak self] reason in
            Task { @MainActor in self?.handleDrop(reason, destination: destination, key: key) }
        }
        do {
            try await transport.start(server: destination.serverURL.trimmingCharacters(in: .whitespaces),
                                      streamKey: key, quality: quality)
            if base != quality.videoBitrate { await transport.setVideoBitrate(base) }
        } catch {
            await transport.stop()
            guard !userEnded else { return }
            if attempt == 0 {
                // A first-connect failure is almost always a wrong key/server: don't retry.
                fail(String(localized: "Couldn't connect to \(destination.name). Check the server and stream key."))
            } else {
                scheduleReconnect(destination: destination, key: key, attempt: attempt + 1)
            }
            return
        }
        guard !userEnded else { await transport.stop(); return }
        self.transport = transport
        // Phase 9: the guest (tile + audio) is mixed into the stream only, never the recording.
        let guests = engine.guests?.pipeline
        engine.controller.setLiveSampleSink { buffer, type in
            transport.append(guests?.process(buffer, type) ?? buffer, mediaType: type)
        }
        state.liveState = .live(since: .now)
        state.showBanner(attempt == 0 ? "You're live on \(destination.name)." : "Reconnected. You're live again.")
        startMonitors()
    }

    private func handleDrop(_ reason: String, destination: StreamDestination, key: String) {
        guard !userEnded, state.liveState.isActive else { return }
        tearDown()
        scheduleReconnect(destination: destination, key: key, attempt: 1)
    }

    private func scheduleReconnect(destination: StreamDestination, key: String, attempt: Int) {
        guard let delay = StreamPolicy.reconnectDelay(attempt: attempt) else {
            fail("The stream dropped and couldn't reconnect.")
            return
        }
        state.liveState = .reconnecting(attempt: attempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.userEnded else { return }
            await self.connect(destination: destination, key: key, attempt: attempt)
        }
    }

    private func fail(_ message: String) {
        tearDown()
        state.liveState = .failed(message)
        state.showBanner(message)
    }

    private func tearDown() {
        engine.controller.setLiveSampleSink(nil)
        statsTask?.cancel(); statsTask = nil
        thermalTask?.cancel(); thermalTask = nil
        if let t = transport { transport = nil; Task { await t.stop() } }
        state.liveStats = LiveStats()
    }

    /// Stats once a second; bitrate follows heat.
    private func startMonitors() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let t = self.transport else { return }
                self.state.liveStats = t.currentStats
            }
        }
        thermalTask?.cancel()
        thermalTask = Task { [weak self] in
            var last: ProcessInfo.ThermalState?
            while !Task.isCancelled {
                guard let self, let t = self.transport else { return }
                let thermal = self.state.thermalState
                if thermal != last {
                    last = thermal
                    if thermal == .critical && !self.state.isRecording {
                        self.endLive()
                        self.state.showBanner("Stream ended: the phone is too hot to keep streaming.")
                        return
                    }
                    await t.setVideoBitrate(StreamPolicy.videoBitrate(base: self.quality.videoBitrate, thermal: thermal))
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

extension CameraEngine {
    /// Phase 8: whether the real session has both data outputs to feed a stream.
    func liveCanFeed() async -> Bool {
        let controller = controller
        return await withCheckedContinuation { c in
            controller.sessionQueue.async { c.resume(returning: controller.canFeedLiveStream) }
        }
    }
}
