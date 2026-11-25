import SwiftUI
import CoreImage

// =====================================================================================
//  GuestSheet (Phase 9): open a guest room, invite, choose how the guest appears
// =====================================================================================

struct GuestSheet: View {
    let guests: GuestSessionController
    let state: StudioSessionState
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if state.guestState.isInRoom { inviteSection }
                streamSection
                setupSection
                actionSection
            }
            .navigationTitle("Remote guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            HStack {
                GuestPill(state: state, showsIdle: true)
                Spacer()
            }
            if state.guestState.guestName != nil {
                GuestPreviewTile(frames: guests.pipeline.frames)
                    .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
                    .listRowInsets(EdgeInsets())
            }
            if case .failed(let message) = state.guestState {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if guests.isMock {
                Label("Demo/mock camera: a simulated guest joins and nothing is sent.", systemImage: "wand.and.stars")
                    .font(.footnote).foregroundStyle(.orange)
            } else if !GuestRoomFactory.isLiveKitLinked {
                Label("This build doesn't include LiveKit, so guests are simulated. Build with project-guests.yml to enable them.",
                      systemImage: "shippingbox")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } footer: {
            if state.guestState.isInRoom { Text("Wear headphones: your guest plays through the phone and would echo into your mic.") }
        }
    }

    private var inviteSection: some View {
        Section {
            if let link = guests.inviteLink {
                ShareLink(item: link, subject: Text("Join me on DuoDirector"),
                          message: Text("Open this link to join as my guest. It works in any browser.")) {
                    Label("Send invite link", systemImage: "square.and.arrow.up")
                }
            }
            Button(guests.inviteLink == nil ? "Create invite link" : "New invite link", systemImage: "link.badge.plus") {
                Task { await guests.makeInvite() }
            }
            .disabled(guests.isMakingInvite)
        } header: {
            Text("Invite")
        } footer: {
            Text("The link holds a short-lived pass to this room. Send it only to your guest.")
        }
    }

    private var streamSection: some View {
        Section("In the stream") {
            Toggle("Show guest in Go Live stream", isOn: Binding(get: { state.includeGuestInStream },
                                                                 set: { guests.setIncludeInStream($0) }))
            Picker("Layout", selection: Binding(get: { state.guestLayout }, set: { guests.setLayout($0) })) {
                ForEach(GuestLayout.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .disabled(!state.includeGuestInStream)
            Text("Your recording stays camera-only. The guest is added to the live stream.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var setupSection: some View {
        Section {
            TextField("Room name", text: binding(\.roomName))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Your name", text: binding(\.hostName))
            TextField("Token endpoint (https://…)", text: binding(\.tokenEndpoint))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                TextField("LiveKit server (wss://…)", text: binding(\.serverURL))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Development token (not saved)", text: Binding(get: { guests.manualHostToken },
                                                                           set: { guests.manualHostToken = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } header: {
            Text("LiveKit room")
        } footer: {
            Text("Your token endpoint signs short-lived passes with your LiveKit API secret, which never goes in the app. LiveKit Cloud can host one for you.")
        }
        .disabled(state.guestState.isInRoom || state.guestState == .connecting)
    }

    private var actionSection: some View {
        Section {
            if state.guestState.isInRoom || state.guestState == .connecting {
                Button("Close room", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { guests.closeRoom() }
            } else {
                Button("Open guest room", systemImage: "person.crop.circle.badge.plus") { guests.openRoom() }
                    .disabled(guests.blockReason != nil)
            }
        } footer: {
            if !state.guestState.isInRoom, let reason = guests.blockReason { Text(reason) }
        }
    }

    private func binding(_ key: WritableKeyPath<GuestRoomConfig, String>) -> Binding<String> {
        Binding(get: { guests.config[keyPath: key] },
                set: { var c = guests.config; c[keyPath: key] = $0; guests.updateConfig(c) })
    }
}

/// Guest status tally, next to the LIVE pill.
struct GuestPill: View {
    let state: StudioSessionState
    var showsIdle = false

    var body: some View {
        switch state.guestState {
        case .connected(let name): pill(name, "person.wave.2.fill", .green, .black)
        case .waiting: pill(String(localized: "Room open · waiting"), "person.crop.circle.badge.clock", .teal, .black)
        case .connecting: pill(String(localized: "Opening room…"), "person.crop.circle", .yellow, .black)
        case .reconnecting: pill(String(localized: "Guest reconnecting"), "arrow.triangle.2.circlepath", .orange, .black)
        case .idle, .failed:
            if showsIdle { pill(String(localized: "No guest"), "person.crop.circle.badge.xmark", .gray, .white) }
        }
    }

    private func pill(_ text: String, _ symbol: String, _ bg: Color, _ fg: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.bold()).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(fg).background(bg, in: .capsule)
    }
}

/// The guest's latest frame at 15 fps. Reads the shared frame store, so it works the
/// same with LiveKit and the mock room.
struct GuestPreviewTile: View {
    let frames: GuestFrameStore
    private static let context = CIContext()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            if let pixels = frames.freshFrame(),
               let cg = Self.context.createCGImage(CIImage(cvPixelBuffer: pixels),
                                                   from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels),
                                                                height: CVPixelBufferGetHeight(pixels))) {
                Image(decorative: cg, scale: 1).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.black
                    Label("Guest video paused", systemImage: "video.slash").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityLabel("Guest video")
    }
}
