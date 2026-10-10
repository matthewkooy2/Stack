import XCTest
@testable import Stack

final class JobFilterTests: XCTestCase {
    private func search(query: String = "", filters: JSON = [:], criteria: JSON = [:]) -> JobSearch {
        var value = JobSearch()
        value.query = query
        value.filters = filters
        value.criteria = criteria
        return value
    }

    func testEntryLevelPickSelectsStatedFullTimeSoftwareAndKeepsUnrelatedChoices() {
        let before = search(query: "Nurse", filters: ["sort": "newest", "modes": ["Remote"], "timeline": "confirmed", "future_key": 7])
        let next = before.togglingEntryLevel()
        XCTAssertEqual(next.query, "Software engineer")
        XCTAssertEqual(next.filters["levels"].strings, ["Entry-level"])
        XCTAssertEqual(next.filters["employment_types"].strings, ["Full-time"])
        XCTAssertTrue(next.filters["confirmed_level"].bool)
        XCTAssertTrue(next.filters["confirmed_only"].isNull, "level-only selection must not require every detail")
        XCTAssertEqual(next.filters["sort"].string, "newest")
        XCTAssertEqual(next.filters["modes"].strings, ["Remote"])
        XCTAssertEqual(next.filters["timeline"].string, "confirmed")
        XCTAssertEqual(next.filters["future_key"].int, 7)
    }

    func testEntryLevelPickIsActiveThenTogglesOffWithoutTouchingOtherFilters() {
        var value = search(filters: ["sort": "newest"])
        let on = value.togglingEntryLevel()
        value.query = on.query
        value.filters = on.filters
        XCTAssertTrue(value.entryLevelActive)
        XCTAssertFalse(value.internshipActive)
        let off = value.togglingEntryLevel()
        XCTAssertEqual(off.query, "")
        XCTAssertEqual(off.filters, ["sort": "newest"])
    }

    func testInternshipPickKeepsQueryAndIsSeparateFromEntryLevel() {
        let value = search(query: "Data analyst", filters: ["confirmed_only": true])
        let next = value.togglingInternship()
        XCTAssertEqual(next.query, "Data analyst")
        XCTAssertEqual(next.filters["levels"].strings, ["Internship"])
        XCTAssertEqual(next.filters["employment_types"].strings, ["Internship"])
        XCTAssertTrue(next.filters["confirmed_only"].bool)
        XCTAssertFalse(value.entryLevelActive)
    }

    func testActiveFiltersDescribeSavedChoicesAndRemovalIsTargeted() {
        let value = search(query: "Software engineer", filters: [
            "levels": ["Entry-level"], "employment_types": ["Full-time"], "confirmed_level": true,
            "salary_min": 90000, "salary_period": "year", "sort": "newest",
        ])
        XCTAssertEqual(value.active.map(\.id), ["query", "levels", "employment_types", "salary_min"])
        XCTAssertEqual(value.active[1].label, "Entry-level (stated)")
        let removed = value.removing("levels")
        XCTAssertTrue(removed.filters["levels"].isNull)
        XCTAssertTrue(removed.filters["confirmed_level"].isNull)
        XCTAssertEqual(removed.filters["employment_types"].strings, ["Full-time"])
        XCTAssertEqual(removed.filters["sort"].string, "newest")
        XCTAssertEqual(removed.query, "Software engineer")
        XCTAssertTrue(value.removing("salary_min").filters["salary_period"].isNull)
        XCTAssertEqual(value.removing("query").query, "")
        XCTAssertTrue(search().active.isEmpty)
    }

    func testSortingKeepsQueryAndOtherFilters() {
        let next = search(query: "Nurse", filters: ["levels": ["Senior"]]).sorting(by: "newest")
        XCTAssertEqual(next.query, "Nurse")
        XCTAssertEqual(next.filters["sort"].string, "newest")
        XCTAssertEqual(next.filters["levels"].strings, ["Senior"])
    }

