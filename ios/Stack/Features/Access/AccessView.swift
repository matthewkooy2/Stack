import SwiftUI

/// Welcome, then sign in or create an account. Moves between the two with the shared stage motion.
@MainActor
struct AccessView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.markInFlight) private var markInFlight

    enum Step: Int, StageKey {
        case welcome, signIn, signUp
        var depth: Int { self == .welcome ? 0 : 1 }
    }

    @State private var step: Step
    @State private var username = ""
    @State private var password = ""
    @State private var invite = ""
    @State private var invitationOpen = false

    init(initialStep: Step = .welcome) { _step = State(initialValue: initialStep) }

    var body: some View {
        Stage(key: step) {
            switch step {
            case .welcome: welcome
            case .signIn, .signUp: form
            }
        }
        .padding(.horizontal, Spacing.page)
        .padding(.vertical, 24)
        .background(Brand.page.ignoresSafeArea())
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The mark takes all the room above the buttons.
            GeometryReader { geo in
                StackMark(size: max(120, min(geo.size.width, geo.size.height)), animateIn: !markInFlight)
                    .reportsMarkFrame()
                    .opacity(markInFlight ? 0 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.bottom, 16)
            StoreMessages()
            VStack(spacing: 12) {
                if AppleSignIn.enabled {
                    AppleAccountButton(disabled: store.busy || store.googlePending) { window in
                        Task { await store.signInWithApple(window: window) }
                    }.frame(height: 54)
                }
                GoogleSignInButton(label: store.googlePending ? "Waiting for Google…" : "Continue with Google",
                                   disabled: store.googlePending || store.busy) {
                    Task { await store.signInWithGoogle() }
                }
                if store.googlePending {
                    StackButton(label: "Cancel Google sign-in", kind: .secondary) { store.cancelGoogle() }
                }
                OrDivider().padding(.vertical, 2)
                Button { go(.signUp) } label: {
                    Text("Create an account")
                        .font(.system(.headline).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Brand.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.98))
                .disabled(store.googlePending)
                Button { go(.signIn) } label: {
                    (Text("Already have an account? ").foregroundStyle(Brand.muted)
                        + Text("Sign in").foregroundStyle(Brand.ink).fontWeight(.semibold))
                        .font(Typeface.caption)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.985))
                .disabled(store.googlePending)
                .accessibilityLabel("Sign in")
            }
            .reveal(3, delay: 0.55)
        }
    }

    private var form: some View {
        let signUp = step == .signUp
        return GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            AccessBackButton { go(.welcome) }.disabled(store.busy).reveal(0)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: -10) {
                    Text(signUp ? "Create your" : "Welcome").foregroundStyle(Brand.ink)
                    Text(signUp ? "account." : "back.").foregroundStyle(Brand.accent)
                }
                .font(.system(size: 48, weight: .heavy))
                .tracking(-2.2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                Text(signUp ? "It takes less than a minute." : "Sign in to pick up where you left off.")
                    .font(.system(.title3)).foregroundStyle(Brand.muted)
            }
            .padding(.top, 28)
            .reveal(1)
            VStack(spacing: 18) {
                AccessField(label: "Username", text: $username, keyboard: .asciiCapable, autocapitalization: .never)
                AccessField(label: "Password", text: $password, placeholder: "At least 8 characters", secure: true)
                if invitationOpen {
                    AccessField(label: "Beta invitation (first visit)", text: $invite, placeholder: "Invitation code",
                                keyboard: .asciiCapable, autocapitalization: .never)
                } else {
                    Button {
                        withAnimation(Motion.fadeAnimation) { invitationOpen = true }
                    } label: {
                        Text("I have an invitation code").font(Typeface.caption).fontWeight(.semibold).foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.tap(scale: 0.985))
                }
            }
            .padding(.top, 32)
            .reveal(2)
            Text(store.error)
                .font(Typeface.caption).foregroundStyle(Palette.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .accessibilityAddTraits(.updatesFrequently)
                .fadeSwitch(!store.error.isEmpty, keep: false)
            Spacer(minLength: 24)
            Button {
                Task {
                    await store.signIn(username: username, password: password, signUp: signUp, invite: invite)
                    password = ""
                }
            } label: {
                ZStack {
                    Text(signUp ? "Create account" : "Sign in").opacity(store.busy ? 0 : 1)
                    if store.busy { ProgressView().tint(.white) }
                }
                .font(.system(.headline).weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Brand.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.98))
            .disabled(store.busy)
            .accessibilityLabel(signUp ? "Create account" : "Sign in")
            .reveal(3)
            Button { go(signUp ? .signIn : .signUp) } label: {
                (Text(signUp ? "Already have an account? " : "New here? ").foregroundStyle(Brand.muted)
                    + Text(signUp ? "Sign in" : "Create an account").foregroundStyle(Brand.ink).fontWeight(.semibold))
                    .font(Typeface.caption)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.985))
            .disabled(store.busy)
            .accessibilityLabel(signUp ? "Already have an account? Sign in" : "New here? Create an account")
        }
        .frame(minHeight: geometry.size.height, alignment: .topLeading)
        }
        .scrollDismissesKeyboard(.immediately)
        .scrollIndicators(.hidden)
        }
    }

    private func go(_ next: Step) {
        store.error = ""
        withAnimation(Motion.stageAnimation) { step = next }
    }
}

