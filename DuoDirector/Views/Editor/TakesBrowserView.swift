import AVKit
import SwiftUI

// =====================================================================================
//  TakesBrowserView (Phase 5): every take, with playback and good-take filtering
//
//  • Filters: All · Good (4★+ take, or any 5★ "Good take" marker) · Unrated · Dual-Cam.
//    Search matches shot titles and marker notes.
//  • Detail: AVKit playback. Dual-Cam takes play as a LIVE composite. The same
//    AVMutableComposition + AVVideoComposition the renderer exports is handed to
//    AVPlayerItem, so Guest and Host play in sync (innerStartOffset applied) without
//    rendering anything. A picker switches PiP / Split / Guest only / Host only.
//  • Markers come from the project and can be recovered from the .mov's own
//    timed-metadata track. Tapping one seeks the player.
//  • Rate, render composite (only when cool and charging), share files + sidecars, delete.
// =====================================================================================

struct TakesBrowserView: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", good = "Good", unrated = "Unrated", dual = "Dual-Cam"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .all
    @State private var search = ""

    var body: some View {
        List {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if filtered.isEmpty {
                ContentUnavailableView(state.takes.isEmpty ? "No takes yet" : "No matching takes",
                                       systemImage: "film.stack",
                                       description: Text(state.takes.isEmpty
                                                         ? "Record a take and it shows up here with its markers."
                                                         : "Try another filter."))
            }
            ForEach(filtered) { take in
                NavigationLink {
                    TakeDetailView(state: state, engine: engine, takeID: take.id)
                } label: {
                    TakeRow(take: take, markers: state.markers(forTake: take.takeNumber),
                            progress: state.compositeRenderProgress[take.id])
                }
                .swipeActions {
                    if let engine {
                        Button("Delete", systemImage: "trash", role: .destructive) { engine.deleteTake(take.id) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Shot or marker note")
        .accessibilityIdentifier("takesBrowser")
    }

    /// Newest first. Pure filtering lives in `TakeFilter` (unit-tested).
    private var filtered: [TakeRecord] {
        TakeFilter.apply(filter, search: search, takes: state.takes, markers: state.chapterMarkers)
    }
}

/// Filtering rules, kept pure for tests.
enum TakeFilter {
    static func isGood(_ take: TakeRecord, markers: [TakeMarker]) -> Bool {
        take.rating >= 4 || markers.contains { $0.takeNumber == take.takeNumber && $0.isGoodTake }
    }

    static func apply(_ filter: TakesBrowserView.Filter, search: String,
                      takes: [TakeRecord], markers: [TakeMarker]) -> [TakeRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return takes
            .filter { take in
                switch filter {
                case .all: true
                case .good: isGood(take, markers: markers)
                case .unrated: take.rating == 0
                case .dual: take.captureMode == .dualPodcastMultiCam
                }
            }
            .filter { take in
                guard !query.isEmpty else { return true }
                if take.shotTitle?.lowercased().contains(query) == true { return true }
                return markers.contains { $0.takeNumber == take.takeNumber && $0.note.lowercased().contains(query) }
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Row

private struct TakeRow: View {
    let take: TakeRecord
    let markers: [TakeMarker]
    let progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: take.captureMode.symbol)
                .font(.title3)
                .foregroundStyle(take.captureMode == .dualPodcastMultiCam ? .cyan : .yellow)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Take \(take.takeNumber)").font(.headline)
                    if let title = take.shotTitle { Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                HStack(spacing: 8) {
                    Text(CameraEngine.timecode(take.duration)).monospacedDigit()
                    Text(take.startedAt, format: .dateTime.month().day().hour().minute())
                    if !markers.isEmpty { Label("\(markers.count)", systemImage: "mappin.and.ellipse") }
                    if take.compositeFileURL != nil { Label("Composite", systemImage: "rectangle.inset.bottomtrailing.filled") }
                    if !take.hasMediaOnDisk { Label("No video file", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let progress { ProgressView(value: progress) { Text("Rendering composite…").font(.caption2) } }
            }
            Spacer()
            Text(take.rating == 0 ? "—" : String(repeating: "★", count: take.rating))
                .foregroundStyle(.yellow)
                .accessibilityLabel(take.rating == 0 ? "Unrated" : "\(take.rating) stars")
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct TakeDetailView: View {
    @Bindable var state: StudioSessionState
    let engine: CameraEngine?
    let takeID: TakeRecord.ID

    enum PlaybackLayout: String, CaseIterable, Identifiable {
        case pip = "PiP", split = "Split", guest = "Guest", host = "Host"
        var id: String { rawValue }
    }

    @State private var player = AVPlayer()
    @State private var layout: PlaybackLayout = .pip
    @State private var loadError: String?
    @State private var recoveredCount: Int?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var take: TakeRecord? { state.takes.first { $0.id == takeID } }

    var body: some View {
        if let take {
            List {
                Section {
                    playerSection(for: take)
                    if take.captureMode == .dualPodcastMultiCam && take.innerFileURL != nil {
                        Picker("Playback", selection: $layout) {
                            ForEach(PlaybackLayout.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Rating") {
                    HStack {
                        ForEach(1...5, id: \.self) { star in
                            Button { setRating(star == take.rating ? 0 : star) } label: {
                                Image(systemName: star <= take.rating ? "star.fill" : "star")
                                    .font(.title2).foregroundStyle(.yellow).frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(star) stars")
                        }
                    }
                }

                markersSection(take)
                actionsSection(take)
                infoSection(take)
            }
            .navigationTitle("Take \(take.takeNumber)")
            .task(id: "\(take.id)-\(layout.rawValue)-\(take.compositeFileURL?.path ?? "")") { await loadPlayer(take) }
            .onDisappear { player.pause() }
            .confirmationDialog("Delete take \(take.takeNumber)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete files and markers", role: .destructive) {
                    engine?.deleteTake(take.id)
                    dismiss()
                }
            } message: {
                Text("Removes the camera files, sidecars and composite from DuoDirector. Copies already in Photos stay in Photos.")
            }
        } else {
            ContentUnavailableView("Take deleted", systemImage: "film")
        }
    }

    @ViewBuilder
    private func playerSection(for take: TakeRecord) -> some View {
        if take.hasMediaOnDisk {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .listRowInsets(EdgeInsets())
                .overlay {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle").font(.caption)
                            .padding(8).background(.ultraThinMaterial, in: .capsule)
                    }
                }
        } else {
            ContentUnavailableView("No video file", systemImage: "film",
                                   description: Text(state.sourceMode == .mock
                                                     ? "Simulator takes have markers and sidecars but no video."
                                                     : "The camera files for this take aren't in Files › DuoDirector › Takes."))
        }
    }

    private func markersSection(_ take: TakeRecord) -> some View {
        let markers = state.markers(forTake: take.takeNumber)
        return Section {
            if markers.isEmpty { Text("No markers").foregroundStyle(.secondary) }
            ForEach(markers) { marker in
                Button {
                    player.seek(to: CMTime(seconds: marker.timestamp, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                } label: {
                    HStack {
                        Text(marker.stars).foregroundStyle(.yellow).font(.caption)
                        Text(marker.note).foregroundStyle(.primary)
                        Spacer()
                        Text(CameraEngine.timecode(marker.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if let engine, take.rearFileURL != nil, take.hasMediaOnDisk {
                Button("Recover markers from the video file", systemImage: "arrow.down.doc") {
                    Task { recoveredCount = await engine.recoverMarkers(for: take.id) }
                }
                if let recoveredCount {
                    Text(recoveredCount == 0 ? "No extra markers in the file." : "Recovered \(recoveredCount) marker(s).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Markers")
        } footer: {
            Text("Tap a marker to jump to it. Markers are also written into the .mov and both sidecars.")
        }
    }

    @ViewBuilder
    private func actionsSection(_ take: TakeRecord) -> some View {
        Section("Export") {
            let files = [take.rearFileURL, take.innerFileURL, take.compositeFileURL, take.sidecarJSONURL, take.sidecarFCPXMLURL]
                .compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !files.isEmpty {
                ShareLink(items: files) { Label("Share \(files.count) file(s)", systemImage: "square.and.arrow.up") }
            }
            if let engine, take.captureMode == .dualPodcastMultiCam, take.innerFileURL != nil, take.hasMediaOnDisk {
                if let progress = state.compositeRenderProgress[take.id] {
                    ProgressView(value: progress) { Text("Rendering composite…") }
                    Button("Stop render", systemImage: "stop.circle", role: .destructive) { engine.cancelCompositeRender() }
                } else {
                    let verdict = engine.compositeRenderVerdict
                    Button(take.compositeFileURL == nil ? "Render composite on iPhone" : "Render composite again",
                           systemImage: "square.stack.3d.down.right") {
                        engine.renderComposite(takeID: take.id,
                                               style: layout == .split ? .splitScreenComposite : .pictureInPicture)
                    }
                    .disabled(!verdict.isAllowed || engine.isRenderingComposite)
                    if case .blocked(let reason) = verdict {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if engine != nil {
                Button("Delete take", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(state.isRecording && take.takeNumber == state.takeNumber)
            }
        }
    }

    private func infoSection(_ take: TakeRecord) -> some View {
        Section("Details") {
            LabeledContent("Mode", value: take.captureMode.label)
            if take.captureMode == .dualPodcastMultiCam {
                LabeledContent("Layout", value: take.exportStyle.label)
                LabeledContent("Host sync offset", value: String(format: "%+.3f s", take.innerStartOffset))
            }
            LabeledContent("Duration", value: CameraEngine.timecode(take.duration))
            LabeledContent("Started", value: take.startedAt.formatted(date: .abbreviated, time: .standard))
            LabeledContent("Session ID", value: String(take.sessionIdentifier.prefix(8)) + "…")
        }
    }

    // MARK: Playback

    /// Dual-Cam PiP/Split: live AVVideoComposition (exactly what the renderer exports).
    /// Rendered composite on disk: play that file. Otherwise: one camera file.
    private func loadPlayer(_ take: TakeRecord) async {
        loadError = nil
        let dual = take.captureMode == .dualPodcastMultiCam && take.innerFileURL != nil
        let item: AVPlayerItem?
        switch (dual, layout) {
        case (true, .pip), (true, .split):
            do {
                let style: DualExportStyle = layout == .split ? .splitScreenComposite : .pictureInPicture
                let built = try await CompositeRenderer.makeComposition(take: take, style: style)
                let playerItem = AVPlayerItem(asset: built.composition)
                playerItem.videoComposition = built.videoComposition
                item = playerItem
            } catch {
                loadError = error.localizedDescription
                item = take.rearFileURL.map { AVPlayerItem(url: $0) }
            }
        case (true, .host):
            item = take.innerFileURL.map { AVPlayerItem(url: $0) }
        default:
            item = take.rearFileURL.map { AVPlayerItem(url: $0) }
        }
        player.replaceCurrentItem(with: item)
    }

    private func setRating(_ stars: Int) {
        guard let index = state.takes.firstIndex(where: { $0.id == takeID }) else { return }
        state.takes[index].rating = stars
        // Keep the sidecars in step with the new rating.
        let take = state.takes[index]
        guard take.sidecarJSONURL != nil else { return }
        let settings = TakeSidecarExporter.Settings(resolution: state.resolution, frameRate: state.frameRate.rawValue,
                                                    codec: state.preferredCodec, dolbyVision: state.isDolbyVisionActive)
        _ = try? TakeSidecarExporter.write(take: take, markers: state.markers(forTake: take.takeNumber), settings: settings)
    }
}
