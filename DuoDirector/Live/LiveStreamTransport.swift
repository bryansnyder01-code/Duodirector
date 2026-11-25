import AVFoundation

// =====================================================================================
//  LiveStreamTransport (Phase 8): the seam between DuoDirector and a streaming library
//
//  LiveStreamController talks only to this protocol, so:
//    • the HaishinKit adapter (Platform/HaishinKitTransport.swift) is the ONE file that
//      touches HaishinKit's API, the same isolation pattern as DuoPlatformAPIs.swift,
//    • the Simulator / Demo Mode use MockLiveTransport (no network),
//    • a LiveKit/WebRTC transport for remote guests can slot in next phase.
//
//  Threading: `append` is called on the capture queues (audio/video) at frame rate and
//  must not block. Everything else is called from the main actor.
// =====================================================================================

protocol LiveStreamTransport: AnyObject, Sendable {
    /// Connects and starts publishing. Throws a readable error on auth/network failure.
    func start(server: String, streamKey: String, quality: LiveQuality) async throws
    /// Feeds one captured buffer (BGRA video or PCM audio).
    func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType)
    func setVideoBitrate(_ bitsPerSecond: Int) async
    func stop() async
    /// Called (any thread) when the connection drops after a successful start.
    var onDisconnect: (@Sendable (String) -> Void)? { get set }
    /// Upload stats for the HUD (bits per second actually sent, frames dropped).
    var currentStats: LiveStats { get }
}

struct LiveStats: Equatable, Sendable {
    var sentBitsPerSecond: Int = 0
    var droppedFrames: Int = 0
}

/// Simulator / Demo Mode transport: accepts buffers, reports believable stats, never
/// touches the network. A server containing "fail" throws, to test the error path.
final class MockLiveTransport: LiveStreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bitrate = 0
    private var frames = 0
    var onDisconnect: (@Sendable (String) -> Void)?

    func start(server: String, streamKey: String, quality: LiveQuality) async throws {
        try await Task.sleep(for: .milliseconds(800))      // feels like a handshake
        if server.contains("fail") { throw URLError(.cannotConnectToHost) }
        lock.withLock { bitrate = quality.videoBitrate }
    }

    func append(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        lock.withLock { frames += 1 }
    }

    func setVideoBitrate(_ bitsPerSecond: Int) async { lock.withLock { bitrate = bitsPerSecond } }
    func stop() async { lock.withLock { bitrate = 0 } }

    var currentStats: LiveStats {
        lock.withLock { LiveStats(sentBitsPerSecond: bitrate == 0 ? 0 : bitrate + Int.random(in: -150_000...150_000),
                                  droppedFrames: 0) }
    }
}
