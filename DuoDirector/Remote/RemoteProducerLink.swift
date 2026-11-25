import Foundation
import MultipeerConnectivity
import Observation
import UIKit

// =====================================================================================
//  Remote Producer mode (Phase 6)
//
//  A second iPhone or iPad running DuoDirector becomes a wireless producer remote for the
//  camera phone. It's the "live/remote" candidate scoped to what runs fully on device.
//  Streaming to the internet (RTMP/WebRTC) or recording a remote guest's camera needs a
//  media server or a third-party SDK and stays a future phase.
//
//    CAMERA (the iPhone Duo)                 REMOTE (any iPhone / iPad)
//    advertises "_duodirector._tcp"   ◀───▶  browses, invites
//    asks the user to accept the remote      shows: tally, timecode, ~4 fps preview,
//    sends status at 5 Hz + thumbnails       stereo meters, thermal/battery/storage,
//    executes commands via CameraEngine      prompter + shot; sends commands:
//                                            record/stop, marker, rate, prompter, next shot
//
//  TRANSPORT
//    MultipeerConnectivity (peer-to-peer Wi-Fi / Bluetooth, no router needed), with
//    `encryptionPreference: .required`. Status and thumbnails are sent `.unreliable`
//    (newest wins), commands and the script `.reliable`.
//  SAFETY
//    • The camera user must accept every remote (`pendingInvitation` → alert in
//      CaptureRootView). Only one remote at a time.
//    • A remote can never change the capture mode or format mid-take, delete takes, or
//      touch files. Its commands are exactly the producer actions listed above.
//    • Thumbnails stop at thermal serious (the analysis tap costs GPU time) and in
//      Dual-Cam, which has no video data output to sample.
//  Info.plist: NSLocalNetworkUsageDescription + NSBonjourServices (project.yml).
// =====================================================================================

// MARK: - Wire format (pure Codable, unit-tested)

struct RemoteStatus: Codable, Equatable, Sendable {
    var isRecording: Bool
    var recordingDuration: Double
    var takeNumber: Int
    var captureMode: CaptureMode
    var leftDB: Float
    var rightDB: Float
    var isClipping: Bool
    var thermal: Int                     // ProcessInfo.ThermalState.rawValue
    var batteryLevel: Float?
    var isCharging: Bool
    var minutesLeft: Int?
    var isPrompterPlaying: Bool
    var prompterSpeed: Double
    var activeShotTitle: String?
    var markerCount: Int
    var takeRating: Int
    var countdownRemaining: Int?
    var previewAvailable: Bool
    /// Phase 8. Optional so an older remote (or camera) still decodes the message.
    var isLive: Bool? = nil
    /// Phase 9. The connected remote guest's name, if any.
    var guestName: String? = nil
}

enum RemoteCommand: Codable, Equatable, Sendable {
    case toggleRecording
    case dropMarker(rating: Int, note: String?)
    case rateTake(Int)
    case togglePrompter
    case resetPrompter
    case setPrompterSpeed(Double)
    case nextShot
}

enum RemoteMessage: Codable, Equatable, Sendable {
    case hello(appVersion: String, deviceName: String)
    case status(RemoteStatus)
    case preview(Data)
    case script(String)
    case command(RemoteCommand)

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> RemoteMessage? { try? JSONDecoder().decode(RemoteMessage.self, from: data) }
}

extension RemoteStatus {
    /// Snapshot of the camera's state for the remote.
    @MainActor init(state: StudioSessionState, previewAvailable: Bool) {
        self.init(isRecording: state.isRecording, recordingDuration: state.recordingDuration,
                  takeNumber: state.takeNumber, captureMode: state.captureMode,
                  leftDB: state.leftChannelDB, rightDB: state.rightChannelDB, isClipping: state.isAudioClipping,
                  thermal: state.thermalState.rawValue, batteryLevel: state.batteryLevel, isCharging: state.isCharging,
                  minutesLeft: state.estimatedRecordingMinutesLeft, isPrompterPlaying: state.isPrompterPlaying,
                  prompterSpeed: state.prompterScrollSpeed, activeShotTitle: state.activeShot?.title,
                  markerCount: state.markers(forTake: state.takeNumber).count, takeRating: state.currentTakeRating,
                  countdownRemaining: state.countdownRemaining, previewAvailable: previewAvailable,
                  isLive: state.isLive, guestName: state.guestState.guestName)
    }
}

