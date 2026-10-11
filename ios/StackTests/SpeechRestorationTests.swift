import AVFoundation
import XCTest
@testable import Stack

@MainActor
final class SpeechRestorationTests: XCTestCase {
    private func file(owner: String = "speech-test-owner") throws -> URL {
        let url = try RecordingStore.url(owner: owner, clientID: RecordingStore.newClientID())
        try Data(repeating: 1, count: 64).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("synced"))
        }
        return url
    }

    func testPhoneOriginalSurvivesEditsAndReload() throws {
        let url = try file()
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Recognized original.", text: "Recognized original.", revision: 1), at: url)
        try RecordingStore.editTranscript("Reviewed correction.", at: url)
        let reopened = try XCTUnwrap(RecordingStore.transcript(at: url))
        XCTAssertEqual(reopened.original, "Recognized original.")
        XCTAssertEqual(reopened.text, "Reviewed correction.")
        XCTAssertEqual(reopened.revision, 2)
    }

    func testLateFinalizationCannotRecreateDeletedRecording() throws {
        let url = try file()
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try RecordingStore.saveTranscript(PhoneTranscript(original: "Late.", text: "Late.", revision: 1), at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("json").path))
    }

    func testRawFallbackSyncStateSurvivesReopenWithoutPhoneTranscript() throws {
        let owner = "speech-test-" + UUID().uuidString
        let url = try file(owner: owner)
        let id = url.deletingPathExtension().lastPathComponent
        XCTAssertTrue(RecordingStore.pending(owner: owner).contains { $0.clientID == id })
        try RecordingStore.markSynced("server-recording", at: url)
        XCTAssertNil(RecordingStore.transcript(at: url))
        XCTAssertFalse(RecordingStore.pending(owner: owner).contains { $0.clientID == id })
        try RecordingStore.delete(owner: owner, clientID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("synced").path))
    }

    func testAcknowledgedOlderTextDoesNotHideNewerPhoneEdits() throws {
        let owner = "speech-test-" + UUID().uuidString
        let url = try file(owner: owner)
        let id = url.deletingPathExtension().lastPathComponent
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Original.", text: "Reviewed.", revision: 2), at: url)
        try RecordingStore.markSynced("server-recording", text: "Reviewed.", at: url)
        XCTAssertFalse(RecordingStore.pending(owner: owner).contains { $0.clientID == id })
        try RecordingStore.editTranscript("Newest offline correction.", at: url)
        try RecordingStore.markSynced("server-recording", text: "Reviewed.", at: url)
        XCTAssertEqual(RecordingStore.transcript(at: url)?.text, "Newest offline correction.")
        XCTAssertTrue(RecordingStore.pending(owner: owner).contains { $0.clientID == id })
    }

    func testReopenRecoversPhoneCorrectionAndStopsAutomaticCrossDeviceOverwrite() async throws {
        let url = try file()
        let id = url.deletingPathExtension().lastPathComponent
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Original.", text: "Reviewed.", revision: 2), at: url)
        try RecordingStore.markSynced("server-recording", text: "Reviewed.", at: url)
        try RecordingStore.editTranscript("Offline correction.", at: url)
        let store = AppStore(api: APIClient(origin: URL(string: "https://speech-test.invalid")!, session: stubSession()))
        store.phase = .ready; store.account = AccountState(raw: ["user_id": "speech-test-owner"])
        let model = PrepModel(); model.bind(store)
        for serverAnswer in ["Cross-device correction.", "Reviewed."] {
        StubProtocol.seen = []
        StubProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "prep_get": return (200, envelope(["id": "session-1", "revision": 4, "data": ["answer": .string(serverAnswer), "behavioral": ["local_id": .string(id), "recording_id": "server-recording"]]]))
            case "transcription_get": return (200, envelope(["id": "server-recording", "status": "completed", "model": "Apple SpeechTranscriber", "transcript": "Cross-device correction.", "revision": 3]))
            case "agent_activity": return (200, envelope(["runs": []]))
            default: XCTFail("Unexpected request \(request.url!)"); return (500, Data())
            }
        }
        defer { StubProtocol.handler = nil }
        await model.openSession("session-1")
        XCTAssertEqual(model.draft, "Offline correction.")
        XCTAssertEqual(model.page, .review)
        XCTAssertTrue(model.autosaveFailed)
        await model.autoSave()
        XCTAssertEqual(RecordingStore.transcript(at: url)?.text, "Offline correction.")
        XCTAssertEqual(StubProtocol.seen.count, 3)
        }
    }

    func testOwnerPathsCannotAliasThroughSanitization() throws {
        let id = RecordingStore.newClientID()
        XCTAssertNotEqual(try RecordingStore.url(owner: "owner-a", clientID: id), try RecordingStore.url(owner: "owner-b", clientID: id))
        XCTAssertThrowsError(try RecordingStore.url(owner: "owner-a/", clientID: id))
    }

    func testFinalRangesReplaceProvisionalTextWithoutDuplication() {
        var segments = TranscriptSegments()
        segments.update(start: 0, end: 1, text: "provisional", final: false)
        segments.update(start: 0, end: 1, text: "Final answer", final: true)
        segments.update(start: 0, end: 1, text: "late revision", final: false)
        segments.update(start: 1, end: 2, text: "still thinking", final: false)
        XCTAssertEqual(segments.text(finalOnly: true), "Final answer")
        XCTAssertEqual(segments.text(finalOnly: false), "Final answer still thinking")
    }

    func testFloatMicrophoneConvertsToDurablePCMAndNegotiatedFloatSpeech() throws {
        let natural = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let speech = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: natural, frameCapacity: 4800))
        buffer.frameLength = 4800
        for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.06) * 0.3) }
        let first = try SpeechPCMConverter(from: natural, to: pcm)
        let durable = try XCTUnwrap(first.convert(buffer))
        XCTAssertGreaterThan(durable.frameLength, 0)
        XCTAssertNotNil(durable.int16ChannelData)
        let second = try SpeechPCMConverter(from: pcm, to: speech)
        let recognized = try XCTUnwrap(second.convert(durable))
        XCTAssertGreaterThan(recognized.frameLength, 0)
        XCTAssertNotNil(recognized.floatChannelData)
        _ = try first.finish(); _ = try second.finish()
    }

    nonisolated private func body(_ request: URLRequest) throws -> JSON {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }

    func testLegacyBackendKeepsPhoneTextAndDoesNotQueueWhisper() async throws {
        let url = try file()
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Original.", text: "Reviewed.", revision: 2), at: url)
        let store = AppStore(api: APIClient(origin: URL(string: "https://speech-test.invalid")!, session: stubSession()))
        store.phase = .ready; store.account = AccountState(raw: ["user_id": "speech-test-owner"])
        let model = PrepModel(); model.bind(store)
        model.localURL = url; model.localClientID = url.deletingPathExtension().lastPathComponent; model.draft = "Reviewed."
        StubProtocol.seen = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/function/transcription_list")
            return (200, envelope(["recordings": [], "runtime": [:]]))
        }
        defer { StubProtocol.handler = nil }
        await model.retryUpload()
        XCTAssertEqual(model.draft, "Reviewed.")
        XCTAssertEqual(RecordingStore.transcript(at: url)?.original, "Original.")
        XCTAssertTrue(model.recording.object.isEmpty)
        XCTAssertTrue(model.error.contains("saved on this phone"))
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testAutoSaveReconcilesRecordingWhenPrepAlreadyMatchesNewestEdit() async throws {
        let url = try file()
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Original.", text: "Newest.", revision: 3), at: url)
        let store = AppStore(api: APIClient(origin: URL(string: "https://speech-test.invalid")!, session: stubSession()))
        store.phase = .ready; store.account = AccountState(raw: ["user_id": "speech-test-owner"])
        let model = PrepModel(); model.bind(store)
        model.localURL = url; model.localClientID = url.deletingPathExtension().lastPathComponent; model.draft = "Newest."; model.page = .review
        model.current = ["id": "session-1", "revision": 3, "data": ["problem_id": "project", "answer": "Newest.", "transcript": "Newest.", "canvas": [:], "behavioral": ["local_id": .string(model.localClientID), "recording_id": "recording-1"]]]
        model.recording = ["id": "recording-1", "status": "completed", "model": "Apple SpeechTranscriber", "transcript": "Older.", "revision": 2]
        StubProtocol.seen = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "transcription_action")
            XCTAssertEqual(try self.body(request)["text"].string, "Newest.")
            return (200, envelope(["id": "recording-1", "status": "completed", "model": "Apple SpeechTranscriber", "transcript": "Newest.", "revision": 3]))
        }
        defer { StubProtocol.handler = nil }
        await model.autoSave()
        XCTAssertEqual(model.error, "")
        XCTAssertEqual(model.recording["transcript"].string, "Newest.")
        XCTAssertEqual(RecordingStore.transcript(at: url)?.syncedText, "Newest.")
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testFailedPrepSaveDoesNotAcknowledgePhoneEdits() async throws {
        let url = try file()
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Original.", text: "Reviewed.", revision: 2), at: url)
        let store = AppStore(api: APIClient(origin: URL(string: "https://speech-test.invalid")!, session: stubSession()))
        store.phase = .ready; store.account = AccountState(raw: ["user_id": "speech-test-owner"])
        let model = PrepModel(); model.bind(store)
        model.localURL = url; model.localClientID = url.deletingPathExtension().lastPathComponent; model.draft = "Reviewed."
        model.current = ["id": "session-1", "revision": 1, "data": ["problem_id": "project", "answer": "Older.", "canvas": [:], "behavioral": ["index": 0]]]
        StubProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "transcription_list": return (200, envelope(["client_transcripts": true]))
            case "transcription_upload": return (200, envelope(["id": "recording-1", "status": "completed", "model": "Apple SpeechTranscriber", "original_transcript": "Original.", "transcript": "Original.", "revision": 1]))
            case "transcription_action": return (200, envelope(["id": "recording-1", "status": "completed", "model": "Apple SpeechTranscriber", "original_transcript": "Original.", "transcript": "Reviewed.", "revision": 2]))
            case "prep_catalog": return (200, envelope(["problems": [["id": "project"]]]))
            case "prep_save": return (500, Data())
            default: XCTFail("Unexpected request \(request.url!)"); return (500, Data())
            }
        }
        defer { StubProtocol.handler = nil }
        await model.retryUpload()
        XCTAssertFalse(model.error.isEmpty)
        XCTAssertEqual(RecordingStore.transcript(at: url)?.text, "Reviewed.")
        XCTAssertNil(RecordingStore.transcript(at: url)?.syncedText)
        XCTAssertTrue(RecordingStore.transcript(at: url)?.hasPendingEdits == true)
    }

    func testSyncSendsOriginalAndSavesReviewedCorrectionSeparately() async throws {
        let url = try file()
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Original.", text: "Reviewed.", revision: 2), at: url)
        let store = AppStore(api: APIClient(origin: URL(string: "https://speech-test.invalid")!, session: stubSession()))
        store.phase = .ready; store.account = AccountState(raw: ["user_id": "speech-test-owner"])
        let model = PrepModel(); model.bind(store)
        model.localURL = url; model.localClientID = url.deletingPathExtension().lastPathComponent; model.draft = "Reviewed."
        model.current = ["id": "session-1", "revision": 1, "data": ["problem_id": "project", "answer": "Reviewed.", "canvas": [:], "behavioral": ["index": 0]]]
        let recording: JSON = ["id": "recording-1", "status": "completed", "model": "Apple SpeechTranscriber", "original_transcript": "Original.", "transcript": "Original.", "revision": 1]
        StubProtocol.seen = []
        StubProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "transcription_list": return (200, envelope(["client_transcripts": true, "recordings": [], "runtime": [:]]))
            case "transcription_upload":
                let args = try self.body(request)
                XCTAssertEqual(args["local_transcript"].string, "Original.")
                XCTAssertEqual(Data(base64Encoded: args["content"].string), try Data(contentsOf: url))
                return (200, envelope(recording))
            case "transcription_action":
                let args = try self.body(request)
                XCTAssertEqual(args["text"].string, "Reviewed."); XCTAssertEqual(args["revision"].int, 1)
                var edited = recording; edited["transcript"] = "Reviewed."; edited["revision"] = 2
                return (200, envelope(edited))
            case "prep_catalog": return (200, envelope(["problems": [["id": "project"]]]))
            case "prep_save": return (200, envelope(["id": "session-1", "revision": 2, "data": try self.body(request)["data"]]))
            case "prep_sessions": return (200, envelope(["sessions": []]))
            default: XCTFail("Unexpected request \(request.url!)"); return (500, Data())
            }
        }
        defer { StubProtocol.handler = nil }
        await model.retryUpload()
        XCTAssertEqual(model.error, "")
        XCTAssertEqual(model.recording["original_transcript"].string, "Original.")
        XCTAssertEqual(model.recording["transcript"].string, "Reviewed.")
        XCTAssertEqual(model.draft, "Reviewed.")
        XCTAssertFalse(model.needsPolling)
        XCTAssertEqual(StubProtocol.seen.filter { $0.url?.lastPathComponent == "transcription_upload" }.count, 1)
    }
}
