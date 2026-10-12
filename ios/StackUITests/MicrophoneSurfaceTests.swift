import XCTest

@MainActor
final class MicrophoneSurfaceUITests: XCTestCase {
    private func launch(_ options: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--microphone-ui-fixture"] + options
        app.launch()
        let control = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Live transcription")).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        return app
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication, requireHit: Bool = true) {
        let scroll = app.scrollViews["microphone-fixture-scroll"]
        for _ in 0..<10 {
            if requireHit ? element.isHittable : element.frame.intersects(scroll.frame) { return }
            // Drag in the outer margin so an expanded live-text ScrollView cannot
            // swallow the gesture intended to reach Pause or Stop.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.85))
                .press(forDuration: 0.01, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2)))
        }
        XCTAssertTrue(requireHit ? element.isHittable : element.frame.intersects(scroll.frame))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10) == .completed
    }

    func testLiveVisibilityPauseStopAndRetryRetainAnswer() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Question 1 of 5")).firstMatch.exists)
        let toggle = app.buttons["Live transcription"]
        visible(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "Off")
        capture("microphone-recording-off")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "On")
        XCTAssertTrue(app.staticTexts["Synthetic live transcript"].exists)
        capture("microphone-recording-live")
        toggle.tap()
        XCTAssertFalse(app.staticTexts["Synthetic live transcript"].exists)
        let pause = app.buttons["Pause"]
        visible(pause, in: app); pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 5))
        let clock = app.descendants(matching: .any)["recording-status-clock"]
        let elapsed = clock.value as? String
        XCTAssertNotNil(elapsed)
        Thread.sleep(forTimeInterval: 1.25)
        XCTAssertEqual(clock.value as? String, elapsed)
        app.buttons["Resume"].tap()
        XCTAssertTrue(wait { (clock.value as? String ?? "").hasPrefix("Recording,") })
        let resumed = clock.value as? String
        XCTAssertTrue(wait { clock.value as? String != resumed })
        let stop = app.buttons["Stop recording"]
        visible(stop, in: app); stop.tap()
        XCTAssertTrue(app.staticTexts["Saved answer: Reviewed synthetic answer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved original: Synthetic recognized answer"].exists)
        let retry = app.buttons["Retry synthetic recording"]
        visible(retry, in: app); retry.tap()
        XCTAssertTrue(wait { app.buttons["Pause"].isEnabled && app.buttons["Live transcription"].exists })
    }

    func testUnavailableLiveControlExplainsFallback() {
        let app = launch(["--microphone-no-live"])
        let control = app.buttons["Live transcription unavailable"]
        visible(control, in: app, requireHit: false)
        XCTAssertFalse(control.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "PC transcription will be used")).firstMatch.exists)
        XCTAssertTrue(app.buttons["Stop recording"].exists)
        capture("microphone-fallback")
    }

    func testLargestTextAndReduceMotionKeepControlsAccessible() {
        let app = launch(["--microphone-large-type", "--microphone-reduce-motion"])
        capture("microphone-large-type-top")
        let toggle = app.buttons["Live transcription"]
        visible(toggle, in: app); toggle.tap()
        XCTAssertEqual(toggle.value as? String, "On")
        let stop = app.buttons["Stop recording"]
        visible(stop, in: app)
        capture("microphone-large-type-controls")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Saved answer: Reviewed synthetic answer"].waitForExistence(timeout: 5))
    }

    func testGeneratedSilenceLowersAccessibleLevel() {
        let app = launch()
        let level = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Microphone level")).firstMatch
        XCTAssertTrue(wait { ["Medium", "High"].contains(level.value as? String ?? "") })
        let silence = app.buttons["Send synthetic silence"]
        visible(silence, in: app); silence.tap()
        XCTAssertTrue(wait { level.value as? String == "No sound" })
        capture("microphone-silence")
    }
}
