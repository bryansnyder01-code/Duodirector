import Foundation

/// Phase 6: launch arguments for UI tests and App Store screenshot runs.
///
///   -DuoDirectorUITest YES             throwaway project file, no iCloud
///   -DuoDirectorMock YES               synthetic cameras (already used since Phase 1)
///   -DuoDirectorDemoMode YES           load the Demo Mode / App Store preset at launch
///   -DuoDirectorScreenshotScene <s>    cover | flat | tabletop | takes | social | diagnostics
///   -DuoDirectorRolling YES            start a (mock) take so the REC tally shows
///
/// Parsing is pure (`init(arguments:)`) so it's unit-tested.
struct LaunchOptions: Equatable, Sendable {

    enum ScreenshotScene: String, CaseIterable, Sendable {
        case cover, flat, tabletop, takes, social, diagnostics
    }

    var isUITest = false
    var demoMode = false
    var scene: ScreenshotScene?
    var rolling = false

    static let current = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: "-\(key)"), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func flag(_ key: String) -> Bool {
            guard let raw = value(key)?.lowercased() else { return false }
            return ["yes", "true", "1"].contains(raw)
        }
        isUITest = flag("DuoDirectorUITest")
        demoMode = flag("DuoDirectorDemoMode")
        rolling = flag("DuoDirectorRolling")
        scene = value("DuoDirectorScreenshotScene").flatMap { ScreenshotScene(rawValue: $0.lowercased()) }
    }
}
