import SwiftUI
import PhotosUI
import UIKit

enum SocialImage {
    static func jpeg(_ data: Data, maxSide: CGFloat = 960, limit: Int = 400_000) -> Data? {
        guard data.count <= 20_000_000, let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(source.size.width, source.size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        for quality in [0.8, 0.6, 0.4] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= limit { return jpeg }
        }
        return nil
    }
}
struct ProfilePreviewView: View {
    var peerID: String? = nil
    @EnvironmentObject var store: ChatStore
    private var mine: Bool { peerID == nil || peerID == store.myID }
    private var id: String { peerID ?? store.myID }
    private var profile: SharedProfile {
        mine ? store.ownSharedProfile : store.social.profiles[id] ?? SharedProfile(name: store.name(id), bio: "", avatar: nil, updatedAt: .distantPast, status: "")
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Avatar(name: profile.name, size: 120, imageData: profile.avatar).padding(.top, 26)
                VStack(spacing: 8) {
                    Text(profile.name).font(.largeTitle.bold())
                    if mine, let username = store.state.username { Text("@\(username)").font(.callout.monospaced()).foregroundStyle(.secondary) }
                    if !profile.status.isEmpty { Text(profile.status).font(.title3) }
                    if mine && store.hasPremium { Label("VO1D PREMIUM", systemImage: "sparkles").font(.caption.bold()) }
                    if !profile.bio.isEmpty { Text(profile.bio).multilineTextAlignment(.center).padding(.top, 6) }
                }
                if mine {
                    Text("Так твой профиль выглядит для контактов, которым ты его отправил.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    NavigationLink { StoryComposerView() } label: { Label("Добавить историю", systemImage: "plus.circle") }.buttonStyle(.borderedProminent)
                    NavigationLink { PremiumView() } label: { Label("Premium и коллекция", systemImage: "diamond") }
                }
                ForEach(store.social.stories.filter { $0.author == id && $0.expiresAt > Date() }.sorted { $0.createdAt > $1.createdAt }) { story in
                    StoryCard(story: story)
                }
                if !mine {
                    Text("Профиль получен через E2EE. Изменения появятся после обмена с собеседником.").font(.caption).foregroundStyle(.secondary)
                    Button("Обновить профиль") { request() }
                }
            }.padding(24).frame(maxWidth: .infinity)
        }.background(.black).navigationTitle("Профиль").navigationBarTitleDisplayMode(.inline)
            .task { if !mine { request() } }
    }
    private func request() {
        do { try store.requestProfile(id); Task { await store.sync() } } catch { store.error = error.localizedDescription }
    }
}
struct StoryCard: View {
    var story: PrivateStory
    @EnvironmentObject var store: ChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(story.author == store.myID ? "Твоя история" : store.name(story.author)).font(.headline)
                Spacer()
                Text(story.expiresAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                if story.author == store.myID {
                    Button(role: .destructive) { do { try store.deleteStory(story); Task { await store.sync() } } catch { store.error = error.localizedDescription } } label: { Image(systemName: "trash") }
                }
            }
            if let data = story.image, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 460).clipShape(RoundedRectangle(cornerRadius: 20))
            }
            if !story.text.isEmpty { Text(story.text).font(.title3) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
    }
}
struct StoriesStrip: View {
    @EnvironmentObject var store: ChatStore
    private var authors: [String] { Array(Set(store.social.stories.filter { $0.expiresAt > Date() }.map(\.author))).sorted() }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                NavigationLink { StoryComposerView() } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "plus").font(.title2).frame(width: 58, height: 58).background(.white.opacity(0.08), in: Circle()).overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                        Text("История").font(.caption2)
                    }
                }.buttonStyle(.plain)
                ForEach(authors, id: \.self) { author in
                    NavigationLink { ProfilePreviewView(peerID: author) } label: {
                        VStack(spacing: 7) {
                            Avatar(name: store.name(author), size: 58, imageData: author == store.myID ? store.state.profileAvatar : store.social.profiles[author]?.avatar)
                                .padding(4).overlay(Circle().stroke(.white, lineWidth: 1.5))
                            Text(author == store.myID ? "Ты" : store.name(author)).font(.caption2).lineLimit(1).frame(width: 66)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 4)
        }
    }
}
struct StoryComposerView: View {
    @EnvironmentObject var store: ChatStore
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var photo: PhotosPickerItem?
    @State private var image: Data?
    @State private var audience = Set<String>()
    @State private var loading = false
    private var contacts: [Contact] { store.state.contacts.filter { !$0.blocked && $0.isBot != true && !store.isBuiltinBot($0.id) && store.extended.trustedIDs.contains($0.id) } }
    var body: some View {
        Form {
            Section("Исчезнет через 24 часа") {
                TextField("Твоя история", text: $text, axis: .vertical).lineLimit(3...8)
                    .onChange(of: text) { _, value in if value.count > 1200 { text = String(value.prefix(1200)) } }
                PhotosPicker(selection: $photo, matching: .images) { Label(image == nil ? "Добавить фото" : "Заменить фото", systemImage: "photo") }
                if let data = image, let uiImage = UIImage(data: data) { Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 240) }
            }
            Section("Кому видна") {
                if contacts.isEmpty { Text("Сначала добавь контакт и обменяйся сообщениями.") }
                ForEach(contacts) { contact in
                    Toggle(contact.name, isOn: Binding(get: { audience.contains(contact.id) }, set: { if $0 { audience.insert(contact.id) } else { audience.remove(contact.id) } }))
                }
                Text("Фото сохраняется без EXIF. Выбранные контакты получают зашифрованную копию; они могут сохранить её.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Опубликовать") {
                do { try store.publishStory(text: text, image: image, audience: audience); Task { await store.sync() }; dismiss() }
                catch { store.error = error.localizedDescription }
            }.disabled(loading || audience.isEmpty || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil))
        }.navigationTitle("Новая история")
        .onChange(of: photo) { _, item in
            guard let item else { return }; loading = true
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let jpeg = SocialImage.jpeg(data) { image = jpeg }
                else { store.error = "Не удалось подготовить фото до 400 КБ" }
                loading = false; photo = nil
            }
        }
    }
}
