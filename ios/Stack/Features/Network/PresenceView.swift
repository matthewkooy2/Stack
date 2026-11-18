import SwiftUI

/// Inline public-presence rows, hosted in Network's scroll view. Provider editors keep their
/// existing session-only storage and never publish to LinkedIn, GitHub or a portfolio.
@MainActor
struct PresenceView: View {
    @Binding var reload: Int
    @Environment(AppStore.self) private var store
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
            VStack(alignment: .leading, spacing: 0) {
                Text("Profile drafts").font(Typeface.section).foregroundStyle(Brand.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)
                ForEach(PresencePlatform.allCases) { platform in
                    draftRow(platform)
                    Divider()
                }
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
                Text("Nothing is published. Copy approved text when you’re ready to apply it.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
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

    private var linkedInReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("in").font(.headline.bold()).foregroundStyle(Brand.accent)
                    .frame(width: 32, height: 32)
                    .background(Palette.halo, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
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
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("LinkedIn review options")
                }
            }
            if loading {
                ProgressView("Loading review…").font(.subheadline).tint(Brand.accent)
                    .accessibilityIdentifier("presence-loading")
            } else if !error.isEmpty {
                MessageLine(text: error)
                action("Retry loading review", identifier: "presence-retry") { reload += 1 }
            } else if let model = presentation {
                if let suggested = model.suggested(saved: store.rewriteDrafts[model.taskID]) {
                    Text("Suggested \(model.sectionLabel.lowercased())").font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    Text(suggested.isBlank ? "This rewrite is empty." : suggested)
                        .font(Typeface.body).foregroundStyle(Brand.ink)
                        .lineLimit(4).accessibilityIdentifier("presence-suggested")
                    DisclosureSection("Compare with current wording") {
                        Text(model.current ?? "This section wasn’t captured.")
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
                Text("Get feedback on the profile in your LinkedIn PDF.")
                    .font(.subheadline).foregroundStyle(Brand.muted)
                action("Review LinkedIn", identifier: "presence-start-review") { linkedIn = true }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func draftRow(_ provider: PresencePlatform) -> some View {
        let fields = ProfileDraftField.fields(for: provider.rawValue)
        let edits = fields.compactMap { item -> String? in
            guard let text = store.profileDrafts[provider.rawValue + ":" + item.id], !text.isBlank else { return nil }
            return text
        }
        return Button { platform = provider } label: {
            HStack(spacing: 14) {
                Image(systemName: provider.symbol).font(.body.weight(.medium)).foregroundStyle(Brand.muted)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.rawValue).font(.headline).foregroundStyle(Brand.ink)
                    Text(edits.first ?? provider.detail)
                        .font(.subheadline).foregroundStyle(Brand.muted).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.medium)).foregroundStyle(Brand.muted)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 12).frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.rawValue)
        .accessibilityValue(edits.first ?? provider.detail)
        .accessibilityHint("Edit profile drafts")
        .accessibilityIdentifier(provider == .linkedin ? "presence-linkedin-drafts" : "presence-\(provider.rawValue.lowercased())")
    }

    private func action(_ title: String, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: "arrow.right").font(.footnote).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Brand.accent)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.98))
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
            guard result["id"].string == id else { throw APIError(message: "This LinkedIn review is not available. Try again.") }
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

    var detail: String {
        switch self {
        case .linkedin: return "Headline, About and experience"
        case .github: return "Bio, README and repositories"
        case .portfolio: return "Headline, About and projects"
        }
    }
}
