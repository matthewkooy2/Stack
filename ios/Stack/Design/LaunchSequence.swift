import SwiftUI

/// Displays the mark only while the account is restoring. A cached session can enter immediately.
@MainActor
struct LaunchSequence<Destination: View>: View {
    let isReady: Bool
    @ViewBuilder var destination: () -> Destination
    @Environment(\.stackReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isReady {
                destination().transition(.opacity)
            } else {
                ZStack {
                    Brand.page.ignoresSafeArea()
                    VStack(spacing: 20) {
                        StackMark(size: 80, animateIn: false)
                        ProgressView().tint(Brand.muted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Opening Stack")
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: isReady)
    }
}
