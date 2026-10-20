import SwiftUI

struct ArtifactDetailView: View {
    var initial: CollectibleArtifact
    @EnvironmentObject private var store: ChatStore
    @State private var current: CollectibleArtifact?
    @State private var estimate: Int?
    @State private var sheet: String?
    @State private var notice: String?
    @State private var busy = false
    @State private var buying = false
    @State private var pendingBuy: ArtifactCommand?
    private var gift: CollectibleArtifact { current ?? initial }
    private var mine: Bool { gift.owner == store.myID }
    private var collection: ArtifactCollection? { store.economy.catalog?.collections.first { $0.id == gift.collection } }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ArtifactArtwork(collection: gift.collection, traits: gift.traits, animated: true)
                    .overlay(alignment: .topLeading) {
                        Text(gift.traits == nil ? "ORIGINAL GIFT" : "COLLECTIBLE").font(.caption2.monospaced().bold()).tracking(2).padding(12).background(.black.opacity(0.22), in: Capsule()).padding(16)
                    }
                VStack(spacing: 7) {
                    HStack(spacing: 8) { Text(gift.title).font(.system(size: 32, weight: .bold, design: .rounded)); Text(gift.number).font(.title3.monospaced()).foregroundStyle(.secondary) }.minimumScaleFactor(0.6).lineLimit(1)
                    Text(gift.traits == nil ? "Ещё не улучшен. История начинается здесь." : "Твоё единственное сочетание.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let notice { EconomyNotice(message: notice) }
                VStack(spacing: 16) {
                    detailRow("Владелец", value: mine ? "Ты" : gift.ownerUsername.map { "@" + $0 } ?? String((gift.owner ?? "Удалённый аккаунт").prefix(14)))
                    detailRow("Номер", value: gift.number)
                    HStack { Text("Цена покупки").foregroundStyle(.secondary); Spacer(); CoinAmount(value: gift.pricePaid, size: 17) }.font(.subheadline)
                    if let collection { detailRow("Тираж коллекции", value: collection.supply.formatted()) }
                    if let traits = gift.traits {
                        Divider().overlay(.white.opacity(0.07))
                        traitRow("Модель", trait: traits.model)
                        traitRow("Узор", trait: traits.pattern)
                        traitRow("Фон", trait: traits.backdrop)
                    }
                }.panel()
                if gift.traits != nil, let estimate {
                    VStack(spacing: 8) {
                        HStack { Text("Примерная оценка").font(.subheadline); Spacer(); CoinAmount(value: estimate).font(.headline) }
                        Text("Расчёт по редкости свойств. Это ориентир, а не гарантированная цена продажи.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.panel()
                }
                if mine { ownerActions }
                else if let price = gift.salePrice, gift.listingID != nil {
                    Button { buying = true } label: { HStack { Text("Купить"); Spacer(); CoinAmount(value: price) } }.buttonStyle(PrimaryButton()).disabled(busy)
                }
                if gift.traits != nil {
                    Text("Модель, фон и узор выбраны сервером независимо. Проценты показывают шанс каждого свойства при улучшении.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(22)
        }.background { VoidBackground() }
        .navigationTitle("Артефакт").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mine {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(gift.visible ? "Скрыть из профиля" : "Добавить в профиль", systemImage: gift.visible ? "eye.slash" : "person.crop.circle.badge.plus") { visibility() }
                        if gift.listingID == nil {
                            Button("Передать", systemImage: "gift") { sheet = "transfer" }
                            Button("Продать", systemImage: "tag") { sheet = "list" }
                        } else { Button("Снять с продажи", systemImage: "xmark.circle") { unlist() } }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }.disabled(busy)
                }
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
            NavigationStack {
                if sheet == "upgrade" { ArtifactUpgradeView(gift: gift) { updated in current = updated; sheet = nil; Task { await refresh() } } }
                else { ArtifactTradeView(gift: gift, transfer: sheet == "transfer") { updated in current = updated; sheet = nil; Task { await refresh() } } }
            }
        }
        .confirmationDialog("Купить \(gift.title) \(gift.number)?", isPresented: $buying, titleVisibility: .visible) {
            Button("Купить за \((gift.salePrice ?? 0).formatted()) VO1Dcoin") { buyOnMarket() }
        } message: { Text("Артефакт перейдёт в твою коллекцию. Цена и текущий владелец проверяются сервером.") }
        .overlay { if busy { ProgressView().padding(24).background(.ultraThinMaterial, in: Circle()) } }
    }

    private var ownerActions: some View {
        VStack(spacing: 12) {
            Button { visibility() } label: { Label(gift.visible ? "Скрыть из профиля" : "Добавить в профиль", systemImage: gift.visible ? "eye.slash" : "plus.circle") }.buttonStyle(PrimaryButton()).disabled(busy)
            if gift.listingID != nil {
                if let price = gift.salePrice { HStack { Text("На продаже"); Spacer(); CoinAmount(value: price) }.font(.subheadline).padding(.vertical, 8) }
                Button("Снять с продажи") { unlist() }.buttonStyle(GhostButton()).disabled(busy)
            } else {
                HStack(spacing: 10) {
                    Button { sheet = "transfer" } label: { Label("Передать", systemImage: "gift") }.buttonStyle(GhostButton())
                    Button { sheet = "list" } label: { Label("Продать", systemImage: "tag") }.buttonStyle(GhostButton())
                }.disabled(busy)
                if gift.traits == nil {
                    if collection?.upgrades == true {
                        Button { sheet = "upgrade" } label: { HStack { Label("Улучшить", systemImage: "sparkles"); Spacer(); CoinAmount(value: collection?.upgradePrice ?? 0) } }.buttonStyle(PrimaryButton()).disabled(busy)
                    } else { Text("Улучшение появится, когда администратор выпустит его для этой коллекции.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }
            }
        }
    }
    private func detailRow(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1).textSelection(.enabled) }.font(.subheadline)
    }
    private func traitRow(_ title: String, trait: ArtifactTrait) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(trait.title); Text(trait.probability).font(.caption2.monospaced()).padding(.horizontal, 8).padding(.vertical, 5).background(.white.opacity(0.08), in: Capsule()) }.font(.subheadline)
    }
    private func refresh() async {
        guard let api = store.api else { return }
        let fence = store.sessionFence
        do {
            if store.economy.catalog == nil { try await store.refreshEconomy() }
            struct Detail: Decodable { var artifact: CollectibleArtifact; var estimatedValue: Int }
            let result: Detail = try await api.request("v3/economy/artifact/" + gift.id)
            try store.requireCurrentSession(fence); current = result.artifact; estimate = result.estimatedValue; notice = nil
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
    }
    private func visibility() { perform("visibility", ArtifactCommand(artifactID: gift.id, visible: !gift.visible)) }
    private func unlist() { perform("unlist", ArtifactCommand(artifactID: gift.id)) }
    private func buyOnMarket() {
        let command = pendingBuy ?? ArtifactCommand(expectedPrice: gift.salePrice, listingID: gift.listingID)
        pendingBuy = command; perform("market/buy", command)
    }
    private func perform(_ route: String, _ command: ArtifactCommand) {
        busy = true
        Task {
            defer { busy = false }
            do { current = try await store.artifactCommand(route, command); pendingBuy = nil; notice = nil; Haptics.success(); await refresh() }
            catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}

struct ArtifactTradeView: View {
    var gift: CollectibleArtifact
    var transfer: Bool
    var completed: (CollectibleArtifact) -> Void
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var price = ""
    @State private var confirming = false
    @State private var busy = false
    @State private var notice: String?
    @State private var command: ArtifactCommand?
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ArtifactArtwork(collection: gift.collection, traits: gift.traits).frame(width: 160)
                Text("\(gift.title) \(gift.number)").font(.title2.bold())
                if transfer {
                    TextField("@username или ID получателя", text: $recipient).textInputAutocapitalization(.never).autocorrectionDisabled().voidField().disabled(command != nil)
                    Text("После передачи артефакт принадлежит получателю. Он сам решит, показывать ли подарок в профиле.").font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack { CoinMark(); TextField("Цена в VO1Dcoin", text: $price).keyboardType(.numberPad) }.voidField().disabled(command != nil)
                    Text("Покупатель заплатит эту сумму, ты получишь её целиком. Пока артефакт на продаже, передача и улучшение недоступны.").font(.callout).foregroundStyle(.secondary)
                }
                if let notice { EconomyNotice(message: notice) }
                Button(command == nil ? (transfer ? "Продолжить" : "Выставить на продажу") : "Повторить ту же операцию") { confirming = true }
                    .buttonStyle(PrimaryButton()).disabled(busy || (command == nil && (transfer ? recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : (Int(price) ?? 0) < 1)))
                if busy { ProgressView() }
            }.padding(24)
        }.background { VoidBackground() }.navigationTitle(transfer ? "Передать подарок" : "Продать артефакт").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy || command != nil)
        .confirmationDialog(transfer ? "Передать \(gift.number)?" : "Опубликовать объявление?", isPresented: $confirming, titleVisibility: .visible) {
            Button(transfer ? "Передать \(recipient)" : "Продать за \(price) VO1Dcoin") { submit() }
        } message: { Text(transfer ? "Убедись, что получатель указан верно. Возврат возможен только с его согласия." : "Объявление появится на маркете. Его можно снять до покупки.") }
    }
    private func submit() {
        let pending = command ?? ArtifactCommand(artifactID: gift.id, recipient: transfer ? recipient.trimmingCharacters(in: .whitespacesAndNewlines) : nil, price: transfer ? nil : Int(price))
        command = pending; busy = true
        Task {
            defer { busy = false }
            do {
                if let updated = try await store.artifactCommand(transfer ? "transfer" : "list", pending) { command = nil; Haptics.success(); completed(updated) }
            } catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}

