import XCTest
@testable import VO1DMessenger

final class PremiumToolsTests: XCTestCase {
    func testTemplatesReplaceUnicodeAndVariablesOnceWithoutChangingUnknownTokens() {
        let reply = ReplyTemplate(title: "Встреча", shortcut: "meet", body: "👋 {name}, это {me}. {unknown} {date} {time}")
        let output = reply.rendered(name: "{me}", me: "Алекс", now: Date(timeIntervalSince1970: 1000), locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(output.hasPrefix("👋 {me}, это Алекс. {unknown}"))
        XCTAssertFalse(output.contains("{date}")); XCTAssertFalse(output.contains("{time}"))
        XCTAssertEqual(ReplyTemplate(title: "x", shortcut: "x", body: String(repeating: "{name}", count: 1000)).rendered(name: String(repeating: "a", count: 40), me: "x").count, 4000)
    }

    func testSmartRulesCombineUnreadKindMuteAttachmentExpiryAndExclusions() {
        let now = Date()
        var room = Room(id: "work", title: "Работа", members: [], creator: "me", isGroup: true, createdAt: now, unread: 3)
        var message = ChatMessage(id: "m", roomID: room.id, sender: "peer", text: "Фото", createdAt: now, expiresAt: now.addingTimeInterval(60), replyTo: nil, attachment: Attachment(name: "x", mime: "image/jpeg", data: Data()))
        var rule = SmartFolderRule(kinds: ["groups"], unreadOnly: true, excludeMuted: true, withAttachments: true)
        XCTAssertTrue(rule.matches(room, messages: [message], now: now))
        room.unread = 0; XCTAssertFalse(rule.matches(room, messages: [message], now: now)); room.unread = 3
        room.mutedUntil = now.addingTimeInterval(1); XCTAssertFalse(rule.matches(room, messages: [message], now: now)); room.mutedUntil = nil
        message.expiresAt = now; XCTAssertFalse(rule.matches(room, messages: [message], now: now)); message.expiresAt = nil
        message.viewOnceSeconds = 30; XCTAssertFalse(rule.matches(room, messages: [message], now: now)); message.viewOnceSeconds = nil
        rule.excludedRoomIDs = [room.id]; XCTAssertFalse(rule.matches(room, messages: [message], now: now))
    }

    @MainActor func testHiddenRoomsNeverEnterSmartFoldersAndExpiryKeepsManualMembership() throws {
        let store = ChatStore(), original = store.state, economy = store.economy
        defer { store.state = original; store.economy = economy }
        store.economy = premiumEconomy(store)
        let room = Room(id: "private", title: "Личное", members: [], creator: "me", isGroup: false, createdAt: Date(), unread: 2)
        let folder = ChatFolder(name: "Непрочитанные")
        var tools = PremiumToolsState(); tools.folderRules[folder.id] = SmartFolderRule(unreadOnly: true)
        store.state.premiumTools = tools
        XCTAssertTrue(store.folderContains(folder, room: room))
        store.state.extended = ExtendedState(); store.state.extended?.hiddenRooms = [room.id]
        XCTAssertFalse(store.folderContains(folder, room: room))
        store.state.extended?.hiddenRooms = []; store.economy.catalog?.wallet.premiumUntil = 1
        XCTAssertFalse(store.folderContains(folder, room: room))
        var manual = folder; manual.roomIDs = [room.id]
        XCTAssertTrue(store.folderContains(manual, room: room))
        XCTAssertNotNil(store.premiumTools.folderRules[folder.id])
    }

    @MainActor func testTagsPersistInVaultAndExpiredOrLockedPremiumCannotModifyThem() throws {
        let store = ChatStore(), original = store.state, economy = store.economy
        let oldLocked = store.locked, oldUnlocked = store.sessionUnlocked
        let vault = try XCTUnwrap(store.vault), bytes = try Data(contentsOf: vault.url)
        defer { store.state = original; store.economy = economy; store.locked = oldLocked; store.sessionUnlocked = oldUnlocked; try? bytes.write(to: vault.url, options: [.atomic, .completeFileProtection]) }
        store.locked = false; store.sessionUnlocked = true; store.economy = premiumEconomy(store)
        let message = ChatMessage(id: "saved", roomID: ChatStore.savedRoomID, sender: store.myID, text: "Идея", createdAt: Date(), expiresAt: nil, replyTo: nil, attachment: nil)
        store.state.messages = [message]
        let tag = SavedTag(name: "Идеи")
        try store.changePremiumTools { $0.tags = [tag] }
        try store.toggleSavedTag(tag.id, message: message)
        let persisted = try vault.read(key: XCTUnwrap(store.identity).storage)
        XCTAssertEqual(persisted.premiumTools?.messageTags[message.id], [tag.id])
        var wrongRoom = message; wrongRoom.roomID = "private"
        XCTAssertThrowsError(try store.toggleSavedTag(tag.id, message: wrongRoom))
        store.locked = true; XCTAssertThrowsError(try store.changePremiumTools { $0.tags = [] }); store.locked = false
        store.economy.catalog?.wallet.premiumUntil = 1
        XCTAssertThrowsError(try store.changePremiumTools { $0.tags = [] })
        XCTAssertEqual(store.premiumTools.tags, [tag])
        store.economy = premiumEconomy(store)
        try store.changePremiumTools { $0.tags = [] }
        XCTAssertNil(store.premiumTools.messageTags[message.id])
    }

    func testOldProfileAndWalletPayloadsRemainCompatibleAndFounderZeroIsPreserved() throws {
        var state = VaultState(); state.premiumTools = PremiumToolsState(tags: [SavedTag(name: "Идеи")])
        let restored = try Wire.decoder.decode(VaultState.self, from: Wire.encoder.encode(state))
        XCTAssertEqual(restored.premiumTools?.tags.first?.name, "Идеи")
        let profile = SharedProfile(name: "Alex", bio: "", updatedAt: Date(), status: "")
        XCTAssertNil(try Wire.decoder.decode(SharedProfile.self, from: Wire.encoder.encode(profile)).featuredGiftID)
        let wallet = try JSONDecoder().decode(CoinWallet.self, from: Data("{\"balance\":0,\"refundDebt\":0,\"premiumUntil\":1,\"premium\":false,\"appAccountToken\":\"test\"}".utf8))
        XCTAssertNil(wallet.premiumLifetime)
        let gift = CollectibleArtifact(id: "founder", collection: "nova", serial: 0, pricePaid: 0, acquired: 1, visible: true)
        XCTAssertEqual(gift.number, "#0")
    }

    @MainActor private func premiumEconomy(_ store: ChatStore) -> EconomyState {
        EconomyState(owner: store.myID, catalog: EconomyCatalog(collections: [], wallet: CoinWallet(balance: 0, refundDebt: 0, premiumUntil: Int(Date().timeIntervalSince1970) + 3600, premium: true, appAccountToken: "test"), admin: false, products: [], premiumProduct: "premium"))
    }
}
