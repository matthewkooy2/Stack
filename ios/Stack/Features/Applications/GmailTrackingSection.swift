import SwiftUI

/// The same one-tap setup in Applications and the email settings page.
@MainActor
struct GmailTrackingSection: View {
    @Environment(AppStore.self) private var store
    var onManage: (() -> Void)?
    var onConnected: (() async -> Void)?
    @State private var connecting = false
    @State private var error = ""
    @State private var showScan = false

    private var feature: AgentFeature? { store.account.feature("email") }
    private var connected: Bool { feature?.state == "ready" }
    private var unavailable: Bool { feature?.state == "unavailable" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connected {
                Label("Gmail connected", systemImage: "checkmark.circle")
                    .font(.headline).foregroundStyle(Brand.ink)
            } else {
                Text("Import applications and track replies from Gmail.")
                    .font(Typeface.body).foregroundStyle(Brand.muted)
            }
            if connected {
                PrimaryPill(title: "Scan Gmail", icon: "magnifyingglass") { showScan = true }
                if let onManage { QuietLinks(links: [ScreenLink("Manage connection", action: onManage)]) }
            } else {
                PrimaryPill(title: connecting ? "Connecting…" : "Connect Gmail", icon: "envelope",
                            disabled: connecting || unavailable || store.busy) {
                    Task { await connect() }
                }
                if unavailable {
                    Text("Gmail is unavailable. Try again later.")
                        .font(Typeface.caption).foregroundStyle(Brand.muted)
                }
                DisclosureGroup("What can Stack read?") {
                    Text("Google grants mailbox read access. Stack processes messages about your applications and selected contacts only.")
                        .font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 8)
                }
                .font(Typeface.caption).foregroundStyle(Brand.muted)
            }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .replayable()
        .sheet(isPresented: $showScan) { GmailScanView().environment(store) }
    }

    private func connect() async {
        guard !connecting else { return }
        connecting = true
        error = ""
        defer { connecting = false }
        do {
            try await store.googleConnection.connect(["read"])
            try await store.callAccount("bootstrap")
            guard connected else { throw APIError(message: "Gmail tracking could not finish. Try connecting again.") }
            await onConnected?()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}
