import Foundation

// =====================================================================================
//  Phase 5: pure decision logic pulled out of CameraEngine so it can be unit-tested
//  without a camera, a session or the main actor. CameraEngine calls these and then
//  performs the side effects (banners, reconfigure, accessory isEnabled).
// =====================================================================================

/// Thermal guardrail decisions (Phase 4 behaviour, unchanged).
enum ThermalPolicy {

    struct Actions: Equatable, Sendable {
        /// Serious or worse: pause peaking / zebras / histogram (GPU analysis).
        var pauseOverlays: Bool
        /// Critical: CameraCaptureAccessory(isEnabled: false).
        var pauseAccessory: Bool
        /// Critical: step the frame rate down (deferred while a take is rolling).
        var stepDownFrameRate: Bool
    }

    /// The worse of ProcessInfo's thermal state and the camera's system pressure.
    static func effectiveLevel(thermal: ProcessInfo.ThermalState,
                               cameraPressure: ProcessInfo.ThermalState) -> ProcessInfo.ThermalState {
        thermal.rawValue >= cameraPressure.rawValue ? thermal : cameraPressure
    }

    static func actions(for level: ProcessInfo.ThermalState) -> Actions {
        let serious = level.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let critical = level.rawValue >= ProcessInfo.ThermalState.critical.rawValue
        return Actions(pauseOverlays: serious, pauseAccessory: critical, stepDownFrameRate: critical)
    }

    /// 60 → 30, 30 → 24, 24 → nil (already at the floor).
    static func steppedDownFrameRate(from fps: FrameRatePreset) -> FrameRatePreset? {
        let target: FrameRatePreset = fps == .fps60 ? .fps30 : .fps24
        return target.rawValue < fps.rawValue ? target : nil
    }
}

/// MultiCam bandwidth rules.
enum DualCamBudget {
    /// Apple: a MultiCam configuration is only valid while hardwareCost ≤ 1.0.
    static let maxHardwareCost: Float = 1.0

    /// One step down is allowed: 4K → 1080p. Returns nil when no step-down applies.
    static func resolutionStepDown(hardwareCost: Float, resolution: ResolutionPreset) -> ResolutionPreset? {
        hardwareCost > maxHardwareCost && resolution == .uhd4K ? .hd1080 : nil
    }

    /// Dual mode caps the frame rate (bandwidth) and keeps the main module (1× / 2×).
    static func clampedFrameRate(_ fps: FrameRatePreset, cap: FrameRatePreset = .fps30) -> FrameRatePreset {
        fps.rawValue > cap.rawValue ? cap : fps
    }
}

/// Storage maths for the minutes-left estimate.
enum RecordingBitrate {
    /// Total bits per second written to disk for the current settings, counting both files
    /// in Dual-Cam. Audio is included as a flat 256 kbps.
    static func totalBitsPerSecond(codec: VideoCodecPreset, resolution: ResolutionPreset,
                                   frameRate: FrameRatePreset, dual: Bool) -> Int {
        let perStream: Int
        if codec == .proRes422HQ {
            perStream = resolution == .uhd4K ? 707_000_000 : 176_000_000   // ProRes 422 HQ @30
        } else {
            perStream = resolution.baseBitrate
        }
        let scaled = perStream * max(frameRate.rawValue, 30) / 30
        let inner = dual ? ResolutionPreset.hd1080.baseBitrate : 0
        return scaled + inner + 256_000
    }
}

/// When an on-device composite (split / PiP) may render. Rendering is a full decode +
/// composite + HEVC encode of both files: exactly the load the thermal guard avoids
/// while shooting. So it only runs between takes, on power, while the phone is cool.
enum CompositeRenderPolicy {

    enum Verdict: Equatable, Sendable {
        case allowed
        case blocked(String)
        var isAllowed: Bool { self == .allowed }
    }

    static func verdict(isRecording: Bool, thermal: ProcessInfo.ThermalState,
                        isCharging: Bool, batteryLevel: Float?) -> Verdict {
        if isRecording { return .blocked("Finish the take first.") }
        if thermal.rawValue > ProcessInfo.ThermalState.fair.rawValue {
            return .blocked("iPhone is \(thermal.label.lowercased()). Let it cool down first.")
        }
        // Simulator reports no battery (nil): treat as plugged in.
        if batteryLevel != nil && !isCharging { return .blocked("Plug in to render. Rendering is heavy on the battery.") }
        return .allowed
    }

    /// Mid-render: abort as soon as the phone reaches serious.
    static func shouldAbort(thermal: ProcessInfo.ThermalState) -> Bool {
        thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}
