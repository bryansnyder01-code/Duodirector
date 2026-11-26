import SwiftUI

// =====================================================================================
//  InnerDirectorView: the 7.6" inner display (Phase 3)
//
//  HOW LAYOUT FOLLOWS THE HINGE
//  ────────────────────────────
//  Apple's guidance (forums 848017 / onHingeChange docs) ranks the tools:
//    1. system containers  →  2. ArrangementView  →  3. ReservedRegion queries,
//  and says hinge callbacks must NOT drive layout. So:
//
//   • ArrangementView (iOS 27.1) is the outer wrapper in flat and book postures.
//       .overlay: primary floats ABOVE secondary in z on a flat display (and goes side by
//                 side if the device folds). We use it in FLAT mode: secondary = the
//                 78/22 viewfinder + rail split, primary = the Shot List HUD card.
//       .split:   primary and secondary on either side of the fold; the system keeps
//                 both clear of the crease. We use it in BOOK mode.
//   • ReservedRegion (iOS 27.1), read with GeometryProxy.reservedRegions(kind:options:)
//     INSIDE the GeometryReader on every pass (never cached):
//       .division  = the ~40pt crease. In TABLETOP L-mode its frame splits the screen
//                    into the upper monitor and the lower tactile deck.
//       .occlusion = the inner under-display camera (only while active) and the
//                    persistent status area at the top of the trailing rail. The rail and
//                    the HUD card are inset/moved so nothing interactive sits under them.
//     We also report the fold AXIS (not the frame) into state via onGeometryChange, so
//     the hinge callback can tell book from tabletop for behaviour/badges.
//   • `.onHingeChange` (iOS 27.1) feeds `state.hingePosture`. It's used for behaviour
//     only. The one exception is `.closed`, where the app is on the 5.4" cover display
//     and we swap to the compact cover capture UI (a different screen, not a different
//     arrangement around the fold).
//
//  PHASE 4 ADDITIONS
//  ─────────────────
//   • Dual-Cam Podcast: the viewfinder shows rear (Guest) + inner (Host) from two
//     preview layers. PiP / separate-tracks → movable Host tile that dodges `.occlusion`
//     (the inner camera's own region is ACTIVE while it records); split-screen → Guest |
//     Host panes. Tabletop + dual → Host and Guest side by side above the fold, with
//     Rate Take and Drop Marker on the lower deck (TabletopControlDeckView).
//   • Rail: one-tap Solo Rear 4K ↔ Dual-Cam toggle right under Record (dimmed with an
//     explanatory popover when MultiCam isn't supported).
//   • Guardrails: ThermalPill in the status row; banners come from CaptureRootView.
//   • Accessory withdrawn (or paused for heat): an inline mini-teleprompter + transport /
//     record / marker strip appears under the viewfinder. Nothing about the capture
//     session changes, so a rolling take keeps rolling.
// =====================================================================================

