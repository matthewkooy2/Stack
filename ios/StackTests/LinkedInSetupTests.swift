import XCTest
@testable import Stack

/// LinkedIn review setup shows only unmet required steps, one at a time, and never widens a saved permission.
final class LinkedInSetupTests: XCTestCase {
    private let now: TimeInterval = 1_800_000_000
    private let operatorMessage = "The operator must connect this Stack account to the local CLI subscription."

    private func feature(model: Bool = true, rules: Bool = true, permission: Bool = true, browser: Bool = true, facts: Bool = false) -> AgentFeature {
        func check(_ key: String, _ label: String, _ ok: Bool, fix: String, optional: Bool = false) -> JSON {
            ["key": .string(key), "label": .string(label), "ok": .bool(ok), "optional": .bool(optional),
             "fix": .string(ok ? "" : fix), "action": ""]
        }
        return AgentFeature([
            "key": "linkedin", "title": "LinkedIn profile review", "state": .string(model && rules && permission && browser ? "ready" : "unavailable"),
            "alternative": "Use Profile suggestions on Resume to draft a headline and About from your confirmed facts.",
            "checks": .array([
                check("model", "Model provider connected", model, fix: operatorMessage),
                check("rules", "Standing permissions on", rules, fix: "Turn on standing permissions in Agents → Rules."),
                check("perm:model", "Permission: Model", permission, fix: "Allow Model."),
                check("browser", "Browser worker available", browser, fix: "The operator must configure the isolated browser worker."),
                check("facts", "Confirmed facts for stronger rewrites", facts, fix: "Confirm resume facts.", optional: true),
            ]),
        ])
    }

    private func settings(policy: JSON = [:], selection: String = "codex-cli", options: [JSON] = []) -> JSON {
        ["account_id": "account-1", "policy": policy, "model_selection": .string(selection), "model_options": .array(options)]
    }

    private func granted(_ extra: JSON = [:]) -> JSON {
        var policy: JSON = ["enabled": true, "expires_at": .number(now + 86_400), "actions": ["model"]]
        for (key, value) in extra.object { policy[key] = value }
        return policy
    }

    func testFullyConfiguredAccountGoesStraightToTheProfile() {
        let steps = LinkedInSetup.steps(feature: feature(), settings: settings(policy: granted()), now: now)
        XCTAssertEqual(steps, [.profile])
    }

    func testUnknownReadinessNeverBlocksAndTheServerStaysTheAuthority() {
        XCTAssertEqual(LinkedInSetup.steps(feature: nil, settings: .null, now: now), [.profile])
    }

    func testScreenshotStateListsOnlyRequiredUnmetStepsAndSkipsOptionalFacts() {
        let steps = LinkedInSetup.steps(feature: feature(model: false, rules: false, permission: false), settings: .null, now: now)
        XCTAssertEqual(steps, [.allowModel, .modelUnavailable(message: operatorMessage), .profile])
    }

    func testConfiguredAlternativeModelIsOfferedBeforeAnythingElse() {
        let options: [JSON] = [
            ["selection": "codex-cli", "configured": false, "message": .string(operatorMessage)],
            ["selection": "local", "configured": true, "message": "Local inference configured."],
        ]
        let steps = LinkedInSetup.steps(feature: feature(model: false, rules: false, permission: false),
                                        settings: settings(options: options), now: now)
        XCTAssertEqual(steps, [.switchModel(selection: "local", name: "Local model", reason: operatorMessage), .allowModel, .profile])
    }

    func testSavedSelectionThatIsConfiguredOverridesAStaleSnapshot() {
        let options: [JSON] = [["selection": "codex-cli", "configured": true, "message": "Ready"]]
        let steps = LinkedInSetup.steps(feature: feature(model: false, rules: false, permission: false),
                                        settings: settings(policy: granted(), options: options), now: now)
        XCTAssertEqual(steps, [.profile])
    }

    func testExpiredPermissionNeedsAllowingAgain() {
        let expired = granted(["expires_at": .number(now - 1)])
        XCTAssertEqual(LinkedInSetup.steps(feature: feature(), settings: settings(policy: expired), now: now), [.allowModel, .profile])
    }

    func testBrowserWorkerIsAnOperatorStepAfterTheStepsAPersonCanFinish() {
        let steps = LinkedInSetup.steps(feature: feature(rules: false, permission: false, browser: false), settings: .null, now: now)
        XCTAssertEqual(steps, [.allowModel, .browserUnavailable(message: "The operator must configure the isolated browser worker."), .profile])
    }

    // MARK: Permission choices

    func testTurningPermissionsOnWouldSurfaceEverySavedChoiceForRulesReview() {
        let sleeping: JSON = [
            "enabled": false, "actions": ["send_email", "calendar_write", "gmail_read", "model"],
            "expires_at": 0, "analyze_top_matches": true
        ]
        XCTAssertEqual(LinkedInSetup.rearmedActions(sleeping, now: now),
                       ["Send email", "Calendar changes", "Gmail read", "Daily top-match analysis"])
    }

    func testAlreadyActivePermissionsAreNotPresentedAsRearming() {
        let active: JSON = ["enabled": true, "actions": ["send_email"], "expires_at": .number(now + 60)]
        XCTAssertEqual(LinkedInSetup.rearmedActions(active, now: now), [])
    }

    // MARK: Profile address

    func testProfileAddressAcceptsLinkedInProfilesAndAddsAMissingScheme() {
        XCTAssertEqual(LinkedInSetup.profileURL(" https://www.linkedin.com/in/ada-example/ "), "https://www.linkedin.com/in/ada-example/")
        XCTAssertEqual(LinkedInSetup.profileURL("linkedin.com/in/ada"), "https://linkedin.com/in/ada")
    }

    func testProfileAddressRejectsOtherSitesSchemesAndPaths() {
        for bad in ["", "   ", "http://www.linkedin.com/in/ada", "https://evil.example/in/ada",
                    "https://www.linkedin.com.evil.example/in/ada", "https://www.linkedin.com/company/acme",
                    "https://user@www.linkedin.com/in/ada", "https://www.linkedin.com:8443/in/ada",
                    "https://www.linkedin.com/in/ada/details"] {
            XCTAssertNil(LinkedInSetup.profileURL(bad), bad)
        }
    }
}
