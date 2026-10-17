import SwiftUI
import ImageIO

struct ReportEvidenceFileView: View {
    var attachment: ReportAttachment
    @State private var exported: URL?
    @State private var failure: String?
    private var thumbnail: CGImage? {
        guard ["image/jpeg", "image/png"].contains(attachment.mime), attachment.data.count <= 65536,
              let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 8_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 512,
            kCGImageSourceCreateThumbnailWithTransform as String: true
        ] as CFDictionary)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Выбранный файл: \(attachment.name) · \(attachment.data.count) байт").font(.caption)
            if let thumbnail {
                Image(thumbnail, scale: 1, label: Text("Доказательство: \(attachment.name)")).resizable().scaledToFit().frame(maxHeight: 280)
            }
            Button("Подготовить файл к сохранению") {
                do { exported = try MediaFiles.export(data: attachment.data, name: attachment.name) }
                catch { failure = error.localizedDescription }
            }
            if let exported { ShareLink("Сохранить выбранное вложение", item: exported) }
            if let failure { Text(failure).font(.caption) }
        }
    }
}