struct InnerDirectorView: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine
    @State private var showScriptDrawer = false

    var body: some View {
        Group {
            if state.hingePosture == .closed {
                // Closed: we're on the cover display. Reuse the cover monitor as the full
                // capture UI (non-mirrored, since the creator is behind the phone now).
                OuterMonitorAccessoryView(state: state, engine: engine, isPrimaryDisplay: true)
            } else {
                foldAwareLayout
            }
        }
        .background(.black)
        .foregroundStyle(.white)
        // A container element, so this identifier doesn't override the children's own
        // (e.g. "tabletopDeck", which the screenshot UI test waits for).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("innerDirector")
        .sheet(isPresented: $showScriptDrawer) {
            ScriptDrawer(state: state)
                .presentationDetents([.fraction(0.4), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $state.isShotListDrawerOpen) {
            PencilShotListView(state: state)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var foldAwareLayout: some View {
        GeometryReader { proxy in
            // Fresh region snapshot for THIS layout pass. Never stored.
            let regions = DuoRegions(proxy)
            let posture = regions.posture(override: state.simulatedHingePosture)

            Group {
                switch posture {
                case .flat:
                    flatLayout(regions: regions, size: proxy.size)
                case .book:
                    bookLayout(regions: regions)
                case .tabletop(let fold):
                    tabletopLayout(fold: fold, regions: regions)
                }
            }
            .overlay(alignment: .top) {
                StatusBadges(state: state, posture: posture)
                    .padding(.top, regions.occlusionInsets.top + 4)
            }
            .animation(.snappy, value: posture)
        }
        // Report only the fold AXIS to state (so the hinge callback can tell book from
        // tabletop). The frames themselves stay inside the layout pass.
        .onGeometryChange(for: Axis?.self) { proxy in
            DuoRegions(proxy).foldAxis
        } action: { axis in
            state.setFoldAxis(axis)
        }
    }

    // MARK: Flat (0° / 180°): overlay arrangement around a 78/22 split

    private func flatLayout(regions: DuoRegions, size: CGSize) -> some View {
        let insets = regions.occlusionInsets
        let paneWidth = size.width * 0.78
        // Pin the Shot List HUD where it can't collide with an occlusion: try top-leading
        // of the viewfinder pane, fall back to bottom-leading.
        let card = CGSize(width: min(280, paneWidth - 32), height: 92)
        let topRect = CGRect(x: insets.leading + 16, y: insets.top + 44, width: card.width, height: card.height)
        let hudAtTop = !regions.collides(topRect)

        return DuoOverlayArrangement {
            // PRIMARY (floats above in .overlay): the compact Shot List HUD card.
            ShotListHUDCard(state: state)
                .frame(width: card.width)
                .padding(.leading, insets.leading + 16)
                .padding(.top, hudAtTop ? insets.top + 44 : 0)
                .padding(.bottom, hudAtTop ? 0 : insets.bottom + 120)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: hudAtTop ? .topLeading : .bottomLeading)
        } secondary: {
            // SECONDARY: ~78% viewfinder pane | ~22% trailing thumb rail.
            HStack(spacing: 0) {
                // No prompter band here: the Shot List card floats over that spot, and
                // the talent reads the script on the cover display (or the fallback strip
                // below the viewfinder when the cover monitor is gone).
                ViewfinderPane(state: state, engine: engine, prompterHeight: 0)
                    .frame(width: paneWidth)
                    .padding(.leading, insets.leading)
                RightRailToolbar(state: state, engine: engine, showScriptDrawer: $showScriptDrawer)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, insets.trailing)
            }
        }
    }

    // MARK: Book (vertical crease): split arrangement

    private func bookLayout(regions: DuoRegions) -> some View {
        DuoSplitArrangement(primaryRatio: 0.6) {
            ViewfinderPane(state: state, engine: engine)
        } secondary: {
            HStack(spacing: 0) {
                DirectorPanel(state: state, engine: engine)
                RightRailToolbar(state: state, engine: engine, showScriptDrawer: $showScriptDrawer)
                    .frame(width: 150)
            }
            .padding(regions.occlusionInsets)
        }
    }

    // MARK: Tabletop 90° L-mode (horizontal crease): explicit ReservedRegion layout

    /// Upper half: viewfinder + guides + teleprompter, strictly above `fold.minY`.
    /// Crease: `fold.height` (≈40pt incl. Apple's margins) left empty, non-interactive.
    /// Lower half: TabletopControlDeckView, strictly below `fold.maxY`.
    ///
    /// (`ArrangementView` with `.split.axes(.vertical)` would also stack these, but the
    /// deck wants the exact crease edge, and Apple allows ReservedRegion "if and only if"
    /// the containers don't fit. Here they don't give us the crease position.)
    private func tabletopLayout(fold: CGRect, regions: DuoRegions) -> some View {
        let insets = regions.occlusionInsets
        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Tabletop + Dual-Cam: Host and Guest side by side above the fold.
                Viewfinder(state: state, engine: engine, prompterHeight: 120,
                           dualLayout: state.isDualCam ? .sideBySide : .automatic)
                    // Keep a strip for the status pills so they don't sit on the
                    // HOST / GUEST tile labels.
                    .padding(.top, 30)
                Button { showScriptDrawer = true } label: {
                    Image(systemName: "square.and.pencil").frame(width: 40, height: 40)
                        .background(.black.opacity(0.5), in: .circle)
                }
                .padding(.top, insets.top + 8)
                .padding(.trailing, insets.trailing + 8)
                .accessibilityLabel("Edit script")
            }
            .frame(height: max(0, fold.minY))

            Color.black
                .frame(height: fold.height)
                .overlay(Capsule().fill(.white.opacity(0.08)).frame(width: 60, height: 3))
                .accessibilityHidden(true)

            TabletopControlDeckView(state: state, engine: engine)
                .padding(.leading, insets.leading)
                .padding(.trailing, insets.trailing)
                .padding(.bottom, insets.bottom)
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - Viewfinder

/// 1.4:1 viewfinder pane (the inner display's own aspect), letterboxed in black.
private struct ViewfinderPane: View {
    let state: StudioSessionState
    let engine: CameraEngine
    /// 0 hides the in-viewfinder prompter band.
    var prompterHeight: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                Viewfinder(state: state, engine: engine, prompterHeight: prompterHeight)
                    .aspectRatio(1.4, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
            }
            // Phase 4: cover monitor gone (iOS withdrew it, or the thermal guard paused it).
            // Bring its prompter and controls onto this screen.
            if state.showsAccessoryFallback {
                AccessoryFallbackStrip(state: state, engine: engine)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: state.showsAccessoryFallback)
    }
}

extension StudioSessionState {
    /// True when the talent has lost the cover-display prompter: iOS withdrew the
    /// accessory while we wanted it, or the thermal guard paused it.
    var showsAccessoryFallback: Bool {
        !isOuterAccessoryActive && (wasOuterAccessoryWithdrawn || accessorySuspendedForThermal)
    }
}

/// Inline mini-teleprompter + full transport, shown only while the cover monitor is gone.
/// Pure UI: it calls the same engine methods as the cover monitor did, so a rolling take
/// is never interrupted by the swap.
private struct AccessoryFallbackStrip: View {
    let state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(state.accessorySuspendedForThermal ? "Cover monitor paused (heat)" : "Cover monitor withdrawn",
                      systemImage: "rectangle.portrait.slash")
                    .font(.caption2.bold()).foregroundStyle(.orange)
                if !state.scriptText.isEmpty {
                    TeleprompterText(state: state, fontScale: 0.55)
                        .frame(height: 64)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 6) {
                PrompterTransportPill(state: state)
                HStack(spacing: 8) {
                    CountdownPicker(state: state).buttonStyle(.bordered)
                    Button { engine.dropMarker() } label: { Image(systemName: "mappin.and.ellipse").frame(width: 30, height: 30) }
                        .buttonStyle(.bordered).disabled(!state.isRecording)
                        .accessibilityLabel("Drop marker")
                }
            }
            RecordButton(state: state, engine: engine, diameter: 56)
        }
        .padding(10)
        .background(Color(white: 0.1))
    }
}

