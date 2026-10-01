import Foundation
import CryptoKit
import CommonCrypto
import Security
import SwiftUI
import UniformTypeIdentifiers

struct BackupPayload: Codable {
    var version = 2
    var identity: LocalIdentity?
    var state: VaultState
    var mode: BackupMode? = nil
    var ownerCard: ContactCard? = nil
}
enum BackupMode: String, Codable, CaseIterable, Identifiable {
    case identity, history, full
    var id: String { rawValue }
    var title: String {
        switch self { case .identity: return "Только личность"; case .history: return "Только история"; case .full: return "Личность и история" }
    }
}

struct BackupEnvelope: Codable {
    var format = "VO1D-BACKUP-1"
    var rounds = 600_000
    var salt: Data
    var ciphertext: Data
}

enum SecureBackup {
    static func key(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        guard password.count >= 12, password.utf8.count <= 1024, salt.count == 16, rounds == 600_000 else {
            throw MessengerError.invalid("Нужен пароль от 12 символов и поддерживаемый формат")
        }
        let pass = Array(password.utf8)
        var output = [UInt8](repeating:0,count:32)
        let status = pass.withUnsafeBytes { bytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    bytes.bindMemory(to:Int8.self).baseAddress,pass.count,
                    saltBytes.bindMemory(to:UInt8.self).baseAddress,salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),UInt32(rounds),&output,32)
            }
        }
        guard status == kCCSuccess else { throw MessengerError.invalid("Не удалось получить ключ копии") }
        defer { for i in output.indices { output[i]=0 } }
        return SymmetricKey(data:output)
    }

    static func export(_ payload: BackupPayload, password: String) throws -> Data {
        let salt=try Crypto.random(16)
        let key=try key(password:password,salt:salt,rounds:600_000)
        let clear=try Wire.encoder.encode(sanitized(payload))
        guard clear.count <= 100*1024*1024 else { throw MessengerError.invalid("Копия больше 100 МБ. Очисти ненужные вложения.") }
        let box=try AES.GCM.seal(clear,using:key,authenticating:Data("VO1D-BACKUP-1".utf8))
        guard let combined=box.combined else { throw MessengerError.invalid("Ошибка резервной копии") }
        return try Wire.encoder.encode(BackupEnvelope(salt:salt,ciphertext:combined))
    }

    static func open(_ data: Data, password: String) throws -> BackupPayload {
        guard data.count <= 140*1024*1024 else { throw MessengerError.invalid("Файл копии слишком большой") }
        let envelope=try Wire.decoder.decode(BackupEnvelope.self,from:data)
        guard envelope.format=="VO1D-BACKUP-1" else { throw MessengerError.invalid("Неизвестный формат") }
        let key=try key(password:password,salt:envelope.salt,rounds:envelope.rounds)
        let clear=try AES.GCM.open(AES.GCM.SealedBox(combined:envelope.ciphertext),using:key,
            authenticating:Data("VO1D-BACKUP-1".utf8))
        let payload=try Wire.decoder.decode(BackupPayload.self,from:clear)
        guard [1,2].contains(payload.version) else { throw MessengerError.invalid("Повреждённая копия") }
        if let identity = payload.identity {
            guard identity.storage.count == 32 else { throw MessengerError.invalid("Повреждённые ключи копии") }
            try Crypto.validate(identity.card)
        } else if payload.mode != .history { throw MessengerError.invalid("В копии личности нет ключей") }
        if let owner = payload.ownerCard {
            try Crypto.validate(owner)
            if let identity = payload.identity {
                guard owner.hasSameKeys(as: try identity.card) else { throw MessengerError.invalid("Личность и владелец копии не совпадают") }
            }
        }
        guard payload.state.rooms.count <= 10_000, payload.state.messages.count <= 1_000_000, Set(payload.state.rooms.map(\.id)).count == payload.state.rooms.count else { throw MessengerError.invalid("Повреждённый состав копии") }
        for member in payload.state.rooms.flatMap(\.members) where member.id != ChatStore.builtinBotID { try Crypto.validate(member) }
        for contact in payload.state.contacts where contact.id != ChatStore.builtinBotID { try Crypto.validate(contact.card) }
        return try sanitized(payload)
    }
    static func sanitized(_ input: BackupPayload) throws -> BackupPayload {
        var payload = input
        payload.ownerCard = try input.ownerCard ?? input.identity?.card
        let mode = input.mode ?? .full
        payload.mode = mode
        var local = payload.state.extended ?? ExtendedState()
        if var signal = local.signal {
            signal.sessions = [:]; signal.prekeys = [:]; signal.prekeyExpirations = [:]
            signal.signedKeys = [:]; signal.kyberKeys = [:]; signal.senderKeys = [:]
            signal.pendingPublication = nil; signal.publishedAt = nil
            let random = try Crypto.random(4)
            signal.nextKey = ((UInt32(random[0]) << 24 | UInt32(random[1]) << 16 | UInt32(random[2]) << 8 | UInt32(random[3])) & 0x7fffffff) + 1
            local.signal = mode == .history ? nil : signal
        }
        local.revokedDevices = [:]; local.deviceLinks = []; local.issuedGroupInvites = [:]; local.pendingGroupInvites = []; local.acceptedGroupInvites = [:]
        local.privateBlobDeletes = [:]; local.ownMailboxes = []; local.privateInvite = nil; local.privateInviteLink = nil
        local.invitationBundles = [:]; local.pendingEvents = []; local.reminders = []
        local.privacy.streamIsolation = ""
        payload.state.outbox = []; payload.state.processed = []
        payload.state.extended = local
        if mode == .history {
            payload.identity = nil
            payload.state.accessKey = nil; payload.state.panicCodeHash = nil
            payload.state.publicCode = nil; payload.state.username = nil
            local.peerMailboxes = [:]; local.trustedIDs = []; local.signal = nil; local.archives = []
            payload.state.extended = local
        } else if mode == .identity {
            var state = VaultState()
            state.nickname = input.state.nickname; state.server = input.state.server
            var identityState = ExtendedState(); identityState.signal = local.signal; identityState.privacy = local.privacy
            state.extended = identityState; payload.state = state
        }
        for i in payload.state.messages.indices where payload.state.messages[i].state == "queued" {
            payload.state.messages[i].state = "failed"
        }
        return payload
    }
}

