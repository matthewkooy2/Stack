import XCTest

/// Drives the real `SFSafariViewController` opened from the real `JobsView`, against fictional pages served by
/// `scripts/ci/ios-listing-fixture-server.py` on loopback. No live job page, account or form is involved.
///
/// Start the server first (default port 18765, or `STACK_LISTING_FIXTURE_PORT`), then run this class.
/// The deck is the offline `--screen-flow=deck` fixture; `--listing-url-override=` points its first job at the
/// loopback page. Every step keeps a real screenshot attachment.
@MainActor
final class JobListingSafariUITests: XCTestCase {
    private var port: String { ProcessInfo.processInfo.environment["STACK_LISTING_FIXTURE_PORT"] ?? "18765" }
    private var base: String { "http://127.0.0.1:" + port }
    private var requiredAcceptance: Bool {
        ProcessInfo.processInfo.environment["STACK_LISTING_REQUIRE_ACCEPTANCE"] == "1"
    }

    override func setUp() async throws {
        continueAfterFailure = false
        // The default scheme runs this suite too. Without the loopback fixture there is nothing to test against,
        // so skip (never pass): a skip is not native acceptance.
        let health = control("/health")
        if requiredAcceptance, health != "ok" {
            throw NSError(domain: "ListingFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required listing fixture is unavailable at \(base)"])
        }
        try XCTSkipUnless(health == "ok", "Loopback listing fixture is not running at \(base). Start it with "
            + "`python3 scripts/ci/ios-listing-fixture-server.py --port \(port)` and rerun JobListingSafariUITests.")
        _ = control("/control/fail?on=0")
    }

    // MARK: Helpers

    @discardableResult
    private func control(_ path: String) -> String {
        guard let url = URL(string: base + path) else { return "" }
        var result = ""
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            result = String(data: data ?? Data(), encoding: .utf8) ?? ""
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    private func launch(path: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--screen-flow=deck", "--disable-draft-animations", "--long-undo-window",
                               "--listing-url-override=" + base + path]
        app.launch()
        XCTAssertTrue(app.buttons["job-card-job-alpha"].waitForExistence(timeout: 15), "the deck loads its first card")
        XCTAssertEqual(app.buttons.matching(identifier: "job-card-job-alpha").count, 1,
                       "the accessible card is unique")
        return app
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
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
                        line: UInt = #line) {
        let found = element(app, containing: text)
        if !found.waitForExistence(timeout: timeout) {
            capture("missing-" + text.prefix(24))
            dump(app, "missing-" + text.prefix(24))
            XCTFail("expected '\(text)' on screen", file: file, line: line)
        }
    }

    private func openListing(_ app: XCUIApplication) {
        app.buttons["job-card-job-alpha"].tap()
    }

    private func closeBrowser(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // The captured native tree places Close in TopBrowserBar. Background deck elements can remain in
        // that tree while Safari covers them, so neither a global first match nor card existence proves dismissal.
        let closeControls = app.otherElements["TopBrowserBar"].buttons
            .matching(NSPredicate(format: "label IN %@", ["Close", "Done"]))
        let closeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            closeControls.count == 1 && closeControls.element.isHittable
        }, object: app)
        if XCTWaiter.wait(for: [closeReady], timeout: 10) != .completed {
            dump(app, "no-close")
            capture("no-close")
            XCTFail("the native browser has one hittable Close or Done control", file: file, line: line)
            return
        }
        let close = closeControls.element
        let addresses = app.otherElements["TopBrowserBar"].buttons.matching(identifier: "URL")
        // The actual native AX trees expose Address over most of Close's frame on both SDKs. A default
        // center tap can reach Address while reporting Close as hittable. Use the visible left strip of
        // this same unique Close control, derived from those current frames, and retain dismissal proof.
        let frame = close.frame
        var normalizedX: CGFloat = 0.5
        if addresses.count == 1, frame.intersects(addresses.element.frame) {
            let clearWidth = addresses.element.frame.minX - frame.minX
            guard clearWidth > 0, frame.width > 0 else {
                dump(app, "close-overlapped")
                capture("close-overlapped")
                XCTFail("the native Close control has a visible strip outside Address", file: file, line: line)
                return
            }
            normalizedX = min(clearWidth, frame.width) / (2 * frame.width)
        }
        let addressFrame = addresses.count == 1 ? String(describing: addresses.element.frame) : "absent"
        let geometry = XCTAttachment(string: "Close: \(frame); Address: \(addressFrame); normalized tap: \(normalizedX), 0.5")
        geometry.name = "native-close-hit-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        close.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.5)).tap()
        let cards = app.buttons.matching(identifier: "job-card-job-alpha")
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            closeControls.count == 0 && cards.count == 1 && cards.element.isHittable
        }, object: app)
        if XCTWaiter.wait(for: [dismissed], timeout: 10) != .completed {
            dump(app, "after-close")
            capture("after-close")
            XCTFail("closing the browser removes its native Close control and returns to one hittable deck card",
                    file: file, line: line)
        }
    }

    private func tapLink(_ app: XCUIApplication, _ text: String) {
        let link = app.links[text].exists ? app.links[text] : element(app, containing: text)
        XCTAssertTrue(link.waitForExistence(timeout: 20), "link '\(text)' is on the page")
        link.tap()
    }

    // MARK: Tests

    func testLongTitleListingRendersAndCloses() {
        let app = launch(path: "/listing")
        openListing(app)
        expect(app, "Senior Principal Staff Machine Learning")
        capture("safari-long-title-listing")
        dump(app, "safari-long-title-listing")
        closeBrowser(app)
        capture("safari-closed-to-deck")
    }

    func testInternalLinkThenBackAndForward() {
        let app = launch(path: "/listing")
        openListing(app)
        expect(app, "Senior Principal Staff")
        tapLink(app, "Read the internal detail page")
        expect(app, "Reached through an internal link")
        capture("safari-internal-detail")

        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the browser offers Back")
        back.tap()
        expect(app, "Fictional listing for UI tests")
        capture("safari-back-to-listing")

        let forward = app.buttons["Forward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 10), "the browser offers Forward")
        forward.tap()
        expect(app, "Reached through an internal link")
        capture("safari-forward-to-detail")
        closeBrowser(app)
    }

    func testRedirectLandsOnDestination() {
        let app = launch(path: "/listing")
        openListing(app)
        expect(app, "Senior Principal Staff")
        tapLink(app, "Follow the redirect")
        expect(app, "You arrived through a 302 redirect")
        capture("safari-redirect-destination")
        closeBrowser(app)
    }

    func testTargetBlankLinkStaysInsideTheBrowser() {
        let app = launch(path: "/listing")
        openListing(app)
        expect(app, "Senior Principal Staff")
        tapLink(app, "Open the new tab page")
        expect(app, "Opened by a target=_blank link")
        capture("safari-target-blank")
        XCTAssertEqual(app.state, .runningForeground, "the link did not leave Stack")
        closeBrowser(app)
    }

    func testCloseThenReopenShowsTheListingAgain() {
        let app = launch(path: "/listing")
        openListing(app)
        expect(app, "Senior Principal Staff")
        closeBrowser(app)
        openListing(app)
        expect(app, "Senior Principal Staff")
        capture("safari-reopened")
        closeBrowser(app)
        XCTAssertTrue(app.buttons["Save"].isHittable, "Save and Pass are reachable after reopening")
    }

    /// Supply a distinctive error label actually observed on this OS and locale. Safari renders it out of
    /// process; guessing its text would make a native acceptance claim depend on unobserved system UI.
    func testFailedConnectionThenReloadRecovers() throws {
        let errorText = (ProcessInfo.processInfo.environment["STACK_LISTING_ERROR_TEXT"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try XCTSkipIf(errorText.isEmpty && !requiredAcceptance, "Observe Safari's connection-error label on the target OS/locale, then rerun "
            + "with STACK_LISTING_ERROR_TEXT. Missing calibration is not failure/retry acceptance.")
        control("/control/fail?on=1")
        defer { control("/control/fail?on=0") }
        let app = launch(path: "/flaky")
        openListing(app)

        // The browser must have actually reached the fixture, otherwise an empty screen would look like an error.
        var hits = 0
        for _ in 0..<40 where hits == 0 {
            hits = Int(control("/control/hits?path=/flaky")) ?? 0
            if hits == 0 { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertGreaterThan(hits, 0, "the browser requested /flaky from the fixture")

        if errorText.isEmpty {
            // A hosted calibration run records the actual system UI and fails rather than accepting a skip.
            let reload = app.buttons.matching(NSPredicate(format: "label IN %@", ["Reload", "Reload Page"])).firstMatch
            _ = reload.waitForExistence(timeout: 20)
            capture("safari-error-calibration")
            dump(app, "safari-error-calibration")
            XCTFail("Supply the connection-error label observed in these attachments via STACK_LISTING_ERROR_TEXT, then rerun.")
            return
        }

        let error = element(app, containing: errorText)
        let shown = error.waitForExistence(timeout: 20)
        capture("safari-failed-connection")
        dump(app, "safari-failed-connection")
        XCTAssertTrue(shown, "Safari shows the observed connection-error label '\(errorText)' "
            + "(see the attached accessibility tree if the OS or locale changed)")
        XCTAssertFalse(element(app, containing: "The connection works again").exists,
                       "the recovered page did not load while the server dropped the connection")

        control("/control/fail?on=0")
        let reload = app.buttons.matching(NSPredicate(format: "label IN %@", ["Reload", "Reload Page"])).firstMatch
        XCTAssertTrue(reload.waitForExistence(timeout: 10), "the browser offers Reload")
        reload.tap()
        expect(app, "The connection works again")
        XCTAssertFalse(error.exists, "the error page is gone after recovery")
        capture("safari-recovered-after-reload")
        closeBrowser(app)
    }

    func testOpenInSafariHandsOffToTheSystemBrowser() {
        let app = launch(path: "/listing")
        openListing(app)
        expect(app, "Senior Principal Staff")
        let handoff = app.buttons["Open in Safari"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 10), "the browser offers Open in Safari")
        handoff.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Safari came to the foreground")
        capture("safari-handoff-system-browser")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
}
