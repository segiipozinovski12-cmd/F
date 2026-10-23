import XCTest
import CryptoKit
@testable import VO1DMessenger

final class BotWorkerTests: XCTestCase {
    struct Fixture: Codable {
        var sender: LocalIdentity; var senderCard: ContactCard
        var recipient: LocalIdentity; var recipientCard: ContactCard
        var senderState: SignalSnapshot; var recipientState: SignalSnapshot
        var packet: SignalPacket; var workerExport: Data
    }
    struct Response: Codable {
        var packet: SignalPacket; var workerExport: Data; var recipientState: SignalSnapshot
    }
    func testOfficialNodeSDKAndSwiftShareRatchetAndEncryptedTransfer() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "signal-interop", withExtension: "json"))
        let fixture = try Wire.decoder.decode(Fixture.self, from: Data(contentsOf: url))
        let opened = try SignalProtocol.decrypt(fixture.packet, from: fixture.senderCard, state: fixture.recipientState)
        XCTAssertEqual(String(data: opened.1, encoding: .utf8), "Official Node SDK to Swift")
        XCTAssertThrowsError(try SignalProtocol.decrypt(fixture.packet, from: fixture.senderCard, state: opened.0))
        let reply = try SignalProtocol.encrypt(Data("Swift reply to official Node SDK".utf8), to: fixture.senderCard, identity: fixture.recipient, state: opened.0)
        let packet = try Wire.decoder.decode(SignalPacket.self, from: reply.1)
        let result = try SignalProtocol.decrypt(packet, from: fixture.recipientCard, state: fixture.senderState)
        XCTAssertEqual(String(data: result.1, encoding: .utf8), "Swift reply to official Node SDK")
        var payload = try BotWorkerTransfer.open(fixture.workerExport, password: "interop password 123")
        XCTAssertTrue(payload.bot.card.hasSameKeys(as: fixture.recipientCard))
        payload.state.extended?.signal = reply.0
        let workerExport = try BotWorkerTransfer.export(payload, password: "interop password 123")
        XCTAssertThrowsError(try BotWorkerTransfer.open(workerExport, password: "incorrect password"))
        var invalid = payload; invalid.identity = try LocalIdentity.create()
        XCTAssertThrowsError(try BotWorkerTransfer.export(invalid, password: "interop password 123"))
        // The CI runner retrieves only this disposable test response from the
        // Simulator app container and validates it using the official Node SDK.
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("signal-interop-response.json")
        try Wire.encoder.encode(Response(packet: packet, workerExport: workerExport, recipientState: reply.0)).write(to: output, options: .atomic)
    }
}
