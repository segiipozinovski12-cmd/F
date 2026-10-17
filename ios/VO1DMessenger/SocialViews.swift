import SwiftUI
import PhotosUI
import UIKit
import ImageIO

enum SocialImage {
    static func jpeg(_ data: Data, maxSide: CGFloat = 960, limit: Int = 400_000) -> Data? {
        guard data.count <= 20_000_000, maxSide.isFinite, (1...2048).contains(maxSide),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 120_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        for quality in [0.8, 0.6, 0.4] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= limit { return jpeg }
        }
        return nil
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
struct StoryViewerView: View {
    let author: String
    @EnvironmentObject private var store: ChatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { clock in
            let stories = store.social.stories.filter { $0.author == author && $0.expiresAt > clock.date }.sorted { $0.createdAt < $1.createdAt }
            VStack(spacing: 16) {
                if stories.isEmpty {
                    ContentUnavailableView("История уже исчезла", systemImage: "clock", description: Text("Истории доступны 24 часа."))
                } else {
                    HStack(spacing: 5) {
                        ForEach(stories) { story in
                            Capsule().fill(.white.opacity(page == story.id ? 0.95 : 0.18)).frame(height: 3)
                        }
                    }.padding(.horizontal, 24)
                    TabView(selection: $page) {
                        ForEach(stories) { story in
                            ScrollView { StoryCard(story: story).padding(22).softAppear() }.tag(story.id)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                    Text("Листай в стороны · копии могут быть сохранены получателями").font(.caption2).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
            .onAppear { if page.isEmpty { page = stories.first?.id ?? "" } }
            .onChange(of: stories.map(\.id)) { _, ids in if !ids.contains(page) { page = ids.first ?? "" } }
            .animation(reduceMotion ? nil : Motion.layout, value: stories.map(\.id))
        }
        .background { VoidBackground() }
        .navigationTitle(author == store.myID ? "Твои истории" : store.name(author))
        .navigationBarTitleDisplayMode(.inline)
    }
}
struct StoriesStrip: View {
    @EnvironmentObject var store: ChatStore
    private var authors: [String] { Array(Set(store.social.stories.filter { $0.expiresAt > Date() }.map(\.author))).sorted() }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(authors, id: \.self) { author in
                    NavigationLink { StoryViewerView(author: author) } label: {
                        VStack(spacing: 7) {
                            Avatar(name: store.name(author), size: 44, imageData: author == store.myID ? store.state.profileAvatar : store.social.profiles[author]?.avatar)
                                .clipShape(Circle()).padding(4).overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1.5))
                            Text(author == store.myID ? "Ты" : store.name(author)).font(.caption2).lineLimit(1).frame(width: 66)
                        }
                    }.buttonStyle(MotionButtonStyle()).transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }.padding(.vertical, 4)
        }
        .frame(height: authors.isEmpty ? 0 : 84)
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
