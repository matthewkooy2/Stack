import XCTest

/// Drives the real job search bar and filter sheet inside the offline fixture. No sign-in, network or live data.
@MainActor
final class JobFiltersFlowTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--job-filters-ui-test", "--disable-draft-animations"]
        app.launch()
        XCTAssertTrue(app.buttons["Entry-level software"].waitForExistence(timeout: 10))
        return app
    }

    private func state(_ app: XCUIApplication) -> String {
        app.staticTexts["fixture-state"].label
    }

    private func capture(_ name: String) {
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testQuickPickHighlightsEvenWhenTheServerDropsMatchingProfileValues() {
        let app = launch()
        XCTAssertFalse(app.buttons["Entry-level software"].isSelected)
        capture("job-filters-initial")
        app.buttons["Entry-level software"].tap()
        // The fixture profile is already full-time, so employment_types is normalized away like the server does.
        XCTAssertTrue(state(app).contains("role=Software engineer"))
        XCTAssertTrue(state(app).contains("levels=Entry-level"))
        XCTAssertTrue(state(app).contains("types=Full-time"))
        XCTAssertTrue(app.buttons["Entry-level software"].isSelected)
        XCTAssertFalse(app.buttons["Internships"].isSelected)
        XCTAssertTrue(app.buttons["Remove filter Entry-level (stated)"].exists)
        XCTAssertTrue(app.buttons["Reset filters to profile"].isHittable)
        capture("job-filters-entry-level-active")
        app.buttons["Entry-level software"].tap()
        XCTAssertFalse(app.buttons["Entry-level software"].isSelected)
        XCTAssertTrue(state(app).contains("role=Product designer"))
    }

    func testPayAndDatesOpensFromFilterSummaryAndReturnsWithBack() {
        let app = launch()
        app.buttons["Filters"].tap()
        XCTAssertTrue(app.buttons["Show opportunities"].waitForExistence(timeout: 5))
        let pay = app.buttons["Pay and dates"]
        XCTAssertTrue(pay.exists)
        XCTAssertFalse(app.textFields["Minimum advertised pay (USD)"].exists)
        capture("job-filters-sheet-primary")
        for _ in 0..<4 where !pay.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(pay.isHittable)
        pay.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Minimum advertised pay (USD)"].exists)
        XCTAssertFalse(app.buttons["Confirmed matches only"].exists)
        let week = app.buttons["7"]
        for _ in 0..<4 where !week.isHittable { app.scrollViews.firstMatch.swipeUp() }
        week.tap()
        capture("job-filters-pay-and-dates")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["Show opportunities"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Minimum advertised pay (USD)"].exists)
        XCTAssertEqual(pay.value as? String, "Past 7 days")
        let matching = app.buttons["Matching"]
        for _ in 0..<4 where !matching.isHittable { app.scrollViews.firstMatch.swipeUp() }
        matching.tap()
        let timeline = app.buttons["Confirmed timeline matches only"]
        for _ in 0..<4 where !timeline.isHittable { app.scrollViews.firstMatch.swipeUp() }
        timeline.tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(matching.value as? String, "Confirmed timeline matches only")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Filters"].isHittable)
    }

    func testSortAndResetReturnToProfile() {
        let app = launch()
        app.buttons["Internships"].tap()
        XCTAssertTrue(app.buttons["Internships"].isSelected)
        app.buttons["Sort: Best match"].tap()
        app.buttons["Newest first"].tap()
        XCTAssertTrue(app.buttons["Sort: Newest first"].waitForExistence(timeout: 5))
        XCTAssertTrue(state(app).contains("sort=newest"))
        XCTAssertTrue(app.buttons["Reset filters to profile"].isHittable)
        capture("job-filters-sorted-active")
        app.buttons["Reset filters to profile"].tap()
        XCTAssertFalse(app.buttons["Internships"].isSelected)
        XCTAssertTrue(app.buttons["Sort: Best match"].exists)
        XCTAssertTrue(state(app).contains("levels= |"))
        XCTAssertFalse(app.buttons["Reset filters to profile"].exists)
        capture("job-filters-reset")
    }
}
