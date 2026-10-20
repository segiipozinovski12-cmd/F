import SwiftUI

extension Color {
    static func artifactHex(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct CoinMark: View {
    var size: CGFloat = 22
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.artifactHex(0xF6DEAB), .artifactHex(0xB4884E)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(.black.opacity(0.22), lineWidth: 1).padding(size * 0.12)
            Text("V").font(.system(size: size * 0.53, weight: .black, design: .rounded)).foregroundStyle(Color.artifactHex(0x34220D))
            Circle().fill(.white.opacity(0.8)).frame(width: size * 0.09).offset(x: size * 0.23, y: -size * 0.23)
        }.frame(width: size, height: size).accessibilityLabel("VO1Dcoin")
    }
}

struct CoinAmount: View {
    var value: Int
    var size: CGFloat = 18
    var body: some View {
        HStack(spacing: 5) { CoinMark(size: size); Text(value.formatted()).monospacedDigit() }
    }
}

enum ArtifactPalette {
    static func backdrop(_ id: String?) -> [Color] {
        let colors: [UInt32]
        switch id {
        case "jade": colors = [0x478E79, 0x153D37]
        case "azure": colors = [0x507CB9, 0x182C50]
        case "rose": colors = [0xAA6A87, 0x48243D]
        case "midnight": colors = [0x283244, 0x080D19]
        case "obsidian": colors = [0x19191D, 0x020203]
        default: colors = [0x8672AD, 0x342548]
        }
        return colors.map(Color.artifactHex)
    }
    static func metal(_ id: String?, collection: String) -> [Color] {
        let colors: [UInt32]
        switch id {
        case "pearl": colors = [0xFFFFFF, 0xDDE7F1, 0x798797, 0xF2F5FF]
        case "aurora": colors = [0x9CFFDD, 0x9DB5FF, 0x6947C0, 0xF8B4FF]
        case "gold": colors = [0xFFF5D4, 0xF4D187, 0x95622D, 0xFFECC0]
        case "crimson": colors = [0xFFE0DD, 0xFF536B, 0x5D1528, 0xFF8F98]
        case "monochrome": colors = [0xE7E8EF, 0x747780, 0x18191F, 0xB6B8C4]
        default:
            switch collection {
            case "singularity": colors = [0xFFDED4, 0xE27D70, 0x321C32, 0xFFD4A3]
            case "sovereign": colors = [0xFFF2CD, 0xD5B06D, 0x886434, 0xFFE8A9]
            case "prism": colors = [0xE7E3FF, 0xA696F0, 0x514297, 0xD6C7FF]
            case "orbit": colors = [0xE0FFF1, 0x78C3AF, 0x366A71, 0xD8FFFA]
            default: colors = [0xFFF4DF, 0xF3B993, 0xA44C6E, 0xFFE0C4]
            }
        }
        return colors.map(Color.artifactHex)
    }
}

/// Resolution-independent original artwork. No emoji stand-ins or remote assets.
struct ArtifactArtwork: View {
    var collection: String
    var traits: ArtifactTraits? = nil
    var animated = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floating = false
    private var metal: [Color] { ArtifactPalette.metal(traits?.model.id, collection: collection) }
    private var background: [Color] { ArtifactPalette.backdrop(traits?.backdrop.id) }

