import Foundation
import Observation
import CoreGraphics
import SwiftUI   // Axis

// =====================================================================================
//  StudioSessionState: the single @Observable source of truth (Phase 2).
//
//  Shared by the inner display, the outer cover display (CameraCaptureAccessory), and
//  CameraEngine. Any SwiftUI view that READS a property re-renders when it changes, no
//  matter which screen changed it. Everything is @MainActor; CameraEngine's capture
//  queues hop back to the main actor before writing here.
// =====================================================================================

// MARK: - Lens

/// The iPhone Duo's rear 48MP Dual Fusion system, as presented to the user.
enum LensOption: String, CaseIterable, Identifiable, Codable, Sendable {
    case ultraWide13   // 48MP Fusion Ultra Wide, 13mm, 0.5×  → builtInUltraWideCamera
    case main26        // 48MP Fusion Main, 26mm, 1×          → builtInWideAngleCamera
    case crop52        // 2× optical-quality crop, 52mm       → builtInWideAngleCamera @ videoZoomFactor 2.0

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ultraWide13: "0.5×"
        case .main26: "1×"
        case .crop52: "2×"
        }
    }

    var focalLength: String {
        switch self {
        case .ultraWide13: "13mm"
        case .main26: "26mm"
        case .crop52: "52mm"
        }
    }

    var detail: String {
        switch self {
        case .ultraWide13: "Fusion Ultra Wide 13mm"
        case .main26: "Fusion Main 26mm"
        case .crop52: "2× crop 52mm"
        }
    }

    /// Physical module this lens runs on. 1× and 2× share the Main module, which is what
    /// lets 1× ↔ 2× be a smooth zoom ramp instead of an input swap.
    var usesMainModule: Bool { self != .ultraWide13 }

    /// `videoZoomFactor` on the physical module.
    var zoomFactor: CGFloat { self == .crop52 ? 2.0 : 1.0 }
}

// MARK: - Format presets

enum ResolutionPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case hd1080, uhd4K
    var id: String { rawValue }
    var label: String { self == .uhd4K ? "4K" : "1080p" }
    var width: Int32 { self == .uhd4K ? 3840 : 1920 }
    var height: Int32 { self == .uhd4K ? 2160 : 1080 }
    /// Target HEVC average bitrate. Roughly double Apple's Camera-app defaults, so grading
    /// has headroom. Scaled by frame rate in CameraEngine.
    var baseBitrate: Int { self == .uhd4K ? 100_000_000 : 40_000_000 }   // at 30fps
}

enum FrameRatePreset: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = 24, fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue)" }
}

enum CaptureSourceMode: String, Sendable {
    case live   // real AVCaptureSession
    case mock   // Simulator / no camera: synthetic frames, synthetic meters, timer-only recording
}

/// Codec for AVCaptureMovieFileOutput. ProRes is offered only when the active
/// connection lists it in `availableVideoCodecTypes`.
enum VideoCodecPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case hevc, proRes422HQ
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "ProRes 422 HQ" }
}

// MARK: - Hinge posture (Phase 3)

/// Physical posture of the iPhone Duo hinge.
///
/// Source of truth on device: SwiftUI `.onHingeChange(isEnabled:_:)` (iOS 27.1), wrapped by
/// `duoOnHingeChange` in Platform/DuoPlatformAPIs.swift. It delivers `DeviceHinge.angle`.
/// Book vs tabletop can't be told apart from the angle alone, so we combine it with the
/// fold AXIS that InnerDirectorView reads from the `.division` ReservedRegion.
///
/// IMPORTANT (Apple guidance): hinge callbacks are for treating the hinge as INPUT (badges,
/// behaviour, animation), not for layout. Layout is driven by ArrangementView and
/// ReservedRegion in InnerDirectorView. `hingePosture` is used for behaviour (e.g. the
/// closed-device capture UI, auto-opening the tabletop deck, status badges).
enum HingePosture: String, CaseIterable, Identifiable, Codable, Sendable {
    case flat             // ~180°, fully unfolded
    case bookHalfFolded   // partially folded, crease vertical
    case tabletopLShape   // ~90°, crease horizontal (L-pose on a desk)
    case closed           // folded shut; the app runs on the 5.4" cover display

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: "Flat"
        case .bookHalfFolded: "Book"
        case .tabletopLShape: "Tabletop"
        case .closed: "Closed"
        }
    }

    var symbol: String {
        switch self {
        case .flat: "rectangle"
        case .bookHalfFolded: "book"
        case .tabletopLShape: "laptopcomputer"
        case .closed: "iphone.gen3"
        }
    }

    /// Angle → posture. `foldIsHorizontal` comes from the live `.division` region.
    /// Thresholds are our choice (VERIFY on hardware): ≤ 15° closed, ≥ 165° flat.
    static func from(angleDegrees: Double, foldIsHorizontal: Bool?) -> HingePosture {
        if angleDegrees <= 15 { return .closed }
        if angleDegrees >= 165 { return .flat }
        return foldIsHorizontal == true ? .tabletopLShape : .bookHalfFolded
    }
}

