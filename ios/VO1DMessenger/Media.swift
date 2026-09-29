import Foundation
import AVFoundation
import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published var recording = false
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        guard recorder.record(forDuration: 180) else { throw MessengerError.invalid("Не удалось начать запись") }
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        self.recorder = recorder; file = url; seconds = 0; recording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seconds = min(self.seconds + 1, 180)
                if self.seconds >= 180 { self.timer?.invalidate() }
            }
        }
    }
    func finish() throws -> Attachment? {
        guard let file else { return nil }
        recorder?.stop(); timer?.invalidate(); recording = false
        defer { cancel() }
        return Attachment(name: "Voice.m4a", mime: "audio/mp4", data: try Data(contentsOf: file))
    }
    func cancel() {
        recorder?.stop(); timer?.invalidate(); recorder = nil; recording = false
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum MediaFiles {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("VO1DPreview", isDirectory: true) }
    static func export(_ attachment: Attachment) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: attachment.name).lastPathComponent
        let url = directory.appendingPathComponent(UUID().uuidString + "-" + (safeName.isEmpty ? "file" : safeName))
        try attachment.data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    static func clear() { try? FileManager.default.removeItem(at: directory) }
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
