import Foundation

// SpeechTranscriber revises provisional ranges, then emits immutable final ranges.
// Store replacements by audio range instead of appending every result to the UI.
struct TranscriptSegments {
  private var segments: [(start: Double, end: Double, text: String, final: Bool)] = []
  mutating func update(start: Double, end: Double, text: String, final: Bool) {
    guard start.isFinite, end.isFinite, end >= start, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if segments.contains(where: { $0.final && (($0.start == start && $0.end == end) || (start < $0.end - 0.001 && end > $0.start + 0.001)) }) { return }
    segments.removeAll { !$0.final && (($0.start == start && $0.end == end) || (start < $0.end + 0.001 && end > $0.start - 0.001)) }
    segments.append((start, end, text, final)); segments.sort { $0.start < $1.start }
  }
  func text(finalOnly: Bool) -> String {
    segments.filter { !finalOnly || $0.final }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