// MARK: - Link

@MainActor
@Observable
final class RemoteProducerLink {

    enum Role: Equatable { case idle, camera, remote }

    struct Invitation: Identifiable {
        let id = UUID()
        let peerName: String
        fileprivate let respond: (Bool) -> Void
    }

    static let serviceType = "duodirector"     // → _duodirector._tcp / _udp

    private(set) var role: Role = .idle
    private(set) var connectedPeerName: String?
    private(set) var discoveredPeers: [MCPeerID] = []
    var pendingInvitation: Invitation?
    // Remote-side mirrors of the camera.
    private(set) var remoteStatus: RemoteStatus?
    private(set) var remotePreview: UIImage?
    private(set) var remoteScript = ""
    private(set) var lastError: String?

    @ObservationIgnored private let state: StudioSessionState
    @ObservationIgnored private weak var engine: CameraEngine?
    @ObservationIgnored private let peerID = MCPeerID(displayName: UIDevice.current.name)
    @ObservationIgnored private var session: MCSession?
    @ObservationIgnored private var advertiser: MCNearbyServiceAdvertiser?
    @ObservationIgnored private var browser: MCNearbyServiceBrowser?
    @ObservationIgnored private var bridge: MultipeerBridge?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(state: StudioSessionState, engine: CameraEngine) {
        self.state = state
        self.engine = engine
    }

    var isConnected: Bool { connectedPeerName != nil }

    // MARK: Camera role

