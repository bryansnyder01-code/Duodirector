import AVFoundation

// =====================================================================================
//  Phase 5: markers written INTO the .mov as a timed-metadata track
//
//  WRITE (during capture)
//    AVCaptureMetadataInput (iOS 9+) is a session input that feeds timed metadata to an
//    AVCaptureMovieFileOutput, which writes it as a metadata track in the movie file
//    alongside video and audio. One input per movie output (rear, and inner in
//    Dual-Cam), all on the same clock, so a marker lands at the same moment in both files.
//      • Format: boxed QuickTime metadata, one key: `mdta/com.duodirector.marker`,
//        UTF-8 JSON payload {takeNumber, timestamp, rating, note}.
//      • Each marker is one AVTimedMetadataGroup lasting one frame, timed on the
//        clock handed to the input (the session's synchronization clock).
//
//  READ (takes browser, recovery)
//    AVAssetReader + AVAssetReaderOutputMetadataAdaptor pulls the groups back out, so a
//    take keeps its markers even if it's copied off the phone without its sidecar, and the
//    takes browser can rebuild markers for files the project store doesn't know about.
//
//  The JSON/FCPXML sidecars still carry markers too, because NLEs don't read custom
//  timed metadata as markers. VERIFY ON DEVICE: that AVCaptureMetadataInput is
//  accepted in an AVCaptureMultiCamSession (canAddInput / canAddConnection). If it isn't,
//  Dual-Cam falls back to sidecar-only markers, and `markerTrackStatus` says so.
// =====================================================================================

enum MovieMarkerTrack {

    static let identifier = AVMetadataIdentifier(rawValue: "mdta/com.duodirector.marker")

    /// What each timed group carries.
    struct Payload: Codable, Equatable, Sendable {
        var takeNumber: Int
        var timestamp: TimeInterval
        var rating: Int
        var note: String

        init(_ marker: TakeMarker) {
            takeNumber = marker.takeNumber; timestamp = marker.timestamp
            rating = marker.rating; note = marker.note
        }

        var marker: TakeMarker {
            TakeMarker(takeNumber: takeNumber, timestamp: timestamp, rating: max(1, min(5, rating)), note: note)
        }

        func encodedString() -> String {
            (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}"
        }

        static func decode(_ string: String) -> Payload? {
            try? JSONDecoder().decode(Payload.self, from: Data(string.utf8))
        }
    }

    /// Format description declaring our single metadata key. Required by
    /// AVCaptureMetadataInput(formatDescription:clock:).
    static func formatDescription() -> CMMetadataFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_UTF8 as String,
        ]
        var description: CMMetadataFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    /// One-frame group at `time` on the input's clock.
    static func group(for marker: TakeMarker, at time: CMTime, frameRate: Int) -> AVTimedMetadataGroup {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = Payload(marker).encodedString() as NSString
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))
        return AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: time, duration: duration))
    }

    /// Reads every DuoDirector marker back out of a movie file. Empty if the file has no
    /// marker track (older takes, Simulator, or a session that refused the metadata input).
    static func readMarkers(from url: URL) async throws -> [TakeMarker] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .metadata)
        guard !tracks.isEmpty else { return [] }

        let reader = try AVAssetReader(asset: asset)
        var adaptors: [AVAssetReaderOutputMetadataAdaptor] = []
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            adaptors.append(AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output))
        }
        guard reader.startReading() else { throw reader.error ?? CameraError.cannotAdd("metadata reader") }

        var markers: [TakeMarker] = []
        for adaptor in adaptors {
            while let group = adaptor.nextTimedMetadataGroup() {
                for item in group.items where item.identifier == identifier {
                    if let string = try await item.load(.stringValue), var marker = Payload.decode(string)?.marker {
                        // Prefer the file's own presentation time (exact) over the wall-clock
                        // stamp. VERIFY ON DEVICE: movie-file-output tracks start at 0;
                        // if they don't, subtract the first video sample's time here.
                        if group.timeRange.start.isNumeric { marker.timestamp = group.timeRange.start.seconds }
                        markers.append(marker)
                    }
                }
            }
        }
        return markers.sorted { $0.timestamp < $1.timestamp }
    }
}