/// Camera preview + peaking/zebra overlay + guides + histogram + teleprompter + meters.
private struct Viewfinder: View {
    let state: StudioSessionState
    let engine: CameraEngine
    var prompterHeight: CGFloat
    /// `.automatic` follows `state.dualExportStyle`; `.sideBySide` is the tabletop Host|Guest pair.
    var dualLayout: DualPreviewLayout = .automatic

    enum DualPreviewLayout { case automatic, sideBySide }

    /// Tabletop Host | Guest tiles: the prompter gets its own band above the tiles, so
    /// the script never runs across the HOST / GUEST labels.
    private var prompterAboveTiles: Bool { state.isDualCam && dualLayout == .sideBySide }
    private var showsPrompter: Bool { !state.scriptText.isEmpty && prompterHeight > 0 }

    var body: some View {
        if prompterAboveTiles && showsPrompter {
            VStack(spacing: 0) {
                prompterBand.frame(height: prompterHeight * 0.8)
                viewfinderStack(prompterOverlaid: false)
            }
        } else {
            viewfinderStack(prompterOverlaid: showsPrompter)
        }
    }

    private var prompterBand: some View {
        TeleprompterText(state: state, fontScale: 0.75)
            .background(.black.opacity(0.5))
    }

    private func viewfinderStack(prompterOverlaid: Bool) -> some View {
        ZStack {
            cameraLayer
            if !(state.isDualCam && (dualLayout == .sideBySide || state.dualExportStyle == .splitScreenComposite)) {
                // Guides describe the rear (Guest) frame; in split layouts they'd be misleading.
                FramingGuidesOverlay(show16x9: state.show16x9Guide, show9x16: state.show9x16Guide,
                                     showThirds: state.showThirdsGrid, opacity: state.gridOpacity)
            }

            VStack(spacing: 0) {
                if prompterOverlaid {
                    prompterBand.frame(maxHeight: prompterHeight)
                }
                HStack { OverlayBadges(state: state); Spacer() }.padding(8)
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.showHistogram {
                            LumaHistogramView(store: engine.overlayStore,
                                              zebraThreshold: state.showZebraStripes ? state.zebraThreshold : nil)
                        }
                        RecordingTimecode(state: state)
                    }
                    Spacer()
                    StereoAudioMeter(state: state, thickness: 8).frame(height: 90)
                }
                .padding(10)
            }