    func testSheetEditsPreserveSavedKeysAndLeaveProfileDefaultsUnwritten() {
        let saved: JSON = ["sort": "newest", "future_key": ["a": 1], "timeline": "all"]
        let value = search(filters: saved, criteria: ["roles": "Nurse", "levels": ["Senior"], "employment_types": ["Full-time"]])
        let baseline = JobFilterDraft(search: value)
        var draft = baseline
        XCTAssertEqual(draft.filters(over: saved, from: baseline)["levels"], .null, "unedited profile level stays a default")
        draft.modes = ["Remote"]
        let out = draft.filters(over: saved, from: baseline)
        XCTAssertEqual(out["modes"].strings, ["Remote"])
        XCTAssertEqual(out["sort"].string, "newest")
        XCTAssertEqual(out["future_key"]["a"].int, 1)
        XCTAssertEqual(out["timeline"].string, "all")
        XCTAssertTrue(out["levels"].isNull)
        XCTAssertTrue(out["confirmed_level"].isNull)
    }

    func testConfirmedLevelIsOnlyWrittenWithALevelAndNeverUsesConfirmedOnly() {
        let value = search(criteria: [:])
        let baseline = JobFilterDraft(search: value)
        var draft = baseline
        draft.levels = ["Entry-level"]
        draft.confirmedLevel = true
        var out = draft.filters(over: [:], from: baseline)
        XCTAssertTrue(out["confirmed_level"].bool)
        XCTAssertTrue(out["confirmed_only"].isNull)
        draft.levels = []
        out = draft.filters(over: out, from: baseline)
        XCTAssertFalse(out["confirmed_level"].bool)
    }

    func testConfirmedTimelineWithoutGraduationIsFlaggedAndNeverTreatedAsEligible() {
        var value = search(filters: ["timeline": "confirmed"])
        XCTAssertTrue(value.missingGraduation)
        value.apply(["criteria": ["timeline": "confirmed", "notices": ["Set your graduation date."]],
                     "timeline_preferences": ["graduation_month": ""], "excluded": [], "occupations": []])
        XCTAssertTrue(value.missingGraduation)
        XCTAssertEqual(value.notices, ["Set your graduation date."])
        XCTAssertEqual(value.active.map(\.id), ["timeline"])
    }

    func testMissingGraduationClearsOnceSavedOrWhenTimelineIsNotConfirmed() {
        var value = search(filters: ["timeline": "confirmed"])
        value.apply(["criteria": [:], "timeline_preferences": ["graduation_month": "2027-05"]])
        XCTAssertFalse(value.missingGraduation)
        XCTAssertFalse(search(filters: ["timeline": "compatible"]).missingGraduation)
        XCTAssertFalse(search(filters: ["timeline": "all"]).missingGraduation)
        XCTAssertFalse(search().missingGraduation)
    }

    func testSavedCriteriaTimelineAlsoCountsWhenFiltersOmitIt() {
        XCTAssertTrue(search(criteria: ["timeline": "confirmed"]).missingGraduation)
    }

    func testEntryLevelStaysActiveWhenServerNormalizedAwayProfileMatchingValues() {
        let value = search(query: "", filters: ["levels": ["Entry-level"], "confirmed_level": true, "sort": "newest"],
                           criteria: ["roles": "Software engineer", "employment_types": ["Full-time"]])
        XCTAssertTrue(value.entryLevelActive)
        XCTAssertFalse(value.internshipActive)
        let off = value.togglingEntryLevel()
        XCTAssertEqual(off.query, "")
        XCTAssertEqual(off.filters, ["sort": "newest"])
    }

