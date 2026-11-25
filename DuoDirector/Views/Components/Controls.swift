import SwiftUI

// Shared controls. Each one reads StudioSessionState and either calls a CameraEngine
// intent (lens, format, recording) or writes a value the engine observes (manual camera,
// overlays, gain). The same control on either display stays in sync through Observation.

// MARK: - Recording

struct RecordButton: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var diameter: CGFloat = 72

    var body: some View {
        Button { engine.toggleRecording() } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4)
                RoundedRectangle(cornerRadius: state.isRecording ? 6 : diameter / 2)
                    .fill(.red)
                    .padding(state.isRecording ? diameter * 0.3 : 6)
                if let remaining = state.countdownRemaining {
                    Text("\(remaining)").font(.title.bold()).foregroundStyle(.white)
                }
            }
            .frame(width: diameter, height: diameter)
            .animation(.spring(duration: 0.25), value: state.isRecording)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: state.isRecording)
        .accessibilityLabel(state.countdownRemaining != nil ? "Cancel countdown"
                            : state.isRecording ? "Stop recording" : "Record")
        .disabled(state.status == .configuring || state.status == .saving)
    }
}

/// Cycles 0 → 3 → 5 seconds.
struct CountdownPicker: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        Menu {
            Picker("Countdown", selection: $state.countdownSeconds) {
                ForEach(StudioSessionState.countdownOptions, id: \.self) { s in
                    Text(s == 0 ? "Off" : "\(s) seconds").tag(s)
                }
            }
        } label: {
            Label(state.countdownSeconds == 0 ? "Off" : "\(state.countdownSeconds)s", systemImage: "timer")
        }
        .disabled(state.isRecording)
        .accessibilityLabel("Countdown \(state.countdownSeconds) seconds")
    }
}

/// "Mark Take": only enabled while rolling.
struct MarkTakeButton: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var goodTake = false

    var body: some View {
        Button { engine.markTake(goodTake: goodTake) } label: {
            Label(goodTake ? "Good Take" : "Mark Take", systemImage: goodTake ? "star.fill" : "bookmark.fill")
        }
        .disabled(!state.isRecording)
        .sensoryFeedback(.success, trigger: state.chapterMarkers.count)
    }
}

// MARK: - Lens & format

struct LensPicker: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var axis: Axis = .horizontal

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        layout {
            ForEach(LensOption.allCases) { lens in
                Button { engine.selectLens(lens) } label: {
                    VStack(spacing: 0) {
                        Text(lens.label).font(.caption.bold())
                        Text(lens.focalLength).font(.system(size: 8))
                    }
                    .frame(width: 42, height: 42)
                    .background(state.activeLens == lens ? Color.yellow : Color.white.opacity(0.15), in: .circle)
                    .foregroundStyle(state.activeLens == lens ? .black : .white)
                }
                .buttonStyle(.plain)
                // Module swaps (to/from 0.5×) are blocked mid-take; 1× ↔ 2× zooms are not.
                .disabled(state.isRecording && lens.usesMainModule != state.activeLens.usesMainModule)
                .accessibilityLabel(lens.detail)
            }
        }
    }
}