enum CaptureStatus: Equatable, Sendable {
    case idle
    case configuring
    case ready
    case recording(startedAt: Date)
    case saving
    case failed(String)
    case unauthorized

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// A timestamped take note ("Mark Take").
///
/// Phase 4: carries a 1–5 star rating and is exported to the JSON / FCPXML sidecar next
/// to the .mov files (see Camera/TakeSidecarExporter.swift).
struct TakeMarker: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var takeNumber: Int
    var timestamp: TimeInterval   // seconds into the take
    var rating: Int = 3           // 1…5 stars
    var note: String

    var isGoodTake: Bool { rating >= 5 }
    var stars: String { String(repeating: "★", count: rating) + String(repeating: "☆", count: max(0, 5 - rating)) }
}

/// Phase 1–3 name, kept so older call sites read naturally.
typealias ChapterMarker = TakeMarker

/// One finished (or rolling) take, possibly two synced camera files.
struct TakeRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var takeNumber: Int
    /// Shared by every file of the take (rear + inner), written into each .mov's metadata,
    /// the sidecar, and used to group them after export.
    var sessionIdentifier: String
    var startedAt: Date
    var duration: TimeInterval = 0
    var rating: Int = 0                    // 0 = unrated, else 1…5
    var captureMode: CaptureMode
    var exportStyle: DualExportStyle
    var rearFileURL: URL?
    var innerFileURL: URL?
    /// Inner-file start minus rear-file start, on the session's synchronization clock.
    /// NLEs use it to line the two tracks up (FCPXML lane offset).
    var innerStartOffset: TimeInterval = 0
    var sidecarJSONURL: URL?
    var sidecarFCPXMLURL: URL?
    var photosIdentifiers: [String] = []
    var shotTitle: String?
    /// Phase 5: on-device split/PiP render (CompositeRenderer), nil until rendered.
    var compositeFileURL: URL?
    /// Phase 11: on-device captions (.srt next to the camera files), nil until made.
    var captionsURL: URL?
    /// Phase 11: last social export (vertical and/or burned-in captions).
    var socialExportURL: URL?

    /// True if at least one camera file for this take exists on disk.
    var hasMediaOnDisk: Bool {
        [rearFileURL, innerFileURL].compactMap { $0 }.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The take was recorded to files that are gone (deleted in Files, or a project synced
    /// from another device). Takes with no files at all, such as Demo Mode's, don't count.
    var isMissingMedia: Bool {
        (rearFileURL != nil || innerFileURL != nil) && !hasMediaOnDisk
    }
}

// MARK: - Phase 4: capture mode & dual export

enum CaptureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// One rear camera at full quality (4K, up to 60fps, Dolby Vision / ProRes).
    case singleRearPro
    /// AVCaptureMultiCamSession: rear 48MP Fusion Main (Guest) + inner under-display
    /// camera (Host), each to its own .mov. Capped at 30fps for bandwidth.
    case dualPodcastMultiCam

    var id: String { rawValue }
    var label: String { self == .singleRearPro ? "Solo Rear 4K" : "Dual-Cam Podcast" }
    var symbol: String { self == .singleRearPro ? "camera" : "person.2.wave.2" }
}

