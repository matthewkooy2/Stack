import XCTest

@MainActor
final class AccessFlowTests: XCTestCase {
    func testOfflineLocalDraftEditingWithAnimationsDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["--local-draft-ui-test", "--disable-draft-animations"]
        app.launch()
        XCTAssertTrue(app.buttons["Public profiles"].waitForExistence(timeout: 10))
        for _ in 0..<2 {
            app.buttons["Public profiles"].tap()
            XCTAssertTrue(app.staticTexts["Public profiles"].waitForExistence(timeout: 5))
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Headline")).firstMatch.tap()
            let draft = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", "Draft", XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue)).firstMatch
            XCTAssertTrue(draft.waitForExistence(timeout: 5))
            draft.tap()
            draft.typeText("Testing my profile")
            app.scrollViews.firstMatch.swipeUp()
            app.buttons["Save draft"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Testing my profile")).firstMatch.waitForExistence(timeout: 5))
            capture("public-profile-local-draft-animation-disabled")
            app.buttons["Close"].tap()
        }
        app.buttons["LinkedIn rewrites"].tap()
        XCTAssertTrue(app.buttons["Approve selected rewrites"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeUp()
        app.buttons["Approve selected rewrites"].tap()
        XCTAssertTrue(app.buttons["Copy approved rewrites"].waitForExistence(timeout: 5))
        app.buttons["Copy approved rewrites"].tap()
        XCTAssertTrue(app.staticTexts["Copied. Apply the text on LinkedIn when you're ready."].waitForExistence(timeout: 5))
        capture("linkedin-approved-local-rewrites-animation-disabled")
        app.scrollViews.firstMatch.swipeDown()
        app.buttons["Close"].tap()
        app.buttons["LinkedIn rewrites"].tap()
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(app.buttons["Copy approved rewrites"].waitForExistence(timeout: 5))
    }
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
        // A whole-screen swipe starts over the keyboard rather than the scrollable form.
        app.scrollViews.firstMatch.swipeUp()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        let submit = app.buttons["Sign in"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: submit)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.staticTexts["Use a username of at least 3 characters and a password of at least 8."].waitForExistence(timeout: 5))
        capture("keyboard-validation")
    }
}

