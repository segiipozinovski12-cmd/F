import SwiftUI
import PhotosUI
import UIKit

struct ProfileScreenView: View {
    var owner: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    private var featured: CollectibleArtifact? {
        let selected = mine ? store.social.featuredGiftID : profile?.featuredGiftID
        if selected == "" { return nil }
        return ownGifts.first { $0.visible && $0.id == selected } ?? ownGifts.first { $0.visible }
    }
    private var decoration: ProfileDecoration { (profile?.decoration ?? ProfileDecoration()).allowed(premium: mine ? store.hasPremium : premium) }
    private var sharedRoomID: String? {
        store.state.rooms.first { !$0.isGroup && !store.extended.hiddenRooms.contains($0.id) && $0.members.contains { $0.id == owner } && !store.isLocalUtilityRoom($0.id) }?.id
    }
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
                profileTabs
                if tab == 0 { giftGrid }
                else if tab == 1 { storyGrid }
                else if tab == 3, mine { personalHub }
                else if tab == 3, let sharedRoomID {
                    NavigationLink { SharedMediaView(roomID: sharedRoomID) } label: { Label("Фото, голосовые и файлы", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity) }.buttonStyle(GhostButton())
                } else { about }
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
                ProfileCover(decoration: decoration)
                    .frame(height: 164)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("VO1D").font(.caption.monospaced().bold()).tracking(4)
                            Text((mine ? store.hasPremium : premium) ? "PREMIUM MEMBER" : "YOUR OWN ORBIT").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.8).opacity(0.6)
                        }.padding(22).foregroundStyle(.white.opacity(0.9))
                    }
                    .overlay(alignment: .topTrailing) {
                        if let featured { ArtifactArtwork(collection: featured.collection, traits: featured.traits).frame(width: 132).rotationEffect(.degrees(12)).opacity(0.85).padding(10).accessibilityHidden(true) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
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
                if mine, store.coinWallet?.premiumLifetime == true { Label("Основатель VO1D", systemImage: "crown.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.artifactHex(0xDDBB7D)).padding(.horizontal, 13).padding(.vertical, 7).background(Color.artifactHex(0xDDBB7D).opacity(0.08), in: Capsule()) }
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    if decoration.symbol(at: timeline.date) != nil || profile?.status.isEmpty == false {
                    HStack(spacing: 6) {
                        if let symbol = decoration.symbol(at: timeline.date) { Image(systemName: symbol).foregroundStyle(decoration.colors.first ?? .white) }
                        if let status = profile?.status, !status.isEmpty { Text(status) }
                    }.font(.caption.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 7).background(.white.opacity(0.06), in: Capsule())
                    }
                }
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
        HStack(spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value.formatted()).font(.subheadline.bold().monospacedDigit()) }
    }
    private var personalHub: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Твоё пространство").font(.headline); Spacer(); Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            Button { do { room = try store.savedRoom() } catch { notice = error.localizedDescription } } label: { hubLabel("Избранное", subtitle: "Сохрани важное для себя", icon: "bookmark.fill") }.buttonStyle(MotionButtonStyle())
            NavigationLink { FolderCenterView() } label: { hubLabel("Папки чатов", subtitle: "Свои, работа, всё остальное", icon: "folder.fill") }.buttonStyle(MotionButtonStyle())
            NavigationLink { MessageLibraryView(mode: "scheduled") } label: { hubLabel("Отложенные сообщения", subtitle: "Отправить в нужный момент", icon: "clock.fill") }.buttonStyle(MotionButtonStyle())
            NavigationLink { SnippetsView() } label: { hubLabel("Быстрые ответы", subtitle: "Твои готовые фразы", icon: "text.bubble.fill") }.buttonStyle(MotionButtonStyle())
            NavigationLink { DeviceLinksView() } label: { hubLabel("Мои устройства", subtitle: "Подключения и контроль", icon: "laptopcomputer.and.iphone") }.buttonStyle(MotionButtonStyle())
            NavigationLink { PremiumWorkspaceView() } label: { hubLabel("Возможности Premium", subtitle: "Умные папки, теги и быстрые ответы", icon: "sparkles") }.buttonStyle(MotionButtonStyle())
        }.panel()
    }
    private func hubLabel(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Color.artifactHex(0xC7B4E9)).frame(width: 40, height: 40).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }.foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: 7) { Image(systemName: icon).font(.system(size: 15, weight: .medium)); Text(title).font(.caption.weight(.medium)) }
            .frame(maxWidth: .infinity).padding(.vertical, 15).background(.white.opacity(0.045), in: Capsule())
    }
    private var profileTabs: some View {
        HStack(spacing: 4) {
            ForEach(0..<(mine || sharedRoomID != nil ? 4 : 3), id: \.self) { index in
                Button { withAnimation(reduceMotion ? nil : Motion.layout) { tab = index } } label: {
                    Text(["Подарки", "Истории", "О себе", mine ? "Ещё" : "Медиа"][index]).font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(tab == index ? Color.black : .white.opacity(0.65)).background(tab == index ? Color.white : .clear, in: Capsule())
                }.buttonStyle(MotionButtonStyle()).accessibilityAddTraits(tab == index ? .isSelected : [])
            }
        }.padding(5).background(.white.opacity(0.04), in: Capsule())
    }
    private var giftGrid: some View {
        VStack(spacing: 18) {
            if mine {
                HStack {
                    Text("Коллекция").font(.headline)
                    Spacer()
                    NavigationLink { ArtifactStorefrontView() } label: { Label("В витрину", systemImage: "plus.circle").font(.subheadline.weight(.medium)) }.buttonStyle(MotionButtonStyle())
                }
                if store.economy.total > store.economy.visibleCount {
                    Toggle("Показать скрытые · \(store.economy.total - store.economy.visibleCount)", isOn: $showHidden).font(.caption).tint(.artifactHex(0xB49BDF))
                }
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