/// How dual-cam takes are delivered. Files are always two synced .mov tracks; the style
/// sets the preview layout and the timeline the FCPXML sidecar builds (lanes and
/// transforms), so the edit opens already composed in Final Cut Pro / DaVinci Resolve.
enum DualExportStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case separateSyncedTracks, splitScreenComposite, pictureInPicture
    var id: String { rawValue }
    var label: String {
        switch self {
        case .separateSyncedTracks: "Separate synced tracks"
        case .splitScreenComposite: "Split-screen composite"
        case .pictureInPicture: "Picture-in-picture"
        }
    }
}

enum PiPCorner: String, CaseIterable, Codable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

/// One row of the shot list (Phase 3).
/// `sketchData` is a serialized PencilKit drawing (`PKDrawing.dataRepresentation()`);
/// decode with `PKDrawing(data:)`. Nil until the creator attaches a sketch.
struct ShotListItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var cameraLens: LensOption = .main26
    var framingNote: String = ""
    var isCompleted = false
    var sketchData: Data?
}

// MARK: - Shared state

@Observable
@MainActor
final class StudioSessionState {

    // ── Capture source & status ───────────────────────────────────────────────────
    var sourceMode: CaptureSourceMode = StudioSessionState.defaultSourceMode
    var status: CaptureStatus = .idle
    /// Bumped ONLY when the engine swaps AVCaptureSession objects (single ↔ multicam).
    /// Lens switches reconfigure the running session in place and do NOT bump this, so
    /// preview layers and the CameraCaptureAccessory stay attached.
    var sessionGeneration = 0
    var statusNote: String?                // non-fatal info, e.g. "Dolby Vision off at 60fps"

    // ── Lens (rear 48MP Dual Fusion) ──────────────────────────────────────────────
    var activeLens: LensOption = .main26
    /// True when the active format lists 2.0 in `secondaryNativeResolutionZoomFactors`,
    /// i.e. the 2× crop reads out native 48MP pixels (no upscaling).
    var isCropOpticalQuality = false

    // ── Resolution / frame rate / HDR ─────────────────────────────────────────────
    var resolution: ResolutionPreset = .uhd4K
    var frameRate: FrameRatePreset = .fps24
    /// User's request for Dolby Vision HDR.
    var isDolbyVisionEnabled = true
    /// Whether the ACTIVE device format supports HLG BT.2020 at the current res/fps.
    /// The UI disables the toggle when false; recording falls back to SDR.
    var isDolbyVisionSupported = false
    var isDolbyVisionActive: Bool { isDolbyVisionEnabled && isDolbyVisionSupported }

