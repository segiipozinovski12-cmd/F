import AVFoundation
import CallKit
import CryptoKit
import Foundation
import SwiftUI

enum VoiceCallPhase: String {
    case ringing
    case connecting
    case active
}

struct VoiceCallSession: Identifiable, Equatable {
    let id: UUID
    let callID: String
    let peerID: String
    let peerName: String
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
    private var tapInstalled = false
    var muted = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
    }

    func prepareSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
    }

    func start(onFrame: @escaping (Data) -> Void) throws {
        guard !running else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw MessengerError.invalid("Микрофон недоступен")
        }

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1920, format: format) { [weak self] buffer, _ in
                guard let self, !self.muted else { return }
                guard let data = Self.pcm16Mono16k(buffer: buffer, format: format), !data.isEmpty else { return }
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
        muted = false
    }

    func setSpeaker(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
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
            channel[index] = Float(sample) / 32767
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private static func pcm16Mono16k(buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> Data? {
        guard let source = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let ratio = max(1, Int((format.sampleRate / 16_000).rounded()))
        var data = Data()
        data.reserveCapacity((frameCount / ratio + 1) * 2)

        var index = 0
        while index < frameCount {
            let value = max(-1, min(1, source[index]))
            var sample = Int16(value * 32767).littleEndian
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
            index += ratio
        }
        return data
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
    @Published private(set) var speaker = true
    @Published private(set) var transport = "OFFLINE"

    private let provider: CXProvider
    private let bridge: CallKitBridge
    private let controller = CXCallController()
    private let audio = CallAudioEngine()
    var allowedPeer: ((String) -> Bool)?

    private var socket: URLSessionWebSocketTask?
    private var api: APIClient?
    private var identity: LocalIdentity?
    private var peerCard: ContactCard?
    private var callKey: SymmetricKey?
    private var audioSessionActive = false
    private var socketReady = false
    private var nameResolver: ((String) -> String)?
    private var recordSink: ((CallRecord) -> Void)?

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
    }

    func configure(
        api: APIClient,
        identity: LocalIdentity,
        nameResolver: @escaping (String) -> String,
        recordSink: @escaping (CallRecord) -> Void
    ) {
        self.api = api
        self.identity = identity
        self.nameResolver = nameResolver
        self.recordSink = recordSink
        connectSocket()
    }

    func disconnect() {
        if let current = session {
            provider.reportCall(with: current.id, endedAt: Date(), reason: .failed)
            finishCurrent(status: current.phase == .active ? "interrupted" : (current.incoming ? "missed" : "cancelled"))
        } else {
            cleanup()
        }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketReady = false
        transport = "OFFLINE"
        api = nil
        identity = nil
        nameResolver = nil
        recordSink = nil
    }

    func startCall(peer: ContactCard, name: String) {
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
            let key = try deriveKey(identity: identity, peer: peer, callID: uuid.uuidString)
            peerCard = peer
            callKey = key
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

            let handle = CXHandle(type: .generic, value: name)
            let action = CXStartCallAction(call: uuid, handle: handle)
            action.isVideo = false
            controller.request(CXTransaction(action: action)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.failCurrent(reason: .failed) }
            }
        } catch {
            cleanup()
        }
    }

    func answerFromApp() {
        guard let session, session.incoming else { return }
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
        speaker.toggle()
        audio.setSpeaker(speaker)
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
                try await send([
                    "type": "invite",
                    "to": current.peerID,
                    "callID": current.callID,
                ])
            } catch {
                failCurrent(reason: .failed)
            }
        }
    }

    fileprivate func performAnswer(_ action: CXAnswerCallAction) {
        guard var current = session, current.id == action.callUUID else {
            action.fail()
            return
        }

        current.phase = .active
        current.startedAt = Date()
        session = current
        action.fulfill()

        Task {
            do {
                for _ in 0..<100 {
                    if socketReady && callKey != nil { break }
                    try await Task.sleep(for:.milliseconds(100))
                }
                guard socketReady,callKey != nil else { failCurrent(reason:.failed); return }
                try await send([
                    "type": "answer",
                    "to": current.peerID,
                    "callID": current.callID,
                ])
                activateMediaIfReady()
            } catch {
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

        Task {
            try? await send([
                "type": "end",
                "to": current.peerID,
                "callID": current.callID,
            ])
            finishCurrent(status: localEndStatus(current))
        }
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
        activateMediaIfReady()
    }

    fileprivate func audioDeactivated() {
        audioSessionActive = false
        audio.stop()
    }

    private func connectSocket() {
        guard let api else { return }

        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketReady = false
        transport = "CONNECTING"

        do {
            let request = try api.callSocketRequest()
            let task = api.session.webSocketTask(with: request)
            socket = task
            task.resume()
            receiveLoop(task)
        } catch {
            transport = "OFFLINE"
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await task.receive()
                guard self.socket === task else { return }
                try await self.handle(message)
                self.receiveLoop(task)
            } catch {
                guard self.socket === task else { return }
                self.socket = nil
                self.socketReady = false
                self.transport = "OFFLINE"
                if self.session != nil {
                    self.failCurrent(reason: .failed)
                }

                try? await Task.sleep(for: .seconds(3))
                if self.api != nil && self.socket == nil {
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
            socketReady = true
            transport = "WSS"
            if let current=session, current.incoming, callKey==nil {
                await preparePushedMedia(current)
            }
            return
        }

        if type == "error" {
            let code = packet["code"] as? String ?? "call_error"
            if ["peer_offline", "peer_busy", "peer_unavailable", "unknown_peer"].contains(code) {
                failCurrent(reason: code == "peer_offline" ? .unanswered : .failed)
            }
            return
        }

        guard let peerID = packet["from"] as? String,
              let callID = packet["callID"] as? String else { return }

        if type == "invite" {
            await receiveInvite(from: peerID, callID: callID)
            return
        }

        guard let current = session,
              current.callID == callID,
              current.peerID == peerID else { return }

        switch type {
        case "answer":
            guard !current.incoming else { return }
            var updated = current
            updated.phase = .active
            updated.startedAt = Date()
            session = updated
            provider.reportOutgoingCall(with: current.id, connectedAt: Date())
            activateMediaIfReady()

        case "audio":
            guard current.phase == .active,
                  let payload = packet["payload"] as? String,
                  let encrypted = Data(base64Encoded: payload),
                  let key = callKey else { return }

            let aad = Data("VO1D-CALL-AUDIO-1\n\(callID)".utf8)
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let clear = try AES.GCM.open(box, using: key, authenticating: aad)
            audio.play(clear)

        case "end":
            provider.reportCall(with: current.id, endedAt: Date(), reason: .remoteEnded)
            finishCurrent(status: remoteEndStatus(current))

        default:
            break
        }
    }

    private func receiveInvite(from peerID: String, callID: String) async {
        if session?.callID == callID { return }
        guard allowedPeer?(peerID) != false, session == nil,
              let api,
              let identity,
              let uuid = UUID(uuidString: callID) else { return }

        do {
            let peer = try await api.card(peerID)
            try audio.prepareSession()
            peerCard = peer
            callKey = try deriveKey(identity: identity, peer: peer, callID: callID)

            let name = nameResolver?(peerID) ?? "VO1D"
            session = VoiceCallSession(
                id: uuid,
                callID: callID,
                peerID: peerID,
                peerName: name,
                incoming: true,
                createdAt: Date(),
                phase: .ringing,
                startedAt: nil
            )

            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: name)
            update.localizedCallerName = name
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false

            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                if error != nil {
                    Task { @MainActor in self?.finishCurrent(status: "failed") }
                }
            }
        } catch {
            cleanup()
        }
    }

    func reportPushedCall(peerID: String, callID: String, completion: @escaping () -> Void) {
        guard let uuid=UUID(uuidString:callID) else { completion(); return }
        if session?.id==uuid { completion(); return }
        let update=CXCallUpdate()
        update.remoteHandle=CXHandle(type:.generic,value:"VO1D")
        update.localizedCallerName="VO1D"
        update.hasVideo=false
        let rejected=session != nil || allowedPeer?(peerID)==false || peerID.count != 64
        if !rejected {
            session=VoiceCallSession(id:uuid,callID:callID,peerID:peerID,peerName:"VO1D",incoming:true,createdAt:Date(),phase:.ringing,startedAt:nil)
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
        guard let api,let identity, session?.id==current.id, allowedPeer?(current.peerID) != false else { return }
        do {
            let peer=try await api.card(current.peerID)
            guard session?.id==current.id else { return }
            try audio.prepareSession()
            peerCard=peer
            callKey=try deriveKey(identity:identity,peer:peer,callID:current.callID)
            activateMediaIfReady()
        } catch { failCurrent(reason:.failed) }
    }

    private func activateMediaIfReady() {
        guard audioSessionActive,
              let current = session,
              current.phase == .active,
              callKey != nil else { return }

        do {
            try audio.start { [weak self] frame in
                Task { @MainActor in
                    await self?.sendAudio(frame)
                }
            }
            audio.muted = muted
            audio.setSpeaker(speaker)
        } catch {
            failCurrent(reason: .failed)
        }
    }

    private func sendAudio(_ frame: Data) async {
        guard let current = session,
              current.phase == .active,
              let key = callKey else { return }

        do {
            let aad = Data("VO1D-CALL-AUDIO-1\n\(current.callID)".utf8)
            let box = try AES.GCM.seal(frame, using: key, authenticating: aad)
            guard let combined = box.combined else { return }

            try await send([
                "type": "audio",
                "to": current.peerID,
                "callID": current.callID,
                "payload": combined.base64EncodedString(),
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

    private func deriveKey(
        identity: LocalIdentity,
        peer: ContactCard,
        callID: String
    ) throws -> SymmetricKey {
        try Crypto.validate(peer)
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Crypto.decode(peer.agreementKey, count: 32)
        )
        let shared = try identity.agreementPrivate.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("VO1D-CALL-1\n\(callID)".utf8),
            sharedInfo: Data("voice".utf8),
            outputByteCount: 32
        )
    }

    private func failCurrent(reason: CXCallEndedReason) {
        guard let current = session else {
            cleanup()
            return
        }
        provider.reportCall(with: current.id, endedAt: Date(), reason: reason)

        let status: String
        switch reason {
        case .unanswered:
            status = current.incoming ? "missed" : "unanswered"
        default:
            status = current.phase == .active ? "interrupted" : "failed"
        }
        finishCurrent(status: status)
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
        audio.stop()
        session = nil
        peerCard = nil
        callKey = nil
        muted = false
        speaker = true
        audioSessionActive = false
    }
}

struct CallScreen: View {
    let session: VoiceCallSession
    @EnvironmentObject private var calls: CallManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            VoidBackground()

            VStack(spacing: 30) {
                HStack {
                    Wordmark(compact: true)
                    Spacer()
                    Text(calls.transport)
                        .font(.caption2.monospaced())
                        .tracking(1.5)
                        .foregroundStyle(Theme.secondary)
                }

                Spacer()

                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(.white.opacity(0.09 - Double(index) * 0.018), lineWidth: 1)
                            .frame(width: 150 + CGFloat(index) * 46, height: 150 + CGFloat(index) * 46)
                            .scaleEffect(pulse ? 1.08 + CGFloat(index) * 0.02 : 0.94)
                            .opacity(pulse ? 0.18 : 0.75)
                    }

                    Avatar(name: session.peerName, size: 112)
                        .shadow(color: .white.opacity(0.12), radius: 28)
                }
                .frame(height: 270)

                VStack(spacing: 8) {
                    Text(session.peerName)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.66)

                    Text(statusText)
                        .font(.caption.monospaced())
                        .tracking(1.7)
                        .foregroundStyle(Theme.secondary)

                    if let started = session.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(duration(from: started, to: context.date))
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.82))
                        }
                    }
                }

                Spacer()

                if session.incoming && session.phase == .ringing {
                    HStack(spacing: 42) {
                        callButton(icon: "phone.down.fill", title: "Отклонить", filled: false) {
                            calls.endFromApp()
                        }
                        callButton(icon: "phone.fill", title: "Ответить", filled: true) {
                            calls.answerFromApp()
                        }
                    }
                } else {
                    HStack(spacing: 24) {
                        callButton(
                            icon: calls.muted ? "mic.slash.fill" : "mic.fill",
                            title: calls.muted ? "Микрофон выкл." : "Микрофон",
                            filled: calls.muted
                        ) {
                            calls.toggleMute()
                        }

                        callButton(
                            icon: calls.speaker ? "speaker.wave.3.fill" : "speaker.fill",
                            title: "Динамик",
                            filled: calls.speaker
                        ) {
                            calls.toggleSpeaker()
                        }

                        callButton(icon: "phone.down.fill", title: "Завершить", filled: false) {
                            calls.endFromApp()
                        }
                    }
                }

                Text("Аудио шифруется между устройствами. Relay видит участников, время и объём realtime-трафика, но не получает голос в открытом виде.")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 18)
            }
            .padding(24)
            .padding(.bottom, 18)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var statusText: String {
        switch session.phase {
        case .ringing: return "ВХОДЯЩИЙ VO1D CALL"
        case .connecting: return "СОЕДИНЕНИЕ…"
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
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 58, height: 58)
                    .foregroundStyle(filled ? .black : .white)
                    .background(
                        filled ? Color.white : Color.white.opacity(0.07),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(.white.opacity(filled ? 0 : 0.14)))

                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 82)
        }
        .buttonStyle(.plain)
    }
}

