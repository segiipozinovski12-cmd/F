import SwiftUI

struct VoidPalette {
    var background: Color
    var panel: Color
    var accent: Color
}

enum MessengerTheme: String, Codable, CaseIterable, Identifiable {
    case void, graphite, midnight, plum, forest, aurora, ember, frost
    var premium: Bool { [.aurora, .ember, .frost].contains(self) }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .void: return "VO1D"
        case .graphite: return "Графит"
        case .midnight: return "Глубина"
        case .plum: return "Орбита"
        case .forest: return "Тайга"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .frost: return "Frost"
        }
    }
    var palette: VoidPalette {
        switch self {
        case .void: return VoidPalette(background: .black, panel: Color(white: 0.055), accent: .white)
        case .graphite: return VoidPalette(background: Color(hex: 0x141519), panel: Color(hex: 0x24262C), accent: Color(hex: 0xDFE5F2))
        case .midnight: return VoidPalette(background: Color(hex: 0x080F1C), panel: Color(hex: 0x142137), accent: Color(hex: 0xA3CDFF))
        case .plum: return VoidPalette(background: Color(hex: 0x120C1B), panel: Color(hex: 0x271C35), accent: Color(hex: 0xD8B8FF))
        case .forest: return VoidPalette(background: Color(hex: 0x091412), panel: Color(hex: 0x172C26), accent: Color(hex: 0xACDFC9))
        case .aurora: return VoidPalette(background: Color(hex: 0x101220), panel: Color(hex: 0x21253D), accent: Color(hex: 0xC7C0FF))
        case .ember: return VoidPalette(background: Color(hex: 0x1A100F), panel: Color(hex: 0x34221F), accent: Color(hex: 0xF5C1A2))
        case .frost: return VoidPalette(background: Color(hex: 0x10191C), panel: Color(hex: 0x223239), accent: Color(hex: 0xC1E9EE))
        }
    }
}

enum ChatTheme: String, Codable, CaseIterable, Identifiable {
    case follow, pearl, iris, ocean, moss
    var id: String { rawValue }
    var title: String {
        switch self {
        case .follow: return "Как приложение"
        case .pearl: return "Жемчуг"
        case .iris: return "Ирис"
        case .ocean: return "Океан"
        case .moss: return "Мох"
        }
    }
    func palette(app: VoidPalette) -> VoidPalette {
        switch self {
        case .follow: return app
        case .pearl: return MessengerTheme.void.palette
        case .iris: return MessengerTheme.plum.palette
        case .ocean: return MessengerTheme.midnight.palette
        case .moss: return MessengerTheme.forest.palette
        }
    }
    func outgoing(app: VoidPalette) -> Color {
        self == .pearl ? Color(hex: 0xE7E7ED) : palette(app: app).accent
    }
}

struct AppearancePreferences: Codable {
    var appTheme = MessengerTheme.void
    var defaultChatTheme = ChatTheme.follow
    var roomThemes: [String: ChatTheme] = [:]
    var chatTexture = true
    init() {}
    enum CodingKeys: String, CodingKey { case appTheme, defaultChatTheme, roomThemes, chatTexture }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appTheme = MessengerTheme(rawValue: try values.decodeIfPresent(String.self, forKey: .appTheme) ?? "") ?? .void
        defaultChatTheme = ChatTheme(rawValue: try values.decodeIfPresent(String.self, forKey: .defaultChatTheme) ?? "") ?? .follow
        roomThemes = (try values.decodeIfPresent([String: String].self, forKey: .roomThemes) ?? [:]).compactMapValues(ChatTheme.init(rawValue:))
        chatTexture = try values.decodeIfPresent(Bool.self, forKey: .chatTexture) ?? true
    }
}

private struct VoidPaletteKey: EnvironmentKey { static let defaultValue = MessengerTheme.void.palette }
extension EnvironmentValues {
    var voidPalette: VoidPalette {
        get { self[VoidPaletteKey.self] }
        set { self[VoidPaletteKey.self] = newValue }
    }
}
private extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
extension ChatStore {
    var appearance: AppearancePreferences { state.appearance ?? AppearancePreferences() }
    func changeAppearance(_ update: (inout AppearancePreferences) -> Void) {
        var value = appearance; update(&value); state.appearance = value; persist()
    }
    func chatTheme(_ roomID: String) -> ChatTheme { appearance.roomThemes[roomID] ?? appearance.defaultChatTheme }
}

struct ChatBackdrop: View {
    var palette: VoidPalette
    var texture: Bool
    var body: some View {
        ZStack {
            palette.background
            if texture {
                // Static geometry has no timer, network assets or per-frame work.
                Canvas { context, size in
                    for row in 0..<Int(size.height / 38) {
                        for column in 0..<Int(size.width / 38) {
                            let x = CGFloat(column) * 38 + (row.isMultiple(of: 2) ? 12 : 28)
                            let y = CGFloat(row) * 38 + 18
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(palette.accent.opacity(0.07)))
                        }
                    }
                }.accessibilityHidden(true).allowsHitTesting(false)
            }
        }.ignoresSafeArea()
    }
}

