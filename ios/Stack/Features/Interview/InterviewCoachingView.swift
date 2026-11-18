import SwiftUI

/// Interview feedback laid out to scan (#133): a bold verdict, one card of scores, then short lists under pill
/// headings. Structured replies use their fields directly; older prose replies fall back to their text.
struct InterviewCoachingView: View {
    let coaching: JSON
    /// At most this many points per list, so the final feedback stays short on a phone.
    var limit = 2

    private var scores: [CoachCriterion] { CoachingPresentation.criteria(from: coaching) }
    private var structured: Bool { !scores.isEmpty || !coaching["verdict"].string.isBlank }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if structured {
                if !coaching["verdict"].string.isBlank {
                    Text(coaching["verdict"].string).font(Typeface.title)
                        .foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                }
                if !scores.isEmpty {
                    Card(spacing: 0) {
                        ForEach(Array(scores.enumerated()), id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.name).font(.headline).foregroundStyle(Brand.ink)
                                    Spacer()
                                    ScoreChip(score: item.score)
                                }
                                if !item.why.isBlank {
                                    Text(item.why).font(Typeface.caption).foregroundStyle(Brand.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .combine)
                            .overlay(alignment: .bottom) { if index < scores.count - 1 { Divider() } }
                        }
                    }
                }
                points("Strengths", tone: .success, coaching["strengths"].strings)
                points("To improve", tone: .warning, coaching["weaknesses"].strings)
                if !coaching["work_on"].string.isBlank {
                    Card(spacing: 10) {
                        StatusPill(text: "Next step", tone: .accent)
                        Text(coaching["work_on"].string).font(.headline).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                points("Practice next", tone: .neutral, coaching["follow_ups"].strings)
            } else {
                Text(coaching["text"].string.isBlank ? coaching["summary"].string : coaching["text"].string)
                    .font(Typeface.body).foregroundStyle(Brand.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func points(_ title: String, tone: StatusPill.Tone, _ items: [String]) -> some View {
        let shown = items.filter { !$0.isBlank }.prefix(limit)
        if !shown.isEmpty {
            Card(spacing: 10) {
                StatusPill(text: title, tone: tone)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(Typeface.body.weight(.bold)).foregroundStyle(Brand.accent)
                        Text(item).font(Typeface.body).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
