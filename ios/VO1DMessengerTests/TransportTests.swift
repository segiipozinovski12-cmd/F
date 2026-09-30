import XCTest
@testable import VO1DMessenger

final class TransportTests: XCTestCase {
    func testOnionIsRejectedWithoutTorAndOnlyV3NamesAreAccepted() throws {
        let onion = "http://" + String(repeating:"a",count:56) + ".onion"
        XCTAssertThrowsError(try APIClient.validateURL(onion))
        XCTAssertThrowsError(try APIClient.validateURL(onion.replacingOccurrences(of:"http:",with:"https:")))
        var privacy = PrivacyPreferences(); privacy.embeddedTor = true
        XCTAssertEqual(try APIClient.validateURL(onion,privacy:privacy).host,String(repeating:"a",count:56)+".onion")
        XCTAssertThrowsError(try APIClient.validateURL("http://example.com",privacy:privacy))
        XCTAssertThrowsError(try APIClient.validateURL("http://short.onion",privacy:privacy))
        XCTAssertThrowsError(try APIClient.validateURL("http://user:pass@"+String(repeating:"a",count:56)+".onion",privacy:privacy))
    }
    func testTorRequiresIsolatedSocksCredentialsAndNoCookieCache() throws {
        var privacy = PrivacyPreferences(); privacy.embeddedTor = true
        XCTAssertThrowsError(try TransportConfiguration.make(privacy))
        privacy.streamIsolation = "per-profile-random-token"
        let config = try TransportConfiguration.make(privacy)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertEqual(config.proxyConfigurations.count,1)
        XCTAssertFalse(config.proxyConfigurations[0].allowFailover)
    }
    func testBridgeParserRejectsControlInjectionAndUnimplementedTransports() throws {
        XCTAssertEqual(try EmbeddedTorManager.bridgeLines("127.0.0.1:9001 "+String(repeating:"A",count:40)).count,1)
        for invalid in ["obfs4 1.2.3.4:99 key cert=x","1.2.3.999:9001 "+String(repeating:"A",count:40),"1.2.3.4:0 "+String(repeating:"A",count:40),"--SocksPort 0","1.2.3.4:9 \"Log debug file /tmp/x\""] {
            XCTAssertThrowsError(try EmbeddedTorManager.bridgeLines(invalid))
        }
    }
}
