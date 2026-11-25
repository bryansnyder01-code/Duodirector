import Foundation
import Testing
@testable import DuoDirector

@Suite("Chapters, iCloud merge, launch options, remote protocol")
struct Phase6Tests {

    // MARK: Chapters

    @Test func chaptersStartAtZeroAndCoverTheWholeTake() {
        let markers = [TakeMarker(takeNumber: 1, timestamp: 30, rating: 4, note: "Laugh"),
                       TakeMarker(takeNumber: 1, timestamp: 10, rating: 5, note: "Good take")]
        let chapters = ChapterTrackWriter.chapters(for: markers, duration: 60)
        #expect(chapters.map(\.start) == [0, 10, 30])
        #expect(chapters.first?.title == "Start")
        #expect(chapters[1].title == "★★★★★ Good take")
        #expect(abs(chapters.map(\.duration).reduce(0, +) - 60) < 0.001)
    }

    @Test func nearbyMarkersMerge() {
        let markers = [TakeMarker(takeNumber: 1, timestamp: 5.0, rating: 3, note: "A"),
                       TakeMarker(takeNumber: 1, timestamp: 5.2, rating: 3, note: "B")]
        let chapters = ChapterTrackWriter.chapters(for: markers, duration: 20)
        #expect(chapters.count == 2)
        #expect(chapters[1].title.hasSuffix("A / B"))
    }

    @Test func markerAtZeroReplacesStart() {
        let chapters = ChapterTrackWriter.chapters(for: [TakeMarker(takeNumber: 1, timestamp: 0.1, rating: 3, note: "Intro")],
                                                   duration: 10)
        #expect(chapters.count == 1)
        #expect(chapters[0].title.hasSuffix("Intro"))
    }

    @Test func markersPastTheEndAreClamped() {
        let chapters = ChapterTrackWriter.chapters(for: [TakeMarker(takeNumber: 1, timestamp: 99, rating: 3, note: "Late")],
                                                   duration: 10)
        #expect(chapters.last!.start <= 10)
        #expect(chapters.allSatisfy { $0.duration > 0 })
    }

    @Test func quickTimeTextSampleLayout() {
        let data = ChapterTrackWriter.textSampleData("Hé")          // 3 UTF-8 bytes
        #expect(Array(data.prefix(2)) == [0, 3])                    // big-endian length
        #expect(data.count == 2 + 3 + 12)
        #expect(String(decoding: data[5 + 4 ..< 5 + 8], as: UTF8.self) == "encd")
        #expect(Array(data.suffix(4)) == [0, 0, 1, 0])               // UTF-8
    }

    // MARK: iCloud merge

    private func doc(_ seconds: Double, device: String, script: String, takes: [Int], ratings: [Int: Int] = [:],
                     next: Int) -> ProjectDocument {
        ProjectDocument(
            savedAt: Date(timeIntervalSince1970: seconds), savedByDevice: device, scriptText: script,
            takes: takes.map { n in
                TakeRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, takeNumber: n,
                           sessionIdentifier: "S\(n)", startedAt: .init(timeIntervalSince1970: Double(n)),
                           rating: ratings[n] ?? 0, captureMode: .singleRearPro, exportStyle: .pictureInPicture)
            },
            nextTakeNumber: next)
    }

    @Test func newerDocumentWinsContentAndTakesUnion() {
        let local = doc(100, device: "A", script: "local", takes: [1, 2], ratings: [2: 3], next: 3)
        let remote = doc(200, device: "B", script: "remote", takes: [2, 3], ratings: [2: 5], next: 4)
        let merged = CloudMerge.merge(local: local, remote: remote)
        #expect(merged.scriptText == "remote")
        #expect(merged.takes?.map(\.takeNumber) == [1, 2, 3])
        #expect(merged.takes?.first { $0.takeNumber == 2 }?.rating == 5)   // newer edit wins
        #expect(merged.nextTakeNumber == 4)
        #expect(merged.savedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func takeNumbersNeverCollide() {
        let local = doc(300, device: "A", script: "", takes: [7], next: 8)
        let remote = doc(200, device: "B", script: "", takes: [9], next: 3)
        #expect(CloudMerge.merge(local: local, remote: remote).nextTakeNumber == 10)
    }

    @Test func ownEchoesAndOlderVersionsAreIgnored() {
        let local = doc(200, device: "A", script: "", takes: [], next: 1)
        #expect(!CloudMerge.shouldApply(remote: doc(300, device: "A", script: "", takes: [], next: 1), local: local, deviceID: "A"))
        #expect(!CloudMerge.shouldApply(remote: doc(100, device: "B", script: "", takes: [], next: 1), local: local, deviceID: "A"))
        #expect(CloudMerge.shouldApply(remote: doc(300, device: "B", script: "", takes: [], next: 1), local: local, deviceID: "A"))
    }

    // MARK: Launch options

    @Test func parsesScreenshotArguments() {
        let options = LaunchOptions(arguments: ["DuoDirector", "-DuoDirectorUITest", "YES", "-DuoDirectorDemoMode", "1",
                                                "-DuoDirectorScreenshotScene", "Tabletop", "-DuoDirectorRolling", "no"])
        #expect(options.isUITest && options.demoMode && !options.rolling)
        #expect(options.scene == .tabletop)
        #expect(LaunchOptions(arguments: ["-DuoDirectorScreenshotScene"]).scene == nil)   // missing value
        #expect(LaunchOptions(arguments: []) == LaunchOptions(arguments: ["DuoDirector"]))
    }

    // MARK: Remote protocol

    @Test func remoteMessagesRoundTrip() throws {
        let commands: [RemoteCommand] = [.toggleRecording, .dropMarker(rating: 5, note: "Good take"), .rateTake(4),
                                         .togglePrompter, .resetPrompter, .setPrompterSpeed(55), .nextShot]
        for command in commands {
            #expect(RemoteMessage.decode(try RemoteMessage.command(command).encoded()) == .command(command))
        }
        let status = RemoteStatus(isRecording: true, recordingDuration: 12.5, takeNumber: 3, captureMode: .dualPodcastMultiCam,
                                  leftDB: -12, rightDB: -18, isClipping: false, thermal: 2, batteryLevel: nil, isCharging: true,
                                  minutesLeft: 41, isPrompterPlaying: true, prompterSpeed: 40, activeShotTitle: "Intro",
                                  markerCount: 2, takeRating: 4, countdownRemaining: nil, previewAvailable: false)
        #expect(RemoteMessage.decode(try RemoteMessage.status(status).encoded()) == .status(status))
        #expect(RemoteMessage.decode(Data("garbage".utf8)) == nil)
    }
}
