import AVFoundation
import CallKit
import CryptoKit
import Foundation
import MediaPlayer
import SwiftUI

enum VoiceCallPhase: String {
    case ringing
    case connecting
    case active
    case reconnecting
}

struct VoiceCallSession: Identifiable, Equatable {
    let id: UUID
    let callID: String
    var peerID: String
    var peerName: String
    let incoming: Bool
    let createdAt: Date
    var phase: VoiceCallPhase
    var startedAt: Date?
}

private final class CallAudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var running = false
    var isRunning: Bool { running && engine.isRunning }
    private var tapInstalled = false
    private var captureConverter: AVAudioConverter?
    private let captureFormat = AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16_000,channels:1,interleaved:true)!
    var muted = false
    var quietSpeechBoost = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }

    func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth]
        )
    }

    func start(onFrame: @escaping (Data) -> Void) throws {
        guard !isRunning else { return }
        if running || tapInstalled { stop() }

        let input = engine.inputNode
        // The tap consumes the node's output format. The hardware-side input
        // format may differ after Bluetooth or voice-chat route negotiation.
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MessengerError.invalid("Микрофон недоступен")
        }

        captureConverter = AVAudioConverter(from:format,to:captureFormat)
        guard captureConverter != nil else { throw MessengerError.invalid("Формат микрофона не поддерживается") }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1920, format: format) { [weak self] buffer, _ in
                guard let self, !self.muted else { return }
                guard let data = self.pcm16Mono16k(buffer: buffer, format: format), !data.isEmpty else { return }
                onFrame(data)
            }
            tapInstalled = true
        }

        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        player.stop()
        engine.stop()
        running = false
        captureConverter = nil
        muted = false
    }

    func play(_ data: Data) {
        guard running, data.count >= 2 else { return }
        let frameCount = data.count / 2
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channel = buffer.floatChannelData?[0] else { return }

        let bytes = [UInt8](data)
        for index in 0..<frameCount {
            let lo = UInt16(bytes[index * 2])
            let hi = UInt16(bytes[index * 2 + 1]) << 8
            let sample = Int16(bitPattern: lo | hi)
            let normalized = Float(sample) / 32768
            channel[index] = max(-1, min(1, normalized * (quietSpeechBoost ? 1.4 : 1)))
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func pcm16Mono16k(buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> Data? {
        guard let converter = captureConverter, buffer.frameLength > 0 else { return nil }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat:captureFormat,frameCapacity:capacity) else { return nil }
        var supplied = false, conversionError: NSError?
        let status = converter.convert(to:output,error:&conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0,
              let bytes = output.int16ChannelData?[0] else { return nil }
        return Data(bytes:bytes,count:Int(output.frameLength)*2)
    }

}

enum CallAudioOutput: String, CaseIterable, Identifiable {
    case receiver, speaker, bluetooth

    var id: Self { self }
    var title: String {
        switch self {
        case .receiver: return "Телефон"
        case .speaker: return "Громкая связь"
        case .bluetooth: return "Bluetooth"
        }
    }
    var icon: String {
        switch self {
        case .receiver: return "iphone.gen3"
        case .speaker: return "speaker.wave.3.fill"
        case .bluetooth: return "airpodspro"
        }
    }
}

private final class CallKitBridge: NSObject, CXProviderDelegate {
    weak var owner: CallManager?

    func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in owner?.providerReset() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in owner?.performStart(action) }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in owner?.performAnswer(action) }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in owner?.performEnd(action) }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in owner?.performMute(action) }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in owner?.audioActivated() }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in owner?.audioDeactivated() }
    }
}

@MainActor
final class CallManager: ObservableObject {
    static let shared = CallManager()

    @Published private(set) var session: VoiceCallSession?
    @Published private(set) var muted = false
    @Published private(set) var speaker = false
    @Published private(set) var audioOutput: CallAudioOutput = .receiver
    @Published private(set) var bluetoothAvailable = false
    @Published private(set) var quietSpeechBoost = false
    @Published private(set) var isCallScreenExpanded = true
    @Published private(set) var transport = "OFFLINE"
    @Published private(set) var lastFailure: String?
    @Published private(set) var preparingCall = false

    private let provider: CXProvider
    private let bridge: CallKitBridge
    private let controller = CXCallController()
    private let audio = CallAudioEngine()
    var allowedPeer: ((String) -> Bool)?

    private var socket: URLSessionWebSocketTask?
    private var replacementSocket: URLSessionWebSocketTask?
    private var socketAuthorization: Data?
    private var api: APIClient?
    private var identity: LocalIdentity?
    private var pendingConfiguration: (APIClient, LocalIdentity, ContactCard?)?
    private var canonicalCard: ContactCard?
    private var peerCard: ContactCard?
    private var callKey: SymmetricKey?
    private var callSecrets: CallSecrets?
    private var audioSessionActive = false
    private var socketReady = false
    private var nameResolver: ((String) -> String)?
    private var recordSink: ((CallRecord) -> Void)?
    private var connectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var mediaStartTask: Task<Void, Never>?
    private var mediaGeneration = UUID()
    private var configurationID = UUID()
    private var connectionID = UUID()
    private var routeObserver: NSObjectProtocol?

