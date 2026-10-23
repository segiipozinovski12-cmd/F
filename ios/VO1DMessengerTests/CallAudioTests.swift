import AVFoundation
import CryptoKit
import XCTest
@testable import VO1DMessenger

final class CallAudioTests: XCTestCase {
    func testRealResamplingEncryptedBothDirectionsAndPlaybackContainSound() throws {
        let alice = try LocalIdentity.create(), bob = try LocalIdentity.create()
        let a = CallSecrets(), b = CallSecrets(), id = UUID().uuidString
        let offerA = try a.offer(identity: alice, callID: id, to: bob.card.id)
        let offerB = try b.offer(identity: bob, callID: id, to: alice.card.id)
        let keyA = try a.accept(key: XCTUnwrap(offerB["key"]), signature: XCTUnwrap(offerB["keySignature"]), identity: alice, peer: bob.card, callID: id)
        let keyB = try b.accept(key: XCTUnwrap(offerA["key"]), signature: XCTUnwrap(offerA["keySignature"]), identity: bob, peer: alice.card, callID: id)
        for (rate, channels) in [(48000.0, 1), (44100.0, 2), (16000.0, 1)] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)))
            let converter = try CallPCMConverter(source: format)
            var pcm = Data()
            for block in 0..<8 {
                let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
                input.frameLength = 960
                let data = try XCTUnwrap(input.floatChannelData)
                for channel in 0..<channels {
                    for sample in 0..<960 {
                        data[channel][sample] = 0.35 * sin(Float(2 * Double.pi * 440 * Double(block * 960 + sample) / rate))
                    }
                }
                if let frame = converter.convert(input) { pcm.append(frame) }
            }
            XCTAssertGreaterThan(pcm.count, 1000)
            let sealed = try a.seal(pcm, key: keyA, callID: id)
            let received = try XCTUnwrap(b.open(sealed.0, sequence: sealed.1, key: keyB, callID: id))
            XCTAssertEqual(received, pcm)
            let playback = try XCTUnwrap(CallPCMConverter.playback(received))
            XCTAssertEqual(playback.format.sampleRate, 16000)
            let samples = try XCTUnwrap(playback.floatChannelData?[0])
            let rms = sqrt((0..<Int(playback.frameLength)).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(playback.frameLength))
            XCTAssertGreaterThan(rms, 0.1, "Converted encrypted audio became silent")
            XCTAssertLessThan(rms, 0.8)
            let reply = try b.seal(received, key: keyB, callID: id)
            XCTAssertEqual(try a.open(reply.0, sequence: reply.1, key: keyA, callID: id), pcm)
        }
    }

    func testPlaybackRejectsPartialSamplesAndLimitsBoost() throws {
        XCTAssertNil(CallPCMConverter.playback(Data([1])))
        XCTAssertNil(CallPCMConverter.playback(Data()))
        let buffer = try XCTUnwrap(CallPCMConverter.playback(Data([255, 127, 0, 128]), gain: 1.4))
        XCTAssertEqual(buffer.floatChannelData?[0][0], 1)
        XCTAssertEqual(buffer.floatChannelData?[0][1], -1)
        XCTAssertNil(CallPCMConverter.playback(Data([0, 0]), gain: .nan))
    }
}