            CountdownOverlay(remaining: state.countdownRemaining)
        }
        .clipped()
    }

    /// Solo: rear only. Dual: two preview layers from the same MultiCam session.
    @ViewBuilder
    private var cameraLayer: some View {
        if !state.isDualCam {
            PreviewSurface(state: state, engine: engine, role: .rear)
        } else if dualLayout == .sideBySide {
            HostGuestPreviewPair(state: state, engine: engine)
        } else {
            switch state.dualExportStyle {
            case .splitScreenComposite:
                DualCamSplitPreview(state: state, engine: engine)
            case .pictureInPicture, .separateSyncedTracks:
                DualCamPiPPreview(state: state, engine: engine)
            }
        }
    }
}

// MARK: - Shot List HUD

/// Compact card: active shot, lens, progress, and one-tap "done → next". Placed by the
/// flat layout so it never overlaps an `.occlusion` region.
private struct ShotListHUDCard: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        if let shot = state.activeShot {
            HStack(spacing: 10) {
                Button { state.toggleCompleted(shot.id) } label: {
                    Image(systemName: shot.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2).foregroundStyle(shot.isCompleted ? .green : .white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark shot done")

                VStack(alignment: .leading, spacing: 2) {
                    Text("SHOT \((state.activeShotIndex ?? 0) + 1)/\(state.shotList.count)")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(shot.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(shot.framingNote).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Button { state.completeActiveShotAndAdvance() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Done, next shot")
                    Button { state.isShotListDrawerOpen = true } label: { Image(systemName: "scribble.variable") }
                        .accessibilityLabel("Open shot list and sketches")
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if shot.cameraLens != state.activeLens {
                    // Nudge: the shot calls for a different lens.
                    Text("Use \(shot.cameraLens.label)").font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow, in: .capsule).foregroundStyle(.black)
                        .offset(x: 6, y: -8)
                }
            }
        }
    }
}

// MARK: - Book-mode panel

/// No ScrollView: Apple advises against scroll views inside an ArrangementView.
private struct DirectorPanel: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShotListHUDCard(state: state)
            HStack(spacing: 16) {
                RecordButton(state: state, engine: engine)
                VStack(alignment: .leading, spacing: 8) {
                    CountdownPicker(state: state).buttonStyle(.bordered)
                    MarkTakeButton(state: state, engine: engine, goodTake: true)
                        .buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                }
            }
            PrompterTransportPill(state: state)
            AudioGainControl(state: state)
            if let message = state.lastSaveMessage {
                Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.07))
    }
}

