import AVFoundation
import Observation
import UIKit

// =====================================================================================
//  AudioRouteController (Phase 11): microphone picker, mic mode, headphone check
//
//  DuoDirector owns the AVAudioSession (CaptureSessionController turns the capture
//  session's automatic audio configuration off), so the capture mic follows the
//  session's preferred input: picking a wired, USB-C or Bluetooth mic here
//  is all it takes. Voice Isolation / Wide Spectrum are system mic modes: apps can read
//  them and open the system picker, not set them.
// =====================================================================================

struct AudioInputOption: Identifiable, Equatable, Sendable {
    var id: String          // AVAudioSessionPortDescription.uid
    var name: String
    var kind: Kind

    enum Kind: String, Sendable {
        case builtIn, wired, usb, bluetooth, other
        var symbol: String {
            switch self {
            case .builtIn: "iphone"
            case .wired: "headphones"
            case .usb: "cable.connector"
            case .bluetooth: "airpods"
            case .other: "mic"
            }
        }
    }
}

enum AudioRoutePolicy {
    static func kind(forPortType raw: String) -> AudioInputOption.Kind {
        switch raw {
        case AVAudioSession.Port.builtInMic.rawValue: .builtIn
        case AVAudioSession.Port.headsetMic.rawValue, AVAudioSession.Port.lineIn.rawValue: .wired
        case AVAudioSession.Port.usbAudio.rawValue: .usb
        case AVAudioSession.Port.bluetoothHFP.rawValue, AVAudioSession.Port.bluetoothLE.rawValue: .bluetooth
        default: .other
        }
    }

    /// Outputs you can monitor on without the guest/prompter echoing into the mic.
    static func isPrivateListening(outputPortTypes: [String]) -> Bool {
        let privatePorts: Set<String> = [
            AVAudioSession.Port.headphones.rawValue, AVAudioSession.Port.bluetoothA2DP.rawValue,
            AVAudioSession.Port.bluetoothHFP.rawValue, AVAudioSession.Port.bluetoothLE.rawValue,
            AVAudioSession.Port.usbAudio.rawValue,
        ]
        return outputPortTypes.contains { privatePorts.contains($0) }
    }

    /// Bluetooth mics record at call quality (16 kHz HFP). Worth a warning in a studio app.
    static func qualityNote(for kind: AudioInputOption.Kind) -> String? {
        kind == .bluetooth
            ? String(localized: "Bluetooth mics record at phone-call quality. Use a wired or USB-C mic for best sound.")
            : nil
    }

    static func micModeLabel(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .voiceIsolation: String(localized: "Voice Isolation")
        case .wideSpectrum: String(localized: "Wide Spectrum")
        default: String(localized: "Standard")
        }
    }
}

@MainActor
@Observable
final class AudioRouteController {
    private(set) var inputs: [AudioInputOption] = []
    private(set) var selectedInputID: String?
    private(set) var headphonesConnected = false
    private(set) var outputName = ""
    private(set) var micMode: AVCaptureDevice.MicrophoneMode = .standard
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func refresh() {
        let session = AVAudioSession.sharedInstance()
        inputs = (session.availableInputs ?? []).map {
            AudioInputOption(id: $0.uid, name: $0.portName, kind: AudioRoutePolicy.kind(forPortType: $0.portType.rawValue))
        }
        selectedInputID = session.preferredInput?.uid ?? session.currentRoute.inputs.first?.uid
        let outputs = session.currentRoute.outputs
        headphonesConnected = AudioRoutePolicy.isPrivateListening(outputPortTypes: outputs.map(\.portType.rawValue))
        outputName = outputs.first?.portName ?? ""
        micMode = AVCaptureDevice.activeMicrophoneMode
    }

    var selectedInput: AudioInputOption? { inputs.first { $0.id == selectedInputID } }

    func select(_ id: String) {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == id }) else { return }
        try? session.setPreferredInput(port)
        refresh()
    }

    /// Opens the system Mic Mode picker (Standard / Voice Isolation / Wide Spectrum).
    func showMicModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
