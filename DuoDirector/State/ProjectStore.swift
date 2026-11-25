import Foundation
import Observation

// =====================================================================================
//  ProjectStore (Phase 5): saves and restores the creator's work across launches
//
//  WHAT IS SAVED
//    Script, shot list (including PencilKit sketch data), active shot, every TakeRecord,
//    every TakeMarker, the next take number, and the capture/prompter/overlay preferences.
//
//  WHY A CODABLE DOCUMENT AND NOT SWIFTDATA
//    The README candidate said SwiftData. Everything here is already a Codable value
//    type, owned by one @Observable state object and edited as whole arrays (reorders,
//    sketches). A single atomically-written JSON document gives:
//      • no second model layer to keep in sync with StudioSessionState,
//      • no schema migrations (new optional fields decode as nil),
//      • a human-readable file you can inspect in Files › DuoDirector.
//    If projects ever need querying across many sessions, move TakeRecord/TakeMarker to
//    SwiftData @Model types then. The document format is versioned for that.
//
//  HOW
//    • `load()` once at launch, before the engine starts.
//    • Autosave: withObservationTracking over the saved fields, debounced to 1 s, written
//      off the main actor with `.atomic`. Also `saveNow()` when the app backgrounds.
//    • Demo Mode content is NEVER saved. While `isDemoMode` is on, autosave is skipped;
//      turning it off restores the real content, which then saves normally.
//    • File URLs are re-linked on load. The app container path changes between installs
//      and updates, so only the file NAME is trusted and it's resolved against today's
//      Documents/Takes.
// =====================================================================================

/// On-disk format. Every field is optional on decode so older/newer files still load.
struct ProjectDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var formatVersion: Int = ProjectDocument.currentVersion
    var savedAt: Date = Date()
    /// Phase 6: which device wrote this (iCloud merge ignores its own echoes).
    var savedByDevice: String?
    var scriptText: String?
    var shotList: [ShotListItem]?
    var activeShotID: ShotListItem.ID?
    var takes: [TakeRecord]?
    var markers: [TakeMarker]?
    var nextTakeNumber: Int?
    /// Phase 7: deletion tombstones (id → when). Pruned after `tombstoneLifetime`.
    var deletedTakeIDs: [UUID: Date]?
    var deletedMarkerIDs: [UUID: Date]?

    /// Long enough for a device that's been offline a while to learn about deletions.
    static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600
    var preferences: Preferences?

    struct Preferences: Codable, Equatable, Sendable {
        var resolution: ResolutionPreset?
        var frameRate: FrameRatePreset?
        var codec: VideoCodecPreset?
        var dolbyVision: Bool?
        var captureMode: CaptureMode?
        var dualExportStyle: DualExportStyle?
        var pipCorner: PiPCorner?
        var prompterFontSize: Double?
        var prompterScrollSpeed: Double?
        var prompterMirrored: Bool?
        var mirrorOuterPreview: Bool?
        var countdownSeconds: Int?
        var show16x9Guide: Bool?
        var show9x16Guide: Bool?
        var showThirdsGrid: Bool?
        var gridOpacity: Double?
        var zebraThreshold: Double?
        var showHistogram: Bool?
        var audioGain: Float?
        var autoRenderComposites: Bool?
    }
}

@MainActor
final class ProjectStore {

    let state: StudioSessionState
    let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var isObserving = false
    /// Last document written, so identical autosaves are skipped.
    private var lastSaved: ProjectDocument?
    /// Phase 6: called after every successful local save (CloudSyncController pushes it).
    var onSaved: ((ProjectDocument) -> Void)?

    /// Stable per-install identifier used to tag saved documents.
    static let deviceID: String = {
        let key = "DuoDirectorDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "DuoDirector/project.json")
    }

    init(state: StudioSessionState, fileURL: URL = ProjectStore.defaultURL) {
        self.state = state
        self.fileURL = fileURL
    }

    // MARK: Load