    func testEntryLevelToggleOffKeepsEmploymentOverridesItDoesNotOwn() {
        let value = search(query: "Software engineer",
                           filters: ["levels": ["Entry-level"], "confirmed_level": true, "employment_types": ["Full-time"]],
                           criteria: ["roles": "Software engineer", "employment_types": ["Full-time"]])
        XCTAssertTrue(value.entryLevelActive)
        XCTAssertTrue(value.togglingEntryLevel().filters["employment_types"].isNull)
        let other = search(query: "Software engineer",
                           filters: ["levels": ["Entry-level"], "confirmed_level": true, "employment_types": ["Full-time", "Contract"]],
                           criteria: ["roles": "Software engineer", "employment_types": ["Full-time", "Contract"]])
        XCTAssertFalse(other.entryLevelActive)
        XCTAssertFalse(search(query: "Designer", filters: ["levels": ["Entry-level"], "confirmed_level": true],
                              criteria: ["roles": "Software engineer", "employment_types": ["Full-time"]]).entryLevelActive)
    }

    func testInternshipStaysActiveWhenProfileAlreadyListsInternship() {
        let value = search(filters: ["levels": ["Internship"]], criteria: ["employment_types": ["Internship"]])
        XCTAssertTrue(value.internshipActive)
        let off = value.togglingInternship()
        XCTAssertTrue(off.filters["levels"].isNull)
        XCTAssertTrue(search(filters: ["levels": ["Internship"]], criteria: ["employment_types": ["Full-time"]]).internshipActive == false)
    }

    func testProfileOverridesAreVisibleRemovableAndResettable() {
        let value = search(filters: [
            "exclude_companies": ["Acme"], "exclude_terms": [], "soft": ["location"], "modes": [], "location": "",
            "salary_min": 0, "confirmed_level": true, "has_posting_date": true, "future_key": 1,
        ])
        XCTAssertEqual(Set(value.active.map(\.id)),
                       ["exclude_companies", "exclude_terms", "soft", "modes", "location", "salary_min", "confirmed_level", "has_posting_date"])
        let labels = Dictionary(uniqueKeysWithValues: value.active.map { ($0.id, $0.label) })
        XCTAssertEqual(labels["exclude_companies"], "Hiding Acme")
        XCTAssertEqual(labels["exclude_terms"], "No hidden terms")
        XCTAssertEqual(labels["soft"], "Flexible: location")
        XCTAssertEqual(labels["modes"], "Any arrangement")
        XCTAssertEqual(labels["location"], "Any location")
        XCTAssertEqual(labels["salary_min"], "No minimum pay")
        XCTAssertTrue(value.hasOverrides)
        let removed = value.removing("exclude_terms")
        XCTAssertTrue(removed.filters["exclude_terms"].isNull)
        XCTAssertEqual(removed.filters["future_key"].int, 1)
        XCTAssertEqual(removed.filters["soft"].strings, ["location"])
    }

    func testResetIsAvailableForKeysWithoutChipsAndHiddenWhenNothingIsOverridden() {
        XCTAssertFalse(search().hasOverrides)
        XCTAssertFalse(search(filters: ["country": "US"]).hasOverrides)
        XCTAssertTrue(search(filters: ["sort": "newest"]).hasOverrides)
        XCTAssertTrue(search(filters: ["unreleased_key": true]).hasOverrides)
        XCTAssertTrue(search(query: "Nurse").hasOverrides)
    }

    func testRequestGateSerializesSavesAndLoads() {
        var gate = JobRequestGate()
        XCTAssertTrue(gate.beginLoad())
        XCTAssertTrue(gate.busy)
        XCTAssertFalse(gate.beginSave(), "a preset tapped during a load must wait")
        XCTAssertFalse(gate.beginLoad(), "a second load must not run alongside the first")
        gate.endLoad()
        XCTAssertTrue(gate.beginSave())
        XCTAssertFalse(gate.beginLoad(), "a refresh must not read the search before it is saved")
        XCTAssertFalse(gate.beginSave())
        gate.endSave()
        XCTAssertTrue(gate.beginLoad())
        XCTAssertTrue(gate.loading)
        gate.endLoad()
        XCTAssertFalse(gate.busy)
    }
}
