# DuoDirector (phases 1 to 3)

A native SwiftUI + AVFoundation creator app for iPhone Duo (iOS 27.1+). The 5.4" cover display works as a field monitor and teleprompter. The 7.6" inner display is a director's station that adapts to flat, book, and 90° tabletop (L-pose) postures.

> **Status:** this code was written in an environment without Xcode, so it has **not been compiled yet**. The first job on a Mac is `xcodegen generate`, then build and fix whatever the compiler flags. Every iOS 27.x API goes through one file (`Platform/DuoPlatformAPIs.swift`), so API signature fixes stay in one place.

## Getting started

```bash
brew install xcodegen
cd DuoDirector
xcodegen generate        # creates DuoDirector.xcodeproj from project.yml
open DuoDirector.xcodeproj
```

Set your Development Team in the target's Signing settings, then run on the iPhone Duo simulator or a device.

### Mock modes (Simulator)
- **Mock camera.** Always on in the Simulator, and on when no camera is found. You get an animated synthetic feed, a synthetic audio meter, and recording that only changes state (no files are written). To force it on a device, add the launch argument `-DuoDirectorMock YES`.
- **Simulated posture.** Toolbar overflow (•••) → *Simulate posture* → Flat / Book / Tabletop. This fakes the fold so you can test layouts without a hinge. *Real hinge* goes back to `ReservedRegion`.
- **Cover display preview.** Toolbar overflow → *Preview cover display*. This renders `OuterMonitorAccessoryView` at 466×678 pt, the size reported for the Duo simulator's accessory scene. The Simulator has no camera, so the system never presents the real `CameraCaptureAccessory` there.
- **Xcode Previews.** These exist for the outer monitor, the inner display (flat and tabletop), and the editor.

## Project layout

```
DuoDirector/
├─ project.yml                      XcodeGen spec (deployment target iOS 27.1, Info.plist keys)
├─ DuoDirector/Resources/PrivacyInfo.xcprivacy  Privacy manifest (Phase 4)
├─ DuoDirectorTests/                Swift Testing unit tests (Phase 5–6)
├─ DuoDirectorUITests/              XCUITest screenshots + smoke test (Phase 6)
├─ scripts/capture-screenshots.sh   App Store screenshot export (Phase 6)
├─ docs/APP_STORE_SUBMISSION.md     Submission checklist + App Review notes (Phase 7)
└─ DuoDirector/
   ├─ App/DuoDirectorApp.swift      Creates one StudioSessionState + CameraEngine
   ├─ State/StudioSessionState.swift  @Observable shared state for both displays
   ├─ State/ProjectStore.swift     Saves/restores the project (Phase 5)
   ├─ State/CloudSyncController.swift  iCloud Drive sync + CloudMerge (Phase 6)
   ├─ Remote/                      Remote Producer link + UI (MultipeerConnectivity, Phase 6)
   ├─ App/LaunchOptions.swift      UI-test / screenshot launch arguments (Phase 6)
   ├─ Camera/
   │  ├─ CameraEngine.swift         @MainActor facade: intents, observation → device, Photos, meters, mock mode
   │  ├─ CaptureSessionController.swift  Session/MultiCam, lens switching, formats, HDR movie output,
   │  │                             manual locks, audio + video data outputs, per-channel dBFS
   │  ├─ FocusPeakingMetalOverlay.swift  Sobel peaking + zebra analyzer (Metal-backed Core Image),
   │  │                             overlay store, Simulator frame source, SwiftUI overlay view
   │  ├─ CapturePolicies.swift      Pure thermal / MultiCam / bitrate / render rules (Phase 5, tested)
   │  ├─ MovieMarkerTrack.swift     Markers as a timed-metadata track in the .mov (Phase 5)
   │  ├─ CompositeRenderer.swift    On-device PiP / split render + live preview composition (Phase 5)
   │  ├─ ChapterTrackWriter.swift   QuickTime chapter track via passthrough re-mux (Phase 6)
   │  ├─ SystemMonitor.swift        Thermal / battery / storage telemetry (Phase 4)
   │  └─ TakeSidecarExporter.swift  JSON + FCPXML 1.11 sidecars per take (Phase 4)
   ├─ Platform/DuoPlatformAPIs.swift  ALL iOS 27.x API usage + wrappers (fix signatures here)
   └─ Views/
      ├─ CaptureRootView.swift      NavigationStack, toolbar priorities, accessory registration, lifecycle
      ├─ OuterMonitorAccessoryView.swift  Cover display UI + simulator preview
      ├─ InnerDirectorView.swift    Flat (overlay over a 78/22 split) / Book (split) / Tabletop (crease-driven), RightRailToolbar
      ├─ TabletopControlDeckView.swift  Lower-half deck in L-mode: record + good take (or marker + rating in Dual) | speed wheel | gain + shot checks
      ├─ DualCamViews.swift         Host PiP that avoids occlusions, split pane, tabletop Host|Guest pair (Phase 4)
      ├─ LaunchDiagnosticsView.swift  Telemetry, guardrail simulators, Demo Mode / App Store preset (Phase 4)
      ├─ Components/                Preview surface (live + mock), guides, meter, teleprompter, controls,
      │                             SystemStatusViews (mode toggle, thermal pill, banner, Rate Take / Drop Marker)
      └─ Editor/                    Script & shot list editor, PencilShotListView (docked tools + checklist), PencilKit wrapper,
                                    TakesBrowserView (Phase 5)
```

