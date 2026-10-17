import SwiftUI

struct ReactionCount: Identifiable {
    var emoji: String
    var count: Int
    var selected: Bool
    var id: String { emoji }
    static func groups(_ values: [String: String], ownID: String) -> [ReactionCount] {
        ReactionCatalog.all.compactMap { emoji in
            let count = values.values.filter { $0 == emoji }.count
            return count == 0 ? nil : ReactionCount(emoji: emoji, count: count, selected: values[ownID] == emoji)
        }
    }
}

struct MessageReactionsView: View {
    var reactions: [String: String]
    var ownID: String
    var mine: Bool
    var choose: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips
            ScrollView(.horizontal, showsIndicators: false) { chips }
        }
        .animation(reduceMotion ? nil : Motion.layout, value: reactions)
    }
    private var chips: some View {
        HStack(spacing: 5) {
            ForEach(ReactionCount.groups(reactions, ownID: ownID)) { item in
                Button { choose(item.emoji) } label: {
                    HStack(spacing: 4) {
                        Text(item.emoji).font(.system(size: 19))
                            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.25, 1.0], trigger: item.count) { content, scale in
                                content.scaleEffect(scale)
                            } animation: { _ in Motion.press }
                        if item.count > 1 { Text("\(item.count)").font(.caption.bold()).contentTransition(.numericText()) }
                    }.padding(.horizontal, 9).padding(.vertical, 5)
                        .background((mine ? Color.black : Color.white).opacity(item.selected ? 0.16 : 0.07), in: Capsule())

                }.buttonStyle(MotionButtonStyle())
                    .accessibilityLabel("\(item.emoji), \(item.count)")
                    .accessibilityAddTraits(item.selected ? .isSelected : [])
                    .transition(.asymmetric(insertion: .scale(scale: 0.65).combined(with: .opacity), removal: .opacity))
            }
        }
    }
}

enum ReactionStyle: CaseIterable {
    case hearts, flame, laughter, electric, celebration, orbit
    static func forEmoji(_ emoji: String) -> Self {
        if ["❤️", "🖤", "🤍", "🥰", "😍", "💔", "💕", "💘"].contains(emoji) { return .hearts }
        if ["🔥", "💯", "🚀"].contains(emoji) { return .flame }
        if ["😂", "🤣", "🤡", "💀"].contains(emoji) { return .laughter }
        if ["⚡️", "🤯", "😮", "✨"].contains(emoji) { return .electric }
        if ["🎉", "🏆", "👏", "🎊", "🥳"].contains(emoji) { return .celebration }
        return .orbit
    }
    var particles: Int { self == .celebration ? 18 : 12 }
    func symbol(_ emoji: String, index: Int) -> String {
        if index.isMultiple(of: 3) { return emoji }
        switch self {
        case .hearts: return index.isMultiple(of: 2) ? "♡" : "♥"
        case .flame: return index.isMultiple(of: 2) ? "✦" : "•"
        case .laughter: return "✧"
        case .electric: return index.isMultiple(of: 2) ? "ϟ" : "✦"
        case .celebration: return index.isMultiple(of: 2) ? "▰" : "●"
        case .orbit: return "✦"
        }
    }
}

private struct ReactionBurst: View {
    let emoji: String
    let reduceMotion: Bool
    @State private var progress = 0.0
    @State private var popped = false
    @State private var leaving = false
    private var style: ReactionStyle { .forEmoji(emoji) }
    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle().fill(.white.opacity(0.14 * (1 - progress)))
                    .frame(width: 86, height: 86).blur(radius: 9)
                    .scaleEffect(0.35 + progress * 1.3)
                ForEach(0..<style.particles, id: \.self) { index in
                    particle(index)
                }
            }
            Text(emoji).font(.system(size: reduceMotion ? 28 : 52))
                .scaleEffect(reduceMotion ? 1 : (leaving ? 0.85 : popped ? 1 : 0.2))
                .rotationEffect(.degrees(reduceMotion ? 0 : (style == .laughter ? sin(progress * .pi * 6) * 14 : (1 - progress) * -12)))
                .offset(y: reduceMotion ? 0 : (leaving ? -36 : popped ? -15 : 8))
                .opacity(leaving ? 0 : 1)
                .shadow(color: .black.opacity(0.25), radius: 7, y: 4)
        }
        .frame(width: 168, height: 160)
        .allowsHitTesting(false).accessibilityHidden(true)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.58)) { popped = true }
            withAnimation(.linear(duration: 1.25)) { progress = 1 }
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 650)) } catch { return }
            withAnimation(.easeInOut(duration: 0.48)) { leaving = true }
        }
    }
    private func particle(_ index: Int) -> some View {
        let angle = Double(index) / Double(style.particles) * .pi * 2
        let distance = (index.isMultiple(of: 2) ? 78.0 : 58.0) * progress
        let rising = style == .hearts || style == .flame
        let x = cos(angle) * distance
        let y = rising ? -progress * (70 + Double(index % 4) * 14) : sin(angle) * distance - 16 + (style == .celebration ? progress * progress * 70 : 0)
        return Text(style.symbol(emoji, index: index))
            .font(.system(size: index.isMultiple(of: 3) ? 22 : 13, weight: .bold))
            .foregroundStyle(.white.opacity(0.95))
            .scaleEffect(0.2 + sin(progress * .pi) * 0.95)
            .rotationEffect(.degrees(progress * Double(index.isMultiple(of: 2) ? 100 : -100)))
            .offset(x: x, y: y)
            .opacity(max(0, 1 - progress * progress))
    }
}

private struct ReactionFeedback: ViewModifier {
    var reactions: [String: String]
    var mine: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token: UUID?
    @State private var emoji = ""
    func body(content: Content) -> some View {
        content.overlay(alignment: mine ? .topLeading : .topTrailing) {
            if let token {
                ReactionBurst(emoji: emoji, reduceMotion: reduceMotion).id(token)
                    .offset(x: mine ? -20 : 20, y: -60)
                    .transition(.opacity)
            }
        }
        .onChange(of: reactions) { old, new in
            guard let change = new.sorted(by: { $0.key < $1.key }).first(where: { old[$0.key] != $0.value && ReactionCatalog.all.contains($0.value) }) else { return }
            emoji = change.value
            token = UUID()
        }
        .task(id: token) {
            guard let current = token else { return }
            do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            guard token == current else { return }
            token = nil
        }
    }
}
extension View {
    func reactionFeedback(_ reactions: [String: String], mine: Bool) -> some View { modifier(ReactionFeedback(reactions: reactions, mine: mine)) }
}

struct ReactionPickerView: View {
    var selected: String?
    var choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Твоя реакция").font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.caption.bold()).padding(11).background(.white.opacity(0.08), in: Circle()) }.buttonStyle(MotionButtonStyle()).accessibilityLabel("Закрыть")
            }
            ScrollView {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 10) {
                ForEach(Array(ReactionCatalog.all.enumerated()), id: \.element) { index, emoji in
                    Button {
                        Haptics.light(); dismiss()
                        Task { @MainActor in
                            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
                            choose(emoji)
                        }
                    } label: {
                        Text(emoji).font(.system(size: 29)).frame(maxWidth: .infinity).frame(height: 50)
                            .background(.white.opacity(selected == emoji ? 0.18 : 0.045), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(MotionButtonStyle()).softAppear(index: index)
                }
              }
            }
            if selected != nil {
                Button("Убрать реакцию") { choose(""); dismiss() }.buttonStyle(GhostButton())
            }
        }.padding(22).presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationCornerRadius(32)
    }
}
