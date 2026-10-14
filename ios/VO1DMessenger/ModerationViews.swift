import SwiftUI

struct ReportComposerView: View {
    var target: ReportTarget
    var appealFor: String? = nil
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ReportReason.spam
    @State private var comment = ""
    @State private var selected = Set<String>()
    @State private var attachments = Set<String>()
    @State private var consent = false
    @State private var config: ReportConfig?
    @State private var failure: String?
    @State private var loading = true

    private var messages: [ChatMessage] {
        Array(store.reportCandidates(target: target).suffix(50))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(appealFor == nil ? "Жалоба → @vo1d" : "Апелляция → @vo1d") {
                    Text("Передаются причина, ID и только выбранные ниже доказательства. Остальная переписка остаётся недоступной модерации.")
                        .font(.callout)
                    if let card = config?.card {
                        Text("Отпечаток администратора").font(.caption)
                        Text(card.id).font(.caption.monospaced()).textSelection(.enabled)
                        Text("При первом обращении сверь отпечаток по доверенному каналу. Relay видит ID, время, причину и размер жалобы.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if loading { ProgressView("Проверяем адрес администратора") }
                }
                Section("Причина") {
                    Picker("Причина жалобы", selection: $reason) {
                        ForEach(ReportReason.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Комментарий, необязательно", text: $comment, axis: .vertical)
                        .lineLimit(3...8)
                    Text("\(comment.count)/4000").font(.caption).foregroundStyle(.secondary)
                }
                if !messages.isEmpty && appealFor == nil {
                    Section("Выбери доказательства · до 10 сообщений") {
                        ForEach(messages) { message in evidenceRow(message) }
                        Text("Отправится текст отмеченных сообщений. Файлы включаются отдельным переключателем. Автоматической загрузки удалённых файлов нет.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Явное согласие") {
                    Toggle("Разрешаю передать @vo1d выбранное содержимое и комментарий", isOn: $consent)
                    Text("Доказательства шифруются на устройстве. Срок хранения на relay — до 7 дней. Администратор сможет прочитать и сохранить выбранное содержимое.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let failure { Text(failure).font(.callout).accessibilityLabel("Ошибка: \(failure)") }
                    Button("Зашифровать и отправить", systemImage: "lock.doc") {
                        do {
                            guard let config else { return }
                            try store.queueReport(target: target, reason: reason, comment: comment, selected: selected, attachments: attachments, config: config, consent: consent, appealFor: appealFor)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                    .disabled(!consent || config?.card == nil || comment.count > 4000 || selected.count > 10 || store.locked)
                }
            }
            .navigationTitle(appealFor == nil ? "Сообщить о нарушении" : "Подать апелляцию")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task {
                let current = store.generation
                do {
                    guard let api = store.api else { throw MessengerError.invalid("Подключись к relay") }
                    let result = try await api.reportConfig()
                    guard current == store.generation, !store.locked else { return }
                    config = result
                    if result.card == nil { failure = "Администратор ещё не зарегистрировал @vo1d на этом relay" }
                    if let id = target.messageID, messages.contains(where: { $0.id == id }) { selected.insert(id) }
                } catch { failure = error.localizedDescription }
                loading = false
            }
            .onChange(of: store.generation) { _, _ in dismiss() }
            .onChange(of: store.locked) { _, value in if value { dismiss() } }
        }.preferredColorScheme(.dark)
    }
    private func evidenceRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { selected.contains(message.id) }, set: { value in
                if value { selected.insert(message.id) }
                else { selected.remove(message.id); attachments.remove(message.id) }
            })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text.isEmpty ? "Сообщение с вложением" : message.text).lineLimit(4)
                    Text(message.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
            }
            if selected.contains(message.id), let item = message.attachment, item.blobID == nil, item.data.count <= 65536 {
                Toggle("Также передать файл \(item.name)", isOn: Binding(get: { attachments.contains(message.id) }, set: { value in
                    if value { attachments.insert(message.id) } else { attachments.remove(message.id) }
                })).font(.caption)
            }
        }
    }
}

struct ReportCenterView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var notices: [ModerationNotice] = []
    @State private var failure: String?
    @State private var appeal: ModerationNotice?
    var body: some View {
        List {
            Section("Адрес рассмотрения") {
                Label("@vo1d", systemImage: "checkmark.shield")
                Text("Жалобу можно открыть из профиля, меню чата или меню сообщения. Решения принимаются вручную; число жалоб само по себе не вызывает бан.").font(.caption)
                NavigationLink("Панель модерации") { ModerationDashboardView() }
            }
            Section("Очередь на этом устройстве") {
                ForEach(store.state.pendingReports ?? []) { pending in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pending.stopped ? "Требуется действие" : "Ожидает отправки").font(.headline)
                        Text(pending.failure ?? "Шифротекст сохранён; отправка продолжится при подключении").font(.caption)
                        HStack {
                            Button("Повторить") {
                                guard let i = store.state.pendingReports?.firstIndex(where: { $0.id == pending.id }) else { return }
                                store.state.pendingReports?[i].stopped = false
                                store.state.pendingReports?[i].nextAttempt = Date()
                                store.persist(); Task { await store.sync() }
                            }
                            Button("Отменить", role: .destructive) {
                                store.state.pendingReports?.removeAll { $0.id == pending.id }; store.persist()
                            }
                        }
                    }
                }
                if (store.state.pendingReports ?? []).isEmpty { Text("Очередь пуста").foregroundStyle(.secondary) }
            }
            Section("Отправленные жалобы") {
                ForEach((store.state.submittedReports ?? []).reversed()) { receipt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ReportReason(rawValue: receipt.reason)?.label ?? "Апелляция")
                        Text("\(receipt.status) · \(String(receipt.id.prefix(8)))").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Решения по моему аккаунту") {
                ForEach(notices) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(notice.action == "ban" ? "Блокировка отправки" : notice.action == "restrict" ? "Отправка ограничена" : "Предупреждение")
                        Text("До \(Date(timeIntervalSince1970: Double(notice.expires)).formatted())").font(.caption)
                        Button("Подать апелляцию") { appeal = notice }
                    }
                }
            }
            if let failure { Text(failure).font(.caption) }
        }
        .navigationTitle("Жалобы и решения")
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: store.generation) { _, _ in notices = []; appeal = nil; failure = nil; Task { await refresh() } }
        .sheet(item: $appeal) { item in
            ReportComposerView(target: ReportTarget(subject: store.myID, source: "appeal"), appealFor: item.id)
        }
    }
    private func refresh() async {
        let current = store.generation
        do {
            guard let api = store.api else { return }
            let receipts = try await api.myReports(), nextNotices = try await api.moderationNotices()
            guard current == store.generation, !store.locked else { return }
            stateReceipts(receipts); notices = nextNotices; failure = nil
        } catch { failure = error.localizedDescription }
    }
    private func stateReceipts(_ receipts: [ReportReceipt]) {
        store.state.submittedReports = receipts; store.persist()
    }
}

