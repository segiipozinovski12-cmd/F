import XCTest
@testable import VO1DMessenger

final class ProfileTests: XCTestCase {
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