extension Keychain {
    static func replace(_ identity: LocalIdentity, profileID: String = "default") throws {
        try Crypto.validate(identity.card)
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecAttrAccount as String:account(profileID)]
        let data=try Wire.encoder.encode(identity)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var insert=query
            insert[kSecValueData as String]=data
            insert[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary,nil)==errSecSuccess else { throw MessengerError.invalid("Не удалось восстановить Keychain") }
        } else if status != errSecSuccess { throw MessengerError.invalid("Не удалось обновить Keychain") }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data=data }
    init(configuration: ReadConfiguration) throws { data=configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct BackupCenterView: View {
    @EnvironmentObject var store: ChatStore
    @State private var password = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmRestore = false
    @State private var pendingURL: URL?
    @State private var document = BackupDocument(data:Data())
    @State private var busy = false
    @State private var status = ""
    @State private var mode = BackupMode.full
    var body: some View {
        Form {
            Section("Зашифрованная копия") {
                Picker("Состав",selection:$mode) { ForEach(BackupMode.allCases) { mode in Text(mode.title).tag(mode) } }
                SecureField("Пароль от 12 символов",text:$password)
                Text("История сохраняется без ключей личности. Полная копия включает долгосрочные ключи, но исключает текущие сессии и одноразовые ключи сообщений. Пароль не отправляется на сервер.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Создать копию") {
                    guard let identity=store.identity else { return }
                    busy=true
                    let payload=BackupPayload(identity:identity,state:store.state,mode:mode), secret=password
                    Task {
                        do { document=BackupDocument(data:try await Task.detached { try SecureBackup.export(payload,password:secret) }.value); exporting=true }
                        catch { status=error.localizedDescription }
                        busy=false
                    }
                }.disabled(busy || password.count<12)
                Button("Восстановить из копии") { importing=true }.disabled(busy || password.count<12)
                Text("Восстановление заменяет текущую локальную личность. Копия на старом устройстве не исчезнет: после переноса удали её самостоятельно.")
                    .font(.caption).foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).font(.caption) }
            }
        }.navigationTitle("Резервная копия")
        .fileExporter(isPresented:$exporting,document:document,contentType:.data,defaultFilename:"VO1D-backup.vo1d") { result in
            if case .failure(let error)=result { status=error.localizedDescription }
            password=""
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data]) { result in
            do { pendingURL=try result.get(); confirmRestore=true } catch { status=error.localizedDescription }
        }
        .confirmationDialog("Импортировать копию? Копия личности заменит текущие ключи.",isPresented:$confirmRestore,titleVisibility:.visible) {
            Button("Импортировать",role:.destructive) {
                guard let url=pendingURL else { return }
                busy=true
                let secret=password
                Task {
                    let access=url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() }; busy=false; password="" }
                    do {
                        let bytes=try Data(contentsOf:url)
                        let payload=try await Task.detached { try SecureBackup.open(bytes,password:secret) }.value
                        try store.restoreBackup(payload)
                        await store.connectProductionRelay()
                        status="Копия восстановлена"
                    } catch { status=error.localizedDescription }
                }
            }
        }
    }
}

extension ChatStore {
    func restoreBackup(_ payload: BackupPayload) throws {
        if payload.mode == .history {
            var local = extended
            local.archives.append(HistoryArchive(title:payload.state.nickname,rooms:payload.state.rooms,messages:payload.state.messages,contacts:payload.state.contacts,ownerCard:payload.ownerCard))
            state.extended = local; try save(); return
        }
        guard let restoredIdentity = payload.identity else { throw MessengerError.invalid("Нет ключей для восстановления личности") }
        guard let oldIdentity=identity else { throw MessengerError.invalid("Нет текущих ключей") }
        let oldState=state
        generation += 1
        CallManager.shared.disconnect()
        BackgroundCalls.clear(); MediaFiles.clear(); api?.invalidate()
        do {
            try Keychain.replace(restoredIdentity, profileID: profileID)
            try vault?.write(payload.state,key:restoredIdentity.storage)
            identity=restoredIdentity; ownCard=try restoredIdentity.card; state=payload.state
            api=nil; locked=state.appLock; sessionUnlocked=false; revealedHiddenRooms=false
            deliveryIssues=[:]
        } catch {
            try? Keychain.replace(oldIdentity, profileID: profileID)
            try? vault?.write(oldState,key:oldIdentity.storage)
            throw error
        }
    }
}
