import Foundation
import CryptoKit
import CommonCrypto
import Security
import SwiftUI
import UniformTypeIdentifiers

struct BackupPayload: Codable {
    var version = 1
    var identity: LocalIdentity
    var state: VaultState
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
        let clear=try Wire.encoder.encode(payload)
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
        guard payload.version==1, payload.identity.storage.count==32 else { throw MessengerError.invalid("Повреждённая копия") }
        try Crypto.validate(payload.identity.card)
        for contact in payload.state.contacts where contact.id != ChatStore.builtinBotID { try Crypto.validate(contact.card) }
        return payload
    }
}

extension Keychain {
    static func replace(_ identity: LocalIdentity) throws {
        try Crypto.validate(identity.card)
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service,kSecAttrAccount as String:"identity"]
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
    var body: some View {
        Form {
            Section("Зашифрованная копия") {
                SecureField("Пароль от 12 символов",text:$password)
                Text("Копия содержит приватные ключи и историю. Пароль не отправляется на сервер. Потерянный пароль восстановить нельзя.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Создать копию") {
                    guard let identity=store.identity else { return }
                    busy=true
                    let payload=BackupPayload(identity:identity,state:store.state), secret=password
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
        .confirmationDialog("Заменить локальный аккаунт копией?",isPresented:$confirmRestore,titleVisibility:.visible) {
            Button("Восстановить и заменить",role:.destructive) {
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
        guard let oldIdentity=identity else { throw MessengerError.invalid("Нет текущих ключей") }
        let oldState=state
        CallManager.shared.disconnect()
        do {
            try Keychain.replace(payload.identity)
            try vault?.write(payload.state,key:payload.identity.storage)
            identity=payload.identity; ownCard=try payload.identity.card; state=payload.state
            api=nil; locked=state.appLock; sessionUnlocked=false; revealedHiddenRooms=false
            deliveryIssues=[:]
        } catch {
            try? Keychain.replace(oldIdentity)
            try? vault?.write(oldState,key:oldIdentity.storage)
            throw error
        }
    }
}
