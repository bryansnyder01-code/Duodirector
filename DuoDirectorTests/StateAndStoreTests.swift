import Foundation
import Testing
@testable import DuoDirector

@MainActor
@Suite("State, persistence and takes filtering")
struct StateAndStoreTests {

    private let takesDir = URL(filePath: "/var/mobile/NewContainer/Documents/Takes")

    private func take(_ n: Int, rating: Int = 0, mode: CaptureMode = .singleRearPro, duration: Double = 10) -> TakeRecord {
        TakeRecord(takeNumber: n, sessionIdentifier: "S\(n)", startedAt: Date(timeIntervalSince1970: Double(n) * 100),
                   duration: duration, rating: rating, captureMode: mode, exportStyle: .pictureInPicture,
                   rearFileURL: URL(filePath: "/var/mobile/OldContainer/Documents/Takes/T\(n)-rear.mov"),
                   shotTitle: "Shot \(n)")
    }

    @Test func markersClampRatingAndReturnTheMarker() {
        let state = StudioSessionState()
        let marker = state.addMarker(note: "x", rating: 12)
        #expect(marker.rating == 5)
        #expect(state.chapterMarkers.last == marker)
    }

    @Test func documentRoundTripRestoresContentAndPrefs() throws {
        let source = StudioSessionState()
        source.scriptText = "Hello"
        source.takes = [take(1, rating: 3), take(2, rating: 5, mode: .dualPodcastMultiCam)]
        source.chapterMarkers = [TakeMarker(takeNumber: 2, timestamp: 3, rating: 5, note: "Good take")]
        source.takeNumber = 3
        source.dualExportStyle = .splitScreenComposite
        source.pipCorner = .topLeading
        source.prompterFontSize = 32

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(ProjectStore.document(from: source))
        let document = try decoder.decode(ProjectDocument.self, from: data)

        let restored = StudioSessionState()
        ProjectStore.apply(document, to: restored, takesDirectory: takesDir)
        #expect(restored.scriptText == "Hello")
        #expect(restored.takes.map(\.rating) == [3, 5])
        #expect(restored.chapterMarkers.count == 1)
        #expect(restored.takeNumber == 3)
        #expect(restored.dualExportStyle == .splitScreenComposite)
        #expect(restored.pipCorner == .topLeading)
        #expect(restored.prompterFontSize == 32)
    }

    @Test func relinkKeepsOnlyTheFileName() {
        let moved = ProjectStore.relink(take(4), into: takesDir)
        #expect(moved.rearFileURL == takesDir.appending(path: "T4-rear.mov"))
        #expect(moved.innerFileURL == nil)
    }

    @Test func applyDropsEmptyTakesAndNeverReusesATakeNumber() {
        var empty = take(9, duration: 0)
        empty.rearFileURL = nil
        let document = ProjectDocument(takes: [take(5), empty], nextTakeNumber: 2)
        let state = StudioSessionState()
        ProjectStore.apply(document, to: state, takesDirectory: takesDir)
        #expect(state.takes.map(\.takeNumber) == [5])
        #expect(state.takeNumber == 6)
    }

    @Test func olderDocumentsWithMissingFieldsStillLoad() throws {
        let json = #"{"formatVersion":1,"savedAt":"2026-11-24T12:00:00Z","scriptText":"Old"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ProjectDocument.self, from: Data(json.utf8))
        let state = StudioSessionState()
        let shots = state.shotList
        ProjectStore.apply(document, to: state, takesDirectory: takesDir)
        #expect(state.scriptText == "Old")
        #expect(state.shotList == shots)       // untouched
    }

    @Test func takeFilters() {
        let takes = [take(1, rating: 2), take(2, rating: 4), take(3), take(4, mode: .dualPodcastMultiCam)]
        let markers = [TakeMarker(takeNumber: 3, timestamp: 1, rating: 5, note: "Great story")]
        #expect(TakeFilter.apply(.good, search: "", takes: takes, markers: markers).map(\.takeNumber) == [3, 2])
        #expect(TakeFilter.apply(.unrated, search: "", takes: takes, markers: markers).map(\.takeNumber) == [4, 3])
        #expect(TakeFilter.apply(.dual, search: "", takes: takes, markers: markers).map(\.takeNumber) == [4])
        #expect(TakeFilter.apply(.all, search: "story", takes: takes, markers: markers).map(\.takeNumber) == [3])
        #expect(TakeFilter.apply(.all, search: "shot 1", takes: takes, markers: markers).map(\.takeNumber) == [1])
    }
}