// MARK: - Right rail (trailing vertical toolbar)

/// Priority tiers for the rail. They mirror the ToolbarItemVisibilityPriority values used
/// for the same actions in the navigation-bar toolbar (CaptureRootView):
///   .critical ↔ .duoCritical (higherThan: .high), .high ↔ .high,
///   .standard ↔ .automatic, .low ↔ .low
/// iOS 27.1 has no system vertical toolbar placement we could confirm, so the rail applies
/// the same collapse ORDER itself: lowest tier moves into the overflow menu first.
enum RailTier: Int, Comparable {
    case low, standard, high, critical
    static func < (a: RailTier, b: RailTier) -> Bool { a.rawValue < b.rawValue }
}

/// Trailing vertical toolbar in the thumb zone. Highest-priority capture actions sit at the
/// TOP (where the thumb rests when holding the open device by its right edge):
///   critical: Record
///   high:     Lens switcher, Prompter play/pause, Peaking, Zebras
///   standard: 16:9, 9:16, Histogram, Shot list, Script
///   low:      Format, Exposure & focus, Prompter settings
/// Secondary cinema settings ALWAYS live in the overflow menu at the bottom (the rail's
/// equivalent of ToolbarOverflowMenu): Codec, Dolby Vision, Zebra threshold, Grid
/// opacity, Mirror toggles. As space shrinks, whole tiers fold into that menu.
///
/// The rail reads its OWN reserved regions, so it clears the status-bar occlusion and
/// the inner camera in whatever container it's placed (flat or book).
struct RightRailToolbar: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine
    @Binding var showScriptDrawer: Bool

    enum Panel: String, Identifiable { case format, exposure, prompter; var id: String { rawValue } }
    @State private var openPanel: Panel?

    var body: some View {
        GeometryReader { proxy in
            let regions = DuoRegions(proxy)
            let clear = regions.verticalInsets(forColumn: CGRect(origin: .zero, size: proxy.size))
            // Under ~130pt (inner display in portrait) the rail goes icon-only instead of
            // truncating every title to "…".
            let iconOnly = proxy.size.width < 130
            ViewThatFits(in: .vertical) {
                rail(minimumTier: .low, iconOnly: iconOnly)
                rail(minimumTier: .standard, iconOnly: iconOnly)
                rail(minimumTier: .high, iconOnly: iconOnly)
                rail(minimumTier: .critical, iconOnly: iconOnly)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, clear.top + 8)
            .padding(.bottom, clear.bottom + 8)
        }
        .background(Color(white: 0.06))
    }

    @ViewBuilder
    private func rail(minimumTier: RailTier, iconOnly: Bool) -> some View {
        VStack(spacing: 6) {
            // ── critical ──
            RecordButton(state: state, engine: engine, diameter: 60)
                .accessibilityIdentifier("recordToggle")   // UI tests: the record button
                .padding(.bottom, 2)
            // Phase 4: one-tap Solo ↔ Dual. Critical tier: never folds into overflow, since
            // it's the first decision of a podcast session.
            CaptureModeToggle(state: state, engine: engine, compact: minimumTier == .critical || iconOnly)
                .padding(.bottom, 4)

            // ── high ──
            if RailTier.high >= minimumTier {
                lensSwitcher
                railButton("Prompter", state.isPrompterPlaying ? "pause.fill" : "play.fill",
                           active: state.isPrompterPlaying) { state.togglePrompter() }
                railButton("Peaking", "scope", active: state.showFocusPeaking) { state.showFocusPeaking.toggle() }
                railButton("Zebras", "circle.lefthalf.striped.horizontal", active: state.showZebraStripes) { state.showZebraStripes.toggle() }
            }

            // ── standard ──
            if RailTier.standard >= minimumTier {
                railDivider
                railButton("16:9", "rectangle", active: state.show16x9Guide) { state.show16x9Guide.toggle() }
                railButton("9:16", "rectangle.portrait", active: state.show9x16Guide) { state.show9x16Guide.toggle() }
                railButton("Histogram", "chart.bar.xaxis", active: state.showHistogram) { state.showHistogram.toggle() }
                railButton("Shots \(state.completedShotCount)/\(state.shotList.count)", "pencil.and.list.clipboard",
                           active: state.isShotListDrawerOpen) { state.isShotListDrawerOpen = true }
                railButton("Script", "text.alignleft", active: false) { showScriptDrawer = true }
            }

            // ── low ──
            if RailTier.low >= minimumTier {
                railDivider
                panelButton(.format, "\(state.resolution.label) \(state.frameRate.label)", "film") {
                    FormatControls(state: state, engine: engine).padding().frame(width: 300)
                }
                panelButton(.exposure, state.isAutoExposure && state.isAutoFocus ? "Auto" : "Manual", "dial.medium") {
                    ManualCameraControls(state: state).padding().frame(width: 320)
                }
                panelButton(.prompter, "\(Int(state.prompterScrollSpeed)) pt/s", "speedometer") {
                    PrompterSettingsControls(state: state).padding().frame(width: 300)
                }
            }

            Spacer(minLength: 0)
            overflowMenu(collapsedTier: minimumTier)
        }
        .padding(.horizontal, iconOnly ? 6 : 8)
        .environment(\.railIconOnly, iconOnly)
    }

    /// Always-present overflow, plus anything below `collapsedTier` that no longer fits.
    private func overflowMenu(collapsedTier: RailTier) -> some View {
        Menu {
            if collapsedTier > .high {
                Section("Capture") {
                    Picker("Lens", selection: Binding(get: { state.activeLens }, set: { engine.selectLens($0) })) {
                        ForEach(LensOption.allCases) { Text("\($0.label)  \($0.focalLength)").tag($0) }
                    }
                    Button(state.isPrompterPlaying ? "Pause prompter" : "Play prompter",
                           systemImage: state.isPrompterPlaying ? "pause" : "play") { state.togglePrompter() }
                    Toggle("Focus peaking", isOn: $state.showFocusPeaking)
                    Toggle("Zebras", isOn: $state.showZebraStripes)
                }
            }
            if collapsedTier > .standard {
                Section("Guides") {
                    Toggle("16:9 guide", isOn: $state.show16x9Guide)
                    Toggle("9:16 guide", isOn: $state.show9x16Guide)
                    Toggle("Histogram", isOn: $state.showHistogram)
                    Button("Shot list & sketches", systemImage: "pencil.and.list.clipboard") { state.isShotListDrawerOpen = true }
                    Button("Edit script", systemImage: "text.alignleft") { showScriptDrawer = true }
                }
            }
            if collapsedTier > .low {
                Section("Format") {
                    Picker("Frame rate", selection: Binding(get: { state.frameRate }, set: { engine.selectFrameRate($0) })) {
                        ForEach(FrameRatePreset.allCases) { Text("\($0.label) fps").tag($0) }
                    }
                    Picker("Resolution", selection: Binding(get: { state.resolution }, set: { engine.selectResolution($0) })) {
                        ForEach(ResolutionPreset.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Auto exposure", isOn: $state.isAutoExposure)
                    Toggle("Autofocus", isOn: $state.isAutoFocus)
                }
            }
            CinemaSettingsMenuContent(state: state, engine: engine)
            Section {
                Button("Launch & Diagnostics", systemImage: "stethoscope") {
                    NotificationCenter.default.post(name: .duoShowDiagnostics, object: nil)
                }
                Button(state.liveState.isActive ? "Live stream" : "Go Live", systemImage: "dot.radiowaves.left.and.right") {
                    NotificationCenter.default.post(name: .duoShowGoLive, object: nil)
                }
                Button("Remote guest", systemImage: "person.wave.2") {
                    NotificationCenter.default.post(name: .duoShowGuests, object: nil)
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis.circle").font(.title3)
                Text("More").font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityLabel("More settings")
    }

    /// 0.5× / 1× / 2× segmented chips (one row).
    private var lensSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(LensOption.allCases) { lens in
                Button { engine.selectLens(lens) } label: {
                    Text(lens.label)
                        .font(.caption.bold())
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(state.activeLens == lens ? Color.yellow : Color.white.opacity(0.12), in: .rect(cornerRadius: 8))
                        .foregroundStyle(state.activeLens == lens ? .black : .white)
                }
                .buttonStyle(.plain)
                // Module swaps are blocked mid-take; Dual-Cam is locked to the Fusion Main module.
                .disabled((state.isRecording && lens.usesMainModule != state.activeLens.usesMainModule)
                          || (state.isDualCam && !lens.usesMainModule))
                .accessibilityLabel(lens.detail)
            }
        }
    }

    private var railDivider: some View {
        Divider().overlay(.white.opacity(0.15)).padding(.vertical, 2)
    }

    private func railButton(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        RailButton(title: title, symbol: symbol, active: active, action: action)
    }

    private func panelButton<Content: View>(_ panel: Panel, _ title: String, _ symbol: String,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        railButton(title, symbol, active: openPanel == panel) { openPanel = panel }
            .popover(isPresented: Binding(get: { openPanel == panel }, set: { if !$0 { openPanel = nil } }),
                     arrowEdge: .leading) {
                content()
                    .preferredColorScheme(.dark)
                    .presentationCompactAdaptation(.popover)   // stay a popover on iPhone
            }
    }
}

/// The rail goes icon-only on narrow widths (title stays as the a11y label).
private struct RailIconOnlyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var railIconOnly: Bool {
        get { self[RailIconOnlyKey.self] }
        set { self[RailIconOnlyKey.self] = newValue }
    }
}

private struct RailButton: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void
    @Environment(\.railIconOnly) private var iconOnly

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 22)
                if !iconOnly {
                    Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, iconOnly ? 0 : 10)
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(active ? .black : .white)
            .background(active ? Color.yellow : Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: active)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Secondary cinema settings. Used by BOTH the rail's overflow menu and the navigation
