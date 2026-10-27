import SwiftUI

/// Inline public-presence rows, hosted in Network's scroll view. Provider editors keep their
/// existing session-only storage and never publish to LinkedIn, GitHub or a portfolio.
@MainActor
struct PresenceView: View {
    var refreshID = 0
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var expanded = true
    @State private var run: JSON = .null
    @State private var loading = false
    @State private var error = ""
    @State private var requestID: UUID?
    @State private var reload = 0
    @State private var linkedIn = false
    @State private var editor: PresenceEditorTarget?
    @State private var task: TaskTarget?
    @State private var platform: PresencePlatform?

    private var latestRun: JSON? { PresenceLinkedInPresentation.latestRun(in: store.account.runViews) }
    private var presentation: PresenceLinkedInPresentation? { run.isNull ? nil : PresenceLinkedInPresentation(run: run) }
    private var loadKey: [JSON] {
        [latestRun ?? .null, .number(Double(refreshID)), .number(Double(reload)), .number(Double(store.sessionGeneration))]
    }
    private var detailInset: CGFloat { dynamicTypeSize.isAccessibilitySize ? 0 : 62 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            linkedInRow
            rule
            platformRow(.github, detail: "Bio, README &\nrepo descriptions", symbol: "chevron.left.forwardslash.chevron.right")
            rule
            platformRow(.portfolio, detail: "Headline, About &\nproject drafts", symbol: "globe")
            rule
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

    private var linkedInRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { expanded.toggle() }
            } label: {
                HStack(spacing: 14) {
                    Text("in").font(.system(size: 23, weight: .bold)).foregroundStyle(Brand.accent)
                        .frame(width: 48, height: 48)
                        .background(Brand.accent.opacity(0.09), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("LinkedIn").font(.system(.title3).weight(.bold)).foregroundStyle(Brand.ink)
                        Text(presentation?.sectionLabel ?? "Headline").font(Typeface.caption).foregroundStyle(Brand.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.ink)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.99))
            .accessibilityLabel("LinkedIn")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hide profile review" : "Show profile review")
            .accessibilityIdentifier("presence-linkedin")
            if expanded {
                linkedInContent
                    .padding(.leading, detailInset)
                    .padding(.top, 20)
                    .padding(.bottom, 26)
            }
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var linkedInContent: some View {
        if loading {
            ProgressView("Loading review…").tint(Brand.accent)
                .font(Typeface.caption).foregroundStyle(Brand.muted)
                .accessibilityIdentifier("presence-loading")
        } else if !error.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(error).font(Typeface.caption).foregroundStyle(Brand.muted)
                action("Retry loading review", identifier: "presence-retry") { reload += 1 }
            }
        } else if let model = presentation, let suggested = model.suggested(saved: store.rewriteDrafts[model.taskID]) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    caption("Current")
                    Text(model.current ?? "Not captured in this review.")
                        .font(.body).foregroundStyle(model.current == nil ? Brand.muted : Brand.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("presence-current")
                }
                VStack(alignment: .leading, spacing: 8) {
                    caption("Suggested rewrite")
                    Text(suggested.isBlank ? "Rewrite is empty." : suggested)
                        .font(.title3).foregroundStyle(Brand.ink)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("presence-suggested")
                }
                action("Edit rewrite", identifier: "presence-edit-rewrite") {
                    editor = PresenceEditorTarget(id: model.taskID, rewrites: model.rewrites)
                }
            }
        } else if let model = presentation {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasReview {
                    Text("Your review is ready.").font(.body).foregroundStyle(Brand.ink)
                    // The current backend returns raw coaching. Do not invent a structured headline
                    // or relabel the full coaching document as a suggested rewrite.
                    action("Open review", identifier: "presence-open-review") { task = TaskTarget(id: model.taskID) }
                } else {
                    Text(model.message.isBlank ? AgentLabels.statusLabel(model.status) : model.message)
                        .font(.body).foregroundStyle(Brand.muted)
                    action("Open LinkedIn review", identifier: "presence-open-review") { task = TaskTarget(id: model.taskID) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("No review yet.").font(.body).foregroundStyle(Brand.muted)
                action("Review LinkedIn", identifier: "presence-start-review") { linkedIn = true }
            }
        }
    }

    private func platformRow(_ platform: PresencePlatform, detail: String, symbol: String) -> some View {
        Button { self.platform = platform } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Brand.ink)
                    .frame(width: 48, height: 48)
                    .background(.white, in: Circle())
                    .overlay(Circle().stroke(Brand.rule, lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(platform.rawValue).font(.system(.title3).weight(.bold)).foregroundStyle(Brand.ink)
                    Text(detail).font(Typeface.caption).foregroundStyle(Brand.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.ink)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.99))
        .accessibilityLabel(platform.rawValue)
        .accessibilityHint("Open session-only profile drafts")
        .accessibilityIdentifier("presence-\(platform.rawValue.lowercased())")
    }

    private var rule: some View { Rectangle().fill(Brand.rule).frame(height: 1).accessibilityHidden(true) }
    private func caption(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(Brand.muted)
    }
    private func action(_ title: String, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 16) {
                Text(title).font(.body.weight(.semibold))
                Image(systemName: "arrow.up.right").font(.system(size: 15)).accessibilityHidden(true)
            }
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
        expanded = true
    }
}

private struct PresenceEditorTarget: Identifiable {
    let id: String
    let rewrites: [JSON]
}

private enum PresencePlatform: String, Identifiable {
    case github = "GitHub", portfolio = "Portfolio"
    var id: String { rawValue }
}
