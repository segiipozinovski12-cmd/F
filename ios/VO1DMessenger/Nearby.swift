import Foundation
import MultipeerConnectivity
import SwiftUI
import CryptoKit

enum NearbyProof {
    static func challenge(_ nonce: String) -> Data { Data("VO1D-NEARBY-AUTH-1\n\(nonce)".utf8) }
    static func ack(_ id: String, sender: String, recipient: String) -> Data { Data("VO1D-NEARBY-ACK-1\n\(id)\n\(sender)\n\(recipient)".utf8) }
    static func verify(card: ContactCard, nonce: String, signature: String) throws -> Bool {
        try Crypto.validate(card)
        _ = try Crypto.decode(nonce, count: 32)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(card.signingKey, count: 32))
        return try key.isValidSignature(Crypto.decode(signature, count: 64), for: challenge(nonce))
    }
}

private final class NearbyDelegate: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    weak var owner: NearbyTransport?
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in owner?.changed(peerID, state: state, session: session) }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= 8_000_000 else { return }
        Task { @MainActor in owner?.received(data, from: peerID, session: session) }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
    }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in owner?.found(peerID) }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in owner?.peers.removeAll { $0 == peerID } }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in owner?.status = "Поиск рядом недоступен: \(error.localizedDescription)" }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard let owner, owner.pendingInvitation == nil, owner.store?.sessionUnlocked == true, owner.store?.locked == false else { invitationHandler(false, nil); return }
            owner.pendingInvitation = peerID
            owner.invitationHandler = invitationHandler
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in owner?.status = "Обнаружение недоступно: \(error.localizedDescription)" }
    }
}

