import SwiftUI

enum StackTab: String, CaseIterable, Identifiable {
    case jobs = "Jobs"
    case applications = "Applications"
    case network = "Network"
    case resume = "Resume"
    case prep = "Prep"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .jobs: return "jobs"
        case .applications: return "applications"
        case .network: return "network"
        case .resume: return "resume"
        case .prep: return "prep"
        }
    }
}

@MainActor
struct RootView: View {
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// Existing accounts with saved activity keep their current experience; onboarding is for fresh accounts.
    private var needsJobOnboarding: Bool {
        let account = store.account
        let saved = account.savedSearch
        return !account.userID.isEmpty && !account.raw["profile"]["onboarded"].bool
            && !UserDefaults.standard.bool(forKey: "job-onboarding." + account.userID)
            && account.resumes.isEmpty && account.applications.isEmpty && account.decidedJobIDs.isEmpty
            && account.role.isEmpty && saved["query"].string.isEmpty && saved["filters"].object.isEmpty
    }

    var body: some View {
        LaunchSequence(isReady: store.phase != .starting) {
            ZStack {
                Palette.page.ignoresSafeArea()
                switch store.phase {
                case .starting:
                    Color.clear
                case .startupFailed:
                    VStack(alignment: .leading, spacing: Spacing.stack) {
                        Text("Stack couldn’t load your account").font(Typeface.display).foregroundStyle(Palette.ink)
                            .accessibilityAddTraits(.isHeader)
                        MessageLine(text: store.error)
                        StackButton(label: store.restoringSession ? "Retrying…" : "Retry", disabled: store.restoringSession) {
                            Task { await store.start() }
                        }
                    }
                    .frame(maxWidth: 400)
                    .padding(Spacing.page)
                case .signedOut:
                    AccessView().replayable().transition(.opacity)
                case .admission:
                    InvitationView().replayable().transition(.opacity)
                case .ready:
                    JobOnboardingGate(required: needsJobOnboarding)
                        .id(store.account.userID).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : Motion.fadeAnimation, value: store.phase)
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onOpenURL { url in
            if let destination = StackAppLink.destination(url) { store.linkedDestination = destination }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL, let destination = StackAppLink.destination(url) {
                store.linkedDestination = destination
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        // No timed refresh: the account is re-read on foreground and after each change. The one exception is a
        // running agent task, checked until it finishes (until live task updates replace this).
        .task(id: AgentWatch(phase: store.phase, active: store.account.activeRunCount > 0)) {
            guard store.phase == .ready, store.account.activeRunCount > 0 else { return }
            while !Task.isCancelled, store.account.activeRunCount > 0 {
                try? await Task.sleep(for: .seconds(15))
                if scenePhase == .active { await store.refresh() }
            }
        }
    }
}

@MainActor
struct JobOnboardingGate: View {
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var showingOnboarding: Bool
    @State private var preparingJobs: Bool

    init(required: Bool) {
        _showingOnboarding = State(initialValue: required)
        _preparingJobs = State(initialValue: !required)
    }

    var body: some View {
        ZStack {
            if preparingJobs {
                MainTabs()
                    .opacity(showingOnboarding ? 0 : 1)
                    .allowsHitTesting(!showingOnboarding)
                    .accessibilityHidden(showingOnboarding)
            }
            if showingOnboarding {
                JobOnboardingView(onPrepared: { preparingJobs = true }) {
                    UserDefaults.standard.set(true, forKey: "job-onboarding." + store.account.userID)
                    preparingJobs = true
                    withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { showingOnboarding = false }
                }
                .transition(.opacity)
            }
        }
    }
}

/// Keep visited roots mounted so tab changes preserve decks, drafts and scroll positions.
@MainActor
struct MainTabs: View {
    @Environment(AppStore.self) private var store
    @State private var selection: StackTab = .jobs
    @State private var visited: Set<StackTab> = [.jobs]
    @State private var showProfile = false
    @State private var agentTask: TaskTarget?
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(StackTab.allCases) { tab in
                    if selection == tab || visited.contains(tab) {
                        screen(for: tab)
                            .opacity(selection == tab ? 1 : 0)
                            .allowsHitTesting(selection == tab)
                            .accessibilityHidden(selection != tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar(selection: $selection, namespace: highlight)
        }
        .onChange(of: selection) { _, tab in visited.insert(tab) }
        .onChange(of: store.linkedDestination) { _, destination in
            if let destination { go(to: destination); store.linkedDestination = nil }
        }
        .onAppear {
            if let destination = store.linkedDestination { go(to: destination); store.linkedDestination = nil }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView().environment(store).replayable()
        }
        .sheet(item: $agentTask) { target in AgentTaskSheet(taskID: target.id).environment(store).replayable() }
        .onReceive(NotificationCenter.default.publisher(for: .stackNavigate)) { note in
            guard let destination = note.userInfo?["destination"] as? String else { return }
            go(to: destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stackOpenTarget)) { note in
            guard let info = note.userInfo as? [String: String] else { return }
            open(info)
        }
        .onAppear {
            if let pending = StackAppDelegate.pending { open(pending) }
        }
    }

    /// Switches tabs for a destination named by an agent action, a fix link or a notification.
    private func go(to destination: String) {
        let map: [String: StackTab] = [
            "jobs": .jobs, "applications": .applications, "contacts": .network, "network": .network,
            "resume": .resume, "resume-details": .resume, "resume-bank": .resume, "prep": .prep,
        ]
        guard let tab = map[destination] else { return }
        showProfile = false
        visited.insert(tab)
        if tab == .network { store.pendingOpen["network_section"] = "network" }
        selection = tab
        if destination != "prep" { Task { await store.refresh() } }
    }

    /// Opens the application, contact or agent task a tapped notification refers to.
    private func open(_ info: [String: String]) {
        StackAppDelegate.pending = nil
        guard info["user_id"] == nil || info["user_id"] == store.account.userID else { return }
        let type = info["target_type"] ?? ""
        let id = info["target_id"] ?? ""
        guard !id.isEmpty else { return }
        switch type {
        case "agent":
            showProfile = false
            agentTask = TaskTarget(id: id)
        case "application":
            store.pendingOpen = ["target_type": "application", "target_id": id]
            go(to: "applications")
        case "contact":
            store.pendingOpen = ["target_type": "contact", "target_id": id]
            go(to: "network")
        case "tab":
            // An accountability reminder names the tab where its step happens.
            showProfile = false
            agentTask = nil
            go(to: id)
        default:
            break
        }
    }

    private func screen(for tab: StackTab) -> some View {
        tabScreen(for: tab).replayable()
    }

    @ViewBuilder
    private func tabScreen(for tab: StackTab) -> some View {
        switch tab {
        case .jobs: JobsView(onProfile: { showProfile = true })
        case .applications: ApplicationsView(onProfile: { showProfile = true }, onNavigate: { selection = $0 })
        case .network: NetworkView(onProfile: { showProfile = true })
        case .resume: ResumeView(onProfile: { showProfile = true })
        case .prep: PrepView(isActive: selection == .prep && !showProfile && agentTask == nil,
                             onProfile: { showProfile = true })
        }
    }
}

private struct TabBar: View {
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Binding var selection: StackTab
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StackTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: Glyph.symbol(tab.icon))
                            .symbolVariant(selected ? .fill : .none)
                            .font(.system(size: 19, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(selected ? Brand.accent : Brand.muted)
                    .frame(maxWidth: .infinity, minHeight: 49)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Palette.halo)
                                .matchedGeometryEffect(id: "tab-highlight", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityShowsLargeContentViewer {
                    Label(tab.rawValue, systemImage: Glyph.symbol(tab.icon))
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.stageAnimation, value: selection)
        .padding(4)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.rule, lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Brand.page.ignoresSafeArea(edges: .bottom))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Restarts the agent check when the session changes or a task starts or finishes.
private struct AgentWatch: Equatable {
    let phase: AppStore.Phase
    let active: Bool
}