/// Shown when the account is signed in but has not been admitted to the beta.
@MainActor
struct InvitationView: View {
    @Environment(AppStore.self) private var store
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.stack) {
                Text("Enter your invitation").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink).reveal(0)
                StackField(label: "Beta invitation", text: $code, keyboard: .asciiCapable, autocapitalization: .never).reveal(1)
                MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                StackButton(label: "Continue", disabled: store.busy || code.isBlank) { Task { await store.acceptInvitation(code) } }.reveal(2)
                if store.googleInfo["can_recover"].bool {
                    GoogleAccountCard().reveal(3)
                }
                StackButton(label: "Sign out", kind: .secondary, disabled: store.busy) { Task { await store.signOut() } }
                if store.apple.hasAppleSession { AppleAccountCard() }
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }
}

/// Apple account deletion, including before beta admission.
@MainActor
struct AppleAccountCard: View {
    @Environment(AppStore.self) private var store
    @State private var deletionWindow: UIWindow?
    @State private var confirmDeletion = false
    var body: some View {
        Card(spacing: 12) {
            Text("Delete account").font(Typeface.section)
            Text("Delete your Stack account with fresh Apple confirmation. This removes saved Stack data and revokes its Apple grant.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            Button("Delete account", role: .destructive) {
                deletionWindow = UIApplication.shared.connectedScenes
                    .filter { $0.activationState == .foregroundActive }
                    .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
                confirmDeletion = true
            }.disabled(store.busy || store.googlePending)
        }
        .alert("Delete your Stack account?", isPresented: $confirmDeletion) {
            Button("Delete account", role: .destructive) {
                if let window = deletionWindow { Task { await store.deleteWithApple(window: window) } }
                deletionWindow = nil
            }
            Button("Cancel", role: .cancel) { deletionWindow = nil }
        } message: { Text("Your saved Stack data will be permanently removed after Apple confirms this account. You can then sign up again using any sign-in method.") }
    }
}

/// Google sign-in state for the account: link Google, or keep an original Stack account.
@MainActor
struct GoogleAccountCard: View {
    @Environment(AppStore.self) private var store
    @State private var username = ""
    @State private var password = ""
    @State private var recovering = false

    private var info: JSON { store.googleInfo }

    var body: some View {
        Card(spacing: 12) {
            Text("Your sign-in").font(Typeface.section).foregroundStyle(Palette.ink)
            if !info["username"].string.isEmpty {
                Text("Signed in as \(info["username"].string)").font(Typeface.body).foregroundStyle(Palette.text)
            }
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
            if info["can_recover"].bool, !recovering {
                StackButton(label: "Use my existing Stack account", kind: .secondary) {
                    withAnimation(Motion.fadeAnimation) { recovering = true }
                }
            }
            if info["can_recover"].bool, recovering {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Confirm your original Stack sign-in to keep its saved data.")
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
                    StackButton(label: "Cancel", kind: .secondary, disabled: store.busy) {
                        password = ""
                        withAnimation(Motion.fadeAnimation) { recovering = false }
                    }
                }
            }
        }
    }
}

// MARK: - Form pieces

private struct AccessBackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .frame(width: 44, height: 44)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Brand.rule, lineWidth: 1))
        }
        .buttonStyle(.tap(scale: 0.92, dim: 1))
        .accessibilityLabel("Back")
    }
}

/// A white field with a hairline border that turns blue while it has focus.
private struct AccessField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Typeface.caption).fontWeight(.semibold).foregroundStyle(Brand.ink)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .focused($focused)
            .font(Typeface.body)
            .accessibilityLabel(label)
            .foregroundStyle(Brand.ink)
            .tint(Brand.accent)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(keyboard != .default || secure)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? Brand.accent : Brand.rule, lineWidth: focused ? 2 : 1))
            .animation(Motion.fadeAnimation, value: focused)
        }
    }
}

// MARK: - Welcome pieces

/// "Continue with Google" using the multicolor G on a white button with a neutral outline, per Google's branding.
@MainActor
private struct GoogleSignInButton: View {
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("GoogleG").resizable().scaledToFit().frame(width: 20, height: 20)
                Text(label).font(.system(.headline).weight(.medium)).foregroundStyle(Color(hex: 0x1F1F1F))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(hex: 0x747775), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.98))
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

private struct OrDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Brand.rule).frame(height: 1)
            Text("or").font(Typeface.caption).foregroundStyle(Brand.muted)
            Rectangle().fill(Brand.rule).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}
