import SwiftUI

/// Shared motion, ported from the Prep workflow: one easing curve and one set of durations so every
/// screen moves in step. Entrance motion is skipped and loops stop when Reduce Motion is on.
enum Motion {
    static let stage = 0.30
    static let reveal = 0.36
    static let stagger = 0.055
    static let press = 0.09
    static let fade = 0.20
    static let out = 0.14
    static let loop = 2.0

    /// cubic-bezier(.22, 1, .36, 1)
    static func ease(_ duration: Double) -> Animation { .timingCurve(0.22, 1, 0.36, 1, duration: duration) }
    static var stageAnimation: Animation { ease(stage) }
    static var revealAnimation: Animation { ease(reveal) }
    static var fadeAnimation: Animation { ease(fade) }
    static var release: Animation { .spring(response: 0.28, dampingFraction: 0.62) }
    static var pop: Animation { .spring(response: 0.38, dampingFraction: 0.55) }
}

// MARK: - Page stage

/// Order of the setup → answer → coaching path, so a page can tell whether the person moved on or back.
protocol StageKey: Hashable {
    var depth: Int { get }
}

/// Slides the new page in from the side it was reached from. Re-key it (`.id`) to replay.
struct StageEntrance: ViewModifier {
    let direction: CGFloat
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || shown ? 1 : 0)
            .offset(x: reduceMotion || shown ? 0 : direction * 22)
            .animation(reduceMotion ? nil : Motion.stageAnimation, value: shown)
            .onAppear {
                if reduceMotion { shown = true }
                else { DispatchQueue.main.async { shown = true } }
            }
    }
}

/// Wraps a page so that changing `key` replays its entrance from the direction of travel.
@MainActor
struct Stage<Key: StageKey, Content: View>: View {
    let key: Key
    var step: Int = 0
    @ViewBuilder var content: () -> Content

    @State var memory = Memory()

    final class Memory {
        var key: AnyHashable?
        var depth = 0
        var step = 0
        var direction: CGFloat = 1
    }

    var body: some View {
        let direction = resolveDirection()
        content()
            .modifier(StageEntrance(direction: direction))
            .id(key)
    }

    private func resolveDirection() -> CGFloat {
        let was = memory
        if was.key != AnyHashable(key) {
            if was.key != nil {
                if step != was.step { was.direction = step > was.step ? 1 : -1 }
                else { was.direction = key.depth >= was.depth ? 1 : -1 }
            }
            was.key = AnyHashable(key)
            was.depth = key.depth
            was.step = step
        }
        return was.direction
    }
}

// MARK: - Reveal, tap, pop

/// Content rises into place on appear; `index` staggers siblings.
struct Reveal: ViewModifier {
    var index = 0
    var delay = 0.0
    var rise: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || shown ? 1 : 0)
            .offset(y: reduceMotion || shown ? 0 : rise)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                let wait = 0.04 + delay + Double(min(index, 8)) * Motion.stagger
                withAnimation(Motion.revealAnimation.delay(wait)) { shown = true }
            }
    }
}

extension View {
    func reveal(_ index: Int = 0, delay: Double = 0, rise: CGFloat = 14) -> some View {
        modifier(Reveal(index: index, delay: delay, rise: rise))
    }
}

/// A soft press-in, a springy release, and a fade (rather than a snap) when the control enables or disables.
struct TapStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    var dim: Double = 0.45
    @Environment(\.isEnabled) var isEnabled
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(isEnabled ? 1 : dim)
            .animation(
                configuration.isPressed ? .easeOut(duration: Motion.press) : Motion.release,
                value: configuration.isPressed
            )
            .animation(reduceMotion ? nil : Motion.fadeAnimation, value: isEnabled)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

extension ButtonStyle where Self == TapStyle {
    static var tap: TapStyle { TapStyle() }
    static func tap(scale: CGFloat, dim: Double = 0.45) -> TapStyle { TapStyle(pressedScale: scale, dim: dim) }
}

/// Small springy pop-in for marks such as a completed day.
struct Pop: ViewModifier {
    var delay = 0.0
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion || shown ? 1 : 0.5)
            .opacity(reduceMotion || shown ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(Motion.pop.delay(delay)) { shown = true }
            }
    }
}

extension View {
    func pop(delay: Double = 0) -> some View { modifier(Pop(delay: delay)) }

    /// Fades content in and out. With `keep`, hidden content still holds its layout space.
    func fadeSwitch(_ show: Bool, keep: Bool = false) -> some View {
        modifier(FadeSwitch(show: show, keep: keep))
    }
}

struct FadeSwitch: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let show: Bool
    let keep: Bool

    func body(content: Content) -> some View {
        ZStack {
            if keep || show { content.opacity(show ? 1 : 0).transition(.opacity) }
        }
        .animation(reduceMotion ? nil : (show ? Motion.fadeAnimation : Motion.ease(Motion.out)), value: show)
    }
}

// MARK: - Looping states

/// A soft disc behind an icon; while active, a ring expands from it (recording, working).
@MainActor
struct Halo<Content: View>: View {
    var active = false
    var size: CGFloat = 88
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        let moving = active && !reduceMotion
        ZStack {
            TimelineView(.animation(paused: !moving)) { timeline in
                let phase = moving
                    ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Motion.loop) / Motion.loop
                    : 0
                let eased = 1 - (1 - phase) * (1 - phase)
                Circle()
                    .fill(Palette.ring)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + 0.75 * eased)
                    .opacity(moving ? 0.6 * (1 - eased) : 0)
            }
            Circle().fill(Palette.halo).frame(width: size, height: size)
            content()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
    }
}

/// Gentle opacity breathing for "working" states.
struct Breathe: ViewModifier {
    var active = true
    var minimum = 0.45
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    func body(content: Content) -> some View {
        let moving = active && !reduceMotion
        TimelineView(.animation(paused: !moving)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let wave = 0.5 - 0.5 * cos(2 * .pi * seconds / 2.6)
            content.opacity(moving ? 1 - (1 - minimum) * wave : 1)
        }
    }
}

extension View {
    func breathe(_ active: Bool = true, minimum: Double = 0.45) -> some View {
        modifier(Breathe(active: active, minimum: minimum))
    }
}
