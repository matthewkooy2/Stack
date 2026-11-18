import SwiftUI

/// How a member gets the PDF LinkedIn makes of their own profile. Stack never signs in to LinkedIn.
enum LinkedInPDF {
    static let steps = [
        "On a computer, open linkedin.com and go to your profile.",
        "Under your name, click More (or Resources), then Save to PDF.",
        "Send the downloaded Profile.pdf to this iPhone with AirDrop or iCloud Drive.",
        "Tap Choose PDF and pick Profile.pdf.",
    ]
    static let note = "Stack reads only this file and never signs in to LinkedIn"
    static let wrongType = "Choose your LinkedIn PDF"
    static let tooLarge = "Max 10 MB"
    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }
}

/// A saved review (`artifacts.linkedin_review`) as the rows the result screen shows.
struct LinkedInReviewContent: Equatable {
    struct Finding: Equatable, Identifiable {
        let id: Int
        let priority: String
        let section: String
        let weakness: String
        let quote: String
        let why: String
        let recommendation: String
    }

    let summary: String
    let strengths: [String]
    let findings: [Finding]
    let rewrites: [JSON]
    let questions: [String]
    let limitations: String

    init(_ value: JSON) {
        summary = value["summary"].string
        strengths = value["strengths"].strings.filter { !$0.isBlank }
        findings = value["findings"].array.enumerated().compactMap { index, item in
            let weakness = item["weakness"].string
            guard !weakness.isBlank else { return nil }
            return Finding(id: index, priority: item["priority"].string, section: Self.label(item["section"].string),
                           weakness: weakness, quote: item["quote"].string, why: item["why_it_matters"].string,
                           recommendation: item["recommendation"].string)
        }
        rewrites = value["rewrites"].array.filter { !$0["text"].string.isBlank && !$0["section"].string.isBlank }
        questions = value["questions"].strings.filter { !$0.isBlank }
        limitations = value["limitations"].string
    }

    var isEmpty: Bool { findings.isEmpty && rewrites.isEmpty && summary.isBlank }

    /// Section keys from the server, in the words a member sees on LinkedIn.
    static func label(_ section: String) -> String {
        switch section {
        case "about": return "About"
        case "intro": return "Intro"
        case "skills": return "Skills"
        case "honors": return "Honors"
        default: return section.prefix(1).uppercased() + section.dropFirst()
        }
    }
}

/// Directions for the LinkedIn PDF, an optional target role and the one Choose PDF button.
struct LinkedInPDFUploadScreen: View {
    @Binding var role: String
    var busy = false
    var progress = ""
    var error = ""
    let onChoose: () -> Void
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        SymbolDisc(systemName: "person.crop.rectangle", size: 64)
                        Text("LinkedIn review")
                            .font(Typeface.display)
                            .foregroundStyle(Brand.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("Upload your profile as a PDF")
                            .font(Typeface.body).foregroundStyle(Brand.muted)
                    }
                    .reveal(0)

                    DisclosureSection("How to get your LinkedIn PDF") {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(LinkedInPDF.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    Text("\(index + 1)").font(.system(.subheadline).weight(.semibold))
                                        .foregroundStyle(Brand.accent).frame(width: 18, alignment: .leading)
                                    Text(step).font(Typeface.body).foregroundStyle(Brand.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.vertical, 12)
                                .accessibilityElement(children: .combine)
                                if index < LinkedInPDF.steps.count - 1 {
                                    Rectangle().fill(Brand.rule).frame(height: 1)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("linkedin-pdf-steps")
                    .reveal(1)

                    Card {
                        StackField(label: "Target role", text: $role, placeholder: "Data analyst")
                            .accessibilityIdentifier("linkedin-target-role")
                    }
                    .reveal(2)

                    Text(LinkedInPDF.note).font(.footnote).foregroundStyle(Brand.muted).reveal(3)
                }
                .padding(.horizontal, Spacing.page).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 8) {
                if busy || !error.isEmpty {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Brand.accent) }
                        Text(busy ? progress : error).font(Typeface.caption)
                            .foregroundStyle(busy ? Brand.muted : Palette.danger)
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("linkedin-pdf-status")
                }
                PrimaryPill(title: "Choose PDF", icon: "doc", disabled: busy, action: onChoose)
                    .accessibilityIdentifier("linkedin-choose-pdf")
                if let onRetry, !busy {
                    QuietLinks(links: [ScreenLink("Try again", action: onRetry)])
                        .accessibilityIdentifier("linkedin-pdf-retry")
                }
            }
            .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 12)
        }
        .background(Brand.page.ignoresSafeArea())
        .replayable()
    }
}

