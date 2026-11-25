import Foundation
import Testing
@testable import DuoDirector

@Suite("Guardrail and budget policies")
struct PolicyTests {

    @Test(arguments: [
        (ProcessInfo.ThermalState.nominal, false, false),
        (.fair, false, false),
        (.serious, true, false),
        (.critical, true, true),
    ])
    func thermalActions(level: ProcessInfo.ThermalState, overlays: Bool, critical: Bool) {
        let actions = ThermalPolicy.actions(for: level)
        #expect(actions.pauseOverlays == overlays)
        #expect(actions.pauseAccessory == critical)
        #expect(actions.stepDownFrameRate == critical)
    }

    @Test func effectiveLevelIsTheWorse() {
        #expect(ThermalPolicy.effectiveLevel(thermal: .fair, cameraPressure: .critical) == .critical)
        #expect(ThermalPolicy.effectiveLevel(thermal: .serious, cameraPressure: .nominal) == .serious)
    }

    @Test func frameRateStepDownLadder() {
        #expect(ThermalPolicy.steppedDownFrameRate(from: .fps60) == .fps30)
        #expect(ThermalPolicy.steppedDownFrameRate(from: .fps30) == .fps24)
        #expect(ThermalPolicy.steppedDownFrameRate(from: .fps24) == nil)
    }

    @Test func multiCamStepsDownOnceFrom4K() {
        #expect(DualCamBudget.resolutionStepDown(hardwareCost: 1.2, resolution: .uhd4K) == .hd1080)
        #expect(DualCamBudget.resolutionStepDown(hardwareCost: 1.2, resolution: .hd1080) == nil)
        #expect(DualCamBudget.resolutionStepDown(hardwareCost: 0.9, resolution: .uhd4K) == nil)
        #expect(DualCamBudget.clampedFrameRate(.fps60) == .fps30)
        #expect(DualCamBudget.clampedFrameRate(.fps24) == .fps24)
    }

    @Test func bitrateCountsBothFilesInDual() {
        let solo = RecordingBitrate.totalBitsPerSecond(codec: .hevc, resolution: .uhd4K, frameRate: .fps30, dual: false)
        let dual = RecordingBitrate.totalBitsPerSecond(codec: .hevc, resolution: .uhd4K, frameRate: .fps30, dual: true)
        #expect(solo == 100_000_000 + 256_000)
        #expect(dual - solo == ResolutionPreset.hd1080.baseBitrate)
        let sixty = RecordingBitrate.totalBitsPerSecond(codec: .hevc, resolution: .uhd4K, frameRate: .fps60, dual: false)
        #expect(sixty == 200_000_000 + 256_000)
    }

    @Test func minutesLeftKeepsReserve() {
        #expect(SystemMonitor.minutesLeft(bytes: 1_000_000_000, totalBitsPerSecond: 100_000_000) == 0)
        // 7.5 GB usable at 100 Mbps = 600 s = 10 min
        #expect(SystemMonitor.minutesLeft(bytes: 8_500_000_000, totalBitsPerSecond: 100_000_000) == 10)
        #expect(SystemMonitor.minutesLeft(bytes: nil, totalBitsPerSecond: 1) == nil)
    }

    @Test func compositeRenderNeedsCoolAndCharging() {
        #expect(CompositeRenderPolicy.verdict(isRecording: false, thermal: .nominal, isCharging: true, batteryLevel: 0.5) == .allowed)
        #expect(!CompositeRenderPolicy.verdict(isRecording: true, thermal: .nominal, isCharging: true, batteryLevel: 0.5).isAllowed)
        #expect(!CompositeRenderPolicy.verdict(isRecording: false, thermal: .serious, isCharging: true, batteryLevel: 0.5).isAllowed)
        #expect(!CompositeRenderPolicy.verdict(isRecording: false, thermal: .fair, isCharging: false, batteryLevel: 0.9).isAllowed)
        // Simulator: unknown battery counts as plugged in.
        #expect(CompositeRenderPolicy.verdict(isRecording: false, thermal: .fair, isCharging: false, batteryLevel: nil) == .allowed)
        #expect(CompositeRenderPolicy.shouldAbort(thermal: .serious))
        #expect(!CompositeRenderPolicy.shouldAbort(thermal: .fair))
    }
}
