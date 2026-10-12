import SafariServices
import SwiftUI

/// Decides which listing links may open in the in-app browser.
///
/// `SFSafariViewController` raises an exception for a URL that is not http(s), and a link with embedded
/// credentials (`https://user:pass@host`) is a classic spoofing shape, so both are refused up front.
enum JobListingLink {
    static func safeURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: { forbidden.contains($0) }),
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }
}

/// Whether the Jobs screen is only covered by a presentation, not left.
enum JobsLifecycle {
    static func isCovered(listing: JobListing?, detail: Job?, sheet: JobSheet?) -> Bool {
        listing != nil || detail != nil || sheet != nil
    }
}

/// One listing being read in the browser. Identified by the job so a second tap cannot stack another browser.
struct JobListing: Identifiable, Equatable {
    let job: Job
    let url: URL
    var id: String { job.id }

    init?(job: Job) {
        self.init(job: job, link: job.url)
    }

    init?(job: Job, link: String) {
        guard let url = JobListingLink.safeURL(link) else { return nil }
        self.job = job
        self.url = url
    }
}

/// The system browser UI: loading progress, error page with reload, back/forward, share and "Open in Safari"
/// all come from `SFSafariViewController`, so they behave exactly as people expect. It runs out of process, so
/// Stack never sees the page contents, cookies or anything typed into a form.
@MainActor
struct SafariListing: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredBarTintColor = UIColor(Palette.page)
        controller.preferredControlTintColor = UIColor(Palette.dark)
        controller.dismissButtonStyle = .close
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}

extension View {
    /// Presents the listing full screen over the current screen, which stays alive underneath, so its deck,
    /// filters, scroll position and selection are exactly as they were when the browser closes.
    func jobListingBrowser(item: Binding<JobListing?>) -> some View {
        fullScreenCover(item: item) { listing in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--stub-listing-browser") {
                StubListingBrowser(listing: listing) { item.wrappedValue = nil }
            } else {
                SafariListing(url: listing.url) { item.wrappedValue = nil }.ignoresSafeArea()
            }
            #else
            SafariListing(url: listing.url) { item.wrappedValue = nil }.ignoresSafeArea()
            #endif
        }
    }
}

#if DEBUG
/// Stands in for the system browser in offline UI tests that only need Stack's own presentation and state, so
/// they stay deterministic and never load a page. The real browser is exercised separately against loopback
/// fixture pages (`JobListingSafariUITests`).
@MainActor
private struct StubListingBrowser: View {
    let listing: JobListing
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            VStack(spacing: Spacing.group) {
                HStack {
                    BackButton(label: "Close listing", action: onClose)
                    Spacer()
                }
                Text("Stub browser").font(Typeface.title).foregroundStyle(Palette.ink)
                Text(listing.url.absoluteString)
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("stub-browser-url")
                Spacer()
            }
            .padding(Spacing.page)
        }
    }
}
#endif