/// The finished review: one summary, then each weakness with the exact words it is about and what to do.
struct LinkedInReviewScreen: View {
    let content: LinkedInReviewContent
    var role = ""
    var taskID = ""
    let onDone: () -> Void
    var onAnother: (() -> Void)?
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var open: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LinkedIn review")
                            .font(Typeface.display)
                            .foregroundStyle(Brand.ink)
                            .accessibilityAddTraits(.isHeader)
                        if !role.isBlank { StatusPill(text: "For \(role.lowercased()) roles", tone: .accent) }
                        if !content.summary.isBlank {
                            Card {
                                Text(content.summary).font(Typeface.body).foregroundStyle(Brand.ink)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .reveal(0)

                    if !content.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "To improve")
                            ForEach(content.findings) { finding in findingCard(finding) }
                        }
                        .reveal(1)
                    }

                    if !content.rewrites.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Suggested wording")
                            LinkedInRewriteEditor(taskID: taskID, rewrites: content.rewrites).id(content.rewrites)
                        }
                        .reveal(2)
                    }

                    if !content.strengths.isEmpty { list("Working well", content.strengths, symbol: "checkmark.circle.fill", tint: Palette.success).reveal(3) }
                    if !content.questions.isEmpty { list("Worth adding", content.questions, symbol: "plus.circle.fill", tint: Brand.accent).reveal(3) }

                    if !content.limitations.isBlank {
                        Text(content.limitations).font(.footnote).foregroundStyle(Brand.muted).reveal(4)
                    }
                }
                .padding(.horizontal, Spacing.page).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 4) {
                PrimaryPill(title: "Done", action: onDone).accessibilityIdentifier("linkedin-review-done")
                if let onAnother {
                    QuietLinks(links: [ScreenLink("Review another PDF", action: onAnother)])
                }
            }
            .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 12)
        }
        .background(Brand.page.ignoresSafeArea())
        .replayable()
    }

    private func tone(_ priority: String) -> StatusPill.Tone {
        switch priority.lowercased() {
        case "high": return .danger
        case "medium": return .warning
        default: return .neutral
        }
    }

    /// The weakness and its fix show at once; the quote and why it matters open on tap.
    private func findingCard(_ finding: LinkedInReviewContent.Finding) -> some View {
        let expanded = open.contains(finding.id)
        return Button {
            withAnimation(Motion.animation(Motion.snappy, reduce: reduceMotion)) {
                if expanded { open.remove(finding.id) } else { open.insert(finding.id) }
            }
        } label: {
            Card(spacing: 8) {
                HStack(spacing: 8) {
                    if !finding.priority.isBlank { StatusPill(text: finding.priority.capitalized, tone: tone(finding.priority)) }
                    Text(finding.section).font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    Spacer(minLength: 0)
                }
                Text(finding.weakness).font(.headline)
                    .foregroundStyle(Brand.ink).multilineTextAlignment(.leading)
                Text(finding.recommendation).font(Typeface.body).foregroundStyle(Brand.ink.opacity(0.85))
                    .multilineTextAlignment(.leading)
                if expanded {
                    if !finding.quote.isBlank {
                        Text("“\(finding.quote)”").font(.subheadline).italic().foregroundStyle(Brand.muted)
                            .multilineTextAlignment(.leading)
                    }
                    if !finding.why.isBlank {
                        Text(finding.why).font(.subheadline).foregroundStyle(Brand.muted)
                            .multilineTextAlignment(.leading)
                    }
                } else if !finding.quote.isBlank || !finding.why.isBlank {
                    Text("Why").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityHint(expanded ? "Hides the quote" : "Shows the words this is about and why it matters")
    }

    private func list(_ title: String, _ items: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title)
            Card(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol).font(.subheadline).foregroundStyle(tint).accessibilityHidden(true)
                        Text(item).font(Typeface.body).foregroundStyle(Brand.ink)
                    }
                }
            }
        }
    }
}
