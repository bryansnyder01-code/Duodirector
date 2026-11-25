import ActivityKit
import Foundation

/// Phase 11: the Live Activity shown on the Lock Screen and in the Dynamic Island while a
/// take is rolling. Compiled into both the app and the DuoDirectorWidgets extension.
struct RecordingActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var takeNumber: Int
        var startedAt: Date
        var markerCount: Int
        var isLive: Bool
    }

    /// Active shot title, if any ("Intro", "B-roll 3").
    var shotTitle: String?
}
