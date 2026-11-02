import SwiftUI

@MainActor
struct GmailScanView: View {
    @Environment(AppStore.self) private var store
    @State private var since = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var scan: JSON = [:]
    @State private var reviews: [JSON] = []
    @State private var error = ""
    @State private var busy = false
    @State private var loading = true

    private var scanning: Bool { ["queued", "running"].contains(scan["status"].string) }
    private var resumable: Bool { ["failed", "needs_input", "blocked"].contains(scan["status"].string) }

    var body: some View {
        SheetPage(title: "Find your applications.", subtitle: "Including jobs you applied to outside Stack.") {
            if loading {
                ProgressView("Loading Gmail scan…")
            } else {
                if scanning {
                    Text("Scanning Gmail…").font(Typeface.option).foregroundStyle(Brand.ink)
                    ProgressView()
                    Text("You can close this screen. The scan will keep going.")
                        .font(Typeface.body).foregroundStyle(Brand.muted)
                    QuietLinks(links: [ScreenLink("Stop scan") { Task { await stop() } }])
                        .disabled(busy)
                } else if resumable {
                    PrimaryPill(title: "Resume scan", icon: "arrow.clockwise", disabled: busy) {
                        Task { await resume() }
                    }
                    QuietLinks(links: [ScreenLink("New scan") { scan = [:] }])
                } else {
                    DatePicker("Search since", selection: $since, in: Date(timeIntervalSince1970: 0)...Date(), displayedComponents: .date)
                        .tint(Brand.accent)
                    Text("Find application confirmations, status updates and interview invitations from this date through today.")
                        .font(Typeface.body).foregroundStyle(Brand.muted)
                    PrimaryPill(title: "Start scan", icon: "magnifyingglass", disabled: busy) {
                        Task { await start() }
                    }
                }
                if !scan.object.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !scanning {
                            Text(scan["status"].string == "completed" ? "Scan complete." : scan["message"].string)
                                .font(Typeface.option).foregroundStyle(Brand.ink)
                        }
                        Text("\(scan["scan"]["scanned"].int) emails checked · \(scan["scan"]["imported"].int) imported · \(scan["scan"]["updated"].int) updates")
                            .font(Typeface.caption).foregroundStyle(Brand.muted)
                        Text("Imported applications are tracked automatically. Interview invitations appear in your Stack calendar; Google Calendar changes still wait for your approval.")
                            .font(Typeface.caption).foregroundStyle(Brand.muted)
                    }
                }
                MessageLine(text: error).fadeSwitch(!error.isEmpty)
                if !reviews.isEmpty {
                    Text("A few need a check.").font(Typeface.title).foregroundStyle(Brand.ink)
                    ForEach(reviews, id: \.["id"].string) { event in
                        GmailScanReviewRow(event: event) { await load() }
                    }
                }
            }
        }
        .replayable()
        .task {
            await load()
            loading = false
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
                if scanning { await load(); await store.refresh() }
            }
        }
    }

    private func apply(_ value: JSON) {
        scan = value["scan"]
        reviews = value["reviews"].array
    }

    private func load() async {
        do { apply(try await store.call("gmail_scan_status")); error = "" }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func start() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            apply(try await store.call("gmail_scan_start", ["since": .number(Calendar.current.startOfDay(for: since).timeIntervalSince1970)]))
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func stop() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { try await store.call("agent_cancel", ["id": scan["id"]]); await load() }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func resume() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do { try await store.call("agent_retry", ["id": scan["id"]]); await load() }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

@MainActor
private struct GmailScanReviewRow: View {
    let event: JSON
    let onChanged: () async -> Void
    @Environment(AppStore.self) private var store
    @State private var applicationID = ""
    @State private var company = ""
    @State private var title = ""
    @State private var status = "Submitted"
    @State private var seeded = false
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Brand.rule)
            Text(event["subject"].string).font(Typeface.option).foregroundStyle(Brand.ink)
            Text(String((event["quote"].string.isEmpty ? event["excerpt"].string : event["quote"].string).prefix(600)))
                .font(Typeface.caption).foregroundStyle(Brand.muted)
            Picker("Application", selection: $applicationID) {
                Text("Import a new application").tag("")
                ForEach(store.account.applications.filter { !$0.isDemo }) { app in
                    Text("\(app.job.company) · \(app.job.title)").tag(app.id)
                }
            }
            if applicationID.isEmpty {
                StackField(label: "Company", text: $company)
                StackField(label: "Job title", text: $title)
            }
            Picker("Status", selection: $status) {
                ForEach(["Submitted", "Assessment", "Interview", "Offer", "Rejected"], id: \.self) { Text($0).tag($0) }
            }
            StackButton(label: applicationID.isEmpty ? "Import application" : "Save update",
                        disabled: busy || (applicationID.isEmpty && (company.isBlank || title.isBlank))) {
                Task { await save() }
            }
            QuietLinks(links: [ScreenLink("Not an application") { Task { await ignore() } }]).disabled(busy)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .task {
            guard !seeded else { return }
            seeded = true
            company = event["discovery"]["company"].string
            title = event["discovery"]["title"].string
            if !event["status"].string.isEmpty { status = event["status"].string }
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            try await store.call("agent_resolve_event", ["id": event["id"], "application_id": .string(applicationID),
                                 "status": .string(status), "company": .string(company), "title": .string(title)])
            await store.refresh()
            await onChanged()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func ignore() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do { try await store.call("gmail_scan_dismiss", ["id": event["id"]]); await onChanged() }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}
