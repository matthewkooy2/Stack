import XCTest

@MainActor
final class AccessFlowTests: XCTestCase {
    private func capture(_ name: String) {
        // Existence can become true before the staggered reveal has finished.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWelcomeNavigationAndLocalValidation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Create an account"].waitForExistence(timeout: 10))
        capture("welcome")
        for _ in 0..<3 {
            app.buttons["Sign in"].tap()
            XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
            app.buttons["Sign in"].tap()
            XCTAssertTrue(app.staticTexts["Use a username of at least 3 characters and a password of at least 8."].waitForExistence(timeout: 5))
            capture("sign-in-validation")
            app.buttons["New here? Create an account"].tap()
            XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5))
            capture("sign-up")
            app.buttons["Back"].tap()
            XCTAssertTrue(app.buttons["Create an account"].waitForExistence(timeout: 5))
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["Create an account"].waitForExistence(timeout: 10))
        capture("welcome-after-relaunch")
    }

    func testNamedFieldsAndKeyboardValidation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 10))
        app.buttons["Sign in"].tap()
        let username = app.textFields["Username"]
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap()
        username.typeText("ab")
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Sign in"].isHittable)
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.staticTexts["Use a username of at least 3 characters and a password of at least 8."].waitForExistence(timeout: 5))
        capture("keyboard-validation")
    }
}
