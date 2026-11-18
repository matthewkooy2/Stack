import SwiftUI

/// Welcome, then sign in or create an account. Moves between the two with the shared stage motion.
@MainActor
struct AccessView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion

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
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    VStack(spacing: 2) {
                        StackMark(size: min(128, max(72, geometry.size.height * 0.17)), animateIn: false)
                            .accessibilityHidden(true)
                        Text("Stack")
                            .font(Typeface.display)
                            .foregroundStyle(Brand.ink)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 24)
                    welcomeActions
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var welcomeActions: some View {
        VStack(spacing: 0) {
            StoreMessages()
            VStack(spacing: 12) {
                if AppleSignIn.enabled {
                    AppleAccountButton(disabled: store.busy || store.googlePending) { window in
                        Task { await store.signInWithApple(window: window) }
                    }.frame(height: 54)
                }
                GoogleSignInButton(label: store.googlePending ? "Signing you in…" : "Continue with Google",
                                   disabled: store.googlePending || store.busy) {
                    Task { await store.signInWithGoogle() }
                }
                if store.googlePending {
                    StackButton(label: "Cancel Google sign-in", kind: .secondary) { store.cancelGoogle() }
                }
                OrDivider().padding(.vertical, 2)
                StackButton(label: "Create an account", disabled: store.googlePending) { go(.signUp) }
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
                HStack(spacing: 16) {
                    Link("Privacy policy", destination: URL(string: "https://stackmvp.top/privacy")!)
                    Link("Support", destination: URL(string: "https://stackmvp.top/support")!)
                }
                .font(.footnote)
                .tint(Brand.muted)
            }
        }
    }

    private var form: some View {
        let signUp = step == .signUp
        return GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 0) {
            BackButton { go(.welcome) }.disabled(store.busy).reveal(0)
            Text(signUp ? "Create your account" : "Welcome back")
                .font(Typeface.display)
                .foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
                .reveal(1)
            VStack(spacing: 18) {
                AccessField(label: "Username", text: $username, keyboard: .asciiCapable, autocapitalization: .never, contentType: .username)
                AccessField(label: "Password", text: $password, placeholder: signUp ? "At least 8 characters" : "", secure: true, contentType: signUp ? .newPassword : .password)
                if invitationOpen {
                    AccessField(label: "Beta invitation (first visit)", text: $invite, placeholder: "Invitation code",
                                keyboard: .asciiCapable, autocapitalization: .never)
                } else {
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { invitationOpen = true }
                    } label: {
                        Text("I have an invitation code").font(Typeface.caption).fontWeight(.semibold).foregroundStyle(Brand.accent)
                            .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
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
                .background(Palette.button, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        withAnimation(reduceMotion ? nil : Motion.stageAnimation) { step = next }
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
                Text("Enter your invitation").font(Typeface.display).tracking(-1.8).foregroundStyle(Palette.ink).reveal(0)
                StackField(label: "Beta invitation", text: $code, keyboard: .asciiCapable, autocapitalization: .never).reveal(1)
                MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                StackButton(label: "Continue", disabled: store.busy || code.isBlank) { Task { await store.acceptInvitation(code) } }.reveal(2)
                if store.googleInfo["can_recover"].bool {
                    GoogleAccountCard().reveal(3)
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
                StackButton(label: store.googlePending ? "Connecting…" : "Link Google sign-in",
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

private struct AccessField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var contentType: UITextContentType? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Typeface.caption).fontWeight(.semibold).foregroundStyle(Brand.ink)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .focused($focused)
            .textContentType(contentType)
            .font(Typeface.body)
            .accessibilityLabel(label)
            .foregroundStyle(Brand.ink)
            .tint(Brand.accent)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(keyboard != .default || secure)
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(focused ? Brand.accent : Brand.rule, lineWidth: focused ? 2 : 1))
            .animation(Motion.fadeAnimation, value: focused)
        }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                }
            }
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
