import SwiftUI

enum Motion {
    static let layout = Animation.spring(response: 0.42, dampingFraction: 0.9)
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.8)
    static let reveal = Animation.easeOut(duration: 0.42)
}

struct MotionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}

struct RoundedActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 9)
            .background(.white.opacity(configuration.isPressed ? 0.1 : 0.055), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
    }
}

private struct SoftAppear: ViewModifier {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .offset(y: reduceMotion || visible ? 0 : 9)
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : Motion.reveal.delay(min(Double(index) * 0.028, 0.18))) { visible = true }
            }
    }
}
extension View {
    func softAppear(index: Int = 0) -> some View { modifier(SoftAppear(index: index)) }
}
