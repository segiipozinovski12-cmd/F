import SwiftUI
import Foundation

extension ChatStore {
    var activeNetworkRoute: String {
        guard let client = api else { return "Нет активного соединения" }
        if client.privacy.embeddedTor { return EmbeddedTorManager.shared.ready ? "Tor · встроенный SOCKS · без обхода" : "Tor подключается · отправка закрыта" }
        if client.privacy.proxyEnabled { return client.privacy.proxyUsesTor ? "Внешний Tor · SOCKS не проверен" : "SOCKS5 · без обхода" }
        return "Прямой HTTPS"
    }
}
struct PrivacyDiagnosticsView: View {
    @EnvironmentObject var store: ChatStore
    @State private var integrity = "Ещё не проверено"
    @State private var transientCount = 0
    @State private var deletingFiles = false
    @State private var rotatingMailboxes = false
    var body: some View {
        List {
            Section("Текущее соединение") {
                Label(store.activeNetworkRoute,systemImage:"network")
                Text(store.connection).font(.caption).foregroundStyle(.secondary)
                if let host = store.api?.base.host { Text("Relay: \(host)").font(.caption.monospaced()) }
                NavigationLink("Изменить маршрут") { NetworkRouteView() }
                Text("Этот экран показывает конфигурацию активного клиента. Он не доказывает отсутствие DNS-утечек или корреляции трафика.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Ключи и личность") {
                Text(store.activeProfile?.label ?? "Основная личность")
                Text("Сессии v2: \(store.extended.signal?.sessions.count ?? 0)")
                Text("Одноразовые ключи: \(store.extended.signal?.prekeys.count ?? 0)")
                Text("Приватные адреса: \(store.extended.ownMailboxes.count)")
                let mailboxHealth = store.privateMailboxHealth
                Text("Активные: \(mailboxHealth.active) · скоро истекут: \(mailboxHealth.expiring) · истекли: \(mailboxHealth.expired)")
                    .font(.caption)
                    .foregroundStyle(mailboxHealth.expiring + mailboxHealth.expired > 0 ? .orange : .secondary)
                Button(rotatingMailboxes ? "Подготавливаем адреса…" : "Подготовить новые приватные адреса") {
                    rotatingMailboxes = true
                    Task {
                        do { try await store.rotatePrivateMailboxes() }
                        catch { store.error = error.localizedDescription }
                        rotatingMailboxes = false
                    }
                }
                .disabled(rotatingMailboxes || store.api == nil)
                Text("Старые адреса остаются принимающими до истечения. Новый адрес передаётся собеседнику внутри следующего E2EE-события — без публичной привязки аккаунта.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(integrity).font(.caption)
                Button("Проверить подписи и локальные записи") { do { integrity = try store.integrityReport() } catch { integrity = error.localizedDescription } }
            }
            Section("Временные данные") {
                Text("Расшифрованных временных файлов: \(transientCount)")
                Button("Очистить временные файлы") { MediaFiles.clear(); ResumableDownload.clear(); refresh() }
                Text("На старте и при уходе в фон временные расшифрованные файлы удаляются. Очистка не гарантирует стирание копий в памяти iOS или на уровне флеш-накопителя.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Файлы на relay") {
                Text("Созданных приватных файлов: \(store.extended.privateBlobDeletes.count)")
                Button("Отозвать доступ и удалить мои приватные файлы",role:.destructive) { deletingFiles = true }
                Text("Удаление требует соединения. Уже скачанные копии останутся у получателей.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Восстановление") {
                NavigationLink("Зашифрованная резервная копия") { BackupCenterView() }
                NavigationLink("Архивы истории") { HistoryArchivesView() }
                Text("Копия личности переносит долгосрочные ключи. Копия истории открывается архивом. Старые ключи ratchet и готовая очередь из копии не восстанавливаются.").font(.caption).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background(.black).navigationTitle("Диагностика")
        .onAppear { refresh() }
        .confirmationDialog("Удалить приватные файлы с relay?",isPresented:$deletingFiles,titleVisibility:.visible) {
            Button("Удалить файлы",role:.destructive) { Task { do { try await store.revokePrivateFiles() } catch { store.error = error.localizedDescription } } }
        }
    }
    private func refresh() {
        let roots = [MediaFiles.directory,MediaFiles.transientDirectory]
        transientCount = roots.reduce(0) { total,path in total + ((try? FileManager.default.contentsOfDirectory(at:path,includingPropertiesForKeys:nil).count) ?? 0) }
    }
}
