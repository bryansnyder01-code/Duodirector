import SwiftUI

/// The main capture view. Owns the session lifecycle, the toolbar, and the registration of
/// the outer cover display accessory.
struct CaptureRootView: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine

    @Environment(\.scenePhase) private var scenePhase
    @State private var showEditor = false
    @State private var showManualControls = false
    @State private var showOuterSimulator = false
    @State private var showDiagnostics = false
    @State private var editorStartPane: ScriptShotListEditorView.Pane = .script
    @State private var showRemoteSetup = false
    @State private var showGoLive = false
    @State private var showGuests = false
    /// Phase 10: first-launch onboarding asks for camera/mic in context before starting.
    @State private var showOnboarding = !Onboarding.isCompleted && !LaunchOptions.current.isUITest

    var body: some View {
        NavigationStack {
            InnerDirectorView(state: state, engine: engine)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
                .toolbar { toolbarContent }
        }
        // iOS 27.1: register the cover-display monitor. It's scoped to this view, so it
        // disappears automatically if the user navigates away from capture. If the system
        // withdraws it (fold closed, app backgrounded, another accessory takes over),
        // `onAvailabilityChange` reports false and the inner UI simply hides its
        // "Cover live" badge; no inner functionality depends on the accessory.
        //
        // Phase 4: `isEnabled` is the user's toggle AND the thermal guard. At .critical the
        // engine sets `accessorySuspendedForThermal`, which flips this to false and frees the
        // cover display's compositing budget. Availability goes to the engine so it can raise
        // the "Cover monitor paused" banner and the inner mini-teleprompter takes over.
        .duoCaptureAccessory(
            isEnabled: Binding(get: { state.outerAccessoryShouldBeEnabled },
                               set: { state.isOuterMonitorEnabled = $0 }),
            onAvailabilityChange: { engine.outerAccessoryAvailabilityChanged($0) }
        ) {
            OuterMonitorAccessoryView(state: state, engine: engine)
        }
        // iOS 27.1 hinge input → state.hingePosture (behaviour/badges, not layout).
        .duoOnHingeChange { angle in state.updateHinge(angleDegrees: angle) }
        .task {
            guard !showOnboarding else { return }
            await engine.start()
            stageForScreenshotsIfRequested()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false; Task { await engine.start() } }
                .interactiveDismissDisabled()
        }
        .overlay {
            if case .unauthorized = state.status { PermissionDeniedView().background(.black) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: if !showOnboarding { Task { await engine.start() } }
            case .background:
                if state.isRecording { engine.stopRecording() }
                Task { await engine.stop() }
            default: break
            }
        }
        .sheet(isPresented: $showEditor) {
            ScriptShotListEditorView(state: state, engine: engine, initialPane: editorStartPane)
        }
        .sheet(isPresented: $showManualControls) {
            NavigationStack {
                Form {
                    Section("Format") { FormatControls(state: state, engine: engine) }
                    Section("Exposure, white balance & focus") { ManualCameraControls(state: state) }
                    Section("Overlays") { OverlayToggles(state: state) }
                    Section("Teleprompter") { PrompterSettingsControls(state: state) }
                    Section("Audio") { AudioGainControl(state: state) }
                    Section {
                        CaptureModeSettings(state: state, engine: engine)
                    } header: { Text("Cameras") }
                }
                .navigationTitle("Camera")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showManualControls = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showOuterSimulator) {
            OuterMonitorSimulatorPreview(state: state, engine: engine)
        }
        // Phase 4: Launch & Diagnostics (telemetry, simulators, Demo Mode / App Store preset).
        .sheet(isPresented: $showDiagnostics) {
            LaunchDiagnosticsView(state: state, engine: engine,
                                  previewCoverDisplay: { showDiagnostics = false; showOuterSimulator = true })
        }
        // Thermal/accessory/storage banners float over everything, below the nav bar.
        .overlay(alignment: .top) { SystemStatusBanner(state: state).padding(.top, 52) }
        .onReceive(NotificationCenter.default.publisher(for: .duoShowDiagnostics)) { _ in showDiagnostics = true }
        // Phase 6: Remote Producer setup + the camera-side approval of each remote.
        .sheet(isPresented: $showRemoteSetup) {
            if let link = engine.remoteLink { RemoteSetupSheet(link: link) }
        }
        // Phase 8: Go Live (RTMP/RTMPS).
        .sheet(isPresented: $showGoLive) {
            if let live = engine.liveStream { GoLiveSheet(live: live, state: state) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .duoShowGoLive)) { _ in showGoLive = true }
        // Phase 9: remote guest room, plus a floating tile of the guest while connected.
        .sheet(isPresented: $showGuests) {
            if let guests = engine.guests { GuestSheet(guests: guests, state: state) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .duoShowGuests)) { _ in showGuests = true }
        .overlay(alignment: .bottomLeading) {
            if state.guestState.guestName != nil, let guests = engine.guests {
                GuestPreviewTile(frames: guests.pipeline.frames)
                    .frame(width: 176, height: 99)
                    .overlay(alignment: .bottomLeading) {
                        Text(state.guestState.guestName ?? "").font(.caption2.bold()).padding(4)
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4)).padding(4)
                    }
                    .padding(.leading, 16).padding(.bottom, 120)
                    .onTapGesture { showGuests = true }
            }
        }
        .alert("Allow remote control?",
               isPresented: Binding(get: { engine.remoteLink?.pendingInvitation != nil },
                                    set: { if !$0 { engine.remoteLink?.answerInvitation(false) } }),
               presenting: engine.remoteLink?.pendingInvitation) { _ in
            Button("Allow") { engine.remoteLink?.answerInvitation(true) }
            Button("Decline", role: .cancel) { engine.remoteLink?.answerInvitation(false) }
        } message: { invitation in
            Text("\(invitation.peerName) wants to start and stop takes, drop markers and drive the prompter.")
        }
        .accessibilityIdentifier("captureRoot")
    }

    /// Phase 6: UI tests / screenshot runs stage a scene from launch arguments.
    private func stageForScreenshotsIfRequested() {
        let options = LaunchOptions.current
        guard options.isUITest || options.demoMode || options.scene != nil else { return }
        if options.demoMode && !state.isDemoMode { DemoModePreset.setEnabled(true, state: state, engine: engine) }
        switch options.scene {
        case .cover: showOuterSimulator = true
        case .flat: state.simulatedHingePosture = .flat
        case .tabletop: state.simulatedHingePosture = .tabletopLShape
        case .takes: editorStartPane = .takes; showEditor = true
        case .diagnostics: showDiagnostics = true
        case nil: break
        }
        if options.rolling && !state.isRecording {
            state.countdownSeconds = 0
            engine.toggleRecording()
        }
    }

    // MARK: Toolbar
    //
    // Trailing items carry iOS 27 visibility priorities. When the width shrinks (closed
    // cover-width layouts, Split View, Dynamic Type) the LOWEST priority items move into
    // the system overflow menu first; Record goes last. Items placed inside
    // ToolbarOverflowMenu always live in overflow and never come back into the bar.

    // Phase 3 priorities (iOS 27 ToolbarItemVisibilityPriority). Highest stay longest:
    //   .duoCritical  Record
    //   .high         Lens switcher, Prompter play/pause, Peaking, Zebras
    //   (automatic)   Shot list / sketches
    //   .low          Camera settings sheet
    // Secondary cinema settings (codec, Dolby Vision, zebra threshold, grid opacity,
    // mirroring) live in ToolbarOverflowMenu, which ALWAYS stays in overflow, so narrow
    // widths and split modes never push them over reserved regions. The vertical right
    // rail (RightRailToolbar) mirrors the same tiers.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            FormatBadge(state: state)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { engine.toggleRecording() } label: {
                Image(systemName: state.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel(state.isRecording ? "Stop" : "Record")
        }
        .duoVisibilityPriority(.duoCritical)

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Lens", selection: Binding(get: { state.activeLens }, set: { engine.selectLens($0) })) {
                    ForEach(LensOption.allCases) { Text("\($0.label)  \($0.focalLength)").tag($0) }
                }
            } label: {
                Label(state.activeLens.label, systemImage: "camera.aperture")
            }
            .accessibilityLabel("Lens")
        }
        .duoVisibilityPriority(.high)

        ToolbarItem(placement: .topBarTrailing) {
            Button { state.togglePrompter() } label: {
                Image(systemName: state.isPrompterPlaying ? "pause.circle" : "play.circle")
            }
            .accessibilityLabel(state.isPrompterPlaying ? "Pause teleprompter" : "Play teleprompter")
        }
        .duoVisibilityPriority(.high)

        ToolbarItem(placement: .topBarTrailing) {
            Button { state.showFocusPeaking.toggle() } label: {
                Image(systemName: "scope").symbolVariant(state.showFocusPeaking ? .fill : .none)
            }
            .accessibilityLabel("Focus peaking")
        }
        .duoVisibilityPriority(.high)

        ToolbarItem(placement: .topBarTrailing) {
            Button { state.showZebraStripes.toggle() } label: {
                Image(systemName: state.showZebraStripes ? "circle.lefthalf.striped.horizontal" : "circle.lefthalf.filled")
            }
            .accessibilityLabel("Zebras")
        }
        .duoVisibilityPriority(.high)

        ToolbarItem(placement: .topBarTrailing) {
            Button { state.isShotListDrawerOpen = true } label: { Image(systemName: "pencil.and.list.clipboard") }
                .accessibilityLabel("Shot list and sketches")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button { showManualControls = true } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("Camera settings")
        }
        .duoVisibilityPriority(.low)

        ToolbarOverflowMenu {
            CinemaSettingsMenuContent(state: state, engine: engine)
            Section("Launch") {
                Button("Launch & Diagnostics", systemImage: "stethoscope") { showDiagnostics = true }
                Button("Remote producer", systemImage: "appletvremote.gen4") { showRemoteSetup = true }
                Button(state.liveState.isActive ? "Live stream" : "Go Live", systemImage: "dot.radiowaves.left.and.right") { showGoLive = true }
                Button("Remote guest", systemImage: "person.wave.2") { showGuests = true }
            }
            Section("Session") {
                Toggle("Cover display monitor", isOn: $state.isOuterMonitorEnabled)
                Button("Drop marker", systemImage: "bookmark") { engine.dropMarker() }
                    .disabled(!state.isRecording)
                Button("Reset teleprompter", systemImage: "backward.end") { state.resetPrompter() }
                Button("Script & shot list editor", systemImage: "doc.text") { editorStartPane = .script; showEditor = true }
                Button("Takes", systemImage: "film.stack") { editorStartPane = .takes; showEditor = true }
            }
            Section("Simulator & testing") {
                Button("Preview cover display", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                    showOuterSimulator = true
                }
                Picker("Simulate hinge", selection: $state.simulatedHingePosture) {
                    Text("Real hinge").tag(HingePosture?.none)
                    ForEach(HingePosture.allCases) { Label($0.label, systemImage: $0.symbol).tag(HingePosture?.some($0)) }
                }
            }
        }
    }
}
