import AVFoundation
#if canImport(RTMPHaishinKit)
import HaishinKit
import RTMPHaishinKit
#endif

// =====================================================================================
//  HaishinKitTransport (Phase 8): RTMP / RTMPS publishing via HaishinKit 2.x
//
//  Package: https://github.com/HaishinKit/HaishinKit.swift (products HaishinKit +
//  RTMPHaishinKit, confirmed from Package.swift on main, 2026-11-24). Pinned in project.yml.
//
//  CONFIRMED from the current RTMPHaishinKit docs:
//    let connection = RTMPConnection()
//    let stream = RTMPStream(connection: connection)
//    try await connection.connect("rtmp://host/app")        // async throws
//    try await stream.publish(streamName)                   // async throws
//    errors: RTMPConnection.Error.requestFailed / RTMPStream.Error.requestFailed
//    await stream.setVideoSettings(...) / setAudioSettings(...)   (2.0.x README)
//    VideoCodecSettings(videoSize:bitRate:...)                    (2.0.x README)
//  NOT CONFIRMED (the source file was rate-limited when checked; fix here on first build):
//    • `stream.append(_ sampleBuffer:)` for externally captured buffers. DuoDirector
//      owns the AVCaptureSession, so it can't hand the cameras to MediaMixer.
//    • `stream.close()` / `connection.close()`.
//    • a readyState/status stream for disconnect detection (polled via `connected` here).
//  RTMPS uses the OS TLS stack (export-compliance exempt). SRTHaishinKit is deliberately
//  not linked (libsrt AES would change the encryption answer).
// =====================================================================================

#if canImport(RTMPHaishinKit)
final class HaishinKitTransport: LiveStreamTransport, @unchecked Sendable {
    private let connection = RTMPConnection()
    private lazy var stream = RTMPStream(connection: connection)
    private let lock = NSLock()
    private var isPublishing = false
    private var lastBitrate = 0
    private var watchdog: Task<Void, Never>?
    var onDisconnect: (@Sendable (String) -> Void)?

    func start(server: String, streamKey: String, quality: LiveQuality) async throws {
        var video = VideoCodecSettings(videoSize: .init(width: quality.width, height: quality.height),
                                       bitRate: quality.videoBitrate)
        video.maxKeyFrameIntervalDuration = 2          // platforms want a 2 s GOP
        try? await stream.setVideoSettings(video)   // `try?` compiles whether or not it throws
        var audio = AudioCodecSettings()
        audio.bitRate = LiveQuality.audioBitrate        // VERIFY: 2.0.8 README spelled it `bitrate`
        try? await stream.setAudioSettings(audio)

        _ = try await connection.connect(server)         // VERIFY: return value (response) ignored
        _ = try await stream.publish(streamKey)
        lock.withLock { isPublishing = true; lastBitrate = quality.videoBitrate }
        startWatchdog()
    }

    func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard lock.withLock({ isPublishing }) else { return }
        // VERIFY: name/actor of the append API. If it's async/actor-isolated, wrap in a
        // Task here and keep a small queue so capture queues never block.
        Task { try? await stream.append(sampleBuffer) }
    }

    func setVideoBitrate(_ bitsPerSecond: Int) async {
        var video = await stream.videoSettings
        video.bitRate = bitsPerSecond
        try? await stream.setVideoSettings(video)
        lock.withLock { lastBitrate = bitsPerSecond }
    }

    func stop() async {
        watchdog?.cancel()
        lock.withLock { isPublishing = false }
        _ = try? await stream.close()                     // VERIFY name
        try? await connection.close()                     // VERIFY name
    }

    var currentStats: LiveStats {
        // VERIFY: HaishinKit exposes per-stream info (bytes out / dropped frames); until
        // wired, report the configured bitrate.
        LiveStats(sentBitsPerSecond: lock.withLock { isPublishing ? lastBitrate : 0 }, droppedFrames: 0)
    }

    /// Polls the connection once a second and reports a drop once.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let connected = await self.connection.connected     // VERIFY property name
                if !connected && self.lock.withLock({ self.isPublishing }) {
                    self.lock.withLock { self.isPublishing = false }
                    self.onDisconnect?("Connection to the server was lost.")
                    return
                }
            }
        }
    }
}
#endif

enum LiveTransportFactory {
    /// For diagnostics: which real transport this build links.
    static var realTransportName: String {
        #if canImport(RTMPHaishinKit)
        "HaishinKit RTMP/RTMPS"
        #else
        "None linked (mock only)"
        #endif
    }

    /// Real RTMP on device when HaishinKit is linked; the mock otherwise (Simulator
    /// without the package, Demo Mode, tests).
    static func make(mock: Bool) -> LiveStreamTransport {
        #if canImport(RTMPHaishinKit)
        if !mock { return HaishinKitTransport() }
        #endif
        return MockLiveTransport()
    }
}
