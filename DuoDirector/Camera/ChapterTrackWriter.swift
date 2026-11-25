import AVFoundation

// =====================================================================================
//  ChapterTrackWriter (Phase 6): real QuickTime chapters in each .mov
//
//  Phase 5 wrote markers as a custom timed-metadata track. Apps like QuickTime Player,
//  Photos' scrubber, Finder previews and most NLE importers don't read that, but they do
//  read classic QuickTime CHAPTERS: a text track whose samples are the chapter titles,
//  linked from the video track with a `chap` track reference.
//
//  HOW
//    After a take finishes, before it is copied to Photos, the file is re-muxed in
//    PASSTHROUGH (outputSettings nil: no decode, no encode, so it's I/O only and cheap on
//    heat) with AVAssetReader → AVAssetWriter, and one extra text input carries the
//    chapters. `videoInput.addTrackAssociation(withTrackOf: chapterInput, type: .chapterList)`
//    creates the `chap` reference. The original is then swapped for the new file with
//    FileManager.replaceItemAt, so a failure at any step leaves the original untouched.
//
//  CHAPTERS
//    "Start" at 0, then one chapter per marker: "★★★★☆ Great laugh". Each runs until the
//    next marker (or the end of the take). Markers less than 0.5 s apart are merged.
//
//  VERIFY ON DEVICE
//    • Passthrough of HEVC Main10 / HLG and ProRes keeps the colour atoms (it should;
//      formatDescription is passed as the source format hint).
//    • The timed-metadata marker track (MovieMarkerTrack) survives the re-mux. It is
//      copied as a passthrough metadata input with its format description.
//    • QuickTime Player shows the chapters under View › Go to Chapter.
// =====================================================================================

enum ChapterTrackWriter {

    struct Chapter: Equatable, Sendable {
        var start: Double
        var duration: Double
        var title: String
    }

    // MARK: Pure: markers → chapters (unit-tested)

    static func chapters(for markers: [TakeMarker], duration: Double, minimumGap: Double = 0.5) -> [Chapter] {
        guard duration > 0 else { return [] }
        var points: [(Double, String)] = [(0, "Start")]
        for marker in markers.sorted(by: { $0.timestamp < $1.timestamp }) {
            let t = min(max(0, marker.timestamp), duration)
            let title = "\(marker.stars) \(marker.note)".trimmingCharacters(in: .whitespaces)
            if let last = points.last, t - last.0 < minimumGap {
                // Too close to the previous point: the marker's title wins over "Start".
                points[points.count - 1] = (last.0, last.1 == "Start" && t < minimumGap ? title : last.1 + " / " + marker.note)
            } else {
                points.append((t, title))
            }
        }
        return points.enumerated().map { index, point in
            let end = index + 1 < points.count ? points[index + 1].0 : duration
            return Chapter(start: point.0, duration: max(0.001, end - point.0), title: point.1)
        }
    }