struct FormatControls: View {
    let state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Resolution", selection: Binding(get: { state.resolution }, set: { engine.selectResolution($0) })) {
                ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: Binding(get: { state.frameRate }, set: { engine.selectFrameRate($0) })) {
                ForEach(FrameRatePreset.allCases) { Text("\($0.label) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { state.isDolbyVisionEnabled }, set: { engine.setDolbyVision($0) })) {
                VStack(alignment: .leading) {
                    Text("Dolby Vision HDR")
                    if !state.isDolbyVisionSupported {
                        Text("Not available at \(state.resolution.label) \(state.frameRate.label)fps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!state.isDolbyVisionSupported)
        }
        .disabled(state.isRecording)
    }
}

struct FormatBadge: View {
    let state: StudioSessionState
    var body: some View {
        Text("\(state.resolution.label) · \(state.frameRate.label) · \(state.isDolbyVisionActive ? "DV" : "SDR")")
            .font(.caption.monospaced().bold())
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.15), in: .capsule)
    }
}

// MARK: - Manual exposure / focus / white balance

struct ManualCameraControls: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Auto exposure", isOn: $state.isAutoExposure)
            Group {
                labeledSlider("ISO \(Int(state.isoValue))") {
                    Slider(value: $state.isoValue, in: state.isoRange)
                }
                labeledSlider("Shutter 1/\(Int((1 / state.shutterDuration).rounded()))") {
                    // Log-scaled so the useful 1/48…1/500 range isn't crammed at one end.
                    Slider(value: Binding(
                        get: { log(state.shutterDuration) },
                        set: { state.shutterDuration = exp($0) }),
                           in: log(state.shutterRange.lowerBound)...log(state.shutterRange.upperBound))
                }
                Button("180° shutter (1/\(state.frameRate.rawValue * 2))") {
                    state.shutterDuration = 1.0 / Double(state.frameRate.rawValue * 2)
                }
                .font(.caption)
            }
            .disabled(state.isAutoExposure)

            Divider()
            Toggle("Auto white balance", isOn: $state.isAutoWhiteBalance)
            labeledSlider("\(Int(state.whiteBalanceKelvin))K") {
                Slider(value: $state.whiteBalanceKelvin, in: 2500...10000, step: 50)
            }
            .disabled(state.isAutoWhiteBalance)

            Divider()
            Toggle("Autofocus", isOn: $state.isAutoFocus)
            labeledSlider("Focus \(String(format: "%.2f", state.manualFocusPosition))") {
                HStack {
                    Image(systemName: "flower").font(.caption)
                    Slider(value: $state.manualFocusPosition, in: 0...1)
                    Image(systemName: "mountain.2").font(.caption)
                }
            }
            .disabled(state.isAutoFocus)
        }
    }

    private func labeledSlider<S: View>(_ title: String, @ViewBuilder _ slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.monospacedDigit())
            slider()
        }
    }
}

// MARK: - Teleprompter

struct PrompterSettingsControls: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PrompterTransportPill(state: state)
            VStack(alignment: .leading, spacing: 2) {
                Text("Speed \(Int(state.prompterScrollSpeed)) pt/s").font(.caption)
                Slider(value: Binding(get: { state.prompterScrollSpeed },
                                      set: { state.setPrompterScrollSpeed($0) }), in: 5...200)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Font \(Int(state.prompterFontSize)) pt").font(.caption)
                Slider(value: $state.prompterFontSize, in: StudioSessionState.prompterFontRange, step: 1)
            }
            Toggle("Mirror text (glass rig)", isOn: $state.prompterMirrored)
        }
    }
}

// MARK: - Overlays

struct OverlayToggles: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("16:9 guide (YouTube)", isOn: $state.show16x9Guide)
            Toggle("9:16 guide (Reels/TikTok)", isOn: $state.show9x16Guide)
            Toggle("Focus peaking", isOn: $state.showFocusPeaking)
            Toggle("Zebra stripes", isOn: $state.showZebraStripes)
            VStack(alignment: .leading, spacing: 2) {
                Text("Zebra threshold \(Int(state.zebraThreshold * 100))%").font(.caption)
                Slider(value: $state.zebraThreshold, in: StudioSessionState.zebraRange, step: 0.01)
            }
            .disabled(!state.showZebraStripes)
        }
    }
}

// MARK: - Audio

struct AudioGainControl: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Gain \(Int(state.audioGain * 100))%", systemImage: "mic.fill").font(.caption)
                Spacer()
                Text("\(Int(max(state.leftChannelDB, state.rightChannelDB))) dBFS")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(state.isAudioClipping ? .red : .secondary)
            }
            HStack {
                Slider(value: $state.audioGain, in: 0...1)
                StereoAudioMeter(state: state, axis: .horizontal, thickness: 6, showsLabels: false)
                    .frame(width: 90)
            }
        }
    }
}
