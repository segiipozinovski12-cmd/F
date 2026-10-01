import XCTest
@testable import VO1DMessenger

final class ProfileTests: XCTestCase {
    @MainActor func testInvalidSavedRelayDoesNotBlockTheLocalVault() throws {
        let store = ChatStore()
        let vault = try XCTUnwrap(store.vault)
        let identity = try XCTUnwrap(store.identity)
        try store.save()
        let original = try Data(contentsOf: vault.url)
        defer { try? original.write(to: vault.url, options: [.atomic, .completeFileProtection]) }
        var state = store.state
        state.onboarded = true
        state.nickname = "Local data survives a bad relay"
        state.server = "not a relay URL"
        try vault.write(state, key: identity.storage)
        let reopened = ChatStore()
        XCTAssertNil(reopened.fatalError)
        XCTAssertEqual(reopened.state.nickname, state.nickname)
        XCTAssertNil(reopened.api)
        XCTAssertNotNil(reopened.error)
    }
    @MainActor func testFailedVaultReadCannotOverwriteTheExistingFile() throws {
        let store = ChatStore()
        let vault = try XCTUnwrap(store.vault)
        try store.save()
        let original = try Data(contentsOf: vault.url)
        defer { try? original.write(to: vault.url, options: [.atomic, .completeFileProtection]) }
        let unreadable = Data("unreadable protected vault".utf8)
        try unreadable.write(to: vault.url, options: [.atomic, .completeFileProtection])
        let failed = ChatStore()
        XCTAssertNotNil(failed.fatalError)
        failed.beginActiveSession()
        failed.persist()
        XCTAssertThrowsError(try failed.save())
        XCTAssertEqual(try Data(contentsOf: vault.url), unreadable)
    }
    @MainActor func testProtectedDataRecoveryRunsCredentialMigration() async throws {
        let store = ChatStore()
        let saved = store.state
        defer { store.state = saved; try? store.save() }
        var legacy = VaultState()
        legacy.nickname = "Recovered locally"
        let vault = try XCTUnwrap(store.vault)
        let identity = try XCTUnwrap(store.identity)
        try vault.write(legacy, key: identity.storage)
        store.fatalError = "Protected data was temporarily unavailable"
        await store.reloadProtectedData()
        XCTAssertNil(store.fatalError)
        XCTAssertEqual(store.state.nickname, legacy.nickname)
        XCTAssertNotNil(store.state.extended)
        XCTAssertEqual(store.state.accessKey?.count, 9)
        XCTAssertTrue(store.sessionUnlocked)
    }
    @MainActor func testStartupUsesProtectedKeychainAndEncryptedVault() throws {
        let id = UUID().uuidString
        defer { try? Keychain.delete(profileID:id) }
        let first = try Keychain.load(profileID:id), reopened = try Keychain.load(profileID:id)
        XCTAssertEqual(first.signing,reopened.signing)
        XCTAssertEqual(first.agreement,reopened.agreement)
        XCTAssertEqual(first.storage,reopened.storage)
        let store = ChatStore()
        XCTAssertNil(store.fatalError)
        XCTAssertNotNil(store.identity); XCTAssertNotNil(store.vault)
        try store.save()
        let restarted = ChatStore()
        XCTAssertNil(restarted.fatalError)
        XCTAssertEqual(store.myID,restarted.myID)
    }
    func testProfileVaultsAreSeparateAndUseIndependentKeys() throws {
        let first = try Vault(profileID:UUID().uuidString), second = try Vault(profileID:UUID().uuidString)
        defer { try? first.delete(); try? second.delete() }
        let a = try LocalIdentity.create(), b = try LocalIdentity.create()
        var state = VaultState(); state.nickname = "Only first"
        try first.write(state,key:a.storage)
        XCTAssertNotEqual(first.url,second.url)
        XCTAssertEqual(try second.read(key:b.storage).messages.count,0)
        XCTAssertThrowsError(try first.read(key:b.storage))
        try second.write(VaultState(),key:b.storage)
        try second.delete()
        XCTAssertEqual(try first.read(key:a.storage).nickname,"Only first")
        XCTAssertThrowsError(try Vault(profileID:"../../other"))
    }
}
