import SwiftUI

/// Pre-shoot planning sheet: script, shot list, Apple Pencil storyboards, and take markers.
/// Edits write straight into StudioSessionState, so both teleprompters and the shot HUD
/// update immediately. (Phase 3: the storyboard tab is PencilShotListView.
/// Phase 5: the Takes tab is TakesBrowserView, with playback, filters and composites.)
struct ScriptShotListEditorView: View {
    @Bindable var state: StudioSessionState
    /// Needed by the takes browser for delete / render / marker recovery. Optional so
    /// previews can show the editor without an engine.
    var engine: CameraEngine? = nil
    var initialPane: Pane = .script
    @Environment(\.dismiss) private var dismiss

    enum Pane: String, CaseIterable, Identifiable {
        case script = "Script", shots = "Shot List", storyboard = "Storyboard", takes = "Takes"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .script
    @State private var didApplyInitialPane = false

    var body: some View {
        NavigationStack {
            Group {
                switch pane {
                case .script: ScriptPane(state: state)
                case .shots: ShotListPane(state: state)
                case .storyboard: PencilShotListView(state: state, showsCloseButton: false)
                case .takes: TakesBrowserView(state: state, engine: engine)
                }
            }
            .onAppear {
                if !didApplyInitialPane { pane = initialPane; didApplyInitialPane = true }
            }
            .navigationTitle(pane.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $pane) {
                        ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Script

private struct ScriptPane: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $state.scriptText)
                .font(.system(size: 20, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding()
            Divider()
            HStack(alignment: .top, spacing: 24) {
                PrompterSettingsControls(state: state)
                VStack(alignment: .leading) {
                    Text("~\(readingTime) read").font(.caption)
                    Text("\(wordCount) words").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var wordCount: Int { state.scriptText.split { $0.isWhitespace }.count }
    private var readingTime: String {
        let seconds = Int(Double(wordCount) / 150 * 60)   // ~150 wpm on camera
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

// MARK: - Shot list

private struct ShotListPane: View {
    @Bindable var state: StudioSessionState

    var body: some View {
        List {
            ForEach($state.shotList) { $item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { item.isCompleted.toggle() } label: {
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCompleted ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        TextField("Shot title", text: $item.title).font(.headline)
                        Picker("Lens", selection: $item.cameraLens) {
                            ForEach(LensOption.allCases) { Text("\($0.label) \($0.focalLength)").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        if item.sketchData != nil { Image(systemName: "scribble").foregroundStyle(.yellow) }
                    }
                    TextField("Framing note", text: $item.framingNote, axis: .vertical).font(.callout)
                }
                .padding(.vertical, 4)
                .listRowBackground(item.id == state.activeShot?.id ? Color.yellow.opacity(0.12) : nil)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { state.activateShot(item.id) }
            }
            .onMove { state.shotList.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { state.shotList.remove(atOffsets: $0) }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Add shot", systemImage: "plus") { state.addShot() }
            }
            ToolbarItem(placement: .bottomBar) { EditButton() }
        }
    }
}

#Preview {
    ScriptShotListEditorView(state: StudioSessionState())
}
