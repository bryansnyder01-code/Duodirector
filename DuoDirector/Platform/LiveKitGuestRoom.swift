import AVFoundation
#if canImport(LiveKit)
import LiveKit
#endif

// =====================================================================================
//  LiveKitGuestRoom (Phase 9): remote guests over LiveKit (WebRTC)
//
//  Package: https://github.com/livekit/client-sdk-swift, product `LiveKit`, latest 2.17.0,
//  swift-tools 6.2 (Xcode 26+), iOS 13+. Linked only by the `project-guests.yml` build
//  variant, because WebRTC brings its own encryption (DTLS-SRTP), which changes the
//  export-compliance answer. Without the package, the mock room is used.
//
//  CONFIRMED from the SDK source on main (2026-11-24):
//    LocalVideoTrack.createBufferTrack(name:source:options:reportStatistics:) async
//    BufferCapturer.capture(_ sampleBuffer: CMSampleBuffer)
//    VideoRenderer { isAdaptiveStreamEnabled, adaptiveStreamSize, render(frame:) }
//    VideoTrack.add(videoRenderer:), VideoFrame.toCVPixelBuffer()
//    AudioRenderer.render(pcmBuffer:), RemoteAudioTrack.add(audioRenderer:)
//    RoomDelegate participantDidConnect / participantDidDisconnect / didSubscribeTrack /
//      didStartReconnectWithMode / didCompleteReconnectWithMode / didDisconnectWithError
//    AudioManager.shared.audioSession.isAutomaticConfigurationEnabled (FAQ)
//  NOT CONFIRMED (fix on first build):
//    • room.connect(url:token:) exact labels/options, room.disconnect()
//    • localParticipant.publish(videoTrack:) and setMicrophone(enabled:)
//    • how to reach the BufferCapturer from the track (`track.capturer as? BufferCapturer`)
//    • Track.Source `.camera` spelling
// =====================================================================================

#if canImport(LiveKit)
final class LiveKitGuestRoom: NSObject, GuestRoomTransport, @unchecked Sendable {
    let events = GuestRoomEvents()
    private let room = Room()
    private let lock = NSLock()
    private var capturer: BufferCapturer?
    private var videoTrack: LocalVideoTrack?
    private var hasPublished = false
    private var renderers: [VideoRenderer] = []
    private var audioRenderers: [AudioRenderer] = []

    override init() {
        super.init()
        room.add(delegate: self)                                   // VERIFY name
        // DuoDirector owns the AVAudioSession (playAndRecord / videoRecording for the
        // capture session). Don't let WebRTC reconfigure it mid-take.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
    }

    func connect(serverURL: String, token: String) async throws {
        try await room.connect(url: serverURL, token: token)       // VERIFY options
        let track = await LocalVideoTrack.createBufferTrack(name: "host-camera", source: .camera)
        lock.withLock { videoTrack = track; capturer = track.capturer as? BufferCapturer }  // VERIFY
        // "At least one frame must be captured before publishing" (SDK doc): publish from
        // appendHost once the first frame has gone in.
        try? await room.localParticipant.setMicrophone(enabled: true)   // VERIFY: shares the mic with AVCaptureSession
    }

    func disconnect() async {
        lock.withLock { capturer = nil; videoTrack = nil; hasPublished = false; renderers.removeAll(); audioRenderers.removeAll() }
        await room.disconnect()                                     // VERIFY
    }

    func appendHost(_ sampleBuffer: CMSampleBuffer, mediaType: AVMediaType) {
        guard mediaType == .video else { return }   // mic goes through WebRTC's own capture
        let (capturer, track, needsPublish) = lock.withLock { () -> (BufferCapturer?, LocalVideoTrack?, Bool) in
            let first = !hasPublished && capturer != nil
            if first { hasPublished = true }
            return (capturer, videoTrack, first)
        }
        capturer?.capture(sampleBuffer)
        if needsPublish, let track {
            Task { [room] in _ = try? await room.localParticipant.publish(videoTrack: track) }   // VERIFY
        }
    }

    fileprivate func attach(_ publication: RemoteTrackPublication) {
        if let video = publication.track as? VideoTrack {
            let r = FrameTap(events: events)
            lock.withLock { renderers.append(r) }
            video.add(videoRenderer: r)
        } else if let audio = publication.track as? RemoteAudioTrack {
            let r = AudioTap(events: events)
            lock.withLock { audioRenderers.append(r) }
            audio.add(audioRenderer: r)
        }
    }
}

extension LiveKitGuestRoom: RoomDelegate {
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        events.guestJoined?(participant.name ?? participant.identity?.stringValue ?? "Guest")   // VERIFY identity type
    }
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        if room.remoteParticipants.isEmpty { events.guestLeft?() }
    }
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        attach(publication)
    }
    func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) { events.reconnecting?(true) }
    func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) { events.reconnecting?(false) }
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) { events.disconnected?(error?.localizedDescription) }
}

private final class FrameTap: NSObject, VideoRenderer, @unchecked Sendable {
    let events: GuestRoomEvents
    init(events: GuestRoomEvents) { self.events = events }
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { CGSize(width: 1280, height: 720) }
    nonisolated func render(frame: VideoFrame) {
        if let pixels = frame.toCVPixelBuffer() { events.guestFrame?(pixels) }
    }
}

private final class AudioTap: NSObject, AudioRenderer, @unchecked Sendable {
    let events: GuestRoomEvents
    init(events: GuestRoomEvents) { self.events = events }
    func render(pcmBuffer: AVAudioPCMBuffer) { events.guestAudio?(pcmBuffer) }
}
#endif

enum GuestRoomFactory {
    static func make(mock: Bool) -> GuestRoomTransport {
        #if canImport(LiveKit)
        if !mock { return LiveKitGuestRoom() }
        #endif
        return MockGuestRoom()
    }
    static var isLiveKitLinked: Bool {
        #if canImport(LiveKit)
        true
        #else
        false
        #endif
    }
}
