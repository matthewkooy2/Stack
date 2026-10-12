import XCTest

/// Drives the real resume review sheet in the offline `--screen-flow=resume-review` fixture: a fictional
/// account and a synthetic resume answered by a stub URLProtocol. No sign-in, token, network or live data.
///
/// Launch arguments the fixture reads (see `ScreenFlowServer.reset`):
/// `--reset-resume-drafts` clears the on-device drafts, `--resume-review-user=<id>` picks the account,
/// `--resume-review-revision=<n>` and `--resume-review-remote-name=<text>` simulate a newer server version,
/// `--resume-review-empty` serves a resume with no extracted fields.
@MainActor
final class ResumeReviewFlowUITests: XCTestCase {
    private func launch(_ extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        var arguments = ["--screen-flow=resume-review", "--disable-draft-animations"]
        if reset { arguments.append("--reset-resume-drafts") }
        app.launchArguments = arguments + extra
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func field(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let kinds = [XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue]
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)", label, kinds[0], kinds[1])).firstMatch
    }

    private func text(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    private func state(_ app: XCUIApplication) -> String {
        text(element(app, id: "resume-review-state"))
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Drags along the page's left margin, clear of text fields, so the page scrolls instead of a field.
    /// The drag starts above an open keyboard: one that starts on a key edits the focused field instead.
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let window = app.windows.firstMatch
        var from = from
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.height > 0, window.frame.height > 0 {
            from = min(from, (keyboard.frame.minY - window.frame.minY - 24) / window.frame.height)
        }
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: from))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// A partially clipped control may be hittable without its default tap point being visible.
    private func navigationViewport(_ target: XCUIElement, _ app: XCUIApplication) -> CGRect {
        var viewport = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 44)
        guard target.exists else { return viewport.insetBy(dx: 8, dy: 8) }
        let identifier = target.identifier
        let owners = identifier.isEmpty ? [] : app.scrollViews.allElementsBoundByIndex.filter {
            $0.descendants(matching: .button).matching(identifier: identifier).count > 0
        }
        if let owner = owners.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            viewport = viewport.intersection(owner.frame)
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.height > 0, keyboard.frame.minY < viewport.maxY {
            viewport.size.height = max(0, keyboard.frame.minY - viewport.minY)
        }
        return viewport.insetBy(dx: 8, dy: 8)
    }

    private func fullyVisible(_ target: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard target.exists, target.isHittable, !target.frame.isEmpty else { return false }
        return navigationViewport(target, app).contains(target.frame)
    }

    /// Hittable alone accepts a control clipped under the home indicator, where its tap reaches nothing.
    private func tappable(_ target: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard target.exists, target.isHittable, !target.frame.isEmpty else { return false }
        return navigationViewport(target, app).contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
    }

    private func captureNavigation(_ target: XCUIElement, _ app: XCUIApplication, _ name: String) {
        let exists = target.exists
        let frame = exists ? target.frame : .zero
        let identifier = exists ? target.identifier : "missing-target"
        let geometry = XCTAttachment(string: "identifier=\(identifier); target=\(frame); viewport=\(navigationViewport(target, app)); window=\(app.windows.firstMatch.frame); exists=\(exists); hittable=\(exists && target.isHittable)")
        geometry.name = "resume-navigation-\(name)-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "resume-navigation-\(name)-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "resume-navigation-\(name)-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Scrolls until the element's tap point is inside the measured viewport, down the page first and then back up.
    @discardableResult
    private func show(_ target: XCUIElement, _ app: XCUIApplication, _ what: String,
                      fully: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if fully ? fullyVisible(target, app) : tappable(target, app) { return true }
        for forward in [true, false] {
            for _ in 0..<8 {
                if forward { drag(app, from: 0.7, to: 0.3) } else { drag(app, from: 0.3, to: 0.7) }
                if fully ? fullyVisible(target, app) : tappable(target, app) { return true }
            }
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "resume-review-unreachable-element-tree"
        tree.lifetime = .keepAlways
        add(tree)
        capture("resume-review-unreachable-element")
        XCTFail("\(what) can be scrolled into view", file: file, line: line)
        return false
    }

    private func type(_ app: XCUIApplication, _ label: String, _ text: String, replace: Bool = false) {
        let target = field(app, label)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(label) exists")
        guard show(target, app, label) else { return }
        target.tap()
        if replace, let current = target.value as? String, !current.isEmpty {
            target.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        target.typeText(text)
    }

    private func openSection(_ app: XCUIApplication, _ key: String) {
        let row = element(app, id: "resume-review-section-\(key)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(key) section row exists")
        guard show(row, app, "the \(key) row", fully: true) else { return }
        XCTAssertEqual(app.buttons.matching(identifier: "resume-review-section-\(key)").count, 1)
        captureNavigation(row, app, "\(key)-before-tap")
        XCTAssertTrue(fullyVisible(row, app), "the full section control is inside the measured viewport before tapping")
        row.tap()
        let opened = element(app, id: "resume-review-all-sections").waitForExistence(timeout: 5)
        if !opened { captureNavigation(row, app, "\(key)-failed-to-open") }
        XCTAssertTrue(opened, "the \(key) section opened")
    }

    private func backToSections(_ app: XCUIApplication) {
        let back = element(app, id: "resume-review-all-sections")
        guard show(back, app, "All sections", fully: true) else { return }
        back.tap()
        XCTAssertTrue(element(app, id: "resume-review-section-profile").waitForExistence(timeout: 5))
    }

    private func closeSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        show(close, app, "Close")
        close.tap()
        XCTAssertTrue(app.buttons["Open resume review"].waitForExistence(timeout: 5), "the sheet closed")
    }

    private func reopen(_ app: XCUIApplication) {
        app.buttons["Open resume review"].tap()
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10), "the review reopened")
    }

    // MARK: Tests

    func testEveryFieldIsReachableThroughFocusedSections() {
        let app = launch()
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "needs-review")
        for key in ["profile", "educations", "workExperiences", "projects", "skills", "additional"] {
            XCTAssertTrue(element(app, id: "resume-review-section-\(key)").exists, "\(key) is a section")
        }
        capture("resume-review-sections")

        let expected: [(section: String, labels: [String])] = [
            ("profile", ["Contact Name", "Contact Email", "Contact Phone", "Contact Location", "Contact Link", "Contact Summary",
                         "Contact Headline"]),
            ("educations", ["Education 1 School", "Education 1 Degree", "Education 1 Date", "Education 1 GPA",
                            "Education 1 Location", "Education 1 Details item 1", "Education 2 School"]),
            ("workExperiences", ["Experience 1 Job title", "Experience 1 Company", "Experience 1 Date", "Experience 1 Location",
                                 "Experience 1 Details item 1", "Experience 1 Details item 3"]),
            ("projects", ["Project 1 Project", "Project 1 Date", "Project 1 Details item 1"]),
            ("skills", ["Skills Skills item 1", "Skills Skills item 3"]),
            ("additional", ["Additional details Other details item 1"]),
        ]
        for (section, labels) in expected {
            openSection(app, section)
            for label in labels {
                XCTAssertTrue(field(app, label).waitForExistence(timeout: 5), "\(label) is an editable field")
            }
            capture("resume-review-\(section)")
            backToSections(app)
        }
    }

    func testCorrectedValueShowsLastSavedAndCanBeUndone() {
        let app = launch()
        openSection(app, "profile")
        type(app, "Contact Name", " Jr")
        let saved = element(app, id: "resume-saved-Contact Name")
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "the last saved value is shown next to the correction")
        XCTAssertTrue(saved.label.contains("Ada Example"))
        capture("resume-review-saved-and-corrected")
        let restore = app.buttons["Undo change Contact Name"]
        show(restore, app, "Undo change")
        restore.tap()
        XCTAssertTrue(waitUntil { self.text(self.field(app, "Contact Name")) == "Ada Example" })
        backToSections(app)
        XCTAssertTrue(waitUntil { self.state(app) == "needs-review" }, "restoring every correction leaves nothing unsaved")
    }

    func testEntriesBulletsAndOrderSurviveClosingAndReopening() {
        let app = launch()
        openSection(app, "educations")
        XCTAssertEqual(text(field(app, "Education 1 School")), "Example State University")
        let actions = app.buttons["Actions for Education 1"]
        show(actions, app, "Education 1 actions")
        actions.tap()
        app.buttons["Move down"].tap()
        XCTAssertTrue(waitUntil { self.text(self.field(app, "Education 1 School")) == "Lakeside Community College" },
                      "moving an entry reorders it")
        XCTAssertEqual(text(field(app, "Education 2 School")), "Example State University")
        capture("resume-review-entry-moved")
        backToSections(app)

        openSection(app, "workExperiences")
        let add = app.buttons["Add item to Experience 1 Details"]
        show(add, app, "Add item")
        add.tap()
        type(app, "Experience 1 Details item 4", "Reduced reporting time by half")
        capture("resume-review-bullet-added")
        backToSections(app)

        openSection(app, "projects")
        let addProject = app.buttons["Add project"]
        show(addProject, app, "Add project", fully: true)
        addProject.tap()
        XCTAssertTrue(field(app, "Project 2 Project").waitForExistence(timeout: 5))
        type(app, "Project 2 Project", "Forecast model")
        backToSections(app)
        XCTAssertEqual(state(app), "unsaved")

        closeSheet(app)
        Thread.sleep(forTimeInterval: 0.5)
        reopen(app)
        XCTAssertEqual(state(app), "unsaved", "edits are still there after closing and reopening")
        XCTAssertTrue(element(app, id: "resume-review-restored").exists)
        openSection(app, "educations")
        XCTAssertEqual(text(field(app, "Education 1 School")), "Lakeside Community College")
        backToSections(app)
        openSection(app, "workExperiences")
        XCTAssertEqual(text(field(app, "Experience 1 Details item 4")), "Reduced reporting time by half")
        backToSections(app)
        openSection(app, "projects")
        XCTAssertEqual(text(field(app, "Project 2 Project")), "Forecast model")
        capture("resume-review-restored")
    }

    func testRemovingAnEntryAsksFirstAndKeepsTheOthers() {
        let app = launch()
        openSection(app, "educations")
        let actions = app.buttons["Actions for Education 2"]
        show(actions, app, "Education 2 actions")
        actions.tap()
        app.buttons["Remove entry"].tap()
        XCTAssertTrue(app.buttons["Remove Education 2"].waitForExistence(timeout: 5), "removal asks for confirmation")
        XCTAssertTrue(field(app, "Education 2 School").exists, "nothing is removed before confirming")
        capture("resume-review-remove-confirmation")
        app.buttons["Remove Education 2"].tap()
        XCTAssertTrue(waitUntil { !self.field(app, "Education 2 School").exists })
        XCTAssertEqual(text(field(app, "Education 1 School")), "Example State University")
    }

    func testDraftSurvivesRestartAndIsNotShownToAnotherAccount() {
        var app = launch()
        openSection(app, "profile")
        type(app, "Contact Name", " Restart")
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "unsaved", "the draft survives the app ending")
        openSection(app, "profile")
        XCTAssertEqual(text(field(app, "Contact Name")), "Ada Example Restart")
        app.terminate()

        app = launch(["--resume-review-user=fixture-other-user"], reset: false)
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "needs-review", "another account does not see this draft")
        XCTAssertFalse(element(app, id: "resume-review-restored").exists)
        openSection(app, "profile")
        XCTAssertEqual(text(field(app, "Contact Name")), "Ada Example")
        capture("resume-review-other-account")
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "unsaved", "the first account finds its draft again")
    }

    func testUnavailableStructuredParseShowsRawRecordsAndItsReason() {
        let app = launch(["--resume-review-unavailable"])
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        let record = field(app, "Record r0")
        show(record, app, "Accepted raw record")
        XCTAssertEqual(text(record), "Accepted raw fallback")
        XCTAssertFalse(element(app, id: "resume-review-section-profile").exists)
        XCTAssertTrue(app.staticTexts["Structured review unavailable for rotated PDF"].exists)
        capture("resume-review-unavailable-raw-fallback")
    }

    func testConfirmedRawRecordsStillRequireConfirmingParsedDetails() {
        var app = launch(["--resume-review-unconfirmed-details"])
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "needs-review")
        let confirm = element(app, id: "resume-review-confirm")
        show(confirm, app, "Confirm newly parsed details")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(waitUntil { self.state(app) == "confirmed" })
        capture("resume-review-legacy-details-confirmed")
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "confirmed", "the structured confirmation was saved to the server")
    }

    func testSaveThenConfirmClearsTheDraft() {
        var app = launch()
        openSection(app, "profile")
        type(app, "Contact Name", " Saved")
        backToSections(app)
        let save = element(app, id: "resume-review-save")
        show(save, app, "Save draft")
        save.tap()
        XCTAssertTrue(waitUntil { self.text(self.element(app, id: "resume-review-message")) == "Draft saved." || self.element(app, id: "resume-review-message").label == "Draft saved." })
        XCTAssertEqual(state(app), "needs-review")
        let confirm = element(app, id: "resume-review-confirm")
        show(confirm, app, "Confirm")
        confirm.tap()
        XCTAssertTrue(waitUntil { self.state(app) == "confirmed" })
        capture("resume-review-confirmed")
        app.terminate()

        app = launch(reset: false)
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "confirmed", "a saved review leaves no stale draft behind")
        XCTAssertFalse(element(app, id: "resume-review-restored").exists)
        openSection(app, "profile")
        XCTAssertEqual(text(field(app, "Contact Name")), "Ada Example Saved", "the fixture preserves server values too")
    }

    func testNewerServerVersionKeepsEditsUntilExplicitDiscard() {
        var app = launch()
        openSection(app, "profile")
        type(app, "Contact Name", " Mine")
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        app = launch(["--resume-review-revision=2", "--resume-review-remote-name=Ada Remote"], reset: false)
        XCTAssertTrue(element(app, id: "resume-review-conflict").waitForExistence(timeout: 10))
        XCTAssertEqual(state(app), "conflict")
        XCTAssertFalse(app.buttons["Save draft"].isEnabled, "edits cannot be saved over a newer version")
        capture("resume-review-conflict")
        openSection(app, "profile")
        XCTAssertEqual(text(field(app, "Contact Name")), "Ada Example Mine", "the edit is still shown")
        backToSections(app)

        let discard = element(app, id: "resume-review-discard")
        show(discard, app, "Discard my edits and reload")
        XCTAssertEqual(app.buttons.matching(identifier: "resume-review-discard").count, 1, "the conflict container keeps its child's identifier")
        discard.tap()
        XCTAssertTrue(waitUntil { self.state(app) == "needs-review" })
        openSection(app, "profile")
        XCTAssertEqual(text(field(app, "Contact Name")), "Ada Remote")
    }

    func testEmptyResumeCanBeFilledFromAddedEntries() {
        let app = launch(["--resume-review-empty"])
        XCTAssertTrue(element(app, id: "resume-review-state").waitForExistence(timeout: 10))
        capture("resume-review-empty")
        openSection(app, "educations")
        let add = app.buttons["Add education"]
        show(add, app, "Add education")
        add.tap()
        XCTAssertTrue(field(app, "Education 1 School").waitForExistence(timeout: 5))
        type(app, "Education 1 School", "Example State University")
        backToSections(app)
        let save = element(app, id: "resume-review-save")
        show(save, app, "Save draft")
        save.tap()
        XCTAssertTrue(waitUntil { self.state(app) == "needs-review" })
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Education, 1 entry")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved entry appears in the section list")
    }

    func testFirstBlankBulletSurvivesDismissalThenCanBeSavedAndReloaded() {
        var app = launch(["--resume-review-empty"])
        openSection(app, "skills")
        let add = app.buttons["Add item to Skills Skills"]
        show(add, app, "Add first skill")
        add.tap()
        XCTAssertTrue(field(app, "Skills Skills item 1").waitForExistence(timeout: 5))
        closeSheet(app)
        reopen(app)
        openSection(app, "skills")
        XCTAssertTrue(field(app, "Skills Skills item 1").waitForExistence(timeout: 5), "the blank row survives")
        type(app, "Skills Skills item 1", "SQL")
        backToSections(app)
        let save = element(app, id: "resume-review-save")
        show(save, app, "Save skill")
        save.tap()
        XCTAssertTrue(waitUntil { self.state(app) == "needs-review" })
        app.terminate()
        app = launch(reset: false)
        openSection(app, "skills")
        XCTAssertEqual(text(field(app, "Skills Skills item 1")), "SQL")
    }

    func testOriginalExtractionKeepsOriginalOrderAfterSavedReorderAndRestart() {
        var app = launch()
        openSection(app, "educations")
        let actions = app.buttons["Actions for Education 1"]
        show(actions, app, "Move education")
        actions.tap()
        app.buttons["Move down"].tap()
        backToSections(app)
        let save = element(app, id: "resume-review-save")
        show(save, app, "Save order")
        save.tap()
        XCTAssertTrue(waitUntil { self.state(app) == "needs-review" })
        app.terminate()
        app = launch(reset: false)
        openSection(app, "educations")
        XCTAssertEqual(text(field(app, "Education 1 School")), "Lakeside Community College")
        backToSections(app)
        openSection(app, "original")
        let original = element(app, id: "resume-original-field-educations.0.school")
        show(original, app, "Original education")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "resume-original-field-educations.0.school").count, 1,
                       "the original group keeps its field's identifier")
        XCTAssertTrue(original.label.contains("Example State University"))
        XCTAssertFalse(original.label.contains("Lakeside Community College"))
        XCTAssertTrue(app.staticTexts["Check the extracted dates."].exists)
        capture("resume-original-order-after-saved-reorder")
    }

    func testImportRetryFinishesWithoutDiscardingAnAddedBlankRow() {
        let app = launch(["--resume-review-processing=failed"])
        XCTAssertTrue(app.staticTexts["Processing failed"].waitForExistence(timeout: 10))
        openSection(app, "skills")
        let add = app.buttons["Add item to Skills Skills"]
        show(add, app, "Add skill row")
        add.tap()
        XCTAssertTrue(field(app, "Skills Skills item 4").waitForExistence(timeout: 5))
        let retry = app.buttons["Retry processing"]
        show(retry, app, "Retry import")
        retry.tap()
        XCTAssertTrue(app.staticTexts["Resume ready to review"].waitForExistence(timeout: 15), "account ticket changes drive polling after retry")
        XCTAssertTrue(field(app, "Skills Skills item 4").exists, "the completion read keeps the blank row")
        capture("resume-import-retry-keeps-blank-row")
    }

    func testFreshProcessingReadWinsOverStaleAccountTicket() {
        let app = launch(["--resume-review-processing=completed", "--resume-review-account-processing=failed"])
        XCTAssertTrue(app.staticTexts["Resume ready to review"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Retry processing"].exists, "the stale account snapshot must not override the fresher read")
    }
}
