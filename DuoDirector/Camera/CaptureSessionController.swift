import AVFoundation
import os
import CoreMedia
import VideoToolbox

/// Owns the AVCaptureSession / AVCaptureMultiCamSession and every AVFoundation call
/// (Phase 2).
///
/// Queues:
///  • `sessionQueue`: configuration, start/stop, recording, device locking. These calls
///    block, so they never run on main.
///  • `audioQueue`: AVCaptureAudioDataOutput buffers → per-channel peak/RMS dBFS.
///  • `videoQueue`: AVCaptureVideoDataOutput buffers → FrameAnalyzer (peaking/zebras).
///    `alwaysDiscardsLateVideoFrames` is on and the analyzer self-throttles, so analysis can
///    never back up into the recording path. AVCaptureMovieFileOutput encodes independently.
///
/// All of this is standard AVFoundation that predates iOS 27; nothing here is 27.1-only.
final class CaptureSessionController: NSObject, @unchecked Sendable {

    enum CameraRole: Sendable { case rear, inner }

    struct Configuration: Sendable, Equatable {
        var lens: LensOption
        var frameRate: Int
        var resolution: ResolutionPreset
        var wantsDolbyVision: Bool
        var dualAngle: Bool
        var codec: VideoCodecPreset = .hevc
    }

    struct Capabilities: Sendable {
        var multiCamSupported: Bool
        var appliedFrameRate: Int
        var appliedResolution: ResolutionPreset
        var dolbyVisionSupported: Bool
        var dolbyVisionActive: Bool
        var cropIsOpticalQuality: Bool
        var proResSupported = false
        /// Phase 4: MultiCam bandwidth/thermal cost (0 in single-cam). > 1.0 = over budget.
        var hardwareCost: Float = 0
        var systemPressureCost: Float = 0
        var isoRange: ClosedRange<Float>
        var shutterRange: ClosedRange<Double>
        var sessionReplaced: Bool
        var note: String?
    }

    /// Phase 4: result of one (possibly dual) recording.
    struct RecordingResult: Sendable {
        var rearURL: URL?
        var innerURL: URL?
        /// Inner start − rear start on the session's synchronization clock (seconds).
        var innerStartOffset: TimeInterval
    }

    struct AudioLevels: Sendable {
        var peakL: Float, peakR: Float, rmsL: Float, rmsR: Float
    }

    let sessionQueue = DispatchQueue(label: "duodirector.capture.session")
    private let audioQueue = DispatchQueue(label: "duodirector.capture.audio", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "duodirector.capture.analysis", qos: .utility)

    /// Replaced (not mutated) only when switching between single-cam and multicam.
    private(set) var session: AVCaptureSession = AVCaptureSession()

    private var rearInput: AVCaptureDeviceInput?
    private var innerInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let movieOutput = AVCaptureMovieFileOutput()
    private var innerMovieOutput: AVCaptureMovieFileOutput?
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private(set) var hasAudioDataOutput = false
    private(set) var hasVideoDataOutput = false

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var currentConfig: Configuration?
    private var hdrActive = false

    private var recordingCompletion: (@Sendable (Result<RecordingResult, Error>) -> Void)?
    private var pendingRecordingURLs: [URL] = []
    private var finishedRecordingURLs: [URL] = []
    private var rearRecordingURL: URL?
    private var innerRecordingURL: URL?
    private var startTimes: [URL: CMTime] = [:]
    private var pressureObservation: NSKeyValueObservation?
    /// Phase 5: one timed-metadata input per movie output (rear, inner). See MovieMarkerTrack.
    private var markerInputs: [AVCaptureMetadataInput] = []
    private var markerClock: CMClock = CMClockGetHostTimeClock()
    /// "In file" when every movie output got a marker input, else why not (diagnostics).
    private(set) var markerTrackStatus = "Not configured"

    /// Phase 4: AVCaptureDevice.systemPressureState changes on the rear camera
    /// (level, factors). Called on an arbitrary queue.
    var onSystemPressure: (@Sendable (AVCaptureDevice.SystemPressureState.Level, AVCaptureDevice.SystemPressureState.Factors) -> Void)?

