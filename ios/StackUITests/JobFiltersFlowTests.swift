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
        capture("job-filters-entry-level-active")
        app.buttons["Entry-level software"].tap()
        XCTAssertFalse(app.buttons["Entry-level software"].isSelected)
        XCTAssertTrue(state(app).contains("role=Product designer"))
    }

    func testFiltersSheetKeepsSecondaryFiltersBehindMoreFilters() {
        let app = launch()
        app.buttons["Filters"].tap()
        XCTAssertTrue(app.buttons["Show opportunities"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["More filters"].exists)
        XCTAssertFalse(app.textFields["Minimum advertised pay (USD)"].exists)
        capture("job-filters-sheet-primary")
        app.buttons["More filters"].tap()
        XCTAssertTrue(app.buttons["Fewer filters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Minimum advertised pay (USD)"].exists)
        capture("job-filters-sheet-more")
    }

    func testSortAndResetReturnToProfile() {
        let app = launch()
        app.buttons["Internships"].tap()
        XCTAssertTrue(app.buttons["Internships"].isSelected)
        app.buttons["Sort: Best match"].tap()
        app.buttons["Newest first"].tap()
        XCTAssertTrue(app.buttons["Sort: Newest first"].waitForExistence(timeout: 5))
        XCTAssertTrue(state(app).contains("sort=newest"))
        capture("job-filters-sorted-active")
        app.buttons["Reset filters to profile"].tap()
        XCTAssertFalse(app.buttons["Internships"].isSelected)
        XCTAssertTrue(app.buttons["Sort: Best match"].exists)
        XCTAssertTrue(state(app).contains("levels= |"))
        XCTAssertFalse(app.buttons["Reset filters to profile"].exists)
        capture("job-filters-reset")
    }
}
