import SwiftUI

// =====================================================================================
//  GoLiveSheet (Phase 8): destinations, stream key, quality, Go Live / End
//
//  The stream key is entered in a SecureField and written straight to the Keychain.
//  The sheet only ever shows it redacted (•••••abcd), so it can't leak into a
//  screenshot, a screen recording, or the remote producer's preview.
// =====================================================================================

struct GoLiveSheet: View {
    let live: LiveStreamController
    let state: StudioSessionState
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var editingKey = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                destinationSection
                if let d = live.selectedDestination { serverSection(d) }
                Section {
                    Picker("Quality", selection: Binding(get: { live.quality }, set: { live.quality = $0 })) {
                        ForEach(LiveQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(state.liveState.isActive)
                } footer: {
                    Text("Use 1080p60 only on a strong connection. Heat lowers the bitrate automatically.")
                }
                actionSection
            }
            .navigationTitle("Go Live")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        Section {
            HStack {
                LivePill(state: state, showsIdle: true)
                Spacer()
                if case .live(let since) = state.liveState {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(CameraEngine.timecode(ctx.date.timeIntervalSince(since))).monospacedDigit()
                    }
                }
            }
            if state.liveState.isLive {
                LabeledContent("Upload", value: String(format: "%.1f Mbps", Double(state.liveStats.sentBitsPerSecond) / 1_000_000))
                if state.liveStats.droppedFrames > 0 {
                    LabeledContent("Dropped frames", value: "\(state.liveStats.droppedFrames)")
                }
            }
            if case .failed(let message) = state.liveState {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if state.isDemoMode || state.sourceMode == .mock {
                Label("Demo/mock camera: the stream is simulated and nothing is sent.", systemImage: "wand.and.stars")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var destinationSection: some View {
        Section("Destination") {
            ForEach(live.destinations) { d in
                Button {
                    live.selectedDestinationID = d.id
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text(live.hasKey(for: d) ? String(localized: "Key saved") : String(localized: "No key"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if d.id == live.selectedDestinationID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(state.liveState.isActive)
                .swipeActions {
                    Button("Delete", role: .destructive) { live.remove(d) }
                }
            }
            Menu("Add destination", systemImage: "plus") {
                ForEach(StreamDestination.Kind.allCases, id: \.self) { kind in
                    Button(kind.label) { live.addDestination(kind) }
                }
            }
            .disabled(state.liveState.isActive)
        }
    }

    private func serverSection(_ d: StreamDestination) -> some View {
        Section {
            TextField("Name", text: Binding(get: { d.name }, set: { var c = d; c.name = $0; live.update(c) }))
            TextField("rtmps://server/app", text: Binding(get: { d.serverURL }, set: { var c = d; c.serverURL = $0; live.update(c) }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            if editingKey {
                SecureField("Stream key", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { saveKey(d) }
                Button("Save key") { saveKey(d) }.disabled(keyDraft.isEmpty)
            } else {
                LabeledContent("Stream key", value: live.redactedKey(for: d) ?? String(localized: "Not set"))
                Button(live.hasKey(for: d) ? "Replace key" : "Add key") { keyDraft = ""; editingKey = true }
            }
        } header: {
            Text("Server")
        } footer: {
            Text(d.usesTLS ? "RTMPS: the stream is encrypted on the way to the platform. The key stays in this phone's Keychain."
                           : "Plain RTMP isn't encrypted. Prefer rtmps:// when your platform offers it.")
        }
        .disabled(state.liveState.isActive)
    }

    private var actionSection: some View {
        Section {
            if state.liveState.isActive {
                Button("End stream", systemImage: "stop.circle.fill", role: .destructive) { live.endLive() }
            } else {
                Button("Go Live", systemImage: "dot.radiowaves.left.and.right") { live.goLive() }
                    .disabled(live.blockReason != nil)
            }
        } footer: {
            if !state.liveState.isActive, let reason = live.blockReason { Text(reason) }
        }
    }

    private func saveKey(_ d: StreamDestination) {
        live.setKey(keyDraft, for: d)
        keyDraft = ""
        editingKey = false
    }
}

/// LIVE / CONNECTING / RECONNECTING tally used on the inner display, cover monitor and sheet.
struct LivePill: View {
    let state: StudioSessionState
    var showsIdle = false

    var body: some View {
        switch state.liveState {
        case .live:
            pill("LIVE", "dot.radiowaves.left.and.right", .red, .white)
        case .connecting:
            pill(String(localized: "Connecting…"), "antenna.radiowaves.left.and.right", .yellow, .black)
        case .reconnecting(let attempt):
            pill(String(localized: "Reconnecting (\(attempt))"), "arrow.triangle.2.circlepath", .orange, .black)
        case .idle, .failed:
            if showsIdle { pill(String(localized: "Off air"), "antenna.radiowaves.left.and.right.slash", .gray, .white) }
        }
    }

    private func pill(_ text: String, _ symbol: String, _ bg: Color, _ fg: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(fg)
            .background(bg, in: .capsule)
            .accessibilityLabel(text == "LIVE" ? String(localized: "Streaming live") : text)
    }
}
