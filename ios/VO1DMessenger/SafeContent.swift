import Foundation
import UIKit
import PDFKit
import ImageIO
import Vision
import Network

enum SafeContent {
    static let trackers: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "yclid", "igshid",
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "vero_id"
    ]

    static func cleanURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = components.queryItems?.filter {
            !$0.name.lowercased().hasPrefix("utm_") && !trackers.contains($0.name.lowercased())
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap(\.url).filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
    }

    static func cleanText(_ text: String) -> String {
        var result = text
        for url in links(in: text) { result = result.replacingOccurrences(of: url.absoluteString, with: cleanURL(url).absoluteString) }
        return result
    }

    @MainActor static func copy(_ text: String, seconds: Int = 60) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Double(max(10,seconds)))])
        let count = UIPasteboard.general.changeCount
        Task {
            try? await Task.sleep(for: .seconds(max(10,seconds)))
            if UIPasteboard.general.changeCount == count { UIPasteboard.general.items = [] }
        }
    }

    static func metadataWarnings(data: Data, mime: String) -> [String] {
        var warnings: [String] = []
        if mime == "application/pdf", let pdf = PDFDocument(data: data), let attrs = pdf.documentAttributes {
            for key in [PDFDocumentAttribute.authorAttribute, .creatorAttribute] {
                if let value = attrs[key] as? String, !value.isEmpty { warnings.append("\(key.rawValue): \(value)") }
            }
        }
        if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(data as CFData,nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String: Any] {
            if props[kCGImagePropertyGPSDictionary as String] != nil { warnings.append("В фото есть геолокация GPS") }
            if props[kCGImagePropertyExifDictionary as String] != nil { warnings.append("В фото есть EXIF: камера, дата и параметры снимка") }
        }
        if ["application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation"].contains(mime) {
            warnings.append("Офисный документ может содержать автора, комментарии и историю. Этот формат не очищается автоматически.")
        }
        return warnings.map { String($0.prefix(240)) }
    }

    static func recognizeText(_ data: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func fingerprint(_ first: ContactCard, _ second: ContactCard) -> String {
        "vo1d://verify/" + [first.id,second.id].sorted().joined(separator: "/")
    }
}

enum TransportConfiguration {
    static func make(_ privacy: PrivacyPreferences) throws -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        if privacy.proxyEnabled || privacy.embeddedTor {
            let host = privacy.embeddedTor ? "127.0.0.1" : privacy.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedPort = privacy.embeddedTor ? 19050 : privacy.proxyPort
            guard !host.isEmpty, host.count <= 253, !host.contains("/"), !host.contains("@"),
                  (1...65535).contains(selectedPort),
                  let port = NWEndpoint.Port(rawValue: UInt16(selectedPort)) else {
                throw MessengerError.invalid("Укажи SOCKS5 host и порт 1–65535")
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),port: port)
            var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
            proxy.allowFailover = false
            if privacy.embeddedTor || privacy.proxyUsesTor {
                guard !privacy.streamIsolation.isEmpty else { throw MessengerError.invalid("Сначала подготовь изоляцию соединений Tor") }
                proxy.applyCredential(username:privacy.streamIsolation,password:privacy.streamIsolation)
            }
            config.proxyConfigurations = [proxy]
        }
        return config
    }
}

@MainActor
final class NetworkState: ObservableObject {
    static let shared = NetworkState()
    @Published private(set) var connected = true
    @Published private(set) var wifi = false
    @Published private(set) var expensive = false
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.connected = path.status == .satisfied
                self?.wifi = path.usesInterfaceType(.wifi)
                self?.expensive = path.isExpensive || path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.vo1d.network"))
    }
}

/// Capability and identity requests never forward their bodies or credentials
/// to a redirect target, even when the original server asks for one.
final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
