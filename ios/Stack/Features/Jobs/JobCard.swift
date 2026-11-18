import SwiftUI
import UIKit

/// Presentation only: use the employer excerpts supplied by the compact feed, never generated fit prose.
struct JobCardCopy {
    let job: Job

    var location: String {
        let region = job.raw["remote_eligibility"].string
        let place = job.location.isBlank || job.location == "Location not listed" ? "" : job.location
        let eligibility = job.mode == "Remote" && !region.isBlank ? "Eligible locations: " + region : ""
        let arrangement = job.mode.isBlank || job.mode == "Unknown" ? job.raw["highlights"]["work_arrangement"].string : job.mode
        return [place.isEmpty && eligibility.isEmpty ? "Location not listed" : place, arrangement, eligibility]
            .filter { !$0.isBlank }.joined(separator: " · ")
    }

    var pay: String { job.salary.isBlank ? "Pay not listed" : job.salary }

    var hasPay: Bool { !job.salary.isBlank && !job.salary.localizedCaseInsensitiveContains("not listed") }

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
        if !job.salary.isBlank && !job.salary.localizedCaseInsensitiveContains("not listed") {
            return job.raw["highlights"]["pay_context"].string
        }
        return job.raw["highlights"]["pay_excerpt"].string
    }

    /// When the employer only states pay in text, show that text in place of a "Pay not listed" headline.
    var showsPayHeadline: Bool {
        payExcerpt.isEmpty || (!job.salary.isBlank && !job.salary.localizedCaseInsensitiveContains("not listed"))
    }

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

    // MARK: Card presentation

    /// Compact meta chips in reading order. Missing values are left out entirely.
    var chips: [JobMetaItem] {
        var items: [JobMetaItem] = []
        let place = job.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !place.isEmpty, place != "Location not listed" { items.append(.init(text: place, tone: .neutral)) }
        let arrangement = job.mode.isBlank || job.mode == "Unknown" ? job.raw["highlights"]["work_arrangement"].string : job.mode
        if !arrangement.isBlank, arrangement != "Unknown" { items.append(.init(text: arrangement, tone: .accent)) }
        if hasPay { items.append(.init(text: [pay, payPeriod].filter { !$0.isEmpty }.joined(separator: " "), tone: .success)) }
        let type = job.raw["employment_type"].string
        if !type.isBlank, type != "Unknown" { items.append(.init(text: type, tone: .neutral)) }
        return items
    }

    /// Up to three short facts: the employer's own duties first, then requirements, then pay and remote scope.
    var bullets: [String] {
        let duties = job.raw["highlights"]["responsibilities"].strings.filter { !$0.isBlank }
        var lines = duties.isEmpty ? (roleExcerpt.isEmpty ? [] : [roleExcerpt]) : Array(duties.prefix(3))
        for requirement in requirements where lines.count < 3 { lines.append(requirement) }
        if lines.count < 3, !showsPayHeadline, !payExcerpt.isEmpty { lines.append(payExcerpt) }
        let region = job.raw["remote_eligibility"].string
        if lines.count < 3, job.mode == "Remote", !region.isBlank { lines.append("Eligible locations: " + region) }
        return lines
    }

    var fit: String { job.fit.trimmingCharacters(in: .whitespacesAndNewlines) }

    var cardTags: [String] { Array(job.tags.filter { !$0.isBlank }.prefix(4)) }

    var accessibilityLabel: String {
        [job.company, job.posted, job.title.isBlank ? "Untitled role" : job.title, location, showsPayHeadline ? pay : "", payPeriod, payExcerpt, tags, roleExcerpt]
            .filter { !$0.isBlank }.joined(separator: ". ")
            + (requirements.isEmpty ? "" : ". " + requirements.joined(separator: ". "))
    }
}

/// A long title stays fully readable in the scrolling body of either job detail sheet.
struct JobHeading: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title.isBlank ? "Untitled role" : job.title)
                .font(Typeface.title).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
            let metadata = [job.company, job.location].filter { !$0.isBlank }.joined(separator: " · ")
            if !metadata.isEmpty { Text(metadata).font(Typeface.body).foregroundStyle(Palette.muted) }
        }
    }
}

