import Foundation
import AVFoundation
import SwiftUI

private enum AudioWaveform {
    static func samples(file: URL, points: Int = 34) -> [CGFloat] {
        guard points > 0,
              let source = try? AVAudioFile(forReading: file),
              source.length > 0 else {
            return Array(repeating: 0.35, count: points)
        }

        var sums = Array(repeating: Float(0), count: points)
        var counts = Array(repeating: 0, count: points)
        let total = max(source.length, 1)

        while source.framePosition < source.length {
            let remaining = source.length - source.framePosition
            let count = AVAudioFrameCount(min(4096, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: count) else { break }
            let start = source.framePosition
            do {
                try source.read(into: buffer, frameCount: count)
            } catch {
                break
            }
            guard let channel = buffer.floatChannelData?[0] else { break }

            for index in 0..<Int(buffer.frameLength) {
                let absoluteFrame = start + AVAudioFramePosition(index)
                let bucket = min(points - 1, Int((absoluteFrame * AVAudioFramePosition(points)) / total))
                sums[bucket] += abs(channel[index])
                counts[bucket] += 1
            }
        }

        let averages = zip(sums, counts).map { sum, count -> CGFloat in
            guard count > 0 else { return 0.12 }
            return CGFloat(sum / Float(count))
        }
        let peak = max(averages.max() ?? 0, 0.001)
        return averages.map { max(0.14, min(1, $0 / peak)) }
    }
}

@MainActor
final class VoicePlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    @Published var progress: Double = 0
    @Published var current: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    let waveform: [CGFloat]

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var file: URL?

    init(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vo1d-voice-\(UUID().uuidString).m4a")
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        file = url
        waveform = AudioWaveform.samples(file: url)
        super.init()

        if let player = try? AVAudioPlayer(contentsOf: url) {
            self.player = player
            player.delegate = self
            player.prepareToPlay()
            duration = player.duration
        }
    }

    deinit {
        timer?.invalidate()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    func toggle() {
        guard let player else { return }

        if player.isPlaying {
            player.pause()
            playing = false
            timer?.invalidate()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {}

        player.play()
        playing = true
        startTimer()
    }

    func seek(to value: Double) {
        guard let player else { return }
        let clamped = min(max(value, 0), 1)
        player.currentTime = player.duration * clamped
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        guard let player else { return }
        current = player.currentTime
        duration = player.duration
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
        if !player.isPlaying && playing {
            playing = false
            timer?.invalidate()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = false
        progress = 0
        current = 0
        timer?.invalidate()
        player.currentTime = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct VoiceMessagePlayer: View {
    let attachment: Attachment
    let tint: Color
    @StateObject private var player: VoicePlayerModel

    init(attachment: Attachment, tint: Color) {
        self.attachment = attachment
        self.tint = tint
        _player = StateObject(wrappedValue: VoicePlayerModel(data: attachment.data))
    }

    var body: some View {
        HStack(spacing: 11) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(player.waveform.enumerated()), id: \.offset) { index, value in
                            let threshold = Double(index + 1) / Double(max(player.waveform.count, 1))
                            Capsule()
                                .fill(tint.opacity(threshold <= player.progress ? 0.95 : 0.30))
                                .frame(
                                    width: max(1.4, (proxy.size.width - CGFloat(player.waveform.count - 1) * 2) / CGFloat(max(player.waveform.count, 1))),
                                    height: 5 + value * 22
                                )
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                player.seek(to: gesture.location.x / max(proxy.size.width, 1))
                            }
                    )
                }
                .frame(height: 30)

                HStack(spacing: 8) {
                    Text(time(player.playing ? player.current : player.duration))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    if let raw = attachment.voiceEffect,
                       let effect = VoiceEffect(rawValue: raw),
                       effect != .natural {
                        Text(effect.title.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .opacity(0.62)
                    }
                }
            }
        }
        .foregroundStyle(tint)
        .frame(minWidth: 190)
    }

    private func time(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