    /// Phase 8: Go Live tap. Receives every audio and video data-output buffer (audio on
    /// `audioQueue`, video on `videoQueue`) while a stream is running; nil = no cost.
    /// Solo mode only: MultiCam has no data outputs (see LiveStreamController).
    typealias LiveSampleSink = @Sendable (CMSampleBuffer, AVMediaType) -> Void
    /// Phase 9: several consumers can tap at once (the RTMP stream and the guest room),
    /// keyed by name. Called per buffer, so the lock only copies the dictionary.
    private let liveSinks = OSAllocatedUnfairLock<[String: LiveSampleSink]>(initialState: [:])
    func setSampleSink(_ sink: LiveSampleSink?, for key: String) { liveSinks.withLock { $0[key] = sink } }
    func setLiveSampleSink(_ sink: LiveSampleSink?) { setSampleSink(sink, for: "stream") }
    private func feedSinks(_ buffer: CMSampleBuffer, _ type: AVMediaType) {
        let sinks = liveSinks.withLock { $0 }
        for sink in sinks.values { sink(buffer, type) }
    }
    /// True when this session can feed a stream (solo session with both data outputs).
    var canFeedLiveStream: Bool { hasVideoDataOutput && hasAudioDataOutput }

    /// Called on `audioQueue` for every audio buffer.
    var onAudioLevels: (@Sendable (AudioLevels) -> Void)?
    /// Receives rear-camera frames on `videoQueue`. Set by CameraEngine.
    var frameAnalyzer: FrameAnalyzer?

    var rearDevice: AVCaptureDevice? { rearInput?.device }

    // MARK: Authorization & audio session