/// bar's ToolbarOverflowMenu, so they never drift apart.
struct CinemaSettingsMenuContent: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine

    var body: some View {
        Section("Cinema") {
            Picker("Codec", selection: Binding(get: { state.preferredCodec }, set: { engine.setCodec($0) })) {
                ForEach(VideoCodecPreset.allCases) { codec in
                    Text(codec.label).tag(codec)
                }
            }
            .disabled(!state.isProResSupported || state.isRecording)
            Toggle("Dolby Vision HDR", isOn: Binding(get: { state.isDolbyVisionEnabled }, set: { engine.setDolbyVision($0) }))
                .disabled(!state.isDolbyVisionSupported || state.isRecording)
            Picker("Zebra threshold", selection: $state.zebraThreshold) {
                ForEach([0.70, 0.80, 0.90, 0.95, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }
            Picker("Grid opacity", selection: $state.gridOpacity) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }
            Toggle("Rule-of-thirds grid", isOn: $state.showThirdsGrid)
            Toggle("Mirror cover preview", isOn: $state.mirrorOuterPreview)
            Toggle("Mirror prompter text", isOn: $state.prompterMirrored)
        }
        if state.isDualCam {
            Section("Dual-Cam") {
                DualExportStylePicker(state: state, engine: engine)
            }
        }
    }
}

