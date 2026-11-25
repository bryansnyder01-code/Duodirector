import PencilKit
import SwiftUI

// =====================================================================================
//  LaunchDiagnosticsView (Phase 4): "Launch & Diagnostics" sheet
//
//  Opened from ToolbarOverflowMenu (CaptureRootView) or the rail's "More" menu.
//  Three jobs:
//
//   1. LIVE TELEMETRY: active cameras, MultiCam hardware/system-pressure cost, device
//      thermal state + camera system pressure, battery, free storage and recording
//      minutes left at the current bitrate, cover accessory state, hinge. All of it is
//      @Observable state fed by CameraEngine + SystemMonitor, so rows update live.
//
//   2. GUARDRAIL TESTING: force a thermal state (nominal → critical) to watch the
//      engine pause peaking/zebras, step the frame rate down and withdraw the cover
//      accessory, without actually heating the phone. In the Simulator, "Simulate
//      MultiCam" unlocks the Dual-Cam toggle.
//
//   3. DEMO MODE / APP STORE PREVIEW PRESET: one switch loads a podcast script, a shot
//      list with Pencil-style storyboard sketches, rated takes and markers, alternating
//      Host/Guest audio, and dual-cam previews (synthetic in the Simulator). Then the
//      posture buttons jump straight to each screenshot set:
//        • 5.4" cover display  (accessory preview at 466 × 678 pt)
//        • 7.6" inner, flat    (overlay arrangement + rail)
//        • Tabletop L-mode     (Host | Guest above the fold, producer deck below)
//      The "SIMULATED" captions on mock feeds are hidden while Demo Mode is on.
// =====================================================================================

