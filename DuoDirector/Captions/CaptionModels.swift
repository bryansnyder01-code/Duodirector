import Foundation

// =====================================================================================
//  Captions (Phase 11): pure models, cue building and SRT. Unit-tested.
//
//  CaptionTranscriber turns a take's audio into timed words ON THE PHONE. This file
//  groups those words into readable cues and writes/reads SubRip (.srt), which every
//  NLE, YouTube, Instagram and TikTok accept.
//
//  Cue rules (common broadcast/social guidance):
//    • at most 2 lines of 42 characters,
//    • at most 6 s on screen, at least 1 s,
//    • a new cue after a pause of 0.8 s, or after sentence-ending punctuation once the
//      cue has been up for 1.5 s.
// =====================================================================================

struct CaptionWord: Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct CaptionCue: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    /// One or two lines.
    var lines: [String]
    var text: String { lines.joined(separator: "\n") }
}

enum CaptionBuilder {
    static let maxLineLength = 42
    static let maxLines = 2
    static let maxDuration: TimeInterval = 6
    static let minDuration: TimeInterval = 1
    static let pauseBreak: TimeInterval = 0.8
    static let sentenceBreakAfter: TimeInterval = 1.5

    static func cues(from words: [CaptionWord]) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        var current: [CaptionWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            cues.append(CaptionCue(start: first.start, end: last.end, lines: wrap(text)))
            current = []
        }

        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let first = current.first, let last = current.last {
                let joined = (current.map(\.text) + [word.text]).joined(separator: " ")
                let tooLong = joined.count > maxLineLength * maxLines
                let tooSlow = word.end - first.start > maxDuration
                let paused = word.start - last.end >= pauseBreak
                let sentence = endsSentence(last.text) && last.end - first.start >= sentenceBreakAfter
                if tooLong || tooSlow || paused || sentence { flush() }
            }
            current.append(word)
        }
        flush()
        return enforceMinimumDuration(cues)
    }

    /// Splits text into at most two lines of ≤ 42 characters, as balanced as possible.
    static func wrap(_ text: String) -> [String] {
        guard text.count > maxLineLength else { return [text] }
        let words = text.split(separator: " ").map(String.init)
        var best: (lines: [String], score: Int)?
        for split in 1..<words.count {
            let a = words[..<split].joined(separator: " ")
            let b = words[split...].joined(separator: " ")
            let overflow = max(0, a.count - maxLineLength) + max(0, b.count - maxLineLength)
            let score = overflow * 1000 + abs(a.count - b.count)
            if best == nil || score < best!.score { best = ([a, b], score) }
        }
        return best?.lines ?? [text]
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…".contains(last)
    }

    /// Stretches short cues to 1 s where the next cue leaves room, never overlapping.
    static func enforceMinimumDuration(_ cues: [CaptionCue]) -> [CaptionCue] {
        var out = cues
        for i in out.indices where out[i].end - out[i].start < minDuration {
            let limit = i + 1 < out.count ? out[i + 1].start : .greatestFiniteMagnitude
            out[i].end = min(out[i].start + minDuration, limit)
        }
        return out
    }
}

enum SubRip {
    /// 3725.5 → "01:02:05,500"
    static func timestamp(_ t: TimeInterval) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    static func render(_ cues: [CaptionCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func parseTimestamp(_ s: Substring) -> TimeInterval? {
        let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// Reads .srt text back (for burn-in and editing). Malformed blocks are skipped.
    static func parse(_ text: String) -> [CaptionCue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timeIndex].components(separatedBy: "-->")
            guard times.count == 2, let start = parseTimestamp(Substring(times[0])),
                  let end = parseTimestamp(Substring(times[1])) else { return nil }
            let body = lines[(timeIndex + 1)...].map(String.init)
            guard !body.isEmpty else { return nil }
            return CaptionCue(start: start, end: end, lines: body)
        }
    }
}
