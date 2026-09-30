import SwiftUI

enum Theme {
    static let background = Color.black
    static let panel = Color.white.opacity(0.055)
    static let panelStrong = Color.white.opacity(0.095)
    static let secondary = Color.white.opacity(0.52)
    static let faint = Color.white.opacity(0.08)
    static let accent = Color.white
}

struct VoidBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false
    var body: some View {
        ZStack {
            Color.black
            RadialGradient(colors: [.white.opacity(0.085), .clear], center: drift ? .topTrailing : .bottomLeading, startRadius: 10, endRadius: 430)
                .animation(reduceMotion ? nil : .easeInOut(duration: 8).repeatForever(autoreverses: true), value: drift)
            Canvas { context, size in
                let spacing: CGFloat = 32
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing
                }
                var y: CGFloat = 0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing
                }
                context.stroke(path, with: .color(.white.opacity(0.025)), lineWidth: 0.5)
            }
            .mask(LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
    }
}

struct BrandMark: View {
    var size: CGFloat = 58
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.025))
            Circle().stroke(.white.opacity(0.13), lineWidth: max(1, size * 0.012))
            Circle()
                .trim(from: 0.08, to: 0.83)
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.5, size * 0.018), lineCap: .round))
                .rotationEffect(.degrees(phase ? 360 : 0))
            Circle()
                .trim(from: 0.58, to: 0.92)
                .stroke(.white.opacity(0.38), style: StrokeStyle(lineWidth: max(1, size * 0.01), lineCap: .round))
                .rotationEffect(.degrees(phase ? -360 : 0))
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.07)
                    .fill(.white)
                    .frame(width: size * 0.22, height: size * 0.56)
                    .rotationEffect(.degrees(34))
                    .offset(x: -size * 0.10)
                RoundedRectangle(cornerRadius: size * 0.07)
                    .fill(.black)
                    .frame(width: size * 0.11, height: size * 0.39)
                    .rotationEffect(.degrees(34))
                    .offset(x: -size * 0.02)
                Circle().fill(.white).frame(width: size * 0.14, height: size * 0.14).offset(x: size * 0.18, y: -size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .white.opacity(0.08), radius: size * 0.22)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 18).repeatForever(autoreverses: false)) { phase = true }
        }
        .accessibilityLabel("VO1D")
    }
}

struct Wordmark: View {
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 9 : 12) {
            BrandMark(size: compact ? 30 : 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("VO1D").font(.system(size: compact ? 16 : 20, weight: .black, design: .monospaced)).tracking(compact ? 4 : 6)
                Text("MESSENGER").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2.4).foregroundStyle(Theme.secondary)
            }
        }
    }
}

struct Avatar: View {
    var name: String
    var group = false
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.34).fill(.white.opacity(0.075))
            RoundedRectangle(cornerRadius: size * 0.34).stroke(.white.opacity(0.13), lineWidth: 1)
            if group {
                Image(systemName: "person.2.fill").font(.system(size: size * 0.30, weight: .medium))
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.36, weight: .black, design: .rounded))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(.white.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.56 : 0.92))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(.white.opacity(configuration.isPressed ? 0.035 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.ultraThinMaterial.opacity(0.18), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.085), lineWidth: 1))
    }
}

extension View {
    func panel() -> some View { modifier(Panel()) }
    func voidField() -> some View {
        padding(16)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
            .autocorrectionDisabled()
    }
}

struct SplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = false
    @State private var scan: CGFloat = -0.8
    var body: some View {
        ZStack {
            VoidBackground()
            VStack(spacing: 26) {
                BrandMark(size: 132)
                    .scaleEffect(reveal ? 1 : 0.78)
                    .opacity(reveal ? 1 : 0)
                VStack(spacing: 8) {
                    Text("VO1D").font(.system(size: 34, weight: .black, design: .monospaced)).tracking(10)
                    Text("PRIVATE MESSAGING LAYER").font(.caption2.monospaced()).tracking(2.4).foregroundStyle(Theme.secondary)
                }
                .offset(y: reveal ? 0 : 12)
                .opacity(reveal ? 1 : 0)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.09))
                        Capsule().fill(.white).frame(width: proxy.size.width * 0.28).offset(x: proxy.size.width * scan)
                    }
                }
                .frame(width: 180, height: 2)
                .clipShape(Capsule())
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.82)) { reveal = true }
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) { scan = 1.08 }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: ChatStore
    @State private var name = ""
    @State private var server = ""
    @State private var advanced = false
    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Wordmark(compact: true)
                        Spacer()
                        Text("E2EE").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                    }.padding(.top, 20)

                    HStack { Spacer(); BrandMark(size: 154).padding(.vertical, 18); Spacer() }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Тише сети.\nБлиже к своим.")
                            .font(.system(size: 43, weight: .black, design: .rounded))
                            .tracking(-2)
                        Text("Никакого телефона и почты. Только ник, твой VO1D ID и ключ доступа.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(5)
                    }

                    VStack(spacing: 12) {
                        TextField("Твой ник", text: $name)
                            .textContentType(.nickname)
                            .voidField()

                        if advanced {
                            TextField("https://твой-relay-сервер", text: $server)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .voidField()
                        }

                        Button {
                            if server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                store.finishLocalOnboarding(name: name)
                            } else {
                                Task { await store.configure(name: name, server: server) }
                            }
                        } label: {
                            HStack {
                                Text(store.busy ? "СОЗДАЁМ ЛИЧНОСТЬ" : "ВОЙТИ В VO1D")
                                Spacer()
                                if store.busy { ProgressView().tint(.black) } else { Image(systemName: "arrow.up.right") }
                            }
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button(advanced ? "Скрыть сервер" : "Свой relay-сервер") { withAnimation(.spring) { advanced.toggle() } }
                            .buttonStyle(GhostButton())
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "key.fill")
                        Text("После создания мы покажем 4-символьный VO1D ID и 9-символьный ключ доступа. Потом они будут доступны только в настройках.")
                            .font(.caption).foregroundStyle(Theme.secondary).lineSpacing(4)
                    }
                }
                .padding(26)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
