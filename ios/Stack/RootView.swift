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

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            switch store.phase {
            case .starting:
                VStack(spacing: 18) {
                    Text("stack").font(Typeface.display).tracking(-1.2).foregroundStyle(Palette.ink)
                    ProgressView().tint(Palette.muted)
                }
                .transition(.opacity)
            case .signedOut:
                AccessView().transition(.opacity)
            case .admission:
                InvitationView().transition(.opacity)
            case .ready:
                MainTabs().transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: store.phase)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refresh() } }
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

/// The five destinations, with a cream bar whose selection glides between items.
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
            TabBar(selection: $selection, namespace: highlight)
        }
        .onChange(of: selection) { _, tab in visited.insert(tab) }
        .sheet(isPresented: $showProfile) {
            ProfileView().environment(store)
        }
        .sheet(item: $agentTask) { target in AgentTaskSheet(taskID: target.id).environment(store) }
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

    @ViewBuilder
    private func screen(for tab: StackTab) -> some View {
        switch tab {
        case .jobs: JobsView(onProfile: { showProfile = true })
        case .applications: ApplicationsView(onProfile: { showProfile = true }, onNavigate: { selection = $0 })
        case .network: NetworkView(onProfile: { showProfile = true })
        case .resume: ResumeView(onProfile: { showProfile = true })
        case .prep: PrepView(isActive: selection == .prep && !showProfile)
        }
    }
}

private struct TabBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: StackTab
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StackTab.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : Motion.ease(0.32)) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        GlyphView(name: tab.icon, size: 21, color: selection == tab ? Palette.icon : Palette.muted)
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Palette.icon : Palette.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Palette.halo.opacity(0.7))
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
        .background(Palette.page)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
