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

    @MainActor func test05SocialExport() {
        let app = launch(scene: "social")
        let toggle = app.switches["Vertical 9:16"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        waitUntilHittable(app.buttons["Cancel"])
        snapshot(app, "05-vertical-captions-export", settle: 2)
    }

    /// Not part of the App Store set any more (gauges at 0.00 don't sell the app), but it
    /// still checks that the diagnostics sheet opens.
    @MainActor func test06Diagnostics() {
        let app = launch(scene: "diagnostics")
        waitFor("diagnostics", in: app)
        waitUntilHittable(app.buttons["Done"])
        snapshot(app, "06-launch-diagnostics", settle: 3)
    }

    /// Sheets slide up with a glass blur; wait until the button is tappable so the shot
    /// isn't caught mid-animation.
    private func waitUntilHittable(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 10)
        let deadline = Date().addingTimeInterval(10)
        while !element.isHittable && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
    }

    // MARK: Smoke

    /// Record → marker → stop in mock mode. Catches launch crashes and dead buttons.
    @MainActor func testRecordMarkerStopSmoke() {
        let app = launch(scene: "flat")
        waitFor("innerDirector", in: app)
        // The rail's record button by identifier (the deck and fallback strip have their
        // own); its label reads "Cancel countdown" during the countdown.
        let toggle = app.buttons["recordToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Record")
        toggle.tap()
        let rolling = NSPredicate(format: "label == 'Stop recording'")
        expectation(for: rolling, evaluatedWith: toggle)
        // 3 s countdown, plus slack: on a busy CI simulator each label check can take
        // several seconds, so 10 s allowed only two looks.
        waitForExpectations(timeout: 30)
        toggle.tap()
        expectation(for: NSPredicate(format: "label == 'Record'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 30)
    }
}
