import SwiftUI
import StoreKit

struct EconomyNotice: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle").font(.callout)
            .foregroundStyle(.orange.opacity(0.9)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct ArtifactTile: View {
    var gift: CollectibleArtifact
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtifactArtwork(collection: gift.collection, traits: gift.traits)
                .overlay(alignment: .topTrailing) {
                    if gift.traits != nil {
                        Image(systemName: "sparkles").font(.caption).padding(9).background(.black.opacity(0.25), in: Circle()).padding(9)
                    }
                }
            HStack(spacing: 4) { Text(gift.title).font(.subheadline.weight(.semibold)); Spacer(minLength: 0); Text(gift.number).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            if let price = gift.salePrice { CoinAmount(value: price, size: 15).font(.caption.bold()) }
            else { Text(gift.traits?.model.title ?? "Оригинальный подарок").font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct ArtifactStorefrontView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var mode = 0
    @State private var filter = "all"
    @State private var market = [CollectibleArtifact]()
    @State private var marketCursor: String?
    @State private var selected: ArtifactCollection?
    @State private var inspecting: ArtifactCollection?
    @State private var notice: String?
    @State private var loading = true
    @State private var pendingPurchase: ArtifactCommand?
    @State private var purchasing = false
    @State private var purchased: CollectibleArtifact?
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("THE VO1D COLLECTION").font(.caption2.monospaced()).tracking(2.5).foregroundStyle(.secondary)
                        Text("Редкость.\nС характером.").font(.system(size: 36, weight: .bold, design: .rounded)).tracking(-1)
                    }
                    Spacer()
                    NavigationLink { CoinWalletView() } label: {
                        VStack(spacing: 8) { CoinMark(size: 36); Text(store.coinWallet?.balance.formatted() ?? "—").font(.headline.monospacedDigit()) }
                            .padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(MotionButtonStyle())
                }
                Picker("Витрина", selection: $mode) { Text("Коллекции").tag(0); Text("Маркет").tag(1) }.pickerStyle(.segmented)
                if let notice { EconomyNotice(message: notice); Button("Повторить загрузку") { Task { await load() } } }
                if let command = pendingPurchase, !purchasing {
                    Button("Проверить и повторить ту же покупку") { buy(command) }.buttonStyle(GhostButton())
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                else if mode == 0 { collections }
                else { marketplace }
                if store.economy.catalog?.admin == true {
                    NavigationLink { ArtifactAdminView() } label: {
                        Label("Управление публикациями", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                    }.buttonStyle(GhostButton())
                }
            }.padding(20)
        }.background { VoidBackground() }
        .navigationTitle("Витрина").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .onChange(of: filter) { _, _ in Task { await loadMarket(more: false) } }
        .confirmationDialog(selected.map { "Купить \($0.title)?" } ?? "Покупка", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let item = selected {
                Button("Купить за \(item.price.formatted()) VO1Dcoin") { buy(ArtifactCommand(collection: item.id, expectedPrice: item.price)) }
            }
        } message: {
            if let item = selected { Text("Осталось \(item.remaining.formatted()) из \(item.supply.formatted()). Номер и владение закрепляются сервером после оплаты.") }
        }
        .fullScreenCover(item: $inspecting) { item in ArtifactInspectionView(collection: item.id) }
        .sheet(item: $purchased) { gift in NavigationStack { ArtifactDetailView(initial: gift) } }
        .overlay { if purchasing { ProgressView("Покупка…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24)) } }
    }

    private var collections: some View {
        Group {
            if let items = store.economy.catalog?.collections, !items.isEmpty {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            Button { inspecting = item } label: {
                                ArtifactArtwork(collection: item.id)
                                    .overlay(alignment: .topLeading) { Text("\(item.supply.formatted()) всего").font(.system(size: 9, weight: .bold)).padding(7).background(.black.opacity(0.22), in: Capsule()).padding(10) }
                                    .overlay(alignment: .bottomTrailing) { Image(systemName: "view.3d").font(.caption).padding(9).background(.black.opacity(0.25), in: Circle()).padding(9) }
                            }.buttonStyle(MotionButtonStyle()).accessibilityLabel("Осмотреть \(item.title) в 3D")
                            Text(item.title).font(.headline)
                            Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(3).frame(minHeight: 46, alignment: .top)
                            ProgressView(value: Double(item.minted), total: Double(item.supply)).tint(.white.opacity(0.55))
                            Text("\(item.remaining.formatted()) доступно").font(.caption2).foregroundStyle(.secondary)
                            Button {
                                selected = item
                            } label: {
                                if item.remaining == 0 { Text("Распродано").font(.caption.bold()) }
                                else { CoinAmount(value: item.price).font(.subheadline.bold()) }
                            }.buttonStyle(PrimaryButton()).disabled(item.remaining == 0 || purchasing || pendingPurchase != nil)
                        }
                    }
                }
            } else if notice == nil {
                ContentUnavailableView("Коллекции скоро появятся", systemImage: "sparkles", description: Text("После публикации администратором подарки появятся здесь у всех."))
            }
        }
    }

    private var marketplace: some View {
        VStack(spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    filterButton("Все", id: "all")
                    ForEach(["singularity", "sovereign", "prism", "orbit", "nova"], id: \.self) { id in filterButton(ArtifactCollection.titles[id] ?? id, id: id) }
                }
            }
            if market.isEmpty { ContentUnavailableView("Маркет пока пуст", systemImage: "bag", description: Text("Здесь появятся артефакты, выставленные владельцами.")) }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(market.filter { filter == "all" || $0.collection == filter }) { gift in
                    NavigationLink { ArtifactDetailView(initial: gift) } label: { ArtifactTile(gift: gift) }.buttonStyle(MotionButtonStyle())
                }
            }
            if marketCursor != nil { Button("Загрузить ещё") { Task { await loadMarket(more: true) } }.buttonStyle(GhostButton()) }
        }
    }
    private func filterButton(_ title: String, id: String) -> some View {
        Button(title) { filter = id }.font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 9)
            .background(.white.opacity(filter == id ? 0.17 : 0.04), in: Capsule()).buttonStyle(MotionButtonStyle())
    }
    private func load() async {
        loading = true; notice = nil
        do { try await store.refreshEconomy(); await loadMarket(more: false) }
        catch is CancellationError { return }
        catch { notice = error.localizedDescription }
        loading = false
    }
    private func loadMarket(more: Bool) async {
        guard let api = store.api else { return }
        let fence = store.sessionFence
        let selectedFilter = filter
        var query: [URLQueryItem] = []
        if more, let marketCursor { query.append(URLQueryItem(name: "cursor", value: marketCursor)) }
        if selectedFilter != "all" { query.append(URLQueryItem(name: "collection", value: selectedFilter)) }
        do {
            let page: ArtifactPage = try await api.request("v3/economy/market", query: query)
            try store.requireCurrentSession(fence)
            guard selectedFilter == filter else { return }
            market = more ? market + page.artifacts.filter { gift in !market.contains { $0.id == gift.id } } : page.artifacts
            marketCursor = page.nextCursor
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
    }
    private func buy(_ command: ArtifactCommand) {
        pendingPurchase = command; purchasing = true
        Task {
            defer { purchasing = false }
            do {
                purchased = try await store.artifactCommand("buy", command)
                pendingPurchase = nil; selected = nil; notice = nil; Haptics.success()
            } catch is CancellationError { return }
            catch let error as HTTPFailure where (400..<500).contains(error.status) { pendingPurchase = nil; notice = error.localizedDescription }
            catch { notice = error.localizedDescription }
        }
    }
}

