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
struct SafariListingPresenter: UIViewControllerRepresentable {
    @Binding var item: JobListing?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        context.coordinator.anchor = anchor
        anchor.onAppear = { [weak coordinator = context.coordinator] in coordinator?.synchronize() }
        return anchor
    }

    func updateUIViewController(_ controller: Anchor, context: Context) {
        context.coordinator.selection = item
        context.coordinator.clearSelection = { item = nil }
        context.coordinator.synchronize()
    }

    static func dismantleUIViewController(_ controller: Anchor, coordinator: Coordinator) {
        controller.onAppear = nil
        coordinator.tearDown()
    }

    final class Anchor: UIViewController {
        var onAppear: (() -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, SFSafariViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
        weak var anchor: Anchor?
        var selection: JobListing?
        var clearSelection: (() -> Void)?
        private var browser: SFSafariViewController?
        private var presentedID: String?
        private var dismissing = false
        private var removed = false

        func synchronize() {
            guard !removed, !dismissing else { return }
            if browser != nil {
                if selection?.id != presentedID { dismiss(clear: false) }
                return
            }
            guard let selection, let anchor, anchor.viewIfLoaded?.window != nil,
                  anchor.presentedViewController == nil else { return }
            let configuration = SFSafariViewController.Configuration()
            configuration.entersReaderIfAvailable = false
            configuration.barCollapsingEnabled = true
            let controller = SFSafariViewController(url: selection.url, configuration: configuration)
            controller.preferredBarTintColor = UIColor(Palette.page)
            controller.preferredControlTintColor = UIColor(Palette.dark)
            controller.dismissButtonStyle = .close
            controller.modalPresentationStyle = .fullScreen
            controller.delegate = self
            browser = controller
            presentedID = selection.id
            trace("present")
            // Safari must be presented modally, never embedded as a child of a SwiftUI cover.
            anchor.present(controller, animated: true)
            controller.presentationController?.delegate = self
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            guard controller === browser else { return }
            trace("native close callback")
            dismiss(clear: true)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === browser else { return }
            finishDismissal(clear: true)
        }

        private func dismiss(clear: Bool) {
            guard !dismissing, let browser else { return }
            dismissing = true
            trace("dismiss begin")
            browser.dismiss(animated: true) { [weak self] in self?.finishDismissal(clear: clear) }
        }

        private func finishDismissal(clear: Bool) {
            guard browser != nil else { return }
            let closedID = presentedID
            browser = nil
            presentedID = nil
            // Retain coverage state until UIKit finishes, so deck cleanup cannot run during dismissal.
            if clear, selection?.id == closedID {
                selection = nil
                clearSelection?()
            }
            dismissing = false
            trace("dismiss complete")
            synchronize()
        }

        func tearDown() {
            removed = true
            clearSelection = nil
            browser?.delegate = nil
            browser?.dismiss(animated: false)
            browser = nil
            presentedID = nil
        }

        private func trace(_ event: String) {
            #if DEBUG
            print("Stack listing browser lifecycle: \(event)")
            #endif
        }
    }
}

extension View {
    /// Presents the listing full screen over the current screen, which stays alive underneath, so its deck,
    /// filters, scroll position and selection are exactly as they were when the browser closes.
    @ViewBuilder
    func jobListingBrowser(item: Binding<JobListing?>) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--stub-listing-browser") {
            fullScreenCover(item: item) { listing in
                StubListingBrowser(listing: listing) { item.wrappedValue = nil }
            }
        } else {
            background(SafariListingPresenter(item: item).frame(width: 0, height: 0))
        }
        #else
        background(SafariListingPresenter(item: item).frame(width: 0, height: 0))
        #endif
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
