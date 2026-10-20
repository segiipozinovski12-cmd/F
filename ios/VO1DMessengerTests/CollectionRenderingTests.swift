import XCTest
import SwiftUI
import UIKit
@testable import VO1DMessenger

private final class CollectionPreviewProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var routes: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "collections.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            let body = Self.routes[request.url?.path ?? ""] ?? Data("{}".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class CollectionRenderingTests: XCTestCase {
    @MainActor func testRenderActualProfileStorefrontAndArtwork() async throws {
        let store = ChatStore(), original = store.state, oldAPI = store.api
        APIClient.testingProtocolClasses = [CollectionPreviewProtocol.self]
        let api = try APIClient(server: "https://collections.invalid", identity: XCTUnwrap(store.identity))
        defer {
            api.invalidate(); CollectionPreviewProtocol.routes = [:]; APIClient.testingProtocolClasses = nil
            store.state = original; store.api = oldAPI
        }
        store.api = api; store.locked = false; store.sessionUnlocked = true
        store.state.nickname = "Alex Morgan"; store.state.username = "alexmorgan"
        store.state.bio = "Собираю редкие моменты. И немного звёзд."
        var social = SocialState(); social.status = "На своей орбите"
        social.stories = [PrivateStory(author: store.myID, text: "Маленькие открытия каждый день.", createdAt: Date(), expiresAt: Date().addingTimeInterval(3600))]
        store.state.social = social
        let identifiers = ["singularity", "sovereign", "prism", "orbit", "nova"]
        let supplies = [2000, 5000, 10000, 35000, 55000], prices = [25000, 10000, 4000, 1500, 500]
        let collections: [[String: Any]] = identifiers.enumerated().map { index, id in
            ["id": id, "title": ArtifactCollection.titles[id]!, "description": "Маленькая вселенная с характером.",
             "supply": supplies[index], "minted": supplies[index] / 3, "price": prices[index], "upgradePrice": 100, "published": true, "upgrades": true]
        }
        let variants: [String: Any] = ["backdrop": ["id": "obsidian", "title": "Obsidian", "weight": 150],
                                       "pattern": ["id": "stars", "title": "Stardust", "weight": 3500],
                                       "model": ["id": "monochrome", "title": "Monochrome", "weight": 40]]
        let gifts: [[String: Any]] = identifiers.enumerated().map { index, id in
            ["id": "preview-\(id)", "collection": id, "serial": index == 0 ? 1 : 126 + index * 73,
             "owner": store.myID, "ownerUsername": "alexmorgan", "pricePaid": prices[index], "lastPricePaid": prices[index],
             "acquired": Int(Date().timeIntervalSince1970), "visible": true,
             "traits": index == 0 ? variants as Any : NSNull() as Any, "listingID": NSNull(), "salePrice": NSNull()]
        }
        func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CollectionPreviewProtocol.routes = [
            "/v3/economy/catalog": try bytes(["collections": collections, "wallet": ["balance": 18650, "refundDebt": 0, "premiumUntil": Int(Date().timeIntervalSince1970) + 3600, "premium": true, "appAccountToken": UUID().uuidString], "admin": true, "products": [], "premiumProduct": "io.vo1d.premium.monthly"]),
            "/v3/economy/inventory": try bytes(["artifacts": gifts, "nextCursor": NSNull(), "total": 5, "visibleCount": 5]),
            "/v3/economy/market": try bytes(["artifacts": [], "nextCursor": NSNull()])
        ]
        try await store.refreshEconomy()
        XCTAssertEqual(store.economy.artifacts.count, 5)
        XCTAssertTrue(store.hasPremium)
        try await capture(NavigationStack { ProfileScreenView(owner: store.myID) }.environmentObject(store), name: "profile")
        try await capture(NavigationStack { ArtifactStorefrontView() }.environmentObject(store), name: "storefront")
        let artwork = VStack(spacing: 14) {
            Text("THE VO1D COLLECTION").font(.caption.monospaced()).tracking(3).padding(.top, 18)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                ForEach(identifiers, id: \.self) { id in
                    VStack(spacing: 7) { ArtifactArtwork(collection: id); Text(ArtifactCollection.titles[id]!).font(.caption.bold()) }
                }
            }.padding(16)
            Spacer(minLength: 0)
        }.background(.black)
        try await capture(artwork, name: "artwork")
    }

    @MainActor private func capture<V: View>(_ view: V, name: String) async throws {
        let controller = UIHostingController(rootView: view.preferredColorScheme(.dark).tint(.white))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852)) }
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let image = renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "collection-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("collection-preview-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
