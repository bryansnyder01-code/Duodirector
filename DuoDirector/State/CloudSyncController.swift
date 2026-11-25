import Foundation
import Observation

// =====================================================================================
//  CloudSyncController (Phase 6): iCloud Drive sync for the project and (optionally) takes
//
//  WHERE
//    The app's iCloud Drive container `iCloud.com.duodirector.app`, published as the
//    "DuoDirector" folder in iCloud Drive (NSUbiquitousContainers in Info.plist):
//      DuoDirector/Project/project.json    ← the ProjectDocument (script, shots, takes, markers)
//      DuoDirector/Takes/…                 ← camera files, sidecars and composites (opt-in)
//
//  HOW
//    • Push: after every local save (ProjectStore.onSaved), a coordinated write
//      (NSFileCoordinator) of project.json into the container.
//    • Pull: an NSMetadataQuery watches project.json in the ubiquitous Documents scope.
//      When another device's version arrives it is downloaded, read with a coordinated
//      read, MERGED with local (CloudMerge, pure and tested) and applied. Never while
//      recording or in Demo Mode; a pending pull runs when the take ends.
//    • Takes (opt-in, they're big): each finished take's files are copied into
//      DuoDirector/Takes. Other devices relink missing local files to those copies and ask
//      iCloud to download them.
//
//  MERGE RULES (CloudMerge)
//    • Script, shot list, active shot, preferences: the newer document wins as a whole.
//    • Takes and markers: union by id. For the same take, the newer document's record
//      wins (ratings follow the latest edit).
//    • Phase 7 deletions: tombstones (id → deletion date) from both sides are unioned
//      (latest date kept), and anything they cover is removed from the merge. A device that
//      receives a tombstone also removes its LOCAL copies of that take's files (never the
//      Photos copies: the app has add-only Photos access). Tombstones expire after 90 days.
//    • Next take number: the max of both, so two devices never reuse a number.
//
//  Requires the iCloud capability (Documents) with container iCloud.com.duodirector.app.
//  See DuoDirector.entitlements and project.yml.
// =====================================================================================

/// Pure merge, unit-tested.
enum CloudMerge {
    static func merge(local: ProjectDocument, remote: ProjectDocument) -> ProjectDocument {
        let remoteIsNewer = remote.savedAt > local.savedAt
        var merged = remoteIsNewer ? remote : local
        let older = remoteIsNewer ? local : remote

        var takes: [TakeRecord.ID: TakeRecord] = [:]
        for take in older.takes ?? [] { takes[take.id] = take }
        for take in merged.takes ?? [] { takes[take.id] = take }          // newer wins
        merged.takes = takes.values.sorted { $0.takeNumber < $1.takeNumber }

        var markers: [TakeMarker.ID: TakeMarker] = [:]
        for marker in older.markers ?? [] { markers[marker.id] = marker }
        for marker in merged.markers ?? [] { markers[marker.id] = marker }
        merged.markers = markers.values.sorted { ($0.takeNumber, $0.timestamp) < ($1.takeNumber, $1.timestamp) }

        // Phase 7: deletions win over edits.
        let takeTombstones = (local.deletedTakeIDs ?? [:]).merging(remote.deletedTakeIDs ?? [:], uniquingKeysWith: max)
        let markerTombstones = (local.deletedMarkerIDs ?? [:]).merging(remote.deletedMarkerIDs ?? [:], uniquingKeysWith: max)
        merged.takes?.removeAll { takeTombstones[$0.id] != nil }
        merged.markers?.removeAll { markerTombstones[$0.id] != nil }
        merged.deletedTakeIDs = takeTombstones.isEmpty ? nil : takeTombstones
        merged.deletedMarkerIDs = markerTombstones.isEmpty ? nil : markerTombstones

        // Take numbers count deleted takes too, so a number is never reused.
        let highestTake = merged.takes?.map(\.takeNumber).max() ?? 0
        merged.nextTakeNumber = max(local.nextTakeNumber ?? 1, remote.nextTakeNumber ?? 1, highestTake + 1)
        merged.savedAt = max(local.savedAt, remote.savedAt)
        return merged
    }

    /// True when `remote` brings something this device hasn't seen.
    static func shouldApply(remote: ProjectDocument, local: ProjectDocument, deviceID: String) -> Bool {
        remote.savedByDevice != deviceID && remote.savedAt > local.savedAt
    }