    private init() {
        let configuration = CXProviderConfiguration(localizedName: "VO1D")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false

        provider = CXProvider(configuration: configuration)
        bridge = CallKitBridge()

        bridge.owner = self
        provider.setDelegate(bridge, queue: nil)
        refreshOutputAvailability()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(notification)
            }
        }
    }

    private func refreshOutputAvailability() {
        bluetoothAvailable = AVAudioSession.sharedInstance().availableInputs?.contains(where: {
            $0.portType == .bluetoothHFP
        }) ?? false
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        refreshOutputAvailability()
        guard session != nil else { return }
        let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        if reason == .oldDeviceUnavailable && audioOutput == .bluetooth && !bluetoothAvailable {
            audioOutput = .receiver
            speaker = false
        }
        guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable ||
              reason == .routeConfigurationChange else { return }
        restartMediaForRouteChange()
    }

    private func restartMediaForRouteChange() {
        guard audio.isRunning else { return }
        mediaGeneration = UUID()
        mediaStartTask?.cancel()
        mediaStartTask = nil
        audio.stop()
        activateMediaIfReady()
    }

    private func applySelectedAudioOutput() throws {
        let system = AVAudioSession.sharedInstance()
        switch audioOutput {
        case .receiver:
            try system.overrideOutputAudioPort(.none)
            if let builtInMic = system.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try system.setPreferredInput(builtInMic)
            }
        case .speaker:
            try system.setPreferredInput(nil)
            try system.overrideOutputAudioPort(.speaker)
        case .bluetooth:
            guard let bluetooth = system.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
                throw MessengerError.invalid("Bluetooth-гарнитура недоступна")
            }
            try system.overrideOutputAudioPort(.none)
            try system.setPreferredInput(bluetooth)
        }
    }

    func configure(
        api: APIClient,
        identity: LocalIdentity,
        ownerCard: ContactCard? = nil,
        nameResolver: @escaping (String) -> String,
        recordSink: @escaping (CallRecord) -> Void
    ) {
        self.nameResolver = nameResolver
        self.recordSink = recordSink
        if self.api === api, socket != nil { return }
        if session != nil, (socket != nil || callSecrets != nil) {
            // An accepted background call retains the delegated identity used
            // for its handshake until it ends, even after foreground unlock.
            pendingConfiguration = (api, identity, ownerCard)
            return
        }
        self.api = api
        self.identity = identity
        startTask?.cancel(); startTask = nil; preparingCall = false
        configurationID = UUID()
        self.canonicalCard = ownerCard ?? (try? identity.card)
        connectSocket()
    }

    func disconnect() {
        configurationID = UUID()
        connectTask?.cancel(); connectTask = nil
        heartbeatTask?.cancel(); heartbeatTask = nil
        startTask?.cancel(); startTask = nil; preparingCall = false
        pendingConfiguration = nil
        if let current = session {
            provider.reportCall(with: current.id, endedAt: Date(), reason: .failed)
            finishCurrent(status: current.phase == .active ? "interrupted" : (current.incoming ? "missed" : "cancelled"))
        } else {
            cleanup()
        }
        socket?.cancel(with: .goingAway, reason: nil)
        replacementSocket?.cancel(with: .goingAway, reason: nil); replacementSocket = nil
        socket = nil
        socketAuthorization = nil
        socketReady = false
        transport = "OFFLINE"
        api = nil
        identity = nil
        canonicalCard = nil
        nameResolver = nil
        recordSink = nil
    }

    func startCall(peer: ContactCard, name: String) {
        guard session == nil, startTask == nil else { return }
        guard NetworkState.shared.connected else { lastFailure = "Для интернет-звонка подключись к Wi-Fi или мобильной сети"; return }
        guard allowedPeer?(peer.id) != false else { lastFailure = "Сначала подтверди общение с этим контактом и разреши звонки"; return }
        lastFailure = nil
        preparingCall = true
        let expected = configurationID
        startTask = Task {
            defer { if expected == configurationID { preparingCall = false; startTask = nil } }
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled, expected == configurationID else { return }
            guard granted else { lastFailure = "Разреши микрофон в настройках iOS → VO1D"; return }
            do {
                try await prepareCallTransport()
                guard !Task.isCancelled, expected == configurationID else { return }
                beginOutgoing(peer: peer, name: name)
            } catch is CancellationError { }
            catch {
                guard expected == configurationID else { return }
                lastFailure = "Не удалось подключить звонок: \(error.localizedDescription)"
            }
        }
    }

    private func beginOutgoing(peer: ContactCard, name: String) {
        guard session == nil, allowedPeer?(peer.id) != false else { return }
        guard socketReady else {
            transport = "RECONNECTING"
            connectSocket()
            return
        }
        guard let identity else { return }

        do {
            try Crypto.validate(peer)
            try audio.prepareSession()

            let uuid = UUID()
            peerCard = peer
            callSecrets = CallSecrets()
            callKey = nil
            session = VoiceCallSession(
                id: uuid,
                callID: uuid.uuidString,
                peerID: peer.id,
                peerName: name,
                incoming: false,
                createdAt: Date(),
                phase: .connecting,
                startedAt: nil
            )
            isCallScreenExpanded = true
            refreshOutputAvailability()

            let handle = CXHandle(type: .generic, value: name)
            let action = CXStartCallAction(call: uuid, handle: handle)
            action.isVideo = false
            controller.request(CXTransaction(action: action)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in
                    guard self?.session?.id == uuid else { return }
                    self?.lastFailure = error?.localizedDescription
                    self?.failCurrent(reason: .failed)
                }
            }
        } catch {
            lastFailure = "Не удалось начать звонок: \(error.localizedDescription)"
            cleanup()
        }
    }

    func answerFromApp() {
        guard let session, session.incoming else { return }
        isCallScreenExpanded = true
        controller.request(CXTransaction(action: CXAnswerCallAction(call: session.id))) { _ in }
    }

    func endFromApp() {
        guard let session else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: session.id))) { _ in }
    }

    func toggleMute() {
        guard let session else { return }
        controller.request(
            CXTransaction(action: CXSetMutedCallAction(call: session.id, muted: !muted))
        ) { _ in }
    }

    func toggleSpeaker() {
        selectAudioOutput(speaker ? .receiver : .speaker)
    }

    func selectAudioOutput(_ output: CallAudioOutput) {
        guard session != nil else { return }
        if output == .bluetooth && !bluetoothAvailable {
            lastFailure = "Bluetooth-гарнитура не подключена"
            return
        }
        let previous = audioOutput
        audioOutput = output
        do {
            if audioSessionActive { try applySelectedAudioOutput() }
            speaker = output == .speaker
            audio.quietSpeechBoost = quietSpeechBoost && speaker
            restartMediaForRouteChange()
        } catch {
            audioOutput = previous
            speaker = previous == .speaker
            lastFailure = "Не удалось переключить звук: \(error.localizedDescription)"
        }
    }

    func toggleQuietSpeechBoost() {
        quietSpeechBoost.toggle()
        audio.quietSpeechBoost = quietSpeechBoost && speaker
    }

    func setCallScreenExpanded(_ expanded: Bool) {
        isCallScreenExpanded = expanded
    }

    fileprivate func performStart(_ action: CXStartCallAction) {
        guard let current = session, current.id == action.callUUID else {
            action.fail()
            return
        }

        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()

        Task {
            do {
                guard let identity,let callSecrets else { throw MessengerError.invalid("Нет ключей звонка") }
                var packet=try callSecrets.offer(identity:identity,callID:current.callID,to:current.peerID,ownerID:canonicalCard?.id)
                packet["type"]="invite"; packet["to"]=current.peerID; packet["callID"]=current.callID
                try await send(packet)
            } catch {
                guard session?.id == current.id else { return }
                lastFailure = error.localizedDescription
                failCurrent(reason: .failed)
            }
        }
    }

    fileprivate func performAnswer(_ action: CXAnswerCallAction) {
        guard var current = session, current.id == action.callUUID, current.incoming, current.phase == .ringing else {
            action.fail()
            return
        }

        current.phase = .connecting
        session = current
        action.fulfill()

        Task {
            do {
                let granted = await withCheckedContinuation { continuation in
                    AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
                }
                guard session?.id == current.id else { return }
                guard granted else {
                    lastFailure = "Разреши микрофон в настройках iOS → VO1D"
                    failCurrent(reason: .failed); return
                }
                try await prepareCallTransport()
                for _ in 0..<100 {
                    guard session?.id == current.id else { return }
                    if socketReady && callKey != nil { break }
                    try await Task.sleep(for:.milliseconds(100))
                }
                guard let ready = session, ready.id == current.id else { return }
                guard socketReady,callKey != nil, !ready.peerID.isEmpty else {
                    lastFailure = "Не удалось получить ключи и адрес собеседника"
                    failCurrent(reason:.failed); return
                }
                guard let identity,let callSecrets else { throw MessengerError.invalid("Нет ключей звонка") }
                var packet=try callSecrets.offer(identity:identity,callID:ready.callID,to:ready.peerID,ownerID:canonicalCard?.id)
                packet["type"]="answer"; packet["to"]=ready.peerID; packet["callID"]=ready.callID
                try await send(packet)
                guard session?.id == ready.id else { return }
                var accepted = ready; accepted.phase = .active; accepted.startedAt = Date(); session = accepted
                activateMediaIfReady()
            } catch {
                guard session?.id == current.id else { return }
                lastFailure = error.localizedDescription
                failCurrent(reason: .failed)
            }
        }
    }

    fileprivate func performEnd(_ action: CXEndCallAction) {
        guard let current = session, current.id == action.callUUID else {
            action.fulfill()
            return
        }
        action.fulfill()

        sendEndSignal(current)
        finishCurrent(status: localEndStatus(current))
    }

    fileprivate func performMute(_ action: CXSetMutedCallAction) {
        muted = action.isMuted
        audio.muted = action.isMuted
        action.fulfill()
    }

    fileprivate func providerReset() {
        if let current = session {
            finishCurrent(status: current.phase == .active ? "interrupted" : (current.incoming ? "missed" : "cancelled"))
        } else {
            cleanup()
        }
    }

    fileprivate func audioActivated() {
        audioSessionActive = true
        refreshOutputAvailability()
        do { try applySelectedAudioOutput() }
        catch { lastFailure = "Аудиовыход недоступен: \(error.localizedDescription)" }
        activateMediaIfReady()
    }

    fileprivate func audioDeactivated() {
        audioSessionActive = false
        mediaGeneration = UUID()
        mediaStartTask?.cancel(); mediaStartTask = nil
        audio.stop()
    }

    private func authorizationDigest(_ request: URLRequest) -> Data {
        Data(SHA256.hash(data: Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8)))
    }

    private func prepareCallTransport() async throws {
        guard let api else { throw MessengerError.invalid("Сессия звонков ещё не готова") }
        let expected = configurationID
        try await api.refreshCallAuthorization()
        guard !Task.isCancelled, expected == configurationID, self.api === api else { throw CancellationError() }
        let desired = authorizationDigest(try api.callSocketRequest())
        if socketAuthorization != desired || socket == nil {
            connectSocket(preservingPendingCall: session?.incoming == true && session?.startedAt == nil)
        }
        for _ in 0..<200 {
            guard !Task.isCancelled, expected == configurationID, self.api === api else { throw CancellationError() }
            if socketReady {
                if socketAuthorization == authorizationDigest(try api.callSocketRequest()) { return }
                connectSocket(preservingPendingCall: session?.incoming == true && session?.startedAt == nil)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MessengerError.invalid("Канал звонков не ответил. Проверь сеть и выбранный маршрут.")
    }

    private func connectSocket(preservingPendingCall: Bool = false) {
        guard let api else { return }
        connectTask?.cancel(); heartbeatTask?.cancel()
        let expected = UUID(); connectionID = expected
        if preservingPendingCall {
            // Let the relay replace the still-live socket atomically. Closing
            // it before the new handshake would discard an unanswered invite.
            if let socket { replacementSocket = socket }
        } else {
            socket?.cancel(with: .goingAway, reason: nil)
            replacementSocket?.cancel(with: .goingAway, reason: nil); replacementSocket = nil
        }
        socket = nil
        socketAuthorization = nil
        socketReady = false
        transport = "CONNECTING"

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await api.refreshCallAuthorization()
                guard !Task.isCancelled, connectionID == expected, self.api === api else { return }
                let request = try api.callSocketRequest()
                socketAuthorization = authorizationDigest(request)
                let task = api.session.webSocketTask(with: request)
                socket = task
                task.resume()
                receiveLoop(task)
                heartbeatTask = Task { [weak self, weak task] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        guard let self, let task, self.socket === task else { return }
                        do {
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                task.sendPing { error in
                                    if let error { continuation.resume(throwing: error) }
                                    else { continuation.resume() }
                                }
                            }
                        } catch { task.cancel(with: .goingAway, reason: nil); return }
                    }
                }
            } catch {
                guard !Task.isCancelled, connectionID == expected, self.api === api else { return }
                transport = "OFFLINE"
                if preparingCall { lastFailure = "Не удалось авторизовать звонки: \(error.localizedDescription)" }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard connectionID == expected, self.api === api else { return }
                connectSocket()
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        let expected = connectionID
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await task.receive()
                guard self.socket === task, self.connectionID == expected else { return }
                try await self.handle(message)
                self.receiveLoop(task)
            } catch {
                guard self.socket === task, self.connectionID == expected else { return }
                self.socket = nil
                self.socketAuthorization = nil
                self.replacementSocket?.cancel(with: .goingAway, reason: nil); self.replacementSocket = nil
                self.socketReady = false
                self.heartbeatTask?.cancel()
                self.transport = "OFFLINE"
                if let current = self.session, current.startedAt != nil, self.callKey != nil { self.pauseCurrent() }
                else if self.session != nil { self.failCurrent(reason: .failed) }

                if (task.response as? HTTPURLResponse)?.statusCode == 401 || task.closeCode.rawValue == 4003 {
                    try? await self.api?.refreshCallAuthorization(force: true)
                }

                try? await Task.sleep(for: .seconds(3))
                if self.connectionID == expected && self.api != nil && self.socket == nil {
                    self.connectSocket()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async throws {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else { return }
            text = value
        @unknown default:
            return
        }

        guard let data = text.data(using: .utf8),
              let packet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = packet["type"] as? String else { return }

        if type == "ready" {
            replacementSocket?.cancel(with: .goingAway, reason: nil); replacementSocket = nil
            socketReady = true
            transport = "WSS"
            if session?.phase == .reconnecting { await sendResume(type:"resume") }
            if let current=session, current.incoming, callKey==nil {
                await preparePushedMedia(current)
            }
            return
        }

        if type == "error" {
            let code = packet["code"] as? String ?? "call_error"
            lastFailure = ["peer_offline": "Собеседник не в сети. Без APNs оба приложения должны быть открыты.",
                           "peer_unavailable": "Собеседник должен принять запрос на переписку и разрешить звонки.",
                           "peer_busy": "Собеседник уже разговаривает."][code] ?? "Ошибка звонка: \(code)"
            if ["peer_offline", "peer_busy", "peer_unavailable", "unknown_peer", "unknown_call", "call_mismatch", "invalid_resume"].contains(code) {
                failCurrent(reason: code == "peer_offline" ? .unanswered : .failed)
            }
            return
        }

        guard let peerID = packet["from"] as? String,
              let callID = packet["callID"] as? String else { return }

        if type == "invite" {
            await receiveInvite(from: peerID, callID: callID,packet:packet)
            return
        }

        guard let current = session,
              current.callID == callID,
              current.peerID == peerID else { return }

        switch type {
        case "ringing":
            guard !current.incoming, current.startedAt == nil else { return }
            var updated = current; updated.phase = .ringing; session = updated
        case "answer":
            guard !current.incoming,let callSecrets,let identity,let peerCard,
                  let key=packet["key"] as? String,let signature=packet["keySignature"] as? String else { return }
            callKey=try callSecrets.accept(key:key,signature:signature,identity:identity,peer:peerCard,callID:callID,ownerID:canonicalCard?.id,certificate:packet["certificate"] as? String)
            var updated = current
            updated.phase = .active
            updated.startedAt = Date()
            session = updated
            provider.reportOutgoingCall(with: current.id, connectedAt: Date())
            activateMediaIfReady()

        case "paused":
            pauseCurrent()
        case "resume", "resumed":
            guard current.startedAt != nil, let key = callKey, let secrets = callSecrets,
                  let encoded = packet["payload"] as? String, let payload = Data(base64Encoded:encoded),
                  let sequence = packet["sequence"] as? String,
                  let clear = try secrets.open(payload,sequence:sequence,key:key,callID:callID),
                  clear == Data("VO1D-CALL-RESUME-2".utf8) else { return }
            var updated = current; updated.phase = .active; session = updated
            transport = "WSS"; activateMediaIfReady()
            if type == "resume" { await sendResume(type:"resumed") }
        case "audio":
            guard current.phase == .active,
                  let payload = packet["payload"] as? String,
                  let encrypted = Data(base64Encoded: payload),
                  let key = callKey else { return }

            guard let callSecrets,let sequence=packet["sequence"] as? String,
                  let clear=try? callSecrets.open(encrypted,sequence:sequence,key:key,callID:callID) else { return }
            audio.play(clear)

        case "end":
            provider.reportCall(with: current.id, endedAt: Date(), reason: .remoteEnded)
            finishCurrent(status: remoteEndStatus(current))

        default:
            break
        }
    }

    private func pauseCurrent() {
        guard var current = session, current.startedAt != nil else { return }
        let firstPause = current.phase != .reconnecting
        current.phase = .reconnecting; session = current; audio.stop(); transport = "RECONNECTING"
        if firstPause {
            let callID = current.callID
            Task { [weak self] in
                try? await Task.sleep(for:.seconds(20))
                guard let self, self.session?.callID == callID, self.session?.phase == .reconnecting else { return }
                self.failCurrent(reason:.failed)
            }
        }
    }
    private func sendResume(type: String) async {
        guard let current = session, let key = callKey, let secrets = callSecrets, socketReady else { return }
        do {
            let frame = try secrets.seal(Data("VO1D-CALL-RESUME-2".utf8),key:key,callID:current.callID)
            try await send(["type":type,"to":current.peerID,"callID":current.callID,"payload":frame.0.base64EncodedString(),"sequence":frame.1])
        } catch { transport = "RECONNECTING" }
    }

    private func receiveInvite(from peerID: String,callID: String,packet: [String:Any]) async {
        guard allowedPeer?(peerID) != false, session==nil || session?.callID==callID,
              let api,let identity,let uuid=UUID(uuidString:callID),
              let key=packet["key"] as? String,let signature=packet["keySignature"] as? String else { return }
        do {
            let peer: ContactCard
            if let packed = packet["card"] as? String { peer = try Wire.decoder.decode(ContactCard.self, from: Crypto.decode(packed)); try Crypto.validate(peer) }
            else { peer=try await api.card(peerID) }
            guard self.api === api else { return }
            guard peer.id == peerID else { throw MessengerError.invalid("ID звонящего не совпал с ключом") }
            guard session==nil || session?.callID==callID else { return }
            let secrets=callSecrets ?? CallSecrets()
            let symmetric=try secrets.accept(key:key,signature:signature,identity:identity,peer:peer,callID:callID,ownerID:canonicalCard?.id,certificate:packet["certificate"] as? String)
            try audio.prepareSession()
            callSecrets=secrets; peerCard=peer; callKey=symmetric
            if var pushed = session, pushed.callID == callID, pushed.peerID.isEmpty {
                pushed.peerID = peerID; pushed.peerName = nameResolver?(peerID) ?? "VO1D"; session = pushed
            }
            if session==nil {
                let name=nameResolver?(peerID) ?? "VO1D"
                session=VoiceCallSession(id:uuid,callID:callID,peerID:peerID,peerName:name,incoming:true,createdAt:Date(),phase:.ringing,startedAt:nil)
                isCallScreenExpanded = false
                let update=CXCallUpdate()
                update.remoteHandle=CXHandle(type:.generic,value:name); update.localizedCallerName=name
                update.hasVideo=false; update.supportsHolding=false; update.supportsGrouping=false; update.supportsUngrouping=false; update.supportsDTMF=false
                provider.reportNewIncomingCall(with:uuid,update:update) { [weak self] error in
                    if let error { Task { @MainActor in
                        guard self?.session?.id == uuid else { return }
                        self?.lastFailure = "iOS не приняла входящий звонок: \(error.localizedDescription)"
                        self?.finishCurrent(status:"failed")
                    } }
                }
            }
            activateMediaIfReady()
        } catch { lastFailure = error.localizedDescription; failCurrent(reason:.failed) }
    }

    func reportPushedCall(peerID: String, callID: String, completion: @escaping () -> Void) {
        guard let uuid=UUID(uuidString:callID) else { completion(); return }
        if session?.id==uuid { completion(); return }
        let update=CXCallUpdate()
        update.remoteHandle=CXHandle(type:.generic,value:"VO1D")
        update.localizedCallerName="VO1D"
        update.hasVideo=false
        let rejected=session != nil || (!peerID.isEmpty && (allowedPeer?(peerID)==false || peerID.count != 64))
        if !rejected {
            session=VoiceCallSession(id:uuid,callID:callID,peerID:peerID,peerName:"VO1D",incoming:true,createdAt:Date(),phase:.ringing,startedAt:nil)
            isCallScreenExpanded = false
        }
        provider.reportNewIncomingCall(with:uuid,update:update) { [weak self] error in
            completion()
            Task { @MainActor in
                guard let self else { return }
                if rejected || error != nil {
                    self.provider.reportCall(with:uuid,endedAt:Date(),reason:.failed)
                    if self.session?.id==uuid { self.cleanup() }
                } else if let current=self.session { await self.preparePushedMedia(current) }
            }
        }
    }

    private func preparePushedMedia(_ current: VoiceCallSession) async {
        guard current.incoming,session?.id==current.id else { return }
        // Wait for the signed ephemeral offer delivered by WSS, never derive from a static peer key.
        if socket==nil && api != nil { connectSocket() }
    }

    private func activateMediaIfReady() {
        guard audioSessionActive,
              let current = session,
              current.phase == .active,
              callKey != nil, mediaStartTask == nil, !audio.isRunning else { return }
        let expected = current.callID
        let captureGeneration = UUID(); mediaGeneration = captureGeneration
        mediaStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if mediaGeneration == captureGeneration { mediaStartTask = nil } }
            // CallKit activation can precede a valid hardware route. Give the
            // audio bus a short bounded warm-up instead of hanging up instantly.
            for attempt in 0..<3 {
                guard !Task.isCancelled, mediaGeneration == captureGeneration, session?.callID == expected, session?.phase == .active, audioSessionActive else { return }
                do {
                    try audio.start { [weak self] frame in
                        Task { @MainActor in
                            guard let self, self.mediaGeneration == captureGeneration, self.session?.callID == expected, self.audioSessionActive else { return }
                            await self.sendAudio(frame)
                        }
                    }
                    audio.muted = muted
                    audio.quietSpeechBoost = quietSpeechBoost && speaker
                    try? applySelectedAudioOutput()
                    return
                } catch {
                    audio.stop()
                    if attempt == 2 {
                        lastFailure = "Не удалось включить звук звонка: \(error.localizedDescription)"
                        failCurrent(reason: .failed)
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(250 * (attempt + 1))) } catch { return }
                }
            }
        }
    }

    private func sendAudio(_ frame: Data) async {
        // Route changes rebuild the capture engine. The call's mute state
        // remains authoritative even before the new tap receives that state.
        guard !muted, let current = session,
              current.phase == .active,
              let key = callKey else { return }

        do {
            guard let callSecrets else { return }
            let frame=try callSecrets.seal(frame,key:key,callID:current.callID)
            let combined=frame.0
            try await send([
                "type": "audio",
                "to": current.peerID,
                "callID": current.callID,
                "payload": combined.base64EncodedString(),
                "sequence":frame.1,
            ])
        } catch {
            // Individual realtime frames may be dropped; the call itself stays alive.
        }
    }

    private func send(_ packet: [String: String]) async throws {
        guard let socket, socketReady else {
            throw MessengerError.invalid("Realtime relay не подключён")
        }
        let data = try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw MessengerError.invalid("Не удалось сериализовать пакет звонка")
        }
        try await socket.send(.string(string))
    }

    private func failCurrent(reason: CXCallEndedReason) {
        guard let current = session else {
            cleanup()
            return
        }
        provider.reportCall(with: current.id, endedAt: Date(), reason: reason)
        sendEndSignal(current)

        let status: String
        switch reason {
        case .unanswered:
            status = current.incoming ? "missed" : "unanswered"
        default:
            status = current.phase == .active ? "interrupted" : "failed"
        }
        finishCurrent(status: status)
    }

    private func sendEndSignal(_ current: VoiceCallSession) {
        guard let socket, socketReady, !current.peerID.isEmpty else { return }
        let packet = ["type":"end", "to":current.peerID, "callID":current.callID]
        Task {
            do {
                let data = try JSONSerialization.data(withJSONObject: packet)
                guard let text = String(data: data, encoding: .utf8) else { return }
                try await socket.send(.string(text))
            } catch { socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    private func localEndStatus(_ current: VoiceCallSession) -> String {
        if current.phase == .active { return "completed" }
        if current.incoming { return "declined" }
        return "cancelled"
    }

    private func remoteEndStatus(_ current: VoiceCallSession) -> String {
        if current.phase == .active { return "completed" }
        if current.incoming { return "missed" }
        return "unanswered"
    }

    private func finishCurrent(status: String) {
        guard let current = session else {
            cleanup()
            return
        }

        let endedAt = Date()
        let duration = current.startedAt.map {
            max(0, Int(endedAt.timeIntervalSince($0)))
        } ?? 0

        recordSink?(
            CallRecord(
                id: UUID().uuidString,
                callID: current.callID,
                peerID: current.peerID,
                peerName: current.peerName,
                incoming: current.incoming,
                startedAt: current.startedAt ?? current.createdAt,
                endedAt: endedAt,
                status: status,
                duration: duration
            )
        )

        cleanup()
    }

    private func cleanup() {
        mediaGeneration = UUID()
        mediaStartTask?.cancel(); mediaStartTask = nil
        audio.stop()
        session = nil
        peerCard = nil
        callKey = nil
        callSecrets = nil
        muted = false
        speaker = false
        audioOutput = .receiver
        quietSpeechBoost = false
        isCallScreenExpanded = true
        audioSessionActive = false
        if let pending = pendingConfiguration {
            pendingConfiguration = nil
            api = pending.0; identity = pending.1; canonicalCard = pending.2 ?? (try? pending.1.card)
            connectSocket()
        }
    }
}

private struct CallVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volume = MPVolumeView()
        volume.showsRouteButton = false
        volume.showsVolumeSlider = true
        volume.tintColor = .white
        return volume
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct CallMiniBanner: View {
    let session: VoiceCallSession
    @EnvironmentObject private var calls: CallManager

    var body: some View {
        VStack(spacing: 16) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                    calls.setCallScreenExpanded(true)
                }
            } label: {
                HStack(spacing: 12) {
                    Avatar(name: session.peerName, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.incoming && session.phase == .ringing ? "Входящий звонок" : "VO1D · Звонок")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.58))
                        Text(session.peerName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 12) {
            if session.incoming && session.phase == .ringing {
                bannerAction("phone.down.fill", fill: .white.opacity(0.13), foreground: .white, label: "Отклонить") {
                    calls.endFromApp()
                }
                bannerAction("phone.fill", fill: .white, foreground: .black, label: "Принять") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        calls.answerFromApp()
                    }
                }
            } else {
                bannerAction("arrow.up.left.and.arrow.down.right", fill: .white.opacity(0.13), foreground: .white, label: "Развернуть") {
                    withAnimation { calls.setCallScreenExpanded(true) }
                }
                bannerAction("phone.down.fill", fill: .white, foreground: .black, label: "Завершить") {
                    calls.endFromApp()
                }
            }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(Color(red: 0.065, green: 0.065, blue: 0.075))
                .overlay {
                    RoundedRectangle(cornerRadius: 25, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.32), radius: 20, y: 10)
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .accessibilityElement(children: .contain)
    }

    private func bannerAction(
        _ symbol: String,
        fill: Color,
        foreground: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct CallScreen: View {
    let session: VoiceCallSession
    @EnvironmentObject private var calls: CallManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var showSoundOptions = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        HStack(spacing: 12) {
                            Wordmark(compact: true)
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                    calls.setCallScreenExpanded(false)
                                }
                            } label: {
                                Label("Свернуть", systemImage: "chevron.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .background(.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 10)

                        ZStack {
                            ForEach(0..<3, id: \.self) { index in
                                Circle()
                                    .stroke(.white.opacity(0.10 - Double(index) * 0.018), lineWidth: 1)
                                    .frame(
                                        width: 162 + CGFloat(index) * 41,
                                        height: 162 + CGFloat(index) * 41
                                    )
                                    .scaleEffect(pulse ? 1.06 + CGFloat(index) * 0.015 : 0.96)
                                    .opacity(pulse ? 0.2 : 0.78)
                            }
                            Avatar(name: session.peerName, size: 114)
                                .shadow(color: .white.opacity(0.10), radius: 28)
                        }
                        .frame(height: 248)
                        .accessibilityHidden(true)

                        VStack(spacing: 10) {
                            Text(session.peerName)
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .multilineTextAlignment(.center)
                            Text(statusText)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .tracking(1.1)
                                .foregroundStyle(.white.opacity(0.64))
                                .multilineTextAlignment(.center)

                            if let started = session.startedAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(duration(from: started, to: context.date))
                                        .font(.system(size: 25, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .monospacedDigit()
                                }
                            }
                        }

                        Spacer(minLength: 10)

                        if session.incoming && session.phase == .ringing {
                            HStack(spacing: 18) {
                                callButton(
                                    icon: "phone.down.fill",
                                    title: "Отклонить",
                                    filled: false
                                ) { calls.endFromApp() }
                                callButton(
                                    icon: "phone.fill",
                                    title: "Принять",
                                    filled: true
                                ) { calls.answerFromApp() }
                            }
                        } else {
                            HStack(spacing: 12) {
                                callButton(
                                    icon: calls.muted ? "mic.slash.fill" : "mic.fill",
                                    title: calls.muted ? "Включить микрофон" : "Микрофон",
                                    filled: calls.muted
                                ) { calls.toggleMute() }

                                callButton(
                                    icon: calls.audioOutput == .speaker ? "speaker.wave.3.fill" : "speaker.wave.2",
                                    title: calls.audioOutput.title,
                                    filled: calls.audioOutput == .speaker
                                ) { showSoundOptions = true }

                                callButton(
                                    icon: "phone.down.fill",
                                    title: "Завершить",
                                    filled: false
                                ) { calls.endFromApp() }
                            }

                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    showSoundOptions.toggle()
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "slider.horizontal.3")
                                    Text("Звук и устройства")
                                    Image(systemName: showSoundOptions ? "chevron.up" : "chevron.down")
                                }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.white.opacity(0.07), in: Capsule())
                            }
                            .buttonStyle(.plain)

                            if showSoundOptions {
                                soundOptions
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        }

                        Text("Звонок использует интернет, а не телефонные минуты. Для связи требуется Wi-Fi или мобильный интернет.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.48))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .frame(maxWidth: 510)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var soundOptions: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("КУДА ВЫВОДИТЬ ЗВУК")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.3)
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 9) {
                routeButton(.receiver)
                routeButton(.speaker)
                if calls.bluetoothAvailable { routeButton(.bluetooth) }
            }

            HStack(spacing: 14) {
                Image(systemName: "speaker.wave.1")
                CallVolumeSlider().frame(height: 34)
                Image(systemName: "speaker.wave.3")
            }
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.76))
            .accessibilityLabel("Системная громкость")

            Toggle(isOn: Binding(
                get: { calls.quietSpeechBoost },
                set: { _ in calls.toggleQuietSpeechBoost() }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Усиление тихой речи")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Может увеличить громкость и искажения")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.48))
                }
            }
            .tint(.white)
            .disabled(calls.audioOutput != .speaker)
            .opacity(calls.audioOutput == .speaker ? 1 : 0.5)
        }
        .padding(17)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    private func routeButton(_ output: CallAudioOutput) -> some View {
        let selected = calls.audioOutput == output
        return Button {
            calls.selectAudioOutput(output)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: output.icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(output.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .foregroundStyle(selected ? .black : .white)
            .background(selected ? Color.white : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var statusText: String {
        switch session.phase {
        case .ringing: return session.incoming ? "ВХОДЯЩИЙ VO1D CALL" : "ВЫЗОВ СОБЕСЕДНИКА…"
        case .connecting: return "СОЕДИНЕНИЕ…"
        case .reconnecting: return "ВОССТАНАВЛИВАЕМ СВЯЗЬ…"
        case .active: return "ЗАЩИЩЁННЫЙ АУДИОКАНАЛ"
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func callButton(
        icon: String,
        title: String,
        filled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 72, height: 72)
                    .foregroundStyle(filled ? .black : .white)
                    .background(
                        filled ? Color.white : Color.white.opacity(0.10),
                        in: Circle()
                    )
                    .overlay {
                        Circle().strokeBorder(.white.opacity(filled ? 0 : 0.14), lineWidth: 1)
                    }
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(MotionButtonStyle())
    }
}