    static func requestAccess() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        return video && audio
    }

    /// We own the AVAudioSession (the capture session's automatic configuration is off) so
    /// input gain is settable and stays put across reconfigurations.
    static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .videoRecording,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)
    }

    /// Maps the UI gain (0…1) to hardware input gain when the current route allows it.
    static func setInputGain(_ gain: Float) {
        let session = AVAudioSession.sharedInstance()
        guard session.isInputGainSettable else { return }
        try? session.setInputGain(max(0, min(1, gain)))
    }

    // MARK: Device discovery

    /// 0.5× → Ultra Wide module. 1× and 2× → Main module (2× is videoZoomFactor 2.0).
    static func rearDevice(for lens: LensOption) -> AVCaptureDevice? {
        if lens.usesMainModule {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Inner under-display camera. VERIFY on hardware: if iPhone Duo exposes a dedicated
    /// device type for it, put that first.
    static func innerDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .front
        ).devices.first
    }

    static var hasAnyCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    // MARK: Full configuration

    /// Applies every capture setting. Rebuilds the session only when single ↔ multicam
    /// changes; everything else is reconfigured in place on the running session.
    func configure(_ config: Configuration) throws -> Capabilities {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        let wantsMultiCam = config.dualAngle && AVCaptureMultiCamSession.isMultiCamSupported
        let isMultiCam = session is AVCaptureMultiCamSession
        var replaced = false
        if wantsMultiCam != isMultiCam || currentConfig == nil {
            try rebuildSession(multiCam: wantsMultiCam)
            replaced = true
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        try attachRearInput(for: config.lens)
        guard let device = rearDevice else { throw CameraError.noCamera }
        var caps = try applyFormat(on: device, config: config, multiCam: wantsMultiCam)
        try device.lockForConfiguration()
        device.videoZoomFactor = clampedZoom(config.lens.zoomFactor, on: device)
        device.unlockForConfiguration()
        currentConfig = config
        refreshConnections()
        caps.sessionReplaced = replaced
        caps.proResSupported = movieOutput.availableVideoCodecTypes.contains(.proRes422HQ)
        if let multi = session as? AVCaptureMultiCamSession {
            // Read AFTER the formats are set: these reflect the configured load.
            caps.hardwareCost = multi.hardwareCost
            caps.systemPressureCost = multi.systemPressureCost
        }
        return caps
    }

    /// Lens switch on the RUNNING session, without stopping it.
    ///  • 1× ↔ 2× stays on the Main module: a smooth `ramp(toVideoZoomFactor:withRate:)`,
    ///    with no input change, so preview, recording and the cover accessory are untouched.
    ///  • ↔ 0.5× swaps the device input inside begin/commitConfiguration. The session keeps
    ///    running (preview layers re-bind automatically in a single-cam session), so the
    ///    CameraCaptureAccessory, which needs a running session, is never withdrawn.
    func switchLens(to lens: LensOption) throws -> Capabilities? {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard var config = currentConfig, let current = rearDevice else { return nil }
        config.lens = lens

        if Self.rearDevice(for: lens) == current {
            try current.lockForConfiguration()
            current.ramp(toVideoZoomFactor: clampedZoom(lens.zoomFactor, on: current), withRate: 4.0)
            current.unlockForConfiguration()
            currentConfig = config
            return nil   // format unchanged
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        try attachRearInput(for: lens)
        guard let device = rearDevice else { throw CameraError.noCamera }
        var caps = try applyFormat(on: device, config: config, multiCam: session is AVCaptureMultiCamSession)
        try device.lockForConfiguration()
        device.videoZoomFactor = clampedZoom(lens.zoomFactor, on: device)
        device.unlockForConfiguration()
        currentConfig = config
        refreshConnections()
        caps.proResSupported = movieOutput.availableVideoCodecTypes.contains(.proRes422HQ)
        return caps
    }

    private func clampedZoom(_ factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        max(device.minAvailableVideoZoomFactor, min(factor, device.activeFormat.videoMaxZoomFactor))
    }

    private func attachRearInput(for lens: LensOption) throws {
        guard let device = Self.rearDevice(for: lens) else { throw CameraError.noCamera }
        guard rearInput?.device != device else { return }
        let multi = session as? AVCaptureMultiCamSession
        if let old = rearInput { session.removeInput(old) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAdd("rear input") }
        if let multi {
            multi.addInputWithNoConnections(input)
            try connectMultiCamRear(input, in: multi)
        } else {
            session.addInput(input)
        }
        rearInput = input
        observeRotation(for: device)
        observeSystemPressure(on: device)
    }

    /// Camera-level thermal/power pressure. Apple recommends reacting at .serious (reduce
    /// frame rate / work) and .critical (reduce further); .shutdown stops capture.
    private func observeSystemPressure(on device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let state = device.systemPressureState
            self?.onSystemPressure?(state.level, state.factors)
        }
    }

    private func rebuildSession(multiCam: Bool) throws {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        rearInput = nil; innerInput = nil; audioInput = nil; innerMovieOutput = nil
        markerInputs = []
        hasAudioDataOutput = false; hasVideoDataOutput = false

        let newSession: AVCaptureSession = multiCam ? AVCaptureMultiCamSession() : AVCaptureSession()
        newSession.automaticallyConfiguresApplicationAudioSession = false
        newSession.automaticallyConfiguresCaptureDeviceForWideColor = false   // we pick HLG ourselves

        newSession.beginConfiguration()
        defer { newSession.commitConfiguration() }

        // Microphone, in stereo where the built-in mics support it (iOS 17+ API).
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), newSession.canAddInput(input) {
            if input.isMultichannelAudioModeSupported(.stereo) {
                input.multichannelAudioMode = .stereo
            }
            if multiCam { newSession.addInputWithNoConnections(input) } else { newSession.addInput(input) }
            audioInput = input
        }

        if multiCam {
            newSession.addOutputWithNoConnections(movieOutput)
        } else if newSession.canAddOutput(movieOutput) {
            newSession.addOutput(movieOutput)
        }

        // Audio metering branch. VERIFY on device: if this can't coexist with the movie
        // output, `hasAudioDataOutput` stays false and CameraEngine polls the movie
        // connection's AVCaptureAudioChannel levels instead.
        audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if !multiCam, newSession.canAddOutput(audioDataOutput) {
            newSession.addOutput(audioDataOutput)
            hasAudioDataOutput = true
        }

        // Analysis branch for peaking/zebras. BGRA keeps Core Image simple; frames are
        // downscaled inside FrameAnalyzer. Not attached in multicam (bandwidth limits).
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if !multiCam, newSession.canAddOutput(videoDataOutput) {
            newSession.addOutput(videoDataOutput)
            hasVideoDataOutput = true
        }

        session = newSession

        if multiCam, let multi = newSession as? AVCaptureMultiCamSession {
            try configureInnerCamera(in: multi)
            connectAudio(to: movieOutput, in: multi)
        }
        attachMarkerInputs(to: newSession)
    }

    /// Phase 5: AVCaptureMetadataInput → each movie output, so markers are written into
    /// the .mov files as a timed-metadata track. Never fatal: if the session refuses, the
    /// sidecars still carry every marker.
    private func attachMarkerInputs(to session: AVCaptureSession) {
        guard let description = MovieMarkerTrack.formatDescription() else {
            markerTrackStatus = "Sidecar only (no format description)"
            return
        }
        markerClock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let outputs = [movieOutput, innerMovieOutput].compactMap { $0 }
        for output in outputs {
            let input = AVCaptureMetadataInput(formatDescription: description, clock: markerClock)
            guard session.canAddInput(input) else { continue }
            if let multi = session as? AVCaptureMultiCamSession {
                multi.addInputWithNoConnections(input)
                let connection = AVCaptureConnection(inputPorts: input.ports, output: output)
                guard multi.canAddConnection(connection) else { multi.removeInput(input); continue }
                multi.addConnection(connection)
            } else {
                session.addInput(input)          // single-cam: auto-connects to the movie output
            }
            markerInputs.append(input)
        }
        markerTrackStatus = markerInputs.count == outputs.count ? "In file + sidecar"
            : markerInputs.isEmpty ? "Sidecar only (session refused metadata input)"
            : "Rear file + sidecar (inner refused metadata input)"
    }

    /// Writes one marker into every recording file at "now" on the marker clock.
    func appendMarker(_ marker: TakeMarker) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard movieOutput.isRecording, !markerInputs.isEmpty else { return }
        let group = MovieMarkerTrack.group(for: marker, at: CMClockGetTime(markerClock),
                                           frameRate: currentConfig?.frameRate ?? 30)
        for input in markerInputs {
            do { try input.append(group) } catch { markerTrackStatus = "Append failed: \(error.localizedDescription)" }
        }
    }

    // MARK: Connections (re-applied after every input change)

    private func refreshConnections() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .cinematicExtended
        }
        applyMovieOutputSettings(connection)
        applyAnalysisRotation()
    }

    /// High-bitrate HEVC .mov. With Dolby Vision on: HEVC Main10 + HLG BT.2020 color
    /// properties. Only keys the output reports as supported are set, so this never throws
    /// an Objective-C exception on hardware that rejects a key.
    private func applyMovieOutputSettings(_ connection: AVCaptureConnection) {
        let config = currentConfig
        let supported = Set(movieOutput.supportedOutputSettingsKeys(for: connection))

        // Phase 3: ProRes 422 HQ when requested and offered (intra-frame, no bitrate keys).
        if config?.codec == .proRes422HQ, movieOutput.availableVideoCodecTypes.contains(.proRes422HQ) {
            var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.proRes422HQ]
            if hdrActive, supported.contains(AVVideoColorPropertiesKey) {
                settings[AVVideoColorPropertiesKey] = Self.hlgColorProperties
            }
            movieOutput.setOutputSettings(settings, for: connection)
            return
        }

        guard movieOutput.availableVideoCodecTypes.contains(.hevc) else { return }
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]

        let res = config?.resolution ?? .uhd4K
        let fps = config?.frameRate ?? 30
        if supported.contains(AVVideoCompressionPropertiesKey) {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: res.baseBitrate * max(fps, 30) / 30,
                AVVideoExpectedSourceFrameRateKey: fps,
            ]
            if hdrActive { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        if hdrActive, supported.contains(AVVideoColorPropertiesKey) {
            settings[AVVideoColorPropertiesKey] = Self.hlgColorProperties
        }
        movieOutput.setOutputSettings(settings, for: connection)
    }

    // Immutable after init; [String: Any] just can't be proven Sendable.
    private nonisolated(unsafe) static let hlgColorProperties: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]

    // MARK: Rotation

    private func observeRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in
            guard let self else { return }
            sessionQueue.async { self.applyAnalysisRotation() }
        }
    }

    /// Analysis frames are rotated like the preview so the overlay lines up pixel-for-pixel
    /// with the aspect-fill preview layer.
    private func applyAnalysisRotation() {
        guard let coordinator = rotationCoordinator,
              let connection = videoDataOutput.connection(with: .video) else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }

    // MARK: MultiCam (rear + inner under-display), from Phase 1

    private func connectMultiCamRear(_ input: AVCaptureDeviceInput, in multi: AVCaptureMultiCamSession) throws {
        guard let port = input.ports(for: .video, sourceDeviceType: input.device.deviceType,
                                     sourceDevicePosition: .back).first else { return }
        for connection in movieOutput.connections where connection.inputPorts.contains(where: { $0.mediaType == .video }) {
            multi.removeConnection(connection)
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: movieOutput)
        guard multi.canAddConnection(connection) else { throw CameraError.cannotAdd("rear multicam connection") }
        multi.addConnection(connection)
    }

    private func configureInnerCamera(in multi: AVCaptureMultiCamSession) throws {
        guard let device = Self.innerDevice() else { return }
        let input = try AVCaptureDeviceInput(device: device)
        guard multi.canAddInput(input) else { throw CameraError.cannotAdd("inner input") }
        multi.addInputWithNoConnections(input)
        innerInput = input

        // VERIFY: a second AVCaptureMovieFileOutput in MultiCam. If refused, move the inner
        // camera to AVCaptureVideoDataOutput + AVAssetWriter.
        let output = AVCaptureMovieFileOutput()
        guard multi.canAddOutput(output) else { throw CameraError.cannotAdd("inner movie output") }
        multi.addOutputWithNoConnections(output)
        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: .front).first else { return }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard multi.canAddConnection(connection) else { throw CameraError.cannotAdd("inner connection") }
        multi.addConnection(connection)
        connectAudio(to: output, in: multi)
        innerMovieOutput = output

        if let format = device.formats.first(where: {
            $0.isMultiCamSupported && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == 1920
        }) {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        }
    }

    private func connectAudio(to output: AVCaptureOutput, in multi: AVCaptureMultiCamSession) {
        guard let audioInput,
              let port = audioInput.ports(for: .audio, sourceDeviceType: audioInput.device.deviceType,
                                          sourceDevicePosition: .unspecified).first else { return }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        if multi.canAddConnection(connection) { multi.addConnection(connection) }
    }

    // MARK: Format selection (resolution / fps / Dolby Vision)

    private func applyFormat(on device: AVCaptureDevice, config: Configuration, multiCam: Bool) throws -> Capabilities {
        var note: String?
        var resolution = config.resolution
        var fps = config.frameRate

        func candidates(res: ResolutionPreset, fps: Int, hdr: Bool) -> [AVCaptureDevice.Format] {
            device.formats.filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == res.width && dims.height == res.height
                    && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) }
                    && (!hdr || format.supportedColorSpaces.contains(.HLG_BT2020))
                    && (!multiCam || format.isMultiCamSupported)
            }
        }

        var pool = candidates(res: resolution, fps: fps, hdr: false)
        if pool.isEmpty {
            // Step down fps, then resolution.
            if let lower = FrameRatePreset.allCases.map(\.rawValue).filter({ $0 < fps }).reversed()
                .first(where: { !candidates(res: resolution, fps: $0, hdr: false).isEmpty }) {
                note = "\(fps)fps isn't available at \(resolution.label); using \(lower)fps."
                fps = lower
            } else if resolution == .uhd4K {
                resolution = .hd1080
                note = "4K isn't available with these settings; using 1080p."
            }
            pool = candidates(res: resolution, fps: fps, hdr: false)
        }
        guard !pool.isEmpty else { throw CameraError.noMatchingFormat }

        let hdrPool = candidates(res: resolution, fps: fps, hdr: true)
        let dolbyVisionSupported = !hdrPool.isEmpty
        let useHDR = config.wantsDolbyVision && dolbyVisionSupported
        if config.wantsDolbyVision && !dolbyVisionSupported {
            note = (note.map { $0 + " " } ?? "") + "Dolby Vision isn't available at \(resolution.label) \(fps)fps; recording SDR."
        }

        // Prefer a format whose 2× crop is native-resolution (48MP readout) on the Main module.
        let preferred = (useHDR ? hdrPool : pool)
        let format = preferred.first(where: { $0.secondaryNativeResolutionZoomFactors.contains(2.0) }) ?? preferred[0]

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeColorSpace = useHDR ? .HLG_BT2020 : .sRGB
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        hdrActive = useHDR

        let minShutter = format.minExposureDuration.seconds
        let maxShutter = min(format.maxExposureDuration.seconds, 1.0 / Double(fps))   // can't exceed frame time
        return Capabilities(
            multiCamSupported: AVCaptureMultiCamSession.isMultiCamSupported,
            appliedFrameRate: fps,
            appliedResolution: resolution,
            dolbyVisionSupported: dolbyVisionSupported,
            dolbyVisionActive: useHDR,
            cropIsOpticalQuality: format.secondaryNativeResolutionZoomFactors.contains(2.0),
            isoRange: format.minISO...format.maxISO,
            shutterRange: minShutter...max(minShutter, maxShutter),
            sessionReplaced: false,
            note: note)
    }

    // MARK: Running

    func startRunning() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if !session.isRunning { session.startRunning() }
    }

    func stopRunning() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        if session.isRunning { session.stopRunning() }
    }

    // MARK: Preview layers

    /// NOTE: inner and outer displays each create a preview layer on the same session.
    /// VERIFY on device that a single-cam session feeds both; if not, drive the cover
    /// monitor from the analysis frames instead.
    func makePreviewLayer(for role: CameraRole) -> AVCaptureVideoPreviewLayer {
        if let multi = session as? AVCaptureMultiCamSession {
            let layer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multi)
            let input = role == .rear ? rearInput : innerInput
            let position: AVCaptureDevice.Position = role == .rear ? .back : .front
            if let input, let port = input.ports(for: .video, sourceDeviceType: input.device.deviceType,
                                                 sourceDevicePosition: position).first {
                let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
                if multi.canAddConnection(connection) { multi.addConnection(connection) }
            }
            return layer
        }
        return AVCaptureVideoPreviewLayer(session: session)
    }

    // MARK: Recording

    static var takesDirectory: URL {
        let dir = URL.documentsDirectory.appending(path: "Takes", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Starts the rear output and, in MultiCam, the inner output in the same session-queue
    /// turn, so both begin on the same frame boundary as closely as the hardware allows.
    /// Exact alignment comes from the start times recorded in `didStartRecordingTo` on
    /// the session's synchronization clock (`innerStartOffset`).
    ///
    /// Both files carry the same `sessionIdentifier` in their QuickTime metadata.
    func startRecording(sessionIdentifier: String, takeNumber: Int,
                        completion: @escaping @Sendable (Result<RecordingResult, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !movieOutput.isRecording else { return }
        recordingCompletion = completion
        pendingRecordingURLs = []
        finishedRecordingURLs = []
        startTimes = [:]
        rearRecordingURL = nil
        innerRecordingURL = nil
        let metadata = Self.metadata(sessionIdentifier: sessionIdentifier, takeNumber: takeNumber)
        movieOutput.metadata = metadata + [Self.item(.quickTimeMetadataCameraIdentifier, "rear-guest")]
        innerMovieOutput?.metadata = metadata + [Self.item(.quickTimeMetadataCameraIdentifier, "inner-host")]

        if let connection = movieOutput.connection(with: .video), let coordinator = rotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }

        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let base = "DuoDirector-T\(takeNumber)-\(stamp)"
        let rearURL = Self.takesDirectory.appending(path: "\(base)-rear.mov")
        pendingRecordingURLs.append(rearURL)
        rearRecordingURL = rearURL

        var innerURL: URL?
        if innerMovieOutput != nil {
            let url = Self.takesDirectory.appending(path: "\(base)-inner.mov")
            pendingRecordingURLs.append(url)
            innerRecordingURL = url
            innerURL = url
        }
        movieOutput.startRecording(to: rearURL, recordingDelegate: self)
        if let inner = innerMovieOutput, let innerURL { inner.startRecording(to: innerURL, recordingDelegate: self) }
    }

    var isMultiCamActive: Bool { session is AVCaptureMultiCamSession && innerMovieOutput != nil }

    /// Active camera names for diagnostics.
    var activeCameraNames: [String] {
        [rearInput?.device.localizedName, innerInput?.device.localizedName].compactMap { $0 }
    }

    private static func metadata(sessionIdentifier: String, takeNumber: Int) -> [AVMetadataItem] {
        [
            item(.quickTimeMetadataContentIdentifier, sessionIdentifier),
            item(.quickTimeMetadataTitle, "DuoDirector take \(takeNumber)"),
            item(.quickTimeMetadataSoftware, "DuoDirector"),
            item(.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: Date())),
        ]
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    func stopRecording() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        movieOutput.stopRecording()
        innerMovieOutput?.stopRecording()
    }

    /// Fallback metering when AVCaptureAudioDataOutput couldn't be attached.
    func connectionAudioLevels() -> AudioLevels? {
        guard let channels = movieOutput.connection(with: .audio)?.audioChannels, let left = channels.first else { return nil }
        let right = channels.count > 1 ? channels[1] : left
        return AudioLevels(peakL: left.peakHoldLevel, peakR: right.peakHoldLevel,
                           rmsL: left.averagePowerLevel, rmsR: right.averagePowerLevel)
    }

    // MARK: Manual device locking
    //
    // Each method takes the device lock, applies one parameter, and releases it. They're
    // cheap enough to call on every slider change (CameraEngine coalesces them anyway).

    func focus(atDevicePoint point: CGPoint) throws {
        guard let device = rearDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = point
            device.exposureMode = .autoExpose
        }
    }

    /// `position` nil → continuous autofocus.
    func setLensPosition(_ position: Float?) throws {
        guard let device = rearDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let position, device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: max(0, min(1, position)))
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    /// `iso`/`duration` nil → continuous auto exposure. Values are clamped to the active
    /// format. (Known iOS 27 beta report: custom exposure ignored on the front camera.)
    func setExposure(iso: Float?, duration seconds: Double?) throws {
        guard let device = rearDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard let iso, let seconds, device.isExposureModeSupported(.custom) else {
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            return
        }
        let format = device.activeFormat
        let clampedISO = max(format.minISO, min(format.maxISO, iso))
        let duration = CMTimeClampToRange(CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                          range: CMTimeRange(start: format.minExposureDuration,
                                                             end: min(format.maxExposureDuration, device.activeVideoMinFrameDuration)))
        device.setExposureModeCustom(duration: duration, iso: clampedISO)
    }

    /// `kelvin` nil → continuous auto white balance. Kelvin → device gains via
    /// `deviceWhiteBalanceGains(for:)`, each gain clamped to 1…maxWhiteBalanceGain
    /// (out-of-range gains raise an exception).
    func setWhiteBalance(kelvin: Float?, tint: Float = 0) throws {
        guard let device = rearDevice else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard let kelvin, device.isWhiteBalanceModeSupported(.locked) else {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            return
        }
        var gains = device.deviceWhiteBalanceGains(
            for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint))
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = max(1, min(maxGain, gains.redGain))
        gains.greenGain = max(1, min(maxGain, gains.greenGain))
        gains.blueGain = max(1, min(maxGain, gains.blueGain))
        device.setWhiteBalanceModeLocked(with: gains)
    }
}

