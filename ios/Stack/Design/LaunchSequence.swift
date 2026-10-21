import SwiftUI

/// The cold-start sequence, one continuous motion. The app opens on the same blue as the icon and the coins drop in
/// white. As the last coin lands the field turns to the page colour and the coins to blue, and while that is still
/// blending the mark glides to its place on the destination, which fades in around it. The mark that flies is an
/// overlay above everything; the destination's own copy stays hidden until it lands, so nothing is ever swapped
/// mid-air.
@MainActor
struct LaunchSequence<Destination: View>: View {
    /// True once there is somewhere to go (the account has loaded, or failed).
    let isReady: Bool
    @ViewBuilder var destination: () -> Destination

    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var started = false
    @State private var minimumShown = false
    @State private var showsDestination = false
    @State private var landed = false
    @State private var look = 0.0
    @State private var field = Brand.accent
    @State private var lightStatusBar = true
    @State private var target: CGRect?
    @State private var flying = false
    @State private var vanish = false

    private static var markSize: CGFloat { 230 }
    private var canGo: Bool { minimumShown && isReady }

    var body: some View {
        ZStack {
            field.ignoresSafeArea()
            if showsDestination {
                destination()
                    .environment(\.markInFlight, !landed)
                    .transition(.opacity)
            }
        }
        .onPreferenceChange(MarkFrameKey.self) { target = $0 }
        .overlay { flyingMark }
        .preferredColorScheme(lightStatusBar ? .dark : nil)
        .task {
            // The drop takes about a second; start the hand-off as the last coin lands.
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : 1.05))
            minimumShown = true
        }
        .onChange(of: canGo) { _, go in
            if go && !started { started = true; Task { await run() } }
        }
    }

    @ViewBuilder private var flyingMark: some View {
        if !landed {
            GeometryReader { screen in
                let home = CGPoint(x: screen.size.width / 2, y: screen.size.height / 2)
                let there = flying ? target : nil
                StackMark(look: look, size: Self.markSize)
                    .frame(width: Self.markSize, height: Self.markSize)
                    .scaleEffect(there.map { $0.width / Self.markSize } ?? (vanish ? 1.12 : 1))
                    .opacity(vanish ? 0 : 1)
                    .position(there.map { CGPoint(x: $0.midX, y: $0.midY) } ?? home)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private func run() async {
        let blend = reduceMotion ? 0.01 : 0.7
        // 1. The colours turn over.
        withAnimation(.easeInOut(duration: blend)) {
            look = 1
            field = Brand.page
        }
        // 2. Part-way through, the destination fades in and the mark sets off for it.
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.02 : 0.3))
        lightStatusBar = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.45)) { showsDestination = true }
        try? await Task.sleep(for: .milliseconds(60))   // let the destination report where its mark goes
        if target != nil {
            withAnimation(reduceMotion ? nil : .spring(response: 0.85, dampingFraction: 0.84)) { flying = true }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.05 : 0.95))
        } else {
            // Nothing to land on (the account's tabs): let the mark ease away.
            withAnimation(.easeIn(duration: reduceMotion ? 0.01 : 0.4)) { vanish = true }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.05 : 0.45))
        }
        landed = true
    }
}