/// Horizontal intent is required as well as distance, so scrolling a long card cannot save or pass it.
enum JobCardSwipe {
    static let threshold: CGFloat = 110

    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * 1.25
    }

    static func decision(for translation: CGSize) -> Bool? {
        guard isHorizontal(translation), abs(translation.width) > threshold else { return nil }
        return translation.width > 0
    }
}

struct JobMetaItem: Hashable {
    enum Tone: Hashable { case neutral, accent, success }
    let text: String
    let tone: Tone
}

/// A small tinted capsule for one fact about the role.
struct JobMetaChip: View {
    let item: JobMetaItem

    var body: some View {
        Text(item.text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch item.tone {
        case .neutral: return Brand.ink
        case .accent: return Brand.accent
        case .success: return Palette.success
        }
    }

    private var background: Color {
        switch item.tone {
        case .neutral: return Palette.muted.opacity(0.12)
        case .accent: return Palette.halo
        case .success: return Palette.success.opacity(0.13)
        }
    }
}

/// Takes its content's natural height up to `limit`; taller content is cut off (and faded by the caller).
struct JobHeightCap: Layout {
    var limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let size = view.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

@MainActor
struct JobCard: View {
    let job: Job
    var isActive = true
    var preferredLocation = ""
    var onOpen: (() -> Void)?
    var onDetails: (() -> Void)?
    var onSave: (() -> Void)?
    var onPass: (() -> Void)?
    var accessibilityID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let cornerRadius: CGFloat = Radius.card + 6

    private var copy: JobCardCopy { JobCardCopy(job: job) }
    private var largeText: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cardBody
            if isActive, let onDetails {
                Button(action: onDetails) {
                    Image(systemName: "info")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.9, dim: 1))
                .accessibilityLabel("Job details")
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private var cardBody: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                hero
                    .frame(minHeight: geometry.size.height * (largeText ? 0.2 : 0.36))
                    .layoutPriority(-1)
                    .allowsHitTesting(false)
                JobHeightCap(limit: geometry.size.height * (largeText ? 0.72 : 0.58)) { details }
                    .layoutPriority(1)
                    .clipped()
                    .mask {
                        VStack(spacing: 0) {
                            Rectangle().fill(.black)
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        }
                    }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Palette.surface)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.accessibilityLabel)
        .accessibilityIdentifier(accessibilityID ?? "job-card-" + job.id)
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityHint((onSave != nil && onPass != nil
            ? "Opens the listing. Swipe up or down for Save, Pass, and Details."
            : "Opens the listing.") + (copy.fit.isEmpty ? "" : " Why it fits: " + copy.fit))
        .accessibilityAction { onOpen?() }
        .accessibilityActions {
            if let onDetails { Button("Job details", action: onDetails) }
            if let onSave { Button("Save", action: onSave) }
            if let onPass { Button("Pass", action: onPass) }
        }
        .accessibilityHidden(!isActive)
    }

    // MARK: Hero

    /// The photo takes whatever height the details leave, with the employer on a soft scrim at its foot.
    private var hero: some View {
        Palette.rule
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { photo }
            .overlay(alignment: .bottom) {
                company
                    .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 56)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
            }
            .clipped()
    }

    private var photo: some View {
        let id = JobPhoto.id(for: job, preferredLocation: preferredLocation)
        let image = UIImage(named: "job-photo-" + id + ".jpg") ?? UIImage(named: "job-photo-forest.jpg")
        return Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Brand.page
            }
        }
    }

    private var company: some View {
        HStack(spacing: 12) {
            logoTile
            VStack(alignment: .leading, spacing: 1) {
                Text(job.company.isBlank ? "Company not listed" : job.company)
                    .font(.headline).foregroundStyle(.white)
                    .lineLimit(largeText ? 3 : 1)
                if !job.posted.isBlank {
                    Text(job.posted).font(.caption).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var logoTile: some View {
        let tint = Palette.tint(for: job.company)
        return Group {
            if let image = JobLogoImages.image(job) {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            } else {
                Text(job.initial)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(tint.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.fill)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(job.title.isBlank ? "Untitled role" : job.title)
                .font(.title.weight(.bold)).tracking(-0.6)
                .foregroundStyle(Brand.ink)
                .lineLimit(3).minimumScaleFactor(0.85)
                .accessibilityAddTraits(.isHeader)
            let chips = copy.chips
            if !chips.isEmpty {
                FlowLayout(spacing: 6) { ForEach(chips, id: \.self) { JobMetaChip(item: $0) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            }
            if !copy.fit.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(Brand.accent)
                    Text(copy.fit).font(.subheadline).foregroundStyle(Brand.ink).lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.halo, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .padding(.top, 14)
            }
            let bullets = copy.bullets
            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(bullets, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Brand.accent.opacity(0.7)).frame(width: 5, height: 5).offset(y: -2)
                            Text(line).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.88)).lineLimit(2)
                        }
                    }
                }
                .padding(.top, 16)
            }
            let tags = copy.cardTags
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag).font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(Palette.rule, lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The card's shape while the deck loads, so nothing jumps when the first role arrives.
@MainActor
struct JobCardSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.rule.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 12) {
                        SkeletonBlock(width: 42, height: 42, radius: 12)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: 130, height: 14)
                            SkeletonBlock(width: 80, height: 11)
                        }
                    }
                    .padding(20)
                }
                .shimmer()
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBlock(height: 24, radius: 8)
                SkeletonBlock(width: 190, height: 24, radius: 8)
                HStack(spacing: 6) {
                    SkeletonBlock(width: 84, height: 26, radius: 13)
                    SkeletonBlock(width: 66, height: 26, radius: 13)
                    SkeletonBlock(width: 100, height: 26, radius: 13)
                }
                .padding(.top, 2)
                SkeletonBlock(height: 14)
                SkeletonBlock(width: 240, height: 14)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
        }
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: JobCard.cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading jobs")
    }
}