struct CoinWalletView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var products: [Product] = []
    @State private var loading = true
    @State private var busy = false
    @State private var notice: String?
    @State private var history: [CoinLedgerEntry] = []
    @State private var cursor: String?
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                CoinMark(size: 76).padding(.top, 12)
                VStack(spacing: 5) {
                    Text(store.coinWallet?.balance.formatted() ?? "—").font(.system(size: 48, weight: .bold, design: .rounded)).contentTransition(.numericText())
                    Text("VO1Dcoin").foregroundStyle(.secondary)
                }
                Text("Немного монет.\nМного возможностей.").font(.title2.bold()).multilineTextAlignment(.center)
                if let notice { EconomyNotice(message: notice) }
                if let debt = store.coinWallet?.refundDebt, debt > 0 {
                    EconomyNotice(message: "По возвращённой покупке осталось погасить \(debt.formatted()) VO1Dcoin. Пополнения и выручка от продаж пойдут на погашение.")
                }
                if loading { ProgressView() }
                ForEach(products) { product in
                    Button { purchase(product) } label: {
                        HStack {
                            CoinAmount(value: Int(product.id.split(separator: ".").last ?? "0") ?? 0, size: 27).font(.headline)
                            Spacer()
                            Text(product.displayPrice).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10).background(.white.opacity(0.08), in: Capsule())
                        }.padding(17).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(MotionButtonStyle()).disabled(busy || !store.canStartApplePayment)
                }
                if !loading && !store.canStartApplePayment {
                    Text("Оплата Apple ещё не подключена администратором. Списание недоступно до настройки проверки покупок.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Проверить доступность") { Task { await load() } }.buttonStyle(GhostButton()).disabled(busy)
                } else if !loading && products.isEmpty { Text("Покупки появятся после настройки продуктов в App Store Connect.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                NavigationLink { PremiumPlanView() } label: { Label("Открыть VO1D_PREMIUM", systemImage: "sparkles").frame(maxWidth: .infinity) }.buttonStyle(GhostButton())
                Button("Восстановить покупки") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await AppStore.sync(); await store.recoverStorePurchases(); await loadHistory(more: false) }
                        catch { notice = error.localizedDescription }
                    }
                }.disabled(busy)
                Text("Оплата в валюте твоего App Store. Монеты зачисляются после подтверждения платежа. VO1Dcoin используются внутри VO1D.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Операции").font(.title3.bold())
                        ForEach(history) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) { Text(entry.title).font(.subheadline); Text(Date(timeIntervalSince1970: Double(entry.created)), style: .date).font(.caption2).foregroundStyle(.secondary) }
                                Spacer(); Text((entry.delta > 0 ? "+" : "") + entry.delta.formatted()).font(.subheadline.monospacedDigit()).foregroundStyle(entry.delta > 0 ? .green : .white)
                            }
                        }
                        if cursor != nil { Button("Ещё операции") { Task { await loadHistory(more: true) } } }
                    }.panel()
                }
            }.padding(22)
        }.background { VoidBackground() }.navigationTitle("Кошелёк").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .overlay { if busy { ProgressView().padding(24).background(.ultraThinMaterial, in: Circle()) } }
    }
    private func load() async {
        loading = true; notice = nil
        let fence = store.sessionFence
        do {
            try await store.refreshEconomy()
            let fetched = try await Product.products(for: store.canStartApplePayment ? (store.economy.catalog?.products ?? []) : [])
            try store.requireCurrentSession(fence)
            products = fetched.sorted { $0.price < $1.price }
            await loadHistory(more: false)
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
        loading = false
    }
    private func purchase(_ product: Product) {
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do { try await store.buyStoreProduct(product); await loadHistory(more: false) }
            catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
    private func loadHistory(more: Bool) async {
        guard let api = store.api else { return }
        let fence = store.sessionFence
        do {
            struct Page: Decodable { var entries: [CoinLedgerEntry]; var nextCursor: String? }
            let page: Page = try await api.request("v3/economy/history", query: more ? [URLQueryItem(name: "cursor", value: cursor)] : [])
            try store.requireCurrentSession(fence)
            history = more ? history + page.entries : page.entries; cursor = page.nextCursor
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
    }
}

struct CoinLedgerEntry: Decodable, Identifiable {
    var seq: Int
    var delta: Int
    var kind: String
    var created: Int
    var id: Int { seq }
    var title: String {
        switch kind {
        case "topup": return "Пополнение"
        case "purchase": return "Покупка подарка"
        case "market_purchase": return "Покупка на маркете"
        case "sale": return "Продажа артефакта"
        case "upgrade": return "Улучшение"
        case "transfer_sent": return "Подарок передан"
        case "transfer_received": return "Подарок получен"
        case "refund": return "Возврат платежа App Store"
        default: return "Операция с VO1Dcoin"
        }
    }
}

struct ArtifactAdminView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var collections: [ArtifactCollection] = []
    @State private var selected: ArtifactCollection?
    @State private var notice: String?
    @State private var success: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Твой следующий дроп.").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Проверь тираж и опубликуй подарок. После подтверждения он появится в витрине у всех пользователей.").font(.callout).foregroundStyle(.secondary)
                if let notice { EconomyNotice(message: notice) }
                if let success { Label(success, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
                ForEach(collections) { item in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 15) {
                            ArtifactArtwork(collection: item.id).frame(width: 86)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item.title).font(.headline)
                                Text("\(item.minted.formatted()) / \(item.supply.formatted()) куплено").font(.caption).foregroundStyle(.secondary)
                                CoinAmount(value: item.price, size: 16).font(.caption.bold())
                                Text(item.published ? "В витрине" : "Черновик").font(.caption2).foregroundStyle(item.published ? .green : .secondary)
                            }
                        }
                        if !item.published {
                            Button("Выложить подарок") { selected = item }.buttonStyle(PrimaryButton()).disabled(busy)
                        }
                    }.panel()
                }
            }.padding(22)
        }.background { VoidBackground() }.navigationTitle("Публикации").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .confirmationDialog("Выложить подарок в витрину?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
            if let selected { Button("Да, опубликовать") { publish(selected) } }
        } message: {
            if let selected { Text("\(selected.title) · тираж \(selected.supply.formatted()). Покупки станут доступны всем пользователям.") }
        }
    }
    private func load() async {
        guard let api = store.api else { return }
        let fence = store.sessionFence
        do {
            struct Page: Decodable { var collections: [ArtifactCollection] }
            let page: Page = try await api.request("v3/economy/admin")
            try store.requireCurrentSession(fence); collections = page.collections
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
    }
    private func publish(_ item: ArtifactCollection) {
        let route = "admin/publish"
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await store.artifactCommand(route, ArtifactCommand(collection: item.id, confirmed: true))
                notice = nil; success = "\(item.title) появился в витрине у всех"; selected = nil; Haptics.success(); await load()
            } catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}
