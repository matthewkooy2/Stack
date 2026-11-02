import SwiftUI

/// Presentation only: use the employer excerpts supplied by the compact feed, never generated fit prose.
struct JobCardCopy {
    let job: Job

    var location: String {
        [job.location.isBlank ? "Location not listed" : job.location, job.mode == "Unknown" ? "" : job.mode]
            .filter { !$0.isBlank }.joined(separator: " · ")
    }

    var pay: String { job.salary.isBlank ? "Pay not listed" : job.salary }

    var payPeriod: String {
        guard !job.salary.isBlank, !job.salary.localizedCaseInsensitiveContains("not listed") else { return "" }
        let unit = job.raw["compensation"]["unit"].string.lowercased()
        let salary = job.salary.lowercased()
        switch unit {
        case "year":
            return ["year", "/yr", "annual"].contains(where: { salary.contains($0) }) ? "" : "/ year"
        case "hour":
            return ["hour", "/hr", "hourly"].contains(where: { salary.contains($0) }) ? "" : "/ hour"
        default: return ""
        }
    }

    var payExcerpt: String {
        guard job.salary.isBlank || job.salary.localizedCaseInsensitiveContains("not listed") else { return "" }
        return job.raw["highlights"]["pay_excerpt"].string
    }

    /// When the employer only states pay in text, show that text in place of a "Pay not listed" headline.
    var showsPayHeadline: Bool { payExcerpt.isEmpty }

    var roleExcerpt: String {
        let supplied = job.raw["highlights"]["responsibilities"].strings.first { !$0.isBlank }
        return supplied ?? job.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var requirements: [String] {
        let excerpts = job.raw["highlights"]["requirements"].strings.filter { !$0.isBlank }
        let source = excerpts.isEmpty ? job.requirements : excerpts
        var seen: Set<String> = []
        return source.filter { !$0.isBlank && $0 != roleExcerpt && seen.insert($0).inserted }.prefix(2).map { $0 }
    }

    var tags: String { job.tags.filter { !$0.isBlank }.prefix(4).joined(separator: " · ") }

    var accessibilityLabel: String {
        [job.company, job.posted, job.title, location, pay, payPeriod, payExcerpt, tags, roleExcerpt]
            .filter { !$0.isBlank }.joined(separator: ". ")
            + (requirements.isEmpty ? "" : ". " + requirements.joined(separator: ". "))
    }
}

/// Horizontal intent is required as well as distance, so scrolling a long card cannot save or pass it.
enum JobCardSwipe {
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.25
    }

    static func decision(for translation: CGSize) -> Bool? {
        guard isHorizontal(translation), abs(translation.width) > 110 else { return nil }
        return translation.width > 0
    }
}

@MainActor
struct JobCard: View {
    let job: Job
    var embedded = false
    var requirementsDisabled = false
    var onOpen: (() -> Void)?
    var onFilter: (() -> Void)?
    var onDetails: (() -> Void)?
    var onSave: (() -> Void)?
    var onPass: (() -> Void)?
    var accessibilityID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 36
    @ScaledMetric(relativeTo: .title2) private var paySize: CGFloat = 28

    private var copy: JobCardCopy { JobCardCopy(job: job) }

    var body: some View {
        VStack(spacing: 24) {
            header
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(job.title)
                            .font(.system(size: titleSize, weight: .heavy)).tracking(-1.8)
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 16)
                        Text(copy.location)
                            .font(.body).foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 18)
                        if copy.showsPayHeadline {
                            pay
                                .padding(.bottom, copy.payExcerpt.isEmpty ? 30 : 8)
                        }
                        if !copy.payExcerpt.isEmpty {
                            Text(copy.payExcerpt)
                                .font(copy.showsPayHeadline ? .subheadline : .body.weight(.semibold))
                                .foregroundStyle(copy.showsPayHeadline ? Brand.muted : Brand.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, copy.showsPayHeadline ? 24 : 26)
                        }
                        if !copy.tags.isEmpty {
                            Text(copy.tags).font(.body.weight(.semibold)).foregroundStyle(Brand.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 16)
                        }
                        if !copy.roleExcerpt.isEmpty {
                            Text(copy.roleExcerpt).font(.title3).foregroundStyle(Brand.ink)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 26)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(copy.requirements, id: \.self) { requirement in
                                Text(requirement).font(.body).foregroundStyle(Brand.muted)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
                }
                .scrollIndicators(.hidden)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy.accessibilityLabel)
                .accessibilityIdentifier(accessibilityID ?? "job-card-" + job.id)
                .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
                .accessibilityHint(JobListing(job: job) == nil ? "Opens the job details" : "Opens the employer listing")
                .accessibilityAction { onOpen?() }
                .accessibilityActions {
                    if let onDetails { Button("Job details", action: onDetails) }
                    if let onSave { Button("Save", action: onSave) }
                    if let onPass { Button("Pass", action: onPass) }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, embedded ? 0 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Brand.rule, lineWidth: 1))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(job.initial)
                    .font(.body.weight(.semibold)).foregroundStyle(Brand.ink)
                    .frame(width: 40, height: 40)
                    .background(Brand.page, in: Circle())
                    .overlay(Circle().stroke(Brand.rule, lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.company).font(.headline).foregroundStyle(Brand.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !job.posted.isEmpty {
                        Text(job.posted).font(.subheadline).foregroundStyle(Brand.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            .accessibilityHidden(true) // Included in the reading area's complete card label.
            if let onFilter {
                Button(action: onFilter) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(Brand.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(requirementsDisabled)
                .accessibilityLabel("Requirements and job tools")
                .accessibilityIdentifier("job-requirements")
                .padding(.trailing, -10)
                .padding(.top, -8)
            }
        }
    }

    private var pay: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                payAmount.fixedSize()
                if !copy.payPeriod.isEmpty { payUnit.fixedSize() }
            }
            VStack(alignment: .leading, spacing: 4) {
                payAmount
                if !copy.payPeriod.isEmpty { payUnit }
            }
        }
    }

    private var payAmount: some View {
        Text(copy.pay).font(.system(size: paySize, weight: .bold)).tracking(-0.8)
            .foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
    }

    private var payUnit: some View {
        Text(copy.payPeriod).font(.body).foregroundStyle(Brand.muted)
    }
}
