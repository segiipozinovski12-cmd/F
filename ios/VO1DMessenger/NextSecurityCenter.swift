import SwiftUI

struct SecurityFinding: Identifiable {
    var id: String
    var title: String
    var detail: String
    var needsAttention: Bool
}

extension ChatStore {
    var securityFindings: [SecurityFinding] {
        let unverified = state.contacts.filter { !$0.blocked && !isBuiltinBot($0.id) && !$0.verified }.count
        return [
            SecurityFinding(id: "lock", title: "Device Guard", detail: state.appLock ? "Блокировка включена" : "Включи защиту входа в приложение", needsAttention: !state.appLock),
            SecurityFinding(id: "requests", title: "Запросы от незнакомцев", detail: preferences.requireRequests ? "Сначала требуется согласие" : "Новые контакты могут начать переписку сразу", needsAttention: !preferences.requireRequests),
            SecurityFinding(id: "fingerprints", title: "Проверка ключей", detail: "Несверенных контактов: \(unverified)", needsAttention: unverified > 0),
            SecurityFinding(id: "route", title: "Маршрут", detail: activeNetworkRoute, needsAttention: api == nil),
            SecurityFinding(id: "links", title: "Ссылки", detail: preferences.confirmLinks ? "Выход в браузер подтверждается" : "Добавь подтверждение перед открытием сайтов", needsAttention: !preferences.confirmLinks),
            SecurityFinding(id: "recording", title: "Запись экрана", detail: preferences.protectRecording ? "Включена защитная шторка" : "Содержимое может попадать в запись", needsAttention: !preferences.protectRecording),
            SecurityFinding(id: "queue", title: "Smart Queue", detail: "Сообщений: \(state.outbox.count); жалоб: \((state.pendingReports ?? []).count)", needsAttention: deliveryIssues.values.contains { $0.nextAttempt == .distantFuture })
        ]
    }
}

struct NextSecurityCenterView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var integrity = ""
    @State private var failure: String?
    var body: some View {
        List {
            Section("Security Check · только на устройстве") {
                ForEach(store.securityFindings) { finding in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(finding.title, systemImage: finding.needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                        Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                Button("Проверить ключи и целостность") {
                    do { try store.identity?.validate(); integrity = try store.integrityReport() }
                    catch { integrity = error.localizedDescription }
                }
                if !integrity.isEmpty { Text(integrity).font(.caption) }
                Text("Эта локальная проверка не заменяет независимый аудит, проверку сети или защиту скомпрометированного устройства.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Device Guard") {
                Toggle("Защита входа", isOn: Binding(get: { store.state.appLock }, set: { enabled in Task { await store.setLock(enabled) } }))
                Toggle("Шторка при записи экрана", isOn: store.preferenceBinding(\.protectRecording))
                Toggle("Подтверждение ссылок", isOn: store.preferenceBinding(\.confirmLinks))
                Toggle("Запросы от незнакомцев", isOn: store.preferenceBinding(\.requireRequests))
            }
            Section("Trust Circle") {
                Text("В круг попадают только выбранные контакты. Проверка отпечатка и доверие — отдельные действия. Состав не публикуется другим пользователям; список согласия на звонки синхронизируется с relay.").font(.caption)
                ForEach(store.state.contacts.filter { !store.isBuiltinBot($0.id) && !$0.blocked }) { contact in
                    Toggle(isOn: Binding(get: { store.extended.trustedIDs.contains(contact.id) }, set: { value in
                        store.changeExtended { local in
                            local.trustedIDs.removeAll { $0 == contact.id }
                            if value { local.trustedIDs.append(contact.id) }
                        }
                        Task { do { try await store.trustOnServer(contact.id, trusted: value); try await store.applyPrivacy() } catch { failure = error.localizedDescription } }
                    })) {
                        VStack(alignment: .leading) {
                            Text(contact.name)
                            Text(contact.verified ? "Отпечаток сверен" : "Отпечаток не сверен").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Данные и восстановление") {
                NavigationLink("Private Spaces") { PrivateSpacesView() }
                NavigationLink("Secure Notes") { SecureNotesView() }
                NavigationLink("Зашифрованная копия") { BackupCenterView() }
                NavigationLink("Очередь сообщений") { MessageLibraryView(mode: "outbox") }
                NavigationLink("Жалобы") { ReportCenterView() }
                NavigationLink("Диагностика") { PrivacyDiagnosticsView() }
            }
            if let failure { Text(failure).font(.caption) }
        }.navigationTitle("Безопасность")
    }
}