struct AppearanceSettingsView: View {
    var roomID: String? = nil
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var premiumPlan = false
    private var app: VoidPalette { store.appearance.appTheme.palette }
    private var selection: ChatTheme { roomID.map(store.chatTheme) ?? store.appearance.defaultChatTheme }
    private var chat: VoidPalette { selection.palette(app: app) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if roomID == nil {
                    Text("ТЕМА ПРИЛОЖЕНИЯ").font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92))], spacing: 12) {
                        ForEach(MessengerTheme.allCases) { theme in
                            Button {
                                if theme.premium && !store.hasPremium { premiumPlan = true }
                                else { choose { $0.appTheme = theme } }
                            } label: {
                                VStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 18).fill(theme.palette.background)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Capsule().fill(theme.palette.accent).frame(width: 28, height: 5)
                                            Capsule().fill(theme.palette.panel).frame(height: 14)
                                            Capsule().fill(theme.palette.panel).frame(height: 14)
                                        }.padding(12)
                                    }.frame(height: 76).overlay(RoundedRectangle(cornerRadius: 18).stroke(store.appearance.appTheme == theme ? theme.palette.accent : .white.opacity(0.12), lineWidth: 2))
                                    HStack(spacing: 4) { Text(theme.title); if theme.premium { Image(systemName: "sparkles").font(.caption2) } }.font(.caption.bold())
                                }
                            }.buttonStyle(MotionButtonStyle()).accessibilityAddTraits(store.appearance.appTheme == theme ? .isSelected : [])
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Так будет выглядеть чат").font(.caption).foregroundStyle(Theme.secondary)
                        Spacer()
                        Image(systemName: "lock.fill").font(.caption)
                    }
                    Text("Тише сети. Ближе к своим.").padding(13).background(chat.panel, in: RoundedRectangle(cornerRadius: 21))
                    HStack {
                        Spacer(minLength: 36)
                        Text("И со своим настроением ✨").foregroundStyle(.black).padding(13).background(selection.outgoing(app: app), in: RoundedRectangle(cornerRadius: 21))
                    }
                    HStack { Text("Сообщение").foregroundStyle(.secondary); Spacer(); Image(systemName: "arrow.up.circle.fill").foregroundStyle(chat.accent) }.padding(12).background(chat.panel, in: Capsule())
                }.padding(18).background { ChatBackdrop(palette: chat, texture: store.appearance.chatTexture) }.clipShape(RoundedRectangle(cornerRadius: 28)).overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 14) {
                    Text(roomID == nil ? "Цвет всех чатов" : "Цвет этого чата").font(.headline)
                    ForEach(ChatTheme.allCases) { theme in
                        Button {
                            choose { value in
                                if let roomID { value.roomThemes[roomID] = theme }
                                else { value.defaultChatTheme = theme }
                            }
                        } label: {
                            HStack {
                                Circle().fill(theme.outgoing(app: app)).frame(width: 24, height: 24)
                                Text(theme.title)
                                Spacer()
                                if selection == theme { Image(systemName: "checkmark.circle.fill").transition(.scale.combined(with: .opacity)) }
                            }.padding(14).background(.white.opacity(selection == theme ? 0.09 : 0.035), in: Capsule())
                        }.buttonStyle(MotionButtonStyle())
                    }
                    if let roomID, store.appearance.roomThemes[roomID] != nil {
                        Button("Использовать общую тему чатов") { choose { $0.roomThemes[roomID] = nil } }.buttonStyle(GhostButton())
                    }
                }
                if roomID == nil {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Тихая текстура фона", isOn: Binding(get: { store.appearance.chatTexture }, set: { flag in choose { $0.chatTexture = flag } }))
                        Toggle("Компактный список чатов", isOn: store.preferenceBinding(\.compactRows))
                        Text("Размер сообщений · \(Int(store.preferences.fontSize))").font(.subheadline)
                        Slider(value: store.preferenceBinding(\.fontSize), in: 13...23, step: 1)
                        Text("Оформление хранится в зашифрованном хранилище этой личности и не передаётся собеседникам. Уменьшение движения учитывается из настроек iOS.").font(.caption).foregroundStyle(Theme.secondary)
                    }.panel()
                }
            }.padding(22).softAppear()
        }.background(app.background).navigationTitle(roomID == nil ? "Оформление" : "Оформление чата").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $premiumPlan) { NavigationStack { PremiumPlanView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { premiumPlan = false } } } } }
    }
    private func choose(_ update: (inout AppearancePreferences) -> Void) {
        Haptics.light()
        withAnimation(reduceMotion ? nil : Motion.layout) { store.changeAppearance(update) }
    }
}
