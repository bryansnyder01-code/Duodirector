import AVFoundation
import os
import Photos
import SwiftUI

/// Main-actor facade over the capture pipeline (Phase 4).
///
/// Views on BOTH displays call these intents (`setCaptureMode`, `selectLens`,
/// `startRecordingWithCountdown`, `dropMarker`, `rateTake` …) or write manual/overlay
/// values into `StudioSessionState`, which the engine observes and pushes to the device.
///
/// Phase 4 adds:
///  • Dual-Cam Podcast mode: `AVCaptureMultiCamSession` with the rear 48MP Fusion Main
///    (Guest) + the inner under-display camera (Host), capped at 30fps and stepped down
///    to 1080p if `hardwareCost` exceeds 1.0. Each camera records its own .mov; both carry
///    the same session identifier; a JSON + FCPXML sidecar syncs them in an NLE.
///  • Thermal guardrails: `ProcessInfo.thermalState` (via SystemMonitor) and the camera's
///    `systemPressureState`. Serious: pause GPU overlays. Critical: pause the cover
///    accessory and step frame rate down (between takes, never mid-take).
///  • Accessory resilience: if iOS withdraws the CameraCaptureAccessory mid-shoot, the
///    inner display takes over prompter + controls; recording never depended on it.
///  • Battery/storage telemetry and Demo Mode for App Store screenshots.
///
/// `.mock` source mode (Simulator / `-DuoDirectorMock YES`) never touches devices.
@MainActor
final class CameraEngine {

    let state: StudioSessionState
    let controller = CaptureSessionController()
    let overlayStore = AnalysisOverlayStore()
    let systemMonitor = SystemMonitor()
    private(set) var analyzer: FrameAnalyzer!
    private let mockSource = MockFrameSource()
    private let meterAccumulator = MeterAccumulator()

    static let clipThresholdDB: Float = -0.5
    static let clipHoldSeconds: TimeInterval = 1.5
    /// Dual-cam bandwidth cap.
    static let multiCamMaxFrameRate: FrameRatePreset = .fps30

    private var isStarted = false
    private var lastClipAt: Date = .distantPast
    private var countdownTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var mockAudioTask: Task<Void, Never>?
    private var fallbackMeterTask: Task<Void, Never>?
    private var manualApplyPending = false
    /// Thermal guard: overlay prefs to restore when the device cools.
    private var savedOverlayPrefs: (peaking: Bool, zebra: Bool)?
    /// Worst of process thermal state and camera system pressure.
    private var cameraPressure: ProcessInfo.ThermalState = .nominal
    private var simulatedThermal: ProcessInfo.ThermalState?
    /// Phase 5: the one composite render allowed at a time.
    private var renderTask: Task<Void, Never>?
    /// Phase 6: iCloud sync and the remote-producer link, set by DuoDirectorApp.
    /// Optional so previews and tests run without them.
    var cloudSync: CloudSyncController?
    var remoteLink: RemoteProducerLink?
    /// Phase 8: Go Live (RTMP/RTMPS). Created in DuoDirectorApp.
    var liveStream: LiveStreamController?
    /// Phase 9: remote guests (LiveKit). Created in DuoDirectorApp.
    var guests: GuestSessionController?
    /// Phase 11: Lock Screen / Dynamic Island record timer. nil in UI tests.
    var recordingActivity: RecordingActivityController?
    /// Phase 11: the one social export allowed at a time, and caption jobs.
    private var socialTask: Task<Void, Never>?

    init(state: StudioSessionState) {
        self.state = state
        if !CaptureSessionController.hasAnyCamera { state.sourceMode = .mock }

        let store = overlayStore
        analyzer = FrameAnalyzer(
            onOverlay: { image in Task { @MainActor in store.overlay = image } },
            onHistogram: { bins in Task { @MainActor in store.histogram = bins } })
        controller.frameAnalyzer = analyzer
        mockSource.analyzer = analyzer
        mockSource.onFrame = { image in Task { @MainActor in store.mockFrame = image } }
        mockSource.onInnerFrame = { image in Task { @MainActor in store.mockInnerFrame = image } }

        let accumulator = meterAccumulator
        controller.onAudioLevels = { [weak self] levels in
            guard let batch = accumulator.add(levels) else { return }
            Task { @MainActor in self?.applyAudio(batch) }
        }
        controller.onSystemPressure = { [weak self] level, _ in
            Task { @MainActor in self?.cameraPressureChanged(level) }
        }

        systemMonitor.onThermalChange = { [weak self] thermal in self?.processThermalChanged(thermal) }
        systemMonitor.onBatteryChange = { [weak self] level, charging in self?.batteryChanged(level, charging) }
        systemMonitor.onStorageChange = { [weak self] bytes in self?.storageChanged(bytes) }

        observeOverlaySettings()
        observeManualControls()
    }

    var isMock: Bool { state.sourceMode == .mock }

    // MARK: Lifecycle

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        systemMonitor.start()

        if isMock {
            // Simulator: no MultiCam unless Demo Mode / "Simulate MultiCam" says so,
            // so the disabled-toggle path is what you see by default.
            state.isMultiCamSupported = state.simulateMultiCamSupport || state.isDemoMode
            state.isDolbyVisionSupported = true
            state.isCropOpticalQuality = true
            state.isProResSupported = true
            state.status = .ready
            mockSource.setLens(state.activeLens)
            mockSource.start(context: analyzer.context)
            startMockAudio()
            return
        }

