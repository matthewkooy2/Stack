import SwiftUI
import UIKit

/// The LinkedIn design connected to the existing browser and raw coaching endpoints.
@MainActor
struct LinkedInFlow: View {
    enum Step: Int, StageKey { case url, role, login, ready, scanning, results, scanError; var depth: Int { rawValue } }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppStore.self) private var store
    @State private var step: Step = .url
    @State private var id = ""
    @State private var url = ""
    @State private var role = ""
    @State private var paused = false
    @State private var showRewrites = false
    @State private var reviewText = ""
    @State private var editedReview = ""
    @State private var error = ""
    @State private var run: JSON = .null
    @State private var browser = RemoteBrowserModel()
    @State private var analysis: Task<Void, Never>?
    private var emptyReview: Bool { reviewText.isEmpty }
    private var scanning: Bool { step == .scanning && !paused && scenePhase == .active }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                Stage(key: step) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.stack) {
                            content(browserHeight: max(260, min(430, geometry.size.height * 0.51)))
                        }
                        .padding(.horizontal, Spacing.page)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
                .frame(maxHeight: .infinity)
                footer
            }
        }
        .background(Palette.page.ignoresSafeArea())
        .tint(Palette.dark)
        .task(id: scanning) {
            while scanning && !Task.isCancelled {
                do {
                    let latest = try await store.call("agent_run", ["id": .string(id)], linkedin: true)
                    run = latest
                    if ["completed", "failed"].contains(latest["status"].string) { apply(latest); return }
                    try await Task.sleep(for: .seconds(1))
                } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { browser.reconnect() } else { browser.background() }
        }
        .onDisappear { browser.close(); analysis?.cancel() }
        .sheet(isPresented: $showRewrites) {
            LinkedInCoachingEditor(text: $editedReview)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            BackButton(label: "Back") { back() }
            Spacer()
            if step == .role {
                Button("Skip") { role = ""; Task { await start() } }
                    .font(Typeface.body).foregroundStyle(Palette.text)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.tap)
                    .accessibilityIdentifier("linkedin-skip-role")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func content(browserHeight: CGFloat) -> some View {
        switch step {
        case .url:
            heading("Your LinkedIn profile", "Enter the profile you want to review.")
            StackField(label: "LinkedIn profile URL", text: $url, placeholder: "linkedin.com/in/your-name/",
                       keyboard: .URL, autocapitalization: .never)
                .accessibilityIdentifier("linkedin-profile-url").reveal(1)
        case .login:
            heading("Sign in to LinkedIn")
            LinkedInBrowser(model: browser, height: browserHeight + 65)
                .reveal(1)
        case .role:
            heading("Your target role", "Tailor the review to your next role.")
            StackField(label: "Role (optional)", text: $role, placeholder: "e.g. Data analyst")
                .accessibilityIdentifier("linkedin-target-role").reveal(1)
        case .ready:
            heading("Ready to review", role.isBlank ? "" : "For \(role.lowercased()) roles")
            LinkedInBrowser(model: browser, height: browserHeight)
                .reveal(1)
        case .scanning:
            heading(paused ? "Scan paused" : "Reviewing your profile")
            LinkedInBrowser(model: browser, height: browserHeight).reveal(1)
            VStack(alignment: .leading, spacing: 10) {
                Text(paused ? "Resume when you’re ready" : run["step_number"].int >= 2 ? "Preparing your review…" : "Reading your profile…")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                ProgressView(value: run["step_number"].int >= 2 ? 1 : 0, total: 2).tint(Palette.dark)
                    .accessibilityLabel("Scan progress")
            }.reveal(2)
        case .scanError:
            heading("Connection interrupted", error.isEmpty ? "Try again to continue your review." : error)
            LinkedInBrowser(model: browser, height: browserHeight).reveal(1)
        case .results:
            if emptyReview {
                heading("Nothing to review yet", "We couldn’t read your profile. Try scanning again.")
            } else {
                heading("Your LinkedIn review", role.isBlank ? "" : "For \(role.lowercased()) roles")
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Coaching")
                    Text(reviewText).font(Typeface.body).foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                }.reveal(1)
            }
        }
    }

    private func heading(_ title: String, _ subtitle: String = "") -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).font(Typeface.body).foregroundStyle(Palette.text) }
        }.reveal(0)
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            switch step {
            case .url:
                StackButton(label: "Continue") { hideKeyboard(); go(.role) }
            case .login:
                StackButton(label: "Continue") { hideKeyboard(); go(.ready) }
            case .role:
                StackButton(label: "Continue") { Task { await start() } }
            case .ready:
                StackButton(label: "Analyze my profile", icon: "sparkles") { analyze() }
                    .accessibilityIdentifier("linkedin-analyze")
            case .scanning:
                StackButton(label: paused ? "Resume scan" : "Take control", icon: paused ? "play" : "pause") {
                    if paused { analyze() }
                    else { Task { await browser.act("take"); paused = true } }
                }
                Button("Stop scan") {
                    analysis?.cancel()
                    Task { await browser.act("stop"); go(.ready) }
                }
                .font(Typeface.caption).foregroundStyle(Palette.muted).frame(minHeight: 44)
            case .scanError:
                StackButton(label: "Retry scan", icon: "refresh") { analyze() }
            case .results:
                if emptyReview {
                    StackButton(label: "Try scan again", icon: "refresh") { analyze() }
                } else {
                    StackButton(label: "Review rewrites") { showRewrites = true }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 12)
        .background(Palette.page)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rule.opacity(0.5)).frame(height: 0.5) }
    }

    private func start() async {
        hideKeyboard()
        error = ""
        do {
            let result = try await store.call("agent_linkedin_start", [
                "url": .string(LinkedInSetup.profileURL(url)),
                "target_role": .string(role)
            ], linkedin: true)
            id = result["id"].string
            run = result
            browser.open(store: store, id: id, linkedin: true, onChanged: {})
            go(.login)
        } catch {
            if !(error is CancellationError) {
                self.error = error.localizedDescription
                go(.scanError)
            }
        }
    }

    private func analyze() {
        hideKeyboard()
        error = ""
        paused = false
        go(.scanning)
        analysis = Task {
            await browser.finishInput()
            do {
                let result = try await store.call("agent_respond", [
                    "id": .string(id),
                    "target_role": .string(role)
                ], linkedin: true)
                if !Task.isCancelled { apply(result) }
            } catch {
                if !(error is CancellationError) {
                    self.error = error.localizedDescription
                    go(.scanError)
                }
            }
        }
    }

    private func apply(_ result: JSON) {
        run = result
        switch result["status"].string {
        case "completed":
            reviewText = result["artifacts"]["linkedin_review"]["summary"].string
            editedReview = reviewText
            go(.results)
        case "failed": error = result["message"].string; go(.scanError)
        case "paused": paused = true; go(.scanning)
        case "needs_input": go(.login)
        default: break
        }
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? nil : Motion.stageAnimation) { step = next }
    }
    private func back() {
        hideKeyboard()
        switch step {
        case .url: dismiss()
        case .role: go(.url)
        case .login: go(.role)
        case .ready: go(.login)
        case .scanning:
            analysis?.cancel()
            Task { await browser.act("take"); go(.ready) }
        case .scanError: go(.ready)
        case .results: go(.ready)
        }
    }
    private func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

@MainActor
private struct LinkedInCoachingEditor: View {
    @Binding var text: String
    @State private var copied = false

    var body: some View {
        SheetPage(title: "Suggested rewrites") {
            StackField(label: "Coaching", text: $text, multiline: true)
            StackButton(label: copied ? "Copied" : "Copy", kind: .secondary) {
                UIPasteboard.general.string = text
                copied = true
            }
        }
        .onChange(of: text) { _, _ in copied = false }
    }
}