@MainActor
final class NearbyTransport: ObservableObject {
    static let shared = NearbyTransport()
    @Published var enabled = false
    @Published var peers: [MCPeerID] = []
    @Published var pendingInvitation: MCPeerID?
    @Published var status = "Выключено"
    weak var store: ChatStore?
    fileprivate var invitationHandler: ((Bool, MCSession?) -> Void)?
    private let bridge = NearbyDelegate()
    private var channel: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var challenges: [MCPeerID: String] = [:]
    private var authenticated: [MCPeerID: String] = [:]
    private var frames: [MCPeerID: (Date, Int)] = [:]
    private init() { bridge.owner = self }
    func start(store: ChatStore) {
        stop()
        guard store.sessionUnlocked, !store.locked else { return }
        self.store = store
        let peer = MCPeerID(displayName: "VO1D-" + String(UUID().uuidString.prefix(6)))
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = bridge; channel = session
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "vo1d-nearby")
        advertiser?.delegate = bridge; advertiser?.startAdvertisingPeer()
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "vo1d-nearby")
        browser?.delegate = bridge; browser?.startBrowsingForPeers()
        enabled = true; status = "Твоё имя рядом: \(peer.displayName)"
    }
    func stop() {
        invitationHandler?(false, nil); invitationHandler = nil; pendingInvitation = nil
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers(); channel?.disconnect()
        advertiser = nil; browser = nil; channel = nil; store = nil
        challenges = [:]; authenticated = [:]; frames = [:]; peers = []; enabled = false; status = "Выключено"
    }
    fileprivate func found(_ peer: MCPeerID) { if !peers.contains(peer) && peers.count < 30 { peers.append(peer) } }
    func invite(_ peer: MCPeerID) {
        guard let channel, channel.connectedPeers.count < 4 else { return }
        browser?.invitePeer(peer, to: channel, withContext: nil, timeout: 20)
    }
    func answerInvitation(_ accept: Bool) {
        invitationHandler?(accept, accept ? channel : nil); invitationHandler = nil; pendingInvitation = nil
    }
    fileprivate func changed(_ peer: MCPeerID, state: MCSessionState, session: MCSession) {
        guard session === channel else { return }
        if state == .connected {
            guard let nonce = try? Crypto.random(32).base64EncodedString() else { return }
            challenges[peer] = nonce
            try? send(["kind": "challenge", "nonce": nonce], to: peer)
        } else if state == .notConnected { authenticated[peer] = nil; challenges[peer] = nil; frames[peer] = nil }
    }
    private func send(_ value: [String: String], to peer: MCPeerID) throws {
        guard let channel else { throw MessengerError.invalid("Нет локального соединения") }
        try channel.send(Wire.encoder.encode(value), toPeers: [peer], with: .reliable)
    }
    fileprivate func received(_ data: Data, from peer: MCPeerID, session: MCSession) {
        guard session === channel, let store, store.sessionUnlocked, !store.locked, let identity = store.identity else { return }
        guard authenticated[peer] != nil || data.count <= 16_384 else { return }
        let window = frames[peer] ?? (Date(), 0)
        let count = Date().timeIntervalSince(window.0) > 60 ? 0 : window.1
        guard count < 180 else { return }; frames[peer] = (count == 0 ? Date() : window.0, count + 1)
        do {
            let packet = try Wire.decoder.decode([String: String].self, from: data)
            switch packet["kind"] {
            case "challenge":
                guard let nonce = packet["nonce"], (try? Crypto.decode(nonce, count: 32)) != nil, let card = store.ownCard else { return }
                let signature = try identity.signingPrivate.signature(for: NearbyProof.challenge(nonce)).base64EncodedString()
                try send(["kind": "auth", "card": Wire.encoder.encode(card).base64EncodedString(), "signature": signature], to: peer)
            case "auth":
                guard let nonce = challenges.removeValue(forKey: peer), let encoded = packet["card"], let proof = packet["signature"] else { return }
                let card = try Wire.decoder.decode(ContactCard.self, from: Crypto.decode(encoded)); try Crypto.validate(card)
                guard store.state.contacts.contains(where: { $0.card == card && !$0.blocked && $0.verified }), store.extended.trustedIDs.contains(card.id) else { status = "Сначала добавь контакт и сверь отпечаток ключей"; return }
                guard try NearbyProof.verify(card: card, nonce: nonce, signature: proof) else { return }
                authenticated[peer] = card.id; status = "Подключён: \(store.name(card.id))"
                try flush()
            case "envelope":
                guard let id = authenticated[peer], let encoded = packet["body"], let contact = store.state.contacts.first(where: { $0.id == id && !$0.blocked && $0.verified }) else { return }
                let envelope = try Wire.decoder.decode(Envelope.self, from: Crypto.decode(encoded))
                guard envelope.sender == id, envelope.recipient == store.myID, envelope.deferredEvent == nil, envelope.opaque == nil, envelope.expiresAt > Int(Date().timeIntervalSince1970) else { return }
                if !store.state.processed.contains(envelope.id) {
                    // Roll back ratchet advancement if durable storage fails.
                    let previous = store.state
                    do {
                        let event = try store.openSignalEvent(envelope, identity: identity, sender: contact.card)
                        try store.apply(event, sender: contact.card)
                        store.state.processed.append(envelope.id); try store.save()
                    } catch { store.state = previous; throw error }
                }
                let proof = try identity.signingPrivate.signature(for: NearbyProof.ack(envelope.id, sender: id, recipient: store.myID)).base64EncodedString()
                try send(["kind": "ack", "id": envelope.id, "signature": proof], to: peer)
            case "ack":
                guard let id = authenticated[peer], let envelopeID = packet["id"], let signature = packet["signature"],
                      let contact = store.state.contacts.first(where: { $0.id == id && !$0.blocked }),
                      let pending = store.state.outbox.first(where: { $0.envelope.id == envelopeID && $0.envelope.recipient == id }) else { return }
                let key = try Curve25519.Signing.PublicKey(rawRepresentation: Crypto.decode(contact.card.signingKey, count: 32))
                guard try key.isValidSignature(Crypto.decode(signature, count: 64), for: NearbyProof.ack(envelopeID, sender: store.myID, recipient: id)) else { return }
                let previous = store.state
                store.state.outbox.removeAll { $0.id == pending.id }
                if let messageID = pending.messageID, !store.state.outbox.contains(where: { $0.messageID == messageID }), let index = store.state.messages.firstIndex(where: { $0.id == messageID }) { store.state.messages[index].state = "delivered" }
                do { try store.save() } catch { store.state = previous; throw error }
            default: break
            }
        } catch { status = "Локальная доставка: \(error.localizedDescription)" }
    }
    func flush() throws {
        guard let store, let identity = store.identity, store.sessionUnlocked, !store.locked else { return }
        var sent = 0
        for pending in store.state.outbox {
            guard sent < 12 else { break }
            guard pending.envelope.expiresAt > Int(Date().timeIntervalSince1970),
                  (pending.notBefore ?? .distantPast) <= Date(),
                  store.deliveryIssues[pending.id]?.nextAttempt != .distantFuture else { continue }
            guard let peer = authenticated.first(where: { $0.value == pending.envelope.recipient })?.key,
                  let target = store.state.contacts.first(where: { $0.id == pending.envelope.recipient && !$0.blocked && $0.verified }),
                  pending.envelope.opaque == nil else { continue }
            var envelope = pending.envelope
            if let deferred = envelope.deferredEvent {
                guard let current = store.extended.signal else { continue }
                let event = try Wire.decoder.decode(ChatEvent.self, from: deferred)
                // Offline bootstrap is deliberately disallowed: first exchange
                // Signal keys online/private QR. No weaker fallback is created.
                guard let result = try? SignalProtocol.encrypt(Wire.encoder.encode(event), to: target.card, identity: identity, state: current, bundle: nil) else { continue }
                envelope = try Crypto.sealPayload(result.1, from: identity, to: target.card, expiry: event.contentExpiry, id: envelope.id)
                // A locally addressed envelope must never accidentally leave
                // through the account relay on the next synchronization pass.
                envelope.nearbyOnly = true
                let previous = store.state
                var local = store.extended; local.signal = result.0; store.state.extended = local
                guard let index = store.state.outbox.firstIndex(where: { $0.id == pending.id }) else { continue }
                store.state.outbox[index].envelope = envelope
                do { try store.save() } catch { store.state = previous; throw error }
            }
            try send(["kind": "envelope", "body": Wire.encoder.encode(envelope).base64EncodedString()], to: peer)
            sent += 1
        }
    }
}
struct NearbyView: View {
    @EnvironmentObject var store: ChatStore
    @ObservedObject private var nearby = NearbyTransport.shared
    var body: some View {
        Form {
            Section("Связь рядом") {
                Toggle("Включить до выхода из приложения", isOn: Binding(get: { nearby.enabled }, set: { if $0 { nearby.start(store: store) } else { nearby.stop() } }))
                Text(nearby.status).font(.caption)
                Text("Оба приложения должны быть открыты. Работает между устройствами поблизости по Wi-Fi/Bluetooth без интернета. Сначала обменяйтесь сообщениями и сверьте отпечатки. После подтверждения соединения соседнее устройство получает твой публичный ключ. Глобальная анонимность в локальной сети не обеспечивается.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Устройства") {
                ForEach(nearby.peers, id: \.self) { peer in Button(peer.displayName) { nearby.invite(peer) } }
                Button("Отправить очередь рядом") { do { try nearby.flush() } catch { store.error = error.localizedDescription } }.disabled(!nearby.enabled)
                Text("Файлы, уже загруженные на relay, требуют интернета для скачивания.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Без интернета")
        .confirmationDialog("Подключить устройство рядом?", isPresented: Binding(get: { nearby.pendingInvitation != nil }, set: { if !$0 { nearby.answerInvitation(false) } }), titleVisibility: .visible) {
            Button("Подключить") { nearby.answerInvitation(true) }
            Button("Отклонить", role: .cancel) { nearby.answerInvitation(false) }
        } message: { Text(nearby.pendingInvitation?.displayName ?? "VO1D") }
    }
}
