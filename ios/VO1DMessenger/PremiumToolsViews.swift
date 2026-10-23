import SwiftUI
import Translation

extension SavedTag {
    var tint: Color {
        switch color {
        case "blue": return .artifactHex(0x85ACF0)
        case "mint": return .artifactHex(0x82CBB7)
        case "gold": return .artifactHex(0xDDBB7D)
        case "rose": return .artifactHex(0xE59BB9)
        default: return .artifactHex(0xC4ABED)
        }
    }
}

struct PremiumAccessView<Content: View>: View {
    @EnvironmentObject private var store: ChatStore
    var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        Group { if store.hasPremium { content() } else { PremiumPlanView() } }
            .task { if store.coinWallet == nil { try? await store.refreshEconomy() } }
    }
}

struct PremiumWorkspaceView: View {
    var body: some View {
        PremiumAccessView {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Image(systemName: "sparkles").font(.system(size: 42)).foregroundStyle(Color.artifactHex(0xC4ABED)).padding(.top, 15)
                    Text("Меньше рутины.\nБольше твоего.").font(.system(size: 32, weight: .bold, design: .rounded))
                    NavigationLink { FolderCenterView() } label: { toolRow("Умные папки", detail: "Чаты сами находят своё место", icon: "folder.badge.gearshape") }
                    NavigationLink { SavedTagsView() } label: { toolRow("Теги Избранного", detail: "Идеи, работа и важное — в один тап", icon: "tag") }
                    NavigationLink { ReplyTemplatesView() } label: { toolRow("Быстрые ответы", detail: "Готовые фразы с именем, датой и временем", icon: "text.bubble") }
                    NavigationLink { AppearanceSettingsView() } label: { toolRow("Твой стиль", detail: "Темы и обои для каждой беседы", icon: "paintpalette") }
                    Label("Перевод доступен в меню текстового сообщения. Расшифровка — под голосовым.", systemImage: "globe").font(.callout).foregroundStyle(.secondary).lineSpacing(4).padding(.top, 5)
                }.padding(24)
            }.background { VoidBackground() }.navigationTitle("Возможности Premium").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func toolRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 48, height: 48).background(.white.opacity(0.06), in: Circle()).foregroundStyle(Color.artifactHex(0xC4ABED))
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.foregroundStyle(.primary).padding(17).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct SmartFolderEditorView: View {
    var folderID: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule = SmartFolderRule()
    @State private var enabled = true
    @State private var notice: String?
    var body: some View {
        PremiumAccessView {
            Form {
                Section { Toggle("Подбирать чаты автоматически", isOn: $enabled) }
                if enabled {
                    Section("Какие беседы добавлять") {
                        kind("Личные", id: "direct"); kind("Группы", id: "groups"); kind("Каналы", id: "channels")
                        Text("Без выбранного типа — все беседы. Чаты, добавленные вручную, останутся в папке.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Условия") {
                        Toggle("Только непрочитанные", isOn: $rule.unreadOnly)
                        Toggle("Без отключённых уведомлений", isOn: $rule.excludeMuted)
                        Toggle("С фото, голосовыми или файлами", isOn: $rule.withAttachments)
                    }
                    Section("Всегда исключать") {
                        ForEach(store.state.rooms.filter { !store.extended.hiddenRooms.contains($0.id) }) { room in
                            Toggle(room.title, isOn: Binding(get: { rule.excludedRoomIDs.contains(room.id) }, set: { value in rule.excludedRoomIDs.removeAll { $0 == room.id }; if value { rule.excludedRoomIDs.append(room.id) } }))
                        }
                    }
                }
                if let notice { Text(notice).foregroundStyle(.red) }
                Section { Button("Сохранить правила") { save() } }
            }.scrollContentBackground(.hidden).background { VoidBackground() }.navigationTitle("Умная папка").tint(.artifactHex(0xC4ABED))
                .onAppear { if let saved = store.premiumTools.folderRules[folderID] { rule = saved } else { enabled = false } }
        }
    }
    private func kind(_ title: String, id: String) -> some View {
        Toggle(title, isOn: Binding(get: { rule.kinds.contains(id) }, set: { value in rule.kinds.removeAll { $0 == id }; if value { rule.kinds.append(id) } }))
    }
    private func save() {
        do { try store.changePremiumTools { if enabled { $0.folderRules[folderID] = rule } else { $0.folderRules[folderID] = nil } }; dismiss() }
        catch { notice = error.localizedDescription }
    }
}

struct SavedTagsView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var name = ""
    @State private var color = "violet"
    @State private var editingID: String?
    @State private var notice: String?
    var body: some View {
        PremiumAccessView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Найти важное.\nЗа секунду.").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Помечай сообщения в Избранном и переключай подборки прямо в чате.").font(.callout).foregroundStyle(.secondary)
                    TextField("Например, Идеи", text: $name).voidField().onChange(of: name) { _, value in name = String(value.prefix(24)) }
                    HStack(spacing: 18) {
                        ForEach(SavedTag.colors, id: \.self) { choice in
                            Button { color = choice } label: { Circle().fill(SavedTag(name: "", color: choice).tint).frame(width: 34, height: 34).overlay { if color == choice { Image(systemName: "checkmark").foregroundStyle(.black) } } }.accessibilityLabel(choice)
                        }
                    }.frame(maxWidth: .infinity)
                    Button(editingID == nil ? "Создать тег" : "Сохранить тег") { save() }.buttonStyle(PrimaryButton()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editingID != nil { Button("Отменить редактирование") { editingID = nil; name = "" }.frame(maxWidth: .infinity) }
                    if let notice { EconomyNotice(message: notice) }
                    ForEach(store.premiumTools.tags) { tag in
                        HStack(spacing: 12) {
                            Image(systemName: "tag.fill").foregroundStyle(tag.tint).frame(width: 38, height: 38).background(tag.tint.opacity(0.12), in: Circle())
                            Text(tag.name).font(.headline); Spacer()
                            Button { name = tag.name; color = tag.color; editingID = tag.id } label: { Image(systemName: "pencil") }.accessibilityLabel("Изменить " + tag.name)
                            Button(role: .destructive) { remove(tag) } label: { Image(systemName: "trash") }.padding(.leading, 10).accessibilityLabel("Удалить " + tag.name)
                        }.padding(17).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 27))
                    }
                }.padding(24)
            }.background { VoidBackground() }.navigationTitle("Теги Избранного").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func save() {
        do {
            try store.changePremiumTools { tools in
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tools.tags.contains(where: { $0.id != editingID && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) else { throw MessengerError.invalid("Тег с таким именем уже есть") }
                if let editingID, let index = tools.tags.firstIndex(where: { $0.id == editingID }) { tools.tags[index].name = clean; tools.tags[index].color = color }
                else { tools.tags.append(SavedTag(name: clean, color: color)) }
            }
            name = ""; editingID = nil; notice = nil; Haptics.success()
        } catch { notice = error.localizedDescription }
    }
    private func remove(_ tag: SavedTag) {
        do { try store.changePremiumTools { $0.tags.removeAll { $0.id == tag.id } }; if editingID == tag.id { editingID = nil; name = "" } }
        catch { notice = error.localizedDescription }
    }
}

