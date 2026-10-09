import SwiftUI

/// Welcome, then sign in or create an account. Moves between the two with the shared stage motion.
struct AccessView: View {
    @Environment(AppStore.self) private var store

    enum Step: Int, StageKey {
        case welcome, signIn, signUp
        var depth: Int { self == .welcome ? 0 : 1 }
    }

    @State private var step: Step = .welcome
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var invitationOpen = false

    var body: some View {
        Stage(key: step) {
            switch step {
            case .welcome: welcome
            case .signIn, .signUp: form
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, 24)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("stack")
                .font(.system(size: 52, weight: .bold))
                .tracking(-2.1)
                .foregroundStyle(Palette.ink)
                .reveal(0)
            Text("Your next chapter, organized. Find roles, track applications and practice for the interview.")
                .font(Typeface.body)
                .foregroundStyle(Palette.muted)
                .reveal(1)
            Spacer()
            MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
            VStack(spacing: Spacing.option) {
                OptionRow(label: store.googlePending ? "Waiting for Google…" : "Continue with Google", icon: "link",
                          disabled: store.googlePending || store.busy, showsChevron: false) {
                    Task { await store.signInWithGoogle() }
                }
                .reveal(2)
                if store.googlePending {
                    StackButton(label: "Cancel Google sign-in", kind: .secondary) { store.cancelGoogle() }
                }
                OptionRow(label: "Create an account", icon: "add-session", oat: true, disabled: store.googlePending) { go(.signUp) }.reveal(3)
                OptionRow(label: "Sign in", icon: "continue-session", disabled: store.googlePending) { go(.signIn) }.reveal(4)
            }
            .padding(.bottom, 24)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            BackButton { go(.welcome) }.disabled(store.busy)
            Text(step == .signUp ? "Create your account" : "Welcome back")
                .font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            VStack(spacing: 18) {
                StackField(label: "Username", text: $username, keyboard: .asciiCapable, autocapitalization: .never)
                StackField(label: "Password", text: $password, placeholder: "At least 8 characters", secure: true)
                if invitationOpen {
                    StackField(label: "Beta invitation (first visit)", text: $invite, placeholder: "Invitation code",
                               keyboard: .asciiCapable, autocapitalization: .never)
                } else {
                    StackButton(label: "I have an invitation code", kind: .secondary) {
                        withAnimation(Motion.fadeAnimation) { invitationOpen = true }
                    }
                }
            }
            .reveal(0)
            MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty, keep: false)
            Spacer()
            StackButton(label: step == .signUp ? "Create account" : "Sign in", disabled: store.busy) {
                Task {
                    await store.signIn(username: username, password: password, signUp: step == .signUp, invite: invite)
                    password = ""
                }
            }
            .reveal(1)
            StackButton(label: step == .signUp ? "Already have an account? Sign in" : "New here? Create an account",
                        kind: .secondary, disabled: store.busy) { go(step == .signUp ? .signIn : .signUp) }
            if store.busy { ProgressView().tint(Palette.muted).frame(maxWidth: .infinity) }
        }
    }

    private func go(_ next: Step) {
        store.error = ""
        withAnimation(Motion.stageAnimation) { step = next }
    }
}

/// Shown when the account is signed in but has not been admitted to the beta.
struct InvitationView: View {
    @Environment(AppStore.self) private var store
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.stack) {
                Text("Finish signing in").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink).reveal(0)
                Text("Your account is authenticated. A beta invitation is required to enter Stack.")
                    .font(Typeface.body).foregroundStyle(Palette.muted).reveal(1)
                StackField(label: "Beta invitation", text: $code, keyboard: .asciiCapable, autocapitalization: .never).reveal(2)
                MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                StackButton(label: "Continue", disabled: store.busy) { Task { await store.acceptInvitation(code) } }.reveal(3)
                if store.googleInfo["can_recover"].bool {
                    GoogleAccountCard().reveal(4)
                }
                StackButton(label: "Sign out", kind: .secondary, disabled: store.busy) { Task { await store.signOut() } }
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }
}

/// Google sign-in state for the account: link Google, or keep an original Stack account.
struct GoogleAccountCard: View {
    @Environment(AppStore.self) private var store
    @State private var username = ""
    @State private var password = ""

    private var info: JSON { store.googleInfo }

    var body: some View {
        Card(spacing: 12) {
            Text("Your sign-in").font(Typeface.section).foregroundStyle(Palette.ink)
            if !info["username"].string.isEmpty {
                Text("Signed in as \(info["username"].string)").font(Typeface.body).foregroundStyle(Palette.text)
            }
            Text("Your resumes, applications, contacts and practice are saved to this account.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if info["google"].bool {
                Text("Google sign-in linked").font(Typeface.body).foregroundStyle(Palette.success)
            } else {
                StackButton(label: store.googlePending ? "Waiting for Google…" : "Link Google sign-in",
                            disabled: store.googlePending || store.busy) {
                    Task { await store.signInWithGoogle(link: true) }
                }
            }
            if store.googlePending {
                StackButton(label: "Cancel Google sign-in", kind: .secondary) { store.cancelGoogle() }
            }
            if info["can_recover"].bool {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Use your existing Stack account").font(Typeface.body).foregroundStyle(Palette.ink)
                    Text("Confirm your original Stack credentials to preserve its account and saved data.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    StackField(label: "Existing Stack username", text: $username, keyboard: .asciiCapable, autocapitalization: .never)
                    StackField(label: "Existing Stack password", text: $password, secure: true)
                    StackButton(label: "Use my existing Stack account",
                                disabled: store.busy || username.isBlank || password.isEmpty) {
                        Task {
                            await store.recoverGoogle(username: username, password: password)
                            password = ""
                        }
                    }
                }
            }
        }
    }
}