struct ModerationDashboardView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var access: ModerationAccess?
    @State private var token: String?
    @State private var expiresAt = 0
    @State private var secret = ""
    @State private var code = ""
    @State private var queue: [ModerationCase] = []
    @State private var queueCursor: String?
    @State private var appealCursor: String?
    @State private var statusFilter = "active"
    @State private var reasonFilter = ""
    @State private var assignmentFilter = "all"
    @State private var search = ""
    @State private var appeals: [ModerationAppeal] = []
    @State private var events: [ModerationAudit] = []
    @State private var selected: ModerationCase?
    @State private var appealContent: ReportContent?
    @State private var selectedAppeal: ModerationAppeal?
    @State private var appealOutcome = "upheld"
    @State private var confirmAppeal = false
    @State private var selfReview = false
    @State private var roleIdentity = ""
    @State private var assignedRole = "reviewer"
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        List {
            Section("Доступ") {
                Text("Роль: \(access?.role ?? "пользователь")")
                Text("@vo1d закреплён за первой зарегистрировавшей его личностью. MFA сессия действует 15 минут и закрывается при уходе в фон.").font(.caption)
                if access?.role != nil && token == nil { authentication }
                if token != nil {
                    Button("Закрыть доступ") {
                        if let api = store.api, let token { Task { try? await api.logoutModerator(token: token) } }
                        clear()
                    }
                }
            }
            if token != nil {
                Section("Фильтры очереди") {
                    Picker("Статус", selection: $statusFilter) {
                        Text("Активные").tag("active"); Text("Все").tag("all")
                        Text("Новые").tag("open"); Text("На рассмотрении").tag("reviewing")
                        Text("Решённые").tag("resolved"); Text("Отклонённые").tag("dismissed")
                    }
                    Picker("Причина", selection: $reasonFilter) {
                        Text("Все причины").tag("")
                        ForEach(ReportReason.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Ответственный", selection: $assignmentFilter) {
                        Text("Все").tag("all"); Text("Мои дела").tag("mine"); Text("Не назначены").tag("unassigned")
                    }
                    TextField("Начало ID дела или пользователя · от 8 символов", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Применить фильтры") { run { _ in await refresh() } }
                }
                Section("Очередь · \(queue.count) загружено") {
                    ForEach(queue) { item in
                        Button { selected = item } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ReportReason(rawValue: item.reason)?.label ?? item.reason)
                                Text("\(item.status) · \(String(item.subject.prefix(12)))").font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let assignee = item.assignee { Text("Ответственный: \(assignee == store.myID ? "ты" : String(assignee.prefix(12)))").font(.caption) }
                            }
                        }
                    }
                    if queue.isEmpty { Text("Нет жалоб") }
                    if queueCursor != nil { Button("Загрузить ещё жалобы") { loadMore(appeals: false) } }
                }
                Section("Апелляции") {
                    ForEach(appeals) { item in
                        Button("\(item.status) · \(String(item.report.prefix(8)))") { openAppeal(item) }
                    }
                    if appealCursor != nil { Button("Загрузить ещё апелляции") { loadMore(appeals: true) } }
                    if let appealContent {
                        Text(appealContent.comment).textSelection(.enabled)
                    }
                    if let selectedAppeal {
                        Text("Исходное дело: \(selectedAppeal.report)").font(.caption.monospaced()).textSelection(.enabled)
                        if access?.role == "owner" {
                            Toggle("Подтверждаю пересмотр собственного решения, если оно моё", isOn: $selfReview)
                            Text("Предпочтителен другой администратор. Пересмотр своего решения владельцем записывается в аудит.").font(.caption)
                        }
                        if ["owner", "admin"].contains(access?.role ?? "") {
                            Button("Оставить решение в силе") { appealOutcome = "upheld"; confirmAppeal = true }
                            Button("Удовлетворить апелляцию и снять это ограничение") { appealOutcome = "overturned"; confirmAppeal = true }
                        }
                    }
                }
                if access?.role == "owner" { roles }
                Section("Аудит · последние 200 событий") {
                    ForEach(events) { event in
                        Text(event.entry).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let failure { Text(failure).font(.callout) }
        }
        .disabled(working)
        .navigationTitle("Модерация")
        .task { await refresh() }
        .refreshable { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear() } }
        .onChange(of: store.generation) { _, _ in clear(); access = nil }
        .onChange(of: store.locked) { _, value in if value { clear() } }
        .onDisappear { clear() }
        .task(id: token) {
            guard let activeToken = token else { return }
            let seconds = max(1, expiresAt - Int(Date().timeIntervalSince1970))
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if token == activeToken { clear() }
        }
        .sheet(item: $selected, onDismiss: { Task { await refresh() } }) { item in
            if let token { ModeratorCaseView(item: item, token: token, role: access?.role ?? "reviewer") }
        }
        .confirmationDialog("Подтвердить решение по апелляции?", isPresented: $confirmAppeal, titleVisibility: .visible) {
            Button("Подтвердить") {
                guard let item = selectedAppeal, let token else { return }
                run { api in
                    try await api.decideAppeal(item, outcome: appealOutcome, acknowledgeSelfReview: selfReview, token: token)
                    selectedAppeal = nil; appealContent = nil; selfReview = false
                    await refresh()
                }
            }
        }
    }
    private var authentication: some View {
        Group {
            if access?.mfaEnabled != true {
                Button("Настроить MFA") {
                    let current = store.generation
                    run { api in
                        let result = try await api.setupModeratorMFA()
                        guard current == store.generation, !store.locked, scenePhase == .active else { return }
                        secret = result.secret
                    }
                }
                if !secret.isEmpty {
                    Text("Добавь секрет в отдельное приложение аутентификации: TOTP, SHA-1, 6 цифр, 30 секунд.").font(.caption)
                    Text(secret).font(.body.monospaced()).textSelection(.enabled)
                    Button("Скопировать на 30 секунд") { SafeContent.copy(secret, seconds: 30) }
                }
            }
            SecureField("Код аутентификатора", text: $code).keyboardType(.numberPad)
            Button("Открыть панель") {
                let current = store.generation
                run { api in
                    let login = try await api.loginModerator(code: code)
                    guard current == store.generation, scenePhase == .active, !store.locked else { return }
                    token = login.token; expiresAt = login.expiresAt; secret = ""; code = ""
                    await refresh()
                }
            }.disabled(code.count != 6)
        }
    }
    private var roles: some View {
        Section("Роли модераторов") {
            TextField("Полный ID модератора", text: $roleIdentity).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Роль", selection: $assignedRole) {
                Text("Просмотр очереди").tag("reviewer")
                Text("Решения и ограничения").tag("admin")
                Text("Отозвать доступ").tag("none")
            }
            Text("Выбранные доказательства зашифрованы только для @vo1d. Делегированные роли не получают ключ к ним.").font(.caption)
            Button("Применить роль") {
                guard let token else { return }
                run { api in try await api.assignModerator(identity: roleIdentity, role: assignedRole, token: token); await refresh() }
            }.disabled(roleIdentity.count != 64)
        }
    }
    private func clear() {
        token = nil; secret = ""; code = ""; queue = []; appeals = []; events = []; selected = nil; appealContent = nil
        queueCursor = nil; appealCursor = nil; selectedAppeal = nil; selfReview = false; confirmAppeal = false
    }
    private func run(_ operation: @escaping (APIClient) async throws -> Void) {
        guard let api = store.api else { return }
        let current = store.generation
        working = true
        failure = nil
        Task {
            do { try await operation(api) } catch { if current == store.generation { failure = error.localizedDescription } }
            working = false
        }
    }
    private func refresh() async {
        let current = store.generation
        do {
            guard let api = store.api else { return }
            let nextAccess = try await api.moderationAccess()
            guard current == store.generation, !store.locked else { return }
            access = nextAccess
            if let token {
                guard expiresAt > Int(Date().timeIntervalSince1970), scenePhase == .active else { clear(); return }
                let filters = [statusFilter, reasonFilter, search, assignmentFilter]
                let reports = try await api.moderationPage(token: token, status: filters[0], reason: filters[1], search: filters[2], assignment: filters[3])
                let nextAppeals = try await api.appealPage(token: token)
                let audit = try await api.moderationAudit(token: token)
                guard current == store.generation, self.token == token, !store.locked, scenePhase == .active, filters == [statusFilter, reasonFilter, search, assignmentFilter] else { return }
                queue = reports.reports; queueCursor = reports.nextCursor
                appeals = nextAppeals.appeals; appealCursor = nextAppeals.nextCursor; events = audit
            }
        } catch { if current == store.generation, !store.locked { failure = error.localizedDescription } }
    }
    private func loadMore(appeals isAppeals: Bool) {
        guard let token else { return }
        let current = store.generation
        let filters = [statusFilter, reasonFilter, search, assignmentFilter]
        let cursor = isAppeals ? appealCursor : queueCursor
        guard let cursor else { return }
        run { api in
            if isAppeals {
                let result = try await api.appealPage(token: token, cursor: cursor)
                guard current == store.generation, self.token == token, !store.locked, scenePhase == .active, appealCursor == cursor else { return }
                let known = Set(appeals.map(\.id))
                appeals += result.appeals.filter { !known.contains($0.id) }; appealCursor = result.nextCursor
            } else {
                let result = try await api.moderationPage(token: token, status: filters[0], reason: filters[1], search: filters[2], assignment: filters[3], cursor: cursor)
                guard current == store.generation, self.token == token, !store.locked, scenePhase == .active, queueCursor == cursor, filters == [statusFilter, reasonFilter, search, assignmentFilter] else { return }
                let known = Set(queue.map(\.id))
                queue += result.reports.filter { !known.contains($0.id) }; queueCursor = result.nextCursor
            }
        }
    }
    private func openAppeal(_ item: ModerationAppeal) {
        guard let token, let identity = store.identity else { return }
        selectedAppeal = item; appealContent = nil; selfReview = false
        guard access?.role == "owner" else { return }
        let current = store.generation
        run { api in
            let sealed = try await api.moderationEvidence(item.id, appeal: true, token: token)
            let content = try Wire.decoder.decode(ReportContent.self, from: Crypto.openPayload(sealed.envelope, identity: identity, sender: sealed.senderCard)).validated(for: sealed.envelope)
            guard content.source == "appeal", content.subject == item.identity, content.appealFor == nil || content.appealFor == item.report else { throw MessengerError.invalid("Апелляция не соответствует делу") }
            guard current == store.generation, self.token == token, !store.locked else { return }
            appealContent = content
            if content.appealFor == nil { failure = "Апелляция ранней версии: номер дела не связан с шифротекстом. Проверь исходное решение вручную." }
        }
    }
}