/// Fades in with drag distance: a tinted edge glow and a SAVE or PASS stamp. Decorative only.
struct JobSwipeStamp: View {
    /// Horizontal drag in points; positive saves, negative passes.
    let offset: CGFloat

    private var amount: CGFloat { min(max((abs(offset) - 14) / (JobCardSwipe.threshold - 14), 0), 1) }
    private var saving: Bool { offset > 0 }
    private var tint: Color { saving ? Palette.success : Palette.danger }

    var body: some View {
        ZStack(alignment: saving ? .topLeading : .topTrailing) {
            LinearGradient(colors: [tint.opacity(0.34), tint.opacity(0)],
                           startPoint: saving ? .leading : .trailing,
                           endPoint: saving ? .trailing : .leading)
                .opacity(amount)
            HStack(spacing: 6) {
                Image(systemName: saving ? "bookmark.fill" : "xmark")
                Text(saving ? "SAVE" : "PASS").tracking(1.5)
            }
            .font(.system(.title3, design: .rounded).weight(.heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint, lineWidth: 2.5))
            .rotationEffect(.degrees(saving ? -10 : 10))
            .scaleEffect(0.82 + 0.18 * amount)
            .opacity(amount)
            .padding(.top, 64).padding(.horizontal, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Keep the normalized employer PNG decoded while a card follows a finger at display refresh rate.
@MainActor
enum JobLogoImages {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    static func image(_ job: Job) -> UIImage? {
        let png = job.logoPNG
        if !png.isEmpty {
            if let image = cache.object(forKey: png as NSString) { return image }
            if let data = Data(base64Encoded: png), let image = UIImage(data: data) {
                cache.setObject(image, forKey: png as NSString)
                return image
            }
        }
        guard let domain = JobBrand.domain(for: job) else { return nil }
        return UIImage(named: domain + ".png")
    }
}
