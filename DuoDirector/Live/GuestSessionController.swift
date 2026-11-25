import AVFoundation
import Observation
import os

// =====================================================================================
//  GuestSessionController (Phase 9): host side of a remote-guest room
//
//  Flow: Open room → the host's camera is published from the same capture taps as Go
//  Live (Solo mode) → Invite guest makes a LiveKit Meet link with a fresh guest token →
//  the guest's video shows as a tile and, with "Guest in stream" on, is composited into
//  the RTMP stream with their audio mixed in. Recordings stay host-only and clean.
//
//  Audio: DuoDirector keeps owning the AVAudioSession. The guest plays through the
//  current route, so the host should wear headphones, or the guest's voice reaches the
//  mic and echoes (the capture session's .videoRecording mode has no echo cancelling).
// =====================================================================================

/// Capture-queue side of guests in the stream. Sendable, lives as long as the controller.
final class GuestStreamPipeline: Sendable {
    let frames = GuestFrameStore()
    let compositor = GuestStreamCompositor()
    let mixer = GuestAudioMixer()
    private let enabled = OSAllocatedUnfairLock(initialState: false)

    func setEnabled(_ on: Bool) { enabled.withLock { $0 = on }; if !on { mixer.clear() } }

    /// Called by the RTMP sink for every buffer; returns what should be streamed.
    func process(_ buffer: CMSampleBuffer, _ type: AVMediaType) -> CMSampleBuffer {
        guard enabled.withLock({ $0 }) else { return buffer }
        if type == .video {
            guard let guest = frames.freshFrame() else { return buffer }
            return compositor.composite(host: buffer, guest: guest) ?? buffer
        }
        return mixer.mix(into: buffer)
    }
}

@MainActor
@Observable
final class GuestSessionController {

    private let state: StudioSessionState
    private let engine: CameraEngine
    private let defaults: UserDefaults
    let pipeline = GuestStreamPipeline()

    private(set) var config: GuestRoomConfig
    /// Development only: a host token pasted from `lk token create`. Kept in memory,
    /// never saved (tokens expire and grant room access).
    var manualHostToken = ""
    private(set) var inviteLink: URL?
    private(set) var isMakingInvite = false

    @ObservationIgnored private var room: GuestRoomTransport?
    @ObservationIgnored private var resolvedServerURL = ""
    @ObservationIgnored private let session: URLSession

    init(state: StudioSessionState, engine: CameraEngine, defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.state = state
        self.engine = engine
        self.defaults = defaults
        self.session = session
        if let data = defaults.data(forKey: GuestRoomConfig.defaultsKey),
           let saved = try? JSONDecoder().decode(GuestRoomConfig.self, from: data) {
            config = saved
        } else {
            config = GuestRoomConfig()
        }
        pipeline.compositor.setLayout(state.guestLayout)
        pipeline.setEnabled(state.includeGuestInStream)
    }

    var isMock: Bool { engine.isMock || state.isDemoMode }

    func updateConfig(_ c: GuestRoomConfig) {
        config = c
        if let data = try? JSONEncoder().encode(c) { defaults.set(data, forKey: GuestRoomConfig.defaultsKey) }
    }

    func setLayout(_ layout: GuestLayout) { state.guestLayout = layout; pipeline.compositor.setLayout(layout) }
    func setIncludeInStream(_ on: Bool) { state.includeGuestInStream = on; pipeline.setEnabled(on) }

    var blockReason: String? {
        if isMock { return state.isDualCam ? String(localized: "Guests work in Solo mode. Switch off Dual-Cam to open the room.") : nil }
        switch GuestPolicy.validate(config, isDualCam: state.isDualCam, hasManualToken: !manualHostToken.isEmpty) {
        case .dualCamUnsupported: return String(localized: "Guests work in Solo mode. Switch off Dual-Cam to open the room.")
        case .emptyRoom: return String(localized: "Give the room a name.")
        case .badServerURL: return String(localized: "The LiveKit server must start with wss://.")
        case .endpointNotHTTPS: return String(localized: "Add your token endpoint (https://…), or paste a development token.")
        case nil: return nil
        }
    }

    // MARK: Room

    func openRoom() {
        guard !state.guestState.isInRoom, state.guestState != .connecting else { return }
        if let reason = blockReason { state.showBanner(reason); return }
        state.guestState = .connecting
        Task { await connect() }
    }

