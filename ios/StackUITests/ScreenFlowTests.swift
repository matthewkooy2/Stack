import XCTest

/// Drives the real simplified screens inside the offline `--screen-flow=` fixture: a fictional account answered
/// by a stub URLProtocol. No sign-in, token, network or live data. Every flow keeps screenshot attachments.
@MainActor
final class ScreenFlowUITests: XCTestCase {
    private func launch(_ flow: String, extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screen-flow=\(flow)", "--disable-draft-animations"] + extra
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

    /// Stacked sheets each keep a Close button in the hierarchy. The one in front is the hittable one that sits
    /// lowest on screen; hierarchy order and index are not a reliable signal.
    private func frontClose(_ app: XCUIApplication) -> XCUIElement? {
        closeButtons(app).filter { $0.exists && $0.isHittable }.max { $0.frame.minY < $1.frame.minY }
    }

    private func closeTop(_ app: XCUIApplication) {
        guard let close = frontClose(app) else {
            diagnose(app, "no-hittable-close")
            XCTFail("a presented sheet has a hittable Close button")
            return
        }
        close.tap()
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

    /// Asserts a condition that is waited for, and keeps a screenshot plus the accessibility tree when it never holds.
    @discardableResult
    private func require(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
        let held = waitUntil(timeout, condition)
        if !held {
            diagnose(app, what)
            XCTFail("\(what)", file: file, line: line)
        }
        return held
    }

    /// A screenshot and the accessibility hierarchy, kept so a failure can be diagnosed from the result bundle.
    private func diagnose(_ app: XCUIApplication, _ what: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "diagnostic-\(what)"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ax-tree-\(what)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// A drag along the page's left margin, clear of text fields, so it moves the page rather than a field.
    /// SwiftUI sheet scroll views are not reported as ScrollView elements, so the window is the stable target.
    private func dragPage(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: from))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Whether the element is on screen and clear of the system edges: the top inset, the home indicator and
    /// the keyboard, where a tap can land without reaching the control.
    private func comfortable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let window = app.windows.firstMatch.frame
        var bottom = window.maxY - window.height * 0.10
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY - 8) }
        return element.frame.midY > window.minY + window.height * 0.10 && element.frame.midY < bottom
    }

    /// Scrolls the page, a bounded number of times, until the element is comfortably tappable: up the page first,
    /// then back down. Returns false (with diagnostics) when it never gets there.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6, _ what: String = "element") -> Bool {
        if comfortable(element, in: app) { return true }
        for forward in [true, false] {
            for _ in 0..<attempts {
                if forward { dragPage(app, from: 0.55, to: 0.25) } else { dragPage(app, from: 0.3, to: 0.6) }
                if comfortable(element, in: app) { return true }
            }
        }
        diagnose(app, "reveal-failed-\(what)")
        return false
    }

    /// Reveals then taps, failing with diagnostics when the element never becomes comfortably tappable.
    private func tap(_ element: XCUIElement, in app: XCUIApplication, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(reveal(element, in: app, what), "\(what) is reachable by scrolling", file: file, line: line)
        element.tap()
    }

    /// Dismisses the keyboard the way a person does: drag the page toward it (the page dismisses interactively),
    /// then drag the keyboard itself down. Verified, not assumed.
    private func dismissKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        dragPage(app, from: 0.35, to: 0.9)
        if waitUntil(2, { !keyboard.exists }) { return }
        keyboard.swipeDown()
        require(app, "the keyboard dismissed by a drag", timeout: 4) { !keyboard.exists }
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
        require(app, "the PDF preview sheet appeared (marker or an added Close button)", timeout: 15) {
            preview.exists || closeButtons(app).count > closesBefore
        }
        XCTAssertFalse(app.staticTexts["This document is not available to preview."].exists, "no preview error is shown")
        capture("resume-preview-nested")
        let previewClose = app.buttons["pdf-preview-close"]
        XCTAssertTrue(previewClose.waitForExistence(timeout: 5), "the preview sheet has its own identified Close")
        XCTAssertTrue(previewClose.isHittable, "the preview's Close is the visible front button")
        previewClose.tap()
        require(app, "the preview sheet closed and the Manage sheet is frontmost again", timeout: 5) {
            !preview.exists && !previewClose.exists
        }

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

    private func openApplicationHelp(_ app: XCUIApplication) {
        let application = row(app, "Senior Product Data Analyst")
        XCTAssertTrue(application.waitForExistence(timeout: 10))
        application.tap()
        let help = row(app, "Agent help")
        XCTAssertTrue(reveal(help, in: app, "agent-help"))
        // Use the revealed control's measured center and verify the disclosure transition before searching
        // for its children. The failed capture still had Agent help collapsed, so scrolling for a child hid
        // the missed transition rather than revealing that action.
        help.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        require(app, "agent-help-expanded") { help.value as? String == "Expanded" }
    }

    func testAutofillStartsWithoutModelAndOpensReviewTask() {
        let app = launch("applications")
        openApplicationHelp(app)
        let autofill = row(app, "Autofill saved answers")
        XCTAssertTrue(reveal(autofill, in: app, "autofill-action"))
        XCTAssertTrue(autofill.isEnabled, "autofill does not require a model provider")
        XCTAssertTrue(autofill.label.contains("may autosave"))
        tap(autofill, in: app, "start-autofill")
        XCTAssertTrue(app.staticTexts["Fixture autofill waiting for your review."].firstMatch.waitForExistence(timeout: 10),
                      "starting autofill opens its task, using the returned task ID")
        capture("applications-autofill-review-task")
    }

    func testMixedAutofillAndModelSetupIsDeduplicatedAndUnavailableActionIsDisabled() {
        let app = launch("applications-autofill-unavailable")
        openApplicationHelp(app)
        let autofill = row(app, "Autofill saved answers")
        XCTAssertTrue(reveal(autofill, in: app, "unavailable-autofill-action"))
        XCTAssertFalse(autofill.isEnabled)
        let browserFix = app.staticTexts["✕ Configure the browser worker for autofill."].firstMatch
        XCTAssertTrue(reveal(browserFix, in: app, "browser-setup-guidance"))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "✕ Connect a model provider in Agents.")).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "✕ Configure the browser worker for autofill.")).count, 1)
        capture("applications-mixed-autofill-setup")
    }

    func testApplicationDetailDisclosuresAndNotesSaveRecovery() {
        let app = launch("applications")
        let application = row(app, "Senior Product Data Analyst")
        XCTAssertTrue(application.waitForExistence(timeout: 10))
        capture("applications-list-long-title")

        application.tap()
        XCTAssertTrue(app.buttons["Notes"].waitForExistence(timeout: 5))
        // Disclosure rows announce "title, detail", so match on the title's start. The detail sheet is long,
        // so each row and the setup guidance are scrolled into view rather than assumed on screen.
        XCTAssertTrue(reveal(row(app, "Resume"), in: app, "resume-row"), "the Resume row is reachable")
        XCTAssertTrue(reveal(row(app, "Status history"), in: app, "history-row"), "the Status history row is reachable")
        let setup = app.staticTexts["✕ Connect a model provider in Agents."].firstMatch
        XCTAssertTrue(reveal(setup, in: app, "setup-guidance"), "required setup guidance is shown and reachable")
        let fixCount = app.staticTexts.matching(NSPredicate(format: "label == %@", "✕ Connect a model provider in Agents.")).count
        XCTAssertEqual(fixCount, 1, "the shared setup fix is said once, not per task")
        XCTAssertFalse(row(app, "Explain my fit").exists, "the task choices stay collapsed until asked for")
        capture("applications-detail-setup-guidance")

        // The choices, and the no-start/no-send assurance, are one tap away.
        tap(row(app, "Agent help"), in: app, "agent-help")
        XCTAssertTrue(reveal(row(app, "Explain my fit"), in: app, "explain-fit"), "the task choices open on demand")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "✕ Connect a model provider in Agents.")).count, 1,
                       "opening the choices does not repeat the shared fix")
        capture("applications-agent-help-open")

        tap(app.buttons["Notes"], in: app, "Notes")
        let notes = field(app, "Your notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        tap(notes, in: app, "the notes field")
        notes.typeText("Follow up with the recruiter on Friday")
        capture("applications-notes-keyboard")
        // With the keyboard up, Save notes is below it. Dismiss it by gesture, then bring Save into view.
        dismissKeyboard(app)
        capture("applications-notes-keyboard-dismissed")
        let save = app.buttons["Save notes"]
        tap(save, in: app, "Save notes")
        let failure = app.staticTexts["We couldn't save your notes. Check your connection and try again."]
        require(app, "the failed save explains itself", timeout: 8) { failure.exists }
        XCTAssertTrue(reveal(failure, in: app, "save-failure-message"), "the save error is visible on screen")
        capture("applications-notes-save-failed")

        XCTAssertTrue(reveal(field(app, "Your notes"), in: app, "notes-field"), "the notes field is reachable after the failure")
        XCTAssertTrue(text(field(app, "Your notes")).contains("Follow up"), "the note stays after the failed save")
        tap(save, in: app, "Save notes (retry)")
        let saved = app.staticTexts["Saved to your Stack."]
        require(app, "the retry confirms the save", timeout: 8) { saved.exists }
        XCTAssertTrue(reveal(saved, in: app, "saved-notice"), "the saved notice is visible on screen")
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
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        // The row starts under the home indicator, where a tap is swallowed; bring it clear first.
        tap(disclosure, in: app, "fit-and-tags-disclosure")
        require(app, "the Fit and tags disclosure expanded", timeout: 5) { (disclosure.value as? String) == "Expanded" }
        capture("jobs-detail-expanded")

        // The deck card behind the sheet carries the whole fit note in one combined label, so match the note by
        // its opening words, which only the disclosure's own text begins with.
        let fit = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Strong match: your SQL")).firstMatch
        require(app, "the full fit note is in the disclosure", timeout: 5) { fit.exists }
        XCTAssertTrue(fit.label.contains("project work covers"), "the note is complete, not clamped")
        let tag = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Remote friendly")).firstMatch
        XCTAssertTrue(reveal(tag, in: app, "remote-friendly-tag"), "tags beyond the card's first three are available")
        capture("jobs-detail-fit-and-tags")
    }

    /// Proves only the standalone fixture host: a bare card and the details sheet each present the listing stub
    /// and close back to where they were. It does not exercise `JobsView` (see `JobsDeckFlowUITests`) or the
    /// native Safari view, which this fixture replaces with a stub.
    func testStandaloneCardHostPresentsStubListingFromCardAndDetailsAndReturns() {
        let app = launch("jobs", extra: ["--stub-listing-browser"])
        let card = app.buttons["job-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let url = app.staticTexts["stub-browser-url"]
        require(app, "the card opens its listing in the browser", timeout: 5) { url.exists }
        XCTAssertEqual(url.label, "https://example.invalid/jobs/1")
        capture("jobs-listing-browser")
        app.buttons["Close listing"].tap()
        require(app, "closing returns to the same card", timeout: 5) { !url.exists && card.exists }

        // Reopen works, and the job's details and application link remain reachable from the same screen.
        card.tap()
        require(app, "the listing reopens", timeout: 5) { url.exists }
        app.buttons["Close listing"].tap()
        require(app, "the listing closed again", timeout: 5) { !url.exists }
        app.buttons["Open job details"].tap()
        let apply = app.buttons["Open application page"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        require(app, "the application page opens in the browser from details", timeout: 5) { url.exists }
        app.buttons["Close listing"].tap()
        require(app, "details are still showing after the browser closes", timeout: 5) { !url.exists && apply.exists }
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
        let openButton = app.buttons["Use my existing Stack account"]
        let usernameField = field(app, "Existing Stack username")
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))
        XCTAssertFalse(usernameField.exists, "recovery starts collapsed")
        capture("recovery-collapsed")
        openButton.tap()
        // The collapsed trigger and the form's submit share one label, so the fields are the real signal.
        require(app, "the recovery fields appeared", timeout: 5) { usernameField.exists }
        capture("recovery-open")
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        tap(cancel, in: app, "recovery-cancel")
        require(app, "the recovery fields disappeared after Cancel", timeout: 5) {
            !usernameField.exists && !field(app, "Existing Stack password").exists
        }
        XCTAssertTrue(openButton.waitForExistence(timeout: 5), "the collapsed trigger is back")
        capture("recovery-cancelled")
    }
}
