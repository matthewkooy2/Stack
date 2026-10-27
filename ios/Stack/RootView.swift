import SwiftUI
import AuthenticationServices

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        LaunchSequence(isReady: store.phase != .starting) {
            ZStack {
                Palette.page.ignoresSafeArea()
                switch store.phase {
                case .starting:
                    Color.clear
                case .signedOut:
                    AccessView().replayable().transition(.opacity)
                case .admission:
                    InvitationView().replayable().transition(.opacity)
                case .ready:
                    MainTabs().transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : Motion.fadeAnimation, value: store.phase)
        }
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            Task { await store.refresh() }
        }
        .task(id: store.phase) {
            guard store.phase == .ready else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if scenePhase == .active { await store.refresh() }
            }
        }
    }
}

/// The five destinations retain their order, with the blue look on Jobs, Network and Prep.
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
                    if visited.contains(tab) {
                        screen(for: tab)
                            .opacity(selection == tab ? 1 : 0)
                            .allowsHitTesting(selection == tab)
                            .accessibilityHidden(selection != tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TabBar(selection: $selection, namespace: highlight, resumeIsEmpty: store.account.resumes.isEmpty)
        }
        .onChange(of: selection) { _, tab in visited.insert(tab) }
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
        withAnimation(Motion.ease(0.32)) { selection = tab }
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
        case .prep: PrepView(isActive: selection == .prep && !showProfile && agentTask == nil)
        }
    }
}

private struct TabBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: StackTab
    let namespace: Namespace.ID
    let resumeIsEmpty: Bool

    private var resumeUpload: Bool { selection == .resume && resumeIsEmpty }
    /// Screens in the blue look: the bar's icons and selection follow it. Prep keeps the page colour only.
    private var branded: Bool { selection == .jobs || selection == .network || resumeUpload }
    private var brandedPage: Bool { branded || selection == .prep }
    private var pageColor: Color { brandedPage ? Brand.page : Palette.page }
    private var highlight: Color {
        if resumeUpload { return .clear }
        return branded ? Brand.accent.opacity(0.10) : Palette.halo.opacity(0.7)
    }

    private func tint(for tab: StackTab) -> Color {
        if branded { return selection == tab ? Brand.accent : Brand.muted }
        return selection == tab ? Palette.icon : Palette.muted
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StackTab.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : Motion.ease(0.32)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        GlyphView(name: tab.icon, size: 21, color: tint(for: tab))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(tint(for: tab))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(highlight)
                                .matchedGeometryEffect(id: "tab-highlight", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.94, dim: 1))
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(pageColor.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(brandedPage ? Brand.rule : Palette.rule).frame(height: 1) }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
