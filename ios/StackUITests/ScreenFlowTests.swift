import XCTest

/// Drives the real simplified screens inside the offline `--screen-flow=` fixture: a fictional account answered
/// by a stub URLProtocol. No sign-in, token, network or live data. Every flow keeps screenshot attachments.
@MainActor
final class ScreenFlowUITests: XCTestCase {
    private func launch(_ flow: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screen-flow=\(flow)", "--disable-draft-animations"]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        // Existence can become true before the staggered reveal has finished.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Rows announce "label, detail", so match on the label's start.
    private func row(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func field(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let kinds = [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
                     XCUIElement.ElementType.secureTextField.rawValue]
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
                        label, kinds[0], kinds[1], kinds[2])).firstMatch
    }

    private func text(_ field: XCUIElement) -> String { field.value as? String ?? "" }

    private func closeButtons(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "label == %@", "Close")).allElementsBoundByIndex
    }

    /// Sheets can stack; the topmost presented Close is the last one in the hierarchy.
    private func closeTop(_ app: XCUIApplication) {
        let closes = closeButtons(app)
        XCTAssertFalse(closes.isEmpty, "there is a sheet to close")
        closes.last?.tap()
    }

    /// Polls a condition on the run loop; unlike a fixed sleep it fails when the state never arrives.
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Scrolls the frontmost scroll view, a bounded number of times, until the element can be tapped:
    /// down the page first, then back up. Long sheets and the keyboard can leave a control off screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) -> Bool {
        func ready() -> Bool { element.exists && element.isHittable }
        if ready() { return true }
        for direction in [true, false] {
            for _ in 0..<attempts {
                let target = app.scrollViews.allElementsBoundByIndex.last ?? app.windows.firstMatch
                if direction { target.swipeUp() } else { target.swipeDown() }
                if ready() { return true }
            }
        }
        return ready()
    }

    /// Reveals then taps, failing with the element's description when it never becomes tappable.
    private func tap(_ element: XCUIElement, in app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(reveal(element, in: app), "\(what) is reachable by scrolling", file: file, line: line)
        element.tap()
    }

    // MARK: Settings

    func testSettingsDetailsDraftSurvivesBackAndReopen() {
        let app = launch("settings")
        XCTAssertTrue(row(app, "Your details").waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "Job matching").exists)
        XCTAssertTrue(row(app, "Account").exists)
        capture("settings-hub")

        row(app, "Your details").tap()
        let name = field(app, "Your name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Lovelace")
        capture("settings-details-editing")

        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["Save changes"].waitForExistence(timeout: 5), "an unsaved edit offers Save on the hub")
        capture("settings-hub-unsaved")

        row(app, "Your details").tap()
        XCTAssertTrue(field(app, "Your name").waitForExistence(timeout: 5))
        XCTAssertTrue(text(field(app, "Your name")).contains("Lovelace"), "the draft survives going back and reopening")
        capture("settings-details-draft-retained")

        // The model settings request failed once at launch; its error stays visible with the picker collapsed.
        app.buttons["Back"].tap()
        row(app, "Account").tap()
        XCTAssertTrue(app.staticTexts["Model settings are unavailable right now."].waitForExistence(timeout: 5))
        capture("settings-account-model-error")
    }

    // MARK: Resume

    func testResumeManageRenameSurvivesNestedSheets() {
        let app = launch("resume")
        let resume = row(app, "Ada Example - Senior")
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "Tailor for a job").exists)
        capture("resume-list-long-name")

        resume.tap()
        XCTAssertTrue(app.buttons["Manage"].waitForExistence(timeout: 5))
        capture("resume-actions")
        tap(app.buttons["Manage"], in: app, "Manage")
        let rename = field(app, "Resume name")
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        tap(rename, in: app, "the rename field")
        rename.typeText(" v2")
        capture("resume-rename-draft")

        tap(row(app, "Review details"), in: app, "Review details")
        XCTAssertTrue(app.staticTexts["Resume details"].waitForExistence(timeout: 5))
        capture("resume-details-nested")
        closeTop(app)

        XCTAssertTrue(row(app, "Format").waitForExistence(timeout: 5))
        tap(row(app, "Format"), in: app, "Format")
        XCTAssertTrue(app.staticTexts["Tailoring format"].waitForExistence(timeout: 5))
        capture("resume-format-nested")
        closeTop(app)

        // The preview sheet is ready when its marker exists or a second Close button has been presented.
        let preview = app.descendants(matching: .any).matching(identifier: "pdf-preview").firstMatch
        XCTAssertTrue(waitUntil(5) { row(app, "Preview").exists }, "Preview row is back after closing Format")
        let closesBefore = closeButtons(app).count
        tap(row(app, "Preview"), in: app, "Preview")
        XCTAssertTrue(waitUntil(15) { preview.exists || closeButtons(app).count > closesBefore },
                      "the PDF preview sheet appeared (marker or an added Close button)")
        XCTAssertFalse(app.staticTexts["This document is not available to preview."].exists, "no preview error is shown")
        capture("resume-preview-nested")
        closeTop(app)
        XCTAssertTrue(waitUntil(5) { !preview.exists && closeButtons(app).count == closesBefore },
                      "the preview sheet closed and the Manage sheet is frontmost again")

        XCTAssertTrue(field(app, "Resume name").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(field(app, "Resume name"), in: app), "the rename field is reachable after returning")
        XCTAssertTrue(text(field(app, "Resume name")).contains(" v2"), "the rename draft is retained")
        capture("resume-rename-retained")
    }

    // MARK: Network

    func testNetworkContactDraftAndLinkedInRetryAreRetained() {
        let app = launch("network")
        XCTAssertTrue(row(app, "Your contacts").waitForExistence(timeout: 10))
        capture("network-list")

        row(app, "Your contacts").tap()
        XCTAssertTrue(app.buttons["Add a contact"].waitForExistence(timeout: 5))
        app.buttons["Add a contact"].tap()
        let name = field(app, "Contact name")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Katherine Example")
        capture("network-contact-draft")
        app.buttons["Close"].tap()

        XCTAssertTrue(row(app, "Your contacts").waitForExistence(timeout: 5))
        row(app, "Your contacts").tap()
        XCTAssertTrue(field(app, "Contact name").waitForExistence(timeout: 5))
        XCTAssertTrue(text(field(app, "Contact name")).contains("Katherine"), "the contact draft survives close and reopen")
        capture("network-contact-draft-retained")
        app.buttons["Close"].tap()

        XCTAssertTrue(row(app, "LinkedIn review").waitForExistence(timeout: 5))
        row(app, "LinkedIn review").tap()
        XCTAssertTrue(app.buttons["Retry loading profile"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["LinkedIn profile service is unavailable. Try again."].exists)
        XCTAssertFalse(field(app, "Target role (optional)").exists, "fields stay hidden until the profile loads")
        capture("network-linkedin-load-failed")

        app.buttons["Retry loading profile"].tap()
        let role = field(app, "Target role (optional)")
        XCTAssertTrue(role.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Retry loading profile"].exists)
        role.tap()
        role.typeText(" lead")
        capture("network-linkedin-loaded-editing")
        app.buttons["Close"].tap()

        XCTAssertTrue(row(app, "LinkedIn review").waitForExistence(timeout: 5))
        row(app, "LinkedIn review").tap()
        XCTAssertTrue(field(app, "Target role (optional)").waitForExistence(timeout: 10))
        XCTAssertTrue(text(field(app, "Target role (optional)")).contains("lead"), "the typed role survives close and reopen")
        capture("network-linkedin-draft-retained")
    }

    // MARK: Applications

    func testApplicationDetailDisclosuresAndNotesSaveRecovery() {
        let app = launch("applications")
        let application = row(app, "Senior Product Data Analyst")
        XCTAssertTrue(application.waitForExistence(timeout: 10))
        capture("applications-list-long-title")

        application.tap()
        XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 5))
        // Disclosure rows announce "title, detail", so match on the title's start. The detail sheet is long,
        // so each row and the setup guidance are scrolled into view rather than assumed on screen.
        XCTAssertTrue(reveal(row(app, "Resume"), in: app), "the Resume row is reachable")
        XCTAssertTrue(reveal(row(app, "Status history"), in: app), "the Status history row is reachable")
        let setup = app.staticTexts["✕ Connect a model provider in Agents."].firstMatch
        XCTAssertTrue(reveal(setup, in: app), "required setup guidance is shown and reachable")
        capture("applications-detail-setup-guidance")

        tap(app.buttons["Notes"], in: app, "Notes")
        let notes = field(app, "Your notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        tap(notes, in: app, "the notes field")
        notes.typeText("Follow up with the recruiter on Friday")
        capture("applications-notes-keyboard")
        let save = app.buttons["Save notes"]
        tap(save, in: app, "Save notes")
        let failure = app.staticTexts["We couldn't save your notes. Check your connection and try again."]
        XCTAssertTrue(waitUntil(8) { failure.exists || reveal(failure, in: app, attempts: 2) },
                      "the failed save explains itself")
        capture("applications-notes-save-failed")

        XCTAssertTrue(reveal(field(app, "Your notes"), in: app), "the notes field is reachable after the failure")
        XCTAssertTrue(text(field(app, "Your notes")).contains("Follow up"), "the note stays after the failed save")
        tap(save, in: app, "Save notes (retry)")
        let saved = app.staticTexts["Saved to your Stack."]
        XCTAssertTrue(waitUntil(8) { saved.exists || reveal(saved, in: app, attempts: 2) }, "the retry confirms the save")
        capture("applications-notes-saved")
    }

    // MARK: Jobs

    func testJobDetailShowsFullFitAndTagsOnDemand() {
        let app = launch("jobs")
        XCTAssertTrue(app.buttons["Open job details"].waitForExistence(timeout: 10))
        capture("jobs-card-clamped")
        app.buttons["Open job details"].tap()
        let disclosure = app.buttons["Fit and tags"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 10))
        capture("jobs-detail-collapsed")
        tap(disclosure, in: app, "Fit and tags")
        let fit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "project work covers")).firstMatch
        XCTAssertTrue(waitUntil(5) { fit.exists }, "the full fit note is available")
        XCTAssertTrue(reveal(fit, in: app), "the full fit note can be scrolled to")
        let tag = app.staticTexts["Remote friendly"]
        XCTAssertTrue(reveal(tag, in: app), "tags beyond the card's first three are available")
        capture("jobs-detail-fit-and-tags")
    }

    // MARK: Onboarding

    func testWelcomeIsShortAndRecoveryCanBeCancelled() {
        let welcome = launch("onboarding")
        XCTAssertTrue(welcome.buttons["Create an account"].waitForExistence(timeout: 10))
        XCTAssertTrue(welcome.staticTexts["Find roles, track applications, practice interviews."].exists)
        XCTAssertTrue(welcome.buttons["Sign in"].exists)
        capture("onboarding-welcome")
        welcome.terminate()

        let app = launch("recovery")
        XCTAssertTrue(app.buttons["Use my existing Stack account"].waitForExistence(timeout: 10))
        capture("recovery-collapsed")
        app.buttons["Use my existing Stack account"].tap()
        XCTAssertTrue(field(app, "Existing Stack username").waitForExistence(timeout: 5))
        capture("recovery-open")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Use my existing Stack account"].waitForExistence(timeout: 5))
        XCTAssertFalse(field(app, "Existing Stack username").exists)
        capture("recovery-cancelled")
    }
}
