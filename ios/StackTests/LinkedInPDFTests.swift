import XCTest
@testable import Stack

/// The LinkedIn PDF review: what the result screen reads from a stored review, the PDF-only picker,
/// and the Network row finding PDF reviews. Stubs only; no file, network or model.
@MainActor
final class LinkedInPDFTests: XCTestCase {
    func testReviewKeepsUsableRowsInServerOrderWithReadableSections() {
        let content = LinkedInReviewContent([
            "summary": "Lead with outcomes.",
            "strengths": ["Clear tools", ""],
            "findings": [
                ["section": "headline", "priority": "high", "quote": "Data Analyst", "weakness": "Title first.",
                 "why_it_matters": "First line read.", "recommendation": "Lead with skills."],
                ["section": "about", "priority": "low", "quote": "x", "weakness": "", "recommendation": "Dropped: no weakness."],
                ["section": "about", "priority": "medium", "quote": "I build", "weakness": "Broad.", "recommendation": "Name a project."],
            ],
            "rewrites": [["section": "headline", "text": "Data analyst | SQL"], ["section": "", "text": "No section"],
                         ["section": "about", "text": "  "]],
            "questions": ["How many users?"],
            "limitations": "Reviewed from your LinkedIn PDF export.",
        ])
        XCTAssertEqual(content.summary, "Lead with outcomes.")
        XCTAssertEqual(content.strengths, ["Clear tools"])
        XCTAssertEqual(content.findings.map(\.section), ["Headline", "About"])
        XCTAssertEqual(content.findings.map(\.priority), ["high", "medium"])
        XCTAssertEqual(content.rewrites.count, 1)
        XCTAssertFalse(content.isEmpty)
    }

    func testMissingOrEmptyReviewIsEmpty() {
        XCTAssertTrue(LinkedInReviewContent(.null).isEmpty)
        XCTAssertTrue(LinkedInReviewContent(["summary": "  ", "findings": [], "rewrites": []]).isEmpty)
    }

    func testOnlyPDFsAreAcceptedWithTheLinkedInMessage() {
        let uploader = ResumeUploader(read: { url in (url.lastPathComponent, "content") },
                                      accepts: LinkedInPDF.isPDF, wrongType: LinkedInPDF.wrongType)
        XCTAssertTrue(uploader.begin())
        XCTAssertFalse(uploader.picked(.success(URL(fileURLWithPath: "/fixture/Profile.docx"))))
        XCTAssertEqual(uploader.message, LinkedInPDF.wrongType)
        XCTAssertTrue(uploader.begin())
        XCTAssertTrue(uploader.picked(.success(URL(fileURLWithPath: "/fixture/Profile.PDF"))))
        XCTAssertEqual(uploader.progress, "Reading Profile.PDF…")
    }

    func testResumeUploaderDefaultsAreUnchanged() {
        let uploader = ResumeUploader(read: { url in (url.lastPathComponent, "content") })
        XCTAssertTrue(uploader.begin())
        XCTAssertFalse(uploader.picked(.success(URL(fileURLWithPath: "/fixture/Profile.txt"))))
        XCTAssertEqual(uploader.message, ResumeFiles.wrongType)
    }

    func testNetworkRowUsesPDFReviewsAndTheirSections() {
        let older: JSON = ["id": "browser-review", "kind": "linkedin", "created_at": 1.0,
                           "artifacts": ["linkedin_review": ["summary": "Old"]]]
        let pdf: JSON = ["id": "pdf-review", "kind": "linkedin_pdf", "status": "completed", "created_at": 2.0, "artifacts": [
            "linkedin_pdf": ["sections": ["headline": "Data Analyst @ Example Corp"]],
            "linkedin_review": ["rewrites": [["section": "headline", "text": "Data analyst | SQL"]]],
        ]]
        let latest = PresenceLinkedInPresentation.latestRun(in: [older, pdf])
        XCTAssertEqual(latest?["id"].string, "pdf-review")
        let model = PresenceLinkedInPresentation(run: pdf)
        XCTAssertEqual(model.current, "Data Analyst @ Example Corp")
        XCTAssertEqual(model.suggested(saved: nil), "Data analyst | SQL")
    }

    func testDirectionsNameTheExactLinkedInSteps() {
        let text = LinkedInPDF.steps.joined(separator: " ")
        for words in ["linkedin.com", "More", "Save to PDF", "Choose PDF"] { XCTAssertTrue(text.contains(words), words) }
        XCTAssertTrue(LinkedInPDF.note.contains("never signs in to LinkedIn"))
    }
}