    var body: some View {
        ZStack {
            LinearGradient(colors: background, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [metal[1].opacity(0.22), .clear], center: .init(x: 0.5, y: 0.38), startRadius: 0, endRadius: 180)
            Canvas { context, size in
                context.scaleBy(x: size.width / 300, y: size.height / 300)
                drawPattern(&context)
                let ground = Path(ellipseIn: CGRect(x: 92, y: 244, width: 116, height: 12))
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 9))
                    layer.fill(ground, with: .color(.black.opacity(0.34)))
                }
                var object = context
                drawObject(&object)
                for (x, y, r) in [(74.0, 84.0, 2.0), (232, 120, 1.5), (214, 219, 2.2)] {
                    let star = starPath(center: CGPoint(x: x, y: y), radius: r * 2.5, points: 4)
                    context.fill(star, with: .color(metal[0].opacity(0.8)))
                }
            }.offset(y: floating && animated && !reduceMotion ? -4 : 0)
            LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing).allowsHitTesting(false)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12)))
        .onAppear {
            if animated && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled {
                withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { floating = true }
            }
        }
        .accessibilityLabel("\(ArtifactCollection.titles[collection] ?? collection), \(traits?.model.title ?? "Original"), фон \(traits?.backdrop.title ?? "Lavender")")
    }

    private func drawPattern(_ context: inout GraphicsContext) {
        guard traits?.pattern.id != "void" else { return }
        for row in 0..<6 {
            for column in 0..<5 {
                let center = CGPoint(x: CGFloat(column) * 69 + (row.isMultiple(of: 2) ? 10 : 40), y: CGFloat(row) * 61 + 9)
                var path = Path()
                switch traits?.pattern.id {
                case "orbits": path.addEllipse(in: CGRect(x: center.x - 9, y: center.y - 4, width: 18, height: 8))
                case "diamonds": path = starPath(center: center, radius: 8, points: 4, inner: 0.58)
                case "runes":
                    path.move(to: CGPoint(x: center.x - 5, y: center.y - 8)); path.addLine(to: CGPoint(x: center.x + 5, y: center.y)); path.addLine(to: CGPoint(x: center.x - 5, y: center.y + 8)); path.closeSubpath()
                case "eclipse": path.addEllipse(in: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14))
                default: path = starPath(center: center, radius: 6, points: 4)
                }
                context.stroke(path, with: .color(.white.opacity(0.10)), lineWidth: 1)
            }
        }
    }

    private func drawObject(_ context: inout GraphicsContext) {
        let shading = GraphicsContext.Shading.linearGradient(Gradient(colors: metal), startPoint: CGPoint(x: 95, y: 65), endPoint: CGPoint(x: 210, y: 235))
        context.addFilter(.shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 14))
        switch collection {
        case "singularity":
            let ring = Path(ellipseIn: CGRect(x: 52, y: 115, width: 196, height: 64))
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 12)); glow.stroke(ring, with: .color(metal[1].opacity(0.9)), lineWidth: 14)
            }
            context.fill(Path(ellipseIn: CGRect(x: 97, y: 91, width: 106, height: 116)), with: .color(.black))
            context.stroke(Path(ellipseIn: CGRect(x: 94, y: 88, width: 112, height: 122)), with: shading, lineWidth: 5)
            context.stroke(ring, with: shading, lineWidth: 7)
            context.stroke(Path(ellipseIn: CGRect(x: 47, y: 109, width: 206, height: 76)), with: .color(metal[0].opacity(0.6)), lineWidth: 1)
            context.fill(Path(ellipseIn: CGRect(x: 111, y: 104, width: 78, height: 88)), with: .color(.black))
        case "sovereign":
            var crown = Path()
            crown.move(to: CGPoint(x: 83, y: 196))
            for point in [CGPoint(x: 66, y: 113), CGPoint(x: 111, y: 148), CGPoint(x: 150, y: 78), CGPoint(x: 189, y: 148), CGPoint(x: 234, y: 113), CGPoint(x: 217, y: 196)] { crown.addLine(to: point) }
            crown.closeSubpath(); context.fill(crown, with: shading)
            context.stroke(crown, with: .color(metal[0].opacity(0.8)), lineWidth: 1.5)
            context.fill(Path(roundedRect: CGRect(x: 81, y: 200, width: 138, height: 14), cornerRadius: 6), with: shading)
            context.fill(starPath(center: CGPoint(x: 150, y: 169), radius: 19, points: 4, inner: 0.55), with: .color(metal[2]))
            for x in [105.0, 195] { context.fill(Path(ellipseIn: CGRect(x: x - 5, y: 175, width: 10, height: 10)), with: .color(metal[0])) }
        case "prism":
            let points = [CGPoint(x: 150, y: 63), CGPoint(x: 218, y: 119), CGPoint(x: 199, y: 205), CGPoint(x: 150, y: 238), CGPoint(x: 97, y: 205), CGPoint(x: 81, y: 119)]
            for i in 0..<points.count {
                var facet = Path(); facet.move(to: CGPoint(x: 150, y: 145)); facet.addLine(to: points[i]); facet.addLine(to: points[(i + 1) % points.count]); facet.closeSubpath()
                context.fill(facet, with: .linearGradient(Gradient(colors: [metal[i % 4], metal[(i + 1) % 4]]), startPoint: points[i], endPoint: CGPoint(x: 150, y: 166)))
                context.stroke(facet, with: .color(.white.opacity(0.3)), lineWidth: 0.8)
            }
        case "orbit":
            let planet = Path(ellipseIn: CGRect(x: 100, y: 95, width: 103, height: 111))
            context.fill(planet, with: .radialGradient(Gradient(colors: [metal[0], metal[1], metal[2]]), center: CGPoint(x: 125, y: 120), startRadius: 0, endRadius: 100))
            for index in 0..<3 {
                let inset = CGFloat(index) * 7
                context.stroke(Path(ellipseIn: CGRect(x: 55 - inset, y: 125 - inset / 2, width: 190 + inset * 2, height: 57 + inset)), with: shading, lineWidth: index == 0 ? 8 : 1.5)
            }
            context.fill(Path(ellipseIn: CGRect(x: 225, y: 102, width: 13, height: 13)), with: shading)
        default:
            let star = starPath(center: CGPoint(x: 150, y: 148), radius: 89, points: 4, inner: 0.37)
            context.drawLayer { glow in glow.addFilter(.blur(radius: 18)); glow.fill(star, with: .color(metal[1].opacity(0.6))) }
            context.fill(star, with: shading)
            context.stroke(star, with: .color(metal[0].opacity(0.9)), lineWidth: 1.3)
            context.fill(starPath(center: CGPoint(x: 150, y: 148), radius: 44, points: 4, inner: 0.35), with: .linearGradient(Gradient(colors: [metal[0], metal[2]]), startPoint: CGPoint(x: 130, y: 120), endPoint: CGPoint(x: 172, y: 180)))
        }
    }

    private func starPath(center: CGPoint, radius: CGFloat, points: Int, inner: CGFloat = 0.25) -> Path {
        Path { path in
            for index in 0..<(points * 2) {
                let angle = Double(index) * .pi / Double(points) - .pi / 2
                let r = index.isMultiple(of: 2) ? radius : radius * inner
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}
