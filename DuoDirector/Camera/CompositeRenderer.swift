import AVFoundation
import CoreGraphics

// =====================================================================================
//  CompositeRenderer (Phase 5): optional on-device split-screen / PiP render
//
//  Phase 4 delivered composites only as FCPXML timelines, because rendering on a hot
//  phone fights the thermal guard. This adds a real render for people who want a
//  ready-to-post file, under strict conditions (CompositeRenderPolicy):
//    • never while recording,
//    • thermal state nominal or fair,
//    • on power (charging / full),
//    • aborts the moment the device reaches serious (CameraEngine watches).
//
//  PIPELINE
//    AVMutableComposition: rear (Guest) video + audio at 0; inner (Host) video inserted
//    at `innerStartOffset` (the same sync the FCPXML uses).
//    AVMutableVideoComposition: one instruction, two layer instructions whose transforms
//    reproduce the FCPXML layout exactly:
//      pictureInPicture      inner at 30 % in the bottom-right corner (4 % margin)
//      splitScreenComposite  rear and inner each at 50 %, side by side, centred
//    AVAssetExportSession, HEVC 1080p preset (4K composites are rarely worth the heat),
//    the iOS 18 async `export(to:as:)` API, with progress from `states(updateInterval:)`.
//    Output: `<take>-composite.mov` next to the camera files.
// =====================================================================================

enum CompositeRenderer {

    enum RenderError: LocalizedError {
        case missingFiles, noVideoTrack, cannotExport, cancelled
        var errorDescription: String? {
            switch self {
            case .missingFiles: "Both camera files are needed for a composite."
            case .noVideoTrack: "A camera file has no video track."
            case .cannotExport: "This device can't export the composite."
            case .cancelled: "Render stopped."
            }
        }
    }

    /// Render canvas. 1080p keeps the encode short and cool.
    static let renderSize = CGSize(width: 1920, height: 1080)

    /// Where a layer goes on the canvas, as (scale, centre) in canvas points. Pure, so
    /// tests can check it against the FCPXML layout.
    struct Placement: Equatable, Sendable {
        var scale: CGFloat
        var center: CGPoint
    }

    static func placements(for style: DualExportStyle, canvas: CGSize = renderSize) -> (rear: Placement, inner: Placement) {
        let full = Placement(scale: 1, center: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
        switch style {
        case .separateSyncedTracks, .pictureInPicture:
            // Matches TakeSidecarExporter: scale 0.3, inset 4 % of height from the corner.
            let s: CGFloat = 0.3
            let margin = canvas.height * 0.04
            let w = canvas.width * s, h = canvas.height * s
            return (full, Placement(scale: s, center: CGPoint(x: canvas.width - margin - w / 2,
                                                             y: canvas.height - margin - h / 2)))
        case .splitScreenComposite:
            return (Placement(scale: 0.5, center: CGPoint(x: canvas.width * 0.25, y: canvas.height / 2)),
                    Placement(scale: 0.5, center: CGPoint(x: canvas.width * 0.75, y: canvas.height / 2)))
        }
    }

    /// Transform that takes a track (with its preferredTransform applied) to `placement`,
    /// aspect-fit into the canvas first.
    static func transform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                          placement: Placement, canvas: CGSize = renderSize) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { return .identity }
        let fit = min(canvas.width / size.width, canvas.height / size.height) * placement.scale
        // 1. orient (and move the oriented frame back to the origin), 2. scale, 3. centre.
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(translationX: placement.center.x - size.width * fit / 2,
                                             y: placement.center.y - size.height * fit / 2))
    }

    /// Builds the synced composition + layout. Shared by `render` and by the takes
    /// browser, which plays it live through AVPlayerItem.videoComposition (no file needed),
    /// so preview and render can never disagree.
    static func makeComposition(take: TakeRecord, style: DualExportStyle) async throws
        -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition) {
        guard let rearURL = take.rearFileURL, let innerURL = take.innerFileURL,
              FileManager.default.fileExists(atPath: rearURL.path),
              FileManager.default.fileExists(atPath: innerURL.path) else { throw RenderError.missingFiles }

        let rearAsset = AVURLAsset(url: rearURL)
        let innerAsset = AVURLAsset(url: innerURL)
        guard let rearVideo = try await rearAsset.loadTracks(withMediaType: .video).first,
              let innerVideo = try await innerAsset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let rearAudio = try await rearAsset.loadTracks(withMediaType: .audio).first
        let rearDuration = try await rearAsset.load(.duration)
        let innerDuration = try await innerAsset.load(.duration)

        let composition = AVMutableComposition()
        guard let rearTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let innerTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.cannotExport }

        try rearTrack.insertTimeRange(CMTimeRange(start: .zero, duration: rearDuration), of: rearVideo, at: .zero)
        // Positive offset: inner started later, so it sits later on the timeline. Negative:
        // trim the inner file's head instead.
        let offset = CMTime(seconds: take.innerStartOffset, preferredTimescale: 600)
        if offset >= .zero {
            try innerTrack.insertTimeRange(CMTimeRange(start: .zero, duration: innerDuration), of: innerVideo, at: offset)
        } else {
            let trim = CMTimeMultiply(offset, multiplier: -1)
            try innerTrack.insertTimeRange(CMTimeRange(start: trim, duration: CMTimeSubtract(innerDuration, trim)),
                                           of: innerVideo, at: .zero)
        }
        if let rearAudio, let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: rearDuration), of: rearAudio, at: .zero)
        }

        let (rearPlacement, innerPlacement) = placements(for: style)
        let rearLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: rearTrack)
        rearLayer.setTransform(transform(naturalSize: try await rearVideo.load(.naturalSize),
                                         preferredTransform: try await rearVideo.load(.preferredTransform),
                                         placement: rearPlacement), at: .zero)
        let innerLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: innerTrack)
        innerLayer.setTransform(transform(naturalSize: try await innerVideo.load(.naturalSize),
                                          preferredTransform: try await innerVideo.load(.preferredTransform),
                                          placement: innerPlacement), at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        // First layer instruction is on top: Host PiP above Guest.
        instruction.layerInstructions = [innerLayer, rearLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let fps = try await rearVideo.load(.nominalFrameRate)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, fps.rounded()))))
        videoComposition.instructions = [instruction]
        return (composition, videoComposition)
    }

    /// Renders the take. `progress` is called on an arbitrary task with 0…1.
    /// Cancel the calling Task to stop (the export is cancelled and the partial file removed).
    static func render(take: TakeRecord, style: DualExportStyle,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (composition, videoComposition) = try await makeComposition(take: take, style: style)
        guard let rearURL = take.rearFileURL else { throw RenderError.missingFiles }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVC1920x1080)
        else { throw RenderError.cannotExport }
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        // Swift 6: AVAssetExportSession isn't Sendable in every SDK. It's only used for
        // progress reads and cancel, both documented as thread-safe.
        nonisolated(unsafe) let session = export

        let outputURL = rearURL.deletingLastPathComponent()
            .appending(path: rearURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-rear", with: "") + "-composite.mov")
        try? FileManager.default.removeItem(at: outputURL)

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { progressTask.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await session.export(to: outputURL, as: .mov)
            } onCancel: {
                session.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw Task.isCancelled ? RenderError.cancelled : error
        }
        progress(1)
        return outputURL
    }
}
