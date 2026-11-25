import AVFoundation
import Foundation
import os
import Speech

// =====================================================================================
//  CaptionTranscriber (Phase 11): on-device speech-to-text for a take
//
//  PRIVACY: `requiresOnDeviceRecognition = true`. If this phone or language can't
//  transcribe on device, we stop with an error instead of falling back to Apple's
//  servers, so "nothing leaves your phone" stays true. The usage string says so too.
//
//  Pipeline: take's .mov → audio-only .m4a (passthrough-quality export, deleted after)
//  → SFSpeechURLRecognitionRequest → word segments → CaptionBuilder → .srt next to
//  the camera files.
//
//  VERIFY on hardware: iOS 27 may deprecate SFSpeechRecognizer in favour of
//  SpeechAnalyzer/SpeechTranscriber (iOS 26). It still works; a deprecation warning
//  is fine for 1.0. Move to SpeechAnalyzer if it ever stops working on device.
// =====================================================================================

enum CaptionTranscriber {

    enum TranscribeError: LocalizedError {
        case notAuthorized, onDeviceUnavailable, noAudio, noSpeech, failed(String)
        var errorDescription: String? {
            switch self {
            case .notAuthorized: String(localized: "Turn on Speech Recognition for DuoDirector in Settings to make captions.")
            case .onDeviceUnavailable: String(localized: "This iPhone can't transcribe this language on device, and DuoDirector never sends audio to a server.")
            case .noAudio: String(localized: "This take has no audio track.")
            case .noSpeech: String(localized: "No speech was found in this take.")
            case .failed(let message): message
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized
    }

    /// Transcribes `videoURL` and writes `<take>.srt` next to it. Returns the .srt URL.
    static func makeCaptions(for videoURL: URL, locale: Locale = .current) async throws -> URL {
        guard await requestAuthorization() else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { throw TranscribeError.onDeviceUnavailable }

        let audioURL = try await extractAudio(from: videoURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let words = try await recognize(audioURL, with: recognizer)
        let cues = CaptionBuilder.cues(from: words)
        guard !cues.isEmpty else { throw TranscribeError.noSpeech }

        let srtURL = captionsURL(for: videoURL)
        try SubRip.render(cues).write(to: srtURL, atomically: true, encoding: .utf8)
        return srtURL
    }

    /// `Take-012-rear.mov` → `Take-012.srt`
    static func captionsURL(for videoURL: URL) -> URL {
        let base = videoURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-rear", with: "").replacingOccurrences(of: "-composite", with: "")
        return videoURL.deletingLastPathComponent().appending(path: base + ".srt")
    }

    private static func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw TranscribeError.noAudio }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscribeError.failed(String(localized: "Couldn't read the take's audio."))
        }
        let out = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }

    private static func recognize(_ audioURL: URL, with recognizer: SFSpeechRecognizer) async throws -> [CaptionWord] {
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let once = OSAllocatedUnfairLock(initialState: false)
        nonisolated(unsafe) var task: SFSpeechRecognitionTask?
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[CaptionWord], Error>) in
                task = recognizer.recognitionTask(with: request) { result, error in
                    // Pull Sendable values out of the (non-Sendable) result right here.
                    let words: [CaptionWord]? = result.flatMap { r in
                        r.isFinal ? r.bestTranscription.segments.map {
                            CaptionWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                        } : nil
                    }
                    let message = error?.localizedDescription
                    guard words != nil || message != nil else { return }
                    guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                    if let words { c.resume(returning: words) }
                    else { c.resume(throwing: TranscribeError.failed(message ?? "")) }
                }
            }
        } onCancel: {
            task?.cancel()
        }
    }
}
