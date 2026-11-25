import Foundation
import Security

// =====================================================================================
//  Go Live (Phase 8): models, pure policies, and Keychain storage for stream keys
// =====================================================================================

/// Where a stream goes. The stream KEY is never stored here (it's a secret). It lives in
/// the Keychain under `id` (StreamKeyStore).
struct StreamDestination: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case youtube, twitch, custom
        var label: String {
            switch self {
            case .youtube: "YouTube Live"
            case .twitch: "Twitch"
            case .custom: "Custom RTMP / RTMPS"
            }
        }
        /// Platform ingest defaults. Users can override the server for regional ingests.
        /// VERIFY before launch: copy the current RTMPS ingest from each platform's
        /// dashboard (YouTube Studio › Go live › Stream settings; Twitch › Stream Manager).
        var defaultServer: String {
            switch self {
            case .youtube: "rtmps://a.rtmps.youtube.com/live2"
            case .twitch: "rtmps://live.twitch.tv/app"
            case .custom: ""
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var serverURL: String

    var usesTLS: Bool { serverURL.lowercased().hasPrefix("rtmps://") }

    static func preset(_ kind: Kind) -> StreamDestination {
        StreamDestination(name: kind.label, kind: kind, serverURL: kind.defaultServer)
    }
}

/// Output quality. Bitrates follow YouTube/Twitch guidance for H.264 at these sizes.
enum LiveQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case p720_30, p1080_30, p1080_60
    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720_30: "720p30 · 2.5 Mbps"
        case .p1080_30: "1080p30 · 4.5 Mbps"
        case .p1080_60: "1080p60 · 6 Mbps"
        }
    }
    var width: Int { self == .p720_30 ? 1280 : 1920 }
    var height: Int { self == .p720_30 ? 720 : 1080 }
    var frameRate: Int { self == .p1080_60 ? 60 : 30 }
    var videoBitrate: Int {
        switch self {
        case .p720_30: 2_500_000
        case .p1080_30: 4_500_000
        case .p1080_60: 6_000_000
        }
    }
    static let audioBitrate = 128_000
}

enum LiveState: Equatable, Sendable {
    case idle
    case connecting
    case live(since: Date)
    case reconnecting(attempt: Int)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .connecting, .live, .reconnecting: true
        case .idle, .failed: false
        }
    }
    var isLive: Bool { if case .live = self { true } else { false } }
}

/// Pure rules, unit-tested.
enum StreamPolicy {

    enum ValidationError: Error, Equatable {
        case badScheme, missingHost, missingKey, dualCamUnsupported, srtNotOffered
    }

    /// RTMP/RTMPS only. SRT would bring libsrt's own AES encryption, which would change
    /// the app's export-compliance answer (ITSAppUsesNonExemptEncryption = NO).
    static func validate(server: String, key: String, isDualCam: Bool) -> ValidationError? {
        if isDualCam { return .dualCamUnsupported }
        let lower = server.trimmingCharacters(in: .whitespaces).lowercased()
        if lower.hasPrefix("srt://") { return .srtNotOffered }
        guard lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://") else { return .badScheme }
        guard let url = URL(string: lower), let host = url.host, !host.isEmpty else { return .missingHost }
        if key.trimmingCharacters(in: .whitespaces).isEmpty { return .missingKey }
        return nil
    }

    /// Heat costs bitrate first, then frame rate: serious = 70 %, critical = 50 %.
    static func videoBitrate(base: Int, thermal: ProcessInfo.ThermalState) -> Int {
        switch thermal {
        case .serious: base * 7 / 10
        case .critical: base / 2
        default: base
        }
    }

    /// Exponential backoff with a cap: 1, 2, 4, 8, 15, 15… seconds. Gives up after `maxAttempts`.
    static let maxReconnectAttempts = 8
    static func reconnectDelay(attempt: Int) -> Double? {
        guard attempt >= 1, attempt <= maxReconnectAttempts else { return nil }
        return min(15, pow(2, Double(attempt - 1)))
    }

    /// Never post the key anywhere a screenshot or log could catch it.
    static func redacted(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "•", count: key.count) }
        return String(repeating: "•", count: key.count - 4) + key.suffix(4)
    }
}

/// Stream keys in the Keychain (kSecClassGenericPassword, this device only, available
/// after first unlock so a locked phone mid-stream can still reconnect).
enum StreamKeyStore {
    private static let service = "com.duodirector.streamkey"

    static func save(_ key: String, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func load(for id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: id.uuidString,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(for id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}
