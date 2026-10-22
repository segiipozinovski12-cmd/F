import SwiftUI

/// Optional fields keep existing encrypted profile events and local vaults readable.
struct ProfileDecoration: Codable, Hashable {
    var cover = "void"
    var symbol: String?
    var statusUntil: Date?
    static let covers = ["void", "graphite", "aurora", "ember", "frost", "rose", "cobalt", "gold"]
    static let symbols = ["moon.stars.fill", "sparkles", "bolt.fill", "heart.fill", "headphones", "airplane", "gamecontroller.fill", "cup.and.saucer.fill"]
    var premium: Bool { !["void", "graphite"].contains(cover) || symbol != nil }
    var activeSymbol: String? { symbol(at: Date()) }
    func symbol(at date: Date) -> String? { statusUntil.map { $0 <= date } == true ? nil : symbol }
    func validate() throws {
        guard Self.covers.contains(cover), symbol == nil || Self.symbols.contains(symbol!),
              statusUntil == nil || statusUntil!.timeIntervalSince1970.isFinite else {
            throw MessengerError.invalid("Неизвестное оформление профиля")
        }
    }
    func allowed(premium: Bool) -> Self {
        premium ? self : Self(cover: ["void", "graphite"].contains(cover) ? cover : "void")
    }
    var title: String {
        ["void": "VO1D", "graphite": "Графит", "aurora": "Aurora", "ember": "Ember", "frost": "Frost", "rose": "Rose", "cobalt": "Cobalt", "gold": "Gold"][cover] ?? "VO1D"
    }
    var colors: [Color] {
        let hex: [UInt32]
        switch cover {
        case "graphite": hex = [0x626B7B, 0x171B24]
        case "aurora": hex = [0x8B68C8, 0x254A58, 0x111724]
        case "ember": hex = [0xBB704E, 0x451C34, 0x1A1018]
        case "frost": hex = [0x8CBFC9, 0x294667, 0x101923]
        case "rose": hex = [0xBD7797, 0x48273D, 0x18111D]
        case "cobalt": hex = [0x567CE1, 0x252557, 0x101421]
        case "gold": hex = [0xC1A16B, 0x54412D, 0x191510]
        default: hex = [0x615472, 0x252132, 0x111115]
        }
        return hex.map(Color.artifactHex)
    }
}

struct ProfileCover: View {
    var decoration: ProfileDecoration
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: decoration.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(0..<3) { index in
                    Circle().stroke(.white.opacity(0.1), lineWidth: 1)
                        .frame(width: CGFloat(160 + index * 74), height: CGFloat(160 + index * 74))
                        .position(x: geometry.size.width * 0.86, y: geometry.size.height * 0.1)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
            }
        }.clipped().accessibilityHidden(true)
    }
}
