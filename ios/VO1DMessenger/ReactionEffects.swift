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
                        Text(item.emoji).font(.system(size: 17))
                        if item.count > 1 { Text("\(item.count)").font(.caption.bold()).contentTransition(.numericText()) }
                    }.padding(.horizontal, 9).padding(.vertical, 5)
                        .background((mine ? Color.black : Color.white).opacity(item.selected ? 0.16 : 0.07), in: Capsule())
                        .overlay(Capsule().stroke((mine ? Color.black : Color.white).opacity(item.selected ? 0.24 : 0), lineWidth: 1))
                }.buttonStyle(MotionButtonStyle())
                    .accessibilityLabel("\(item.emoji), \(item.count)")
                    .accessibilityAddTraits(item.selected ? .isSelected : [])
                    .transition(.asymmetric(insertion: .scale(scale: 0.65).combined(with: .opacity), removal: .opacity))
            }
        }
    }
}

private struct ReactionFeedback: ViewModifier {
    var reactions: [String: String]
    var mine: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var token: UUID?
    @State private var emoji = ""
    @State private var expanded = false
    func body(content: Content) -> some View {
        content.overlay(alignment: mine ? .topLeading : .topTrailing) {
            if token != nil {
                ZStack {
                    if !reduceMotion {
                        Circle().stroke(.white.opacity(expanded ? 0 : 0.75), lineWidth: 2)
                            .frame(width: 58, height: 58).scaleEffect(expanded ? 1.7 : 0.3)
                        ForEach(0..<8) { index in
                            let angle = Double(index) * .pi / 4
                            Text(index.isMultiple(of: 3) ? emoji : "✦")
                                .font(.system(size: index.isMultiple(of: 3) ? 16 : 11))
                                .offset(x: expanded ? cos(angle) * 55 : 0, y: expanded ? sin(angle) * 48 - 16 : 0)
                                .rotationEffect(.degrees(expanded ? Double(index * 19) : 0))
                                .scaleEffect(expanded ? 0.6 : 0.2).opacity(expanded ? 0 : 1)
                        }
                    }
                    Text(emoji).font(.system(size: reduceMotion ? 26 : 42))
                        .scaleEffect(reduceMotion ? 1 : (expanded ? 1.18 : 0.35))
                        .offset(y: reduceMotion ? 0 : (expanded ? -22 : 5))
                        .opacity(expanded ? 0 : 1)
                }.frame(width: 120, height: 110).offset(x: mine ? -12 : 12, y: -32)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: reactions) { old, new in
            guard let change = new.sorted(by: { $0.key < $1.key }).first(where: { old[$0.key] != $0.value && ReactionCatalog.all.contains($0.value) }) else { return }
            emoji = change.value
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { expanded = false; token = UUID() }
        }
        .task(id: token) {
            guard let current = token else { return }
            await Task.yield()
            guard !Task.isCancelled, token == current else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.35) : .easeOut(duration: 0.85)) { expanded = true }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
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
                        Haptics.light(); choose(emoji); dismiss()
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
