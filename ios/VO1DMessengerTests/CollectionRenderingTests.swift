import XCTest
import SwiftUI
import UIKit
import SceneKit
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
    @MainActor func testGhostFaceRemainsVisibleAfterTextureAtlasConversion() throws {
        let image = try XCTUnwrap(ArtifactSceneFactory.poster(collection: "nova", model: "original").cgImage)
        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        var facialPixels = 0
        // Studio reflections lift black pigment into brown/gray. Check contrast in the face,
        // excluding the darker pumpkin/fold atlas regions around the silhouette.
        for y in 52..<76 {
            for x in 51..<71 {
                let i = (y * 128 + x) * 4
                if pixels[i + 3] > 200 && pixels[i] < 170 && pixels[i + 1] < 170 && pixels[i + 2] < 170 { facialPixels += 1 }
            }
        }
        XCTAssertGreaterThan(facialPixels, 3, "Eyes and mouth must be on the front of the ghost, not on the back or pumpkin atlas.")
    }

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
        social.decoration = ProfileDecoration(cover: "aurora", symbol: "moon.stars.fill", statusUntil: Date().addingTimeInterval(3600))
        social.stories = [PrivateStory(author: store.myID, text: "Маленькие открытия каждый день.", createdAt: Date(), expiresAt: Date().addingTimeInterval(3600))]
        store.state.social = social
        let identifiers = ["singularity", "sovereign", "prism", "orbit", "nova"]
        let supplies = [5000, 7500, 20000, 15000, 55000], prices = [25000, 10000, 4000, 1500, 500]
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
        CollectionPreviewProtocol.routes["/v3/economy/history"] = try bytes(["entries": [], "nextCursor": NSNull()])
        for gift in gifts {
            CollectionPreviewProtocol.routes["/v3/economy/artifact/" + (gift["id"] as! String)] = try bytes(["artifact": gift, "estimatedValue": 28500])
        }
        try await store.refreshEconomy()
        XCTAssertEqual(store.economy.artifacts.count, 5)
        XCTAssertTrue(store.hasPremium)
        try await capture(NavigationStack { ProfileScreenView(owner: store.myID) }.environmentObject(store), name: "profile")
        try await capture(NavigationStack { ArtifactStorefrontView() }.environmentObject(store), name: "storefront")
        try await capture(NavigationStack { ProfileEditorView() }.environmentObject(store), name: "profile-editor")
        try await capture(NavigationStack { PremiumPlanView() }.environmentObject(store), name: "premium")
        try await capture(NavigationStack { AppearanceSettingsView() }.environmentObject(store), name: "appearance")
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
        let skins = VStack(spacing: 12) {
            Text("CHROME UNICORN / MATERIAL STUDIES").font(.caption2.monospaced()).tracking(2).padding(.top, 20)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(ArtifactSceneFactory.models, id: \.self) { model in
                    let traits = ArtifactTraits(backdrop: ArtifactTrait(id: "obsidian", title: "Obsidian", weight: 150), pattern: ArtifactTrait(id: "void", title: "Void", weight: 50), model: ArtifactTrait(id: model, title: model.capitalized, weight: 40))
                    VStack(spacing: 5) { ArtifactArtwork(collection: "singularity", traits: traits); Text(model.capitalized).font(.caption) }
                }
            }.padding(16)
            Spacer(minLength: 0)
        }.background(.black)
        try await capture(skins, name: "skins")
        let monochrome = ArtifactTraits(backdrop: ArtifactTrait(id: "obsidian", title: "Obsidian", weight: 150), pattern: ArtifactTrait(id: "stars", title: "Stardust", weight: 3500), model: ArtifactTrait(id: "monochrome", title: "Monochrome", weight: 40))
        try await capture(ArtifactInspectionView(collection: "singularity", traits: monochrome, number: "#1"), name: "inspection")

        // Gallery-only fixture: every image uses the production SwiftUI views or
        // the exact SceneKit meshes/materials shipped in the application.
        let angles: [(String, Float, Float, Float)] = [
            ("front", 0, 0, 7.4), ("right", .pi / 2, 0, 7.4),
            ("back", .pi, 0, 7.4), ("left", -.pi / 2, 0, 7.4),
            ("above", 0.45, 0.65, 7.4), ("close", -0.25, 0.08, 5.8)
        ]
        for id in identifiers {
            for (angle, yaw, pitch, distance) in angles {
                try autoreleasepool {
                    let scene = ArtifactSceneFactory.scene(collection: id, model: "original")
                    scene.background.contents = UIColor.black
                    scene.rootNode.childNode(withName: "orbit", recursively: false)?.eulerAngles = SCNVector3(pitch, yaw, 0)
                    let camera = scene.rootNode.childNode(withName: "camera", recursively: false)
                    camera?.position.z = distance
                    let renderer = SCNRenderer(device: nil, options: nil)
                    renderer.scene = scene; renderer.pointOfView = camera
                    let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1600, height: 1600), antialiasingMode: .multisampling4X)
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("collection-preview-photo-\(id)-\(angle).png")
                    try XCTUnwrap(image.pngData()).write(to: url)
                }
            }
            for lighting in 0...2 {
                let controls = ArtifactSceneControls(yaw: 0, pitch: 0, distance: 7.4, automatic: false, lighting: lighting, reset: 1)
                try await capture(ArtifactInspectionView(collection: id, number: "#\(id == "singularity" ? 1 : 200)", snapshotControls: controls), name: "inspect-\(id)-light-\(lighting)")
            }
            let gift = try XCTUnwrap(store.economy.artifacts.first { $0.collection == id })
            try await capture(NavigationStack { ArtifactDetailView(initial: gift) }.environmentObject(store), name: "detail-\(id)")
        }
        for (index, cover) in ProfileDecoration.covers.enumerated() {
            var social = store.social
            social.decoration = ProfileDecoration(cover: cover, symbol: ProfileDecoration.symbols[index % ProfileDecoration.symbols.count], statusUntil: Date().addingTimeInterval(3600))
            social.featuredGiftID = store.economy.artifacts[index % identifiers.count].id
            store.state.social = social
            try await capture(NavigationStack { ProfileScreenView(owner: store.myID) }.environmentObject(store), name: "profile-cover-\(cover)")
        }
        let peerCard = try LocalIdentity.create().card
        store.state.contacts.append(Contact(card: peerCard, name: "Ника", verified: true))
        let room = Room(id: "gallery-room", title: "Ника", members: [try XCTUnwrap(store.identity).card, peerCard], creator: store.myID, isGroup: false, createdAt: Date().addingTimeInterval(-3600))
        store.state.rooms.append(room)
        let conversation = ["Смотри, какую коллекцию собрала ✨", "Этот кристалл выглядит как кусочек льда", "А мне нравится Cute Ghost 👻", "Он теперь живёт у меня в профиле", "Завтра отправлю тебе один 🎁", "Договорились. До завтра 🌙"]
        for (index, text) in conversation.enumerated() {
            store.state.messages.append(ChatMessage(id: "gallery-message-\(index)", roomID: room.id, sender: index % 2 == 0 ? peerCard.id : store.myID, text: text, createdAt: Date().addingTimeInterval(Double(index - 6) * 90), expiresAt: nil, replyTo: nil, attachment: nil, state: "sent", readBy: [peerCard.id], deliveredTo: [peerCard.id]))
        }
        for theme in [MessengerTheme.void, .aurora, .ember, .frost, .rose, .cobalt, .gold] {
            var appearance = store.appearance; appearance.appTheme = theme
            appearance.wallpaper = theme == .gold ? .grid : .dots
            store.state.appearance = appearance
            try await capture(NavigationStack { ChatView(roomID: room.id) }.environmentObject(store), name: "chat-theme-\(theme.rawValue)")
        }
        store.state.appearance = AppearancePreferences()
        store.state.secureNotes = [SecureNote(title: "Идеи на завтра", text: "Собрать коллекцию. Выбрать подарок. Встретиться с друзьями."), SecureNote(title: "Мои любимые места", text: "Кофейня у парка · вечерняя прогулка · новые маршруты")]
        try await capture(NavigationStack { SettingsView() }.environmentObject(store), name: "settings")
        try await capture(NavigationStack { ToolsCenterView() }.environmentObject(store), name: "tools")
        try await capture(NavigationStack { CoinWalletView() }.environmentObject(store), name: "wallet")
        try await capture(NavigationStack { SecureNotesView() }.environmentObject(store), name: "secure-notes")
        try await capture(NavigationStack { FolderCenterView() }.environmentObject(store), name: "folders")
        try await capture(NavigationStack { PrivacyView() }.environmentObject(store), name: "privacy")
    }

    @MainActor func testEveryArtifactHasFiniteThreeDimensionalGeometryAndOpaqueRenderedPixels() throws {
        for collection in ArtifactSceneFactory.collections {
            for model in ArtifactSceneFactory.models {
                let scene = ArtifactSceneFactory.scene(collection: collection, model: model)
                let object = try XCTUnwrap(scene.rootNode.childNode(withName: "artifact", recursively: true))
                let asset = try XCTUnwrap(ArtifactModelAssets.catalog?.collections[collection])
                XCTAssertEqual(object.childNodes.count, asset.meshes.count)
                for (mesh, node) in zip(asset.meshes, object.childNodes) {
                    let geometry = try XCTUnwrap(node.geometry)
                    XCTAssertEqual(geometry.sources(for: .vertex).first?.vectorCount, mesh.vertices)
                    XCTAssertEqual(geometry.elements.first?.primitiveCount, mesh.indices / 3)
                }
                let bounds = object.boundingBox
                XCTAssertGreaterThan(bounds.max.x - bounds.min.x, 0.5, "\(collection)/\(model)")
                XCTAssertGreaterThan(bounds.max.y - bounds.min.y, 0.5)
                XCTAssertGreaterThan(bounds.max.z - bounds.min.z, 0.3)
                object.enumerateChildNodes { node, _ in
                    guard let geometry = node.geometry else { return }
                    XCTAssertFalse(geometry.materials.isEmpty)
                    for source in geometry.sources(for: .vertex) + geometry.sources(for: .normal) {
                        guard source.bytesPerComponent == 4, source.usesFloatComponents else { continue }
                        source.data.withUnsafeBytes { bytes in
                            for i in 0..<source.vectorCount {
                                for j in 0..<source.componentsPerVector {
                                    let offset = source.dataOffset + i * source.dataStride + j * 4
                                    XCTAssertTrue(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self).isFinite)
                                }
                            }
                        }
                    }
                }
                let poster = ArtifactSceneFactory.poster(collection: collection, model: model)
                let image = try XCTUnwrap(poster.cgImage)
                var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                let covered = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 128 }.count
                XCTAssertGreaterThan(covered, 100, "Blank render: \(collection)/\(model)")
                XCTAssertLessThan(covered, 3600, "Background must remain transparent")
            }
        }
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