    func closeRoom() {
        let r = room
        room = nil
        inviteLink = nil
        engine.controller.setSampleSink(nil, for: "guests")
        pipeline.frames.clear(); pipeline.mixer.clear()
        let wasInRoom = state.guestState.isInRoom
        state.guestState = .idle
        if wasInRoom { state.showBanner("Guest room closed.") }
        Task { await r?.disconnect() }
    }

    private func connect() async {
        let mock = isMock
        if !mock {
            guard await engine.liveCanFeed() else {
                fail(String(localized: "The camera isn't delivering frames yet. Try again after the preview starts."))
                return
            }
        }
        let credentials: (server: String, token: String)
        do {
            if mock {
                credentials = ("wss://demo.invalid", "demo")
            } else if !manualHostToken.isEmpty {
                credentials = (config.serverURL, manualHostToken)
            } else {
                credentials = try await fetchToken(identity: GuestPolicy.hostIdentity, name: config.hostName)
            }
        } catch {
            fail(String(localized: "Couldn't get a room token from your endpoint."))
            return
        }
        let room = GuestRoomFactory.make(mock: mock)
        wire(room.events)
        do {
            try await room.connect(serverURL: credentials.server, token: credentials.token)
        } catch {
            await room.disconnect()
            fail(String(localized: "Couldn't join the guest room. Check the server and token."))
            return
        }
        guard state.guestState == .connecting else { await room.disconnect(); return }   // closed meanwhile
        self.room = room
        resolvedServerURL = credentials.server
        engine.controller.setSampleSink({ buffer, type in room.appendHost(buffer, mediaType: type) }, for: "guests")
        state.guestState = .waiting
        state.showBanner("Guest room open. Invite your guest.")
        if mock { await makeInvite() }
    }

    private func wire(_ events: GuestRoomEvents) {
        let pipeline = pipeline
        events.guestFrame = { pipeline.frames.put($0) }
        events.guestAudio = { pipeline.mixer.pushGuest($0) }
        events.guestJoined = { [weak self] name in
            Task { @MainActor in
                guard let self, self.state.guestState.isInRoom else { return }
                self.state.guestState = .connected(guestName: name)
                self.state.showBanner("\(name) joined. Headphones on to avoid echo.")
            }
        }
        events.guestLeft = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.guestState.isInRoom else { return }
                self.pipeline.frames.clear(); self.pipeline.mixer.clear()
                self.state.guestState = .waiting
                self.state.showBanner("Your guest left the room.")
            }
        }
        events.reconnecting = { [weak self] on in
            Task { @MainActor in
                guard let self, self.state.guestState.isInRoom else { return }
                if on { self.state.guestState = .reconnecting } else if self.state.guestState == .reconnecting { self.state.guestState = .waiting }
            }
        }
        events.disconnected = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.room != nil else { return }
                self.closeRoom()
                if let reason { self.state.guestState = .failed(reason) }
            }
        }
    }

    private func fail(_ message: String) {
        engine.controller.setSampleSink(nil, for: "guests")
        state.guestState = .failed(message)
        state.showBanner(message)
    }

    // MARK: Invite

    /// Fetches a guest token and builds the link. Each invite gets a fresh identity.
    func makeInvite() async {
        guard state.guestState.isInRoom else { return }
        isMakingInvite = true
        defer { isMakingInvite = false }
        if isMock {
            inviteLink = GuestPolicy.meetLink(serverURL: "wss://demo.invalid", token: "demo-guest")
            return
        }
        guard !config.tokenEndpoint.isEmpty else {
            state.showBanner("Invites need a token endpoint. With a pasted token, send the guest their own token.")
            return
        }
        do {
            let (server, token) = try await fetchToken(identity: GuestPolicy.guestIdentity(), name: "Guest")
            inviteLink = GuestPolicy.meetLink(serverURL: server.isEmpty ? resolvedServerURL : server, token: token)
        } catch {
            state.showBanner("Couldn't create a guest invite.")
        }
    }

    private func fetchToken(identity: String, name: String) async throws -> (String, String) {
        guard let url = URL(string: config.tokenEndpoint.trimmingCharacters(in: .whitespaces)) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TokenRequest(room_name: config.roomName, participant_identity: identity,
                                                                 participant_name: name))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let server = decoded.server_url ?? config.serverURL
        guard !server.isEmpty else { throw URLError(.badURL) }
        return (server, decoded.participant_token)
    }
}