## How the pieces fit

- **One state object.** `StudioSessionState` is `@Observable @MainActor`. The inner views, the cover-display accessory, and `CameraEngine` all hold the same instance. A tap on Record on either display goes through `CameraEngine.toggleRecording()`, which updates `state.status`, and both displays re-render. The accessory is hosted in a separate system scene, so `state` and `engine` are passed in explicitly rather than through `.environment`.
- **The teleprompter stays in sync.** The scroll position (`teleprompterOffset`) lives in state and is driven by one task, so both copies scroll together.
- **Cover display withdrawal.** The accessory is an enhancement only. `onAvailabilityChange` sets `isOuterMonitorAvailable`, and that only drives a "Cover live" badge. Every cover-display control also exists on the inner display.
- **Fold handling.** `InnerDirectorView` reads `reservedRegions(kind:)` inside its `GeometryReader` on every layout pass. It never caches them. Posture comes from the active `.division` frame: none means flat, a tall frame means book, and a wide frame means tabletop. Controls are inset away from `.occlusion` regions, such as the inner under-display camera and system chrome.

## iOS 27.1 API verification (checked against developer.apple.com, 2026-11-24)

| API | Status | Notes |
|---|---|---|
| `CameraCaptureAccessory(isEnabled:content:)` | ✅ Confirmed | iOS 27.1. Conforms to `SceneAccessoryContent` |
| `.onAvailabilityChange { }` on the accessory | ✅ In Apple sample | |
| `View.sceneAccessory(content:)` | ⚠️ Named in Apple sample, declaration not seen | Wrapped in `duoCaptureAccessory(...)` |
| `ArrangementView(primary:secondary:)`, `.arrangementViewStyle(.split / .overlay)`, `.split.axes(_:)`, `.splitArrangementLayoutRatio(_:)` | ✅ Confirmed | iOS 27.1. Apple advises no ScrollView/List/TabView inside it |
| `ReservedRegion` (`kind`, `frame`, `margins`, `isActive`), kinds `.division` / `.occlusion`, `.includeInactive` | ✅ Confirmed | `frame` already includes margins |
| `GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:)` | ✅ Confirmed | Returns `[ReservedRegion]` |
| Fold posture enum (flat/book/tabletop) | ❌ Doesn't exist | Apple DTS says to derive it from `.division` regions (we do) |
| `ToolbarOverflowMenu { }` | ✅ Confirmed | iOS 27.0. Items always stay in overflow |
| `ToolbarItemVisibilityPriority(higherThan:)`, `.high`, `.low` | ✅ Confirmed | iOS 27.0 |
| `ToolbarContent.visibilityPriority(_:)` | ⚠️ Third-party article only | Wrapped in `duoVisibilityPriority(_:)` |
| System "trailing vertical toolbar" placement | ❌ Not found | `DirectorSideRail` is a custom rail that collapses via `ViewThatFits` |

