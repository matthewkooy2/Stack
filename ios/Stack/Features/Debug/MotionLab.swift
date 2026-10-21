#if DEBUG
import SwiftUI

/// Debug-only way to review animations without signing out or relaunching. A slim handle on the right edge of the real
/// app opens a bar over whatever screen is showing: "Replay screen" rebuilds it so its entrance runs again (any screen
/// marked `.replayable()`), and "Preview" opens full-screen examples that can't be reached while signed in.
/// Excluded from Release builds. Previews run on the offline fixture store, never the signed-in session.
///
/// To make a new screen reviewable: add `.replayable()` to it, and, if it is only reachable in a particular state,
/// add a case to `LabScreen`.
enum LabScreen: String, CaseIterable, Identifiable {
    case launch = "Launch screen", login = "Login screen", signIn = "Sign-in form", signUp = "Create-account form"
    var id: String { rawValue }
}

@MainActor
private struct MotionLabPreview: View {
    let initial: LabScreen
    @Environment(\.dismiss) private var dismiss
    @State private var screen: LabScreen
    @State private var take = 0
    @State private var fixture = ScreenFlowUITestScene.makeStore(flow: "onboarding")

    init(initial: LabScreen) {
        self.initial = initial
        _screen = State(initialValue: initial)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            preview.id("\(screen.rawValue)-\(take)")
            HStack(spacing: 10) {
                Picker("Screen", selection: $screen) {
                    ForEach(LabScreen.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Button { take += 1 } label: { Label("Replay", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
            }
            .padding(10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 8)
        }
        .environment(fixture)
    }

    @ViewBuilder private var preview: some View {
        switch screen {
        case .launch:
            ZStack {
                Brand.page.ignoresSafeArea()
                StackBars(scale: 0.7)
            }
        case .login:
            AccessView()
        case .signIn:
            AccessView(initialStep: .signIn)
        case .signUp:
            AccessView(initialStep: .signUp)
        }
    }
}

private struct MotionLabHost: ViewModifier {
    @State private var barOpen = false
    @State private var token = 0
    @State private var preview: LabScreen?

    func body(content: Content) -> some View {
        content
            .environment(\.replayToken, token)
            .overlay(alignment: .trailing) {
                Button { withAnimation(.snappy) { barOpen.toggle() } } label: {
                    Image(systemName: barOpen ? "chevron.right" : "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 44)
                        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8))
                }
                .accessibilityLabel("Motion lab")
            }
            .overlay(alignment: .bottom) {
                if barOpen {
                    HStack(spacing: 10) {
                        Button { token += 1 } label: { Label("Replay screen", systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderedProminent)
                        Menu {
                            ForEach(LabScreen.allCases) { item in Button(item.rawValue) { preview = item } }
                        } label: { Label("Preview", systemImage: "rectangle.on.rectangle") }
                            .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.bottom, 84)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .fullScreenCover(item: $preview) { MotionLabPreview(initial: $0) }
    }
}

extension View {
    /// Adds the debug motion lab. Only called from DEBUG code.
    func motionLab() -> some View { modifier(MotionLabHost()) }
}
#endif