// MARK: - Sample buffer delegates (audio meter + analysis)

extension CaptureSessionController: AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioDataOutput {
            if let levels = AudioMetering.levels(from: sampleBuffer) { onAudioLevels?(levels) }
            feedSinks(sampleBuffer, .audio)
        } else if output === videoDataOutput {
            // FrameAnalyzer returns immediately when overlays are off or it's throttling.
            frameAnalyzer?.analyze(sampleBuffer)
            feedSinks(sampleBuffer, .video)
        }
    }
}

/// Per-buffer RMS and peak in dBFS for up to two channels. Handles Int16, Int32 and
/// Float32 PCM, interleaved or not. Mono input reports the same value for L and R.
enum AudioMetering {
    static func levels(from sampleBuffer: CMSampleBuffer) -> CaptureSessionController.AudioLevels? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard listSize > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        var peak = [Float](repeating: 0, count: 2)
        var sumSquares = [Float](repeating: 0, count: 2)
        var frames = 0

        func sample(_ base: UnsafeMutableRawPointer, _ index: Int) -> Float {
            if isFloat && bits == 32 { return base.load(fromByteOffset: index * 4, as: Float.self) }
            if bits == 16 { return Float(base.load(fromByteOffset: index * 2, as: Int16.self)) / 32_768 }
            if bits == 32 { return Float(base.load(fromByteOffset: index * 4, as: Int32.self)) / 2_147_483_648 }
            return 0
        }

