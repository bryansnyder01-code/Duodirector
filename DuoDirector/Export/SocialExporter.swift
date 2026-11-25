import AVFoundation
import CoreText
import QuartzCore
import UIKit
import Vision

// =====================================================================================
//  SocialExporter (Phase 11): one-tap 9:16 vertical export and burned-in captions
//
//  Source: the take's composite if there is one, otherwise the rear camera file.
//  Vertical: Vision finds the main face about once a second; ReframePlanner smooths the
//  centres and the crop pans between them with transform ramps (no jumps). No face →
//  centre crop. Captions: the take's .srt drawn with Core Animation text layers.
//  Output: `<take>-social.mov`, HEVC, saved to Photos by CameraEngine.
// =====================================================================================

enum SocialExporter {

    struct Options: Equatable, Sendable {
        var vertical = true
        var burnCaptions = false
    }

    enum ExportError: LocalizedError {
        case noSource, noVideoTrack, nothingToDo, cannotExport, cancelled
        var errorDescription: String? {
            switch self {
            case .noSource: String(localized: "This take's video file isn't on this iPhone.")
            case .noVideoTrack: String(localized: "The video file has no picture.")
            case .nothingToDo: String(localized: "Choose vertical, captions, or both.")
            case .cannotExport: String(localized: "This iPhone can't export this video.")
            case .cancelled: String(localized: "Export stopped.")
            }
        }
    }

    static func sourceURL(for take: TakeRecord) -> URL? {
        [take.compositeFileURL, take.rearFileURL].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func outputURL(for source: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-rear", with: "").replacingOccurrences(of: "-composite", with: "")
        return source.deletingLastPathComponent().appending(path: base + "-social.mov")
    }

    static func export(take: TakeRecord, options: Options,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard options.vertical || options.burnCaptions else { throw ExportError.nothingToDo }
        guard let source = sourceURL(for: take) else { throw ExportError.noSource }
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let naturalSize = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let fps = try await video.load(.nominalFrameRate)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.cannotExport }
        let range = CMTimeRange(start: .zero, duration: duration)
        try videoTrack.insertTimeRange(range, of: video, at: .zero)
        if let audio, let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(range, of: audio, at: .zero)
        }

        // Orientation: move the oriented frame to the origin first.
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let oriented = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        let orient = preferred.concatenating(CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))

        let canvas: CGSize = options.vertical ? ReframePlanner.verticalSize : oriented
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        if options.vertical {
            progress(0.02)
            let times = ReframePlanner.sampleTimes(duration: duration.seconds)
            let raw = await faceCenters(asset: asset, at: times)
            let centers = ReframePlanner.smoothedCenters(raw)
            func t(_ i: Int) -> CGAffineTransform {
                orient.concatenating(ReframePlanner.transform(orientedSize: oriented, centerX: centers[i], canvas: canvas))
            }
            layer.setTransform(t(0), at: .zero)
            for i in 0..<(times.count - 1) where centers[i] != centers[i + 1] {
                let from = CMTime(seconds: times[i], preferredTimescale: 600)
                let to = CMTime(seconds: times[i + 1], preferredTimescale: 600)
                layer.setTransformRamp(fromStart: t(i), toEnd: t(i + 1), timeRange: CMTimeRange(start: from, end: to))
            }
        } else {
            layer.setTransform(orient, at: .zero)
        }
        progress(0.1)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, fps.rounded()))))
        videoComposition.instructions = [instruction]

        if options.burnCaptions, let srt = take.captionsURL, let text = try? String(contentsOf: srt, encoding: .utf8) {
            let cues = SubRip.parse(text)
            if !cues.isEmpty {
                let (parent, videoLayer) = captionLayers(cues: cues, canvas: canvas)
                videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHEVCHighestQuality)
        else { throw ExportError.cannotExport }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        nonisolated(unsafe) let exporter = session

        let out = outputURL(for: source)
        try? FileManager.default.removeItem(at: out)
        let progressTask = Task {
            for await state in exporter.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { progress(0.1 + 0.9 * p.fractionCompleted) }
            }
        }
        defer { progressTask.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: out, as: .mov)
            } onCancel: {
                exporter.cancelExport()
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw Task.isCancelled ? ExportError.cancelled : error
        }
        progress(1)
        return out
    }

    // MARK: Face tracking

    /// Horizontal centre (0…1, in the ORIENTED frame) of the largest face at each time.
    private static func faceCenters(asset: AVAsset, at times: [TimeInterval]) async -> [Double?] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        var out: [Double?] = []
        for t in times {
            if Task.isCancelled { break }
            guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else {
                out.append(nil); continue
            }
            out.append(largestFaceCenter(in: image))
        }
        while out.count < times.count { out.append(nil) }
        return out
    }

    private static func largestFaceCenter(in image: CGImage) -> Double? {
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([faces, people])
        let faceBoxes: [CGRect] = (faces.results ?? []).map { $0.boundingBox }
        let peopleBoxes: [CGRect] = (people.results ?? []).map { $0.boundingBox }
        let boxes = faceBoxes.isEmpty ? peopleBoxes : faceBoxes
        guard let biggest = boxes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return Double(biggest.midX)      // Vision is normalised with a bottom-left origin; x is unchanged.
    }

    // MARK: Captions

    /// Core Animation layers for the export. AVFoundation renders this tree with a
    /// bottom-left origin, so y is measured up from the bottom of the frame.
    private static func captionLayers(cues: [CaptionCue], canvas: CGSize) -> (CALayer, CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: canvas)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let vertical = canvas.height > canvas.width
        let fontSize = (vertical ? canvas.width : canvas.height) * 0.05
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxWidth = canvas.width * 0.86
        let bottom = canvas.height * (vertical ? 0.16 : 0.08)

        for cue in cues {
            let attributed = NSAttributedString(string: cue.text, attributes: [
                .font: font, .foregroundColor: UIColor.white,
                .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }(),
            ])
            let size = attributed.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
            let pad = fontSize * 0.35
            let box = CALayer()
            box.frame = CGRect(x: (canvas.width - size.width) / 2 - pad, y: bottom,
                               width: ceil(size.width) + pad * 2, height: ceil(size.height) + pad * 2)
            box.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
            box.cornerRadius = fontSize * 0.3
            box.opacity = 0

            let text = CATextLayer()
            text.string = attributed
            text.frame = CGRect(x: pad, y: pad, width: ceil(size.width), height: ceil(size.height))
            text.isWrapped = true
            text.alignmentMode = .center
            text.contentsScale = 1
            box.addSublayer(text)

            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + max(0, cue.start)
            show.duration = max(0.1, cue.end - cue.start)
            show.isRemovedOnCompletion = true
            box.add(show, forKey: "show")
            parent.addSublayer(box)
        }
        return (parent, videoLayer)
    }
}
