import SwiftUI

/// App entry point.
///
/// One `StudioSessionState` and one `CameraEngine` are created here and handed to every
/// screen. The outer cover display (CameraCaptureAccessory) and the inner display are
/// rendered in the same process, so both read and write the *same* `@Observable`
/// instance and stay in sync with no extra plumbing.
///
/// Important: the accessory content is hosted in a separate system scene, so do not rely on
/// `.environment(...)` propagating into it. Pass `state` / `engine` explicitly (we do).
///
/// Phase 5: `ProjectStore` restores the saved project BEFORE the engine is created (so
/// the restored capture mode / format is what the first configure uses), then autosaves.
///
/// Phase 6: `CloudSyncController` (iCloud Drive) and `RemoteProducerLink`
/// (MultipeerConnectivity) are created here and handed to the engine. UI-test launch
/// arguments (`LaunchOptions`) can skip persistence and stage Demo Mode screenshots.
///
/// Phase 8: `LiveStreamController` (Go Live over RTMP/RTMPS) is handed to the engine too.
///
/// Phase 11: the recording Live Activity and the App Intents bridge.
@main
struct DuoDirectorApp: App {
    @State private var state: StudioSessionState
    @State private var engine: CameraEngine
    @State private var store: ProjectStore
    @State private var cloud: CloudSyncController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let options = LaunchOptions.current
        let state = StudioSessionState()
        // UI tests use a throwaway project file so screenshots never touch real work.
        let store = ProjectStore(state: state, fileURL: options.isUITest
                                 ? FileManager.default.temporaryDirectory.appending(path: "uitest-project.json")
                                 : ProjectStore.defaultURL)
        if !options.isUITest { store.load() }
        store.startAutosave()
        let engine = CameraEngine(state: state)
        let cloud = CloudSyncController(state: state, store: store)
        engine.cloudSync = options.isUITest ? nil : cloud
        engine.remoteLink = RemoteProducerLink(state: state, engine: engine)
        engine.liveStream = LiveStreamController(state: state, engine: engine)
        engine.guests = GuestSessionController(state: state, engine: engine)
        // Phase 11: Live Activity record timer, and Siri / Shortcuts / Action button.
        engine.recordingActivity = options.isUITest ? nil : RecordingActivityController()
        IntentBridge.engine = engine
        _state = State(initialValue: state)
        _store = State(initialValue: store)
        _cloud = State(initialValue: cloud)
        _engine = State(initialValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            CaptureRootView(state: state, engine: engine)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Flush the debounce before iOS can suspend us.
            if phase != .active { store.saveNow() }
        }
    }
}