struct ReplyTemplatesView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var editor: ReplyTemplate?
    @State private var notice: String?
    var body: some View {
        PremiumAccessView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Ответ готов.\nОсталось отправить.").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Сохраняй длинные ответы. Имя собеседника, твоя подпись, дата и время подставятся при вставке.").font(.callout).foregroundStyle(.secondary)
                    Button { editor = ReplyTemplate(title: "", shortcut: "", body: "") } label: { Label("Новый быстрый ответ", systemImage: "plus") }.buttonStyle(PrimaryButton())
                    if let notice { EconomyNotice(message: notice) }
                    ForEach(store.premiumTools.replyTemplates) { reply in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(reply.title).font(.headline); Spacer(); Text("/" + reply.shortcut).font(.caption.monospaced()).foregroundStyle(Color.artifactHex(0xC4ABED)) }
                            Text(reply.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            HStack { Button("Изменить") { editor = reply }; Spacer(); Button("Удалить", role: .destructive) { do { try store.changePremiumTools { $0.replyTemplates.removeAll { $0.id == reply.id } } } catch { notice = error.localizedDescription } } }.font(.caption)
                        }.padding(20).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 30))
                    }
                }.padding(24)
            }.background { VoidBackground() }.navigationTitle("Быстрые ответы").navigationBarTitleDisplayMode(.inline)
                .sheet(item: $editor) { reply in NavigationStack { ReplyTemplateEditor(reply: reply) } }
        }
    }
}

