import SwiftUI

/// Everything inside a disc centred in the rect.
private struct Disc: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// Everything outside that disc (fill with the even-odd rule).
private struct Outside: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: 2 * radius, height: 2 * radius))
        return path
    }
}

/// The cold-start sequence, one continuous motion. The app opens on the same blue as the icon and the white coins
/// drop in. Then a ring of the page colour spreads out from the mark: inside it the field is the page and the coins
/// are blue, outside it they are still blue and white. Contrast between coins and field never drops, which a plain
/// cross-fade cannot avoid (white-to-blue coins and blue-to-white field pass through the same colour half-way).
/// While the ring is still spreading the mark glides to its place on the destination, which fades in beneath. The
/// mark that flies is an overlay; the destination's own copy stays hidden until it lands.
@MainActor
struct LaunchSequence<Destination: View>: View {
    /// True once there is somewhere to go (the account has loaded, or failed).
    let isReady: Bool
    @ViewBuilder var destination: () -> Destination

    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var started = false
    @State private var minimumShown = false
    @State private var mounted = false
    @State private var hold = true
    @State private var covered = false
    @State private var showsDestination = false
    @State private var landed = false
    @State private var reveal: CGFloat = 0
    @State private var target: CGRect?
    @State private var flying = false
    @State private var vanish = false

    private static var markSize: CGFloat { 230 }
    private var canGo: Bool { minimumShown && isReady }

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            // Built before it is needed, hidden, so its one-off start-up cost lands while nothing is moving.
            if mounted {
                destination()
                    .environment(\.markInFlight, !landed)
                    .environment(\.launchHold, hold)
                    .opacity(showsDestination ? 1 : 0)
                    .allowsHitTesting(landed)
            }
        }
        .onPreferenceChange(MarkFrameKey.self) { target = $0 }
        .overlay { splash }
        .task {
            // The drop takes about a second; the ring starts as the last coin lands.
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : 1.05))
            minimumShown = true
        }
        .onChange(of: canGo) { _, go in
            if go && !started { started = true; Task { await run() } }
        }
    }

    @ViewBuilder private var splash: some View {
        if !landed {
            GeometryReader { screen in
                let reach = hypot(screen.size.width, screen.size.height) / 2
                let radius = reveal * reach
                let there = flying ? target : nil
                ZStack {
                    // Always present: by the time the ring has grown past the corners there is nothing left of it.
                    // (Removing it when `reveal` reaches 1 would fade it out, since the state jumps to 1 at once.)
                    Outside(radius: radius).fill(Brand.accent, style: FillStyle(eoFill: true))
                    mark(look: 0, in: screen.size, there: there)
                        .mask { Outside(radius: radius).fill(Color.black, style: FillStyle(eoFill: true)) }
                        .opacity(covered ? 0 : 1)
                    mark(look: 1, in: screen.size, there: there)
                        .mask { Disc(radius: covered ? 10_000 : radius) }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    /// One copy of the mark. The white and the blue copies share this placement, so they stay exactly on top of
    /// each other while one hands over to the other.
    private func mark(look: Double, in size: CGSize, there: CGRect?) -> some View {
        StackMark(look: look, size: Self.markSize, animateIn: look == 0)
            .frame(width: Self.markSize, height: Self.markSize)
            .scaleEffect(there.map { $0.width / Self.markSize } ?? (vanish ? 1.12 : 1))
            .opacity(vanish ? 0 : 1)
            .position(there.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private func run() async {
        // 0. A beat: the coins have landed and nothing moves. Build the destination now, so any start-up hitch
        //    happens here, unseen, and the spot the mark will land on is known and fixed.
        mounted = true
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.02 : 0.25))
        // 1. The ring spreads from the mark.
        withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : 0.85)) { reveal = 1 }
        // 2. Part-way through, the destination's entrances begin and the mark sets off for it.
        try? await Task.sleep(for: .seconds(reduceMotion ? 0.02 : 0.35))
        hold = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.01 : 0.45)) { showsDestination = true }
        Task {
            // By now the ring has swallowed the white copy of the mark: stop drawing it, without animating.
            try? await Task.sleep(for: .seconds(0.2))
            withTransaction(Transaction(animation: nil)) { covered = true }
        }
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
