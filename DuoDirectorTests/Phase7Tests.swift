import Foundation
import Testing
@testable import DuoDirector

@MainActor
@Suite("Deletion sync (tombstones)")
struct Phase7Tests {

    private func take(_ n: Int) -> TakeRecord {
        TakeRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, takeNumber: n,
                   sessionIdentifier: "S\(n)", startedAt: .init(timeIntervalSince1970: Double(n)), duration: 5,
                   captureMode: .singleRearPro, exportStyle: .pictureInPicture,
                   rearFileURL: URL(filePath: "/tmp/T\(n)-rear.mov"))
    }

    @Test func deletionOnOneDeviceWinsOverTheOthersCopy() {
        let deletedAt = Date(timeIntervalSince1970: 150)
        // Device B deleted take 2 (older save); device A still has it and saved later.
        let local = ProjectDocument(savedAt: .init(timeIntervalSince1970: 200), savedByDevice: "A",
                                    takes: [take(1), take(2)], nextTakeNumber: 3)
        let remote = ProjectDocument(savedAt: .init(timeIntervalSince1970: 160), savedByDevice: "B",
                                     takes: [take(1)], nextTakeNumber: 3, deletedTakeIDs: [take(2).id: deletedAt])
        let merged = CloudMerge.merge(local: local, remote: remote)
        #expect(merged.takes?.map(\.takeNumber) == [1])
        #expect(merged.deletedTakeIDs?[take(2).id] == deletedAt)
        #expect(CloudMerge.takesDeleted(by: merged, from: local).map(\.takeNumber) == [2])
        #expect(merged.nextTakeNumber == 3)     // number 2 is never reused
    }

    @Test func markerTombstonesRemoveMarkers() {
        let marker = TakeMarker(takeNumber: 1, timestamp: 1, rating: 3, note: "x")
        let local = ProjectDocument(savedAt: .init(timeIntervalSince1970: 300), markers: [marker])
        let remote = ProjectDocument(savedAt: .init(timeIntervalSince1970: 100), deletedMarkerIDs: [marker.id: Date()])
        #expect(CloudMerge.merge(local: local, remote: remote).markers?.isEmpty == true)
    }

    @Test func applyHidesTombstonedTakesAndPrunesOldTombstones() {
        let ancient = Date().addingTimeInterval(-ProjectDocument.tombstoneLifetime - 60)
        let document = ProjectDocument(takes: [take(1), take(2)], nextTakeNumber: 3,
                                       deletedTakeIDs: [take(2).id: Date(), take(9).id: ancient])
        let state = StudioSessionState()
        ProjectStore.apply(document, to: state, takesDirectory: URL(filePath: "/tmp"))
        #expect(state.takes.map(\.takeNumber) == [1])
        #expect(state.deletedTakeIDs.keys.contains(take(2).id))
        #expect(!state.deletedTakeIDs.keys.contains(take(9).id))      // expired
    }

    @Test func tombstonesRoundTripThroughTheDocument() throws {
        let state = StudioSessionState()
        state.deletedTakeIDs = [UUID(): Date(timeIntervalSince1970: 1_800_000_000)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectDocument.self, from: encoder.encode(ProjectStore.document(from: state)))
        #expect(decoded.deletedTakeIDs == state.deletedTakeIDs)
    }

    @Test func fileNamesCoverEveryArtefact() {
        var t = take(4)
        t.innerFileURL = URL(filePath: "/x/T4-inner.mov")
        t.sidecarJSONURL = URL(filePath: "/x/T4.duodirector.json")
        #expect(CloudSyncController.fileNames(of: t) == ["T4-rear.mov", "T4-inner.mov", "T4.duodirector.json"])
    }
}
