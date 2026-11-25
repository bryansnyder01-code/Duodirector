import PencilKit
import SwiftUI

/// Apple Pencil storyboard pad + shot checklist for the 7.6" nano-texture inner display
/// (Phase 3).
///
/// Layout: the canvas takes the leading side unobstructed. EVERYTHING else (pen,
/// highlighter and eraser tools, colours, width, undo/redo, and the shot checklist) is
/// docked in a trailing column, so nothing floats over the drawing. The column is inset
/// away from `.occlusion` regions that overlap it (status area at the top of the rail,
/// inner camera when active), read live from the GeometryProxy on every layout pass.
///
/// Flow while filming:
///   1. Pick a shot in the checklist (loads its sketch into the scratchpad).
///   2. Sketch the framing with Apple Pencil (`state.currentSketchData`).
///   3. The sketch is attached to that ShotListItem (`sketchData`), automatically or
///      with "Attach".
///   4. Tick it off when it's in the can, or use "Done → Next".
///
/// Simulator: drawing works with mouse/trackpad (drawingPolicy forced to .anyInput),
/// and the hinge posture toggles in the toolbar apply here too.
struct PencilShotListView: View {
    @Bindable var state: StudioSessionState
    var showsCloseButton = true
    @Environment(\.dismiss) private var dismiss

    @State private var canvasController = PencilCanvasController()
    @State private var tool: PencilDockTool = .pen
    @State private var inkColor: Color = .white
    @State private var inkWidth: CGFloat = 2.5
    @State private var allowsFingerDrawing = false
    @State private var autoAttach = true
    @State private var showsFramingTemplate = true

    private let palette: [Color] = [.white, .yellow, .red, .cyan, .green]

    var body: some View {
        GeometryReader { proxy in
            // Live regions for THIS pass, so the dock always clears the occlusions.
            let regions = DuoRegions(proxy)
            let dockWidth: CGFloat = min(240, max(190, proxy.size.width * 0.26))
            let dockColumn = CGRect(x: proxy.size.width - dockWidth, y: 0, width: dockWidth, height: proxy.size.height)
            let dockInsets = regions.verticalInsets(forColumn: dockColumn)

            HStack(spacing: 0) {
                canvasArea
                    .padding(.leading, regions.occlusionInsets.leading)
                Divider()
                dock
                    .frame(width: dockWidth)
                    .padding(.top, dockInsets.top)
                    .padding(.bottom, dockInsets.bottom)
                    .padding(.trailing, regions.occlusionInsets.trailing)
            }
        }
        .background(Color(white: 0.06))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onChange(of: state.currentSketchData) {
            if autoAttach { state.attachSketchToActiveShot() }
        }
        .onAppear {
            // Load the active shot's sketch if the pad is empty.
            if state.currentSketchData.isEmpty, let id = state.activeShot?.id { state.activateShot(id) }
        }
    }

    // MARK: Canvas

    private var canvasArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.activeShot?.title ?? "Scratchpad").font(.headline)
                    if let note = state.activeShot?.framingNote, !note.isEmpty {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let lens = state.activeShot?.cameraLens {
                    Text("\(lens.label) · \(lens.focalLength)")
                        .font(.caption.monospaced().bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.white.opacity(0.12), in: .capsule)
                }
                if showsCloseButton {
                    Button("Done") { dismiss() }.buttonStyle(.bordered)
                }
            }

            ZStack {
                PencilCanvasView(
                    drawingData: $state.currentSketchData,
                    tool: tool.pkTool(color: UIColor(inkColor), width: inkWidth),
                    allowsFingerDrawing: allowsFingerDrawing,
                    controller: canvasController)
                if showsFramingTemplate {
                    // Faint 16:9 frame + thirds so framing sketches match the real crop.
                    FramingGuidesOverlay(show16x9: true, show9x16: state.show9x16Guide,
                                         showThirds: true, opacity: 0.35)
                        .padding(10)
                }
            }
            .clipShape(.rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
        }
        .padding(14)
    }

    // MARK: Trailing dock

    private var dock: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                toolSection
                Divider()
                checklistSection
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
        .background(Color(white: 0.09))
    }

    private var toolSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOOLS").font(.caption2.bold()).foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(PencilDockTool.allCases) { item in
                    Button { tool = item } label: {
                        Image(systemName: item.symbol)
                            .font(.title3)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(tool == item ? Color.yellow : Color.white.opacity(0.1), in: .rect(cornerRadius: 8))
                            .foregroundStyle(tool == item ? .black : .white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.label)
                }
            }

            HStack(spacing: 8) {
                ForEach(palette, id: \.self) { color in
                    Button { inkColor = color } label: {
                        Circle().fill(color).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: inkColor == color ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Ink colour")
                }
            }
            .disabled(tool == .eraser || tool == .lasso)

            VStack(alignment: .leading, spacing: 2) {
                Text("Width \(String(format: "%.1f", inkWidth))").font(.caption2)
                Slider(value: $inkWidth, in: 1...8)
            }
            .disabled(tool == .eraser || tool == .lasso)

            HStack {
                Button { canvasController.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!canvasController.canUndo).accessibilityLabel("Undo")
                Button { canvasController.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!canvasController.canRedo).accessibilityLabel("Redo")
                Spacer()
                Button(role: .destructive) { canvasController.clear() } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Clear sketch")
            }
            .buttonStyle(.bordered)

            Toggle("Framing template", isOn: $showsFramingTemplate).font(.caption)
            #if !targetEnvironment(simulator)
            Toggle("Draw with finger", isOn: $allowsFingerDrawing).font(.caption)
            #endif
        }
    }

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHOT LIST").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Text("\(state.completedShotCount)/\(state.shotList.count)").font(.caption2.monospacedDigit())
            }

            ForEach(state.shotList) { item in
                ShotChecklistRow(item: item, isActive: item.id == state.activeShot?.id,
                                 onToggle: { state.toggleCompleted(item.id) },
                                 onSelect: { state.activateShot(item.id) })
            }

            HStack {
                Button("Add", systemImage: "plus") { state.addShot() }
                Spacer()
                Button("Done → Next", systemImage: "checkmark.circle") { state.completeActiveShotAndAdvance() }
                    .disabled(state.activeShot == nil)
            }
            .font(.caption)
            .buttonStyle(.bordered)

            Toggle("Attach sketch automatically", isOn: $autoAttach).font(.caption)
            if !autoAttach {
                Button("Attach sketch to shot", systemImage: "paperclip") { state.attachSketchToActiveShot() }
                    .font(.caption).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// One checklist row: a big tick target on the leading edge (Pencil- and thumb-friendly),
/// the title, and a sketch indicator.
struct ShotChecklistRow: View {
    let item: ShotListItem
    let isActive: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? .green : .white.opacity(0.7))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark \(item.title) not done" : "Mark \(item.title) done")

            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
                        .strikethrough(item.isCompleted)
                    Text(item.cameraLens.focalLength).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if item.sketchData != nil {
                Image(systemName: "scribble").font(.caption).foregroundStyle(.yellow)
                    .accessibilityLabel("Has sketch")
            }
        }
        .padding(6)
        .background(isActive ? Color.yellow.opacity(0.15) : .clear, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? .yellow.opacity(0.6) : .clear))
    }
}

#Preview("Pencil shot list") {
    PencilShotListView(state: StudioSessionState())
}
