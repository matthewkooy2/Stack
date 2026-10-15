import XCTest
@testable import Stack

/// LinkedIn review setup shows only unmet provider and browser requirements, one at a time.
final class LinkedInSetupTests: XCTestCase {
    private let operatorMessage = "The server model provider is not configured."

    private func feature(model: Bool = true, browser: Bool = true, facts: Bool = false, legacyModelGate: Bool = false) -> AgentFeature {
        func check(_ key: String, _ label: String, _ ok: Bool, fix: String, optional: Bool = false) -> JSON {
            ["key": .string(key), "label": .string(label), "ok": .bool(ok), "optional": .bool(optional),
             "fix": .string(ok ? "" : fix), "action": ""]
        }
        var checks: [JSON] = [
            check("model", "Model provider connected", model, fix: operatorMessage),
            check("browser", "Browser worker available", browser, fix: "The operator must configure the isolated browser worker."),
            check("facts", "Confirmed facts for stronger rewrites", facts, fix: "Confirm resume facts.", optional: true),
        ]
        if legacyModelGate {
            checks.append(check("rules", "Standing permissions on", false, fix: "Turn on rules."))
            checks.append(check("perm:model", "Permission: Model", false, fix: "Allow Model."))
        }
        return AgentFeature([
            "key": "linkedin", "title": "LinkedIn profile review", "state": .string(model && browser ? "ready" : "unavailable"),
            "alternative": "Use Profile suggestions on Resume to draft a headline and About from your confirmed facts.",
            "checks": .array(checks),
        ])
    }

    private func settings(selection: String = "codex-cli", options: [JSON] = []) -> JSON {
        ["model_selection": .string(selection), "model_options": .array(options)]
    }

    func testFullyConfiguredAccountGoesStraightToTheProfile() {
        let steps = LinkedInSetup.steps(feature: feature(), settings: settings())
        XCTAssertEqual(steps, [.profile])
    }

    func testUnknownReadinessNeverBlocksAndTheServerStaysTheAuthority() {
        XCTAssertEqual(LinkedInSetup.steps(feature: nil, settings: .null), [.profile])
    }

    func testScreenshotStateListsOnlyRequiredUnmetStepsAndSkipsOptionalFacts() {
        let steps = LinkedInSetup.steps(feature: feature(model: false), settings: .null)
        XCTAssertEqual(steps, [.modelUnavailable(message: operatorMessage), .profile])
    }

    func testConfiguredAlternativeModelIsOfferedBeforeAnythingElse() {
        let options: [JSON] = [
            ["selection": "codex-cli", "configured": false, "message": .string(operatorMessage)],
            ["selection": "local", "configured": true, "message": "Local inference configured."],
        ]
        let steps = LinkedInSetup.steps(feature: feature(model: false), settings: settings(options: options))
        XCTAssertEqual(steps, [.switchModel(selection: "local", name: "Local model", reason: operatorMessage), .profile])
    }

    func testSavedSelectionThatIsConfiguredOverridesAStaleSnapshot() {
        let options: [JSON] = [["selection": "codex-cli", "configured": true, "message": "Ready"]]
        let steps = LinkedInSetup.steps(feature: feature(model: false), settings: settings(options: options))
        XCTAssertEqual(steps, [.profile])
    }

    func testLegacyModelPermissionChecksNeverGateReview() {
        XCTAssertEqual(LinkedInSetup.steps(feature: feature(legacyModelGate: true), settings: settings()), [.profile])
    }

    func testBrowserWorkerIsAnOperatorStepAfterTheStepsAPersonCanFinish() {
        let steps = LinkedInSetup.steps(feature: feature(browser: false), settings: .null)
        XCTAssertEqual(steps, [.browserUnavailable(message: "The operator must configure the isolated browser worker."), .profile])
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
