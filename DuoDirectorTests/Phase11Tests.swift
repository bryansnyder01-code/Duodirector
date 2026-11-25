import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import DuoDirector

@Suite("1.0 features (Phase 11)")
struct Phase11Tests {

    private func w(_ text: String, _ start: Double, _ end: Double) -> CaptionWord {
        CaptionWord(text: text, start: start, end: end)
    }

    // MARK: Captions

    @Test func groupsWordsAndBreaksOnPauses() {
        let words = [w("Hello", 0, 0.4), w("there", 0.5, 0.9), w("friends", 2.0, 2.5), w("welcome", 2.6, 3.0)]
        let cues = CaptionBuilder.cues(from: words)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello there")
        #expect(cues[1].text == "friends welcome")
        #expect(cues[1].start == 2.0)
    }

    @Test func breaksAfterSentenceOnceLongEnough() {
        let words = [w("This", 0, 0.5), w("is", 0.5, 1.0), w("done.", 1.0, 1.6), w("Next", 1.7, 2.0), w("one", 2.0, 2.3)]
        let cues = CaptionBuilder.cues(from: words)
        #expect(cues.map(\.text) == ["This is done.", "Next one"])
    }

    @Test func capsCueLengthAndDuration() {
        let words = (0..<40).map { i in w("word\(i)", Double(i) * 0.3, Double(i) * 0.3 + 0.25) }
        let cues = CaptionBuilder.cues(from: words)
        for cue in cues {
            #expect(cue.end - cue.start <= CaptionBuilder.maxDuration + 0.001)
            #expect(cue.lines.count <= CaptionBuilder.maxLines)
            for line in cue.lines { #expect(line.count <= CaptionBuilder.maxLineLength) }
        }
        #expect(cues.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.count == 40)
    }

    @Test func wrapsIntoBalancedLines() {
        let lines = CaptionBuilder.wrap("The quick brown fox jumps over the lazy dog and keeps on running")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= 42 })
        #expect(abs(lines[0].count - lines[1].count) < 12)
        #expect(CaptionBuilder.wrap("Short") == ["Short"])
    }

    @Test func shortCuesAreStretchedWithoutOverlap() {
        let cues = CaptionBuilder.enforceMinimumDuration([
            CaptionCue(start: 0, end: 0.3, lines: ["Hi"]),
            CaptionCue(start: 0.6, end: 2, lines: ["there"]),
        ])
        #expect(cues[0].end == 0.6)
        #expect(cues[1].end == 2)
    }

    @Test func subRipRoundTrips() {
        let cues = [CaptionCue(start: 1.25, end: 3.5, lines: ["Hello", "world"]),
                    CaptionCue(start: 3725.5, end: 3727, lines: ["Later"])]
        let text = SubRip.render(cues)
        #expect(text.hasPrefix("1\n00:00:01,250 --> 00:00:03,500\nHello\nworld\n"))
        #expect(text.contains("01:02:05,500 --> 01:02:07,000"))
        #expect(SubRip.parse(text) == cues)
        #expect(SubRip.parse("garbage\n\n2\nnot a time\nx").isEmpty)
    }

    @Test func captionsFileSitsNextToTheTake() {
        let url = URL(filePath: "/tmp/Takes/Take-012-rear.mov")
        #expect(CaptionTranscriber.captionsURL(for: url).lastPathComponent == "Take-012.srt")
        #expect(SocialExporter.outputURL(for: url).lastPathComponent == "Take-012-social.mov")
    }

    // MARK: Vertical reframe

    @Test func smoothingFillsGapsAndHoldsSteady() {
        #expect(ReframePlanner.smoothedCenters([nil, nil]) == [0.5, 0.5])
        let filled = ReframePlanner.smoothedCenters([nil, 0.3, nil], window: 1, deadZone: 0)
        #expect(filled == [0.3, 0.3, 0.3])
        // Small sway inside the dead zone doesn't move the crop.
        let steady = ReframePlanner.smoothedCenters([0.5, 0.51, 0.49, 0.5, 0.52], window: 1)
        #expect(Set(steady).count == 1)
    }

    @Test func cropStaysInsideTheFrame() {
        let source = CGSize(width: 1920, height: 1080)
        let fraction = ReframePlanner.cropWidthFraction(source: source)
        #expect(abs(fraction - 0.31640625) < 0.0001)
        #expect(ReframePlanner.clampedCenter(0, source: source) == fraction / 2)
        #expect(ReframePlanner.clampedCenter(1, source: source) == 1 - fraction / 2)
        #expect(ReframePlanner.clampedCenter(0.5, source: source) == 0.5)
    }

    @Test func landscapeFillsVerticalCanvas() {
        let source = CGSize(width: 1920, height: 1080)
        let canvas = ReframePlanner.verticalSize
        let t = ReframePlanner.transform(orientedSize: source, centerX: 0.5)
        let rect = CGRect(origin: .zero, size: source).applying(t)
        #expect(abs(rect.height - canvas.height) < 0.5)
        #expect(abs(rect.midX - canvas.width / 2) < 0.5)
        // Hard left: the frame's left edge sits on the canvas's left edge, no black bar.
        let left = CGRect(origin: .zero, size: source).applying(ReframePlanner.transform(orientedSize: source, centerX: 0))
        #expect(abs(left.minX) < 0.5)
        let right = CGRect(origin: .zero, size: source).applying(ReframePlanner.transform(orientedSize: source, centerX: 1))
        #expect(abs(right.maxX - canvas.width) < 0.5)
    }

    @Test func portraitSourceFitsWidth() {
        let source = CGSize(width: 1080, height: 1920)
        let rect = CGRect(origin: .zero, size: source).applying(ReframePlanner.transform(orientedSize: source, centerX: 0.2))
        #expect(rect.equalTo(CGRect(origin: .zero, size: ReframePlanner.verticalSize)))
    }

    @Test func sampleTimesCoverTheTake() {
        let times = ReframePlanner.sampleTimes(duration: 10)
        #expect(times.first == 0)
        #expect(times.last == 10)
        #expect(times.count == 11)
        #expect(ReframePlanner.sampleTimes(duration: 3600).count == 120)
    }

    // MARK: Policies

    @Test func socialExportPolicy() {
        #expect(SocialExportPolicy.verdict(isRecording: false, isRendering: false, thermal: .nominal,
                                           isCharging: false, batteryLevel: 0.5) == .allowed)
        #expect(!SocialExportPolicy.verdict(isRecording: true, isRendering: false, thermal: .nominal,
                                            isCharging: true, batteryLevel: 1).isAllowed)
        #expect(!SocialExportPolicy.verdict(isRecording: false, isRendering: true, thermal: .nominal,
                                            isCharging: true, batteryLevel: 1).isAllowed)
        #expect(!SocialExportPolicy.verdict(isRecording: false, isRendering: false, thermal: .serious,
                                            isCharging: true, batteryLevel: 1).isAllowed)
        #expect(!SocialExportPolicy.verdict(isRecording: false, isRendering: false, thermal: .nominal,
                                            isCharging: false, batteryLevel: 0.1).isAllowed)
        #expect(SocialExportPolicy.verdict(isRecording: false, isRendering: false, thermal: .fair,
                                           isCharging: true, batteryLevel: 0.1) == .allowed)
    }

    @Test func audioRoutes() {
        #expect(AudioRoutePolicy.kind(forPortType: AVAudioSession.Port.usbAudio.rawValue) == .usb)
        #expect(AudioRoutePolicy.kind(forPortType: AVAudioSession.Port.builtInMic.rawValue) == .builtIn)
        #expect(AudioRoutePolicy.kind(forPortType: AVAudioSession.Port.bluetoothHFP.rawValue) == .bluetooth)
        #expect(AudioRoutePolicy.qualityNote(for: .bluetooth) != nil)
        #expect(AudioRoutePolicy.qualityNote(for: .usb) == nil)
        #expect(AudioRoutePolicy.isPrivateListening(outputPortTypes: [AVAudioSession.Port.headphones.rawValue]))
        #expect(!AudioRoutePolicy.isPrivateListening(outputPortTypes: [AVAudioSession.Port.builtInSpeaker.rawValue]))
    }

    // MARK: Persistence

    @MainActor @Test func newPreferencesAndFilesPersist() {
        let state = StudioSessionState()
        state.autoCaptionTakes = true
        state.hardwareButtonsRecord = false
        var take = TakeRecord(takeNumber: 1, sessionIdentifier: "s", startedAt: .now,
                              captureMode: .singleRearPro, exportStyle: .separateSyncedTracks)
        take.duration = 3
        take.captionsURL = URL(filePath: "/old/place/Take-001.srt")
        take.socialExportURL = URL(filePath: "/old/place/Take-001-social.mov")
        state.takes = [take]

        let document = ProjectStore.document(from: state)
        let restored = StudioSessionState()
        let dir = URL(filePath: "/new/Takes")
        ProjectStore.apply(document, to: restored, takesDirectory: dir)
        #expect(restored.autoCaptionTakes)
        #expect(!restored.hardwareButtonsRecord)
        #expect(restored.takes.first?.captionsURL == dir.appending(path: "Take-001.srt"))
        #expect(restored.takes.first?.socialExportURL == dir.appending(path: "Take-001-social.mov"))
    }
}
