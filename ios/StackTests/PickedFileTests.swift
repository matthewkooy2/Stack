import XCTest
@testable import Stack

final class PickedFileTests: XCTestCase {
    private func temporaryFile(bytes: Int, name: String = "resume.pdf") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    func testBackgroundReadEncodesTheFileAndKeepsItsName() async throws {
        let url = try temporaryFile(bytes: 3, name: "Ada Resume.pdf")
        let file = try await readPickedFileInBackground(url, limit: 10, tooLarge: "too large")
        XCTAssertEqual(file.name, "Ada Resume.pdf")
        XCTAssertEqual(file.content, Data(repeating: 0x41, count: 3).base64EncodedString())
    }

    func testBackgroundReadRejectsFilesOverTheLimitWithTheCallersMessage() async throws {
        let url = try temporaryFile(bytes: 11)
        do {
            _ = try await readPickedFileInBackground(url, limit: 10, tooLarge: "PDF must be 10 MB or smaller.")
            XCTFail("An oversized file must be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "PDF must be 10 MB or smaller.")
        }
    }
}
