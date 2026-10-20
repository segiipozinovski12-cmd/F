import SwiftUI

struct ArtifactUpgradeView: View {
    var gift: CollectibleArtifact
    var completed: (CollectibleArtifact) -> Void
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var result: CollectibleArtifact?
    @State private var phase = 0
    @State private var running = false
    @State private var busy = false
    @State private var confetti = false
    @State private var notice: String?
    @State private var command: ArtifactCommand?
    @State private var rollTask: Task<Void, Never>?
    private var price: Int { store.economy.catalog?.collections.first { $0.id == gift.collection }?.upgradePrice ?? 0 }
    private let models = ["original", "pearl", "aurora", "gold", "crimson", "monochrome"]
    private let backgrounds = ["jade", "azure", "lavender", "rose", "midnight", "obsidian"]
    private let patterns = ["stars", "orbits", "diamonds", "runes", "eclipse", "void"]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text(phase == 3 ? "Единственный. Твой." : "За гранью обычного.")
                    .font(.system(size: 30, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                reel
                HStack(spacing: 8) {
                    reelLabel("Фон", value: phase >= 1 ? result?.traits?.backdrop.title : nil)
                    reelLabel("Узор", value: phase >= 2 ? result?.traits?.pattern.title : nil)
                    reelLabel("Модель", value: phase >= 3 ? result?.traits?.model.title : nil)
                }
                if let notice { EconomyNotice(message: notice) }
                if phase == 3, let result {
                    Text("\(result.title) \(result.number)").font(.title2.bold())
                    Text("Сочетание сохранено. Повторно улучшить этот артефакт нельзя.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Готово") { completed(result) }.buttonStyle(PrimaryButton())
                } else {
                    Text("Три независимых шанса.\nОдно неповторимое сочетание.").font(.title3.bold()).multilineTextAlignment(.center)
                    Text("Сначала остановится фон, затем узор и модель. Результат выбирает сервер до начала анимации; закрытие экрана его не меняет.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    odds
                    Button { upgrade() } label: {
                        HStack { Text(command == nil ? "Улучшить" : "Повторить запрос"); Spacer(); CoinAmount(value: price) }
                    }.buttonStyle(PrimaryButton()).disabled(busy || running || price == 0)
                    if busy { ProgressView("Получаем сочетание…") }
                }
            }.padding(24)
        }.background { VoidBackground() }.navigationTitle("Улучшение").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy || running) } }
        .interactiveDismissDisabled(busy || running)
        .onDisappear { rollTask?.cancel() }
    }

    private var reel: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase == 3 || reduceMotion)) { clock in
            let speed = running ? 5.0 : 0.65
            let position = clock.date.timeIntervalSince1970 * speed
            let tick = Int(position)
            let fraction = position - floor(position)
            ZStack {
                if phase == 3 || reduceMotion {
                    ArtifactArtwork(collection: gift.collection, traits: phase == 3 ? result?.traits : previewTraits(0))
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: 12) {
                            ForEach(0..<3) { index in
                                ArtifactArtwork(collection: gift.collection, traits: previewTraits(tick + index))
                                    .frame(width: geometry.size.width - 24)
                            }
                        }
                        .offset(x: -(geometry.size.width - 12) * fraction + 12)
                    }.aspectRatio(1, contentMode: .fit).clipped()
                    HStack { Image(systemName: "chevron.right"); Spacer(); Image(systemName: "chevron.left") }.font(.caption.bold()).padding(.horizontal, 3)
                }
                if confetti && !reduceMotion { ConfettiBurst().allowsHitTesting(false) }
            }
        }.accessibilityLabel(running ? "Идёт раскрытие артефакта" : "Предпросмотр улучшения")
    }

    private var odds: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Честные вероятности").font(.subheadline.bold())
            Text("Фон: Jade 30% · Azure 27% · Lavender 23% · Rose 14% · Midnight 4,5% · Obsidian 1,5%")
            Text("Узор: Stardust 35% · Orbits 28% · Diamonds 22% · Runes 11% · Eclipse 3,5% · Pure Void 0,5%")
            Text("Модель: Original 40% · Pearl 28% · Aurora 20% · Liquid Gold 9% · Crimson Chrome 2,6% · Monochrome 0,4%")
            Text("Любая модель может выпасть с любым фоном. Полный Monochrome + Obsidian + Pure Void: 0,00003%.").foregroundStyle(.secondary)
        }.font(.caption).lineSpacing(3).panel()
    }
    private func reelLabel(_ title: String, value: String?) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) { Text(title); if value != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } }.font(.caption2).foregroundStyle(.secondary)
            Text(value ?? (running ? "•••" : "?" )).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity).padding(.vertical, 14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
    }
    private func previewTraits(_ tick: Int) -> ArtifactTraits {
        let preview = ArtifactTraits(
            backdrop: ArtifactTrait(id: backgrounds[tick % backgrounds.count], title: "", weight: 0),
            pattern: ArtifactTrait(id: patterns[(tick / 2) % patterns.count], title: "", weight: 0),
            model: ArtifactTrait(id: models[(tick / 3) % models.count], title: "", weight: 0))
        guard let final = result?.traits else { return preview }
        return ArtifactTraits(backdrop: phase >= 1 ? final.backdrop : preview.backdrop,
                              pattern: phase >= 2 ? final.pattern : preview.pattern,
                              model: phase >= 3 ? final.model : preview.model)
    }
    private func upgrade() {
        let pending = command ?? ArtifactCommand(artifactID: gift.id, expectedPrice: price)
        command = pending; busy = true; notice = nil
        rollTask = Task { @MainActor in
            defer { busy = false; running = false }
            do {
                guard let upgraded = try await store.artifactCommand("upgrade", pending) else { return }
                result = upgraded; command = nil; busy = false; running = true
                if reduceMotion { phase = 3; Haptics.success(); return }
                for step in 1...3 {
                    try await Task.sleep(for: .seconds(step == 1 ? 1.6 : 1.1))
                    try Task.checkCancellation()
                    withAnimation(Motion.layout) { phase = step }
                    Haptics.medium()
                }
                withAnimation(.easeOut(duration: 0.9)) { confetti = true }
                Haptics.success()
            } catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}

private struct ConfettiBurst: View {
    @State private var exploded = false
    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<36) { index in
                let angle = Double(index) * 2.39996
                let distance = CGFloat(70 + (index * 37) % 120)
                RoundedRectangle(cornerRadius: 2)
                    .fill([Color.white, .artifactHex(0xD9BBFF), .artifactHex(0xEAD0A2)][index % 3])
                    .frame(width: 4, height: 8)
                    .rotationEffect(.degrees(exploded ? Double(index * 43) : 0))
                    .position(x: proxy.size.width / 2 + (exploded ? CGFloat(cos(angle)) * distance : 0), y: proxy.size.height / 2 + (exploded ? CGFloat(sin(angle)) * distance : 0))
                    .opacity(exploded ? 0 : 1)
            }
        }.onAppear { withAnimation(.easeOut(duration: 1.5)) { exploded = true } }.accessibilityHidden(true)
    }
}
