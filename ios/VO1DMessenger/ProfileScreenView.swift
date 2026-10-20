import SwiftUI
import PhotosUI
import UIKit

struct ProfileScreenView: View {
    var owner: String
    @EnvironmentObject private var store: ChatStore
    @State private var tab = 0
    @State private var gifts: [CollectibleArtifact] = []
    @State private var cursor: String?
    @State private var premium = false
    @State private var total = 0
    @State private var editing = false
    @State private var composing = false
    @State private var notice: String?
    @State private var loading = true
    @State private var showHidden = true
    @State private var room: Room?
    private var mine: Bool { owner == store.myID }
    private var profile: SharedProfile? { mine ? store.ownSharedProfile : store.social.profiles[owner] }
    private var name: String { profile?.name ?? store.name(owner) }
    private var stories: [PrivateStory] { store.social.stories.filter { $0.author == owner && $0.expiresAt > Date() }.sorted { $0.createdAt > $1.createdAt } }
    private var ownGifts: [CollectibleArtifact] { mine ? (store.economy.owner == owner ? store.economy.artifacts : []) : gifts }
    private var visibleGifts: [CollectibleArtifact] { ownGifts.filter { $0.visible || (mine && showHidden) } }
    private var featured: CollectibleArtifact? { ownGifts.first { $0.visible && $0.traits != nil } }
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                if let notice { EconomyNotice(message: notice); Button("Повторить загрузку") { Task { await load() } } }
                if mine { shortcuts }
                else if let contact = store.state.contacts.first(where: { $0.id == owner }), !contact.blocked {
                    HStack(spacing: 12) {
                        Button { do { room = try store.direct(contact) } catch { notice = error.localizedDescription } } label: { Label("Написать", systemImage: "bubble.left.fill") }.buttonStyle(PrimaryButton())
                        NavigationLink { ContactDetailView(contactID: owner) } label: { Image(systemName: "ellipsis").font(.title3).padding(15) }.buttonStyle(RoundedActionStyle())
                    }
                }
                Picker("Профиль", selection: $tab) { Text("Подарки").tag(0); Text("Истории").tag(1); Text("О себе").tag(2) }.pickerStyle(.segmented)
                if tab == 0 { giftGrid }
                else if tab == 1 { storyGrid }
                else { about }
            }.padding(.horizontal, 20).padding(.bottom, 32)
        }.background { VoidBackground() }
        .navigationTitle(mine ? "Мой профиль" : name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mine {
                ToolbarItem(placement: .topBarTrailing) { Button("Изменить") { editing = true }.font(.subheadline.weight(.medium)) }
            }
        }
        .task(id: owner) { await load() }.refreshable { await load() }
        .sheet(isPresented: $editing) { NavigationStack { ProfileEditorView() } }
        .sheet(isPresented: $composing) { NavigationStack { StoryComposerView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { composing = false } } } } }
        .navigationDestination(item: $room) { ChatView(roomID: $0.id) }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 30)
                    .fill(LinearGradient(colors: ArtifactPalette.backdrop(featured?.traits?.backdrop.id).map { $0.opacity(0.7) } + [.black.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 164)
                    .overlay(alignment: .topTrailing) {
                        if let featured { ArtifactArtwork(collection: featured.collection, traits: featured.traits).frame(width: 108).rotationEffect(.degrees(14)).opacity(0.5).padding(12).accessibilityHidden(true) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 30))
                Group {
                    if !stories.isEmpty {
                        NavigationLink { StoryViewerView(author: owner) } label: { avatar }.buttonStyle(MotionButtonStyle())
                    } else { avatar }
                }.offset(y: 42)
            }.padding(.top, 8).padding(.bottom, 42)
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 28, weight: .bold, design: .rounded)).tracking(-0.6)
                    if mine ? store.hasPremium : premium { Image(systemName: "seal.fill").font(.title3).foregroundStyle(Color.artifactHex(0xC7ACF0)).accessibilityLabel("VO1D_PREMIUM") }
                }.multilineTextAlignment(.center)
                if mine, let username = store.state.username { Text("@" + username).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                if let status = profile?.status, !status.isEmpty { Text(status).font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 7).background(.white.opacity(0.07), in: Capsule()) }
                if let bio = profile?.bio, !bio.isEmpty { Text(bio).font(.subheadline).lineSpacing(4).multilineTextAlignment(.center).textSelection(.enabled).padding(.top, 4) }
            }
            HStack(spacing: 34) {
                metric("Подарки", value: mine ? store.economy.visibleCount : total)
                metric("Истории", value: stories.count)
            }.padding(.top, 4)
        }
    }
    private var avatar: some View {
        Avatar(name: name, size: 104, imageData: profile?.avatar)
            .clipShape(Circle()).padding(5).background(.black, in: Circle())
            .overlay(Circle().strokeBorder(LinearGradient(colors: stories.isEmpty ? [.white.opacity(0.15), .white.opacity(0.06)] : [.artifactHex(0xBDA3EB), .artifactHex(0xECD8B1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: stories.isEmpty ? 1 : 3))
            .accessibilityLabel(stories.isEmpty ? "Фото профиля" : "Открыть истории")
    }
    private func metric(_ title: String, value: Int) -> some View {
        VStack(spacing: 4) { Text(value.formatted()).font(.title3.bold().monospacedDigit()); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private var shortcuts: some View {
        HStack(spacing: 10) {
            shortcut("История", icon: "plus.circle") { composing = true }
            NavigationLink { CoinWalletView() } label: { shortcutLabel("Кошелёк", icon: "v.circle") }.buttonStyle(MotionButtonStyle())
            NavigationLink { PremiumPlanView() } label: { shortcutLabel("Premium", icon: "sparkles") }.buttonStyle(MotionButtonStyle())
        }
    }
    private func shortcut(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { shortcutLabel(title, icon: icon) }.buttonStyle(MotionButtonStyle())
    }
    private func shortcutLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 20, weight: .medium)); Text(title).font(.caption.weight(.medium)) }
            .frame(maxWidth: .infinity).padding(.vertical, 17).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))
    }
    private var giftGrid: some View {
        VStack(spacing: 18) {
            if mine {
                Toggle("Показать скрытые · \(max(0, store.economy.total - store.economy.visibleCount))", isOn: $showHidden).font(.caption).tint(.artifactHex(0xB49BDF))
                NavigationLink { ArtifactStorefrontView() } label: { Label("Найти свой артефакт", systemImage: "gift").frame(maxWidth: .infinity) }.buttonStyle(GhostButton())
            }
            if loading { ProgressView().padding(30) }
            else if visibleGifts.isEmpty {
                ContentUnavailableView("Коллекция начинается с одного", systemImage: "gift", description: Text(mine ? "Выбери подарок в витрине. Добавь его в профиль, чтобы показать друзьям." : "Здесь появятся подарки, которые владелец добавит в профиль."))
            }
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(visibleGifts) { gift in
                    NavigationLink { ArtifactDetailView(initial: gift) } label: {
                        ArtifactTile(gift: gift).overlay(alignment: .topLeading) {
                            if !gift.visible { Image(systemName: "eye.slash.fill").font(.caption).padding(9).background(.black.opacity(0.4), in: Circle()).padding(9) }
                        }
                    }.buttonStyle(MotionButtonStyle())
                }
            }
            if mine ? store.economy.nextCursor != nil : cursor != nil {
                Button("Загрузить ещё подарки") { Task { if mine { do { try await store.loadMoreArtifacts() } catch { notice = error.localizedDescription } } else { await loadPublic(more: true) } } }.buttonStyle(GhostButton())
            }
        }
    }
    private var storyGrid: some View {
        VStack(spacing: 16) {
            if mine { Button { composing = true } label: { Label("Новая история", systemImage: "plus.circle") }.buttonStyle(PrimaryButton()) }
            if stories.isEmpty { ContentUnavailableView("Пока тихо", systemImage: "circle.dashed", description: Text("Истории доступны 24 часа выбранным контактам.")) }
            ForEach(stories) { story in NavigationLink { StoryViewerView(author: owner, initialStoryID: story.id) } label: { StoryCard(story: story) }.buttonStyle(MotionButtonStyle()) }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("О себе").font(.title3.bold())
            Text(profile?.bio.isEmpty == false ? (profile?.bio ?? "") : "Здесь пока нет описания.").font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            if mine {
                Button("Изменить профиль") { editing = true }.buttonStyle(GhostButton())
                NavigationLink { AppearanceSettingsView() } label: { Label("Темы и оформление", systemImage: "paintpalette") }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).panel()
    }
    private func load() async {
        loading = true; notice = nil
        if mine {
            do { try await store.refreshEconomy() }
            catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        } else { await loadPublic(more: false) }
        loading = false
    }
    private func loadPublic(more: Bool) async {
        guard let api = store.api else { loading = false; return }
        let fence = store.sessionFence
        do {
            let page: ArtifactPage = try await api.request("v3/economy/profile/" + owner, query: more ? [URLQueryItem(name: "cursor", value: cursor)] : [])
            try store.requireCurrentSession(fence)
            gifts = more ? gifts + page.artifacts : page.artifacts; cursor = page.nextCursor; premium = page.premium == true; total = page.total ?? gifts.count
        } catch is CancellationError { return }
        catch { notice = error.localizedDescription }
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var status = ""
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var notice: String?
    @State private var audience = Set<String>()
    var body: some View {
        Form {
            Section {
                HStack { Spacer(); PhotosPicker(selection: $photo, matching: .images) { Avatar(name: name, size: 100, imageData: avatar).overlay(alignment: .bottomTrailing) { Image(systemName: "camera.fill").font(.subheadline).padding(9).background(.regularMaterial, in: Circle()) } }; Spacer() }.listRowBackground(Color.clear)
                if avatar != nil { Button("Убрать фото", role: .destructive) { avatar = nil } }
                TextField("Имя", text: $name).onChange(of: name) { _, value in name = String(value.prefix(40)) }
                TextField("@username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.state.username == "vo1d")
                TextField("Статус", text: $status).onChange(of: status) { _, value in status = String(value.prefix(32)) }
            }
            Section("О себе · \(bio.count)/160") {
                TextField("Пара слов о тебе", text: $bio, axis: .vertical).lineLimit(3...6).onChange(of: bio) { _, value in bio = String(value.prefix(160)) }
            }
            Section("Поделиться профилем") {
                ForEach(store.state.contacts.filter { !$0.blocked && $0.isBot != true && !store.isBuiltinBot($0.id) && store.extended.trustedIDs.contains($0.id) }) { contact in
                    Toggle(contact.name, isOn: Binding(get: { audience.contains(contact.id) }, set: { if $0 { audience.insert(contact.id) } else { audience.remove(contact.id) } }))
                }
                Text("Имя, фото, описание и статус отправятся только выбранным доверенным контактам в зашифрованном виде.").font(.caption).foregroundStyle(.secondary)
            }
            if let notice { Section { EconomyNotice(message: notice) } }
        }.navigationTitle("Изменить профиль").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("Готово") { save() }.bold().disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.interactiveDismissDisabled(busy)
        .onAppear { name = store.state.nickname; username = store.state.username ?? ""; bio = store.state.bio ?? ""; status = store.social.status; avatar = store.state.profileAvatar }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            let fence = store.sessionFence; busy = true
            Task {
                defer { busy = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let jpeg = SocialImage.jpeg(data, maxSide: 384, limit: 160_000) else { throw MessengerError.invalid("Не удалось подготовить фото") }
                    try store.requireCurrentSession(fence); avatar = jpeg
                } catch is CancellationError { return }
                catch { notice = error.localizedDescription }
            }
        }
    }
    private func save() {
        busy = true; notice = nil
        let fence = store.sessionFence
        Task {
            defer { busy = false }
            do {
                let clean = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
                if !clean.isEmpty && clean != store.state.username {
                    guard let api = store.api else { throw MessengerError.invalid("Нет соединения") }
                    _ = try await api.claimUsername(clean)
                    try store.requireCurrentSession(fence); store.state.username = clean
                } else if clean.isEmpty && store.state.username != nil { throw MessengerError.invalid("Чтобы сменить username, укажи новый.") }
                try store.requireCurrentSession(fence)
                let previous = store.state
                do {
                    store.state.nickname = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.state.bio = bio; store.state.profileAvatar = avatar
                    var social = store.social; social.status = status; store.state.social = social
                    try store.shareProfile(with: audience)
                    try store.save()
                } catch { store.state = previous; throw error }
                Task { await store.sync() }; Haptics.success(); dismiss()
            } catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}
