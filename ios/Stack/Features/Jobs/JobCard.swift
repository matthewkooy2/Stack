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
    var isActive = true
    var preferredLocation = ""
    var onOpen: (() -> Void)?
    var onDetails: (() -> Void)?
    var onSave: (() -> Void)?
    var onPass: (() -> Void)?
    var accessibilityID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var copy: JobCardCopy { JobCardCopy(job: job) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                photo
                    .frame(width: geometry.size.width,
                           height: min(geometry.size.width * 0.36, geometry.size.height * (dynamicTypeSize.isAccessibilitySize ? 0.16 : 0.26)))
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        company.padding(.bottom, 12)
                        Text(job.title.isBlank ? "Untitled role" : job.title)
                            .font(.title.weight(.bold)).tracking(-0.6)
                            .accessibilityAddTraits(.isHeader)
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 10)
                        Label(copy.location, systemImage: "mappin")
                            .font(.subheadline).foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if !employment.isEmpty {
                            Label(employment, systemImage: "briefcase").font(.subheadline).foregroundStyle(Brand.muted)
                                .padding(.top, 6)
                        }
                        if copy.showsPayHeadline {
                            Text([copy.pay, copy.payPeriod].filter { !$0.isEmpty }.joined(separator: " "))
                                .font(payIsMissing ? .subheadline : .title3.weight(.semibold))
                                .foregroundStyle(payIsMissing ? Brand.muted : Brand.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 12)
                        }
                        if !copy.payExcerpt.isEmpty {
                            Text(copy.payExcerpt).font(.subheadline).foregroundStyle(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 12)
                        }
                        if !copy.roleExcerpt.isEmpty || !copy.requirements.isEmpty {
                            Divider().padding(.vertical, 16)
                            if !copy.roleExcerpt.isEmpty {
                                Text(copy.roleExcerpt).font(.body).foregroundStyle(Brand.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !copy.requirements.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(copy.requirements, id: \.self) { requirement in
                                        Text(requirement).font(.subheadline).foregroundStyle(Brand.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.padding(.top, 16)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .scrollIndicators(.hidden)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy.accessibilityLabel)
                .accessibilityIdentifier(accessibilityID ?? "job-card-" + job.id)
                .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
                .accessibilityHint(onSave != nil && onPass != nil
                    ? "Opens the employer listing. Swipe up or down for Save, Pass, and Job details."
                    : "Opens the employer listing.")
                .accessibilityAction { onOpen?() }
                .accessibilityActions {
                    if let onDetails { Button("Job details", action: onDetails) }
                    if let onSave { Button("Save", action: onSave) }
                    if let onPass { Button("Pass", action: onPass) }
                }
                .accessibilityHidden(!isActive)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.surface)
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }

        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var employment: String {
        let type = job.raw["employment_type"].string
        return type.isBlank || type == "Unknown" ? "" : type
    }

    private var payIsMissing: Bool {
        job.salary.isBlank || job.salary.localizedCaseInsensitiveContains("not listed")
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
            Group {
                if let image = JobLogoImages.image(job) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text(job.initial).font(.title2.weight(.semibold)).foregroundStyle(Brand.ink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.page)
                }
            }
            .frame(width: 36, height: 36)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(job.company.isBlank ? "Company not listed" : job.company)
                .font(.headline)
                .foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            if !job.posted.isBlank && !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 4)
                Text(job.posted).font(.caption).foregroundStyle(Brand.muted).multilineTextAlignment(.trailing)
            }
        }
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