        for (bufferIndex, buffer) in UnsafeMutableAudioBufferListPointer(listPointer).enumerated() {
            guard let data = buffer.mData else { continue }
            let bytesPerSample = max(1, bits / 8)
            let stride = isNonInterleaved ? 1 : Int(buffer.mNumberChannels)
            let count = Int(buffer.mDataByteSize) / bytesPerSample / max(1, stride)
            frames = max(frames, count)
            for frame in 0..<count {
                for ch in 0..<stride {
                    let channel = min(1, isNonInterleaved ? bufferIndex : ch)
                    let value = abs(sample(data, frame * stride + ch))
                    peak[channel] = max(peak[channel], value)
                    sumSquares[channel] += value * value
                }
            }
        }
        guard frames > 0 else { return nil }
        if channels == 1 { peak[1] = peak[0]; sumSquares[1] = sumSquares[0] }

        func db(_ linear: Float) -> Float { 20 * log10(max(linear, 0.000_001)) }
        return .init(peakL: db(peak[0]), peakR: db(peak[1]),
                     rmsL: db(sqrt(sumSquares[0] / Float(frames))),
                     rmsR: db(sqrt(sumSquares[1] / Float(frames))))
    }
}

// MARK: - Recording delegate

extension CaptureSessionController: AVCaptureFileOutputRecordingDelegate {
    /// Record each file's real start on the session's synchronization clock.
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        let now = CMClockGetTime(clock)
        sessionQueue.async { [self] in startTimes[fileURL] = now }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async { [self] in
            // Some successful stops arrive with an error flagged "finished successfully".
            let succeeded = error == nil
                || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            if let error, !succeeded {
                recordingCompletion?(.failure(error))
                recordingCompletion = nil
                return
            }
            finishedRecordingURLs.append(outputFileURL)
            if finishedRecordingURLs.count == pendingRecordingURLs.count {
                var offset: TimeInterval = 0
                if let rear = rearRecordingURL, let inner = innerRecordingURL,
                   let r = startTimes[rear], let i = startTimes[inner] {
                    offset = CMTimeSubtract(i, r).seconds
                }
                recordingCompletion?(.success(RecordingResult(rearURL: rearRecordingURL, innerURL: innerRecordingURL,
                                                              innerStartOffset: offset)))
                recordingCompletion = nil
            }
        }
    }
}

enum CameraError: LocalizedError {
    case noCamera, noMatchingFormat, cannotAdd(String), unauthorized

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera is available."
        case .noMatchingFormat: "No camera format matches these settings."
        case .cannotAdd(let what): "Couldn't add \(what) to the capture session."
        case .unauthorized: "Camera or microphone access is turned off in Settings."
        }
    }
}
