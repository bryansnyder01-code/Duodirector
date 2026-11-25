import SwiftUI

/// Content for the 5.4" outer cover display, registered as a `CameraCaptureAccessory`
/// (iOS 27.1) from `CaptureRootView` via `duoCaptureAccessory(...)` (see
/// Platform/DuoPlatformAPIs.swift).
///
/// Scenario: the phone is open, the rear 48MP cameras point at the creator, and the cover
/// display faces the same way, so it's a field monitor + teleprompter they can see and
/// touch while filming themselves.
///
/// Phase 2 layout, top to bottom:
///   1. Teleprompter HUD: translucent dark band at the TOP edge (nearest the rear camera
///      housing, so the creator's eyeline stays close to the lens). TimelineView-driven
///      scrolling, font size −/+, Play/Pause/Reset pill.
///   2. Live mirrored preview (full-bleed, behind everything) with the peaking/zebra Metal
///      overlay and 16:9 / 9:16 safe-zone guides.
///   3. Stereo dB peak bars with a red CLIP lamp on the leading edge.
///   4. Bottom bar: countdown selector (Off/3s/5s), Record/Stop, and Mark Take (while
///      rolling) or Prompter play/pause (while idle).
///
/// Rules from Apple's accessory guidance that this view follows:
///   • Nothing here is essential. The system can withdraw the accessory at any time, so
///     every action also exists on the inner display.
///   • `state` / `engine` are passed explicitly; the accessory lives in a separate system
///     scene, so we don't rely on environment propagation.
///
/// Phase 4:
///   • Dual-Cam Podcast: the cover display faces the same way as the rear camera, so it's
///     the GUEST's monitor. It keeps the rear (Guest) preview full-bleed and adds a
///     "DUAL · HOST REC" badge so the guest knows the other angle is rolling.
///   • Thermal: at .serious the engine pauses peaking/zebras (the pill says so here too).
///     At .critical CaptureRootView sets the accessory's `isEnabled` to false, so this
///     view goes away entirely and the inner display's fallback strip takes over.
///   • A compact system banner sits under the status row (accessory scenes don't get
///     CaptureRootView's overlay).
///   • Drop Marker replaces Mark Take (same marker, now with a default 3★ rating).
struct OuterMonitorAccessoryView: View {
    let state: StudioSessionState
    let engine: CameraEngine
    /// Phase 3: true when the device is CLOSED and this is the app's main UI on the cover
    /// display (operator behind the phone), so the preview is not mirrored.
    var isPrimaryDisplay = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                // 2. Mirrored preview; the analysis overlay is inside PreviewSurface so it
                //    mirrors and crops with the picture.
                PreviewSurface(state: state, engine: engine, role: .rear,
                               mirrored: !isPrimaryDisplay && state.mirrorOuterPreview)
                    .ignoresSafeArea()

                FramingGuidesOverlay(show16x9: state.show16x9Guide, show9x16: state.show9x16Guide,
                                     showThirds: state.showThirdsGrid, opacity: state.gridOpacity)

