import Foundation
import CryptoKit
import SwiftUI

struct PremiumReceipt: Codable, Hashable, Identifiable {
    var kind: String
    var id: String
    var owner: String
    var expiresAt: Int
    var label: String
    var symbol: String
    var signature: String
    var bytes: Data {
        Data("VO1D-COMMERCE-1\n\(kind)\n\(id)\n\(owner)\n\(expiresAt)\n\(Data(label.utf8).base64EncodedString())\n\(symbol)".utf8)
    }
    func validate(owner expected: String) throws {
        guard owner == expected, ["premium", "collectible"].contains(kind), id.count == 32,
              label.count <= 40, ["sparkles", "moon.stars.fill", "diamond.fill", "flame.fill", "bolt.fill"].contains(symbol),
              let pinned = Bundle.main.object(forInfoDictionaryKey: "VO1DCommercePublicKey") as? String, !pinned.isEmpty else {
            throw MessengerError.invalid("Подпись Premium не настроена в этой сборке")
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(pinned, count: 32))
        guard try key.isValidSignature(Crypto.decode(signature, count: 64), for: bytes) else {
            throw MessengerError.invalid("Поддельное подтверждение Premium")
        }
    }
}
typealias CollectibleReceipt = PremiumReceipt
extension ChatStore {
    var hasPremium: Bool {
        guard let receipt = social.premium, receipt.kind == "premium", receipt.expiresAt > Int(Date().timeIntervalSince1970) else { return false }
        return (try? receipt.validate(owner: myID)) != nil
    }
    func redeemPremium(_ code: String) async throws {
        guard let api else { throw MessengerError.invalid("Нет соединения") }
        let expected = generation
        let receipt: PremiumReceipt = try await api.request("v2/commerce/redeem", method: "POST", body: Wire.encoder.encode(["code": code.trimmingCharacters(in: .whitespacesAndNewlines)]))
        guard expected == generation else { throw CancellationError() }
        try receipt.validate(owner: myID)
        var value = social
        if receipt.kind == "premium" { value.premium = receipt }
        else if !value.collectibles.contains(where: { $0.id == receipt.id }) { value.collectibles.append(receipt) }
        state.social = value; try save()
    }
}
struct PremiumView: View {
    @EnvironmentObject var store: ChatStore
    @State private var code = ""
    @State private var busy = false
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "sparkles").font(.system(size: 42))
                    Text("VO1D PREMIUM").font(.title.bold())
                    Text(store.hasPremium ? "Активен" : "Больше пространства для твоей личности").foregroundStyle(.secondary)
                    if let receipt = store.social.premium, store.hasPremium {
                        Text("До \(Date(timeIntervalSince1970: Double(receipt.expiresAt)).formatted(date: .abbreviated, time: .omitted))")
                    }
                }.padding(.vertical)
            }
            Section("Включено") {
                Label("30 активных историй вместо 5", systemImage: "circle.dashed")
                Label("60 папок вместо 20", systemImage: "folder")
                Label("Статус и коллекционная витрина", systemImage: "diamond")
                Text("Шифрование, Tor, звонки и основные реакции доступны всем.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Активировать") {
                SecureField("Одноразовый код", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(busy ? "Проверяем подпись…" : "Активировать код") {
                    busy = true
                    Task {
                        do { try await store.redeemPremium(code); code = ""; Haptics.success() }
                        catch { store.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy || code.isEmpty)
                Text("Код выдаётся оператором. Автоматическая оплата в этой версии не подключена.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Коллекция") {
                if store.social.collectibles.isEmpty { Text("Здесь появятся подписанные коллекционные предметы.").foregroundStyle(.secondary) }
                ForEach(store.social.collectibles.filter { (try? $0.validate(owner: store.myID)) != nil }) { item in
                    Label(item.label, systemImage: item.symbol)
                }
                Text("Это коллекционные сертификаты VO1D. Они не являются NFT в блокчейне.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Premium")
    }
}
