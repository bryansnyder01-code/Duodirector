import Foundation
import CoreGraphics

// =====================================================================================
//  Remote guests (Phase 9): models and pure policies
//
//  A guest joins a LiveKit room from a link (any browser, via LiveKit Meet, or another
//  DuoDirector). The host's camera is published into the room; the guest's video and
//  audio come back, show as a tile, and can be composited into the Go Live stream.
//
//  Tokens: a LiveKit client needs a short-lived JWT signed with the project's API secret.
//  The secret must NEVER ship in the app, so DuoDirector asks the user's own token
//  endpoint (LiveKit Cloud's token server, or a few lines on any server) for tokens.
//  For development, a token minted with `lk token create` can be pasted instead.
// =====================================================================================

struct GuestRoomConfig: Codable, Equatable, Sendable {
    /// HTTPS endpoint that returns LiveKit tokens (see TokenRequest / TokenResponse).
    var tokenEndpoint: String = ""
    /// Optional wss:// LiveKit URL. Used when the endpoint doesn't return one.
    var serverURL: String = ""
    var roomName: String = "duodirector-studio"
    var hostName: String = "Host"

    static let defaultsKey = "guests.config"
}

/// The JSON a token endpoint receives and returns. Field names follow LiveKit's standard
/// token-endpoint format (VERIFY against docs.livekit.io › Authentication › Tokens).
struct TokenRequest: Codable, Equatable, Sendable {
    var room_name: String
    var participant_identity: String
    var participant_name: String
}

struct TokenResponse: Codable, Equatable, Sendable {
    var server_url: String?
    var participant_token: String
}

enum GuestState: Equatable, Sendable {
    case idle
    case connecting
    /// In the room, nobody else has joined yet.
    case waiting
    case connected(guestName: String)
    case reconnecting
    case failed(String)

    var isInRoom: Bool {
        switch self {
        case .waiting, .connected, .reconnecting: true
        case .idle, .connecting, .failed: false
        }
    }
    var guestName: String? { if case .connected(let n) = self { n } else { nil } }
}

/// How the guest appears in the stream (and the host's preview).
enum GuestLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case pictureInPicture, sideBySide
    var id: String { rawValue }
    var label: String { self == .pictureInPicture ? "Guest in corner" : "Side by side" }

    /// Where the host and guest images go on a canvas (CG coordinates, origin bottom-left,
    /// which is what Core Image uses). Pure, unit-tested.
    func rects(canvas: CGSize) -> (host: CGRect, guest: CGRect) {
        switch self {
        case .pictureInPicture:
            let w = (canvas.width * 0.28).rounded()
            let h = (w * 9 / 16).rounded()
            let margin = (canvas.width * 0.025).rounded()
            return (CGRect(origin: .zero, size: canvas),
                    CGRect(x: canvas.width - w - margin, y: margin, width: w, height: h))
        case .sideBySide:
            let half = (canvas.width / 2).rounded(.down)
            return (CGRect(x: 0, y: 0, width: half, height: canvas.height),
                    CGRect(x: half, y: 0, width: canvas.width - half, height: canvas.height))
        }
    }
}

enum GuestPolicy {

    enum ConfigError: Error, Equatable { case endpointNotHTTPS, badServerURL, emptyRoom, dualCamUnsupported }

    static func validate(_ config: GuestRoomConfig, isDualCam: Bool, hasManualToken: Bool) -> ConfigError? {
        if isDualCam { return .dualCamUnsupported }
        if config.roomName.trimmingCharacters(in: .whitespaces).isEmpty { return .emptyRoom }
        let server = config.serverURL.trimmingCharacters(in: .whitespaces).lowercased()
        if !server.isEmpty, !(server.hasPrefix("wss://") || server.hasPrefix("ws://")) { return .badServerURL }
        if hasManualToken { return server.isEmpty ? .badServerURL : nil }
        guard let url = URL(string: config.tokenEndpoint.trimmingCharacters(in: .whitespaces)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return .endpointNotHTTPS }
        return nil
    }

    /// Identities must be unique per room. The host is fixed; each invite gets a new one.
    static let hostIdentity = "duodirector-host"
    static func guestIdentity(_ id: UUID = UUID()) -> String { "guest-" + id.uuidString.prefix(8).lowercased() }

    /// A link the guest opens in any browser: LiveKit Meet's custom-server page.
    /// VERIFY the query names on https://meet.livekit.io before launch. The link holds a
    /// short-lived token, so share it only with the guest.
    static func meetLink(serverURL: String, token: String) -> URL? {
        var c = URLComponents(string: "https://meet.livekit.io/custom")
        c?.queryItems = [URLQueryItem(name: "liveKitUrl", value: serverURL),
                         URLQueryItem(name: "token", value: token)]
        return c?.url
    }

    /// The guest's tile is only worth compositing while their video is fresh.
    static let staleFrameSeconds: Double = 1.5
    static func isFresh(lastFrameAt: Date?, now: Date = .now) -> Bool {
        guard let t = lastFrameAt else { return false }
        return now.timeIntervalSince(t) < staleFrameSeconds
    }

    /// Guest audio level in the stream mix (0…1). Ducked a little under the host's mic
    /// so a hot guest line doesn't clip the mix.
    static let guestMixGain: Float = 0.85
}