// MARK: - Script drawer (Phase 2)

private struct ScriptDrawer: View {
    @Bindable var state: StudioSessionState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $state.scriptText)
                    .font(.system(size: state.prompterFontSize * 0.7, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal)
                Divider()
                PrompterSettingsControls(state: state).padding()
            }
            .navigationTitle("Script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PasteButton(payloadType: String.self) { strings in
                        if let text = strings.first { state.scriptText = text; state.resetPrompter() }
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Status

private struct StatusBadges: View {
    let state: StudioSessionState
    let posture: DuoPosture

    var body: some View {
        // Narrow widths: icon-only pills rather than pills truncated into each other.
        ViewThatFits(in: .horizontal) {
            pills(iconOnly: false)
            pills(iconOnly: true)
        }
        .font(.caption2)
        .allowsHitTesting(false)
    }

    private func pills(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            pill(state.hingePosture.label
                 + (state.hingeAngleDegrees.map { " \(Int($0))°" } ?? "")
                 + (state.simulatedHingePosture != nil ? " (sim)" : ""),
                 state.hingePosture.symbol)
            if state.isOuterMonitorAvailable { pill("Cover live", "rectangle.portrait.fill", .green) }
            if state.isDualCam { pill("Dual-Cam · \(state.dualExportStyle.label)", CaptureMode.dualPodcastMultiCam.symbol, .cyan) }
            ThermalPill(state: state)
            LivePill(state: state)
            GuestPill(state: state)
            if state.sourceMode == .mock { pill("Mock camera", "wand.and.stars", .orange) }
            if state.activeLens == .crop52 && !state.isCropOpticalQuality { pill("2× digital", "plus.magnifyingglass", .yellow) }
            if case .saving = state.status { pill("Saving…", "arrow.down.circle", .white) }
            if case .unauthorized = state.status { pill("Camera access off", "exclamationmark.triangle", .red) }
            if case .failed(let message) = state.status { pill(message, "exclamationmark.triangle", .red) }
            if let note = state.statusNote { pill(note, "info.circle", .yellow) }
        }
        .environment(\.statusPillIconOnly, iconOnly)
        .fixedSize()
    }

    private func pill(_ text: String, _ icon: String, _ color: Color = .white) -> some View {
        StatusPillLabel(text: text, icon: icon, color: color)
    }
}

