import AppIntents
import Foundation

// =====================================================================================
//  App Intents (Phase 11): Siri, Shortcuts, Spotlight and the Action button
//
//  "Start a take in DuoDirector", "Stop the take", "Add a marker". Each intent opens
//  the app (the camera only runs in the foreground) and talks to the one CameraEngine
//  through IntentBridge. To put Record on the Action button: Settings › Action Button ›
//  Shortcut › DuoDirector › Start or Stop a Take.
//
//  Camera Control and the volume buttons are handled in CaptureRootView
//  (`onCameraCaptureEvent`), not here.
// =====================================================================================

/// Set by DuoDirectorApp. Weak so tests and previews never keep an engine alive.
@MainActor
enum IntentBridge {
    static weak var engine: CameraEngine?

    /// After a cold launch from an intent, give the camera a moment to come up.
    static func readyEngine() async -> CameraEngine? {
        for _ in 0..<30 {
            if let engine, engine.state.status != .idle, engine.state.status != .configuring { return engine }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return engine
    }
}

struct ToggleTakeIntent: AppIntent {
    static var title: LocalizedStringResource { "Start or Stop a Take" }
    static var description: IntentDescription { "Starts a take, or stops the one that's rolling." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = await IntentBridge.readyEngine() else { return .result(dialog: "Open DuoDirector first.") }
        let wasRecording = engine.state.isRecording
        engine.toggleRecording()
        return .result(dialog: wasRecording ? "Take stopped." : "Rolling.")
    }
}

struct StartTakeIntent: AppIntent {
    static var title: LocalizedStringResource { "Start a Take" }
    static var description: IntentDescription { "Starts recording after the countdown you've set." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = await IntentBridge.readyEngine() else { return .result(dialog: "Open DuoDirector first.") }
        guard !engine.state.isRecording else { return .result(dialog: "Already rolling.") }
        engine.startRecordingWithCountdown()
        return .result(dialog: "Rolling.")
    }
}

struct StopTakeIntent: AppIntent {
    static var title: LocalizedStringResource { "Stop the Take" }
    static var description: IntentDescription { "Stops and saves the take that's rolling." }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = await IntentBridge.readyEngine() else { return .result(dialog: "Open DuoDirector first.") }
        guard engine.state.isRecording else { return .result(dialog: "Nothing is rolling.") }
        engine.stopRecording()
        return .result(dialog: "Take stopped.")
    }
}

struct AddMarkerIntent: AppIntent {
    static var title: LocalizedStringResource { "Add a Marker" }
    static var description: IntentDescription { "Drops a marker in the take that's rolling." }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Note") var note: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let engine = await IntentBridge.readyEngine() else { return .result(dialog: "Open DuoDirector first.") }
        guard engine.state.isRecording else { return .result(dialog: "Start a take first.") }
        engine.dropMarker(note: note)
        return .result(dialog: "Marker added.")
    }
}

struct DuoDirectorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTakeIntent(),
                    phrases: ["Roll in \(.applicationName)", "Start or stop a take in \(.applicationName)"],
                    shortTitle: "Start or Stop", systemImageName: "record.circle")
        AppShortcut(intent: StartTakeIntent(),
                    phrases: ["Start a take in \(.applicationName)", "Start recording in \(.applicationName)"],
                    shortTitle: "Start a Take", systemImageName: "record.circle")
        AppShortcut(intent: StopTakeIntent(),
                    phrases: ["Stop the take in \(.applicationName)", "Stop recording in \(.applicationName)"],
                    shortTitle: "Stop the Take", systemImageName: "stop.circle")
        AppShortcut(intent: AddMarkerIntent(),
                    phrases: ["Add a marker in \(.applicationName)", "Mark this in \(.applicationName)"],
                    shortTitle: "Add a Marker", systemImageName: "bookmark")
    }
}