        // Checked once at startup; the dual toggle is disabled (with a tip) when false.
        state.isMultiCamSupported = AVCaptureMultiCamSession.isMultiCamSupported
        if !state.isMultiCamSupported, state.isDualCam { state.captureMode = .singleRearPro }

        guard await CaptureSessionController.requestAccess() else {
            isStarted = false
            state.status = .unauthorized
            return
        }
        do { try CaptureSessionController.configureAudioSession() } catch { state.statusNote = error.localizedDescription }
        CaptureSessionController.setInputGain(state.audioGain)

        state.status = .configuring
        await reconfigure()
        await onSessionQueue { $0.startRunning() }
    }

    func stop() async {
        isStarted = false
        systemMonitor.stop()
        mockSource.stop()
        mockAudioTask?.cancel()
        fallbackMeterTask?.cancel()
        guard !isMock else { return }
        await onSessionQueue { $0.stopRunning() }
    }

    /// Full reconfigure on the live session. Only single ↔ multicam replaces the session.
    func reconfigure() async {
        guard !isMock else { return }
        let dual = state.isDualCam && state.isMultiCamSupported
        if dual {
            // MultiCam: rear Fusion Main only (0.5× Ultra Wide would be a THIRD sensor),
            // and ≤ 30fps to stay within bandwidth.
            if !state.activeLens.usesMainModule { state.activeLens = .main26 }
            if state.frameRate.rawValue > Self.multiCamMaxFrameRate.rawValue { state.frameRate = Self.multiCamMaxFrameRate }
        }
        let config = CaptureSessionController.Configuration(
            lens: state.activeLens, frameRate: state.frameRate.rawValue, resolution: state.resolution,
            wantsDolbyVision: state.isDolbyVisionEnabled, dualAngle: dual, codec: state.preferredCodec)
        let result: Result<CaptureSessionController.Capabilities, Error> = await onSessionQueue { controller in
            Result { try controller.configure(config) }
        }
        switch result {
        case .success(let caps):
            apply(caps)
            if caps.sessionReplaced { state.sessionGeneration += 1 }
            // MultiCam over budget at 4K → step down to 1080p once (DualCamBudget, tested).
            if dual, let lower = DualCamBudget.resolutionStepDown(hardwareCost: caps.hardwareCost, resolution: state.resolution) {
                state.resolution = lower
                state.showBanner("Dual-cam at 4K exceeds this device's camera bandwidth. Using 1080p30.")
                await reconfigure()
                return
            }
            if !state.isRecording { state.status = .ready }
            restartMeteringIfNeeded()
            scheduleManualApply()
        case .failure(let error):
            if dual {
                // Fall back to solo rather than leaving the user without a camera.
                state.captureMode = .singleRearPro
                state.showBanner("Dual-cam couldn't start (\(error.localizedDescription)). Switched to Solo Rear 4K.")
                await reconfigure()
            } else {
                state.status = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ caps: CaptureSessionController.Capabilities) {
        if let fps = FrameRatePreset(rawValue: caps.appliedFrameRate) { state.frameRate = fps }
        state.resolution = caps.appliedResolution
        state.isDolbyVisionSupported = caps.dolbyVisionSupported
        state.isCropOpticalQuality = caps.cropIsOpticalQuality
        state.isProResSupported = caps.proResSupported
        if !state.isProResSupported { state.preferredCodec = .hevc }
        state.multiCamHardwareCost = caps.hardwareCost
        state.multiCamSystemPressureCost = caps.systemPressureCost
        state.isoRange = caps.isoRange
        state.shutterRange = caps.shutterRange
        state.isoValue = min(max(state.isoValue, caps.isoRange.lowerBound), caps.isoRange.upperBound)
        state.shutterDuration = min(max(state.shutterDuration, caps.shutterRange.lowerBound), caps.shutterRange.upperBound)
        state.statusNote = caps.note
        updateStorageEstimate()
    }

    /// AVCaptureAudioDataOutput isn't attached in MultiCam; use connection levels there.
    private func restartMeteringIfNeeded() {
        fallbackMeterTask?.cancel()
        if !controller.hasAudioDataOutput { startFallbackMeter() }
        if state.isDualCam && !controller.hasVideoDataOutput && (state.showFocusPeaking || state.showZebraStripes) {
            state.statusNote = "Peaking & zebras are off in Dual-Cam (no analysis output in MultiCam)."
        }
    }

    // MARK: Capture mode (Phase 4)

    /// One-tap Solo Rear 4K ↔ Dual-Cam Podcast. Blocked mid-take.
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != state.captureMode, !state.isRecording else { return }
        if mode == .dualPodcastMultiCam && !state.isMultiCamSupported {
            state.showBanner("Dual-Cam Podcast needs MultiCam support, which this device doesn't report.")
            return
        }
        if mode == .dualPodcastMultiCam && state.guestState.isInRoom {
            state.showBanner("Close the guest room before switching to Dual-Cam.")
            return
        }
        if mode == .dualPodcastMultiCam && state.liveState.isActive {
            state.showBanner("End the live stream before switching to Dual-Cam.")
            return
        }
        state.captureMode = mode
        if isMock {
            if mode == .dualPodcastMultiCam {
                if !state.activeLens.usesMainModule { state.activeLens = .main26; mockSource.setLens(.main26) }
                if state.frameRate.rawValue > Self.multiCamMaxFrameRate.rawValue { state.frameRate = Self.multiCamMaxFrameRate }
            }
            updateStorageEstimate()
            return
        }
        state.status = .configuring
        Task { await reconfigure() }
    }

    func setDualExportStyle(_ style: DualExportStyle) {
        state.dualExportStyle = style
    }

    /// Phase 1–3 name.
    func setDualAngle(_ enabled: Bool) { setCaptureMode(enabled ? .dualPodcastMultiCam : .singleRearPro) }

    // MARK: Lens

    func selectLens(_ lens: LensOption) {
        guard lens != state.activeLens else { return }
        if state.isDualCam && !lens.usesMainModule {
            state.showBanner("Dual-Cam uses the Fusion Main camera (1× / 2×).")
            return
        }
        let needsModuleSwap = lens.usesMainModule != state.activeLens.usesMainModule
        if needsModuleSwap && state.isRecording { return }
        state.activeLens = lens
        if isMock { mockSource.setLens(lens); return }

        Task {
            let result: Result<CaptureSessionController.Capabilities?, Error> = await onSessionQueue { controller in
                Result { try controller.switchLens(to: lens) }
            }
            switch result {
            case .success(let caps?): apply(caps); scheduleManualApply()
            case .success(nil): break
            case .failure(let error): state.statusNote = error.localizedDescription
            }
        }
    }

    // MARK: Format presets

    func selectFrameRate(_ fps: FrameRatePreset) {
        guard !state.isRecording, fps != state.frameRate else { return }
        if state.isDualCam && fps.rawValue > Self.multiCamMaxFrameRate.rawValue {
            state.showBanner("Dual-Cam is capped at 30fps.")
            return
        }
        state.frameRate = fps
        state.thermalSteppedDownFrom = nil
        if state.isAutoExposure { state.shutterDuration = 1.0 / Double(fps.rawValue * 2) }
        updateStorageEstimate()
        Task { await reconfigure() }
    }

    func selectResolution(_ resolution: ResolutionPreset) {
        guard !state.isRecording, resolution != state.resolution else { return }
        state.resolution = resolution
        updateStorageEstimate()
        Task { await reconfigure() }
    }

    func setDolbyVision(_ enabled: Bool) {
        guard !state.isRecording else { return }
        state.isDolbyVisionEnabled = enabled
        Task { await reconfigure() }
    }

    func setCodec(_ codec: VideoCodecPreset) {
        guard !state.isRecording, codec != state.preferredCodec else { return }
        state.preferredCodec = codec
        updateStorageEstimate()
        Task { await reconfigure() }
    }

    // MARK: Recording

    func toggleRecording() {
        if state.countdownRemaining != nil { cancelCountdown(); return }
        state.isRecording ? stopRecording() : startRecordingWithCountdown()
    }

    func startRecordingWithCountdown() {
        guard !state.isRecording, state.countdownRemaining == nil else { return }
        guard state.countdownSeconds > 0 else { startRecording(); return }
        countdownTask = Task {
            for remaining in stride(from: state.countdownSeconds, to: 0, by: -1) {
                state.countdownRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { state.countdownRemaining = nil; return }
            }
            state.countdownRemaining = nil
            startRecording()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        state.countdownRemaining = nil
    }

    func startRecording() {
        guard !state.isRecording, state.status != .saving else { return }
        if let minutes = state.estimatedRecordingMinutesLeft, minutes < 2 {
            state.showBanner("Less than 2 minutes of storage left. Free up space to keep recording.", seconds: nil)
        }
        let start = Date()
        let sessionID = UUID().uuidString
        let take = TakeRecord(takeNumber: state.takeNumber, sessionIdentifier: sessionID, startedAt: start,
                              captureMode: state.captureMode, exportStyle: state.dualExportStyle,
                              shotTitle: state.activeShot?.title)
        state.takes.append(take)
        state.status = .recording(startedAt: start)
        recordingActivity?.start(takeNumber: state.takeNumber, startedAt: start,
                                 isLive: state.liveState.isLive, projectName: state.activeShot?.title)
        AccessibilityNotification.Announcement(String(localized: "Recording take \(state.takeNumber)")).post()
        state.recordingDuration = 0
        state.lastSaveMessage = nil
        if !state.isPrompterPlaying, !state.scriptText.isEmpty { state.setPrompterPlaying(true) }

        durationTask?.cancel()
        durationTask = Task {
            while !Task.isCancelled, state.isRecording {
                state.recordingDuration = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        guard !isMock else { return }
        let takeNumber = state.takeNumber
        controller.sessionQueue.async { [controller] in
            controller.startRecording(sessionIdentifier: sessionID, takeNumber: takeNumber) { result in
                Task { @MainActor [weak self] in await self?.finishRecording(result) }
            }
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        state.setPrompterPlaying(false)
        durationTask?.cancel()
        recordingActivity?.end()
        AccessibilityNotification.Announcement(String(localized: "Recording stopped")).post()
        if let start = state.recordingStart { state.recordingDuration = Date().timeIntervalSince(start) }

        if isMock {
            // Simulated take: no video files, but the sidecar is written for real so the
            // JSON/FCPXML export can be inspected in Files.
            updateCurrentTake { $0.duration = self.state.recordingDuration }
            writeSidecars()
            state.status = .ready
            state.lastSaveMessage = "Simulated take \(state.takeNumber) · \(Self.timecode(state.recordingDuration)) · sidecar written (no video in Simulator)"
            state.takeNumber += 1
            applyDeferredThermalStepDown()
            return
        }
        state.status = .saving
        controller.sessionQueue.async { [controller] in controller.stopRecording() }
    }

    private func finishRecording(_ result: Result<CaptureSessionController.RecordingResult, Error>) async {
        switch result {
        case .success(let recording):
            updateCurrentTake {
                $0.duration = self.state.recordingDuration
                $0.rearFileURL = recording.rearURL
                $0.innerFileURL = recording.innerURL
                $0.innerStartOffset = recording.innerStartOffset
            }
            state.lastSavedAssetURL = recording.rearURL
            writeSidecars()
            // Phase 6: QuickTime chapters (passthrough re-mux, I/O only) BEFORE Photos copies
            // the file, so the Photos copy has them too. Never blocks saving on failure.
            await writeChapters(into: [recording.rearURL, recording.innerURL].compactMap { $0 })
            await saveToPhotos([recording.rearURL, recording.innerURL].compactMap { $0 })
            if let take = state.takes.last(where: { $0.takeNumber == state.takeNumber }) {
                cloudSync?.uploadTake(take)
                if state.autoCaptionTakes { generateCaptions(takeID: take.id, quiet: true) }
            }
        case .failure(let error):
            state.lastSaveMessage = "Recording failed: \(error.localizedDescription)"
        }
        state.takeNumber += 1
        state.status = .ready
        applyDeferredThermalStepDown()
        processRenderQueueIfIdle()
    }

    // MARK: Chapters (Phase 6)

    private func writeChapters(into urls: [URL]) async {
        let markers = state.markers(forTake: state.takeNumber)
        guard !markers.isEmpty else { return }
        for url in urls {
            do {
                try await ChapterTrackWriter.addChapters(to: url, markers: markers)
            } catch {
                state.statusNote = "Chapters skipped: \(error.localizedDescription). Markers are in the sidecar."
            }
        }
    }

    // MARK: Composite render (Phase 5)

    /// Whether a render may start right now (CompositeRenderPolicy, unit-tested).
    var compositeRenderVerdict: CompositeRenderPolicy.Verdict {
        CompositeRenderPolicy.verdict(isRecording: state.isRecording || state.status == .saving,
                                      thermal: ThermalPolicy.effectiveLevel(thermal: state.thermalState, cameraPressure: cameraPressure),
                                      isCharging: state.isCharging, batteryLevel: state.batteryLevel)
    }

    var isRenderingComposite: Bool { renderTask != nil }

    /// Renders one dual take as a split/PiP .mov (style = the take's own export style,
    /// with separate-tracks rendered as PiP), then saves it to Photos.
    func renderComposite(takeID: TakeRecord.ID, style: DualExportStyle? = nil) {
        guard renderTask == nil else { state.showBanner("A composite is already rendering."); return }
        guard case .allowed = compositeRenderVerdict else {
            if case .blocked(let reason) = compositeRenderVerdict { state.showBanner(reason) }
            return
        }
        guard let take = state.takes.first(where: { $0.id == takeID }) else { return }
        let renderStyle = style ?? (take.exportStyle == .splitScreenComposite ? .splitScreenComposite : .pictureInPicture)
        state.compositeRenderProgress[takeID] = 0
        renderTask = Task { [weak self] in
            do {
                let url = try await CompositeRenderer.render(take: take, style: renderStyle) { fraction in
                    Task { @MainActor in self?.state.compositeRenderProgress[takeID] = fraction }
                }
                guard let self else { return }
                if let index = state.takes.firstIndex(where: { $0.id == takeID }) {
                    state.takes[index].compositeFileURL = url
                    cloudSync?.uploadTake(state.takes[index])
                }
                await saveCompositeToPhotos(url)
            } catch {
                self?.state.showBanner("Composite not rendered: \(error.localizedDescription)")
            }
            self?.state.compositeRenderProgress[takeID] = nil
            self?.renderTask = nil
            self?.processRenderQueueIfIdle()
        }
    }

    func cancelCompositeRender(reason: String? = nil) {
        renderTask?.cancel()
        renderTask = nil
        state.compositeRenderProgress.removeAll()
        if let reason { state.showBanner(reason) }
    }

    /// Auto-render: when enabled, render the oldest dual take that has both files and no
    /// composite yet, but only if the policy allows (cool + charging + not recording).
    func processRenderQueueIfIdle() {
        guard state.autoRenderComposites, renderTask == nil, !isMock, compositeRenderVerdict.isAllowed else { return }
        if let next = state.takes.first(where: {
            $0.captureMode == .dualPodcastMultiCam && $0.compositeFileURL == nil && $0.innerFileURL != nil && $0.hasMediaOnDisk
        }) {
            renderComposite(takeID: next.id)
        }
    }

    private func saveCompositeToPhotos(_ url: URL) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            state.lastSaveMessage = "Composite saved in Files › DuoDirector › Takes."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
            }
            state.lastSaveMessage = "Composite saved to Photos and Files › Takes."
        } catch {
            state.lastSaveMessage = "Composite is in Files › Takes (Photos: \(error.localizedDescription))."
        }
    }

    // MARK: Captions & social export (Phase 11)

    /// Transcribes a take on the phone and saves `<take>.srt` next to its files.
    /// `quiet`: auto-captions after a take only report failures in the status note.
    func generateCaptions(takeID: TakeRecord.ID, quiet: Bool = false) {
        guard !state.captioningTakeIDs.contains(takeID),
              let take = state.takes.first(where: { $0.id == takeID }),
              let source = [take.rearFileURL, take.compositeFileURL].compactMap({ $0 })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        state.captioningTakeIDs.insert(takeID)
        Task { [weak self] in
            do {
                let url = try await CaptionTranscriber.makeCaptions(for: source)
                guard let self else { return }
                if let i = state.takes.firstIndex(where: { $0.id == takeID }) {
                    state.takes[i].captionsURL = url
                    cloudSync?.uploadTake(state.takes[i])
                }
                if !quiet { state.showBanner(String(localized: "Captions ready for take \(take.takeNumber).")) }
            } catch {
                if quiet { self?.state.statusNote = String(localized: "Captions skipped: \(error.localizedDescription)") }
                else { self?.state.showBanner(error.localizedDescription) }
            }
            self?.state.captioningTakeIDs.remove(takeID)
        }
    }

    var socialExportVerdict: CompositeRenderPolicy.Verdict {
        SocialExportPolicy.verdict(isRecording: state.isRecording || state.status == .saving,
                                   isRendering: renderTask != nil || socialTask != nil,
                                   thermal: ThermalPolicy.effectiveLevel(thermal: state.thermalState, cameraPressure: cameraPressure),
                                   isCharging: state.isCharging, batteryLevel: state.batteryLevel)
    }

    func exportForSocial(takeID: TakeRecord.ID, options: SocialExporter.Options) {
        guard case .allowed = socialExportVerdict else {
            if case .blocked(let reason) = socialExportVerdict { state.showBanner(reason) }
            return
        }
        guard let take = state.takes.first(where: { $0.id == takeID }) else { return }
        state.socialExportProgress[takeID] = 0
        socialTask = Task { [weak self] in
            do {
                let url = try await SocialExporter.export(take: take, options: options) { fraction in
                    Task { @MainActor in self?.state.socialExportProgress[takeID] = fraction }
                }
                guard let self else { return }
                if let i = state.takes.firstIndex(where: { $0.id == takeID }) { state.takes[i].socialExportURL = url }
                await saveCompositeToPhotos(url)
            } catch {
                self?.state.showBanner(String(localized: "Export didn't finish: \(error.localizedDescription)"))
            }
            self?.state.socialExportProgress[takeID] = nil
            self?.socialTask = nil
        }
    }

    func cancelSocialExport() {
        socialTask?.cancel()
        socialTask = nil
        state.socialExportProgress.removeAll()
    }

    // MARK: Takes management (Phase 5)

    /// Deletes a take's files (camera files, sidecars, composite) and its markers.
    /// Photos copies are left alone on purpose: the app only has add-only access.
    func deleteTake(_ id: TakeRecord.ID) {
        guard let take = state.takes.first(where: { $0.id == id }), !(state.isRecording && take.takeNumber == state.takeNumber) else { return }
        for url in [take.rearFileURL, take.innerFileURL, take.sidecarJSONURL, take.sidecarFCPXMLURL, take.compositeFileURL,
                    take.captionsURL, take.socialExportURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        // Phase 7: tombstones so iCloud propagates the deletion instead of restoring it.
        let now = Date()
        state.deletedTakeIDs[id] = now
        for marker in state.markers(forTake: take.takeNumber) { state.deletedMarkerIDs[marker.id] = now }
        state.takes.removeAll { $0.id == id }
        state.chapterMarkers.removeAll { $0.takeNumber == take.takeNumber }
        cloudSync?.deleteCloudFiles(of: take)
    }

    /// Re-reads markers from the .mov's timed-metadata track (MovieMarkerTrack) and merges
    /// any the project doesn't have (e.g. after restoring files without the project).
    @discardableResult
    func recoverMarkers(for id: TakeRecord.ID) async -> Int {
        guard let take = state.takes.first(where: { $0.id == id }), let url = take.rearFileURL,
              let found = try? await MovieMarkerTrack.readMarkers(from: url) else { return 0 }
        let existing = state.markers(forTake: take.takeNumber)
        let new = found
            .map { var m = $0; m.takeNumber = take.takeNumber; return m }
            .filter { candidate in !existing.contains { abs($0.timestamp - candidate.timestamp) < 0.5 } }
        state.chapterMarkers.append(contentsOf: new)
        return new.count
    }

    private func updateCurrentTake(_ change: (inout TakeRecord) -> Void) {
        guard let index = state.takes.lastIndex(where: { $0.takeNumber == state.takeNumber }) else { return }
        change(&state.takes[index])
    }

    private func writeSidecars() {
        guard let index = state.takes.lastIndex(where: { $0.takeNumber == state.takeNumber }) else { return }
        let take = state.takes[index]
        let settings = TakeSidecarExporter.Settings(resolution: state.resolution, frameRate: state.frameRate.rawValue,
                                                    codec: state.preferredCodec, dolbyVision: state.isDolbyVisionActive)
        do {
            let urls = try TakeSidecarExporter.write(take: take, markers: state.markers(forTake: take.takeNumber), settings: settings)
            state.takes[index].sidecarJSONURL = urls.json
            state.takes[index].sidecarFCPXMLURL = urls.fcpxml
        } catch {
            state.statusNote = "Couldn't write sidecar: \(error.localizedDescription)"
        }
    }

    // MARK: Markers & ratings

    /// "Mark Take" / "Drop Marker": timestamped marker during a take.
    func markTake(note: String? = nil, goodTake: Bool = false) {
        guard state.isRecording else { return }
        writeMarkerIntoFiles(state.addChapterMarker(note: note, goodTake: goodTake))
    }

    func dropMarker(rating: Int = 3, note: String? = nil) {
        guard state.isRecording else { return }
        writeMarkerIntoFiles(state.addMarker(note: note, rating: rating))
        recordingActivity?.update(markerCount: state.markers(forTake: state.takeNumber).count)
    }

    /// Phase 5: the same marker also goes into the .mov's timed-metadata track
    /// (MovieMarkerTrack), timed on the session clock, in both files in Dual-Cam.
    private func writeMarkerIntoFiles(_ marker: TakeMarker) {
        guard !isMock else { return }
        controller.sessionQueue.async { [controller] in controller.appendMarker(marker) }
    }

    /// For diagnostics: where markers end up.
    func markerTrackStatus() async -> String {
        guard !isMock else { return "Sidecar only (Simulator)" }
        return await onSessionQueue { $0.markerTrackStatus }
    }

    /// "Rate Take": stars for the rolling take, or the last one. If the take's sidecar
    /// already exists, it's rewritten with the new rating.
    func rateTake(_ stars: Int) {
        state.rateCurrentTake(stars)
        if !state.isRecording, let last = state.takes.last, last.sidecarJSONURL != nil {
            let settings = TakeSidecarExporter.Settings(resolution: state.resolution, frameRate: state.frameRate.rawValue,
                                                        codec: state.preferredCodec, dolbyVision: state.isDolbyVisionActive)
            _ = try? TakeSidecarExporter.write(take: last, markers: state.markers(forTake: last.takeNumber), settings: settings)
        }
    }

    // MARK: Photos

    /// Saves every file of the take (rear + inner) to Photos. Sidecars stay in
    /// Documents/Takes next to our copies of the .movs (Photos can't hold sidecars); all
    /// share the session identifier written into each file's metadata.
    private func saveToPhotos(_ urls: [URL]) async {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else {
            state.lastSaveMessage = "Saved in Files › DuoDirector › Takes. Allow Photos access in Settings to save to your library."
            return
        }
        do {
            let identifiers = IdentifierBox()
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false   // keep our copy next to the sidecar
                    request.addResource(with: .video, fileURL: url, options: options)
                    if let id = request.placeholderForCreatedAsset?.localIdentifier { identifiers.values.append(id) }
                }
            }
            state.lastSavedPhotosIdentifier = identifiers.values.first
            updateCurrentTake { $0.photosIdentifiers = identifiers.values }
            let files = urls.count == 2 ? "Both camera files" : "Take"
            state.lastSaveMessage = "\(files) saved to Photos\(state.isDolbyVisionActive ? " (Dolby Vision)" : ""). Sidecar in Files › Takes."
        } catch {
            state.lastSaveMessage = "Couldn't save to Photos: \(error.localizedDescription). Files are in DuoDirector › Takes."
        }
    }

    private final class IdentifierBox: @unchecked Sendable { var values: [String] = [] }

    // MARK: Focus

    func focus(atDevicePoint devicePoint: CGPoint) {
        state.isAutoFocus = true
        guard !isMock else { return }
        controller.sessionQueue.async { [controller] in try? controller.focus(atDevicePoint: devicePoint) }
    }

    // MARK: Cover accessory lifecycle (Phase 4)

    /// Wired to CameraCaptureAccessory.onAvailabilityChange. The capture session never
    /// depends on the accessory, so a withdrawal can't interrupt recording. We just tell
    /// the inner UI to take over the prompter and controls.
    func outerAccessoryAvailabilityChanged(_ available: Bool) {
        let wasActive = state.isOuterAccessoryActive
        state.isOuterAccessoryActive = available
        if available {
            if state.wasOuterAccessoryWithdrawn { state.showBanner("Cover monitor is back.", seconds: 3) }
            state.wasOuterAccessoryWithdrawn = false
        } else if wasActive && state.outerAccessoryShouldBeEnabled {
            // We wanted it and iOS took it away (fold change, another accessory, etc.).
            state.wasOuterAccessoryWithdrawn = true
            state.showBanner(state.isRecording
                ? "Cover monitor was withdrawn by iOS. Prompter and controls are on this screen. Still recording."
                : "Cover monitor was withdrawn by iOS. Prompter and controls are on this screen.")
        }
    }

    // MARK: Thermal & battery guardrails (Phase 4)

    /// For the diagnostics sheet: test the guard without heating the phone.
    func simulateThermalState(_ thermal: ProcessInfo.ThermalState?) {
        simulatedThermal = thermal
        processThermalChanged(ProcessInfo.processInfo.thermalState)
    }

    private func processThermalChanged(_ thermal: ProcessInfo.ThermalState) {
        let effective = simulatedThermal ?? thermal
        state.thermalState = effective
        applyThermalPolicy()
    }

    private func cameraPressureChanged(_ level: AVCaptureDevice.SystemPressureState.Level) {
        state.cameraPressureLevel = level.rawValue
        cameraPressure = switch level {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical, .shutdown: .critical
        default: .nominal
        }
        applyThermalPolicy()
    }

    /// Effective level = worst of ProcessInfo thermal state and camera system pressure.
    ///  • nominal/fair: restore anything we paused.
    ///  • serious:  pause focus peaking + zebras (GPU analysis); recording untouched.
    ///  • critical: also pause cover-accessory content (isEnabled = false) and step frame
    ///              rate down to 24/30. If a take is rolling, the fps change waits until it
    ///              ends, because changing format mid-take could drop frames.
    private func applyThermalPolicy() {
        // Decisions are pure (ThermalPolicy, unit-tested); this method does the effects.
        let level = ThermalPolicy.effectiveLevel(thermal: state.thermalState, cameraPressure: cameraPressure)
        let actions = ThermalPolicy.actions(for: level)
        if renderTask != nil, CompositeRenderPolicy.shouldAbort(thermal: level) {
            cancelCompositeRender(reason: "Composite render stopped: iPhone is getting warm. It'll resume when cool and charging.")
        }
        if actions.pauseOverlays {
            if !state.overlaysSuspendedForThermal {
                savedOverlayPrefs = (state.showFocusPeaking, state.showZebraStripes)
                state.showFocusPeaking = false
                state.showZebraStripes = false
                state.overlaysSuspendedForThermal = true
                overlayStore.isThermallyPaused = true
                state.showBanner("iPhone is warm. Peaking & zebras paused to keep recording smooth.")
            }
        } else if state.overlaysSuspendedForThermal {
            if let saved = savedOverlayPrefs {
                state.showFocusPeaking = saved.peaking
                state.showZebraStripes = saved.zebra
            }
            savedOverlayPrefs = nil
            state.overlaysSuspendedForThermal = false
            overlayStore.isThermallyPaused = false
            state.showBanner("Temperature back to normal. Overlays restored.", seconds: 3)
        }

        if actions.pauseAccessory {
            if !state.accessorySuspendedForThermal {
                state.accessorySuspendedForThermal = true   // → CameraCaptureAccessory(isEnabled: false)
                state.showBanner("iPhone is hot. Cover monitor paused\(state.isRecording ? "; recording continues on this screen" : "")."
                                 , seconds: nil)
            }
            if actions.stepDownFrameRate { stepDownFrameRateIfPossible() }
        } else if state.accessorySuspendedForThermal {
            state.accessorySuspendedForThermal = false
            if let original = state.thermalSteppedDownFrom, !state.isRecording {
                state.thermalSteppedDownFrom = nil
                state.frameRate = original
                Task { await reconfigure() }
            }
            state.showBanner("Cover monitor resumed.", seconds: 3)
        }
    }

    private func stepDownFrameRateIfPossible() {
        guard !state.isRecording else { return }   // wait for the take to end
        guard let target = ThermalPolicy.steppedDownFrameRate(from: state.frameRate) else { return }
        state.thermalSteppedDownFrom = state.thermalSteppedDownFrom ?? state.frameRate
        state.frameRate = target
        state.showBanner("iPhone is hot. Frame rate stepped down to \(target.label)fps.", seconds: nil)
        if !isMock { Task { await reconfigure() } }
    }

    private func applyDeferredThermalStepDown() {
        let level = ThermalPolicy.effectiveLevel(thermal: state.thermalState, cameraPressure: cameraPressure)
        if ThermalPolicy.actions(for: level).stepDownFrameRate { stepDownFrameRateIfPossible() }
    }

    private func batteryChanged(_ level: Float?, _ charging: Bool) {
        let wasCharging = state.isCharging
        state.batteryLevel = level
        state.isCharging = charging
        if renderTask != nil, wasCharging, !charging {
            cancelCompositeRender(reason: "Composite render paused: unplugged.")
        }
        processRenderQueueIfIdle()
        if let level, level < 0.1, !charging {
            state.showBanner("Battery below 10%. Plug in to keep shooting.", seconds: nil)
        }
    }

    private func storageChanged(_ bytes: Int64?) {
        state.availableStorageBytes = bytes
        updateStorageEstimate()
    }

    /// Minutes left at the current codec/resolution/fps, counting both files in dual mode.
    func updateStorageEstimate() {
        let bits = RecordingBitrate.totalBitsPerSecond(codec: state.preferredCodec, resolution: state.resolution,
                                                       frameRate: state.frameRate, dual: state.isDualCam)
        state.estimatedRecordingMinutesLeft = SystemMonitor.minutesLeft(bytes: state.availableStorageBytes,
                                                                         totalBitsPerSecond: bits)
    }

    // MARK: Observation → device

    private func observeOverlaySettings() {
        withObservationTracking {
            analyzer.update(.init(peaking: state.showFocusPeaking, zebra: state.showZebraStripes,
                                  zebraThreshold: state.zebraThreshold, histogram: state.showHistogram))
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOverlaySettings() }
        }
    }

    private func observeManualControls() {
        withObservationTracking {
            _ = (state.isAutoExposure, state.isoValue, state.shutterDuration,
                 state.isAutoWhiteBalance, state.whiteBalanceKelvin,
                 state.isAutoFocus, state.manualFocusPosition, state.audioGain)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleManualApply()
                self?.observeManualControls()
            }
        }
    }

    private func scheduleManualApply() {
        guard !manualApplyPending else { return }
        manualApplyPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(33))
            manualApplyPending = false
            await applyManualControls()
        }
    }

    private func applyManualControls() async {
        guard !isMock else { return }
        let iso: Float? = state.isAutoExposure ? nil : state.isoValue
        let shutter: Double? = state.isAutoExposure ? nil : state.shutterDuration
        let kelvin: Float? = state.isAutoWhiteBalance ? nil : state.whiteBalanceKelvin
        let lens: Float? = state.isAutoFocus ? nil : state.manualFocusPosition
        CaptureSessionController.setInputGain(state.audioGain)
        _ = await onSessionQueue { controller in
            try? controller.setExposure(iso: iso, duration: shutter)
            try? controller.setWhiteBalance(kelvin: kelvin)
            try? controller.setLensPosition(lens)
        }
    }

    // MARK: Audio metering

    private func applyAudio(_ levels: CaptureSessionController.AudioLevels) {
        let release: Float = 0.7
        state.leftChannelDB = max(levels.peakL, state.leftChannelDB - release)
        state.rightChannelDB = max(levels.peakR, state.rightChannelDB - release)
        state.leftChannelRMS = levels.rmsL
        state.rightChannelRMS = levels.rmsR

        let now = Date()
        if max(levels.peakL, levels.peakR) >= Self.clipThresholdDB {
            lastClipAt = now
            state.isAudioClipping = true
        } else if state.isAudioClipping, now.timeIntervalSince(lastClipAt) > Self.clipHoldSeconds {
            state.isAudioClipping = false
        }
    }

    private func startFallbackMeter() {
        fallbackMeterTask?.cancel()
        fallbackMeterTask = Task {
            while !Task.isCancelled {
                if let levels = await onSessionQueue({ $0.connectionAudioLevels() }) { applyAudio(levels) }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// Simulator meters. Normal mode: speech-like levels with a clip every ~8 s.
    /// Demo Mode: a two-person podcast (Host on L, Guest on R, alternating turns) so App
    /// Previews show believable stereo movement and no clip warnings.
    private func startMockAudio() {
        mockAudioTask?.cancel()
        mockAudioTask = Task {
            var t = 0.0
            while !Task.isCancelled {
                t += 0.033
                let gain = Double(0.35 + state.audioGain)
                if state.isDemoMode {
                    let hostTalking = sin(t * 0.4) > 0
                    let syllables = abs(sin(t * 9)) * (0.6 + 0.4 * abs(sin(t * 2.3)))
                    let talk = -46 + 34 * syllables * gain
                    let idle = -54 + Double.random(in: -2...2)
                    let l = Float(min(-3, hostTalking ? talk : idle)), r = Float(min(-3, hostTalking ? idle : talk))
                    applyAudio(.init(peakL: l, peakR: r, rmsL: l - 9, rmsR: r - 9))
                } else {
                    let envelope = (sin(t * 7) * 0.5 + 0.5) * (sin(t * 1.3) * 0.5 + 0.5)
                    let base = -50 + 46 * envelope * gain
                    let spike = t.truncatingRemainder(dividingBy: 8) < 0.12 ? 12.0 : 0
                    func ch(_ offset: Double) -> Float { Float(min(0, base + spike + offset + Double.random(in: -2...2))) }
                    let l = ch(0), r = ch(-3 * sin(t * 0.5))
                    applyAudio(.init(peakL: l, peakR: r, rmsL: l - 8, rmsR: r - 8))
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    // MARK: Demo Mode (Phase 4)

    /// Called by DemoModePreset. In mock mode, enables simulated MultiCam so dual previews
    /// can be captured for App Store screenshots.
    func setDemoMode(_ enabled: Bool) {
        state.isDemoMode = enabled
        if isMock {
            state.isMultiCamSupported = enabled || state.simulateMultiCamSupport
            if !state.isMultiCamSupported, state.isDualCam { state.captureMode = .singleRearPro }
        }
    }

    func setSimulatedMultiCamSupport(_ enabled: Bool) {
        state.simulateMultiCamSupport = enabled
        if isMock {
            state.isMultiCamSupported = enabled || state.isDemoMode
            if !state.isMultiCamSupported, state.isDualCam { state.captureMode = .singleRearPro }
        }
    }

    var activeCameraNames: [String] {
        if isMock {
            return state.isDualCam ? ["Simulated Fusion Main (rear)", "Simulated under-display (inner)"]
                                   : ["Simulated \(state.activeLens.detail)"]
        }
        return controller.activeCameraNames
    }

    // MARK: Helpers

    static func timecode(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable (CaptureSessionController) -> T) async -> T {
        let controller = controller
        return await withCheckedContinuation { continuation in
            controller.sessionQueue.async { continuation.resume(returning: work(controller)) }
        }
    }
}

/// Collects audio buffers on the audio queue and releases one batch (max peak, latest RMS)
/// every ~33 ms.
final class MeterAccumulator: Sendable {
    private struct Pending { var levels: CaptureSessionController.AudioLevels?; var lastFlush = Date.distantPast }
    private let lock = OSAllocatedUnfairLock(initialState: Pending())

    func add(_ levels: CaptureSessionController.AudioLevels) -> CaptureSessionController.AudioLevels? {
        lock.withLock { (pending: inout Pending) -> CaptureSessionController.AudioLevels? in
            if var merged = pending.levels {
                merged.peakL = max(merged.peakL, levels.peakL)
                merged.peakR = max(merged.peakR, levels.peakR)
                merged.rmsL = levels.rmsL
                merged.rmsR = levels.rmsR
                pending.levels = merged
            } else {
                pending.levels = levels
            }
            let now = Date()
            guard now.timeIntervalSince(pending.lastFlush) >= 0.033 else { return nil }
            pending.lastFlush = now
            defer { pending.levels = nil }
            return pending.levels
        }
    }
}
