import XCTest

/// Drives the real `JobsView` (deck, search bar, details sheet, undo) against the offline `--screen-flow=deck`
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
        let entry = app.buttons["Entry-level software"]
        entry.tap()
        XCTAssertTrue(card(app, "job-entry").waitForExistence(timeout: 10), "the filter replaced the deck")
        XCTAssertTrue(entry.isSelected)

        card(app, "job-entry").tap()
        XCTAssertEqual(listingURL(app), "https://example.invalid/jobs/entry")
        closeListing(app)
        XCTAssertTrue(card(app, "job-entry").exists, "the filtered card is still on top")
        XCTAssertTrue(app.buttons["Entry-level software"].isSelected, "the filter is still active")
        capture("deck-filter-after-browser")

        app.buttons["Reset filters to profile"].tap()
        XCTAssertTrue(card(app, "job-alpha").waitForExistence(timeout: 10), "reset restored the profile deck")
        XCTAssertFalse(app.buttons["Entry-level software"].isSelected)
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
}
