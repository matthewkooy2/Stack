import ExpoModulesCore
import Speech

public final class StackSpeechModule: Module {
  private var capture: AnyObject?
  public func definition() -> ModuleDefinition {
    Name("StackSpeech")
    Events("capture")
    AsyncFunction("capabilities") { () async -> [String: Any] in
      if #available(iOS 26.0, *) { return await StackSpeechSession.capabilities() }
      return ["available": false, "reason": "On-device speech requires iOS 26 and a supported iPhone. PC transcription will be used."]
    }
    AsyncFunction("start") { (uri: String, id: String) async throws -> Void in
      if #available(iOS 26.0, *) {
        try await self.begin(uri: uri, id: id)
      } else { throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "On-device speech is unavailable."]) }
    }
    AsyncFunction("pause") { (id: String) async throws -> Void in
      if #available(iOS 26.0, *) { try await self.pause(id: id) }
    }
    AsyncFunction("resume") { (id: String) async throws -> Void in
      if #available(iOS 26.0, *) { try await self.resume(id: id) }
    }
    AsyncFunction("stop") { (id: String, cancelled: Bool) async -> [String: Any] in
      if #available(iOS 26.0, *) { return await self.end(id: id, cancelled: cancelled) }
      return ["id": id, "complete": false]
    }
    OnDestroy {
      Task { @MainActor in
        if #available(iOS 26.0, *), let session = self.capture as? StackSpeechSession {
          _ = await session.stop(cancelled: true, reason: "Recording screen closed. Audio was kept.")
        }
      }
    }
  }
  @available(iOS 26.0, *) @MainActor private func begin(uri: String, id: String) async throws {
    if let previous = capture as? StackSpeechSession, previous.isBusy { throw StackSpeechSession.failure("A recording is already in progress.") }
    let session = StackSpeechSession(id: id) { [weak self] event in self?.sendEvent("capture", event) }
    capture = session
    do { try await session.start(uri: uri) }
    catch { _ = await session.stop(cancelled: true, reason: error.localizedDescription); throw error }
  }
  @available(iOS 26.0, *) @MainActor private func pause(id: String) throws {
    guard let session = capture as? StackSpeechSession, session.id == id else { throw StackSpeechSession.failure("Recording is unavailable.") }
    try session.pause()
  }
  @available(iOS 26.0, *) @MainActor private func resume(id: String) throws {
    guard let session = capture as? StackSpeechSession, session.id == id else { throw StackSpeechSession.failure("Recording is unavailable.") }
    try session.resume()
  }
  @available(iOS 26.0, *) @MainActor private func end(id: String, cancelled: Bool) async -> [String: Any] {
    guard let session = capture as? StackSpeechSession, session.id == id else { return ["id": id, "complete": false] }
    return await session.stop(cancelled: cancelled, reason: cancelled ? "Recording cancelled. Audio was kept." : "")
  }
}
