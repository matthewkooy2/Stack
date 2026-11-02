import SwiftUI

/// A short optional setup for a new account. The choices seed its first saved job search.
@MainActor
struct JobOnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    let onDone: () -> Void
    @State private var role = ""
    @State private var location = ""
    @State private var picker = ""
    @State private var finished = false
    @State private var working = false
    @State private var error = ""

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            if picker == "role" {
                RoleChoiceView(current: role, onSelect: { role = $0; picker = "" }, onBack: { picker = "" })
            } else if picker == "location" {
                LocationChoiceView(onSelect: { location = $0; picker = "" }, onBack: { picker = "" })
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 56)
                    Text(finished ? "You’re all set." : "A little about\nyour search.")
                        .font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink).reveal(0)
                    Text(finished ? "You can update your preferences anytime." : "This helps us get started.")
                        .font(Typeface.body).foregroundStyle(Brand.muted).padding(.top, 12).reveal(1)
                    if !finished {
                        VStack(alignment: .leading, spacing: 24) {
                            selection("Role or job title", value: role.isEmpty ? "Choose a role" : role) { picker = "role" }
                            selection("City or state", value: location.isEmpty ? "Choose a location" : location) { picker = "location" }
                        }.padding(.top, 44).reveal(2)
                    }
                    Spacer(minLength: 24)
                    MessageLine(text: error).fadeSwitch(!error.isEmpty)
                    StackButton(label: finished ? "Explore jobs" : (working ? "Saving…" : "Continue"), disabled: working) {
                        if finished { onDone() } else { Task { await save() } }
                    }
                    if !finished {
                        Button("Skip for now") { onDone() }.font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(working)
                    }
                }.padding(.horizontal, Spacing.page).padding(.bottom, 16)
            }
        }.replayable()
    }
    private func selection(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text(label).fontWeight(.semibold) + Text(" (optional)").foregroundColor(Brand.muted))
                .font(Typeface.caption).foregroundStyle(Brand.ink)
            Button(action: action) {
                HStack { Text(value).foregroundStyle(Brand.muted); Spacer(); Image(systemName: "chevron.down").foregroundStyle(Brand.muted) }
                    .padding(.horizontal, 16).frame(height: 54).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
        }
    }
    private func save() async {
        guard !working else { return }; working = true; error = ""; defer { working = false }
        guard !role.isEmpty || !location.isEmpty else { withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { finished = true }; return }
        let userID = store.account.userID
        var filters = store.account.savedSearch["filters"]
        if !location.isEmpty { filters["location"] = .string(location) }
        if !role.isEmpty { filters["any_role"] = .bool(false) }
        do {
            let query = role.isEmpty ? store.account.savedSearch["query"].string : role
            let result = try await store.call("save_search", ["query": .string(query), "filters": filters])
            guard store.account.userID == userID else { return }
            store.account.raw["saved_search"] = ["query": result["query"], "filters": result["filters"]]
            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { finished = true }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}
