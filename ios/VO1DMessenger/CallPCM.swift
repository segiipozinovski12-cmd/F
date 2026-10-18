import AVFoundation
import Foundation

/// One converter per capture tap. Route recovery never mutates a converter
/// while the real-time callback is using it.
final class CallPCMConverter {
    static let rate: Double = 16_000
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let source: AVAudioFormat

    init(source: AVAudioFormat) throws {
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate,
                                        channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw MessengerError.invalid("Формат микрофона не поддерживается")
        }
        self.source = source; self.target = target; self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        guard input.frameLength > 0 else { return nil }
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * Self.rate / source.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: count) else { return nil }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    static func playback(_ data: Data, gain: Float = 1) -> AVAudioPCMBuffer? {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 96 * 1024,
              gain.isFinite, gain > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        let bytes = [UInt8](data)
        for index in 0..<(data.count / 2) {
            let value = Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)
            samples[index] = max(-1, min(1, Float(value) / 32768 * gain))
        }
        buffer.frameLength = AVAudioFrameCount(data.count / 2)
        return buffer
    }
}
