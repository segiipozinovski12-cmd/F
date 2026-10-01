import SwiftUI

struct ContactsView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var adding = false
    @State private var search = ""
    @State private var room: Room?
    @State private var contactFilter = "Все"

    private var contacts: [Contact] {
        store.state.contacts.filter {
            let match = contactFilter=="Все" || (contactFilter=="Избранные" && store.extended.favorites.contains($0.id)) || (contactFilter=="Проверенные" && $0.verified) || (contactFilter=="Блокировки" && $0.blocked)
            return match && (search.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.card.shortID.localizedCaseInsensitiveContains(search))
        }.sorted { a,b in
            let af=store.extended.favorites.contains(a.id), bf=store.extended.favorites.contains(b.id)
            return af != bf ? af : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("VO1D / PEOPLE").font(.caption2.monospaced()).tracking(2.5).foregroundStyle(Theme.secondary)
                                Text("Люди").font(.system(size: 34, weight: .black, design: .rounded)).tracking(-1)
                            }
                            Spacer()
                            Button { adding = true } label: {
                                Image(systemName: "plus")
                                    .font(.title3.bold())
                                    .frame(width: 48, height: 48)
                                    .background(.white, in: Circle())
                                    .foregroundStyle(.black)
                            }
                        }

                        HStack(spacing: 11) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                            TextField("Ник, ID или XROSB", text: $search)
                                .textInputAutocapitalization(.never)
                        }
                        .voidField()

                        Picker("Контакты",selection:$contactFilter) {
                            ForEach(["Все","Избранные","Проверенные","Блокировки"],id:\.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented)
                        NavigationLink {
                            MyIdentityView()
                        } label: {
                            HStack(spacing: 14) {
                                BrandMark(size: 48)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("ТВОЙ VO1D ID").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                                    Text(store.state.publicCode ?? "----")
                                        .font(.system(size: 21, weight: .black, design: .monospaced))
                                        .tracking(4)
                                }
                                Spacer()
                                Image(systemName: "qrcode")
                            }
                            .panel()
                        }
                        .buttonStyle(.plain)

                        if contacts.isEmpty {
                            VStack(spacing: 17) {
                                BrandMark(size: 76)
                                Text(search.isEmpty ? "Никого лишнего." : "Ничего не найдено.")
                                    .font(.title3.bold())
                                Text(search.isEmpty ? "Добавь человека по его 4-символьному VO1D ID или QR-приглашению." : "Попробуй другой ник или отпечаток.")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(4)
                                if search.isEmpty {
                                    Button("ДОБАВИТЬ ЧЕЛОВЕКА") { adding = true }
                                        .buttonStyle(PrimaryButton())
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                            .panel()
                        } else {
                            VStack(spacing: 10) {
                                ForEach(contacts) { contact in
                                    NavigationLink {
                                        ContactDetailView(contactID: contact.id)
                                    } label: {
                                        HStack(spacing: 14) {
                                            Avatar(name: contact.name)
                                            VStack(alignment: .leading, spacing: 5) {
                                                HStack(spacing: 6) {
                                                    Text(contact.name).font(.headline)
                                                    if store.isBuiltinBot(contact.id) {
                                                        Text("BOT")
                                                            .font(.system(size: 8, weight: .black, design: .monospaced))
                                                            .tracking(1)
                                                            .padding(.horizontal, 6)
                                                            .padding(.vertical, 3)
                                                            .background(.white, in: Capsule())
                                                            .foregroundStyle(.black)
                                                    } else if contact.verified {
                                                        Image(systemName: "checkmark.seal.fill").font(.caption)
                                                    }
                                                }
                                                Text(
                                                    store.isBuiltinBot(contact.id)
                                                        ? "XROSB · СИСТЕМНЫЙ КОНТАКТ"
                                                        : (contact.blocked ? "ЗАБЛОКИРОВАН" : contact.card.shortID)
                                                )
                                                    .font(.caption2.monospaced())
                                                    .tracking(1)
                                                    .foregroundStyle(Theme.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.secondary)
                                        }
                                        .panel()
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $adding) { AddContactView() }
            .navigationDestination(item: $room) { ChatView(roomID: $0.id) }
        }
    }
}

struct AddContactView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss
    var initialValue = ""
    @State private var value = ""
    @State private var scanning = false
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Wordmark(compact: true)
                        Spacer()
                        Button("Закрыть") { dismiss() }.foregroundStyle(Theme.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Найди своего.")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                        Text("Введи 4-символьный VO1D ID, специальный ключ XROSB, QR-приглашение или полный технический ID.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(4)
                    }

                    TextField("Например 7KQ2 или XROSB", text: $value)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .tracking(value.count <= 4 ? 4 : 0)
                        .voidField()
                        .onChange(of: value) { _, input in
                            if !input.hasPrefix("vo1d://") && input.count <= 8 {
                                value = input.uppercased().filter { $0.isLetter || $0.isNumber }
                            }
                        }

                    Button("СКАНИРОВАТЬ QR", systemImage: "qrcode.viewfinder") { scanning = true }
                        .buttonStyle(GhostButton())

                    if let failure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))
                            .padding(.horizontal, 3)
                    }

                    Button(busy ? "ИЩЕМ…" : "ДОБАВИТЬ") {
                        busy = true
                        Task {
                            do {
                                _ = try await store.addContact(value)
                                dismiss()
                            } catch {
                                failure = error.localizedDescription
                            }
                            busy = false
                        }
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)

                    Spacer()
                }
                .padding(24)
            }
            .onAppear { if value.isEmpty { value=initialValue } }
            .sheet(isPresented: $scanning) {
                QRScanner {
                    value = $0
                    scanning = false
                }
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button("Закрыть") { scanning = false }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct MyIdentityView: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(spacing: 22) {
                    BrandMark(size: 96)
                    Text(store.state.nickname).font(.title.bold())

                    VStack(alignment: .leading, spacing: 9) {
                        Text("VO1D ID").font(.caption2.monospaced()).tracking(2.2).foregroundStyle(Theme.secondary)
                        Text(store.state.publicCode ?? "----")
                            .font(.system(size: 32, weight: .black, design: .monospaced))
                            .tracking(6)
                            .textSelection(.enabled)
                        Text("Эти 4 символа можно отправить другу для поиска в VO1D.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()

                    if let invite = try? store.invite() {
                        QRCodeView(text: invite)
                            .frame(maxWidth: 285)
                        ShareLink(item: invite) {
                            Label("ПОДЕЛИТЬСЯ QR-ПРИГЛАШЕНИЕМ", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(PrimaryButton())
                    }
                    Button("СОЗДАТЬ ПРИВАТНОЕ ПРИГЛАШЕНИЕ") {
                        Task { do { try await store.preparePrivateInvite() } catch { store.error = error.localizedDescription } }
                    }.buttonStyle(.bordered)
                    Text("Приватное приглашение действует час и используется один раз. Оно содержит адрес доставки и одноразовые ключи, зашифрованные ключом из ссылки.")
                        .font(.caption).foregroundStyle(Theme.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("ТЕХНИЧЕСКИЙ ОТПЕЧАТОК").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                        Text(store.myID).font(.caption2.monospaced()).textSelection(.enabled)
                        Text("Он связан с публичным ключом. Приватный ключ в QR и приглашение не включается.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
                }
                .padding(24)
            }
        }
        .navigationTitle("Личность")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ContactDetailView: View {
    var contactID: String
    @EnvironmentObject private var store: ChatStore
    @State private var room: Room?
    @State private var alias = ""

    private var contact: Contact? { store.state.contacts.first { $0.id == contactID } }

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                if let contact {
                    VStack(spacing: 18) {
                        VStack(spacing: 12) {
                            Avatar(name: contact.name, size: 82)
                            HStack(spacing: 8) {
                                Text(contact.name).font(.title2.bold())
                                if store.isBuiltinBot(contact.id) {
                                    Text("BOT")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .tracking(1)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(.white, in: Capsule())
                                        .foregroundStyle(.black)
                                }
                            }
                            Text(store.isBuiltinBot(contact.id) ? "XROSB" : contact.card.shortID)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)

                        if !store.isBuiltinBot(contactID) {
                            NavigationLink("ПРИВАТНОСТЬ И ПРОВЕРКА QR") { ContactPrivacyView(contactID:contactID) }
                        }
                        Button("НАПИСАТЬ СООБЩЕНИЕ", systemImage: "bubble.left.fill") {
                            do { room = try store.direct(contact) }
                            catch { store.error = error.localizedDescription }
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(contact.blocked)

                        if !store.isBuiltinBot(contact.id) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ЛОКАЛЬНОЕ ИМЯ").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                                TextField("Имя", text: $alias).voidField()
                                Button("СОХРАНИТЬ") {
                                    guard let index = store.state.contacts.firstIndex(where: { $0.id == contactID }),
                                          !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                    let clean = String(alias.prefix(40))
                                    store.state.contacts[index].name = clean
                                    for roomIndex in store.state.rooms.indices
                                    where !store.state.rooms[roomIndex].isGroup &&
                                          store.state.rooms[roomIndex].members.contains(where: { $0.id == contactID }) {
                                        store.state.rooms[roomIndex].title = clean
                                    }
                                    store.persist()
                                }
                                .buttonStyle(GhostButton())
                            }
                            .panel()
                        }

                        if !store.isBuiltinBot(contact.id) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ПРОВЕРКА").font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                            Text(contact.id).font(.caption2.monospaced()).textSelection(.enabled)
                            Toggle("Отпечаток сверен", isOn: Binding(
                                get: { contact.verified },
                                set: { value in
                                    if let index = store.state.contacts.firstIndex(where: { $0.id == contactID }) {
                                        store.state.contacts[index].verified = value
                                        store.persist()
                                        Task { try? await store.trustOnServer(contactID,trusted:store.extended.trustedIDs.contains(contactID)) }
                                    }
                                }
                            ))
                            .tint(.white)
                            Text("Сверяй полный отпечаток по уже доверенному каналу. Ник и короткий ID сами по себе не доказывают личность.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                            .panel()

                            Button(contact.blocked ? "РАЗБЛОКИРОВАТЬ" : "ЗАБЛОКИРОВАТЬ") {
                                Task { await store.toggleBlock(contact) }
                            }
                            .buttonStyle(GhostButton())
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("СИСТЕМНЫЙ КОНТАКТ")
                                    .font(.caption2.monospaced())
                                    .tracking(2)
                                    .foregroundStyle(Theme.secondary)
                                Text("VO1D Bot работает локально внутри приложения и не является обычным сетевым пользователем.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                                    .lineSpacing(4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .panel()
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Контакт")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { alias = contact?.name ?? "" }
        .navigationDestination(item: $room) { ChatView(roomID: $0.id) }
    }
}
