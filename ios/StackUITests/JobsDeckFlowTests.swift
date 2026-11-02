import XCTest

/// Drives the real `JobsView` (deck, requirements sheet, details sheet, undo) against the offline `--screen-flow=deck`
/// fixture: a fictional account answered by a stub URLProtocol, no sign-in or network. The listing browser is
/// replaced here by a deterministic in-app stub (`--stub-listing-browser`), so these tests cover Stack's own
/// presentation, state and dismissal wiring. The real `SFSafariViewController` is driven against loopback
/// fixture pages in `JobListingSafariUITests`.
@MainActor
final class JobsDeckFlowUITests: XCTestCase {
    private func launch(flow: String = "deck") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--screen-flow=" + flow, "--disable-draft-animations", "--stub-listing-browser",
                               "--long-undo-window"]
        app.launch()
        XCTAssertTrue(app.buttons["job-card-job-alpha"].waitForExistence(timeout: 10), "the deck loads its first card")
        XCTAssertEqual(app.buttons.matching(identifier: "job-card-job-alpha").count, 1,
                       "decorative swipe stamps must not create a second accessible card")
        return app
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func card(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.buttons["job-card-" + id] }

    private func closeListing(_ app: XCUIApplication) {
        let close = app.buttons["Close listing"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the browser has a close control")
        close.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                 object: app.staticTexts["stub-browser-url"])
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed, "the browser closed")
    }

    private func listingURL(_ app: XCUIApplication) -> String {
        let url = app.staticTexts["stub-browser-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5), "the listing browser opened")
        return url.label
    }

    func testCardsOpenTheirOwnListingInDeckOrderAndInvalidLinkFallsBackToDetails() {
        let app = launch()
        card(app, "job-alpha").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/alpha")
        capture("deck-listing-alpha")
        closeListing(app)
        XCTAssertTrue(card(app, "job-alpha").exists, "the same card is still on top after closing")

        // Reopening the same card works.
        card(app, "job-alpha").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/alpha")
        closeListing(app)

        app.buttons["Pass"].tap()
        XCTAssertTrue(card(app, "job-bravo").waitForExistence(timeout: 5), "the deck advanced in order")
        card(app, "job-bravo").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/bravo")
        closeListing(app)

        // The third job's link is not http(s): the tap opens its details with a note, never a browser.
        app.buttons["Pass"].tap()
        XCTAssertTrue(card(app, "job-charlie").waitForExistence(timeout: 5))
        card(app, "job-charlie").tap()
        let note = app.staticTexts["This listing's link can't be opened safely in the app."]
        XCTAssertTrue(note.waitForExistence(timeout: 10), "the details explain why there is no browser")
        XCTAssertFalse(app.staticTexts["stub-browser-url"].exists)
        XCTAssertFalse(app.buttons["Open application page"].exists)
        capture("deck-invalid-link-details")
        app.buttons["Close"].tap()
        XCTAssertTrue(card(app, "job-charlie").waitForExistence(timeout: 5), "closing details keeps the card")
    }

    func testPendingUndoSurvivesOpeningAndClosingTheBrowser() {
        let app = launch()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Saved Platform Analyst"].waitForExistence(timeout: 5))
        XCTAssertTrue(card(app, "job-bravo").waitForExistence(timeout: 5), "the next card is on top")

        card(app, "job-bravo").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/bravo")
        closeListing(app)

        // Presenting the browser must not force an early commit. The real Undo timer (2.4s) keeps running while
        // browsing; this test's 60s window (--long-undo-window) only keeps a slow runner from expiring it, so it
        // does not show Undo surviving an arbitrarily long browse.
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Undo is still offered after the browser closed")
        capture("deck-undo-after-browser")
        undo.tap()
        XCTAssertTrue(card(app, "job-alpha").waitForExistence(timeout: 5), "the saved card came back")
        XCTAssertFalse(app.buttons["Undo"].exists)
    }

    func testFilterAndDeckSurviveTheBrowserAndResetRestoresIt() {
        let app = launch()
        app.buttons["job-requirements"].tap()
        let entry = app.buttons["Entry-level software"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(card(app, "job-entry").waitForExistence(timeout: 10), "the filter replaced the deck")
        XCTAssertFalse(app.staticTexts["Requirements"].exists, "saving a quick pick closes requirements")

        card(app, "job-entry").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/entry")
        closeListing(app)
        XCTAssertTrue(card(app, "job-entry").exists, "the filtered card is still on top")
        app.buttons["job-requirements"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.isSelected, "the filter is still active")
        capture("deck-filter-after-browser")

        app.buttons["Reset filters to profile"].tap()
        XCTAssertTrue(card(app, "job-alpha").waitForExistence(timeout: 10), "reset restored the profile deck")
        app.buttons["job-requirements"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(entry.isSelected)
    }

    func testDetailsButtonKeepsDetailsAndActionsReachableAroundTheBrowser() {
        let app = launch()
        app.buttons["Job details"].tap()
        let apply = app.buttons["Open application page"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/alpha")
        closeListing(app)
        XCTAssertTrue(apply.exists, "details are still showing after the browser closes")
        app.buttons["Close"].tap()
        XCTAssertTrue(card(app, "job-alpha").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].isHittable, "Save and Pass are reachable again")
        app.buttons["Save"].tap()
        XCTAssertTrue(card(app, "job-bravo").waitForExistence(timeout: 5))
    }

    /// The second page is answered 3s after the first card is on screen, so the browser is open when it is due.
    /// This proves eventual continuation: after the browser closes the deck still receives the page without any
    /// user action. It cannot tell a page that landed while covered from one fetched on dismissal; observing
    /// that would need production internals and is deliberately not attempted.
    func testPagingEventuallyContinuesAfterTheBrowserCloses() {
        let app = launch(flow: "deck-paging")
        card(app, "job-alpha").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/alpha")
        Thread.sleep(forTimeInterval: 5)
        closeListing(app)
        XCTAssertTrue(card(app, "job-alpha").exists)
        capture("deck-paging-after-browser")
        app.buttons["Pass"].tap()
        XCTAssertTrue(card(app, "job-bravo").waitForExistence(timeout: 15), "the deferred page filled the deck")
    }

    func testHorizontalSwipesDecideButShortAndVerticalDragsDoNotOpenTheBrowser() {
        let app = launch()
        let first = card(app, "job-alpha")
        let middle = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        middle.press(forDuration: 0.05, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.64, dy: 0.45)))
        XCTAssertTrue(first.exists, "a short horizontal drag keeps the card")
        XCTAssertFalse(app.staticTexts["stub-browser-url"].exists, "ending a drag is not a tap")
        middle.press(forDuration: 0.05, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(first.exists, "vertical content scrolling cannot decide a job")
        XCTAssertFalse(app.staticTexts["stub-browser-url"].exists)

        first.swipeRight()
        XCTAssertTrue(card(app, "job-bravo").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved Platform Analyst"].exists)
        app.buttons["Undo"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.swipeLeft()
        XCTAssertTrue(card(app, "job-bravo").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Passed Platform Analyst"].exists)
        XCTAssertFalse(app.staticTexts["stub-browser-url"].exists)
    }

    func testRequirementsAreInsideTheCardAndOpeningThemDoesNotOpenAListing() {
        let app = launch()
        XCTAssertFalse(app.staticTexts["Jobs"].exists, "there is no Jobs heading above the card")
        XCTAssertFalse(app.buttons["Entry-level software"].exists, "quick picks live behind the card control")
        let requirements = app.buttons["job-requirements"]
        XCTAssertTrue(requirements.isHittable)
        requirements.tap()
        XCTAssertTrue(app.staticTexts["Requirements"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["stub-browser-url"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(card(app, "job-alpha").waitForExistence(timeout: 5))
        capture("deck-minimal-card")
    }

}