    /// QuickTime text sample: 16-bit big-endian length, UTF-8 text, then an `encd` atom
    /// declaring UTF-8 (0x00000100). This is the layout QuickTime chapter readers expect.
    static func textSampleData(_ title: String) -> Data {
        let text = Data(title.utf8.prefix(Int(UInt16.max)))
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt16(text.count).bigEndian, Array.init))
        data.append(text)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(12).bigEndian, Array.init))
        data.append(contentsOf: Array("encd".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0x0000_0100).bigEndian, Array.init))
        return data
    }

    // MARK: Writing

    enum WriteError: LocalizedError {
        case noVideo, cannotWrite(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: "The file has no video track."
            case .cannotWrite(let why): "Couldn't add chapters (\(why))."
            }
        }
    }

    /// Adds chapters to the movie at `url`, in place. No-op when there are no markers.
    static func addChapters(to url: URL, markers: [TakeMarker]) async throws {
        guard !markers.isEmpty else { return }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration).seconds
        let chapters = chapters(for: markers, duration: duration)
        guard chapters.count > 1 else { return }

        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else { throw WriteError.noVideo }

        let reader = try AVAssetReader(asset: asset)
        let tempURL = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)      // keeps the session ID etc.

        // Passthrough pair for every existing track (video, audio, timed metadata).
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var videoInput: AVAssetWriterInput?
        for track in tracks where [.video, .audio, .metadata].contains(track.mediaType) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
                videoInput = videoInput ?? input
            }
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            pairs.append((output, input))
        }

        // Chapter text track.
        guard let textFormat = makeTextFormatDescription() else { throw WriteError.cannotWrite("text format") }
        let chapterInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: textFormat)
        chapterInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(chapterInput) else { throw WriteError.cannotWrite("chapter input") }
        writer.add(chapterInput)
        if let videoInput, videoInput.canAddTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue) {
            videoInput.addTrackAssociation(withTrackOf: chapterInput, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        }
        // Chapter tracks are referenced, not played: keep it out of the default track group.
        chapterInput.marksOutputTrackAsEnabled = false

        guard reader.startReading() else { throw reader.error ?? WriteError.cannotWrite("reader") }
        guard writer.startWriting() else { throw writer.error ?? WriteError.cannotWrite("writer") }
        writer.startSession(atSourceTime: .zero)

        // Copy every passthrough track CONCURRENTLY. AVAssetWriter interleaves tracks, so
        // feeding them one after another would stall once one input runs ahead of the rest.
        let chapterSamples = chapters.compactMap { makeTextSample($0, format: textFormat) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (index, (output, writerInput)) in pairs.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "duodirector.chapters.copy.\(index)")
                let box = SampleSource(output: output)
                // Swift 6: each input is touched only on its own serial queue.
                nonisolated(unsafe) let input = writerInput
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard let sample = box.next(), input.append(sample) else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
            group.enter()
            let chapterQueue = DispatchQueue(label: "duodirector.chapters.text")
            let pending = ChapterQueue(samples: chapterSamples)
            nonisolated(unsafe) let chapterInput = chapterInput
            chapterInput.requestMediaDataWhenReady(on: chapterQueue) {
                while chapterInput.isReadyForMoreMediaData {
                    guard let sample = pending.next() else {
                        chapterInput.markAsFinished()
                        group.leave()
                        return
                    }
                    chapterInput.append(sample)
                }
            }
            group.notify(queue: .global(qos: .utility)) { done.resume() }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tempURL)
            throw writer.error ?? WriteError.cannotWrite("finish")
        }
        if reader.status == .failed {
            try? FileManager.default.removeItem(at: tempURL)
            throw reader.error ?? WriteError.cannotWrite("read")
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    /// Pulls samples from one reader output (only touched on that input's queue).
    private final class SampleSource: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        init(output: AVAssetReaderTrackOutput) { self.output = output }
        func next() -> CMSampleBuffer? { output.copyNextSampleBuffer() }
    }

    private final class ChapterQueue: @unchecked Sendable {
        private var samples: [CMSampleBuffer]
        init(samples: [CMSampleBuffer]) { self.samples = samples }
        func next() -> CMSampleBuffer? { samples.isEmpty ? nil : samples.removeFirst() }
    }

    /// Minimal QuickTime text ('text') sample description with a UTF-8-capable default style.
    private static func makeTextFormatDescription() -> CMFormatDescription? {
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: [
                kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255,
            ],
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 12,
                kCMTextFormatDescriptionStyle_ForegroundColor: [
                    kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                    kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
                ],
            ],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_QTText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    private static func makeTextSample(_ chapter: Chapter, format: CMFormatDescription) -> CMSampleBuffer? {
        let data = textSampleData(chapter.title)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: chapter.duration, preferredTimescale: 600),
                                        presentationTimeStamp: CMTime(seconds: chapter.start, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                             sampleBufferOut: &sample)
        return sample
    }
}
