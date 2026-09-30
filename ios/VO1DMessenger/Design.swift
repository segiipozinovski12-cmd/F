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
    @State private var scan = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.11), .white.opacity(0.025), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 220
                        )
                    )
                    .frame(width: 440, height: 440)
                    .blur(radius: 22)
                    .offset(
                        x: drift ? proxy.size.width * 0.34 : -proxy.size.width * 0.28,
                        y: drift ? -proxy.size.height * 0.20 : proxy.size.height * 0.26
                    )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.065), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 180
                        )
                    )
                    .frame(width: 360, height: 360)
                    .blur(radius: 38)
                    .offset(
                        x: drift ? -proxy.size.width * 0.38 : proxy.size.width * 0.38,
                        y: drift ? proxy.size.height * 0.34 : -proxy.size.height * 0.24
                    )

                Canvas { context, size in
                    let spacing: CGFloat = 30
                    var path = Path()
                    var x: CGFloat = 0
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += spacing
                    }
                    var y: CGFloat = 0
                    while y < size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        y += spacing
                    }
                    context.stroke(path, with: .color(.white.opacity(0.024)), lineWidth: 0.5)
                }
                .mask(
                    RadialGradient(
                        colors: [.white, .white.opacity(0.5), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.75
                    )
                )

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.045), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 150)
                    .blur(radius: 18)
                    .offset(y: scan ? proxy.size.height * 0.62 : -proxy.size.height * 0.62)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 8.5).repeatForever(autoreverses: true),
                value: drift
            )
            .animation(
                reduceMotion ? nil : .linear(duration: 7.0).repeatForever(autoreverses: false),
                value: scan
            )
        }
        .ignoresSafeArea()
        .onAppear {
            drift = true
            scan = true
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 58
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.025))

            Circle()
                .stroke(.white.opacity(0.14), lineWidth: max(1, size * 0.012))

            Circle()
                .trim(from: 0.03, to: 0.46)
                .stroke(.white, style: StrokeStyle(lineWidth: max(1.6, size * 0.018), lineCap: .round))
                .rotationEffect(.degrees(phase ? 360 : 0))

            Circle()
                .trim(from: 0.53, to: 0.96)
                .stroke(.white.opacity(0.48), style: StrokeStyle(lineWidth: max(1.1, size * 0.012), lineCap: .round))
                .rotationEffect(.degrees(phase ? -360 : 0))

            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .stroke(.white.opacity(0.24), lineWidth: max(1, size * 0.01))
                .frame(width: size * 0.46, height: size * 0.46)
                .rotationEffect(.degrees(45))

            Circle()
                .fill(.black)
                .frame(width: size * 0.29, height: size * 0.29)
                .overlay(Circle().stroke(.white, lineWidth: max(1.5, size * 0.018)))

            Capsule()
                .fill(.white)
                .frame(width: size * 0.055, height: size * 0.23)
                .offset(y: -size * 0.012)

            Circle()
                .fill(.white)
                .frame(width: size * 0.052, height: size * 0.052)
                .offset(x: size * 0.285, y: -size * 0.285)
        }
        .frame(width: size, height: size)
        .shadow(color: .white.opacity(0.1), radius: size * 0.18)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) { phase = true }
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
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .allowsTightening(true)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
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
            .lineLimit(1)
            .minimumScaleFactor(0.70)
            .allowsTightening(true)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.56 : 0.92))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(.white.opacity(configuration.isPressed ? 0.035 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}

struct Panel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.17), .white.opacity(0.035), .white.opacity(0.09)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.26), radius: 18, y: 10)
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
    @State private var appeared = false

    var body: some View {
        ZStack {
            VoidBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Wordmark(compact: true)
                        Spacer()
                        HStack(spacing: 7) {
                            Circle()
                                .fill(.white)
                                .frame(width: 6, height: 6)
                                .scaleEffect(appeared ? 1 : 0.55)
                            Text("PRODUCTION")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                        }
                        .foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 18)

                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.055), lineWidth: 1)
                            .frame(width: 196, height: 196)
                            .scaleEffect(appeared ? 1.12 : 0.82)
                            .opacity(appeared ? 0 : 0.75)

                        Circle()
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                            .frame(width: 174, height: 174)
                            .rotationEffect(.degrees(appeared ? 18 : -12))

                        BrandMark(size: 142)
                            .scaleEffect(appeared ? 1 : 0.88)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 11) {
                        Text("Тише сети.\nБлиже к своим.")
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .tracking(-1.9)
                            .minimumScaleFactor(0.82)

                        Text("Никакого телефона и почты. Ник, VO1D ID и локальные криптографические ключи. Production relay подключается автоматически.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(5)
                    }

                    VStack(spacing: 12) {
                        TextField("Твой ник", text: $name)
                            .textContentType(.nickname)
                            .submitLabel(.go)
                            .voidField()
                            .onSubmit {
                                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !clean.isEmpty, !store.busy else { return }
                                Task { await store.onboardProduction(name: clean) }
                            }

                        Button {
                            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await store.onboardProduction(name: clean) }
                        } label: {
                            HStack(spacing: 10) {
                                Text(store.busy ? "ПОДКЛЮЧАЕМ VO1D…" : "ВОЙТИ В VO1D")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.62)
                                    .allowsTightening(true)
                                    .layoutPriority(1)

                                Spacer(minLength: 8)

                                if store.busy {
                                    ProgressView()
                                        .tint(.black)
                                        .scaleEffect(0.85)
                                } else {
                                    Image(systemName: "arrow.up.right")
                                        .font(.subheadline.bold())
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OFFICIAL RELAY")
                                .font(.caption2.monospaced())
                                .tracking(1.7)
                            Text(AppConfig.productionRelayHost)
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .panel()

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "key.fill")
                        Text("После создания покажем 4-символьный VO1D ID и 9-символьный ключ доступа. Сохрани их.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(4)
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            withAnimation(.spring(response: 0.72, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