struct ReplyTemplateEditor: View {
    @State var reply: ReplyTemplate
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Название", text: $reply.title).voidField().onChange(of: reply.title) { _, value in reply.title = String(value.prefix(40)) }
                HStack { Text("/").foregroundStyle(.secondary); TextField("команда латиницей", text: $reply.shortcut).textInputAutocapitalization(.never).autocorrectionDisabled() }.voidField()
                TextField("Текст ответа", text: $reply.body, axis: .vertical).lineLimit(5...12).voidField().onChange(of: reply.body) { _, value in reply.body = String(value.prefix(4000)) }
                ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(["{name}", "{me}", "{date}", "{time}"], id: \.self) { token in Button(token) { reply.body += token }.font(.caption.monospaced()).padding(11).background(.white.opacity(0.07), in: Capsule()) } } }
                Text("ПРЕДПРОСМОТР").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Text(reply.rendered(name: "Ника", me: store.state.nickname)).font(.callout).padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 28))
                if let notice { EconomyNotice(message: notice) }
                Button("Сохранить ответ") {
                    do {
                        var clean = reply; clean.title = clean.title.trimmingCharacters(in: .whitespacesAndNewlines); clean.shortcut = clean.shortcut.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased(); clean.body = clean.body.trimmingCharacters(in: .whitespacesAndNewlines)
                        try store.changePremiumTools { tools in if let index = tools.replyTemplates.firstIndex(where: { $0.id == clean.id }) { tools.replyTemplates[index] = clean } else { tools.replyTemplates.append(clean) } }; dismiss()
                    } catch { notice = error.localizedDescription }
                }.buttonStyle(PrimaryButton())
            }.padding(24)
        }.background { VoidBackground() }.navigationTitle("Быстрый ответ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
    }
}

struct PremiumTranslationSheet: View {
    var messageID: String
    var body: some View {
        PremiumAccessView {
            if #available(iOS 18.0, *) { LocalMessageTranslationView(messageID: messageID) }
            else { ContentUnavailableView("Перевод на устройстве", systemImage: "globe", description: Text("Для этой возможности требуется iOS 18 или новее.")) }
        }
    }
}

@available(iOS 18.0, *)
private struct LocalMessageTranslationView: View {
    var messageID: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var target = Locale.current.language.languageCode?.identifier ?? "ru"
    @State private var configuration: TranslationSession.Configuration?
    @State private var result = ""
    @State private var notice: String?
    @State private var busy = false
    @State private var fence: SessionFence?
    private var source: String? {
        store.state.messages.first { $0.id == messageID && $0.viewOnceSeconds == nil && ($0.expiresAt ?? .distantFuture) > Date() }?.text
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("Перевод на устройстве", systemImage: "globe").font(.title2.bold())
                if !store.locked, store.sessionUnlocked, let source {
                    Text(source).font(.body).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 28))
                    Picker("Перевести на", selection: $target) {
                        ForEach([("ru", "Русский"), ("en", "English"), ("uk", "Українська"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("zh", "中文"), ("ja", "日本語"), ("ko", "한국어")], id: \.0) { Text($0.1).tag($0.0) }
                    }.tint(.artifactHex(0xC4ABED)).disabled(busy)
                    Button { translate() } label: { HStack { if busy { ProgressView().tint(.black) }; Text(busy ? "Переводим…" : "Перевести") } }.buttonStyle(PrimaryButton()).disabled(busy || source.isEmpty)
                    if !result.isEmpty { Text(result).font(.body).textSelection(.enabled).padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Color.artifactHex(0xAC95DD).opacity(0.14), in: RoundedRectangle(cornerRadius: 30)) }
                    Text("Для нового языка iOS предложит загрузить модель. Текст обрабатывается на устройстве.").font(.caption).foregroundStyle(.secondary)
                }
                if let notice { EconomyNotice(message: notice) }
            }.padding(24)
        }.background { VoidBackground() }.navigationTitle("Перевод").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .translationTask(configuration) { session in
                defer { busy = false }
                do {
                    guard let fence, let source, !store.locked, store.sessionUnlocked, store.hasPremium else { throw CancellationError() }
                    let response = try await session.translate(source)
                    try store.requireCurrentSession(fence); try Task.checkCancellation()
                    guard !store.locked, store.sessionUnlocked, store.hasPremium, self.source == source else { throw CancellationError() }
                    result = response.targetText
                } catch is CancellationError { return }
                catch { notice = "Не удалось перевести. Проверь доступность языковой модели в iOS. " + error.localizedDescription }
            }
            .onChange(of: store.locked) { _, locked in if locked { clear(); dismiss() } }
            .onChange(of: store.profileID) { _, _ in clear(); dismiss() }
            .onChange(of: source) { _, _ in clear() }
            .onChange(of: store.hasPremium) { _, value in if !value { clear() } }
            .onDisappear { clear() }
    }
    private func clear() { result = ""; configuration = nil; fence = nil; busy = false }
    private func translate() {
        busy = true; notice = nil; result = ""
        let expected = store.sessionFence
        Task {
            do {
                try await store.authorizePremiumTools(); try store.requireCurrentSession(expected)
                guard !store.locked, store.sessionUnlocked, source != nil else { throw CancellationError() }
                fence = expected
                if configuration == nil { configuration = .init(source: nil, target: Locale.Language(identifier: target)) }
                else { configuration = .init(source: nil, target: Locale.Language(identifier: target)); configuration?.invalidate() }
            } catch is CancellationError { busy = false }
            catch { notice = error.localizedDescription; busy = false }
        }
    }
}