struct ModeratorCaseView: View {
    var item: ModerationCase
    var token: String
    var role: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var content: ReportContent?
    @State private var failure: String?
    @State private var action: String?
    @State private var confirming = false
    @State private var working = false
    @State private var assignee = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Дело \(item.id.prefix(8))") {
                    Text(item.subject).font(.caption.monospaced()).textSelection(.enabled)
                    Text(ReportReason(rawValue: item.reason)?.label ?? item.reason)
                    Text("Статус: \(item.status)")
                }
                if let content {
                    Section("Добровольно представленные доказательства") {
                        Text(content.comment).textSelection(.enabled)
                        ForEach(content.messages) { evidence in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(evidence.sender.prefix(12)).font(.caption.monospaced())
                                Text(evidence.text).textSelection(.enabled)
                                if let attachment = evidence.attachment {
                                    ReportEvidenceFileView(attachment: attachment)
                                }
                            }
                        }
                        Text("Представленный текст не является независимым доказательством авторства. Не принимай решения только по числу жалоб.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if role == "owner" {
                    Button("Расшифровать выбранные доказательства") { decrypt() }
                }
                Section("Решение") {
                    Button("Назначить дело себе") { assign(store.myID) }
                    if item.assignee == store.myID || role != "reviewer" {
                        Button("Освободить назначение") { assign(nil) }
                    }
                    if role == "owner" || role == "admin" {
                        TextField("ID ответственного модератора", text: $assignee).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Назначить модератору") { assign(assignee) }.disabled(assignee.count != 64)
                    }
                    Button("Взять на рассмотрение") { decide(status: "reviewing", action: "none") }
                    Button("Отклонить жалобу") { action = "dismiss"; confirming = true }
                    if role == "owner" || role == "admin" {
                        ForEach([("warn", "Предупредить"), ("restrict", "Ограничить отправку на сутки"), ("ban", "Заблокировать отправку на сутки"), ("lift", "Снять ограничение")], id: \.0) { value in
                            Button(value.1) { action = value.0; confirming = true }
                        }
                    }
                }
                if let failure { Text(failure) }
            }
            .disabled(working)
            .navigationTitle("Рассмотрение жалобы")
            .toolbar { Button("Закрыть") { dismiss() } }
            .confirmationDialog("Подтвердить решение по этой жалобе?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Подтвердить") {
                    if let action { decide(status: action == "dismiss" ? "dismissed" : "resolved", action: action == "dismiss" ? "none" : action) }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { content = nil; dismiss() } }
            .onChange(of: store.generation) { _, _ in content = nil; dismiss() }
            .onChange(of: store.locked) { _, value in if value { content = nil; dismiss() } }
        }
    }
    private func decrypt() {
        guard let api = store.api, let identity = store.identity else { return }
        let current = store.generation
        working = true
        Task {
            defer { working = false }
            do {
                let sealed = try await api.moderationEvidence(item.id, token: token)
                let decoded = try Wire.decoder.decode(ReportContent.self, from: Crypto.openPayload(sealed.envelope, identity: identity, sender: sealed.senderCard)).validated(for: sealed.envelope)
                guard decoded.subject == item.subject, decoded.reason.rawValue == item.reason, decoded.source == item.source else { throw MessengerError.invalid("Доказательства не соответствуют метаданным жалобы") }
                guard current == store.generation, !store.locked, scenePhase == .active else { return }
                content = decoded
            } catch { failure = error.localizedDescription }
        }
    }
    private func decide(status: String, action: String) {
        guard let api = store.api else { return }
        working = true
        Task {
            defer { working = false }
            do { try await api.decide(item, status: status, action: action, token: token); dismiss() }
            catch { failure = error.localizedDescription }
        }
    }
    private func assign(_ identity: String?) {
        guard let api = store.api else { return }
        working = true
        Task {
            defer { working = false }
            do { try await api.assignCase(item, assignee: identity, token: token); dismiss() }
            catch { failure = error.localizedDescription }
        }
    }
}
