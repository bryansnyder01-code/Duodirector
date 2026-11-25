import SwiftUI

// =====================================================================================
//  Phase 4 shared controls: capture-mode toggle, thermal pill, status banner,
//  Rate Take / Drop Marker, dual export settings.
//  Used by the inner rail, the tabletop deck, the cover monitor and the settings sheet,
//  so every surface shows the same thing.
// =====================================================================================

extension Notification.Name {
    /// Any surface (rail overflow, cover monitor) can ask CaptureRootView to open the
    /// Launch & Diagnostics sheet without threading a binding through every view.
    /// Phase 8: opens the Go Live sheet from anywhere (the rail's overflow menu).
    static let duoShowGoLive = Notification.Name("duoShowGoLive")
    /// Phase 9: opens the Remote guest sheet.
    static let duoShowGuests = Notification.Name("duoShowGuests")
    static let duoShowDiagnostics = Notification.Name("DuoDirector.showDiagnostics")
}

// MARK: - Solo ↔ Dual toggle

/// One-tap Solo Rear 4K ↔ Dual-Cam Podcast.
///
/// When MultiCam isn't supported (older devices, the Simulator without "Simulate
/// MultiCam", or a device that refuses the rear + inner pair) the button stays tappable but
/// dimmed. A tap explains why in a popover instead of silently doing nothing; a disabled
/// SwiftUI button wouldn't receive the tap at all. `.help` adds the same text as a
/// pointer/Pencil-hover tooltip.
struct CaptureModeToggle: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var compact = false
    @State private var showUnsupportedTip = false

    private var unsupportedReason: String {
        state.sourceMode == .mock
            ? "Dual-Cam needs AVCaptureMultiCamSession. Turn on Simulate MultiCam or Demo Mode in Launch & Diagnostics."
            : "This device doesn't support recording the rear and inner cameras at the same time."
    }

    var body: some View {
        let dual = state.isDualCam
        let supported = state.isMultiCamSupported
        Button {
            guard supported else { showUnsupportedTip = true; return }
            engine.setCaptureMode(dual ? .singleRearPro : .dualPodcastMultiCam)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: dual ? CaptureMode.dualPodcastMultiCam.symbol : CaptureMode.singleRearPro.symbol)
                    .font(.body.weight(.semibold))
                if !compact {
                    // Narrow rails (inner display in portrait) drop the words rather than
                    // wrap them one letter per line.
                    ViewThatFits(in: .horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(dual ? "DUAL-CAM" : "SOLO 4K").font(.caption.bold())
                            Text(dual ? "Host + Guest" : "Rear Pro").font(.system(size: 9)).opacity(0.75)
                        }
                        .fixedSize()
                        Text(dual ? "DUAL" : "SOLO").font(.caption2.bold()).fixedSize()
                        Color.clear.frame(width: 0)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: 44)
            .foregroundStyle(dual ? .black : .white)
            .background(dual ? Color.cyan : Color.white.opacity(0.1), in: .rect(cornerRadius: 10))
            .opacity(supported ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(state.isRecording)      // never swap sessions mid-take
        .sensoryFeedback(.selection, trigger: dual)
        .help(supported ? "Switch to \(dual ? CaptureMode.singleRearPro.label : CaptureMode.dualPodcastMultiCam.label)" : unsupportedReason)
        .accessibilityLabel("Capture mode: \(state.captureMode.label)")
        .accessibilityHint(supported ? "Double-tap to switch" : unsupportedReason)
        .popover(isPresented: $showUnsupportedTip, arrowEdge: .leading) {
            Label(unsupportedReason, systemImage: "info.circle")
                .font(.callout)
                .padding()
                .frame(width: 280)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Thermal pill

/// Shows only when a guardrail is doing something, so a normal session has no clutter.
struct ThermalPill: View {
    let state: StudioSessionState

    private var isVisible: Bool {
        state.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            || state.overlaysSuspendedForThermal || state.accessorySuspendedForThermal
            || state.thermalSteppedDownFrom != nil
    }

    private var text: String {
        var parts = ["Device \(state.thermalState.label.lowercased())"]
        if state.overlaysSuspendedForThermal { parts.append("overlays paused") }
        if let from = state.thermalSteppedDownFrom { parts.append("\(from.label)→\(state.frameRate.label) fps") }
        if state.accessorySuspendedForThermal { parts.append("cover paused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if isVisible {
            let critical = state.thermalState == .critical
            Label(text, systemImage: critical ? "thermometer.high" : "thermometer.medium")
                .font(.caption2.bold())
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .foregroundStyle(.black)
                .background(critical ? Color.red : Color.orange, in: .capsule)
                .accessibilityLabel("Thermal warning: \(text)")
                .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - Banner

/// `state.systemStatusBannerMessage` (accessory withdrawn, thermal step-downs, low
/// storage, unsupported mode…). Tap to dismiss; most banners also auto-clear.
struct SystemStatusBanner: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        ZStack {
            if let message = state.systemStatusBannerMessage {
                Button { state.systemStatusBannerMessage = nil } label: {
                    Label(message, systemImage: "exclamationmark.bubble.fill")
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.regularMaterial, in: .capsule)
                        .shadow(radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityHint("Double-tap to dismiss")
            }
        }
        .animation(.snappy, value: state.systemStatusBannerMessage)
    }
}

// MARK: - Rate Take / Drop Marker

/// Five stars for the rolling take (or the last finished one). Writes to TakeRecord.rating,
/// which becomes the FCPXML keyword and the JSON sidecar rating.
struct RateTakeStars: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var starSize: CGFloat = 30

    var body: some View {
        let rating = state.currentTakeRating
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button { engine.rateTake(star == rating ? 0 : star) } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: starSize * 0.6, weight: .semibold))
                        .foregroundStyle(star <= rating ? .yellow : .white.opacity(0.6))
                        .frame(width: starSize + 8, height: starSize + 8)   // ≥ 38pt targets
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
            }
        }
        .disabled(state.takes.isEmpty)
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rate take, currently \(rating) of 5")
    }
}

/// Drops a rated marker at the current timecode. Long-press picks a 5★ "Good take" marker.
struct DropMarkerButton: View {
    let state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        Button { engine.dropMarker() } label: {
            Label("Drop Marker", systemImage: "mappin.and.ellipse")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .foregroundStyle(.black)
        .disabled(!state.isRecording)
        .contextMenu {
            ForEach((1...5).reversed(), id: \.self) { stars in
                Button(String(repeating: "★", count: stars)) {
                    engine.dropMarker(rating: stars, note: stars == 5 ? "Good take" : nil)
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: state.chapterMarkers.count)
    }
}

// MARK: - Settings section

/// Capture mode + dual export settings for the Camera settings sheet and diagnostics.
struct CaptureModeSettings: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        Picker("Capture mode", selection: Binding(get: { state.captureMode }, set: { engine.setCaptureMode($0) })) {
            ForEach(CaptureMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(state.isRecording)

        if !state.isMultiCamSupported {
            Text("Dual-Cam is unavailable: this device doesn't report AVCaptureMultiCamSession support.")
                .font(.footnote).foregroundStyle(.secondary)
        }

        if state.isDualCam {
            DualExportStylePicker(state: state, engine: engine)
            if state.dualExportStyle == .pictureInPicture || state.dualExportStyle == .separateSyncedTracks {
                Picker("Host preview corner", selection: $state.pipCorner) {
                    Text("Top left").tag(PiPCorner.topLeading)
                    Text("Top right").tag(PiPCorner.topTrailing)
                    Text("Bottom left").tag(PiPCorner.bottomLeading)
                    Text("Bottom right").tag(PiPCorner.bottomTrailing)
                }
            }
            Text("Dual-Cam records two synced .mov files (max \(CameraEngine.multiCamMaxFrameRate.label) fps, Fusion Main 1×/2×) plus a JSON and FCPXML sidecar.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct DualExportStylePicker: View {
    let state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        Picker("Dual export", selection: Binding(get: { state.dualExportStyle }, set: { engine.setDualExportStyle($0) })) {
            ForEach(DualExportStyle.allCases) { Text($0.label).tag($0) }
        }
    }
}