    // ── Manual camera overrides ───────────────────────────────────────────────────
    var isAutoExposure = true
    var isoValue: Float = 100
    var shutterDuration: Double = 1.0 / 48        // seconds (1/48 = 180° at 24fps)
    var isAutoWhiteBalance = true
    var whiteBalanceKelvin: Float = 5600
    var isAutoFocus = true
    var manualFocusPosition: Float = 0.5           // 0.0 (near) … 1.0 (far)
    /// Device limits, published by CameraEngine from the active format so sliders clamp.
    var isoRange: ClosedRange<Float> = 25...3200
    var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 24)

    // ── Audio metering (AVCaptureAudioDataOutput) ─────────────────────────────────
    var leftChannelDB: Float = -160
    var rightChannelDB: Float = -160
    var leftChannelRMS: Float = -160
    var rightChannelRMS: Float = -160
    /// Peak-hold clip flag: set when either channel reaches the clip threshold and held
    /// for `CameraEngine.clipHoldSeconds` after the last clipping buffer.
    var isAudioClipping = false
    var audioGain: Float = 0.5                     // 0.0 … 1.0 → AVAudioSession input gain

    // ── Teleprompter ──────────────────────────────────────────────────────────────
    var scriptText: String = StudioSessionState.sampleScript
    private(set) var isPrompterPlaying = false
    /// Points per second. Use `setPrompterScrollSpeed(_:)` while playing so position
    /// doesn't jump.
    private(set) var prompterScrollSpeed: Double = 40
    var prompterFontSize: Double = 28              // 20 … 36 pt
    var prompterMirrored = false                   // for beam-splitter glass rigs
    var countdownSeconds: Int = 3                  // 0, 3, or 5
    var countdownRemaining: Int?                   // non-nil while counting down

    static let prompterFontRange: ClosedRange<Double> = 20...36
    static let countdownOptions = [0, 3, 5]

    /// Prompter position is computed from time, not pushed by a timer: views wrap the
    /// text in `TimelineView(.animation)` and call `prompterOffset(at:)`. Both displays
    /// derive the same offset from the same clock, so they scroll in lock-step with no
    /// per-frame state writes.
    @ObservationIgnored private var prompterAccumulated: Double = 0
    private var prompterPlayStartedAt: Date?
    private var prompterResetToken = 0             // observed so a paused reset redraws

    // ── Overlays ──────────────────────────────────────────────────────────────────
    var show16x9Guide = true
    var show9x16Guide = true
    var showFocusPeaking = false
    var showZebraStripes = false
    var zebraThreshold: Double = 0.95              // 0.70 … 1.0 luma
    static let zebraRange: ClosedRange<Double> = 0.70...1.0
    var needsFrameAnalysis: Bool { showFocusPeaking || showZebraStripes || showHistogram }

    // ── Recording session metadata ────────────────────────────────────────────────
    var recordingDuration: TimeInterval = 0
    var takeNumber = 1
    var chapterMarkers: [ChapterMarker] = []
    /// Local file URL of the most recent finished take (kept in Documents/Takes).
    var lastSavedAssetURL: URL?
    /// `PHAsset.localIdentifier` if the take was also saved to Photos.
    var lastSavedPhotosIdentifier: String?
    var lastSaveMessage: String?

    // ── Codec (Phase 3 overflow menu) ─────────────────────────────────────────────
    var preferredCodec: VideoCodecPreset = .hevc
    var isProResSupported = false

    // ── Capture mode / multi-cam (Phase 4) ────────────────────────────────────────
    var captureMode: CaptureMode = .singleRearPro
    var dualExportStyle: DualExportStyle = .pictureInPicture
    /// From `AVCaptureMultiCamSession.isMultiCamSupported` at startup. False in the
    /// Simulator unless Demo Mode or "Simulate MultiCam" (diagnostics) turns it on.
    var isMultiCamSupported = false
    var simulateMultiCamSupport = false
    /// Where the Host (inner camera) PiP sits; the PiP skips corners that hit an occlusion.
    var pipCorner: PiPCorner = .bottomTrailing
    /// MultiCam hardware/system-pressure cost reported after configuration (≤ 1.0 is OK).
    var multiCamHardwareCost: Float = 0
    var multiCamSystemPressureCost: Float = 0
    var isDualCam: Bool { captureMode == .dualPodcastMultiCam }
    /// Phase 1–3 names.
    var isDualAngleEnabled: Bool { isDualCam }
    var isDualAngleSupported: Bool { isMultiCamSupported }

    // ── Thermal / battery / accessory resilience (Phase 4) ───────────────────────
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// Camera-specific pressure from AVCaptureDevice.systemPressureState (often earlier
    /// than the process thermal state).
    var cameraPressureLevel: String = "nominal"
    /// Overlays turned off by the thermal guard (restored when it cools down).
    var overlaysSuspendedForThermal = false
    /// Cover accessory content paused by the thermal guard.
    var accessorySuspendedForThermal = false
    /// Frame rate the thermal guard stepped down from (restored when it cools down).
    var thermalSteppedDownFrom: FrameRatePreset?
    var batteryLevel: Float?                       // 0…1, nil if unknown
    var isCharging = false
    var availableStorageBytes: Int64?
    var estimatedRecordingMinutesLeft: Int?
    /// Non-intrusive banner (thermal step-downs, cover-monitor withdrawal, low storage…).
    var systemStatusBannerMessage: String?

    // ── Takes & export metadata (Phase 4) ─────────────────────────────────────────
    var takes: [TakeRecord] = []
    /// Phase 5: composite render progress per take (0…1). Present only while rendering.
    var compositeRenderProgress: [TakeRecord.ID: Double] = [:]
    /// Phase 5: render split/PiP composites by themselves when the phone is cool + charging.
    var autoRenderComposites = false
    /// Phase 11: on-device caption jobs in flight (take ids) and social exports (0…1).
    var captioningTakeIDs: Set<TakeRecord.ID> = []
    var socialExportProgress: [TakeRecord.ID: Double] = [:]
    /// Phase 11: transcribe each finished take on the phone (off by default: it's work
    /// the phone does right after a take, when it may be warm).
    var autoCaptionTakes = false
    /// Phase 11: Camera Control / volume buttons start and stop takes.
    var hardwareButtonsRecord = true
    /// Phase 5: where markers are written (diagnostics), e.g. "In file + sidecar".
    var markerTrackStatus = "Unknown"
    /// Phase 5: when the project was last saved to disk (nil = never / not persisted).
    var lastPersistedAt: Date?
    /// Phase 7: tombstones for deleted takes and markers (id → deletion time), so a
    /// deletion on one device removes the take everywhere instead of syncing back.
    var deletedTakeIDs: [TakeRecord.ID: Date] = [:]
    var deletedMarkerIDs: [TakeMarker.ID: Date] = [:]
    var currentTake: TakeRecord? { takes.last(where: { $0.takeNumber == takeNumber }) ?? takes.last }

    // ── Demo / App Store preview (Phase 4) ────────────────────────────────────────
    var isDemoMode = false

    // ── Go Live (Phase 8) ─────────────────────────────────────────────────────────
    /// Mirrored by LiveStreamController so every display (inner, cover, remote) can show
    /// the LIVE tally without holding the controller.
    var liveState: LiveState = .idle
    var liveStats = LiveStats()
    var isLive: Bool { liveState.isLive }

    // ── Remote guests (Phase 9) ───────────────────────────────────────────────────
    var guestState: GuestState = .idle
    var guestLayout: GuestLayout = .pictureInPicture
    var includeGuestInStream = true

    // ── Grid / histogram / mirroring (Phase 3) ────────────────────────────────────
    var showThirdsGrid = false
    var gridOpacity: Double = 0.5                  // guides + grid line opacity, 0.1 … 1.0
    var showHistogram = true
    var mirrorOuterPreview = true                  // cover-display preview reads like a mirror

    // ── Hinge posture (Phase 3) ───────────────────────────────────────────────────
    /// Posture from hardware (`.onHingeChange`). Use `hingePosture` to read.
    private(set) var hardwareHingePosture: HingePosture = .flat
    private(set) var hingeAngleDegrees: Double?    // nil when no hinge is reported
    /// Axis of the active `.division` region, reported by InnerDirectorView via
    /// onGeometryChange. Only the axis is kept, never the frame (frames go stale).
    private(set) var foldAxis: Axis?
    /// Simulator / testing override, from the toolbar's "Simulate posture" picker.
    var simulatedHingePosture: HingePosture?
    /// Effective posture: simulation wins, then hardware.
    var hingePosture: HingePosture { simulatedHingePosture ?? hardwareHingePosture }

    // ── Shot list & storyboarding (Phase 3) ───────────────────────────────────────
    var shotList: [ShotListItem] = StudioSessionState.sampleShotList
    var activeShotID: ShotListItem.ID? = StudioSessionState.sampleShotList.first?.id
    var isShotListDrawerOpen = false
    /// Apple Pencil scratchpad (serialized PKDrawing). Attach copies it to the active shot.
    var currentSketchData = Data()

    // ── Displays / debugging ──────────────────────────────────────────────────────
    /// True while iOS 27.1 is actually presenting our CameraCaptureAccessory on the cover
    /// display (from `onAvailabilityChange`). False when unavailable OR withdrawn.
    var isOuterAccessoryActive = false
    /// The user's toggle, bound (with the thermal guard) to CameraCaptureAccessory(isEnabled:).
    var isOuterMonitorEnabled = true
    /// True when the system withdrew the accessory while we still wanted it, e.g. during
    /// a shoot. InnerDirectorView then surfaces its inline mini-teleprompter and full
    /// controls; recording is unaffected because the session never depended on it.
    var wasOuterAccessoryWithdrawn = false
    /// Effective isEnabled for CameraCaptureAccessory (user toggle AND not thermally paused).
    var outerAccessoryShouldBeEnabled: Bool { isOuterMonitorEnabled && !accessorySuspendedForThermal }
    /// Phase 1–3 name.
    var isOuterMonitorAvailable: Bool { isOuterAccessoryActive }

    // MARK: Derived

    var isRecording: Bool { status.isRecording }

    var recordingStart: Date? {
        if case .recording(let start) = status { return start }
        return nil
    }

    var activeShot: ShotListItem? {
        guard let id = activeShotID else { return shotList.first }
        return shotList.first { $0.id == id }
    }

    var activeShotIndex: Int? {
        guard let id = activeShotID ?? shotList.first?.id else { return nil }
        return shotList.firstIndex { $0.id == id }
    }

    var completedShotCount: Int { shotList.filter(\.isCompleted).count }

    // MARK: Hinge

    /// Called from `.onHingeChange` (via `duoOnHingeChange`). nil = no hinge reported.
    func updateHinge(angleDegrees: Double?) {
        hingeAngleDegrees = angleDegrees
        if let angleDegrees { recomputeHinge(angleDegrees) } else { hardwareHingePosture = .flat }
    }

    func setFoldAxis(_ axis: Axis?) {
        guard axis != foldAxis else { return }
        foldAxis = axis
        if let angle = hingeAngleDegrees { recomputeHinge(angle) }
    }

    private func recomputeHinge(_ angle: Double) {
        let next = HingePosture.from(angleDegrees: angle, foldIsHorizontal: foldAxis.map { $0 == .horizontal })
        if next != hardwareHingePosture { hardwareHingePosture = next }
    }

    // MARK: Shot list

    /// Make `id` the active shot and load its sketch into the scratchpad.
    func activateShot(_ id: ShotListItem.ID) {
        activeShotID = id
        currentSketchData = shotList.first { $0.id == id }?.sketchData ?? Data()
    }

    /// Copy the scratchpad onto the active shot (or clear it when the pad is empty).
    func attachSketchToActiveShot() {
        guard let index = activeShotIndex else { return }
        shotList[index].sketchData = currentSketchData.isEmpty ? nil : currentSketchData
    }

    func toggleCompleted(_ id: ShotListItem.ID) {
        guard let index = shotList.firstIndex(where: { $0.id == id }) else { return }
        shotList[index].isCompleted.toggle()
    }

    /// Mark the active shot done and move to the next unfinished one.
    func completeActiveShotAndAdvance() {
        guard let index = activeShotIndex else { return }
        shotList[index].isCompleted = true
        attachSketchToActiveShot()
        if let next = shotList.indices.dropFirst(index + 1).first(where: { !shotList[$0].isCompleted }) {
            activateShot(shotList[next].id)
        }
    }

    func addShot(title: String? = nil) {
        let item = ShotListItem(title: title ?? "Shot \(shotList.count + 1)", cameraLens: activeLens)
        shotList.append(item)
        activateShot(item.id)
    }

    func markers(forTake take: Int) -> [ChapterMarker] { chapterMarkers.filter { $0.takeNumber == take } }

    // MARK: Teleprompter

    func prompterOffset(at date: Date) -> Double {
        _ = prompterResetToken   // register observation dependency
        guard let start = prompterPlayStartedAt else { return prompterAccumulated }
        return prompterAccumulated + max(0, date.timeIntervalSince(start)) * prompterScrollSpeed
    }

    func setPrompterPlaying(_ playing: Bool) {
        guard playing != isPrompterPlaying else { return }
        if playing {
            prompterPlayStartedAt = Date()
        } else {
            prompterAccumulated = prompterOffset(at: Date())
            prompterPlayStartedAt = nil
        }
        isPrompterPlaying = playing
    }

    func togglePrompter() { setPrompterPlaying(!isPrompterPlaying) }

    func resetPrompter() {
        prompterAccumulated = 0
        if isPrompterPlaying { prompterPlayStartedAt = Date() }
        prompterResetToken += 1
    }

    func setPrompterScrollSpeed(_ speed: Double) {
        // Fold elapsed distance in at the OLD speed before switching.
        if isPrompterPlaying {
            prompterAccumulated = prompterOffset(at: Date())
            prompterPlayStartedAt = Date()
        }
        prompterScrollSpeed = max(5, min(200, speed))
    }

    // MARK: Markers

    @discardableResult
    func addChapterMarker(note: String? = nil, goodTake: Bool = false) -> TakeMarker {
        addMarker(note: note ?? (goodTake ? "Good take" : nil), rating: goodTake ? 5 : 3)
    }

    /// Drop a rated marker at the current point of the take.
    @discardableResult
    func addMarker(note: String? = nil, rating: Int = 3) -> TakeMarker {
        let timestamp = recordingStart.map { Date().timeIntervalSince($0) } ?? recordingDuration
        let marker = TakeMarker(
            takeNumber: takeNumber,
            timestamp: timestamp,
            rating: max(1, min(5, rating)),
            note: note ?? "Marker \(markers(forTake: takeNumber).count + 1)")
        chapterMarkers.append(marker)
        return marker
    }

    /// "Rate Take": rates the rolling take, or the last finished one.
    func rateCurrentTake(_ stars: Int) {
        let target = isRecording ? takeNumber : (takes.last?.takeNumber ?? takeNumber)
        if let index = takes.lastIndex(where: { $0.takeNumber == target }) {
            takes[index].rating = max(0, min(5, stars))
        }
    }

    var currentTakeRating: Int {
        let target = isRecording ? takeNumber : (takes.last?.takeNumber ?? takeNumber)
        return takes.last(where: { $0.takeNumber == target })?.rating ?? 0
    }

    // MARK: Banner

    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    /// Shows a banner; auto-clears after `seconds` unless replaced (nil = sticky).
    func showBanner(_ message: String, seconds: Double? = 6) {
        // Phase 7: static banners are looked up in Localizable.xcstrings at runtime
        // (interpolated ones fall back to English until they move to String(localized:)).
        let message = NSLocalizedString(message, comment: "System status banner")
        systemStatusBannerMessage = message
        // VoiceOver: banners are important (heat, storage, accessory), so announce them.
        AccessibilityNotification.Announcement(message).post()
        bannerTask?.cancel()
        guard let seconds else { return }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.systemStatusBannerMessage == message { self?.systemStatusBannerMessage = nil }
        }
    }

    // MARK: Defaults

    /// Simulator always runs in mock mode. On device, pass launch argument
    /// `-DuoDirectorMock YES` to force it.
    static var defaultSourceMode: CaptureSourceMode {
        #if targetEnvironment(simulator)
        return .mock
        #else
        return UserDefaults.standard.bool(forKey: "DuoDirectorMock") ? .mock : .live
        #endif
    }

    static let sampleScript = """
    Welcome back to the channel.
    Today we're unfolding the iPhone Duo and setting it up as a full director's station.
    The cover screen faces me as a field monitor and teleprompter,
    while the inner screen handles framing, focus, and audio.
    Let's get into it.
    """

    static let sampleShotList: [ShotListItem] = [
        ShotListItem(title: "Intro Hook - 26mm Medium", cameraLens: .main26,
                     framingNote: "Eyes on the top third, lean in on the hook line"),
        ShotListItem(title: "Product B-Roll - 13mm Wide", cameraLens: .ultraWide13,
                     framingNote: "Desk wide, slow slide left to right"),
        ShotListItem(title: "Detail Insert - 52mm Close", cameraLens: .crop52,
                     framingNote: "Hands + logo, rack focus at 60fps"),
        ShotListItem(title: "Outro CTA - 26mm Medium", cameraLens: .main26,
                     framingNote: "Point to subscribe, hold 3s"),
    ]
}
