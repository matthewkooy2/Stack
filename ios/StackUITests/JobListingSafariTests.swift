import XCTest

/// Drives the real `SFSafariViewController` opened from the real `JobsView`, against fictional pages served by
/// `scripts/ci/ios-listing-fixture-server.py` on loopback. No live job page, account or form is involved.
///
/// Start the server first (default port 18765, or `STACK_LISTING_FIXTURE_PORT`), then run this class.
/// The deck is the offline `--screen-flow=deck` fixture; `--listing-url-override=` points its first job at the
/// loopback page. Every step keeps a real screenshot attachment.
@MainActor
final class JobListingSafariUITests: XCTestCase {
    private var fixtureReady = false
    private var listingPath: String?
    private var port: String { ProcessInfo.processInfo.environment["STACK_LISTING_FIXTURE_PORT"] ?? "18765" }
    private var base: String { "http://127.0.0.1:" + port }
    private var requiredAcceptance: Bool {
        ProcessInfo.processInfo.environment["STACK_LISTING_REQUIRE_ACCEPTANCE"] == "1"
    }

    override func setUp() async throws {
        // Failed async helpers throw Swift errors so XCTest can finish their tasks before teardown.
        continueAfterFailure = true
        fixtureReady = false
        // The default scheme runs this suite too. Without the loopback fixture there is nothing to test against,
        // so skip (never pass): a skip is not native acceptance.
        let health: String
        do {
            health = try await control("/health")
        } catch {
            if requiredAcceptance { throw error }
            throw XCTSkip("Loopback listing fixture is not running at \(base): \(error)")
        }
        if requiredAcceptance, health != "ok" {
            throw NSError(domain: "ListingFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required listing fixture is unavailable at \(base)"])
        }
        try XCTSkipUnless(health == "ok", "Loopback listing fixture is not running at \(base). Start it with "
            + "`python3 scripts/ci/ios-listing-fixture-server.py --port \(port)` and rerun JobListingSafariUITests.")
        try await control("/control/fail?on=0")
        fixtureReady = true
    }

    override func tearDown() async throws {
        if fixtureReady {
            // A failed recovery assertion must not leave the next case's fixture in failure mode.
            try await control("/control/fail?on=0")
        }
        try await super.tearDown()
    }

    // MARK: Helpers

    @discardableResult
    private func control(_ path: String, timeout: TimeInterval = 15) async throws -> String {
        let url = URL(string: base + path)!
        var request = URLRequest(url: url)
        // The retained cold-network trace reached the healthy loopback server after 8.25s. This bounds
        // that startup, without retrying a failed request or converting its failure into an empty reply.
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = Date()
        // Suspend the async main-actor test, rather than blocking it with a semaphore or nested run loop.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NSError(domain: "ListingFixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid fixture reply for \(path): \(response)"])
        }
        print("FIXTURE control \(path): HTTP200 \(text), \(Date().timeIntervalSince(start))s")
        return text
    }

    private func launch(path: String) async throws -> XCUIApplication {
        listingPath = path
        let app = XCUIApplication()
        app.launchArguments = ["--screen-flow=deck", "--disable-draft-animations", "--long-undo-window",
                               "--listing-url-override=" + base + path]
        app.launch()
        let loaded = await poll(app.buttons["job-card-job-alpha"], "exists == true", until: Date().addingTimeInterval(15))
        _ = try XCTUnwrap(loaded ? app : nil, "the deck loads its first card")
        XCTAssertEqual(app.buttons.matching(identifier: "job-card-job-alpha").count, 1,
                       "the accessible card is unique")
        return app
    }

    private func capture(_ name: String) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name + "-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Any element, in the app or its Safari view, whose label contains the text. Label only: web headings and
    /// error text are exposed as labels, and matching arbitrary values was speculative. If the first native run
    /// shows the text only as a value, the attached accessibility dump will say so and this can widen.
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func expect(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20, file: StaticString = #filePath,
                        line: UInt = #line) async throws {
        // waitForExistence also captures a debug description after every miss; this polls the query alone.
        let found = element(app, containing: text)
        if !(await poll(found, "exists == true", until: Date().addingTimeInterval(timeout))) {
            await capture("missing-" + text.prefix(24))
            dump(app, "missing-" + text.prefix(24))
            _ = try XCTUnwrap(Optional<Bool>.none, "expected '\(text)' on screen", file: file, line: line)
        }
    }

    private func hits(_ path: String, timeout: TimeInterval = 15) async throws -> Int {
        let reply = try await control("/control/hits?path=" + path, timeout: timeout)
        guard let count = Int(reply) else {
            throw NSError(domain: "ListingFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid hit count: \(reply)"])
        }
        return count
    }

    private func openListing(_ app: XCUIApplication) async throws {
        let path = try XCTUnwrap(listingPath, "launch supplies the listing path")
        let before = try await hits(path)
        app.buttons["job-card-job-alpha"].tap()
        // Safari's new web process requested the page 16s after a tap in the retained trace (27s in an
        // earlier trace). Observe that real request first, then keep the original 20s rendering assertion.
        // This also proves that reopening makes a new request. The browser is opened only once.
        let deadline = Date().addingTimeInterval(30)
        var requested = false
        while Date() < deadline {
            if try await hits(path, timeout: max(0.1, min(15, deadline.timeIntervalSinceNow))) > before {
                requested = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        if !requested {
            dump(app, "listing-request-missing")
            await capture("listing-request-missing")
        }
        _ = try XCTUnwrap(requested ? true : nil, "the browser requested \(path) after its single opening tap")
    }

    private func closeBrowser(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) async throws {
        // The captured native tree places Close in TopBrowserBar. Background deck elements can remain in
        // that tree while Safari covers them, so neither a global first match nor card existence proves dismissal.
        let closeControls = app.otherElements["TopBrowserBar"].buttons
            .matching(NSPredicate(format: "label IN %@", ["Close", "Done"]))
        // A hit-point query took over15s in the failed10s wait. Poll only the scoped control count, which
        // proves uniqueness without finding a missing element or repeatedly mapping its hit point.
        let close = closeControls.firstMatch
        let unique = await poll(closeControls, "count == 1", until: Date().addingTimeInterval(10))
        if !unique || !close.isHittable {
            dump(app, "no-close")
            await capture("no-close")
            _ = try XCTUnwrap(Optional<Bool>.none, "the native browser has one hittable Close or Done control", file: file, line: line)
            return
        }
        let addresses = app.otherElements["TopBrowserBar"].buttons.matching(identifier: "URL")
        // Use this actual control's measured center. The Address AX frame overlaps it, so an inferred
        // hittable point can miss Close. Keep a single tap and the complete dismissal proof below.
        let frame = close.frame
        let normalizedX: CGFloat = 0.5
        let addressFrame = addresses.count == 1 ? String(describing: addresses.element.frame) : "absent"
        let geometry = XCTAttachment(string: "Close: \(frame); Address: \(addressFrame); normalized tap: \(normalizedX), 0.5")
        geometry.name = "native-close-hit-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        close.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.5)).tap()
        let cards = app.buttons.matching(identifier: "job-card-job-alpha")
        // The failed capture already showed the deck: two sequential remote waits spent the whole deadline
        // finding its card. Wait on that single readiness condition, then preserve both dismissal counts.
        let returned = await poll(cards.firstMatch, "isHittable == true", until: Date().addingTimeInterval(10))
        let dismissed = returned && closeControls.count == 0 && cards.count == 1
        if !dismissed {
            dump(app, "after-close")
            await capture("after-close")
            _ = try XCTUnwrap(Optional<Bool>.none, "closing the browser removes its native Close control and returns to one hittable deck card",
                             file: file, line: line)
        }
    }

    /// Polls a single readiness query, including a query's count, until its deadline.
    private func poll(_ object: Any, _ format: String, until deadline: Date) async -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: object)
        return await XCTWaiter.fulfillment(of: [expectation], timeout: max(0, deadline.timeIntervalSinceNow)) == .completed
    }

    private func tapLink(_ app: XCUIApplication, _ text: String) async throws {
        let link = app.links[text].exists ? app.links[text] : element(app, containing: text)
        let found = await poll(link, "exists == true", until: Date().addingTimeInterval(20))
        _ = try XCTUnwrap(found ? link : nil, "link '\(text)' is on the page")
        link.tap()
    }

    // MARK: Tests

    func testLongTitleListingRendersAndCloses() async throws {
        let app = try await launch(path: "/listing")
        try await openListing(app)
        try await expect(app, "Senior Principal Staff Machine Learning")
        await capture("safari-long-title-listing")
        dump(app, "safari-long-title-listing")
        try await closeBrowser(app)
        await capture("safari-closed-to-deck")
    }

    func testInternalLinkThenBackAndForward() async throws {
        let app = try await launch(path: "/listing")
        try await openListing(app)
        try await expect(app, "Senior Principal Staff")
        try await tapLink(app, "Read the internal detail page")
        try await expect(app, "Reached through an internal link")
        await capture("safari-internal-detail")

        let back = app.buttons["Back"]
        let backReady = await poll(back, "exists == true", until: Date().addingTimeInterval(10))
        XCTAssertTrue(backReady, "the browser offers Back")
        back.tap()
        try await expect(app, "Fictional listing for UI tests")
        await capture("safari-back-to-listing")

        let forward = app.buttons["Forward"]
        let forwardReady = await poll(forward, "exists == true", until: Date().addingTimeInterval(10))
        XCTAssertTrue(forwardReady, "the browser offers Forward")
        forward.tap()
        try await expect(app, "Reached through an internal link")
        await capture("safari-forward-to-detail")
        try await closeBrowser(app)
    }

    func testRedirectLandsOnDestination() async throws {
        let app = try await launch(path: "/listing")
        try await openListing(app)
        try await expect(app, "Senior Principal Staff")
        try await tapLink(app, "Follow the redirect")
        try await expect(app, "You arrived through a 302 redirect")
        await capture("safari-redirect-destination")
        try await closeBrowser(app)
    }

    func testTargetBlankLinkStaysInsideTheBrowser() async throws {
        let app = try await launch(path: "/listing")
        try await openListing(app)
        try await expect(app, "Senior Principal Staff")
        try await tapLink(app, "Open the new tab page")
        try await expect(app, "Opened by a target=_blank link")
        await capture("safari-target-blank")
        XCTAssertEqual(app.state, .runningForeground, "the link did not leave Stack")
        try await closeBrowser(app)
    }

    func testCloseThenReopenShowsTheListingAgain() async throws {
        let app = try await launch(path: "/listing")
        try await openListing(app)
        try await expect(app, "Senior Principal Staff")
        try await closeBrowser(app)
        try await openListing(app)
        try await expect(app, "Senior Principal Staff")
        await capture("safari-reopened")
        try await closeBrowser(app)
        XCTAssertTrue(app.buttons["Save"].isHittable, "Save and Pass are reachable after reopening")
    }

    /// Supply a distinctive error label actually observed on this OS and locale. Safari renders it out of
    /// process; guessing its text would make a native acceptance claim depend on unobserved system UI.
    func testFailedConnectionThenReloadRecovers() async throws {
        let errorText = (ProcessInfo.processInfo.environment["STACK_LISTING_ERROR_TEXT"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipIf(errorText.isEmpty && !requiredAcceptance, "Observe Safari's connection-error label on the target OS/locale, then rerun "
            + "with STACK_LISTING_ERROR_TEXT. Missing calibration is not failure/retry acceptance.")
        try await control("/control/fail?on=1")
        let app = try await launch(path: "/flaky")
        try await openListing(app)

        // The browser must have actually reached the fixture, otherwise an empty screen would look like an error.
        var hits = 0
        for _ in 0..<40 where hits == 0 {
            let reply = try await control("/control/hits?path=/flaky")
            guard let count = Int(reply) else {
                throw NSError(domain: "ListingFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid hit count: \(reply)"])
            }
            hits = count
            if hits == 0 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        XCTAssertGreaterThan(hits, 0, "the browser requested /flaky from the fixture")

        if errorText.isEmpty {
            // A hosted calibration run records the actual system UI and fails rather than accepting a skip.
            let reload = app.buttons.matching(NSPredicate(format: "label IN %@", ["Reload", "Reload Page"])).firstMatch
            _ = await poll(reload, "exists == true", until: Date().addingTimeInterval(20))
            await capture("safari-error-calibration")
            dump(app, "safari-error-calibration")
            XCTFail("Supply the connection-error label observed in these attachments via STACK_LISTING_ERROR_TEXT, then rerun.")
            return
        }

        let error = element(app, containing: errorText)
        let shown = await poll(error, "exists == true", until: Date().addingTimeInterval(20))
        await capture("safari-failed-connection")
        dump(app, "safari-failed-connection")
        XCTAssertTrue(shown, "Safari shows the observed connection-error label '\(errorText)' "
            + "(see the attached accessibility tree if the OS or locale changed)")
        XCTAssertFalse(element(app, containing: "The connection works again").exists,
                       "the recovered page did not load while the server dropped the connection")

        try await control("/control/fail?on=0")
        let reload = app.buttons.matching(NSPredicate(format: "label IN %@", ["Reload", "Reload Page"])).firstMatch
        let reloadReady = await poll(reload, "exists == true", until: Date().addingTimeInterval(10))
        XCTAssertTrue(reloadReady, "the browser offers Reload")
        reload.tap()
        try await expect(app, "The connection works again")
        XCTAssertFalse(error.exists, "the error page is gone after recovery")
        await capture("safari-recovered-after-reload")
        try await closeBrowser(app)
    }

    func testOpenInSafariHandsOffToTheSystemBrowser() async throws {
        let app = try await launch(path: "/listing")
        try await openListing(app)
        try await expect(app, "Senior Principal Staff")
        let handoff = app.buttons["Open in Safari"]
        let handoffReady = await poll(handoff, "exists == true", until: Date().addingTimeInterval(10))
        XCTAssertTrue(handoffReady, "the browser offers Open in Safari")
        handoff.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Safari came to the foreground")
        await capture("safari-handoff-system-browser")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
