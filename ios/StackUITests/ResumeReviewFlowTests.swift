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
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: from))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: to))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Scrolls until the element can be tapped, down the page first and then back up.
    @discardableResult
    private func show(_ target: XCUIElement, _ app: XCUIApplication, _ what: String,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if target.exists, target.isHittable { return true }
        for forward in [true, false] {
            for _ in 0..<8 {
                if forward { drag(app, from: 0.7, to: 0.3) } else { drag(app, from: 0.3, to: 0.7) }
                if target.exists, target.isHittable { return true }
            }
        }
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
        show(row, app, "the \(key) row")
        row.tap()
        XCTAssertTrue(element(app, id: "resume-review-all-sections").waitForExistence(timeout: 5), "the \(key) section opened")
    }

    private func backToSections(_ app: XCUIApplication) {
        let back = element(app, id: "resume-review-all-sections")
        show(back, app, "All sections")
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

    func testCorrectedValueShowsOriginalAndCanBeRestored() {
        let app = launch()
        openSection(app, "profile")
        type(app, "Contact Name", " Jr")
        let original = element(app, id: "resume-original-Contact Name")
        XCTAssertTrue(original.waitForExistence(timeout: 5), "the original value is shown next to the correction")
        XCTAssertTrue(original.label.contains("Ada Example"))
        capture("resume-review-original-and-corrected")
        let restore = app.buttons["Restore original Contact Name"]
        show(restore, app, "Restore original")
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
        show(addProject, app, "Add project")
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
}
