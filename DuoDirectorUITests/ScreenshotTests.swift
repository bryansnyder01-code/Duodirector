import XCTest

/// Phase 6: App Store screenshots + a launch smoke test, driven by Demo Mode.
///
/// Every test launches the app with synthetic cameras, a throwaway project and the
/// Demo Mode preset, stages one scene through LaunchOptions, waits for that scene's
/// accessibility identifier and attaches a full-screen screenshot (kept even on success).
///
/// Run all of them and export the PNGs with:
///   scripts/capture-screenshots.sh "iPhone Duo" Screenshots/
/// Attachment names sort in App Store order: 01-cover, 02-flat, 03-tabletop…
final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(scene: String, rolling: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-DuoDirectorUITest", "YES",
            "-DuoDirectorMock", "YES",
            "-DuoDirectorDemoMode", "YES",
            "-DuoDirectorScreenshotScene", scene,
        ] + (rolling ? ["-DuoDirectorRolling", "YES"] : [])
        app.launch()
        return app
    }

    @MainActor
    private func waitFor(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 15) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(identifier) never appeared")
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String, settle: TimeInterval = 2) {
        // Let the synthetic camera, meters and prompter move so the frame looks alive.
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Screenshot set

    @MainActor func test01CoverDisplay() {
        let app = launch(scene: "cover")
        waitFor("coverMonitor", in: app)
        snapshot(app, "01-cover-5.4in-monitor")
    }

    @MainActor func test02InnerFlatDualCam() {
        let app = launch(scene: "flat", rolling: true)
        waitFor("innerDirector", in: app)
        snapshot(app, "02-inner-7.6in-flat-dualcam", settle: 3)
    }

    @MainActor func test03Tabletop() {
        let app = launch(scene: "tabletop", rolling: true)
        waitFor("tabletopDeck", in: app)
        snapshot(app, "03-tabletop-host-guest", settle: 3)
    }

    @MainActor func test04TakesBrowser() {
        let app = launch(scene: "takes")
        waitFor("takesBrowser", in: app)
        snapshot(app, "04-takes-browser")
    }

    @MainActor func test05Diagnostics() {
        let app = launch(scene: "diagnostics")
        waitFor("diagnostics", in: app)
        // The sheet opens full height for this scene. Wait until it has finished sliding
        // up (the Done button is hittable) so the glass isn't caught mid-blur.
        let done = app.buttons["Done"]
        _ = done.waitForExistence(timeout: 10)
        let deadline = Date().addingTimeInterval(10)
        while !done.isHittable && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        snapshot(app, "05-launch-diagnostics", settle: 3)
    }

    // MARK: Smoke

    /// Record → marker → stop in mock mode. Catches launch crashes and dead buttons.
    @MainActor func testRecordMarkerStopSmoke() {
        let app = launch(scene: "flat")
        waitFor("innerDirector", in: app)
        // The toolbar button by identifier: several controls are labelled "Record"
        // (rail, fallback strip), and their labels change during the countdown.
        let toggle = app.buttons["recordToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Record")
        toggle.tap()
        let rolling = NSPredicate(format: "label == 'Stop'")
        expectation(for: rolling, evaluatedWith: toggle)
        // 3 s countdown, plus slack: on a busy CI simulator each label check can take
        // several seconds, so 10 s allowed only two looks.
        waitForExpectations(timeout: 30)
        toggle.tap()
        expectation(for: NSPredicate(format: "label == 'Record'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 30)
    }
}
