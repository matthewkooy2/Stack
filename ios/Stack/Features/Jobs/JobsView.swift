import SwiftUI

/// A deck of roles. Drag a card right to save it, left to pass; the buttons do the same.
@MainActor
struct JobsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var onProfile: () -> Void

    @State var jobs: [Job] = []
    @State var loaded = false
    @State var loadError = ""
    @State private var nextCursor = ""
    /// One search save or deck load at a time, so a slow older response cannot overwrite a newer search.
    @State private var gate = JobRequestGate()
    @State var drag: CGSize = .zero
    @State var hidden: Set<String> = []
    @State var detail: Job?
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
        return jobs.filter { !decided.contains($0.id) && !hidden.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.option) {
            ScreenHeader(title: "Jobs", subtitle: deck.isEmpty ? "" : "\(deck.count) to review", onProfile: onProfile)
                .padding(.horizontal, Spacing.page)
                .reveal(0)
            JobSearchBar(search: search, sheet: $sheet, disabled: gate.busy,
                         onChange: { query, filters in Task { await applySearch(query: query, filters: filters) } },
                         onReset: { Task { await resetSearch() } })
            if let pending = pendingDecision {
                HStack {
                    Text(pending.save ? "Saved \(pending.job.title)" : "Passed \(pending.job.title)")
                        .font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(2)
                    Spacer()
                    Chip(label: "Undo") { undoDecision() }
                }.padding(.horizontal, Spacing.page)
            }
            if !loadError.isEmpty || !banner.isEmpty || !search.notices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    MessageLine(text: loadError).fadeSwitch(!loadError.isEmpty && deck.first != nil)
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
        .onDisappear { commitDecision() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { commitDecision() } }
        .onReceive(NotificationCenter.default.publisher(for: .stackProfileSaved)) { _ in
            Task { await profileSaved() }
        }
        .sheet(item: $detail) { job in JobDetailView(job: job).environment(store) }
        .sheet(item: $sheet) { value in
            switch value {
            case .filters:
                JobFiltersSheet(search: search) { query, filters in await applySearch(query: query, filters: filters) }
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
        if !loaded {
            VStack { ProgressView().tint(Palette.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let top = deck.first {
            VStack(spacing: 20) {
                ZStack {
                    ForEach(Array(deck.prefix(3).enumerated().reversed()), id: \.element.id) { offset, job in
                        JobCard(job: job)
                            .scaleEffect(1 - CGFloat(offset) * 0.04)
                            .offset(y: CGFloat(offset) * 12)
                            .offset(offset == 0 ? drag : .zero)
                            .rotationEffect(.degrees(offset == 0 ? Double(drag.width / 18) : 0))
                            .overlay(alignment: .topLeading) { if offset == 0 { stamp(for: drag.width) } }
                            .gesture(swipe(top), including: offset == 0 ? .all : .none)
                            .onTapGesture { if offset == 0 { detail = job } }
                            .accessibilityHidden(offset != 0)
                            .accessibilityAction(named: "Save") { decide(top, save: true) }
                            .accessibilityAction(named: "Pass") { decide(top, save: false) }
                    }
                }
                .padding(.horizontal, Spacing.page)
                .frame(maxHeight: .infinity)
                HStack(spacing: 18) {
                    roundButton(icon: "pass", label: "Pass") { decide(top, save: false) }
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
                }
                if !nextCursor.isEmpty {
                    StackButton(label: "Load more roles", icon: "refresh", disabled: gate.busy) {
                        Task { await load(refresh: false, more: true) }
                    }
                }
                HStack(spacing: Spacing.option) {
                    StackButton(label: "Refresh jobs", icon: "refresh", kind: .secondary, disabled: gate.busy) {
                        Task { await load(refresh: true) }
                    }
                    StackButton(label: "Import a job link", icon: "link", kind: .secondary) { sheet = .importLink }
                }
            }
            .padding(.horizontal, Spacing.page)
            Spacer()
        }
    }

    private var emptyTitle: String {
        if !loadError.isEmpty { return "Could not load roles" }
        if search.missingGraduation { return "Add your graduation month" }
        if !nextCursor.isEmpty { return "More roles to review" }
        if search.filters["timeline"].string == "confirmed" { return "No confirmed timeline matches." }
        return "You are all caught up"
    }

    private var emptyMessage: String {
        if !loadError.isEmpty { return loadError }
        if search.missingGraduation {
            return "Confirmed timeline matches compare listings with your graduation month, so none can be confirmed yet. Set it, or choose Hide timeline mismatches in Filters to include unclear listings."
        }
        if !nextCursor.isEmpty { return "Continue to the next page of verified roles." }
        if search.filters["timeline"].string == "confirmed" {
            return "Many listings lack a clear graduation window. Add your graduation date, or choose Hide timeline mismatches to include unclear listings."
        }
        if !search.excluded.isEmpty {
            let reasons = search.excluded.prefix(4).map { "\($0["reason"].string) (\($0["count"].int))" }.joined(separator: ", ")
            return "Hidden by your requirements: \(reasons). Mark some as nice to have in Filters or your profile to see them ranked lower."
        }
        return "New verified roles appear here as they are found. Try another role or location, or refresh after sources finish."
    }

    private func roundButton(icon: String, label: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlyphView(name: icon, size: 26, color: filled ? Palette.onDark : Palette.icon)
                .frame(width: 68, height: 68)
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
                do { try await Task.sleep(for: .milliseconds(2400)) } catch { return }
                guard !Task.isCancelled else { return }
                commitDecision()
            }
        }
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
                loadError = store.error.isEmpty ? "This decision was not saved. Please try again." : store.error
            }
        }
    }

    /// Applies the saved search (profile defaults plus its overrides) and queues collection once.
    private func start() async {
        guard !started else { return }
        started = true
        search.adopt(saved: store.account.savedSearch)
        await load(refresh: true)
    }

    /// Waits for any in-flight request, then claims the gate. Nothing suspends between the check and the claim.
    private func beginSave() async -> Bool {
        while gate.busy {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return gate.beginSave()
    }

    /// A profile edit may have cleared saved overrides (a changed role drops the query and any_role).
    /// Waits for any request, adopts the account's refreshed saved search, then reloads from page one.
    private func profileSaved() async {
        guard await beginSave() else { return }
        commitDecision()
        search.adopt(saved: store.account.savedSearch)
        nextCursor = ""
        gate.endSave()
        await load(refresh: false)
    }

    private func applySearch(query: String, filters: JSON) async {
        guard await beginSave() else { return }
        commitDecision()
        do {
            let stored = try await store.call("save_search", ["query": .string(query), "filters": filters])
            search.adopt(saved: stored)
            store.account.raw["saved_search"] = ["query": .string(search.query), "filters": search.filters]
            nextCursor = ""
            jobs = []
            hidden = []
            sheet = nil
            gate.endSave()
            await load(refresh: true)
        } catch {
            gate.endSave()
            if !(error is CancellationError) { loadError = error.localizedDescription }
        }
    }

    private func resetSearch() async {
        guard await beginSave() else { return }
        commitDecision()
        do {
            try await store.call("reset_search")
            search.adopt(saved: [:])
            store.account.raw["saved_search"] = ["query": "", "filters": [:]]
            nextCursor = ""
            jobs = []
            hidden = []
            gate.endSave()
            await load(refresh: true)
        } catch {
            gate.endSave()
            if !(error is CancellationError) { loadError = error.localizedDescription }
        }
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
                if !(error is CancellationError) { loadError = error.localizedDescription }
                importID = ""
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func load(refresh: Bool, more: Bool = false) async {
        guard store.phase == .ready, gate.beginLoad() else { return }
        let generation = store.sessionGeneration
        loadError = ""
        var pages = 0
        defer { gate.endLoad() }
        repeat {
            pages += 1
            let continuing = more || pages > 1
            do {
                let result = try await store.api.call("search_jobs", [
                    "query": .string(search.query),
                    "filters": search.filters,
                    "refresh": .bool(refresh && pages == 1),
                    "cursor": .string(continuing ? nextCursor : ""),
                ])
                guard generation == store.sessionGeneration, store.phase == .ready, !Task.isCancelled else { return }
                let incoming = result["jobs"].array.map(Job.init)
                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) {
                    jobs = continuing ? jobs + incoming.filter { incomingJob in !jobs.contains { $0.id == incomingJob.id } } : incoming
                }
                nextCursor = result["next_cursor"].string
                search.apply(result)
            } catch is CancellationError { return }
            catch {
                if generation == store.sessionGeneration { loadError = error.localizedDescription }
                break
            }
            // Keep a few cards ahead without waiting for the person to ask for the next page.
        } while !nextCursor.isEmpty && deck.count < 5 && pages < 6
        loaded = true
    }
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
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if !job.tags.isEmpty {
                FlowLayout(spacing: 8) { ForEach(job.tags.prefix(6), id: \.self) { Chip(label: $0) } }
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
    @Environment(\.openURL) private var openURL

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
                if let url = URL(string: displayed.url), !displayed.url.isEmpty {
                    StackButton(label: "Open application page", icon: "link", kind: .dark) { openURL(url) }.reveal(2)
                }
                if !match.object.isEmpty { matchSection(match) }
                if !raw["timeline"].object.isEmpty { timelineSection(raw["timeline"]) }
                if !displayed.requirements.isEmpty {
                    Card {
                        Text("What they look for").font(Typeface.section).foregroundStyle(Palette.ink)
                        ForEach(displayed.requirements, id: \.self) { item in
                            HStack(alignment: .top, spacing: 10) {
                                GlyphView(name: "check", size: 14, color: Palette.muted).padding(.top, 5)
                                Text(item).font(Typeface.body).foregroundStyle(Palette.text)
                            }
                        }
                    }
                    .reveal(3)
                }
                descriptionSection(raw)
                attribution(raw)
            }
        }
        .task(id: job.id) { await loadDetails() }
    }

    private func matchSection(_ match: JSON) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "How this matches you")
            if !match["label"].string.isEmpty {
                Text(match["label"].string).font(Typeface.section).foregroundStyle(Palette.ink)
            }
            ForEach(Array(match["checks"].array.enumerated()), id: \.offset) { _, check in
                HStack(alignment: .top, spacing: 10) {
                    Text(mark(check["status"].string)).font(Typeface.body).foregroundStyle(Palette.muted).frame(width: 18)
                    Text("\(check["label"].string)\(check["required"].bool ? "" : " (nice to have)"): \(check["detail"].string)")
                        .font(Typeface.body).foregroundStyle(Palette.text)
                }
            }
            Text("✓ confirmed · ? not stated or unclear · ~ fits with a caveat · ✕ conflicts with a nice-to-have")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if !match["confirm"].strings.isEmpty {
                SectionLabel(text: "Confirm before applying")
                ForEach(match["confirm"].strings, id: \.self) { Text("• \($0)").font(Typeface.body).foregroundStyle(Palette.text) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timelineSection(_ timeline: JSON) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(timeline["label"].string).font(Typeface.section).foregroundStyle(Palette.ink)
            Text(timeline["reason"].string).font(Typeface.body).foregroundStyle(Palette.text)
            Text("Timeline check only · Not a guarantee of eligibility. Based on the listing text below.")
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
            VStack(alignment: .leading, spacing: 12) {
                Text(snippet ? "Description excerpt — read the full listing at the source." : "Employer listing")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                ForEach(blocks.isEmpty ? [displayed.summary] : blocks, id: \.self) {
                    Text($0).font(Typeface.body).foregroundStyle(Palette.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func attribution(_ raw: JSON) -> some View {
        let a = raw["attribution"]
        if a["label"].string == "Jobs by Adzuna", let url = URL(string: a["url"].string) {
            Button { openURL(url) } label: {
                Text("Jobs by Adzuna").font(Typeface.caption).foregroundStyle(Palette.dark).underline()
            }
            .accessibilityLabel("Jobs by Adzuna")
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
