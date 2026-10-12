import SwiftUI

/// A deck of roles. Drag a card right to save it, left to pass; the buttons do the same.
@MainActor
struct JobsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var onProfile: () -> Void

    @State private var feed = JobDeckFeed()
    @State var drag: CGSize = .zero
    @State var hidden: Set<String> = []
    @State var detail: Job?
    @State var listing: JobListing?
    @State var search = JobSearch()
    @State var sheet: JobSheet?
    @State var started = false
    @State var importID = ""
    @State var banner = ""
    @State private var pendingDecision: (job: Job, save: Bool, generation: Int)?
    @State private var undoTimer: Task<Void, Never>?
    @State private var leavingID: String?

    private var deck: [Job] {
        let decided = store.account.decidedJobIDs
        return feed.jobs.filter { !decided.contains($0.id) && !hidden.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.option) {
            ScreenHeader(title: "Jobs", subtitle: deck.isEmpty ? "" : "\(deck.count) to review", onProfile: onProfile)
                .padding(.horizontal, Spacing.page)
                .reveal(0)
            JobSearchBar(search: search, sheet: $sheet, disabled: feed.busy,
                         onChange: { query, filters in
                             let event = reserveChange()
                             Task { await applySearch(event, query: query, filters: filters) }
                         },
                         onReset: {
                             let event = reserveChange()
                             Task { await resetSearch(event) }
                         })
            if let pending = pendingDecision {
                HStack {
                    Text(pending.save ? "Saved \(pending.job.title)" : "Passed \(pending.job.title)")
                        .font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(2)
                    Spacer()
                    Chip(label: "Undo") { undoDecision() }
                }.padding(.horizontal, Spacing.page)
            }
            if !feed.loadError.isEmpty || !banner.isEmpty || !search.notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MessageLine(text: feed.loadError).fadeSwitch(!feed.loadError.isEmpty && deck.first != nil)
                    MessageLine(text: banner, isError: false).fadeSwitch(!banner.isEmpty)
                    ForEach(search.notices, id: \.self) { MessageLine(text: $0) }
                }
                .padding(.horizontal, Spacing.page)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 8)
        .task { await start() }
        .task(id: importID) { await watchImport() }
        .onDisappear {
            // A full-screen cover reports the screen underneath as disappeared. It is still the same visit:
            // keep the pending Undo and the paging in flight until the browser or sheet closes.
            guard !JobsLifecycle.isCovered(listing: listing, detail: detail, sheet: sheet) else { return }
            commitDecision()
            feed.cancel()
        }
        .onChange(of: listing) { old, new in
            // Paging that stopped short while the browser was open picks up again.
            guard old != nil, new == nil, feed.loaded, !feed.nextCursor.isEmpty, !feed.busy,
                  deck.count < JobDeckFeed.targetDeck else { return }
            Task { await load(refresh: false, more: true) }
        }
        .onChange(of: store.sessionGeneration) { _, _ in resetForSession() }
        .onChange(of: store.phase) { _, phase in if phase != .ready { resetForSession() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { commitDecision() } }
        .onReceive(NotificationCenter.default.publisher(for: .stackProfileSaved)) { _ in
            let event = reserveChange()
            Task { await profileSaved(event) }
        }
        .sheet(item: $detail) { job in JobDetailView(job: job).environment(store) }
        .jobListingBrowser(item: $listing)
        .sheet(item: $sheet) { value in
            switch value {
            case .filters:
                JobFiltersSheet(search: search) { query, filters in
                    let event = reserveChange()
                    return { await applySearch(event, query: query, filters: filters) }
                }
                    .environment(store)
            case .timeline:
                JobTimelineSheet(graduation: store.account.graduationMonth, availableFrom: store.account.availableFrom) {
                    sheet = nil
                    await load(refresh: false)
                }
                .environment(store)
            case .sources:
                JobSourcesSheet().environment(store)
            case .importLink:
                JobImportSheet { id in
                    importID = id
                    banner = "Link queued for verification. It will appear only if a supported, active US job is found."
                    sheet = nil
                }
                .environment(store)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !feed.loaded {
            VStack { ProgressView().tint(Palette.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let top = deck.first {
            VStack(spacing: 20) {
                ZStack {
                    ForEach(Array(deck.prefix(3).enumerated().reversed()), id: \.element.id) { offset, job in
                        let canOpenListing = JobListing(job: job) != nil
                        JobCard(job: job)
                            .scaleEffect(1 - CGFloat(offset) * 0.04)
                            .offset(y: CGFloat(offset) * 12)
                            .offset(offset == 0 ? drag : .zero)
                            .rotationEffect(.degrees(offset == 0 ? Double(drag.width / 18) : 0))
                            .overlay(alignment: .topLeading) {
                                if offset == 0 { stamp(for: drag.width).accessibilityHidden(true) }
                            }
                            .gesture(swipe(top), including: offset == 0 ? .all : .none)
                            .onTapGesture { if offset == 0 { open(job) } }
                            .accessibilityHidden(offset != 0)
                            .accessibilityIdentifier("job-card-" + job.id)
                            .accessibilityHint(canOpenListing ? "Opens the listing" : "Opens the job details")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityActions {
                                // A job without a safe link has no browser to open; its tap goes to details.
                                if canOpenListing { Button("Open listing") { open(job) } }
                                Button("Job details") { detail = job }
                            }
                            .accessibilityAction(named: "Save") { decide(top, save: true) }
                            .accessibilityAction(named: "Pass") { decide(top, save: false) }
                    }
                }
                .padding(.horizontal, Spacing.page)
                .frame(maxHeight: .infinity)
                HStack(spacing: 18) {
                    roundButton(icon: "pass", label: "Pass") { decide(top, save: false) }
                    roundButton(icon: "details", label: "Job details", size: 52) { detail = top }
                    roundButton(icon: "save", label: "Save", filled: true) { decide(top, save: true) }
                }
                .padding(.bottom, 12)
            }
        } else {
            VStack(spacing: 14) {
                EmptyNote(
                    icon: "sparkles",
                    title: emptyTitle,
                    message: emptyMessage
                )
                if search.missingGraduation {
                    StackButton(label: "Set graduation", icon: "clock") { sheet = .timeline }
                } else if !feed.nextCursor.isEmpty {
                    StackButton(label: "Load more roles", icon: "refresh", disabled: feed.busy) {
                        Task { await load(refresh: false, more: true) }
                    }
                } else {
                    StackButton(label: "Refresh jobs", icon: "refresh", disabled: feed.busy) {
                        Task { await load(refresh: true) }
                    }
                }
                StackButton(label: "Import a job link", kind: .secondary) { sheet = .importLink }
            }
            .padding(.horizontal, Spacing.page)
            Spacer()
        }
    }

    private var emptyTitle: String {
        if !feed.loadError.isEmpty { return "Could not load roles" }
        if search.missingGraduation { return "Add your graduation month" }
        if !feed.nextCursor.isEmpty { return "More roles to review" }
        if search.filters["timeline"].string == "confirmed" { return "No confirmed timeline matches." }
        return "You are all caught up"
    }

    private var emptyMessage: String {
        if !feed.loadError.isEmpty { return feed.loadError }
        if search.missingGraduation {
            return "Add your graduation month so timelines can be confirmed, or relax the timeline in Filters."
        }
        if !feed.nextCursor.isEmpty { return "More verified roles are ready." }
        if search.filters["timeline"].string == "confirmed" {
            return "Many listings do not state a graduation window. Relax the timeline in Filters to see them."
        }
        if !search.excluded.isEmpty {
            let reasons = search.excluded.prefix(4).map { "\($0["reason"].string) (\($0["count"].int))" }.joined(separator: ", ")
            return "Hidden by your requirements: \(reasons). Mark some as nice to have to see them ranked lower."
        }
        return "New verified roles appear here as they are found."
    }

    /// A tap reads the listing in the in-app browser; a job without a safe web link opens its details instead.
    private func open(_ job: Job) {
        guard listing == nil, detail == nil, leavingID == nil else { return }
        if let next = JobListing(job: job) { listing = next } else { detail = job }
    }

    private func roundButton(icon: String, label: String, filled: Bool = false, size: CGFloat = 68,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlyphView(name: icon, size: size > 60 ? 26 : 22, color: filled ? Palette.onDark : Palette.icon)
                .frame(width: size, height: size)
                .background(filled ? Palette.dark : Palette.button, in: Circle())
        }
        .buttonStyle(.tap(scale: 0.92))
        .accessibilityLabel(label)
    }

    private func stamp(for width: CGFloat) -> some View {
        let saving = width > 0
        let label: Text = Text(saving ? "SAVE" : "PASS")
            .font(Font.system(.headline, design: .rounded).weight(.heavy))
        return label.foregroundStyle(saving ? Palette.success : Palette.danger)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(saving ? Palette.success : Palette.danger, lineWidth: 2))
            .rotationEffect(.degrees(saving ? -10 : 10))
            .padding(22)
            .opacity(min(Double(abs(width)) / 110.0, 1.0))
    }

    private func swipe(_ job: Job) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if value.translation.width > 110 { decide(job, save: true) }
                else if value.translation.width < -110 { decide(job, save: false) }
                else { withAnimation(Motion.release) { drag = .zero } }
            }
    }

    private func decide(_ job: Job, save: Bool) {
        guard !hidden.contains(job.id), leavingID == nil else { return }
        commitDecision()
        leavingID = job.id
        let generation = store.sessionGeneration
        withAnimation(reduceMotion ? nil : Motion.ease(0.26)) { drag = CGSize(width: save ? 700 : -700, height: 40) }
        Task {
            defer { leavingID = nil }
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 230))
            guard generation == store.sessionGeneration, store.phase == .ready, !Task.isCancelled else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                hidden.insert(job.id)
                drag = .zero
            }
            pendingDecision = (job, save, generation)
            if scenePhase != .active { commitDecision(); return }
            undoTimer = Task {
                do { try await Task.sleep(for: undoWindow) } catch { return }
                guard !Task.isCancelled else { return }
                commitDecision()
            }
        }
    }

    /// How long Undo stays offered. UI tests lengthen it so a slow machine cannot expire it mid-assertion.
    private var undoWindow: Duration {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--long-undo-window") { return .seconds(60) }
        #endif
        return .milliseconds(2400)
    }

    private func undoDecision() {
        guard let pending = pendingDecision else { return }
        undoTimer?.cancel()
        undoTimer = nil
        pendingDecision = nil
        withAnimation(reduceMotion ? nil : Motion.release) { _ = hidden.remove(pending.job.id) }
    }

    private func commitDecision() {
        guard let pending = pendingDecision else { return }
        pendingDecision = nil
        undoTimer?.cancel()
        undoTimer = nil
        guard pending.generation == store.sessionGeneration, store.phase == .ready else { return }
        Task {
            let saved = await store.swipe(jobID: pending.job.id, save: pending.save)
            guard pending.generation == store.sessionGeneration else { return }
            if !saved {
                withAnimation(reduceMotion ? nil : Motion.release) { _ = hidden.remove(pending.job.id) }
                feed.loadError = store.error.isEmpty ? "This decision was not saved. Please try again." : store.error
            }
        }
    }

    /// Applies the saved search (profile defaults plus its overrides) and queues collection once.
    /// Coming back after the view was torn down only reloads when nothing was ever shown.
    private func start() async {
        if started {
            if !feed.loaded { await load(refresh: false) }
            return
        }
        started = true
        search.adopt(saved: store.account.savedSearch)
        await load(refresh: true)
    }

    /// Called synchronously from the user's event, so the place in line and the account it belongs to are both
    /// fixed before any task starts. A task that begins after the session changed is rejected by the feed.
    private func reserveChange() -> JobChangeEvent {
        JobChangeEvent(ticket: feed.reserveChange(), generation: store.sessionGeneration)
    }

    /// Another account or a signed-out session must never keep paging or showing the previous deck.
    private func resetForSession() {
        feed.invalidate(clearing: true)
        hidden = []
    }

    /// A profile edit may have cleared saved overrides (a changed role drops the query and any_role).
    /// Paging stops at once; the account's refreshed saved search is adopted when the gate is free.
    private func profileSaved(_ event: JobChangeEvent) async {
        commitDecision()
        await feed.change(ticket: event.ticket, refresh: false, clearing: false, isCurrent: { isCurrent(event.generation) }, makeSource: { makeSource() },
                          accepted: { search.adopt(saved: store.account.savedSearch) })
    }

    private func applySearch(_ event: JobChangeEvent, query: String, filters: JSON) async {
        commitDecision()
        var stored: JSON = .null
        await feed.change(ticket: event.ticket, refresh: true, clearing: true, isCurrent: { isCurrent(event.generation) }, makeSource: { makeSource() },
                          save: { stored = try await store.call("save_search", ["query": .string(query), "filters": filters]) },
                          accepted: {
            search.adopt(saved: stored)
            store.account.raw["saved_search"] = ["query": .string(search.query), "filters": search.filters]
            hidden = []
            sheet = nil
        })
    }

    private func resetSearch(_ event: JobChangeEvent) async {
        commitDecision()
        await feed.change(ticket: event.ticket, refresh: true, clearing: true, isCurrent: { isCurrent(event.generation) }, makeSource: { makeSource() },
                          save: { try await store.call("reset_search") },
                          accepted: {
            search.adopt(saved: [:])
            store.account.raw["saved_search"] = ["query": "", "filters": [:]]
            hidden = []
        })
    }

    /// Follows an imported link until the server has verified it or given up.
    private func watchImport() async {
        guard !importID.isEmpty else { return }
        let id = importID
        var polls = 0
        while !Task.isCancelled, polls < 40 {
            polls += 1
            do {
                let result = try await store.call("get_import_status", ["id": .string(id)])
                let status = result["status"].string
                banner = "Import: \(status). \(result["message"].string)"
                if ["complete", "review", "error"].contains(status) {
                    importID = ""
                    await load(refresh: false)
                    return
                }
            } catch {
                if !(error is CancellationError) { feed.loadError = error.localizedDescription }
                importID = ""
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == store.sessionGeneration && store.phase == .ready
    }

    /// Captures the search as it is now, so a page can never be requested with filters that were replaced mid-flight.
    private func makeSource() -> JobDeckSource {
        let generation = store.sessionGeneration
        let query = search.query, filters = search.filters
        return JobDeckSource(
            fetch: { [store] cursor, refresh in
                try await store.api.call("search_jobs", [
                    "query": .string(query), "filters": filters, "refresh": .bool(refresh), "cursor": .string(cursor),
                ])
            },
            deckCount: { deck.count },
            isCurrent: { isCurrent(generation) },
            received: { search.apply($0) },
            animate: { change in withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { change() } })
    }

    func load(refresh: Bool, more: Bool = false) async {
        guard store.phase == .ready else { return }
        await feed.load(refresh: refresh, more: more, source: makeSource())
    }
}

/// A search or profile change as the person made it: its queue ticket and the session it belongs to.
struct JobChangeEvent {
    let ticket: Int
    let generation: Int
}

@MainActor
struct JobCard: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Avatar(initials: job.initial, tint: Palette.halo, size: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.company).font(Typeface.section).foregroundStyle(Palette.ink)
                    if !job.posted.isEmpty { Text(job.posted).font(Typeface.caption).foregroundStyle(Palette.muted) }
                }
            }
            Text(job.title)
                .font(Typeface.display).tracking(-0.8).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !job.location.isEmpty { Label(job.location, systemImage: "mappin.and.ellipse") }
                if !job.mode.isEmpty { Text("· \(job.mode)") }
            }
            .font(Typeface.caption).foregroundStyle(Palette.muted)
            if !job.salary.isEmpty { Text(job.salary).font(Typeface.body).foregroundStyle(Palette.text) }
            if !job.fit.isEmpty || !job.reason.isEmpty {
                Text(job.fit.isEmpty ? job.reason : job.fit)
                    .font(Typeface.body).foregroundStyle(Palette.text)
                    .lineLimit(3)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if !job.tags.isEmpty {
                FlowLayout(spacing: 8) { ForEach(job.tags.prefix(3), id: \.self) { Chip(label: $0) } }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Palette.rule, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct JobDetailView: View {
    let job: Job
    @Environment(AppStore.self) private var store
    @State private var fullJob: Job?
    @State private var loadError = ""
    @State private var loading = true
    private var displayed: Job { fullJob ?? job }
    @Environment(\.dismiss) private var dismiss
    @State private var listing: JobListing?

    var body: some View {
        let raw = displayed.raw
        let match = raw["match"]
        ZStack {
            Palette.page.ignoresSafeArea()
            Page {
                HStack {
                    BackButton(label: "Close") { dismiss() }
                    Spacer()
                }
                Text(displayed.title).font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink).reveal(0)
                Text("\(displayed.company) · \(displayed.location)").font(Typeface.body).foregroundStyle(Palette.muted).reveal(1)
                if !displayed.posted.isEmpty { Text(displayed.posted).font(Typeface.caption).foregroundStyle(Palette.muted) }
                if loading { ProgressView().tint(Palette.muted) }
                MessageLine(text: loadError).fadeSwitch(!loadError.isEmpty)
                if !loadError.isEmpty {
                    StackButton(label: "Retry details", icon: "refresh") { Task { await loadDetails() } }
                }
                if let next = JobListing(job: displayed) {
                    StackButton(label: "Open application page", icon: "link", kind: .dark) { listing = next }.reveal(2)
                } else if !displayed.url.isBlank {
                    Text("This listing's link can't be opened safely in the app.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                if !match.object.isEmpty { matchSection(match) }
                if !match["confirm"].strings.isEmpty { confirmSection(match["confirm"].strings) }
                if !raw["timeline"].object.isEmpty {
                    DisclosureSection(raw["timeline"]["label"].string.isEmpty ? "Timeline" : raw["timeline"]["label"].string) {
                        timelineSection(raw["timeline"])
                    }
                }
                if !displayed.requirements.isEmpty {
                    DisclosureSection("What they look for") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(displayed.requirements, id: \.self) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    GlyphView(name: "check", size: 14, color: Palette.muted).padding(.top, 5)
                                    Text(item).font(Typeface.body).foregroundStyle(Palette.text)
                                }
                            }
                        }
                    }
                }
                fitSection
                descriptionSection(raw)
                attribution(raw)
            }
        }
        .task(id: job.id) { await loadDetails() }
        .jobListingBrowser(item: $listing)
    }

    private func matchSection(_ match: JSON) -> some View {
        DisclosureSection(match["label"].string.isEmpty ? "How this matches you" : match["label"].string,
                          detail: match["label"].string.isEmpty ? "" : "How this matches you") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(match["checks"].array.enumerated()), id: \.offset) { _, check in
                    HStack(alignment: .top, spacing: 10) {
                        Text(mark(check["status"].string)).font(Typeface.body).foregroundStyle(Palette.muted).frame(width: 18)
                        Text("\(check["label"].string)\(check["required"].bool ? "" : " (nice to have)"): \(check["detail"].string)")
                            .font(Typeface.body).foregroundStyle(Palette.text)
                    }
                }
                Text("✓ confirmed · ? unclear · ~ caveat · ✕ conflicts with a nice-to-have")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    /// The deck card clamps the fit note and tags; the full text lives here, on demand.
    @ViewBuilder
    private var fitSection: some View {
        let fit = displayed.fit.isBlank ? displayed.reason : displayed.fit
        if !fit.isBlank || !displayed.tags.isEmpty {
            DisclosureSection("Fit and tags") {
                VStack(alignment: .leading, spacing: 12) {
                    if !fit.isBlank { Text(fit).font(Typeface.body).foregroundStyle(Palette.text) }
                    if !displayed.tags.isEmpty {
                        FlowLayout(spacing: 8) { ForEach(displayed.tags, id: \.self) { Chip(label: $0) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func confirmSection(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm before applying").font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            ForEach(items, id: \.self) { Text("• \($0)").font(Typeface.body).foregroundStyle(Palette.text) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineSection(_ timeline: JSON) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(timeline["reason"].string).font(Typeface.body).foregroundStyle(Palette.text)
            Text("Timeline check only, not a guarantee of eligibility.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(timeline["evidence"].array.enumerated()), id: \.offset) { _, item in
                Card(spacing: 6) {
                    Text(item["field"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    Text(item["quote"].string).font(Typeface.body).foregroundStyle(Palette.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func descriptionSection(_ raw: JSON) -> some View {
        let snippet = raw["snippet"].bool
        let blocks = [raw["description"].string, raw["qualifications"].string, raw["eligibility"].string, raw["remote_eligibility"].string]
            .filter { !$0.isBlank }
        if !blocks.isEmpty || !displayed.summary.isEmpty {
            DisclosureSection(snippet ? "Listing excerpt" : "Employer listing") {
                VStack(alignment: .leading, spacing: 12) {
                    if snippet {
                        Text("Read the full listing at the source.").font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                    ForEach(blocks.isEmpty ? [displayed.summary] : blocks, id: \.self) {
                        Text($0).font(Typeface.body).foregroundStyle(Palette.text)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func attribution(_ raw: JSON) -> some View {
        let a = raw["attribution"]
        if a["label"].string == "Jobs by Adzuna" {
            // The attribution is always shown; it is only a link when the URL passes the same http(s) check.
            if let next = JobListing(job: displayed, link: a["url"].string) {
                Button { listing = next } label: {
                    Text("Jobs by Adzuna").font(Typeface.caption).foregroundStyle(Palette.dark).underline()
                }
                .accessibilityLabel("Jobs by Adzuna")
            } else {
                Text("Jobs by Adzuna").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        } else if !raw["source_name"].string.isEmpty {
            let checked = raw["checked_at"].double
            Text("Source: \(raw["source_name"].string)\(checked > 0 ? " · Checked \(shortDate(checked))" : "")")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
    }

    private func mark(_ status: String) -> String {
        ["match": "✓", "unknown": "?", "partial": "~", "conflict": "✕"][status] ?? "•"
    }

    private func loadDetails() async {
        let generation = store.sessionGeneration
        loading = true
        loadError = ""
        defer { loading = false }
        do {
            let result = try await store.api.call("get_job", ["id": .string(job.id)])
            guard generation == store.sessionGeneration, store.phase == .ready, !Task.isCancelled else { return }
            fullJob = Job(result)
        } catch is CancellationError { }
        catch { if generation == store.sessionGeneration { loadError = error.localizedDescription } }
    }
}

/// Wraps its children onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
