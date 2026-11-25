import Foundation
import CoreImage
import CoreVideo
import Testing
@testable import DuoDirector

@Suite("Remote guests (Phase 9)")
struct Phase9Tests {

    private func config(endpoint: String = "https://tokens.example.com/livekit", server: String = "",
                        room: String = "studio") -> GuestRoomConfig {
        GuestRoomConfig(tokenEndpoint: endpoint, serverURL: server, roomName: room, hostName: "Host")
    }

    // MARK: Validation

    @Test func validEndpointConfigPasses() {
        #expect(GuestPolicy.validate(config(), isDualCam: false, hasManualToken: false) == nil)
        #expect(GuestPolicy.validate(config(server: "wss://x.livekit.cloud"), isDualCam: false, hasManualToken: false) == nil)
    }

    @Test func rejectsBadConfigs() {
        #expect(GuestPolicy.validate(config(), isDualCam: true, hasManualToken: false) == .dualCamUnsupported)
        #expect(GuestPolicy.validate(config(room: "  "), isDualCam: false, hasManualToken: false) == .emptyRoom)
        #expect(GuestPolicy.validate(config(endpoint: "http://insecure.example.com"), isDualCam: false, hasManualToken: false) == .endpointNotHTTPS)
        #expect(GuestPolicy.validate(config(endpoint: ""), isDualCam: false, hasManualToken: false) == .endpointNotHTTPS)
        #expect(GuestPolicy.validate(config(server: "https://x.livekit.cloud"), isDualCam: false, hasManualToken: false) == .badServerURL)
    }

    @Test func manualTokenNeedsAServerButNoEndpoint() {
        #expect(GuestPolicy.validate(config(endpoint: ""), isDualCam: false, hasManualToken: true) == .badServerURL)
        #expect(GuestPolicy.validate(config(endpoint: "", server: "wss://x.livekit.cloud"), isDualCam: false, hasManualToken: true) == nil)
    }

    // MARK: Identities, links, tokens

    @Test func guestIdentitiesAreUniqueAndNeverTheHost() {
        let a = GuestPolicy.guestIdentity(), b = GuestPolicy.guestIdentity()
        #expect(a != b && a.hasPrefix("guest-") && a != GuestPolicy.hostIdentity)
    }

    @Test func meetLinkCarriesServerAndToken() throws {
        let url = try #require(GuestPolicy.meetLink(serverURL: "wss://x.livekit.cloud", token: "abc.def"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host == "meet.livekit.io")
        #expect(items.first { $0.name == "liveKitUrl" }?.value == "wss://x.livekit.cloud")
        #expect(items.first { $0.name == "token" }?.value == "abc.def")
    }

    @Test func tokenEndpointJSONShape() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            TokenRequest(room_name: "studio", participant_identity: "duodirector-host", participant_name: "Host"))) as? [String: String]
        #expect(body?["room_name"] == "studio" && body?["participant_identity"] == "duodirector-host")
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"participant_token":"t"}"#.utf8))
        #expect(response.server_url == nil && response.participant_token == "t")
    }

    // MARK: Layout & freshness

    @Test func pipSitsBottomRightInsideTheCanvas() {
        let canvas = CGSize(width: 1920, height: 1080)
        let r = GuestLayout.pictureInPicture.rects(canvas: canvas)
        #expect(r.host == CGRect(origin: .zero, size: canvas))
        #expect(r.guest.maxX < canvas.width && r.guest.minY > 0 && r.guest.minY < 100)   // CI origin is bottom-left
        #expect(abs(r.guest.width / r.guest.height - 16.0 / 9.0) < 0.02)
    }

    @Test func sideBySideSplitsWithoutGaps() {
        let r = GuestLayout.sideBySide.rects(canvas: CGSize(width: 1281, height: 720))
        #expect(r.host.maxX == r.guest.minX)
        #expect(r.host.width + r.guest.width == 1281)
    }

    @Test func fillCoversTheTargetRect() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        let rect = CGRect(x: 100, y: 50, width: 320, height: 180)
        #expect(GuestStreamCompositor.fill(image, into: rect).extent.integral == rect)
    }

    @Test func staleGuestFramesDropOut() {
        let now = Date()
        #expect(GuestPolicy.isFresh(lastFrameAt: now.addingTimeInterval(-0.5), now: now))
        #expect(!GuestPolicy.isFresh(lastFrameAt: now.addingTimeInterval(-3), now: now))
        #expect(!GuestPolicy.isFresh(lastFrameAt: nil, now: now))
    }

    @Test func frameStoreReturnsOnlyFreshFrames() {
        let store = GuestFrameStore()
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        store.put(pb!)
        #expect(store.freshFrame() != nil)
        #expect(store.freshFrame(now: .now.addingTimeInterval(5)) == nil)
        store.clear()
        #expect(store.freshFrame() == nil)
    }

    @Test func guestStateFlags() {
        #expect(GuestState.waiting.isInRoom && GuestState.connected(guestName: "Sam").isInRoom)
        #expect(GuestState.connected(guestName: "Sam").guestName == "Sam")
        #expect(!GuestState.connecting.isInRoom && !GuestState.failed("x").isInRoom)
    }

    @Test func mockRoomFailurePath() async {
        let room = MockGuestRoom()
        await #expect(throws: (any Error).self) { try await room.connect(serverURL: "wss://fail.test", token: "t") }
    }

    @Test func remoteStatusWithoutGuestStillDecodes() throws {
        let json = """
        {"isRecording":false,"recordingDuration":0,"takeNumber":1,"captureMode":"singleRearPro","leftDB":-60,
         "rightDB":-60,"isClipping":false,"thermal":0,"isCharging":false,"isPrompterPlaying":false,
         "prompterSpeed":1,"markerCount":0,"takeRating":0,"previewAvailable":true,"isLive":true}
        """
        let status = try JSONDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
        #expect(status.guestName == nil && status.isLive == true)
    }
}
