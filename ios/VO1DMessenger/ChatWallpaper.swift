import SwiftUI

enum ChatWallpaper: String, CaseIterable, Codable, Identifiable {
    case dots, grid, orbits, diamonds
    var id: String { rawValue }
    var premium: Bool { self != .dots }
    var title: String {
        switch self { case .dots: return "Точки"; case .grid: return "Сетка"; case .orbits: return "Орбиты"; case .diamonds: return "Кристаллы" }
    }
}

struct WallpaperPattern: View {
    var style: ChatWallpaper
    var color: Color
    var body: some View {
        Canvas { context, size in
            let ink = GraphicsContext.Shading.color(color.opacity(0.07))
            if style == .orbits {
                for index in 0..<9 {
                    let radius = CGFloat(index + 1) * 68
                    context.stroke(Path(ellipseIn: CGRect(x: size.width * 0.8 - radius, y: size.height * 0.3 - radius, width: radius * 2, height: radius * 2)), with: ink, lineWidth: 1)
                }
            } else {
                let step: CGFloat = style == .diamonds ? 64 : 38
                for row in 0...Int(size.height / step) {
                    for column in 0...Int(size.width / step) {
                        let x = CGFloat(column) * step, y = CGFloat(row) * step
                        if style == .grid {
                            var path = Path(); path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + step, y: y)); path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x, y: y + step))
                            context.stroke(path, with: ink, lineWidth: 0.5)
                        } else if style == .diamonds {
                            var path = Path(); path.move(to: CGPoint(x: x + 16, y: y)); path.addLine(to: CGPoint(x: x + 28, y: y + 18)); path.addLine(to: CGPoint(x: x + 16, y: y + 36)); path.addLine(to: CGPoint(x: x + 4, y: y + 18)); path.closeSubpath()
                            context.stroke(path, with: ink, lineWidth: 1)
                        } else {
                            context.fill(Path(ellipseIn: CGRect(x: x + (row.isMultiple(of: 2) ? 12 : 28), y: y + 18, width: 1.6, height: 1.6)), with: ink)
                        }
                    }
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
