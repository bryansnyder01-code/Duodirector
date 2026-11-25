import Foundation
import Testing
@testable import DuoDirector

@Suite("Go Live (Phase 8)")
struct Phase8Tests {

    // MARK: Validation

    @Test func acceptsRTMPAndRTMPS() {
        #expect(StreamPolicy.validate(server: "rtmps://a.rtmps.youtube.com/live2", key: "abcd-1234", isDualCam: false) == nil)
        #expect(StreamPolicy.validate(server: "rtmp://192.168.1.20/live", key: "k", isDualCam: false) == nil)
        #expect(StreamPolicy.validate(server: "  RTMPS://live.twitch.tv/app ", key: "k", isDualCam: false) == nil)
    }

    @Test func rejectsBadInput() {
        #expect(StreamPolicy.validate(server: "https://youtube.com", key: "k", isDualCam: false) == .badScheme)
        #expect(StreamPolicy.validate(server: "srt://host:9000", key: "k", isDualCam: false) == .srtNotOffered)
        #expect(StreamPolicy.validate(server: "rtmp://", key: "k", isDualCam: false) == .missingHost)
        #expect(StreamPolicy.validate(server: "rtmps://live.twitch.tv/app", key: "   ", isDualCam: false) == .missingKey)
        #expect(StreamPolicy.validate(server: "rtmps://live.twitch.tv/app", key: "k", isDualCam: true) == .dualCamUnsupported)
    }

    // MARK: Heat, backoff, redaction

    @Test func heatLowersBitrate() {
        #expect(StreamPolicy.videoBitrate(base: 6_000_000, thermal: .nominal) == 6_000_000)
        #expect(StreamPolicy.videoBitrate(base: 6_000_000, thermal: .fair) == 6_000_000)
        #expect(StreamPolicy.videoBitrate(base: 6_000_000, thermal: .serious) == 4_200_000)
        #expect(StreamPolicy.videoBitrate(base: 6_000_000, thermal: .critical) == 3_000_000)
    }

    @Test func reconnectBackoffIsCappedAndFinite() {
        let delays = (1...StreamPolicy.maxReconnectAttempts).compactMap(StreamPolicy.reconnectDelay)
        #expect(delays == [1, 2, 4, 8, 15, 15, 15, 15])
        #expect(StreamPolicy.reconnectDelay(attempt: 0) == nil)
        #expect(StreamPolicy.reconnectDelay(attempt: StreamPolicy.maxReconnectAttempts + 1) == nil)
    }

    @Test func keysAreRedacted() {
        #expect(StreamPolicy.redacted("abcd-efgh-1234") == "••••••••••1234")
        #expect(StreamPolicy.redacted("abc") == "•••")
        #expect(!StreamPolicy.redacted("secret-key-9876").contains("secret"))
    }

    // MARK: Models

    @Test func presetsUseRTMPS() {
        #expect(StreamDestination.preset(.youtube).usesTLS)
        #expect(StreamDestination.preset(.twitch).usesTLS)
        #expect(StreamDestination.preset(.custom).serverURL.isEmpty)
    }

    @Test func destinationJSONNeverContainsAKey() throws {
        let d = StreamDestination.preset(.twitch)
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        #expect(!json.lowercased().contains("key"))
        #expect(try JSONDecoder().decode(StreamDestination.self, from: Data(json.utf8)) == d)
    }

    @Test func qualityLadder() {
        #expect(LiveQuality.p720_30.width == 1280 && LiveQuality.p720_30.frameRate == 30)
        #expect(LiveQuality.p1080_60.height == 1080 && LiveQuality.p1080_60.frameRate == 60)
        #expect(LiveQuality.allCases.map(\.videoBitrate) == LiveQuality.allCases.map(\.videoBitrate).sorted())
    }

    @Test func liveStateFlags() {
        #expect(LiveState.connecting.isActive && !LiveState.connecting.isLive)
        #expect(LiveState.live(since: .now).isLive)
        #expect(LiveState.reconnecting(attempt: 2).isActive)
        #expect(!LiveState.failed("x").isActive && !LiveState.idle.isActive)
    }

    // MARK: Transport

    @Test func mockTransportConnectsAndReportsStats() async throws {
        let t = MockLiveTransport()
        try await t.start(server: "rtmps://example.test/app", streamKey: "k", quality: .p720_30)
        #expect(t.currentStats.sentBitsPerSecond > 2_000_000)
        await t.setVideoBitrate(1_000_000)
        #expect(t.currentStats.sentBitsPerSecond < 1_200_000)
        await t.stop()
        #expect(t.currentStats.sentBitsPerSecond == 0)
    }

    @Test func mockTransportFailurePath() async {
        let t = MockLiveTransport()
        await #expect(throws: (any Error).self) {
            try await t.start(server: "rtmps://fail.test/app", streamKey: "k", quality: .p720_30)
        }
    }

    // MARK: Remote compatibility

    @Test func remoteStatusWithoutIsLiveStillDecodes() throws {
        // A Phase 6/7 camera doesn't send `isLive`; a Phase 8 remote must still decode it.
        let old = """
        {"isRecording":false,"recordingDuration":0,"takeNumber":1,"captureMode":"singleRearPro","leftDB":-60,
         "rightDB":-60,"isClipping":false,"thermal":0,"isCharging":false,"isPrompterPlaying":false,
         "prompterSpeed":1,"markerCount":0,"takeRating":0,"previewAvailable":true}
        """
        let status = try JSONDecoder().decode(RemoteStatus.self, from: Data(old.utf8))
        #expect(status.isLive == nil)
    }
}
