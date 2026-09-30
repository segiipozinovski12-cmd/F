import Foundation
import AVFoundation
import SwiftUI
import CoreImage.CIFilterBuiltins

enum VoiceEffect: String, CaseIterable, Identifiable, Codable {
    case natural
    case deep
    case bright
    case robot
    case shadow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .natural: return "Обычный"
        case .deep: return "Глубокий"
        case .bright: return "Высокий"
        case .robot: return "Робот"
        case .shadow: return "Тень"
        }
    }

    var subtitle: String {
        switch self {
        case .natural: return "Без обработки"
        case .deep: return "Ниже и плотнее"
        case .bright: return "Выше и легче"
        case .robot: return "Металлический оттенок"
        case .shadow: return "Ниже и медленнее"
        }
    }

    var pitch: Float {
        switch self {
        case .natural: return 0
        case .deep: return -520
        case .bright: return 520
        case .robot: return -110
        case .shadow: return -760
        }
    }

    var rate: Float {
        switch self {
        case .shadow: return 0.88
        case .robot: return 1.04
        default: return 1
        }
    }

    var overlap: Float {
        self == .robot ? 3 : 8
    }
}

enum VoiceProcessor {
    static func render(input: URL, effect: VoiceEffect) throws -> URL {
        guard effect != .natural else { return input }

        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = effect.pitch
        pitch.rate = effect.rate
        pitch.overlap = effect.overlap

        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let output = try MediaFiles.transientURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000
        ]
        let destination = try AVAudioFile(forWriting: output, settings: settings)

        player.scheduleFile(source, at: nil)
        try engine.start()
        player.play()

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            throw MessengerError.invalid("Не удалось подготовить обработку голоса")
        }

        let estimatedFrames = AVAudioFramePosition(
            Double(source.length) / Double(max(effect.rate, 0.5))
        ) + AVAudioFramePosition(format.sampleRate)

        while engine.manualRenderingSampleTime < estimatedFrames {
            let remaining = estimatedFrames - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
            if frames == 0 { break }
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                try destination.write(from: buffer)
            case .insufficientDataFromInputNode:
                if !player.isPlaying { engine.stop(); return output }
            case .cannotDoInCurrentContext:
                continue
            case .error:
                engine.stop()
                throw MessengerError.invalid("Не удалось применить голосовой эффект")
            @unknown default:
                engine.stop()
                throw MessengerError.invalid("Неизвестная ошибка обработки голоса")
            }
        }

        player.stop()
        engine.stop()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: output.path)
        return output
    }
}

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published var recording = false
    @Published var paused = false
    @Published var seconds = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var file: URL?
    func start() async throws {
        let allowed = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard allowed else { throw MessengerError.invalid("Разреши доступ к микрофону в настройках iOS") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let url = try MediaFiles.transientURL()
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        guard recorder.record(forDuration: 180) else { throw MessengerError.invalid("Не удалось начать запись") }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        self.recorder = recorder; file = url; seconds = 0; paused = false; recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.paused else { return }
                self.seconds = min(self.seconds + 1, 180)
                if self.seconds >= 180 { self.timer?.invalidate() }
            }
        }
    }
    func togglePause() {
        guard let recorder, recording else { return }
        if paused {
            recorder.record()
            paused = false
        } else {
            recorder.pause()
            paused = true
        }
    }

    func finish(effect: VoiceEffect) throws -> Attachment? {
        guard let file else { return nil }
        recorder?.stop()
        timer?.invalidate()
        recording = false
        paused = false

        let rendered = try VoiceProcessor.render(input: file, effect: effect)
        let data = try Data(contentsOf: rendered)
        if rendered != file { try? FileManager.default.removeItem(at: rendered) }
        defer { cancel() }

        guard data.count <= 3 * 1024 * 1024 else {
            throw MessengerError.invalid("Голосовое сообщение получилось слишком большим")
        }
        return Attachment(
            name: "Voice.m4a",
            mime: "audio/mp4",
            data: data,
            viewSeconds: nil,
            voiceEffect: effect.rawValue
        )
    }
    func cancel() {
        recorder?.stop(); timer?.invalidate(); recorder = nil; recording = false; paused = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum MediaFiles {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("VO1DPreview", isDirectory: true) }
    static var transientDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("VO1DTransient", isDirectory: true) }
    static func transientURL() throws -> URL {
        try FileManager.default.createDirectory(at:transientDirectory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        return transientDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
    }
    static func export(_ attachment: Attachment) throws -> URL {
        try export(data: attachment.data, name: attachment.name)
    }

    static func export(data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + (safeName.isEmpty ? "file" : safeName))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    static func clear() {
        try? FileManager.default.removeItem(at:directory)
        try? FileManager.default.removeItem(at:transientDirectory)
        // Remove known legacy playback files left behind by a crash before v2.
        for file in (try? FileManager.default.contentsOfDirectory(at:FileManager.default.temporaryDirectory,includingPropertiesForKeys:nil)) ?? [] where file.lastPathComponent.hasPrefix("vo1d-voice-") {
            try? FileManager.default.removeItem(at:file)
        }
    }
}

struct QRCodeView: View {
    let text: String
    var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    var body: some View {
        if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(18).background(.white, in: RoundedRectangle(cornerRadius: 24)).accessibilityLabel("QR-код контакта") }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var completion: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.completion = completion; return controller }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ScannerController, coordinator: ()) { uiViewController.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var completion: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vo1d.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var consumed = false
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                if allowed { self.configure() }
                else { self.showError("Разреши камеру в настройках iOS или вставь приглашение вручную.") }
            }
        }
    }
    private func showError(_ text: String) {
        let label = UILabel(); label.text = text; label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 30, dy: 60); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
    }
    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { showError("Камера недоступна. Вставь приглашение вручную."); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output); output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview; preview.frame = view.bounds
        queue.async { [weak self] in self?.session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { queue.async { [weak self] in self?.session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !consumed, let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let value = code.stringValue, value.hasPrefix("vo1d://contact/") else { return }
        consumed = true; stop(); completion?(value)
    }
}