    /// Takes present locally that the merge deleted (their local files get removed).
    static func takesDeleted(by merged: ProjectDocument, from local: ProjectDocument) -> [TakeRecord] {
        let tombstones = merged.deletedTakeIDs ?? [:]
        return (local.takes ?? []).filter { tombstones[$0.id] != nil }
    }
}

@MainActor
@Observable
final class CloudSyncController {

    enum Status: Equatable {
        case off, unavailable(String), starting, upToDate(Date?), syncing(String), failed(String)
        var label: String {
            switch self {
            case .off: "Off"
            case .unavailable(let why): why
            case .starting: "Connecting to iCloud…"
            case .upToDate(let date): date.map { "Up to date · \($0.formatted(date: .omitted, time: .shortened))" } ?? "Up to date"
            case .syncing(let what): what
            case .failed(let why): "Error: \(why)"
            }
        }
    }

    nonisolated static let containerIdentifier = "iCloud.com.duodirector.app"

    private(set) var status: Status = .off
    /// Device-local choices (UserDefaults): sync is a per-device decision. Changed via the
    /// setters below (not didSet, which this project avoids on @Observable properties).
    private(set) var isEnabled: Bool
    private(set) var syncsTakeFiles: Bool

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "DuoDirectorCloudSync")
        enabled ? start() : stop()
    }

    func setSyncsTakeFiles(_ enabled: Bool) {
        syncsTakeFiles = enabled
        UserDefaults.standard.set(enabled, forKey: "DuoDirectorCloudSyncTakes")
        if enabled { state.takes.forEach(uploadTake); relinkCloudTakes() }
    }

    @ObservationIgnored private let state: StudioSessionState
    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var containerURL: URL?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pendingRemote: ProjectDocument?
    @ObservationIgnored private var recordingObservation = false

    init(state: StudioSessionState, store: ProjectStore) {
        self.state = state
        self.store = store
        isEnabled = UserDefaults.standard.bool(forKey: "DuoDirectorCloudSync")
        syncsTakeFiles = UserDefaults.standard.bool(forKey: "DuoDirectorCloudSyncTakes")
        store.onSaved = { [weak self] document in self?.push(document) }
        if isEnabled { start() }
    }

    private var projectURL: URL? { containerURL?.appending(path: "Documents/Project/project.json") }
    private var cloudTakesURL: URL? { containerURL?.appending(path: "Documents/Takes") }

    // MARK: Lifecycle

    func start() {
        guard isEnabled else { return }
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .unavailable("Sign in to iCloud and turn on iCloud Drive to sync.")
            return
        }
        status = .starting
        Task {
            // url(forUbiquityContainerIdentifier:) can block. Never call it on the main thread.
            let identifier = Self.containerIdentifier
            let url = await Task.detached(priority: .utility) {
                FileManager.default.url(forUbiquityContainerIdentifier: identifier)
            }.value
            guard let url else { status = .unavailable("iCloud container unavailable. Check the iCloud capability."); return }
            containerURL = url
            try? FileManager.default.createDirectory(at: url.appending(path: "Documents/Project"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: url.appending(path: "Documents/Takes"), withIntermediateDirectories: true)
            startQuery()
            push(store.currentDocument)
            relinkCloudTakes()
            watchRecordingForPendingPull()
        }
    }

    func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        status = .off
    }

    // MARK: Push

    private func push(_ document: ProjectDocument) {
        guard isEnabled, let projectURL else { return }
        status = .syncing("Uploading project…")
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .utility) {
                Result {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(document)
                    try Self.coordinatedWrite(data, to: projectURL)
                }
            }.value
            switch result {
            case .success: status = .upToDate(Date())
            case .failure(let error): status = .failed(error.localizedDescription)
            }
        }
    }

    /// Copies a finished take's files into iCloud Drive › DuoDirector › Takes (opt-in).
    func uploadTake(_ take: TakeRecord) {
        guard isEnabled, syncsTakeFiles, let destination = cloudTakesURL else { return }
        let files = [take.rearFileURL, take.innerFileURL, take.sidecarJSONURL, take.sidecarFCPXMLURL, take.compositeFileURL]
            .compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        status = .syncing("Uploading take \(take.takeNumber)…")
        Task {
            let failures: Int = await Task.detached(priority: .background) {
                var failed = 0
                for file in files {
                    let target = destination.appending(path: file.lastPathComponent)
                    do { try Self.coordinatedCopy(from: file, to: target) } catch { failed += 1 }
                }
                return failed
            }.value
            status = failures == 0 ? .upToDate(Date()) : .failed("\(failures) file(s) of take \(take.takeNumber) didn't upload")
        }
    }

    // MARK: Pull

    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "project.json")
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.queryChanged() }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main, using: handler),
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main, using: handler),
        ]
        query.start()
        self.query = query
    }

    private func queryChanged() {
        guard let query, let projectURL else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        guard let item = query.results.first as? NSMetadataItem else { return }
        let downloaded = (item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String)
            == NSMetadataUbiquitousItemDownloadingStatusCurrent
        if !downloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: projectURL)
            status = .syncing("Downloading project…")
            return
        }
        Task {
            let remote: ProjectDocument? = await Task.detached(priority: .utility) {
                guard let data = try? Self.coordinatedRead(projectURL) else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try? decoder.decode(ProjectDocument.self, from: data)
            }.value
            guard let remote else { return }
            receive(remote)
        }
    }

    private func receive(_ remote: ProjectDocument) {
        let local = store.currentDocument
        guard CloudMerge.shouldApply(remote: remote, local: local, deviceID: ProjectStore.deviceID) else {
            status = .upToDate(state.lastPersistedAt)
            return
        }
        guard !state.isRecording, !state.isDemoMode else {
            pendingRemote = remote          // applied when the take ends / Demo Mode ends
            status = .syncing("Changes from another device will apply after this take.")
            return
        }
        let merged = CloudMerge.merge(local: local, remote: remote)
        // Phase 7: a deletion elsewhere removes this device's local copies too.
        for take in CloudMerge.takesDeleted(by: merged, from: local) { removeLocalFiles(of: take) }
        store.applyMerged(merged)
        relinkCloudTakes()
        status = .upToDate(Date())
    }

    /// Re-checks a deferred pull whenever recording / Demo Mode changes.
    private func watchRecordingForPendingPull() {
        withObservationTracking {
            _ = (state.isRecording, state.isDemoMode)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let remote = pendingRemote, !state.isRecording, !state.isDemoMode {
                    pendingRemote = nil
                    receive(remote)
                }
                watchRecordingForPendingPull()
            }
        }
    }

    /// Takes whose files aren't on this device but are in iCloud: point them at the cloud
    /// copy and start the download. Playback works once iCloud has fetched the file.
    private func relinkCloudTakes() {
        guard syncsTakeFiles, let cloud = cloudTakesURL else { return }
        for index in state.takes.indices {
            func relink(_ url: URL?) -> URL? {
                guard let url, !FileManager.default.fileExists(atPath: url.path) else { return url }
                let candidate = cloud.appending(path: url.lastPathComponent)
                try? FileManager.default.startDownloadingUbiquitousItem(at: candidate)
                return candidate
            }
            state.takes[index].rearFileURL = relink(state.takes[index].rearFileURL)
            state.takes[index].innerFileURL = relink(state.takes[index].innerFileURL)
            state.takes[index].compositeFileURL = relink(state.takes[index].compositeFileURL)
        }
    }

    // MARK: Deletions (Phase 7)

    /// Removes a deleted take's files from iCloud Drive › DuoDirector › Takes.
    func deleteCloudFiles(of take: TakeRecord) {
        guard isEnabled, let cloud = cloudTakesURL else { return }
        let names = Self.fileNames(of: take)
        Task.detached(priority: .utility) {
            for name in names { try? Self.coordinatedDelete(cloud.appending(path: name)) }
        }
    }

    private func removeLocalFiles(of take: TakeRecord) {
        let local = CaptureSessionController.takesDirectory
        for name in Self.fileNames(of: take) {
            try? FileManager.default.removeItem(at: local.appending(path: name))
        }
    }

    nonisolated static func fileNames(of take: TakeRecord) -> [String] {
        [take.rearFileURL, take.innerFileURL, take.sidecarJSONURL, take.sidecarFCPXMLURL, take.compositeFileURL]
            .compactMap { $0?.lastPathComponent }
    }

    nonisolated private static func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
            do { try FileManager.default.removeItem(at: target) } catch { deleteError = error }
        }
        if let error = coordinationError ?? deleteError { throw error }
    }

    // MARK: File coordination (off the main actor)

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    nonisolated private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result { try Data(contentsOf: source) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    nonisolated private static func coordinatedCopy(from source: URL, to target: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: target, options: .forReplacing,
                                       error: &coordinationError) { from, to in
            do {
                if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                try FileManager.default.copyItem(at: from, to: to)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }
}
