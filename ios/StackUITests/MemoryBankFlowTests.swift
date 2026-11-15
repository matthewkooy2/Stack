import XCTest

/// Exercises the real screen and its existing RPC contract using the offline URLProtocol fixture.
@MainActor
final class MemoryBankFlowUITests: XCTestCase {
    func testChoicesSurviveAFailedSaveStayWithTheirResumeAndCanBeCleared() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screen-flow=memory-preview", "--disable-draft-animations", "--memory-save-fails-once"]
        app.launch()
        let choose = app.buttons["Choose facts for tailoring"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        choose.tap()
        let fact = app.buttons["memory-fact-memory-1-r0"]
        XCTAssertTrue(fact.waitForExistence(timeout: 5))
        XCTAssertEqual(fact.value as? String, "Not selected")
        XCTAssertFalse(app.buttons["memory-fact-memory-3-r0"].exists, "draft facts cannot be selected")
        fact.tap()
        let save = app.buttons["memory-save-choices"]
        save.tap()
        XCTAssertTrue(app.staticTexts["Memory choices could not be saved. Try again."].waitForExistence(timeout: 5))
        XCTAssertEqual(fact.value as? String, "Selected", "a failed save keeps the user's choices")
        save.tap()
        XCTAssertTrue(app.staticTexts["Choices saved for this resume."].waitForExistence(timeout: 5))
        app.buttons["Choose resume: Backup resume.pdf"].tap()
        XCTAssertEqual(fact.value as? String, "Not selected", "choices do not leak into a different resume")
        app.buttons["Choose resume: Main resume.pdf"].tap()
        XCTAssertEqual(fact.value as? String, "Selected", "the saved selection is restored from the server response")
        app.buttons["Clear choices"].tap()
        save.tap()
        XCTAssertTrue(app.staticTexts["Choices saved for this resume."].waitForExistence(timeout: 5))
        XCTAssertEqual(fact.value as? String, "Not selected")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "memory-bank-confirmed-fact-selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