struct LaunchDiagnosticsView: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine
    /// Closes this sheet and opens the 5.4" cover-display preview (owned by CaptureRootView).
    var previewCoverDisplay: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    /// Mirrors the engine's private override so the picker shows the current choice.
    @State private var simulatedThermal: ProcessInfo.ThermalState?
    /// Screenshot runs open the sheet full height, so the shot shows every section
    /// instead of one row under the half-height glass.
    @State private var detent: PresentationDetent = LaunchOptions.current.scene == .diagnostics ? .large : .medium

    var body: some View {
        NavigationStack {
            Form {
                telemetrySection
                guardrailSection
                phase5Section
                simulateSection
                demoSection
                lastTakeSection
                capabilitiesSection
                // Phase 10: version, privacy policy, open-source licenses.
                Section { NavigationLink("About & acknowledgements") { AboutView() } }
            }
            .task { state.markerTrackStatus = await engine.markerTrackStatus() }
            .accessibilityIdentifier("diagnostics")
            .navigationTitle("Launch & Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    // MARK: 1. Telemetry

    private var telemetrySection: some View {
        Section {
            LabeledContent("Capture mode") {
                Label(state.captureMode.label, systemImage: state.captureMode.symbol)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Active cameras")
                ForEach(engine.activeCameraNames, id: \.self) { name in
                    Label(name, systemImage: "camera.fill").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if state.isDualCam {
                costGauge("MultiCam hardware cost", state.multiCamHardwareCost)
                costGauge("MultiCam system pressure cost", state.multiCamSystemPressureCost)
            }
            LabeledContent("Format", value: "\(state.resolution.label) · \(state.frameRate.label) fps · \(state.preferredCodec.label)\(state.isDolbyVisionActive ? " · Dolby Vision" : "")")
            LabeledContent("Thermal state") {
                Text(state.thermalState.label + (simulatedThermal != nil ? " (simulated)" : ""))
                    .foregroundStyle(thermalColor(state.thermalState))
            }
            LabeledContent("Camera system pressure", value: state.cameraPressureLevel.capitalized)
            LabeledContent("Battery") {
                if let level = state.batteryLevel {
                    Label("\(Int(level * 100))%\(state.isCharging ? " · charging" : "")",
                          systemImage: state.isCharging ? "battery.100.bolt" : batterySymbol(level))
                        .foregroundStyle(level < 0.2 && !state.isCharging ? .red : .primary)
                } else {
                    Text("Unknown (Simulator)").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Free storage") {
                if let bytes = state.availableStorageBytes {
                    VStack(alignment: .trailing) {
                        Text(bytes.formatted(.byteCount(style: .file)))
                        if let minutes = state.estimatedRecordingMinutesLeft {
                            Text("≈ \(minutes) min at current settings\(state.isDualCam ? " (both cameras)" : "")")
                                .font(.caption).foregroundStyle(minutes < 10 ? .red : .secondary)
                        }
                    }
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Cover display accessory", value: accessoryStatus)
            LabeledContent("Hinge", value: state.hingePosture.label
                           + (state.hingeAngleDegrees.map { " · \(Int($0))°" } ?? "")
                           + (state.simulatedHingePosture != nil ? " (simulated)" : ""))
            LabeledContent("Source", value: state.sourceMode == .live ? "Live cameras" : "Mock (synthetic frames)")
        } header: {
            Text("Live telemetry")
        } footer: {
            Text("Storage minutes keep 1 GB in reserve so iOS never has to purge mid-take.")
        }
    }

    private var accessoryStatus: String {
        if state.accessorySuspendedForThermal { return "Paused by thermal guard" }
        if !state.isOuterMonitorEnabled { return "Off" }
        if state.isOuterAccessoryActive { return "Live" }
        if state.wasOuterAccessoryWithdrawn { return "Withdrawn by iOS" }
        return state.sourceMode == .mock ? "Not presented (Simulator)" : "Waiting for system"
    }

    private func costGauge(_ title: String, _ value: Float) -> some View {
        // Apple: a MultiCam configuration must stay at or below 1.0 for both costs.
        Gauge(value: Double(min(value, 1.5)), in: 0...1.5) {
            Text(title)
        } currentValueLabel: {
            Text(value, format: .number.precision(.fractionLength(2)))
        }
        .tint(value > 1 ? .red : value > 0.8 ? .orange : .green)
    }

    // MARK: 2. Guardrails

    private var guardrailSection: some View {
        Section {
            guardrailRow("Peaking & zebras", active: state.overlaysSuspendedForThermal, onText: "Paused (serious)")
            guardrailRow("Frame rate",
                         active: state.thermalSteppedDownFrom != nil,
                         onText: state.thermalSteppedDownFrom.map { "\($0.label) → \(state.frameRate.label) fps (critical)" } ?? "")
            guardrailRow("Cover accessory", active: state.accessorySuspendedForThermal, onText: "isEnabled = false (critical)")
        } header: {
            Text("Thermal guardrails")
        } footer: {
            Text("Serious: overlays pause. Critical: frame rate steps down (after the take ends, so a rolling take isn't cut) and the cover monitor pauses. Everything restores when the device cools to fair.")
        }
    }

    private func guardrailRow(_ title: String, active: Bool, onText: String) -> some View {
        LabeledContent(title) {
            Text(active ? onText : "Normal").foregroundStyle(active ? .orange : .secondary)
        }
    }

    // MARK: Phase 5: persistence, markers, composites

    private var phase5Section: some View {
        Section {
            LabeledContent("Project saved") {
                if let saved = state.lastPersistedAt {
                    Text(saved, format: .relative(presentation: .named))
                } else {
                    Text(state.isDemoMode ? "Paused in Demo Mode" : "Not yet").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Markers written to", value: state.markerTrackStatus + " + QuickTime chapters")
            // Phase 6: iCloud Drive sync (device-local choices).
            if let cloud = engine.cloudSync {
                Toggle("Sync project with iCloud Drive", isOn: Binding(get: { cloud.isEnabled }, set: { cloud.setEnabled($0) }))
                if cloud.isEnabled {
                    Toggle("Also sync video files", isOn: Binding(get: { cloud.syncsTakeFiles }, set: { cloud.setSyncsTakeFiles($0) }))
                    LabeledContent("iCloud", value: cloud.status.label)
                }
            }
            // Phase 6: Remote Producer.
            if let link = engine.remoteLink {
                LabeledContent("Remote producer", value: link.connectedPeerName.map { "Connected: \($0)" }
                               ?? (link.role == .camera ? "Waiting for a remote" : "Off"))
            }
            // Phase 8: Go Live.
            if let live = engine.liveStream {
                LabeledContent("Live stream", value: live.selectedDestination.map { "\($0.name) · \(state.isLive ? "LIVE" : "off air")" } ?? "No destination")
                LabeledContent("Guest room", value: "\(GuestRoomFactory.isLiveKitLinked ? "LiveKit" : "Mock only") · " + (state.guestState.guestName ?? (state.guestState.isInRoom ? "waiting" : "closed")))
                LabeledContent("Stream transport", value: (engine.isMock || state.isDemoMode) ? "Mock (nothing is sent)" : LiveTransportFactory.realTransportName)
            }
            Toggle("Auto-render Dual-Cam composites", isOn: $state.autoRenderComposites)
                .onChange(of: state.autoRenderComposites) { _, on in if on { engine.processRenderQueueIfIdle() } }
            if case .blocked(let reason) = engine.compositeRenderVerdict {
                Text("Rendering waits: \(reason)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Project, iCloud & exports")
        } footer: {
            Text("Composites render only between takes, while the iPhone is cool and charging, and stop if it warms up. Video sync uploads every take's files to iCloud Drive › DuoDirector › Takes, which can use a lot of iCloud storage.")
        }
    }

    // MARK: 2b. Simulate

    private var simulateSection: some View {
        Section("Simulate") {
            Picker("Thermal state", selection: Binding(
                get: { simulatedThermal },
                set: { simulatedThermal = $0; engine.simulateThermalState($0) })) {
                Text("Real sensor").tag(ProcessInfo.ThermalState?.none)
                ForEach([ProcessInfo.ThermalState.nominal, .fair, .serious, .critical], id: \.rawValue) {
                    Text($0.label).tag(ProcessInfo.ThermalState?.some($0))
                }
            }
            if state.sourceMode == .mock {
                Toggle("Simulate MultiCam support", isOn: Binding(
                    get: { state.simulateMultiCamSupport }, set: { engine.setSimulatedMultiCamSupport($0) }))
            }
            Picker("Hinge posture", selection: $state.simulatedHingePosture) {
                Text("Real hinge").tag(HingePosture?.none)
                ForEach(HingePosture.allCases) { Label($0.label, systemImage: $0.symbol).tag(HingePosture?.some($0)) }
            }
            Button("Show sample banner", systemImage: "exclamationmark.bubble") {
                state.showBanner("Cover monitor was withdrawn by iOS. Prompter and controls are on this screen.")
            }
        }
    }

    // MARK: 3. Demo Mode

    private var demoSection: some View {
        Section {
            Toggle(isOn: Binding(get: { state.isDemoMode }, set: { DemoModePreset.setEnabled($0, state: state, engine: engine) })) {
                Label("Demo Mode / App Store Preview", systemImage: "sparkles.tv")
            }
            .disabled(state.isRecording)

            if state.isDemoMode {
                Button("5.4″ cover display", systemImage: "rectangle.portrait") {
                    state.simulatedHingePosture = nil
                    previewCoverDisplay()
                }
                Button("7.6″ inner display, flat", systemImage: "rectangle.split.2x1") {
                    state.simulatedHingePosture = .flat
                    dismiss()
                }
                Button("Tabletop L-mode", systemImage: "laptopcomputer") {
                    state.simulatedHingePosture = .tabletopLShape
                    dismiss()
                }
                if state.sourceMode == .mock {
                    Button(state.isRecording ? "Stop demo take" : "Roll a demo take",
                           systemImage: state.isRecording ? "stop.circle" : "record.circle") {
                        engine.toggleRecording()
                        if state.isRecording == false { dismiss() }
                    }
                }
            }
        } header: {
            Text("Demo Mode")
        } footer: {
            Text("Loads a podcast script, a sketched shot list, rated takes and markers, Host/Guest audio and dual-cam previews. In the Simulator, cameras are synthetic. Turning it off restores your own script and shot list.")
        }
    }

    // MARK: Last take

    @ViewBuilder
    private var lastTakeSection: some View {
        if let take = state.takes.last {
            Section("Last take") {
                LabeledContent("Take \(take.takeNumber)", value: take.shotTitle ?? take.captureMode.label)
                LabeledContent("Duration", value: CameraEngine.timecode(take.duration))
                LabeledContent("Rating", value: take.rating == 0 ? "Unrated"
                               : String(repeating: "★", count: take.rating) + String(repeating: "☆", count: 5 - take.rating))
                LabeledContent("Markers", value: "\(state.markers(forTake: take.takeNumber).count)")
                if take.captureMode == .dualPodcastMultiCam {
                    LabeledContent("Inner sync offset", value: String(format: "%+.3f s", take.innerStartOffset))
                    LabeledContent("Session ID", value: String(take.sessionIdentifier.prefix(8)) + "…")
                }
                let sidecars = [take.sidecarJSONURL, take.sidecarFCPXMLURL].compactMap { $0 }
                if !sidecars.isEmpty {
                    ShareLink(items: sidecars) {
                        Label("Share sidecars (JSON + FCPXML)", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    // MARK: Capabilities

    private var capabilitiesSection: some View {
        Section("Capabilities") {
            capability("MultiCam (rear + inner)", state.isMultiCamSupported)
            capability("Dolby Vision HDR", state.isDolbyVisionSupported)
            capability("Apple ProRes", state.isProResSupported)
            capability("2× optical-quality crop", state.isCropOpticalQuality)
        }
    }

    private func capability(_ title: String, _ supported: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(supported ? .green : .secondary)
        }
    }

    // MARK: Helpers

    private func thermalColor(_ thermal: ProcessInfo.ThermalState) -> Color {
        switch thermal {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .secondary
        }
    }

    private func batterySymbol(_ level: Float) -> String {
        switch level {
        case ..<0.15: "battery.0percent"
        case ..<0.4: "battery.25percent"
        case ..<0.65: "battery.50percent"
        case ..<0.9: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

// MARK: - Demo Mode preset

/// Everything Demo Mode swaps in, plus a snapshot of the user's own content so turning it
/// off is lossless. (The snapshot lives for the app session only, on purpose: Demo Mode
/// isn't persisted, so a relaunch always starts clean.)
@MainActor
enum DemoModePreset {

    private struct Snapshot {
        var script: String
        var shotList: [ShotListItem]
        var activeShotID: ShotListItem.ID?
        var takes: [TakeRecord]
        var markers: [TakeMarker]
        var takeNumber: Int
        var captureMode: CaptureMode
        var exportStyle: DualExportStyle
        var guides: (Bool, Bool, Bool)
    }
    private static var snapshot: Snapshot?

    static func setEnabled(_ enabled: Bool, state: StudioSessionState, engine: CameraEngine) {
        enabled ? apply(state: state, engine: engine) : restore(state: state, engine: engine)
    }

    static func apply(state: StudioSessionState, engine: CameraEngine) {
        guard !state.isDemoMode, !state.isRecording else { return }
        snapshot = Snapshot(script: state.scriptText, shotList: state.shotList, activeShotID: state.activeShotID,
                            takes: state.takes, markers: state.chapterMarkers, takeNumber: state.takeNumber,
                            captureMode: state.captureMode, exportStyle: state.dualExportStyle,
                            guides: (state.show16x9Guide, state.showThirdsGrid, state.showHistogram))

        // Turning on Demo Mode lets the mock engine report MultiCam, then switches to dual.
        engine.setDemoMode(true)

        state.scriptText = podcastScript
        state.resetPrompter()
        state.shotList = shotList
        state.activeShotID = state.shotList[1].id
        state.shotList[0].isCompleted = true

        // Three earlier takes with ratings + markers so the Takes pane and HUD look lived-in.
        let now = Date()
        state.takes = (1...3).map { n in
            TakeRecord(takeNumber: n, sessionIdentifier: UUID().uuidString,
                       startedAt: now.addingTimeInterval(Double(-900 + n * 240)),
                       duration: [182.0, 214.0, 397.0][n - 1], rating: [2, 4, 5][n - 1],
                       captureMode: .dualPodcastMultiCam, exportStyle: .pictureInPicture,
                       innerStartOffset: 0.017, shotTitle: shotList[min(n - 1, 1)].title)
        }
        state.chapterMarkers = [
            TakeMarker(takeNumber: 2, timestamp: 48, rating: 4, note: "Great laugh, use as cold open"),
            TakeMarker(takeNumber: 3, timestamp: 63, rating: 5, note: "Good take"),
            TakeMarker(takeNumber: 3, timestamp: 211, rating: 3, note: "Guest story about the first prototype"),
        ]
        state.takeNumber = 4

        state.show16x9Guide = true
        state.showThirdsGrid = true
        state.showHistogram = false
        state.dualExportStyle = .pictureInPicture
        if state.isMultiCamSupported { engine.setCaptureMode(.dualPodcastMultiCam) }
        state.setPrompterPlaying(true)
        state.showBanner("Demo Mode on: sample podcast loaded.", seconds: 3)
    }

    static func restore(state: StudioSessionState, engine: CameraEngine) {
        guard state.isDemoMode, !state.isRecording else { return }
        if let s = snapshot {
            state.scriptText = s.script
            state.shotList = s.shotList
            state.activeShotID = s.activeShotID
            state.takes = s.takes
            state.chapterMarkers = s.markers
            state.takeNumber = s.takeNumber
            state.dualExportStyle = s.exportStyle
            (state.show16x9Guide, state.showThirdsGrid, state.showHistogram) = s.guides
            if s.captureMode != state.captureMode { engine.setCaptureMode(s.captureMode) }
        }
        snapshot = nil
        state.setPrompterPlaying(false)
        state.resetPrompter()
        engine.setDemoMode(false)     // drops simulated MultiCam (and dual) if not otherwise allowed
    }

    // MARK: Content

    static let podcastScript = """
    Welcome back to Fold Forward, the show about making things on the go.
    I'm your host, and today we're recording on a single phone: one camera on me, one on our guest.
    Our guest built a hardware startup from a garage to three continents.
    So let's start at the beginning. What was the very first prototype?
    And what did you get wrong that you'd tell every founder to get right?
    We'll be right back after this. Stay with us.
    """

    static var shotList: [ShotListItem] {
        [
            ShotListItem(title: "Cold open: two-shot", cameraLens: .main26,
                         framingNote: "Host PiP bottom-right, guest centered", sketchData: sketch(.twoShot)),
            ShotListItem(title: "Guest close-up", cameraLens: .crop52,
                         framingNote: "2× on guest, eyes on the upper third", sketchData: sketch(.closeUp)),
            ShotListItem(title: "Prototype on the table", cameraLens: .main26,
                         framingNote: "Tabletop, product in the lower third", sketchData: sketch(.insert)),
            ShotListItem(title: "Outro: split-screen", cameraLens: .main26,
                         framingNote: "Side by side, both wave", sketchData: sketch(.split)),
        ]
    }

    // MARK: Programmatic storyboard sketches
    //
    // Built from PKStroke / PKStrokePath / PKStrokePoint (PencilKit, iOS 14+), so they're
    // real, editable PencilKit drawings in the Storyboard pane, not images.

    enum Sketch { case twoShot, closeUp, insert, split }

    static func sketch(_ kind: Sketch) -> Data {
        let frame = CGRect(x: 20, y: 20, width: 560, height: 315)    // 16:9 storyboard frame
        var strokes = [rect(frame, color: .white, width: 4)]
        switch kind {
        case .twoShot:
            strokes += person(center: CGPoint(x: 300, y: 190), scale: 1.0, color: .systemYellow)
            strokes.append(rect(CGRect(x: 430, y: 220, width: 120, height: 95), color: .systemCyan, width: 3))
            strokes += person(center: CGPoint(x: 490, y: 268), scale: 0.4, color: .systemCyan)
        case .closeUp:
            strokes += person(center: CGPoint(x: 300, y: 240), scale: 2.0, color: .systemYellow)
            strokes.append(line([CGPoint(x: 20, y: 125), CGPoint(x: 580, y: 125)], color: .systemGray, width: 1.5))
        case .insert:
            strokes.append(rect(CGRect(x: 200, y: 220, width: 200, height: 70), color: .systemOrange, width: 4))
            strokes.append(line([CGPoint(x: 120, y: 290), CGPoint(x: 480, y: 290)], color: .systemGray, width: 2))
            strokes.append(line([CGPoint(x: 300, y: 80), CGPoint(x: 300, y: 200), CGPoint(x: 285, y: 185),
                                 CGPoint(x: 300, y: 200), CGPoint(x: 315, y: 185)], color: .systemRed, width: 3))
        case .split:
            strokes.append(line([CGPoint(x: 300, y: 20), CGPoint(x: 300, y: 335)], color: .white, width: 3))
            strokes += person(center: CGPoint(x: 160, y: 200), scale: 0.9, color: .systemYellow)
            strokes += person(center: CGPoint(x: 440, y: 200), scale: 0.9, color: .systemCyan)
        }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }

    private static func person(center: CGPoint, scale: CGFloat, color: UIColor) -> [PKStroke] {
        let head = circle(center: CGPoint(x: center.x, y: center.y - 50 * scale), radius: 28 * scale, color: color)
        let shoulders = line((0...16).map { i in
            let t = CGFloat(i) / 16 * .pi
            return CGPoint(x: center.x - cos(t) * 70 * scale, y: center.y + 40 * scale - sin(t) * 40 * scale)
        }, color: color, width: 4)
        return [head, shoulders]
    }

    private static func circle(center: CGPoint, radius: CGFloat, color: UIColor) -> PKStroke {
        line((0...36).map { i in
            let a = CGFloat(i) / 36 * 2 * .pi
            return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
        }, color: color, width: 4)
    }

    private static func rect(_ r: CGRect, color: UIColor, width: CGFloat) -> PKStroke {
        line([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
              CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)], color: color, width: width)
    }

    /// Densifies the polyline (PencilKit renders the path as a spline through its points,
    /// so sparse corners would round off) and builds one pen stroke.
    private static func line(_ points: [CGPoint], color: UIColor, width: CGFloat) -> PKStroke {
        var dense: [CGPoint] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 6))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = points.last { dense.append(last) }
        let strokePoints = dense.enumerated().map { index, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(index) * 0.008,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color),
                        path: PKStrokePath(controlPoints: strokePoints, creationDate: Date()))
    }
}

#Preview("Launch & Diagnostics (mock)") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    let engine = CameraEngine(state: state)
    return LaunchDiagnosticsView(state: state, engine: engine)
        .task { await engine.start() }
}
