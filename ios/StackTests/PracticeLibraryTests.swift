import AVFoundation
import XCTest
@testable import Stack

final class PracticeLibraryTests: XCTestCase {
    private let owner = "practice-test-owner"

    override func tearDown() {
        VideoLibraryStore.removeAll()
        super.tearDown()
    }

    func testAttemptParsesScoreRubricAndStatus() {
        let scored = PracticeAttempt([
            "id": "a1", "question_id": "lib-proud", "created_at": 10, "transcript": "I led it.", "video_id": "video-abcdefghijkl",
            "duration": 42.5, "score": 75, "rubric": ["specificity": 4, "ownership": 3], "feedback": "Add the result.",
            "status": "scored", "run": ["id": "r1", "message": "Completed"],
        ])
        XCTAssertEqual(scored.score, 75)
        XCTAssertEqual(scored.rubric["ownership"], 3)
        XCTAssertFalse(scored.isCoaching)
        XCTAssertEqual(PracticeScore.label(scored), "75")

        let pending = PracticeAttempt(["id": "a2", "score": .null, "status": "queued", "run": ["id": "r2"]])
        XCTAssertNil(pending.score)
        XCTAssertTrue(pending.isCoaching)
        XCTAssertEqual(PracticeScore.label(pending), "Scoring…")

        let stalled = PracticeAttempt(["id": "a3", "score": .null, "status": "failed"])
        XCTAssertTrue(stalled.isStalled)
        XCTAssertEqual(PracticeScore.label(stalled), "Unscored")
        XCTAssertEqual(PracticeScore.label(nil), "Not started")
    }

    func testSlotUsesServerBestAttempt() {
        let empty = PracticeSlot(["question": ["id": "lib-intro", "title": "Background"], "attempt_count": 0, "best": [:]])
        XCTAssertNil(empty.best)
        let slot = PracticeSlot(["question": ["id": "lib-proud", "title": "Proud"], "attempt_count": 3,
                                 "best": ["id": "best", "score": 88, "status": "scored"]])
        XCTAssertEqual(slot.best?.id, "best")
        XCTAssertEqual(slot.attemptCount, 3)
    }

    func testChoicesDefaultToAvailable() {
        XCTAssertTrue(PracticeChoice(["id": "software", "label": "Software"]).available)
        XCTAssertFalse(PracticeChoice(["id": "technical", "label": "Technical", "available": false]).available)
    }

    func testVideoStoreIsOwnerScopedAndCleansUp() throws {
        let id = VideoLibraryStore.newVideoID()
        let url = try VideoLibraryStore.url(owner: owner, videoID: id)
        try Data([1, 2, 3]).write(to: url)
        try Data([4]).write(to: try VideoLibraryStore.audioURL(owner: owner, videoID: id))
        XCTAssertEqual(VideoLibraryStore.existing(owner: owner, videoID: id), url)
        XCTAssertNil(VideoLibraryStore.existing(owner: "other-owner", videoID: id))
        XCTAssertGreaterThan(VideoLibraryStore.usage(owner: owner), 0)
        XCTAssertThrowsError(try VideoLibraryStore.url(owner: owner, videoID: "../escape"))
        XCTAssertThrowsError(try VideoLibraryStore.url(owner: "../owner", videoID: id))

        try VideoLibraryStore.delete(owner: owner, videoID: id)
        XCTAssertNil(VideoLibraryStore.existing(owner: owner, videoID: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try VideoLibraryStore.audioURL(owner: owner, videoID: id).path))

        let other = VideoLibraryStore.newVideoID()
        try Data([1]).write(to: try VideoLibraryStore.url(owner: owner, videoID: other))
        VideoLibraryStore.removeAll()
        XCTAssertNil(VideoLibraryStore.existing(owner: owner, videoID: other))
    }

    func testWAVHeaderMatchesTranscriptionFormat() {
        let header = AudioExtractor.header(dataBytes: 32_000)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header[8..<12], encoding: .ascii), "WAVE")
        func u32(_ offset: Int) -> UInt32 { header[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func u16(_ offset: Int) -> UInt16 { header[offset..<offset + 2].reversed().reduce(0) { $0 << 8 | UInt16($1) } }
        XCTAssertEqual(u16(20), 1)          // PCM
        XCTAssertEqual(u16(22), 1)          // mono
        XCTAssertEqual(u32(24), 16_000)     // sample rate
        XCTAssertEqual(u16(34), 16)         // bits per sample
        XCTAssertEqual(u32(40), 32_000)     // data bytes
    }

    /// Writes a real AAC file with one second of tone, then checks the extracted WAV.
    func testExtractsSixteenKilohertzMonoAudioFromMovie() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("answer.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        do {
            // The file is closed when it goes out of scope, before extraction reads it.
            let file = try AVAudioFile(forWriting: movie, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
            buffer.frameLength = 44_100
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100) * 0.3) }
            try file.write(from: buffer)
        }
        let wav = try await AudioExtractor.wav(from: movie, to: dir.appendingPathComponent("answer.wav"))
        let data = try Data(contentsOf: wav)
        let seconds = Double(data.count - 44) / Double(AudioExtractor.sampleRate * 2)
        XCTAssertEqual(seconds, 1, accuracy: 0.15)
    }
}
