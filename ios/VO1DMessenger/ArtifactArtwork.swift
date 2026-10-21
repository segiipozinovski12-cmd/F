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

/// Cached posters come from the same geometry used by the interactive viewer.
struct ArtifactArtwork: View {
    var collection: String
    var traits: ArtifactTraits? = nil
    @State private var poster: UIImage?
    var body: some View {
        ArtifactBackdrop(collection: collection, traits: traits)
            .overlay {
                if let poster { Image(uiImage: poster).resizable().scaledToFit().accessibilityHidden(true) }
                else { ProgressView().tint(.white.opacity(0.4)) }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .task(id: collection + ":" + (traits?.model.id ?? "original")) {
                poster = ArtifactSceneFactory.poster(collection: collection, model: traits?.model.id)
            }
            .accessibilityLabel("\(ArtifactCollection.titles[collection] ?? collection), \(traits?.model.title ?? "Original"), фон \(traits?.backdrop.title ?? "Original")")
    }
}

struct ArtifactBackdrop: View {
    var collection: String
    var traits: ArtifactTraits?
    private var background: [Color] {
        let original = ["singularity": "midnight", "sovereign": "rose", "prism": "lavender", "orbit": "jade", "nova": "azure"]
        return ArtifactPalette.backdrop(traits?.backdrop.id ?? original[collection])
    }
    var body: some View {
        ZStack {
            LinearGradient(colors: background, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.15), .clear], center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 220)
            Canvas { context, size in
                context.scaleBy(x: size.width / 300, y: size.height / 300)
                drawPattern(&context)
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 9))
                    layer.fill(Path(ellipseIn: CGRect(x: 92, y: 245, width: 116, height: 10)), with: .color(.black.opacity(0.3)))
                }
            }.allowsHitTesting(false)
        }
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
