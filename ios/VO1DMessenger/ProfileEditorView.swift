import SwiftUI
import PhotosUI
import UIKit

struct ProfileEditorView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var status = ""
    @State private var avatar: Data?
    @State private var photo: PhotosPickerItem?
    @State private var busy = false
    @State private var notice: String?
    @State private var audience = Set<String>()
    @State private var decoration = ProfileDecoration()
    @State private var duration = 0
    @State private var premiumPlan = false
    @State private var section = 0
    @State private var featuredID: String?
    @State private var editorFence: SessionFence?
    init(initialSection: Int = 0) { _section = State(initialValue: initialSection) }
    private let accent = Color.artifactHex(0xC7B4F1)
    private var gifts: [CollectibleArtifact] { store.economy.owner == store.myID ? store.economy.artifacts.filter(\.visible) : [] }
    private var featured: CollectibleArtifact? {
        if featuredID == "" { return nil }
        return gifts.first { $0.id == featuredID } ?? gifts.first
    }
    private var contacts: [Contact] {
        store.state.contacts.filter { !$0.blocked && $0.isBot != true && !store.isBuiltinBot($0.id) && store.extended.trustedIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                preview
                HStack(spacing: 5) {
                    tab("Профиль", icon: "person", value: 0)
                    tab("Стиль", icon: "sparkles", value: 1)
                    tab("Видимость", icon: "eye", value: 2)
                }.padding(5).background(.white.opacity(0.045), in: Capsule())
                if let notice { EconomyNotice(message: notice) }
                if section == 0 { identityFields }
                else if section == 1 { styleFields }
                else { sharingFields }
            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 22)
        }
        .background { VoidBackground() }
        .navigationTitle("Твой профиль").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark").font(.caption.bold()).padding(10).background(.white.opacity(0.07), in: Circle()) }.disabled(busy).accessibilityLabel("Закрыть редактор") } }
        .safeAreaInset(edge: .bottom) {
            Button { save() } label: {
                HStack(spacing: 9) { if busy { ProgressView().tint(.black) }; Text(busy ? "Сохраняем…" : "Сохранить профиль"); if !busy { Image(systemName: "checkmark") } }
            }.buttonStyle(PrimaryButton()).disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 22).padding(.vertical, 12).background(.ultraThinMaterial)
        }
        .interactiveDismissDisabled(busy)
        .onAppear { loadDraft() }
        .onChange(of: store.profileID) { _, _ in dismiss() }
        .onChange(of: store.locked) { _, locked in if locked { dismiss() } }
        .sheet(isPresented: $premiumPlan) { NavigationStack { PremiumPlanView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { premiumPlan = false } } } } }
        .onChange(of: photo) { _, item in
            guard let item, let fence = editorFence else { return }
            busy = true
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

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottom) {
                ProfileCover(decoration: decoration).frame(height: 158)
                    .overlay(alignment: .topLeading) { Label("ПРЕДПРОСМОТР", systemImage: "eye").font(.system(size: 9, weight: .semibold)).tracking(1.4).padding(17).foregroundStyle(.white.opacity(0.8)) }
                    .overlay(alignment: .topTrailing) {
                        if let featured { ArtifactArtwork(collection: featured.collection, traits: featured.traits).frame(width: 116, height: 116).rotationEffect(.degrees(12)).padding(8).accessibilityHidden(true) }
                    }.clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                PhotosPicker(selection: $photo, matching: .images) {
                    Avatar(name: name, size: 94, imageData: avatar).clipShape(Circle()).padding(5).background(.black, in: Circle())
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "camera.fill").font(.caption).foregroundStyle(.black).frame(width: 31, height: 31).background(accent, in: Circle()).overlay(Circle().stroke(.black, lineWidth: 3)) }
                }.buttonStyle(MotionButtonStyle()).offset(y: 39).accessibilityLabel("Изменить фото профиля")
            }.padding(.bottom, 38)
            HStack(spacing: 7) {
                Text(name.isEmpty ? "Твоё имя" : name).font(.system(size: 25, weight: .bold, design: .rounded)).lineLimit(2).multilineTextAlignment(.center)
                if store.hasPremium { Image(systemName: "seal.fill").foregroundStyle(accent).accessibilityLabel("Premium") }
            }
            if !username.isEmpty { Text("@" + username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))).font(.subheadline).foregroundStyle(.secondary) }
            if !status.isEmpty || decoration.activeSymbol != nil {
                HStack(spacing: 6) { if let symbol = decoration.activeSymbol { Image(systemName: symbol).foregroundStyle(accent) }; if !status.isEmpty { Text(status) } }
                    .font(.caption.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 8).background(.white.opacity(0.055), in: Capsule())
            }
        }.frame(maxWidth: .infinity)
    }
    private func tab(_ title: String, icon: String, value: Int) -> some View {
        Button { withAnimation(reduceMotion ? nil : Motion.layout) { section = value } } label: {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(section == value ? Color.black : .white.opacity(0.65)).background(section == value ? accent : .clear, in: Capsule())
        }.buttonStyle(MotionButtonStyle()).accessibilityAddTraits(section == value ? .isSelected : [])
    }
    private var identityFields: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) { fieldTitle("Как тебя называть", counter: "\(name.count)/40"); TextField("Имя", text: $name).textContentType(.nickname).voidField().onChange(of: name) { _, value in name = String(value.prefix(40)) } }
            VStack(alignment: .leading, spacing: 8) {
                fieldTitle("Адрес профиля")
                HStack(spacing: 8) { Text("@").foregroundStyle(accent); TextField("username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.state.username == "vo1d"); if store.state.username == "vo1d" { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) } }.voidField()
                if store.state.username == "vo1d" { Text("Постоянный адрес основателя").font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 8) { fieldTitle("Пара слов о тебе", counter: "\(bio.count)/160"); TextField("Чем живёшь, что любишь…", text: $bio, axis: .vertical).lineLimit(3...6).voidField().onChange(of: bio) { _, value in bio = String(value.prefix(160)) } }
            VStack(alignment: .leading, spacing: 8) { fieldTitle("Сейчас", counter: "\(status.count)/32"); TextField("На своей орбите", text: $status).voidField().onChange(of: status) { _, value in status = String(value.prefix(32)) } }
            if avatar != nil { Button("Убрать фото", role: .destructive) { avatar = nil }.font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8) }
        }
    }
    private var styleFields: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 14) {
                fieldTitle("Твоя палитра")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(ProfileDecoration.covers, id: \.self) { cover in
                            let option = ProfileDecoration(cover: cover)
                            Button { if option.premium && !store.hasPremium { premiumPlan = true } else { decoration.cover = cover; Haptics.light() } } label: {
                                VStack(spacing: 9) {
                                    Circle().fill(LinearGradient(colors: option.colors, startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 58, height: 58)
                                        .overlay { if decoration.cover == cover { Image(systemName: "checkmark").font(.headline).foregroundStyle(.white) } }
                                        .padding(4).overlay(Circle().stroke(decoration.cover == cover ? accent : .clear, lineWidth: 2))
                                    HStack(spacing: 3) { Text(option.title); if option.premium { Image(systemName: "sparkles") } }.font(.system(size: 10, weight: .medium))
                                }
                            }.buttonStyle(MotionButtonStyle()).accessibilityLabel(option.title).accessibilityAddTraits(decoration.cover == cover ? .isSelected : [])
                        }
                    }.padding(.vertical, 3)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                fieldTitle("Настроение", counter: "Premium")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 13) {
                    mood(nil)
                    ForEach(ProfileDecoration.symbols, id: \.self) { mood($0) }
                }
                if decoration.symbol != nil { Picker("Срок статуса", selection: $duration) { Text("Сохранить срок").tag(0); Text("1 час").tag(3600); Text("8 часов").tag(28800); Text("Сутки").tag(86400); Text("Без срока").tag(-1) }.tint(accent).padding(.horizontal, 10).background(.white.opacity(0.04), in: Capsule()) }
            }
            if !gifts.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    fieldTitle("Подарок на обложке")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            Button { featuredID = "" } label: { Image(systemName: "minus").font(.title3).frame(width: 74, height: 74).background(.white.opacity(0.05), in: Circle()).overlay(Circle().stroke(featuredID == "" ? accent : .clear, lineWidth: 2)) }.accessibilityLabel("Без подарка")
                            ForEach(gifts) { gift in
                                Button { featuredID = gift.id; Haptics.light() } label: {
                                    VStack(spacing: 4) { ArtifactArtwork(collection: gift.collection, traits: gift.traits).frame(width: 74, height: 74).background(.white.opacity(0.035), in: Circle()).overlay(Circle().stroke(featured?.id == gift.id ? accent : .clear, lineWidth: 2)); Text(gift.number).font(.caption2.monospaced()) }
                                }.accessibilityLabel(gift.title + " " + gift.number)
                            }
                        }.padding(3)
                    }.buttonStyle(MotionButtonStyle())
                }
            }
        }
    }
    private func mood(_ symbol: String?) -> some View {
        Button {
            if symbol != nil && !store.hasPremium { premiumPlan = true }
            else { decoration.symbol = symbol; if duration == 0 { duration = -1 }; Haptics.light() }
        } label: { Image(systemName: symbol ?? "minus").font(.system(size: 21)).frame(maxWidth: .infinity).frame(height: 52).foregroundStyle(decoration.symbol == symbol ? Color.black : .white).background(decoration.symbol == symbol ? accent : .white.opacity(0.055), in: Circle()) }
            .buttonStyle(MotionButtonStyle()).accessibilityLabel(symbol.map(ProfileDecoration.symbolTitle) ?? "Без значка").accessibilityAddTraits(decoration.symbol == symbol ? .isSelected : [])
    }
    private var sharingFields: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 12) { Image(systemName: "lock.shield").font(.title2).foregroundStyle(accent); VStack(alignment: .leading, spacing: 7) { Text(audience.isEmpty ? "Пока только для тебя" : "Увидят выбранные · \(audience.count)").font(.headline); Text("Имя, фото, описание и оформление отправятся выбранным доверенным контактам в зашифрованном виде.").font(.callout).foregroundStyle(.secondary).lineSpacing(3) } }
            ForEach(contacts) { contact in
                Toggle(isOn: Binding(get: { audience.contains(contact.id) }, set: { if $0 { audience.insert(contact.id) } else { audience.remove(contact.id) } })) {
                    HStack(spacing: 12) { Avatar(name: contact.name, size: 42); Text(contact.name).font(.subheadline) }
                }.tint(accent).padding(.vertical, 5)
            }
            if contacts.isEmpty { Text("Здесь появятся контакты, которым ты доверяешь.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12) }
        }
    }
    private func fieldTitle(_ title: String, counter: String? = nil) -> some View {
        HStack { Text(title).font(.subheadline.weight(.semibold)); Spacer(); if let counter { Text(counter).font(.caption.monospacedDigit()).foregroundStyle(.secondary) } }.padding(.horizontal, 3)
    }
    private func loadDraft() {
        guard editorFence == nil else { return }
        editorFence = store.sessionFence
        name = store.state.nickname; username = store.state.username ?? ""; bio = store.state.bio ?? ""
        status = store.social.status; avatar = store.state.profileAvatar
        decoration = (store.social.decoration ?? ProfileDecoration()).allowed(premium: store.hasPremium)
        featuredID = store.social.featuredGiftID
    }
    private func save() {
        guard let fence = editorFence, !busy else { return }
        busy = true; notice = nil
        Task {
            defer { busy = false }
            do {
                try store.requireCurrentSession(fence)
                guard !store.locked, store.sessionUnlocked else { throw CancellationError() }
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
                    var social = store.social; social.status = status; social.featuredGiftID = featuredID
                    var style = decoration.allowed(premium: store.hasPremium)
                    if duration > 0 { style.statusUntil = Date().addingTimeInterval(Double(duration)) }
                    else if duration == -1 { style.statusUntil = nil }
                    try style.validate(); social.decoration = style; store.state.social = social
                    try store.shareProfile(with: audience); try store.save()
                } catch { store.state = previous; throw error }
                Task { await store.sync() }; Haptics.success(); dismiss()
            } catch is CancellationError { return }
            catch { notice = error.localizedDescription }
        }
    }
}