    func startCamera() {
        stop()
        role = .camera
        let session = makeSession()
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["role": "camera"], serviceType: Self.serviceType)
        advertiser.delegate = bridge
        advertiser.startAdvertisingPeer()
        self.session = session
        self.advertiser = advertiser
    }

    // MARK: Remote role

    func startRemote() {
        stop()
        role = .remote
        session = makeSession()
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = bridge
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func connect(to peer: MCPeerID) {
        guard role == .remote, let session, let browser else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func send(_ command: RemoteCommand) {
        guard role == .remote else { return }
        send(.command(command), mode: .reliable)
    }

    // MARK: Teardown

    func stop() {
        statusTask?.cancel()
        statusTask = nil
        engine?.analyzer.setThumbnailSink(nil)
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil; browser = nil; session = nil; bridge = nil
        role = .idle
        connectedPeerName = nil
        discoveredPeers = []
        remoteStatus = nil
        remotePreview = nil
        pendingInvitation = nil
    }

    // MARK: Internals

    private func makeSession() -> MCSession {
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        let bridge = MultipeerBridge(owner: self)
        session.delegate = bridge
        self.bridge = bridge
        return session
    }

    private func send(_ message: RemoteMessage, mode: MCSessionSendDataMode) {
        guard let session, !session.connectedPeers.isEmpty, let data = try? message.encoded() else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: mode)
    }

    /// Camera side: 5 Hz status, plus thumbnails when available.
    private func startStreaming() {
        statusTask?.cancel()
        send(.hello(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                    deviceName: UIDevice.current.name), mode: .reliable)
        send(.script(state.scriptText), mode: .reliable)
        var lastScript = state.scriptText
        statusTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let previewOK = self.updateThumbnailTap()
                self.send(.status(RemoteStatus(state: self.state, previewAvailable: previewOK)), mode: .unreliable)
                if self.state.scriptText != lastScript {
                    lastScript = self.state.scriptText
                    self.send(.script(lastScript), mode: .reliable)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Thumbnails only in solo mode (MultiCam has no data output) and below thermal serious.
    private func updateThumbnailTap() -> Bool {
        let allowed = !state.isDualCam && state.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        if allowed {
            engine?.analyzer.setThumbnailSink { [weak self] jpeg in
                Task { @MainActor in self?.send(.preview(jpeg), mode: .unreliable) }
            }
        } else {
            engine?.analyzer.setThumbnailSink(nil)
        }
        return allowed
    }

    /// The ONLY things a remote may do.
    private func execute(_ command: RemoteCommand) {
        guard role == .camera, let engine else { return }
        switch command {
        case .toggleRecording: engine.toggleRecording()
        case .dropMarker(let rating, let note): engine.dropMarker(rating: rating, note: note)
        case .rateTake(let stars): engine.rateTake(stars)
        case .togglePrompter: state.togglePrompter()
        case .resetPrompter: state.resetPrompter()
        case .setPrompterSpeed(let speed): state.setPrompterScrollSpeed(speed)
        case .nextShot: state.completeActiveShotAndAdvance()
        }
    }

    // MARK: Bridge callbacks (main actor)

    fileprivate func peerChanged(_ peer: MCPeerID, connected: Bool) {
        if connected {
            connectedPeerName = peer.displayName
            if role == .camera {
                advertiser?.stopAdvertisingPeer()           // one remote at a time
                state.showBanner("\(peer.displayName) is connected as a remote.", seconds: 4)
                startStreaming()
            }
        } else if connectedPeerName == peer.displayName {
            connectedPeerName = nil
            statusTask?.cancel()
            engine?.analyzer.setThumbnailSink(nil)
            if role == .camera {
                state.showBanner("Remote \(peer.displayName) disconnected.", seconds: 4)
                advertiser?.startAdvertisingPeer()
            }
        }
    }

    fileprivate func received(_ data: Data) {
        guard let message = RemoteMessage.decode(data) else { return }
        switch (role, message) {
        case (.camera, .command(let command)): execute(command)
        case (.remote, .status(let status)): remoteStatus = status
        case (.remote, .preview(let jpeg)): remotePreview = UIImage(data: jpeg)
        case (.remote, .script(let text)): remoteScript = text
        default: break
        }
    }

    fileprivate func invitation(from peer: MCPeerID, handler: @escaping (Bool, MCSession?) -> Void) {
        guard role == .camera, !isConnected, let session else { handler(false, nil); return }
        pendingInvitation = Invitation(peerName: peer.displayName) { [weak self] accept in
            handler(accept, accept ? session : nil)
            self?.pendingInvitation = nil
        }
    }

    func answerInvitation(_ accept: Bool) { pendingInvitation?.respond(accept) }

    fileprivate func found(_ peer: MCPeerID) {
        if !discoveredPeers.contains(peer) { discoveredPeers.append(peer) }
    }

    fileprivate func lost(_ peer: MCPeerID) { discoveredPeers.removeAll { $0 == peer } }

    fileprivate func failed(_ message: String) { lastError = message }
}

// MARK: - Delegate bridge (MultipeerConnectivity calls these on its own queues)

private final class MultipeerBridge: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                                     MCNearbyServiceBrowserDelegate, @unchecked Sendable {
    weak var owner: RemoteProducerLink?
    @MainActor init(owner: RemoteProducerLink) { self.owner = owner }

    private func onMain(_ work: @escaping @Sendable @MainActor (RemoteProducerLink) -> Void) {
        Task { @MainActor [weak self] in if let owner = self?.owner { work(owner) } }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let connected = state == .connected
        guard state != .connecting else { return }
        // Swift 6: MCPeerID is immutable after creation; safe to hand to the main actor.
        nonisolated(unsafe) let peer = peerID
        onMain { $0.peerChanged(peer, connected: connected) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onMain { $0.received(data) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        nonisolated(unsafe) let handler = invitationHandler
        nonisolated(unsafe) let peer = peerID
        onMain { $0.invitation(from: peer, handler: handler) }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let message = error.localizedDescription
        onMain { $0.failed("Couldn't advertise: \(message)") }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["role"] == "camera" else { return }
        nonisolated(unsafe) let peer = peerID
        onMain { $0.found(peer) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        nonisolated(unsafe) let peer = peerID
        onMain { $0.lost(peer) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let message = error.localizedDescription
        onMain { $0.failed("Couldn't search for cameras: \(message)") }
    }
}