Sources: [CameraCaptureAccessory](https://developer.apple.com/documentation/swiftui/cameracaptureaccessory), [Registering a camera capture accessory on iPhone Duo](https://developer.apple.com/documentation/avfoundation/registering-a-camera-capture-accessory-on-iphone-duo), [UISceneAccessory](https://developer.apple.com/documentation/uikit/uisceneaccessory), [ArrangementView](https://developer.apple.com/documentation/swiftui/arrangementview), [ReservedRegion](https://developer.apple.com/documentation/swiftui/reservedregion), [reservedRegions(kind:options:layoutDirectionBehavior:)](https://developer.apple.com/documentation/swiftui/geometryproxy/reservedregions(kind:options:layoutdirectionbehavior:)), [ToolbarOverflowMenu](https://developer.apple.com/documentation/swiftui/toolbaroverflowmenu), [ToolbarItemVisibilityPriority(higherThan:)](https://developer.apple.com/documentation/swiftui/toolbaritemvisibilitypriority/init(higherthan:)), [Forums: fold posture](https://developer.apple.com/forums/thread/847888), [Forums: accessory orientation](https://developer.apple.com/forums/thread/847762), [Adaptive SwiftUI toolbars in iOS 27](https://nilcoalescing.com/blog/AdaptiveSwiftUIToolbarsInIOS27).

## Things to verify on real hardware

1. **Two preview layers on one session.** Both the inner viewfinder and the cover monitor create an `AVCaptureVideoPreviewLayer` on the same session. If the cover one stays black, switch it to a frame tap (`AVCaptureVideoDataOutput`).
2. **Dolby Vision tagging.** HLG BT.2020 + HEVC should produce Dolby Vision files. To check, look for the Dolby Vision badge in Photos.
3. **Inner under-display camera device type.** It's currently found as a front `builtInWideAngleCamera`. If Apple added a new device type for it, add it in `CaptureSessionController.innerDevice()`.
4. **MultiCam with two `AVCaptureMovieFileOutput`s.** If this isn't accepted, move the inner camera to `AVCaptureVideoDataOutput` + `AVAssetWriter`.
5. **AVAudioEngine metering alongside the capture mic.** If they conflict, set `CameraEngine.useCaptureConnectionMetering = true`.
6. **52mm lens.** It's a 2× crop of the Fusion Main unless a discrete `builtInTelephotoCamera` exists.
7. **Front-camera custom exposure.** A Developer Forums thread reports that `setExposureModeCustom` has no effect on the front camera in the iOS 27 beta.

## Phase 2: creator overlays and media pipeline

**Lens switching.** 1× ↔ 2× (52mm) stays on the Fusion Main module and uses `ramp(toVideoZoomFactor:withRate:)`, so it works mid-take. Switching to or from 0.5× (Ultra Wide) swaps the device input inside `beginConfiguration`/`commitConfiguration` on the running session. That swap is blocked mid-take, because it would end the file. The session is never stopped and preview layers are not rebuilt, so the cover-screen accessory stays up. The engine prefers a format that lists 2.0 in `secondaryNativeResolutionZoomFactors`, which gives a native-pixel 2× crop. If none exists, the inner display shows a "2× digital" badge.

**Recording.** HEVC `.mov` at about 100 Mbps for 4K and 40 Mbps for 1080p at 30fps, scaled up for 60fps. With Dolby Vision on, the active format uses HLG BT.2020, the codec uses the HEVC Main10 profile, and `AVVideoColorPropertiesKey` is set to BT.2020/HLG. A settings key is set only if `supportedOutputSettingsKeys(for:)` lists it. Takes are written to Documents/Takes and then added to Photos with add-only access. If Photos access is denied, the file stays in the app and the UI says so.

**Manual controls.** Sliders write `isoValue`, `shutterDuration`, `whiteBalanceKelvin` and `manualFocusPosition` into state. The engine observes those values with `withObservationTracking`, coalesces changes to about 30 Hz, and applies each one under `lockForConfiguration()`. Values are clamped to the active format. White-balance gains come from Kelvin via `deviceWhiteBalanceGains(for:)` and are clamped to 1…`maxWhiteBalanceGain`.

**Audio meter.** `AVCaptureAudioDataOutput` delivers buffers (stereo where `multichannelAudioMode = .stereo` is supported). Each buffer is reduced to per-channel peak and RMS dBFS, merged on the audio queue, and published to the main actor about 30 times a second. Clipping at -0.5 dBFS or above lights the CLIP lamp, which stays on for 1.5 s after the last clipping buffer.

**Peaking and zebras.** `AVCaptureVideoDataOutput` (BGRA, late frames dropped) feeds the analyzer on a utility queue at up to 15 fps, using a 540 px downscale. Peaking takes the Sobel Gx and Gy (`CIConvolutionRGB3X3`), combines them into |G|², thresholds the result, and draws it as a red mask. Zebras compare luma in the sRGB curve against `zebraThreshold` and fill the matching areas with 45° stripes. The overlay is rendered by a Metal-backed `CIContext` into one small image. Both displays draw it inside `PreviewSurface`, so it crops and mirrors with the picture. The movie output records independently of this branch.

**Teleprompter.** The scroll position comes from time (`prompterOffset(at:)` inside `TimelineView(.animation)`), so both displays show the same line and nothing is written to state on each frame. Speed changes take effect without the text jumping.

**Simulator.** `MockFrameSource` renders a synthetic scene with a bright face (which trips the zebras) and a checker chart (which trips peaking). The real analyzer runs on that scene, so the overlays are real and line up with the preview. The stereo meters animate and clip about every 8 s. Recording runs on a timer and reports "Simulated take N" without writing a file.

### Phase 2 things to verify on hardware
- Whether `AVCaptureAudioDataOutput` and `AVCaptureVideoDataOutput` can be added alongside `AVCaptureMovieFileOutput`. If the audio output is refused, the engine falls back to the movie connection's `audioChannels` levels. If the video output is refused, peaking and zebras show nothing on device.
- Whether `CIConvolutionRGB3X3` keeps negative gradients in the RGBAh working format. If peaking looks too thin, use |Gx|+|Gy| or a small Metal kernel instead.
- The bitrate keys that `AVCaptureMovieFileOutput` accepts on iPhone Duo, and whether the Dolby Vision badge appears in Photos.
- The 2× crop: whether it is native on the 4K formats (check `isCropOpticalQuality`).

## Phase 3: hinge posture, right rail, Apple Pencil shot lists

**Hinge posture.** `.onHingeChange(isEnabled:_:)` is confirmed for iOS 27.1. It delivers `(DeviceHingeContext, DeviceHingeContext)`, and `context.hinge?.angle` holds the angle. It's wrapped as `duoOnHingeChange` in `DuoPlatformAPIs.swift` and feeds `state.updateHinge(angleDegrees:)`. The angle becomes a `HingePosture`: 15° or less is closed, 165° or more is flat, and anything in between is book or tabletop, decided by the fold axis that the inner view reports through `onGeometryChange`. Apple's docs say not to use hinge updates for layout, so `hingePosture` drives behaviour and badges only. The exception is `.closed`, where the app is on the cover display and switches to the compact cover capture UI. The fold layouts themselves come from `ArrangementView` and `ReservedRegion`. The cases of `DeviceHinge.Status` couldn't be read, so the code uses `angle` instead.

**Inner layouts.**
- **Flat:** `ArrangementView(.overlay)`. The secondary is a 78% viewfinder pane at 1.4:1 next to a 22% right rail. The primary is a floating Shot List card, placed top-leading unless that spot overlaps an `.occlusion` region, in which case it moves to bottom-leading.
- **Book:** `ArrangementView(.split)`, with the viewfinder on one side and the director panel plus rail on the other.
- **Tabletop:** the live `.division` frame (about 40 pt) splits the screen. The monitor sits above it, the crease is left empty, and `TabletopControlDeckView` sits below it.

**Right rail.** The rail uses the same priority tiers as the nav-bar toolbar, which uses real `ToolbarItemVisibilityPriority`:
- **Critical:** Record.
- **High:** Lens, Prompter, Peaking, Zebras.
- **Standard:** Guides, Histogram, Shots, Script.
- **Low:** Format, Exposure, Prompter settings.

As height runs out, whole tiers fold into the rail's More menu. Codec (HEVC or ProRes 422 HQ), Dolby Vision, zebra threshold, grid opacity and mirroring always live in overflow. On the nav bar they're in `ToolbarOverflowMenu`, and they come from one shared view (`CinemaSettingsMenuContent`). The rail reads its own reserved regions to stay clear of the status area and the inner camera.

**Pencil shot list.** `PencilShotListView` puts the canvas on the left with nothing over it. Pen, pencil, highlighter, eraser, lasso, colours, width, undo/redo and the checklist are docked in a trailing column. The floating system tool picker is off. Sketches are stored as `PKDrawing` data in `ShotListItem.sketchData`, either attached automatically or with the Attach button. You can tick off shots or use "Done → Next". On a device it accepts Pencil only unless "Draw with finger" is on. The Simulator forces `.anyInput`, so a mouse or trackpad works.

**Also added:** a 64-bin luminance histogram (`CIAreaHistogram`) from the same analyzer as peaking and zebras, a rule-of-thirds grid, and guide opacity.

**Simulator.** Toolbar overflow → *Simulate hinge* → Flat, Book, Tabletop or Closed. This fakes a 40 pt crease, so every pose can be tested without hardware.

### Phase 3 things to verify on hardware
- The angle thresholds for closed and flat, and what `DeviceHinge.Status` actually reports.
- Whether the inner camera's `.occlusion` really falls in the rail column. The Shot List card's fallback position depends on it.
- That ProRes 422 HQ shows up in `availableVideoCodecTypes` at the 4K formats you use.

## Phase 4: Dual-Cam Podcast, thermal & battery guardrails, launch readiness

**Capture modes.** `CaptureMode` is `.singleRearPro` (Solo Rear 4K, up to 60 fps, Dolby Vision or ProRes) or `.dualPodcastMultiCam`. At startup `CameraEngine` reads `AVCaptureMultiCamSession.isMultiCamSupported` into `state.isMultiCamSupported`. Dual mode runs the rear 48MP Fusion Main (Guest) and the inner under-display camera (Host) in one MultiCam session, capped at 30 fps and limited to the 1×/2× main module. If `hardwareCost` goes over 1.0 at 4K, it steps down to 1080p, and if configuration fails it falls back to Solo with a banner. The one-tap toggle sits right under Record on the rail. When MultiCam is unsupported it's dimmed, and tapping it shows a popover that explains why.

**Recording.** Each dual take writes two `.mov` files to `Documents/Takes`, which is visible in the Files app. Both carry the same session UUID in QuickTime `contentIdentifier` metadata and are saved to Photos. The sync offset comes from each output's start time on `session.synchronizationClock`. `TakeSidecarExporter` writes two sidecars next to them:
- `<take>.duodirector.json`, with the files, offset, capture settings, take rating and every `TakeMarker` (timestamp, 1–5 stars, note).
- `<take>.fcpxml` (FCPXML 1.11), which imports into Final Cut Pro directly and into DaVinci Resolve via File › Import › Timeline.

The FCPXML timeline follows `DualExportStyle`: separate synced lanes, a 30% PiP, or a 50/50 split. Composites are delivered as NLE timelines rather than rendered on the phone.

**Previews** (`Views/DualCamViews.swift`). Each feed gets its own preview layer. The Host PiP reads its own `ReservedRegion`s and moves off any `.occlusion`, including the inner camera's own region, which is active while it records. Dragging the PiP snaps it to the nearest clear corner. Split-screen insets the Host pane. Tabletop plus Dual shows Host | Guest above the fold, and the lower deck turns into a producer pad with Record, Drop Marker (long-press to set stars) and Rate Take.

**Guardrails** (`Camera/SystemMonitor.swift` + `CameraEngine.applyThermalPolicy`). The policy uses the worse of `ProcessInfo.thermalState` and the camera's `systemPressureState`.
- At *serious*, peaking, zebras and the histogram pause, and a thermal pill appears.
- At *critical*, the frame rate steps down once the take ends (a rolling take is never cut), and the cover accessory is set to `isEnabled = false`.
- Cooling to *fair* restores everything.

Battery level and charging state, plus free storage, feed the minutes-left estimate, which keeps a 1 GB reserve. When the accessory is withdrawn or paused, `InnerDirectorView` shows an inline mini-teleprompter with transport, marker and record controls. The capture session is untouched, so recording carries on.

**Launch & Diagnostics** (`Views/LaunchDiagnosticsView.swift`, opened from the overflow menus) has four parts:
- Live telemetry, guardrail status and simulators for thermal state, MultiCam and hinge.
- Last-take details with a ShareLink for the sidecars.
- A capabilities list.
- **Demo Mode / App Store Preview Preset**, which loads a podcast script, a shot list with programmatic PencilKit storyboard sketches, rated takes and markers, alternating Host/Guest audio and dual previews, and hides the "SIMULATED" captions. Buttons then jump to the 5.4" cover, 7.6" flat and tabletop screenshot setups. Turning it off restores your own content.

**App Store.** `Resources/PrivacyInfo.xcprivacy` declares no tracking and no data collection, with DiskSpace E174.1 and UserDefaults CA92.1. `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` expose the Takes folder in the Files app.

### Phase 4 things to verify on hardware
- That the rear Fusion Main + inner camera pair is actually in `supportedMultiCamDeviceSets`, and the `hardwareCost` / `systemPressureCost` at 4K30 vs 1080p30.
- That two `AVCaptureMovieFileOutput`s are accepted in the MultiCam session at those formats, and that HEVC / HLG settings apply to both.
- The measured sync offset between the two files, by clapping on camera and comparing in Resolve.
- How fast `systemPressureState` climbs during a 20-minute dual take, and whether the critical step-down is enough.
- Whether iOS withdraws the cover accessory on its own under thermal pressure (the fallback strip should appear either way).
- An FCPXML import test in both Final Cut Pro and Resolve. Media paths are relative (`./file.mov`), so keep the sidecar in the same folder as the files.

## Phase 5: persistence, markers in the .mov, takes browser, on-device composites, tests

**Persistence** (`State/ProjectStore.swift`). The script, shot list (including Pencil sketches), takes, markers, the next take number and your preferences are saved to `Application Support/DuoDirector/project.json`.
- It loads at launch before the engine starts, autosaves with a 1 s debounce after any change, and saves again when the app leaves the foreground.
- Demo Mode content is never saved.
- File links are re-resolved by file name against today's Takes folder, because the app container path changes between installs.
- An unreadable file is set aside as `project.unreadable.json` instead of being overwritten.
- I used a versioned Codable document instead of SwiftData. Everything was already a Codable value type owned by one `@Observable` object, so this avoids a second model layer and schema migrations. The file header explains when moving to SwiftData would pay off.

**Markers inside the .mov** (`Camera/MovieMarkerTrack.swift`). An `AVCaptureMetadataInput` is attached to each movie output (rear and inner), so every Drop Marker / Good Take is also written as a timed-metadata track (`mdta/com.duodirector.marker`, a JSON payload) on the session clock. The takes browser can read markers back out of a file with `AVAssetReaderOutputMetadataAdaptor`. The sidecars still carry the markers too, because NLEs don't show custom timed metadata as markers. Launch & Diagnostics shows where markers are being written.

**Takes browser** (`Views/Editor/TakesBrowserView.swift`, the Takes tab or the overflow menu › Takes).
- Filters: All, Good (4★ and up, or a 5★ marker), Unrated and Dual-Cam, plus search over shot titles and marker notes.
- AVKit playback. Dual-Cam takes play as a live synced composite (PiP / Split / Guest / Host) using the same composition the renderer exports.
- Tap a marker to seek to it.
- You can also rate a take (the sidecars are rewritten), recover markers from the file, share files and sidecars, render a composite, or delete a take.

**On-device composites** (`Camera/CompositeRenderer.swift`). Renders an HEVC 1080p PiP or split-screen `.mov` from a Dual-Cam take, using the same layout as the FCPXML.
- It only runs between takes, while the phone is nominal or fair and on power.
- It stops at serious, or when you unplug.
- It saves to Files › Takes and to Photos.
- An optional auto-render setting (Launch & Diagnostics) works through dual takes on its own when those conditions hold.

**Tests** (`DuoDirectorTests/`, Swift Testing, ⌘U). They cover:
- `DuoRegions` posture, insets and collisions (DuoRegions now stores frames, so tests can build layouts by hand), plus Host PiP placement.
- The thermal, MultiCam-budget, bitrate and render policies (now pure functions in `Camera/CapturePolicies.swift`).
- `AudioMetering` with real PCM sample buffers (Float32 interleaved and non-interleaved, Int16 mono, silence).
- FCPXML lanes, offsets and escaping, and the JSON sidecar round trip.
- Marker payloads, composite transforms (including rotated sources), the persistence mapping and relinking, and the take filters.

**Concurrency.** The project now builds with `SWIFT_STRICT_CONCURRENCY: complete`, plus the InferSendableFromCaptures and GlobalConcurrency upcoming features, still in Swift 5 language mode. Every issue Swift 6 would reject shows up as a warning, so the first build of this never-compiled code isn't blocked. Once the warnings are cleared, set `SWIFT_VERSION: "6.0"`.

### Phase 5 things to verify on hardware
- Whether `AVCaptureMetadataInput` is accepted in the MultiCam session for both movie outputs. Diagnostics will say "Sidecar only" if it isn't.
- Whether marker times read back from the file are 0-based, and how far they sit from the sidecar timestamps.
- That `AVAssetExportPresetHEVC1920x1080` with a two-layer video composition finishes within the thermal limits on a 20-minute take.
- How live composite playback in the takes browser performs with two 4K HEVC sources.
- That autosave survives the app being backgrounded mid-take (the take saves once it finishes).

## Phase 6: QuickTime chapters, iCloud sync, Remote Producer, screenshot UI tests, Swift 6 prep

**QuickTime chapters** (`Camera/ChapterTrackWriter.swift`). After each take, and before the Photos copy is made, each .mov is re-muxed in passthrough with a QuickTime chapter text track linked via a `chap` reference. Passthrough means no decode or encode, so it's I/O only. The chapters are "Start" plus one per marker ("★★★★☆ Great laugh"), so they show up in QuickTime Player, Finder and most importers. The original file is only replaced once the new one is complete. If anything fails, the take is still saved and the markers stay in the sidecars.

**iCloud Drive sync** (`State/CloudSyncController.swift`, off by default, turned on per device in Launch & Diagnostics).
- `project.json` is mirrored to *iCloud Drive › DuoDirector › Project* using coordinated reads and writes. An NSMetadataQuery picks up other devices' versions.
- Merge rules (`CloudMerge`):
  - The newer document wins for the script, shots and preferences.
  - Takes and markers are combined by id, and the newer record wins for the same take.
  - The next take number is the higher of the two.
- Remote changes wait while a take is rolling or Demo Mode is on.
- Optional video sync copies each take's files (camera files, sidecars, composite) to *DuoDirector › Takes*. Other devices then download them on demand.
- Needs the iCloud Documents capability with the container `iCloud.com.duodirector.app` (`Resources/DuoDirector.entitlements`).
- Known limit: deleting a take isn't synced yet.

**Remote Producer** (`Remote/`). A second iPhone or iPad running DuoDirector becomes a wireless producer remote over MultipeerConnectivity. It works peer to peer, needs no router, and is encrypted.
- **What the remote shows:** a REC/STBY tally with timecode, a ~4 fps preview (solo mode only), stereo meters, thermal, battery and storage, and the script.
- **What the remote can do:** record/stop, drop a marker, rate the take, play, reset or speed up the prompter, and go to the next shot. It can't do anything else: no format changes, no deletes, no file access.
- **Approval:** the camera user approves every connection, and only one remote can be connected at a time.
- **Turning it on:** overflow menu › Remote producer.

I read "live/remote mode" as an on-device producer remote. Internet live streaming and recording a remote guest's camera need a media server or an SDK, so they're listed below as candidates.

**Screenshot UI tests** (`DuoDirectorUITests/`, `scripts/capture-screenshots.sh`). XCUITest launches the app with `LaunchOptions` arguments (synthetic cameras, a throwaway project, Demo Mode, a scene) and captures five screens:
- 5.4" cover monitor
- 7.6" flat Dual-Cam (rolling)
- Tabletop Host | Guest
- Takes browser
- Launch & Diagnostics

It also runs a record → stop smoke test. The script sets a clean 9:41 status bar, runs the tests and exports the PNGs with `xcresulttool`.

**Swift 6 prep.** The objects that legitimately cross queues are now annotated with `nonisolated(unsafe)`, each with a reason: AVAssetExportSession, AVAssetWriterInput in the re-mux, MCPeerID and MultipeerConnectivity handlers. Main-actor statics that are read off the main actor are now `nonisolated`. Strict checking stays `complete` in Swift 5 mode. Swift 6 is still the step after the first real build, because only a compiler can list what's left.

### Phase 6 things to verify on hardware
- QuickTime Player shows the chapters, and Photos keeps them after import.
- The passthrough re-mux keeps the HLG/Dolby Vision colour metadata and the timed-metadata marker track. Check how long it takes on a 20-minute 4K take.
- iCloud: two devices on the same Apple ID; edit the script on one, rate a take on the other, and check that the merge is right.
- The Remote Producer connection prompt, the Local Network permission prompt, and range and latency between rooms.
- The UI tests on the iPhone Duo simulator, and whether App Store Connect wants separate screenshots for the cover display.

## Phase 7: deletion sync, Spanish localization, App Store submission prep

**Deletion sync.** Deleting a take now leaves a tombstone (take id and marker ids, with the deletion time) in the project document. `CloudMerge` combines tombstones from both devices and drops whatever they cover, so a deleted take no longer comes back from another device.
- A device that receives a tombstone removes its own local copies of that take's files. Photos copies are never touched.
- The iCloud copies are removed too.
- Tombstones expire after 90 days.
- Take numbers are never reused.

**Localization.** `Resources/Localizable.xcstrings` (187 keys) and `InfoPlist.xcstrings` (permission prompts) have complete Spanish translations.
- SwiftUI literals are picked up automatically.
- Static banners are looked up at runtime through `showBanner`. Banners with values in them, such as frame rates or device names, still show in English until they move to `String(localized:)`.
- `CFBundleLocalizations` declares en and es.
- VoiceOver now announces banners and record start/stop.

**Submission prep.** `docs/APP_STORE_SUBMISSION.md` is the full checklist: first build, capabilities, the App Store Connect record, the privacy label ("Data Not Collected"), Accessibility Nutrition Labels, screenshots, App Review notes ready to paste, upload and TestFlight. `ITSAppUsesNonExemptEncryption = NO`, version 1.0 (1).

### Phase 7 things to verify
- Xcode adds Spanish to the project's known regions when it opens the catalogs. If it doesn't, add it under Project › Info › Localizations.
- Check the Spanish UI for truncation on the right rail and the tabletop deck (Spanish runs about 20% longer).
- Deletion sync: delete a take on device A while device B is offline, bring B online, and check that the take and its local files are gone.

## Phase 8: Go Live (RTMP/RTMPS to YouTube, Twitch or any server)
- **Go Live sheet** (overflow menu › Go Live, on the inner display and the rail). Add YouTube Live, Twitch or a custom RTMP/RTMPS destination, paste the stream key, pick 720p30 / 1080p30 / 1080p60, then press Go Live. Destinations are remembered; keys are not stored with them.
- **Stream keys live in the Keychain** (`StreamKeyStore`, this device only, available after first unlock so a locked phone can still reconnect). The UI only ever shows them redacted (`••••••1234`), and they never go into the project file, iCloud, logs or banners.
- **One capture pipeline.** `CaptureSessionController.setLiveSampleSink` taps the existing video/audio data outputs, so you can record a take while live. Streaming is **Solo mode only**: Dual-Cam has no data outputs, so Go Live is blocked in Dual-Cam, and switching to Dual-Cam is blocked while live.
- **Resilience.** A drop reconnects automatically (1, 2, 4, 8, then every 15 s, 8 tries). A failure on the first connect is reported straight away, since it's almost always a wrong key or server. Heat lowers the bitrate (70 % at serious, 50 % at critical); critical heat ends the stream unless a take is recording.
- **LIVE tally** on the inner status row, the cover monitor, the Go Live sheet (with timer and upload rate) and the Remote Producer (`RemoteStatus.isLive`, optional so older versions still decode).
- **HaishinKit stays in one file.** `Platform/HaishinKitTransport.swift` is the only code that touches HaishinKit, behind the `LiveStreamTransport` protocol. The Simulator, Demo Mode and tests use `MockLiveTransport`, which sends nothing. project.yml adds the `HaishinKit` package (from 2.2.0) with the `HaishinKit` and `RTMPHaishinKit` products. SRT is deliberately not linked, to keep `ITSAppUsesNonExemptEncryption = NO`.
- New files: `Live/LiveStreamModels.swift`, `Live/LiveStreamTransport.swift`, `Live/LiveStreamController.swift`, `Platform/HaishinKitTransport.swift`, `Views/GoLiveSheet.swift`, `DuoDirectorTests/Phase8Tests.swift`. 40 new Spanish strings.

### Phase 8 things to verify on the first build
- HaishinKit calls marked `VERIFY` in `Platform/HaishinKitTransport.swift`: appending externally captured `CMSampleBuffer`s, `close()` names, the `connected` property for drop detection, the audio `bitRate` spelling, and real upload stats.
- Copy the current RTMPS ingest URLs from YouTube Studio and Twitch Stream Manager into `StreamDestination.Kind.defaultServer`.
- On device: stream 30 minutes to a private YouTube stream while recording a take; check A/V sync, thermal steps, and that airplane mode for 10 s triggers a reconnect.
- The data-output frame size matches the session preset (often 4K). If HaishinKit doesn't scale to `videoSize`, set the video data output's pixel buffer size for Live.

## Phase 9: Remote guests (LiveKit / WebRTC)
- **Remote guest sheet** (overflow menu › Remote guest). Open a guest room, then **Send invite link**. The guest opens the link in any browser (LiveKit Meet) and joins with camera and mic. There's nothing for them to install.
- **Tokens without secrets in the app.** The app asks *your* token endpoint (LiveKit Cloud's token server, or a few lines on any HTTPS server) for short-lived passes: one for the host and a fresh one per invite. For development, paste a token from `lk token create` under Advanced. It's kept in memory only.
- **The host camera goes out from the same capture taps** as Go Live (`setSampleSink(_:for:)` now fans out to several consumers). Solo mode only, so Dual-Cam is blocked while the room is open.
- **The guest comes back** as a floating tile on the inner display (tap it to open the sheet), a green guest pill on the status row and cover monitor, and the guest's name on the Remote Producer.
- **The guest goes into the stream, not the recording.** With "Show guest in Go Live stream" on, `GuestStreamCompositor` (Core Image) draws the guest in the corner or side by side, and `GuestAudioMixer` mixes their voice under your mic. Your takes stay clean, camera-only files. A frozen guest (no frame for 1.5 s) drops out of the composite automatically.
- **Audio:** DuoDirector keeps owning the audio session (LiveKit's automatic configuration is turned off). Wear headphones, because the capture session's recording mode has no echo cancelling.
- **Two build variants.** `project.yml` builds without LiveKit (guests are simulated, and the export-compliance answer stays NO). `xcodegen generate --spec project-guests.yml` links LiveKit 2.17+ and sets `ITSAppUsesNonExemptEncryption = YES`, because WebRTC brings its own encryption.
- New files: `Live/GuestModels.swift`, `Live/GuestMedia.swift` (room protocol, frame store, compositor, audio mixer, mock room), `Live/GuestSessionController.swift`, `Platform/LiveKitGuestRoom.swift` (the only LiveKit code), `Views/GuestSheet.swift`, `project-guests.yml`, `DuoDirectorTests/Phase9Tests.swift`. 46 new Spanish strings.

### Phase 9 things to verify on the first build
- The LiveKit calls marked `VERIFY` in `Platform/LiveKitGuestRoom.swift`: `room.connect`/`disconnect`, `publish(videoTrack:)`, reaching the `BufferCapturer` from the track, `setMicrophone` while AVCaptureSession also holds the mic, and `Track.Source.camera`.
- The token-endpoint JSON (`room_name`, `participant_identity` → `server_url`, `participant_token`) and the LiveKit Meet link query names (`liveKitUrl`, `token`).
- Whether XcodeGen's `include:` appends or replaces `dependencies` (see `project-guests.yml`).
- On device: a 20-minute call with a guest on a laptop while streaming. Check lip sync of the guest in the stream, echo with and without headphones, and the thermal level (WebRTC encode + RTMP encode at once).

## Phase 10: launch readiness for 1.0 (ships without remote guests)
- **CI without a Mac** (`.github/workflows/ios.yml`). Every push and PR runs xcodegen, builds and runs the unit tests on a macOS runner, and keeps the log and `.xcresult`. Actions › iOS › Run workflow with **upload** archives a Release build from `project.yml` (no LiveKit) and uploads it to App Store Connect. It needs four secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `DEVELOPMENT_TEAM`. The build number comes from the run number (`CFBundleVersion = $(CURRENT_PROJECT_VERSION)`).
- **Compile review.** Every `state.`/`engine.`/`controller.` member and every `Type.member` used in the project was checked against a declaration (all resolve, apart from Apple APIs). Bracket balance passes. The HaishinKit calls now use `try?`, so they compile whether or not those APIs throw. The remaining compile risks are the marked `VERIFY` lines in `Platform/`.
- **First-run onboarding** (`Views/OnboardingView.swift`). Three pages, then camera and mic access is requested in context. The camera doesn't start until onboarding is done. If access is off, a full-screen prompt links to Settings. UI tests skip onboarding.
- **About & acknowledgements** (Diagnostics › About): version, privacy-policy link and the HaishinKit BSD-3 license, which its license requires the app to show.
- **docs/PRIVACY_POLICY.md** (host it, then set `AboutView.privacyPolicyURL`) and **docs/APP_STORE_METADATA.md** (name, subtitle, promo text, description and keywords in English and Spanish).

### Phase 10 things to do
- Create a GitHub repo, push this folder, and add the four secrets. The first CI run will show real compile errors. Fix those first.
- Replace the placeholders: privacy policy contact and date, `AboutView.privacyPolicyURL`, support URL.
- Check the HaishinKit license text against the resolved version's LICENSE file.

## Next phase candidates
- Swift 6 language mode once CI shows zero strict-concurrency warnings.
- Guests 1.1: release the `project-guests.yml` build.
- Record the guest as their own ISO track per take (a third .mov next to host/guest, plus sidecar entries).
- Echo cancelling without headphones (a voice-processing audio mode while a guest is connected).
- More than one guest, and a green-room so you can talk to the guest before they appear in the stream.
- Dual-Cam streaming: composite both angles live (needs a Metal compositor fed from the movie outputs or extra data outputs within the MultiCam budget).
- Stream to two destinations at once, and a scheduled-stream picker via the YouTube Live API (needs sign-in, which changes the privacy answers).
- Move interpolated banner text to `String(localized:)` and add more languages.
- Dynamic Type audit of the HUD text that uses fixed sizes, before claiming Larger Text support.
