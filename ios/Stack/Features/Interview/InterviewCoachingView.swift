import SwiftUI

/// Interview coaching laid out to scan (#133): a bold verdict, one row per score, then short lists under bold
/// headings. Structured replies use their fields directly; older prose replies fall back to their text.
struct InterviewCoachingView: View {
    let coaching: JSON
    /// At most this many points per list, so the final coaching stays short on a phone.
    var limit = 2

    private var scores: [CoachCriterion] { CoachingPresentation.criteria(from: coaching) }
    private var structured: Bool { !scores.isEmpty || !coaching["verdict"].string.isBlank }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if structured {
                if !coaching["verdict"].string.isBlank {
                    Text(coaching["verdict"].string).font(.system(size: 22, weight: .bold)).tracking(-0.6)
                        .foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                }
                if !scores.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(scores) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Brand.ink)
                                    Spacer()
                                    Text("\(item.score)/4").font(.system(.subheadline).weight(.bold).monospacedDigit())
                                        .foregroundStyle(item.score == 0 ? Palette.danger : Brand.accent)
                                }
                                if !item.why.isBlank {
                                    Text(item.why).font(Typeface.caption).foregroundStyle(Brand.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
                        }
                    }
                    .padding(.top, 12)
                }
                points("Strengths", coaching["strengths"].strings)
                points("Weaknesses", coaching["weaknesses"].strings)
                if !coaching["work_on"].string.isBlank {
                    heading("Next step")
                    Text(coaching["work_on"].string).font(.system(size: 17, weight: .bold)).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                }
                points("Practice next", coaching["follow_ups"].strings)
            } else {
                Text(coaching["text"].string.isBlank ? coaching["summary"].string : coaching["text"].string)
                    .font(Typeface.body).foregroundStyle(Brand.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent).padding(.top, 18)
    }

    @ViewBuilder
    private func points(_ title: String, _ items: [String]) -> some View {
        let shown = items.filter { !$0.isBlank }.prefix(limit)
        if !shown.isEmpty {
            heading(title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(Typeface.body.weight(.bold)).foregroundStyle(Brand.accent)
                        Text(item).font(Typeface.body).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}
