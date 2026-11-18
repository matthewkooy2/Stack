import SwiftUI

/// Inline public-presence rows, hosted in Network's scroll view. Provider editors keep their
/// existing session-only storage and never publish to LinkedIn, GitHub or a portfolio.
@MainActor
struct PresenceView: View {
    @Binding var reload: Int
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var run: JSON = .null
    @State private var loading = false
    @State private var error = ""
    @State private var requestID: UUID?
    @State private var linkedIn = false
    @State private var editor: PresenceEditorTarget?
    @State private var task: TaskTarget?
    @State private var platform: PresencePlatform?

    private var latestRun: JSON? { PresenceLinkedInPresentation.latestRun(in: store.account.runViews) }
    private var presentation: PresenceLinkedInPresentation? { run.isNull ? nil : PresenceLinkedInPresentation(run: run) }
    private var loadKey: [JSON] {
        [latestRun ?? .null, .number(Double(reload)), .number(Double(store.sessionGeneration))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            linkedInReview
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Drafts").padding(.leading, 4)
                VStack(spacing: 0) {
                    let platforms = PresencePlatform.allCases
                    ForEach(platforms) { platform in
                        draftRow(platform, last: platform == platforms.last)
                    }
                }
                .padding(.horizontal, 16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .stackElevation()
            }
        }
        .task(id: loadKey) { await load() }
        .onChange(of: store.sessionGeneration) { _, _ in reset() }
        .onChange(of: store.phase) { _, phase in if phase != .ready { reset() } }
        .fullScreenCover(isPresented: $linkedIn, onDismiss: refresh) {
            LinkedInFlow().environment(store)
        }
        .sheet(item: $editor) { target in
            SheetPage(title: "Suggested rewrites") {
                LinkedInRewriteEditor(taskID: target.id, rewrites: target.rewrites)
                Text("Nothing is published")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            .environment(store)
        }
        .sheet(item: $task, onDismiss: refresh) { target in
            AgentTaskSheet(taskID: target.id).environment(store)
        }
        .sheet(item: $platform) { value in
            PublicProfilesView(initialPlatform: value.rawValue).environment(store)
        }
    }

    /// The hero: one card, one primary action that fits the current state of the review.
    private var linkedInReview: some View {
        Card(spacing: 16) {
            HStack(spacing: 12) {
                SymbolTile(systemName: "person.crop.rectangle.fill", weight: .semibold)
                Text("LinkedIn review").font(Typeface.section).foregroundStyle(Brand.ink)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("presence-linkedin")
                Spacer(minLength: 4)
                if latestRun != nil {
                    Menu {
                        Button("Review another PDF", systemImage: "doc.badge.plus") { linkedIn = true }
                        if let model = presentation, model.rewriteIndex != nil {
                            Button("Full review", systemImage: "doc.text") { task = TaskTarget(id: model.taskID) }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Brand.muted)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("LinkedIn review options")
                    .padding(.trailing, -8)
                }
            }
            if loading {
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(width: 120, height: 12)
                    SkeletonBlock(height: 14)
                    SkeletonBlock(height: 14)
                    SkeletonBlock(width: 180, height: 14)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading review")
                .accessibilityIdentifier("presence-loading")
            } else if !error.isEmpty {
                MessageLine(text: error)
                action("Try again", identifier: "presence-retry", prominent: false) { reload += 1 }
            } else if let model = presentation {
                if let suggested = model.suggested(saved: store.rewriteDrafts[model.taskID]) {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusPill(text: "Suggested \(model.sectionLabel.lowercased())", tone: .accent)
                        Text(suggested.isBlank ? "Empty" : suggested)
                            .font(Typeface.body).foregroundStyle(Brand.ink)
                            .lineLimit(4).accessibilityIdentifier("presence-suggested")
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.page, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    DisclosureSection("Current wording") {
                        Text(model.current ?? "Not captured")
                            .font(.subheadline).foregroundStyle(Brand.muted).textSelection(.enabled)
                            .accessibilityIdentifier("presence-current")
                    }
                    action("Edit rewrite", identifier: "presence-edit-rewrite") {
                        editor = PresenceEditorTarget(id: model.taskID, rewrites: model.rewrites)
                    }
                } else {
                    let detail = model.hasReview ? model.summary : (model.message.isBlank ? AgentLabels.statusLabel(model.status) : model.message)
                    if !detail.isBlank {
                        Text(detail).font(Typeface.body).foregroundStyle(Brand.ink).lineLimit(3)
                    }
                    action("Open review", identifier: "presence-open-review") { task = TaskTarget(id: model.taskID) }
                }
            } else {
                Text("Get feedback on your LinkedIn")
                    .font(Typeface.body).foregroundStyle(Brand.muted)
                action("Review LinkedIn", identifier: "presence-start-review") { linkedIn = true }
            }
        }
        .animation(Motion.animation(Motion.smooth, reduce: reduceMotion), value: loading)
    }

    private func draftRow(_ provider: PresencePlatform, last: Bool) -> some View {
        let fields = ProfileDraftField.fields(for: provider.rawValue)
        let edits = fields.compactMap { item -> String? in
            guard let text = store.profileDrafts[provider.rawValue + ":" + item.id], !text.isBlank else { return nil }
            return text
        }
        return Button { platform = provider } label: {
            HStack(spacing: 14) {
                SymbolTile(systemName: provider.symbol, size: 38, tint: provider.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.rawValue).font(.headline).foregroundStyle(Brand.ink)
                    Text(edits.first ?? provider.detail)
                        .font(.subheadline).foregroundStyle(Brand.muted).lineLimit(2)
                }
                Spacer(minLength: 8)
                if !edits.isEmpty { StatusPill(text: "Draft", tone: .success) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted.opacity(0.6)).accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 12).frame(minHeight: 66)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Palette.rule.opacity(0.7)).frame(height: 0.5).padding(.leading, 50) }
            }
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel(provider.rawValue)
        .accessibilityValue(edits.first ?? provider.detail)
        .accessibilityHint("Edit profile drafts")
        .accessibilityIdentifier(provider == .linkedin ? "presence-linkedin-drafts" : "presence-\(provider.rawValue.lowercased())")
    }

    /// One prominent action per card; a quiet text action where it is a retry.
    private func action(_ title: String, identifier: String, prominent: Bool = true, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(.headline).weight(.semibold))
                .foregroundStyle(prominent ? Color.white : Brand.accent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(prominent ? Palette.button : Palette.halo, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.97))
        .accessibilityIdentifier(identifier)
    }

    private func load() async {
        let request = UUID()
        requestID = request
        run = .null
        error = ""
        loading = false
        guard store.phase == .ready, let summary = latestRun else { return }
        let generation = store.sessionGeneration
        let id = summary["id"].string
        loading = true
        defer { if requestID == request { loading = false } }
        do {
            let result = try await store.call("agent_run", ["id": .string(id)], linkedin: true)
            // LinkedIn's prototype transport bypasses AppStore's normal stale-session guard.
            guard !Task.isCancelled, requestID == request, generation == store.sessionGeneration, store.phase == .ready else { return }
            guard result["id"].string == id else { throw APIError(message: "Review unavailable") }
            run = result
        } catch {
            guard !Task.isCancelled, requestID == request, generation == store.sessionGeneration, store.phase == .ready,
                  !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    private func refresh() {
        Task {
            await store.refresh()
            reload += 1
        }
    }

    private func reset() {
        requestID = nil
        run = .null
        loading = false
        error = ""
        linkedIn = false
        editor = nil
        task = nil
        platform = nil
    }
}

private struct PresenceEditorTarget: Identifiable {
    let id: String
    let rewrites: [JSON]
}

private enum PresencePlatform: String, CaseIterable, Identifiable {
    case linkedin = "LinkedIn", github = "GitHub", portfolio = "Portfolio"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .linkedin: return "person.crop.rectangle"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .portfolio: return "globe"
        }
    }

    var tint: Palette.Tint {
        switch self {
        case .linkedin: return Palette.tints[0]
        case .github: return Palette.tints[5]
        case .portfolio: return Palette.tints[1]
        }
    }

    var detail: String {
        switch self {
        case .linkedin: return "Headline, About and experience"
        case .github: return "Bio, README and repositories"
        case .portfolio: return "Headline, About and projects"
        }
    }
}
