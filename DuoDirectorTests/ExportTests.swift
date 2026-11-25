import CoreGraphics
import Foundation
import Testing
@testable import DuoDirector

@Suite("Sidecars, marker track and composites")
struct ExportTests {

    private func dualTake(offset: Double = 0.5, rating: Int = 4, title: String? = "Q&A <intro>") -> TakeRecord {
        TakeRecord(takeNumber: 7, sessionIdentifier: "ABCDEF12-0000", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                   duration: 60, rating: rating, captureMode: .dualPodcastMultiCam, exportStyle: .pictureInPicture,
                   rearFileURL: URL(filePath: "/tmp/T7-rear.mov"), innerFileURL: URL(filePath: "/tmp/T7-inner.mov"),
                   innerStartOffset: offset, shotTitle: title)
    }

    private let settings = TakeSidecarExporter.Settings(resolution: .uhd4K, frameRate: 30, codec: .hevc, dolbyVision: false)

    @Test func fcpxmlPutsHostOnLaneOneAtTheSyncOffset() {
        let xml = TakeSidecarExporter.fcpxml(take: dualTake(), markers: [], settings: settings)
        #expect(xml.contains(#"lane="1""#))
        #expect(xml.contains(#"offset="15/30s""#))          // 0.5 s at 30 fps
        #expect(xml.contains(#"scale="0.3 0.3""#))          // PiP
        #expect(xml.contains("★★★★☆"))                      // rating keyword
    }

    @Test func fcpxmlEscapesUserText() {
        let marker = TakeMarker(takeNumber: 7, timestamp: 2, rating: 5, note: #"Tom & "Jerry" <3"#)
        let xml = TakeSidecarExporter.fcpxml(take: dualTake(), markers: [marker], settings: settings)
        #expect(xml.contains("Tom &amp; &quot;Jerry&quot; &lt;3"))
        #expect(xml.contains("Q&amp;A &lt;intro&gt;"))
        #expect(!xml.contains("<3\""))
    }

    @Test func soloTakeHasNoHostLane() {
        var take = dualTake()
        take.captureMode = .singleRearPro
        take.innerFileURL = nil
        #expect(!TakeSidecarExporter.fcpxml(take: take, markers: [], settings: settings).contains("lane="))
    }

    @Test func jsonSidecarRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = TakeMarker(takeNumber: 7, timestamp: 12.5, rating: 4, note: "Laugh")
        let urls = try TakeSidecarExporter.write(take: dualTake(), markers: [marker], settings: settings, directory: dir)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sidecar = try decoder.decode(TakeSidecarExporter.Sidecar.self, from: Data(contentsOf: urls.json))
        #expect(sidecar.files.count == 2)
        #expect(sidecar.files.last?.startOffsetSeconds == 0.5)
        #expect(sidecar.markers.first?.stars == "★★★★☆")
    }

    @Test func markerPayloadRoundTripsAndClamps() {
        let marker = TakeMarker(takeNumber: 3, timestamp: 4.2, rating: 5, note: "Good take")
        let decoded = MovieMarkerTrack.Payload.decode(MovieMarkerTrack.Payload(marker).encodedString())
        #expect(decoded?.marker.note == "Good take")
        #expect(decoded?.marker.rating == 5)
        var wild = MovieMarkerTrack.Payload(marker)
        wild.rating = 9
        #expect(wild.marker.rating == 5)
        #expect(MovieMarkerTrack.Payload.decode("not json") == nil)
    }

    @Test func markerFormatDescriptionBuilds() {
        #expect(MovieMarkerTrack.formatDescription() != nil)
    }

    // MARK: Composite layout matches the FCPXML layout

    @Test func pipPlacementMatchesSidecar() {
        let canvas = CompositeRenderer.renderSize
        let (rear, inner) = CompositeRenderer.placements(for: .pictureInPicture)
        #expect(rear.scale == 1)
        #expect(inner.scale == 0.3)
        // 4 % margin from bottom-right, like the FCPXML adjust-transform.
        #expect(abs((canvas.width - inner.center.x) - (canvas.width * 0.15 + canvas.height * 0.04)) < 0.01)
    }

    @Test func splitPlacesHalvesSideBySide() {
        let (rear, inner) = CompositeRenderer.placements(for: .splitScreenComposite)
        #expect(rear.scale == 0.5 && inner.scale == 0.5)
        #expect(rear.center.x < inner.center.x)
        #expect(rear.center.y == inner.center.y)
    }

    @Test func transformFitsAndCentres() {
        let placement = CompositeRenderer.Placement(scale: 1, center: CGPoint(x: 960, y: 540))
        let t = CompositeRenderer.transform(naturalSize: CGSize(width: 3840, height: 2160),
                                            preferredTransform: .identity, placement: placement)
        let frame = CGRect(x: 0, y: 0, width: 3840, height: 2160).applying(t)
        #expect(abs(frame.width - 1920) < 0.5 && abs(frame.minX) < 0.5 && abs(frame.minY) < 0.5)
    }

    @Test func transformHandlesPortraitRotation() {
        // A 1920×1080 buffer recorded with a 90° preferredTransform is a portrait picture.
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let placement = CompositeRenderer.Placement(scale: 1, center: CGPoint(x: 960, y: 540))
        let t = CompositeRenderer.transform(naturalSize: CGSize(width: 1920, height: 1080),
                                            preferredTransform: rotate, placement: placement)
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(t)
        #expect(abs(frame.height - 1080) < 0.5)                 // fit to height
        #expect(abs(frame.width - 607.5) < 0.5)                 // 1080 × 1080/1920
        #expect(abs(frame.midX - 960) < 0.5 && abs(frame.midY - 540) < 0.5)
    }
}
