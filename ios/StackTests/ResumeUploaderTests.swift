import XCTest
@testable import Stack

/// The resume upload state: one picker and one request at a time, visible progress, a kept file for an explicit
/// Try again, and nothing carried across accounts. The reader and request are stubs; no file or network is used.
@MainActor
final class ResumeUploaderTests: XCTestCase {
    private final class Calls {
        var reads = 0
        var sends: [String] = []
    }

    private let pdf = URL(fileURLWithPath: "/fixture/Ada Resume.pdf")
    private let docx = URL(fileURLWithPath: "/fixture/Ada Resume.docx")

    private func uploader(_ calls: Calls, readFails: Int = 0) -> ResumeUploader {
        ResumeUploader { url in
            calls.reads += 1
            if calls.reads <= readFails { throw APIError(message: "This file could not be read.") }
            return (url.lastPathComponent, "content-\(calls.reads)")
        }
    }

    func testRepeatedTapsOpenThePickerOnceAndShowItAtOnce() {
        let model = uploader(Calls())
        XCTAssertTrue(model.begin())
        XCTAssertFalse(model.begin())
        XCTAssertEqual(model.phase, .choosing)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.progress, "Opening files…")
    }

    func testCancellingThePickerRestoresIdle() {
        let model = uploader(Calls())
        XCTAssertTrue(model.begin())
        XCTAssertFalse(model.picked(.failure(CocoaError(.userCancelled))))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.begin())
        model.pickerClosed()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.begin(), "A cancelled picker can be opened again")
    }

    func testPDFAndDOCXAreAcceptedAndOtherFilesAreNotSent() async {
        XCTAssertTrue(ResumeFiles.isResume(pdf))
        XCTAssertTrue(ResumeFiles.isResume(docx))
        XCTAssertTrue(ResumeFiles.isResume(URL(fileURLWithPath: "/fixture/RESUME.PDF")))
        for name in ["resume.doc", "resume.tex", "resume.zip", "resume.png", "resume"] {
            XCTAssertFalse(ResumeFiles.isResume(URL(fileURLWithPath: "/fixture/" + name)), name)
        }
        XCTAssertTrue(ResumeFiles.allowedTypes.contains(.pdf))
        XCTAssertEqual(ResumeFiles.allowedTypes.count, 2, "The picker offers PDF and DOCX")

        let calls = Calls()
        let model = uploader(calls)
        XCTAssertTrue(model.begin())
        XCTAssertFalse(model.picked(.success(URL(fileURLWithPath: "/fixture/resume.tex"))))
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.message, ResumeFiles.wrongType)
        XCTAssertFalse(model.canRetry)
        let sent = await model.run { calls.sends.append($0.name) }
        XCTAssertFalse(sent)
        XCTAssertEqual(calls.reads, 0)
        XCTAssertEqual(calls.sends, [])
    }

    func testUploadShowsReadingThenUploadingAndSendsOnce() async {
        let calls = Calls()
        let model = uploader(calls)
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(docx)))
        XCTAssertEqual(model.phase, .reading, "Progress shows before the read starts")
        XCTAssertEqual(model.progress, "Reading Ada Resume.docx…")
        var seen = ""
        let sent = await model.run { file in
            seen = model.progress
            calls.sends.append(file.content)
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(seen, "Uploading Ada Resume.docx…")
        XCTAssertEqual(calls.sends, ["content-1"])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.fileName, "")
        XCTAssertFalse(model.canRetry)
    }

    func testTapsAndPicksWhileUploadingNeverSendASecondRequest() async {
        let calls = Calls()
        let model = uploader(calls)
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        let sent = await model.run { file in
            calls.sends.append(file.name)
            XCTAssertFalse(model.begin())
            XCTAssertFalse(model.picked(.success(self.docx)))
            XCTAssertFalse(model.retry())
            let nested = await model.run { calls.sends.append("duplicate " + $0.name) }
            XCTAssertFalse(nested)
        }
        XCTAssertTrue(sent)
        XCTAssertEqual(calls.sends, ["Ada Resume.pdf"])
        XCTAssertEqual(calls.reads, 1)
    }

    func testFailedUploadKeepsTheFileAndOnlyAnExplicitRetrySendsTheSameBytes() async {
        let calls = Calls()
        let model = uploader(calls)
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        let first = await model.run { file in
            calls.sends.append(file.content)
            throw APIError(message: "Cannot reach Stack. Check your connection and retry.")
        }
        XCTAssertFalse(first)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.message, "Cannot reach Stack. Check your connection and retry.")
        XCTAssertEqual(model.fileName, "Ada Resume.pdf")
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(calls.sends, ["content-1"], "An uncertain result is not retried automatically")

        XCTAssertTrue(model.retry())
        XCTAssertEqual(model.phase, .uploading)
        let second = await model.run { calls.sends.append($0.content) }
        XCTAssertTrue(second)
        XCTAssertEqual(calls.sends, ["content-1", "content-1"])
        XCTAssertEqual(calls.reads, 1, "Try again resends the bytes already read")
        XCTAssertEqual(model.phase, .idle)
    }

    func testFailedReadKeepsThePickedFileAndRetryReadsItAgain() async {
        let calls = Calls()
        let model = uploader(calls, readFails: 1)
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        let first = await model.run { calls.sends.append($0.content) }
        XCTAssertFalse(first)
        XCTAssertEqual(model.message, "This file could not be read.")
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(calls.sends, [])

        XCTAssertTrue(model.retry())
        XCTAssertEqual(model.phase, .reading)
        let second = await model.run { calls.sends.append($0.content) }
        XCTAssertTrue(second)
        XCTAssertEqual(calls.reads, 2)
        XCTAssertEqual(calls.sends, ["content-2"])
    }

    func testCancellingAnotherPickAfterAFailureKeepsTryAgain() async {
        let model = uploader(Calls())
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        _ = await model.run { _ in throw APIError(message: "Upload failed.") }
        XCTAssertTrue(model.begin())
        model.pickerClosed()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.fileName, "Ada Resume.pdf")
    }

    func testAFileIsAcceptedEvenWhenThePickerReportsClosingFirst() {
        let model = uploader(Calls())
        XCTAssertTrue(model.begin())
        model.pickerClosed()
        XCTAssertTrue(model.picked(.success(pdf)))
        XCTAssertEqual(model.phase, .reading)
    }

    func testAnAccountChangeDropsTheFileAndTheLateAnswer() async {
        let calls = Calls()
        let model = uploader(calls)
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        let sent = await model.run { file in
            calls.sends.append(file.name)
            model.reset()
        }
        XCTAssertFalse(sent, "An answer for the previous account is ignored")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.canRetry)
        XCTAssertEqual(model.fileName, "")

        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        let ended = await model.run { _ in throw CancellationError() }
        XCTAssertFalse(ended)
        XCTAssertEqual(model.phase, .idle, "An ended session leaves nothing to retry")
        XCTAssertFalse(model.canRetry)
    }

    func testTheSizeLimitMessageReachesTheScreen() async {
        let model = ResumeUploader { _ in throw APIError(message: ResumeFiles.tooLarge) }
        XCTAssertTrue(model.begin())
        XCTAssertTrue(model.picked(.success(pdf)))
        _ = await model.run { _ in XCTFail("An oversized file is never sent") }
        XCTAssertEqual(model.message, "Resume must be 10 MB or smaller.")
        XCTAssertEqual(ResumeFiles.limit, 10 * 1024 * 1024)
    }
}