                VStack(spacing: 0) {
                    // 1. Lens-adjacent teleprompter HUD (~32% of the height).
                    TeleprompterHUD(state: state)
                        .frame(height: proxy.size.height * 0.32)

                    statusRow
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    phase4Status
                        .padding(.horizontal, 12)
                        .padding(.top, 6)

                    Spacer(minLength: 0)

                    // 3. Stereo meter, large enough to read at arm's length.
                    HStack(alignment: .bottom) {
                        StereoAudioMeter(state: state, thickness: 12)
                            .frame(height: proxy.size.height * 0.24)
                            .padding(8)
                            .background(.black.opacity(0.45), in: .rect(cornerRadius: 10))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                    // 4. Controls.
                    controlBar
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }

                CountdownOverlay(remaining: state.countdownRemaining)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("coverMonitor")
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            RecordingTimecode(state: state)
            Spacer()
            OverlayBadges(state: state)
            Text(state.activeLens.label)
                .font(.caption.bold())
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.6), in: .circle)
        }
    }

    /// Dual badge, thermal pill and (compact) banner.
    private var phase4Status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if state.isDualCam {
                    Label(isPrimaryDisplay ? "DUAL · HOST CAM COVERED" : "DUAL · HOST \(state.isRecording ? "REC" : "READY")",
                          systemImage: CaptureMode.dualPodcastMultiCam.symbol)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(.black)
                        .background(isPrimaryDisplay ? Color.orange : Color.cyan, in: .capsule)
                        // Closed device: the inner camera faces the inner display, so the host
                        // angle is black until the phone is opened. Say so rather than hide it.
                }
                ThermalPill(state: state)
                LivePill(state: state)
                GuestPill(state: state)
                Spacer(minLength: 0)
            }
            if let message = state.systemStatusBannerMessage {
                Text(message)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
                    .padding(8)
                    .background(.black.opacity(0.7), in: .rect(cornerRadius: 10))
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: state.systemStatusBannerMessage)
        .allowsHitTesting(false)
    }

    private var controlBar: some View {
        HStack(spacing: 18) {
            // Countdown: tap cycles Off → 3s → 5s (disabled while rolling).
            BigIconButton(systemImage: "timer",
                          label: state.countdownSeconds == 0 ? "Off" : "\(state.countdownSeconds)s") {
                let options = StudioSessionState.countdownOptions
                let index = options.firstIndex(of: state.countdownSeconds) ?? 0
                state.countdownSeconds = options[(index + 1) % options.count]
            }
            .disabled(state.isRecording || state.countdownRemaining != nil)

            // Record / Stop. With a countdown set, the first tap starts the countdown and
            // CameraEngine.startRecording() fires when it reaches zero; tapping again
            // during the countdown cancels it.
            RecordButton(state: state, engine: engine, diameter: 78)

            if state.isRecording {
                BigIconButton(systemImage: "mappin.and.ellipse",
                              label: "Marker \(state.markers(forTake: state.takeNumber).count + 1)",
                              tint: state.isDualCam ? .cyan : .yellow) {
                    engine.dropMarker()
                }
                .sensoryFeedback(.success, trigger: state.chapterMarkers.count)
            } else {
                BigIconButton(systemImage: state.isPrompterPlaying ? "pause.fill" : "play.fill",
                              label: "Prompter") {
                    state.togglePrompter()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.12)))
    }
}

/// Translucent teleprompter band for the cover display.
private struct TeleprompterHUD: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        ZStack(alignment: .bottom) {
            TeleprompterText(state: state)
                .padding(.bottom, 40)

            // Read-line marker so the creator knows which line is "now".
            Rectangle().fill(.yellow.opacity(0.6)).frame(height: 1.5)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 24)
                .offset(y: -20)
                .allowsHitTesting(false)

            HStack(spacing: 10) {
                PrompterTransportPill(state: state)
                Spacer()
                fontStepper
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.82), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        )
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
    }

    private var fontStepper: some View {
        HStack(spacing: 0) {
            Button { state.prompterFontSize = max(StudioSessionState.prompterFontRange.lowerBound, state.prompterFontSize - 2) } label: {
                Image(systemName: "textformat.size.smaller").frame(width: 38, height: 32)
            }
            .accessibilityLabel("Smaller text")
            Text("\(Int(state.prompterFontSize))").font(.caption.monospacedDigit()).frame(width: 24)
            Button { state.prompterFontSize = min(StudioSessionState.prompterFontRange.upperBound, state.prompterFontSize + 2) } label: {
                Image(systemName: "textformat.size.larger").frame(width: 38, height: 32)
            }
            .accessibilityLabel("Larger text")
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.14), in: .capsule)
    }
}

private struct BigIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title2)
                Text(label).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(tint)
            .frame(width: 70, height: 58)
        }
        .buttonStyle(.plain)
    }
}

/// Simulator stand-in for the cover display. The Simulator has no camera, so the system
/// never presents the real accessory. This renders the same view at the size reported for
/// the iPhone Duo simulator's accessory scene (466 × 678 pt), inside a full-screen cover.
struct OuterMonitorSimulatorPreview: View {
    let state: StudioSessionState
    let engine: CameraEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            OuterMonitorAccessoryView(state: state, engine: engine)
                .frame(width: 466, height: 678)
                .clipShape(.rect(cornerRadius: 36))
                .overlay(RoundedRectangle(cornerRadius: 36).stroke(.gray, lineWidth: 6))
                .scaleEffect(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.08))
                .navigationTitle("Cover display (simulated)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

#Preview("Outer monitor – Dual-Cam (mock)") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    state.simulateMultiCamSupport = true
    let engine = CameraEngine(state: state)
    return OuterMonitorAccessoryView(state: state, engine: engine)
        .frame(width: 466, height: 678)
        .task { await engine.start(); engine.setCaptureMode(.dualPodcastMultiCam) }
}

#Preview("Outer monitor") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    state.showZebraStripes = true
    let engine = CameraEngine(state: state)
    return OuterMonitorAccessoryView(state: state, engine: engine)
        .frame(width: 466, height: 678)
        .task { await engine.start() }
}
