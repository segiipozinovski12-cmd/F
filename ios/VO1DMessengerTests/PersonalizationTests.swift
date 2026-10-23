import XCTest
@testable import VO1DMessenger

final class PersonalizationTests: XCTestCase {
    func testOldProfilesAndVaultAppearanceDecodeWithoutNewFields() throws {
        let profile = SharedProfile(name: "Alex", bio: "Private", updatedAt: Date(), status: "Here")
        let decoded = try Wire.decoder.decode(SharedProfile.self, from: Wire.encoder.encode(profile))
        XCTAssertNil(decoded.decoration)
        let social = try Wire.decoder.decode(SocialState.self, from: Wire.encoder.encode(SocialState()))
        XCTAssertNil(social.decoration); XCTAssertNil(social.featuredGiftID)
        let appearance = try JSONDecoder().decode(AppearancePreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(appearance.wallpaper, .dots); XCTAssertTrue(appearance.roomWallpapers.isEmpty)
    }

    func testExpiredStatusAndUnknownProfileDecorationAreHandled() throws {
        let now = Date()
        var style = ProfileDecoration(cover: "aurora", symbol: "moon.stars.fill", statusUntil: now.addingTimeInterval(10))
        try style.validate()
        XCTAssertNotNil(style.symbol(at: now))
        XCTAssertNil(style.symbol(at: now.addingTimeInterval(10)))
        XCTAssertNil(style.symbol(at: now.addingTimeInterval(11)))
        style.cover = "remote-cover"; XCTAssertThrowsError(try style.validate())
        style.cover = "void"; style.symbol = "unknown"; XCTAssertThrowsError(try style.validate())
    }

    @MainActor func testPersonalizationFallsBackAfterPremiumExpiryWithoutDestroyingPreferences() throws {
        let store = ChatStore()
        let original = store.state, economy = store.economy
        defer { store.state = original; store.economy = economy }
        let premium = CoinWallet(balance: 0, refundDebt: 0, premiumUntil: Int(Date().timeIntervalSince1970) + 1000, premium: true, appAccountToken: "test")
        store.economy = EconomyState(owner: store.myID, catalog: EconomyCatalog(collections: [], wallet: premium, admin: false, products: [], premiumProduct: "premium"))
        var appearance = AppearancePreferences(); appearance.wallpaper = .grid; appearance.roomWallpapers["room"] = .orbits
        store.state.appearance = appearance
        var social = store.social; social.decoration = ProfileDecoration(cover: "gold", symbol: "sparkles"); store.state.social = social
        XCTAssertEqual(store.chatWallpaper(nil), .grid); XCTAssertEqual(store.chatWallpaper("room"), .orbits)
        XCTAssertEqual(store.ownSharedProfile.decoration?.cover, "gold")
        store.economy.catalog?.wallet.premiumUntil = 1
        XCTAssertEqual(store.chatWallpaper("room"), .dots)
        XCTAssertEqual(store.ownSharedProfile.decoration?.cover, "void"); XCTAssertNil(store.ownSharedProfile.decoration?.symbol)
        XCTAssertEqual(store.appearance.roomWallpapers["room"], .orbits)
        XCTAssertEqual(store.social.decoration?.cover, "gold")
    }

    func testWallpapersRoundTripAndUnknownFutureStylesFallBack() throws {
        var appearance = AppearancePreferences(); appearance.wallpaper = .diamonds; appearance.roomWallpapers["private"] = .grid
        let decoded = try JSONDecoder().decode(AppearancePreferences.self, from: JSONEncoder().encode(appearance))
        XCTAssertEqual(decoded.wallpaper, .diamonds); XCTAssertEqual(decoded.roomWallpapers["private"], .grid)
        let future = try JSONDecoder().decode(AppearancePreferences.self, from: Data("{\"wallpaper\":\"future\",\"roomWallpapers\":{\"old\":\"grid\",\"new\":\"future\"}}".utf8))
        XCTAssertEqual(future.wallpaper, .dots); XCTAssertEqual(future.roomWallpapers["old"], .grid); XCTAssertNil(future.roomWallpapers["new"])
    }
}
