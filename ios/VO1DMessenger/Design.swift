import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let panel = Color(red: 0.085, green: 0.09, blue: 0.11)
    static let secondary = Color(red: 0.56, green: 0.58, blue: 0.64)
    static let accent = Color(red: 0.78, green: 0.76, blue: 0.94)
}

struct BrandMark: View {
    var size: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var rotate = false
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.035))
            Circle().stroke(.white.opacity(0.12), lineWidth: 1)
            Circle().trim(from: 0.04, to: 0.76).stroke(AngularGradient(colors: [.clear, .white.opacity(0.4), .white], center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(rotate ? 360 : 0))
            Text("V").font(.system(size: size * 0.44, weight: .light, design: .rounded)).tracking(-3)
            Circle().fill(.white).frame(width: 4, height: 4).offset(x: size * 0.19, y: -size * 0.17)
        }.frame(width: size, height: size)
            .onAppear {
                if !reduceMotion { withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { rotate = true } }
            }.accessibilityLabel("VO1D")
    }
}

struct Avatar: View {
    var name: String
    var group = false
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.35).fill(LinearGradient(colors: [.white.opacity(0.13), Theme.accent.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.35).stroke(.white.opacity(0.09), lineWidth: 1)
            if group { Image(systemName: "person.2.fill").font(.system(size: size * 0.32)) }
            else { Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.38, weight: .medium, design: .rounded)) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .background(.white.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 19))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(18).background(Theme.panel, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.06)))
    }
}

extension View {
    func panel() -> some View { modifier(Panel()) }
    func voidField() -> some View {
        padding(16).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
            .autocorrectionDisabled()
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: ChatStore
    @State var name = ""
    @State var server = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack { Text("VO1D").font(.system(size: 18, weight: .semibold, design: .monospaced)).tracking(5); Spacer(); Text("MESSENGER").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary) }
                    .padding(.top, 28)
                HStack { Spacer(); BrandMark(size: 145).padding(.vertical, 22); Spacer() }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Твоё пространство.\nТвои слова.").font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(-1.5)
                    Text("Без номера телефона. Без почты.\nС ключами, которые остаются у тебя.").font(.subheadline).foregroundStyle(Theme.secondary).lineSpacing(5)
                }
                VStack(spacing: 12) {
                    TextField("Как тебя называть?", text: $name).textContentType(.nickname).voidField()
                    TextField("https://адрес-твоего-сервера", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).voidField()
                    Button { Task { await store.configure(name: name, server: server) } } label: {
                        HStack { Text(store.busy ? "Создаём пространство…" : "Создать личность"); Spacer(); if store.busy { ProgressView().tint(.black) } else { Image(systemName: "arrow.up.right") } }
                    }.buttonStyle(PrimaryButton()).disabled(store.busy || server.isEmpty)
                    Button("Открыть приложение · сервер настрою позже") {
                        store.state.nickname = name.isEmpty ? "Ghost" : String(name.prefix(40))
                        store.state.onboarded = true; store.persist()
                    }.font(.caption).foregroundStyle(Theme.secondary).padding(.top, 3)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "key.horizontal").foregroundStyle(Theme.accent)
                    Text("ID создаётся на устройстве. Общение начнётся после подключения обоих собеседников к одному серверу.")
                        .font(.caption).foregroundStyle(Theme.secondary).lineSpacing(4)
                }
            }.padding(26)
        }.scrollDismissesKeyboard(.interactively)
    }
}