    /// Restores the saved project into `state`. Missing file = first launch, keep samples.
    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(ProjectDocument.self, from: data)
            Self.apply(document, to: state, takesDirectory: CaptureSessionController.takesDirectory)
            lastSaved = document
            state.lastPersistedAt = document.savedAt
        } catch {
            // Keep the unreadable file for support instead of overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            state.showBanner("Couldn't read the saved project. A copy was kept as \(backup.lastPathComponent).", seconds: nil)
        }
    }

    // MARK: Save

    func startAutosave() {
        guard !isObserving else { return }
        isObserving = true
        observe()
    }

    private func observe() {
        withObservationTracking {
            // Touch every saved field (and isDemoMode) so any change re-arms the save.
            _ = Self.document(from: state)
            _ = state.isDemoMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleSave()
                self?.observe()
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    /// Immediate save (app backgrounding). Skipped in Demo Mode.
    func saveNow() {
        saveTask?.cancel()
        Task { await save() }
    }

    private func save() async {
        guard !state.isDemoMode else { return }
        var document = Self.document(from: state)
        // Compare without the timestamp so unchanged content isn't rewritten.
        if var previous = lastSaved {
            previous.savedAt = document.savedAt
            if previous == document { return }
        }
        document.savedAt = Date()
        document.savedByDevice = Self.deviceID
        let url = fileURL
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            encoded = try encoder.encode(document)
        } catch { return }
        let written: Bool = await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch { return false }
        }.value
        if written {
            lastSaved = document
            state.lastPersistedAt = document.savedAt
            onSaved?(document)
        }
    }

    /// Phase 6: the current document as last saved (for merging with iCloud).
    var currentDocument: ProjectDocument {
        var document = Self.document(from: state)
        document.savedAt = state.lastPersistedAt ?? .distantPast
        document.savedByDevice = Self.deviceID
        return document
    }

    /// Phase 6: applies a merged document that came from iCloud, then saves it locally
    /// (the save is what makes it durable on this device; it won't echo back because the
    /// merged content then equals what iCloud has).
    func applyMerged(_ document: ProjectDocument) {
        guard !state.isRecording, !state.isDemoMode else { return }
        Self.apply(document, to: state, takesDirectory: CaptureSessionController.takesDirectory)
        scheduleSave()
    }

    // MARK: Pure mapping (unit-tested)

    static func document(from state: StudioSessionState) -> ProjectDocument {
        ProjectDocument(
            scriptText: state.scriptText,
            shotList: state.shotList,
            activeShotID: state.activeShotID,
            // A take that's still rolling has no files yet; it's saved when it finishes.
            takes: state.takes.filter { !(state.isRecording && $0.takeNumber == state.takeNumber) },
            markers: state.chapterMarkers,
            nextTakeNumber: state.takeNumber,
            deletedTakeIDs: state.deletedTakeIDs.isEmpty ? nil : state.deletedTakeIDs,
            deletedMarkerIDs: state.deletedMarkerIDs.isEmpty ? nil : state.deletedMarkerIDs,
            preferences: .init(
                resolution: state.resolution, frameRate: state.frameRate, codec: state.preferredCodec,
                dolbyVision: state.isDolbyVisionEnabled, captureMode: state.captureMode,
                dualExportStyle: state.dualExportStyle, pipCorner: state.pipCorner,
                prompterFontSize: state.prompterFontSize, prompterScrollSpeed: state.prompterScrollSpeed,
                prompterMirrored: state.prompterMirrored, mirrorOuterPreview: state.mirrorOuterPreview,
                countdownSeconds: state.countdownSeconds, show16x9Guide: state.show16x9Guide,
                show9x16Guide: state.show9x16Guide, showThirdsGrid: state.showThirdsGrid,
                gridOpacity: state.gridOpacity, zebraThreshold: state.zebraThreshold,
                showHistogram: state.showHistogram, audioGain: state.audioGain,
                autoRenderComposites: state.autoRenderComposites))
    }

    static func apply(_ document: ProjectDocument, to state: StudioSessionState, takesDirectory: URL) {
        if let script = document.scriptText { state.scriptText = script }
        if let shots = document.shotList, !shots.isEmpty {
            state.shotList = shots
            state.activeShotID = shots.contains { $0.id == document.activeShotID } ? document.activeShotID : shots.first?.id
        }
        if let takes = document.takes {
            state.takes = takes
                .map { relink($0, into: takesDirectory) }
                // Drop takes that never produced anything (app killed before the first frame).
                .filter { $0.duration > 0 || $0.rearFileURL != nil || $0.sidecarJSONURL != nil }
        }
        if let markers = document.markers { state.chapterMarkers = markers }
        // Phase 7: tombstones (pruned) and never show anything they cover.
        let cutoff = Date().addingTimeInterval(-ProjectDocument.tombstoneLifetime)
        state.deletedTakeIDs = (document.deletedTakeIDs ?? [:]).filter { $0.value > cutoff }
        state.deletedMarkerIDs = (document.deletedMarkerIDs ?? [:]).filter { $0.value > cutoff }
        state.takes.removeAll { state.deletedTakeIDs[$0.id] != nil }
        state.chapterMarkers.removeAll { state.deletedMarkerIDs[$0.id] != nil }
        let highestTake = state.takes.map(\.takeNumber).max() ?? 0
        state.takeNumber = max(document.nextTakeNumber ?? 1, highestTake + 1)

        guard let p = document.preferences else { return }
        if let v = p.resolution { state.resolution = v }
        if let v = p.frameRate { state.frameRate = v }
        if let v = p.codec { state.preferredCodec = v }
        if let v = p.dolbyVision { state.isDolbyVisionEnabled = v }
        // Capture mode is restored as a wish; CameraEngine.start() drops back to solo if
        // MultiCam isn't supported on this device.
        if let v = p.captureMode { state.captureMode = v }
        if let v = p.dualExportStyle { state.dualExportStyle = v }
        if let v = p.pipCorner { state.pipCorner = v }
        if let v = p.prompterFontSize { state.prompterFontSize = v }
        if let v = p.prompterScrollSpeed { state.setPrompterScrollSpeed(v) }
        if let v = p.prompterMirrored { state.prompterMirrored = v }
        if let v = p.mirrorOuterPreview { state.mirrorOuterPreview = v }
        if let v = p.countdownSeconds { state.countdownSeconds = v }
        if let v = p.show16x9Guide { state.show16x9Guide = v }
        if let v = p.show9x16Guide { state.show9x16Guide = v }
        if let v = p.showThirdsGrid { state.showThirdsGrid = v }
        if let v = p.gridOpacity { state.gridOpacity = v }
        if let v = p.zebraThreshold { state.zebraThreshold = v }
        if let v = p.showHistogram { state.showHistogram = v }
        if let v = p.audioGain { state.audioGain = v }
        if let v = p.autoRenderComposites { state.autoRenderComposites = v }
    }

    /// Keeps only the file NAME and resolves it in today's Takes folder.
    static func relink(_ take: TakeRecord, into directory: URL) -> TakeRecord {
        func fix(_ url: URL?) -> URL? { url.map { directory.appending(path: $0.lastPathComponent) } }
        var take = take
        take.rearFileURL = fix(take.rearFileURL)
        take.innerFileURL = fix(take.innerFileURL)
        take.sidecarJSONURL = fix(take.sidecarJSONURL)
        take.sidecarFCPXMLURL = fix(take.sidecarFCPXMLURL)
        take.compositeFileURL = fix(take.compositeFileURL)
        return take
    }
}
