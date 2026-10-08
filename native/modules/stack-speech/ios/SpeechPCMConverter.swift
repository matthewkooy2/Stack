import AVFoundation

// Called serially under SpeechAudioWriter's lock. Keep the buffer conversion
// independent of Speech so the actual sample format can be regression-tested.
final class SpeechPCMConverter {
  private let converter: AVAudioConverter?
  private let sourceFormat: AVAudioFormat
  let format: AVAudioFormat
  private var finished = false
  init(from source: AVAudioFormat, to destination: AVAudioFormat) throws {
    sourceFormat = source; format = destination
    if source == destination { converter = nil }
    else {
      guard let value = AVAudioConverter(from: source, to: destination) else {
        throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio conversion is unavailable."])
      }
      converter = value
    }
  }
  func convert(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
    guard !finished else { throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio conversion already finished."]) }
    guard source.format == sourceFormat else {
      throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "The microphone format changed. Your partial audio was kept."])
    }
    guard source.frameLength > 0 else { return nil }
    guard let converter else { return source }
    let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / sourceFormat.sampleRate) + 64)
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio buffer allocation failed."])
    }
    var used = false; var failure: NSError?
    let status = converter.convert(to: output, error: &failure) { _, status in
      if used { status.pointee = .noDataNow; return nil }
      used = true; status.pointee = .haveData; return source
    }
    if let failure { throw failure }
    guard status != .error else {
      throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."])
    }
    return output.frameLength > 0 ? output : nil
  }
  func finish() throws -> [AVAudioPCMBuffer] {
    guard !finished else { return [] }; finished = true
    guard let converter else { return [] }
    var buffers: [AVAudioPCMBuffer] = []
    // .noDataNow retains the resampler's tail. Explicitly end input so Stop
    // saves and recognizes those last samples instead of discarding them.
    for _ in 0..<16 {
      guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
        throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio buffer allocation failed."])
      }
      var failure: NSError?
      let status = converter.convert(to: output, error: &failure) { _, status in status.pointee = .endOfStream; return nil }
      if let failure { throw failure }
      if output.frameLength > 0 { buffers.append(output) }
      if status == .endOfStream { return buffers }
      if status == .error { break }
    }
    throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio conversion could not finish."])
  }
}