private struct StatusPillIconOnlyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var statusPillIconOnly: Bool {
        get { self[StatusPillIconOnlyKey.self] }
        set { self[StatusPillIconOnlyKey.self] = newValue }
    }
}

private struct StatusPillLabel: View {
    let text: String
    let icon: String
    let color: Color
    @Environment(\.statusPillIconOnly) private var iconOnly

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: icon).accessibilityLabel(text)
            } else {
                Label(text, systemImage: icon)
            }
        }
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(color)
            .background(.black.opacity(0.6), in: .capsule)
    }
}

#Preview("Inner – flat (mock)") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    let engine = CameraEngine(state: state)
    return NavigationStack { InnerDirectorView(state: state, engine: engine) }
        .task { await engine.start() }
}

#Preview("Inner – flat, Dual-Cam PiP (mock)") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    state.simulateMultiCamSupport = true
    let engine = CameraEngine(state: state)
    return NavigationStack { InnerDirectorView(state: state, engine: engine) }
        .task { await engine.start(); engine.setCaptureMode(.dualPodcastMultiCam) }
}

#Preview("Inner – tabletop, Dual-Cam (mock)") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    state.simulateMultiCamSupport = true
    state.simulatedHingePosture = .tabletopLShape
    let engine = CameraEngine(state: state)
    return InnerDirectorView(state: state, engine: engine)
        .task { await engine.start(); engine.setCaptureMode(.dualPodcastMultiCam) }
}

#Preview("Inner – tabletop (simulated)") {
    let state = StudioSessionState()
    state.sourceMode = .mock
    state.simulatedHingePosture = .tabletopLShape
    state.showFocusPeaking = true
    let engine = CameraEngine(state: state)
    return InnerDirectorView(state: state, engine: engine)
        .task { await engine.start() }
}
