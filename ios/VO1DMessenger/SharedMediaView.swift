import SwiftUI
import QuickLook

struct SharedMediaView: View {
    let roomID: String
    @EnvironmentObject private var store: ChatStore
    @State private var category = 0
    @State private var preview: URL?

    private var messages: [ChatMessage] {
        store.messages(roomID).filter { $0.attachment != nil }
    }

    private var photos: [ChatMessage] {
        messages.filter {
            guard let attachment = $0.attachment else { return false }
            return attachment.mime.hasPrefix("image/") && attachment.viewSeconds == nil
        }
    }

    private var voices: [ChatMessage] {
        messages.filter { $0.attachment?.mime.hasPrefix("audio/") == true }
    }

    private var files: [ChatMessage] {
        messages.filter {
            guard let attachment = $0.attachment else { return false }
            return !attachment.mime.hasPrefix("image/") && !attachment.mime.hasPrefix("audio/")
        }
    }

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Категория", selection: $category) {
                        Text("Медиа").tag(0)
                        Text("Голос").tag(1)
                        Text("Файлы").tag(2)
                    }
                    .pickerStyle(.segmented)

                    if category == 0 {
                        photoGrid
                    } else if category == 1 {
                        voiceList
                    } else {
                        fileList
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Медиа и файлы")
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($preview)
        .onChange(of: preview) { _, value in if value == nil { MediaFiles.clear() } }
        .onDisappear { MediaFiles.clear() }
    }

    @ViewBuilder
    private var photoGrid: some View {
        if photos.isEmpty {
            empty("Нет общих фото", icon: "photo.on.rectangle")
        } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach(photos) { message in
                    if let attachment = message.attachment, let image = UIImage(data: attachment.data) {
                        Button {
                            do { preview = try MediaFiles.export(attachment) }
                            catch { store.error = error.localizedDescription }
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 118)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var voiceList: some View {
        if voices.isEmpty {
            empty("Нет голосовых", icon: "waveform")
        } else {
            LazyVStack(spacing: 10) {
                ForEach(voices) { message in
                    if let attachment = message.attachment {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(store.name(message.sender)).font(.caption.bold())
                                Spacer()
                                Text(message.createdAt, style: .time).font(.caption2.monospaced())
                            }
                            .foregroundStyle(Theme.secondary)
                            VoiceMessagePlayer(attachment: attachment, tint: .white)
                        }
                        .panel()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fileList: some View {
        if files.isEmpty {
            empty("Нет общих файлов", icon: "folder")
        } else {
            LazyVStack(spacing: 10) {
                ForEach(files) { message in
                    if let attachment = message.attachment {
                        Button {
                            do { preview = try MediaFiles.export(attachment) }
                            catch { store.error = error.localizedDescription }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "doc.fill")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(attachment.name).lineLimit(2)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(Theme.secondary)
                            }
                            .panel()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func empty(_ title: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle)
            Text(title).font(.headline)
            Text("Здесь появятся вложения из этого чата.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .panel()
    }
}
