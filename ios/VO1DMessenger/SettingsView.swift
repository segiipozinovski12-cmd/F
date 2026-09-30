import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var name = ""
    @State private var server = ""
    @State private var setupCode = ""
    @State private var resetCode = ""
    @State private var showDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("НАСТРОЙКИ").font(.caption2.monospaced()).tracking(3).foregroundStyle(Theme.secondary)
                                Text("Твоё пространство").font(.system(size: 32, weight: .black, design: .rounded)).tracking(-1)
                            }
                            Spacer()
                            BrandMark(size: 54)
                        }
                        .padding(.bottom, 4)

                        profileCard
                        keysCard
                        privacyCard
                        voiceCard
                        relayCard
                        emergencyCard
                        vpnCard
                        legalCard
                        deleteCard

                        HStack {
                            Spacer()
                            VStack(spacing: 5) {
                                Wordmark(compact: true)
                                Text("PRIVATE MESSAGING LAYER · 1.1").font(.system(size: 8, design: .monospaced)).tracking(1.6).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                    .padding(22)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                name = store.state.nickname
                server = store.state.server
            }
            .confirmationDialog("Удалить аккаунт?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Удалить аккаунт и локальные ключи", role: .destructive) {
                    Task { await store.deleteAccount() }
                }
            } message: {
                Text("Будет отправлен запрос на удаление серверной записи, затем локальное зашифрованное хранилище и Keychain будут очищены. Копии, сохранённые другими людьми, приложение удалить не может.")
            }
        }
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Avatar(name: store.state.nickname, size: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.state.nickname).font(.title3.bold())
                    Text("Ник не привязан к телефону или почте").font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }

            TextField("Ник", text: $name)
                .voidField()

            Button("СОХРАНИТЬ НИК") {
                let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                store.state.nickname = String(cleaned.prefix(40))
                store.persist()
            }
            .buttonStyle(GhostButton())
        }
        .panel()
    }

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("КЛЮЧИ", icon: "key.fill")
            keyRow("VO1D ID", store.state.publicCode ?? "----", "4 символа · поиск друзей")
            Divider().overlay(.white.opacity(0.08))
            keyRow("КЛЮЧ ДОСТУПА", store.state.accessKey ?? "---------", "9 символов · вход в приложение")
            NavigationLink {
                MyIdentityView()
            } label: {
                HStack {
                    Text("QR И ТЕХНИЧЕСКИЙ ОТПЕЧАТОК")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(GhostButton())
        }
        .panel()
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("ПРИВАТНОСТЬ", icon: "lock.shield.fill")

            Toggle("Face ID / код устройства", isOn: Binding(
                get: { store.state.appLock },
                set: { value in Task { await store.setLock(value) } }
            ))
            .tint(.white)

            Toggle("Отправлять статусы прочтения", isOn: Binding(
                get: { store.state.readReceipts },
                set: { store.state.readReceipts = $0; store.persist() }
            ))
            .tint(.white)

            NavigationLink("КАК ЗАЩИЩЕНЫ СООБЩЕНИЯ") { PrivacyView() }
                .buttonStyle(GhostButton())
        }
        .panel()
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("ГОЛОС", icon: "waveform.and.mic")

            Text("Выбранный профиль применяется к новым голосовым сообщениям перед отправкой.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(4)

            ForEach(VoiceEffect.allCases) { effect in
                Button {
                    store.setVoiceEffect(effect)
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: store.selectedVoiceEffect() == effect ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(effect.title).font(.subheadline.bold())
                            Text(effect.subtitle).font(.caption2).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Image(systemName: "waveform")
                            .foregroundStyle(.white.opacity(0.48))
                    }
                }
                .buttonStyle(.plain)

                if effect != .shadow {
                    Divider().overlay(.white.opacity(0.07))
                }
            }

            Text("Эффект меняет голос, но не является гарантией анонимности: по записи всё равно могут оставаться узнаваемые особенности речи.")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
        }
        .panel()
    }

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("RELAY", icon: "point.3.connected.trianglepath.dotted")
            TextField("https://chat.example.com", text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .voidField()

            Button(store.busy ? "ПОДКЛЮЧЕНИЕ…" : "ПОДКЛЮЧИТЬ RELAY") {
                Task { await store.configure(name: name, server: server) }
            }
            .buttonStyle(GhostButton())
            .disabled(store.busy || server.isEmpty)

            HStack {
                Text("Состояние").foregroundStyle(Theme.secondary)
                Spacer()
                Text(store.connection).font(.caption.monospaced())
            }
            HStack {
                Text("Очередь").foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(store.state.outbox.count)").font(.caption.monospaced())
            }
        }
        .panel()
    }

    private var emergencyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("ЭКСТРЕННЫЙ СБРОС", icon: "lock.rotation")
            Text("Задай отдельный 4-значный код. Ввод этого кода в поле ниже запускает немедленную очистку локального зашифрованного хранилища и Keychain; если relay доступен, приложение также отправит запрос на удаление аккаунта.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(4)

            SecureField("Новый 4-значный код", text: $setupCode)
                .keyboardType(.numberPad)
                .voidField()
                .onChange(of: setupCode) { _, value in setupCode = String(value.filter(\.isNumber).prefix(4)) }

            Button(store.state.panicCodeHash == nil ? "ЗАДАТЬ КОД" : "ИЗМЕНИТЬ КОД") {
                if store.setEmergencyCode(setupCode) { setupCode = "" }
            }
            .buttonStyle(GhostButton())
            .disabled(setupCode.count != 4)

            if store.state.panicCodeHash != nil {
                Divider().overlay(.white.opacity(0.08))
                SecureField("Код для немедленного сброса", text: $resetCode)
                    .keyboardType(.numberPad)
                    .voidField()
                    .onChange(of: resetCode) { _, value in resetCode = String(value.filter(\.isNumber).prefix(4)) }

                Button("ВЫПОЛНИТЬ ЭКСТРЕННЫЙ СБРОС") {
                    let code = resetCode
                    resetCode = ""
                    Task { _ = await store.emergencyReset(code: code) }
                }
                .buttonStyle(PrimaryButton())
                .disabled(resetCode.count != 4 || store.busy)
            }
        }
        .panel()
    }

    private var vpnCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                BrandMark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("VO1D_VPN").font(.headline.monospaced()).tracking(2)
                    Text("PRIVATE · SECURE · BORDERLESS").font(.system(size: 8, design: .monospaced)).tracking(1.5).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            Text("VPN от VO1D: VLESS + REALITY, TCP/443 и минимизированные сервисные журналы.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(4)

            Link(destination: URL(string: "https://t.me/VO1D_VPNbot")!) {
                HStack {
                    Text("ОТКРЫТЬ VO1D_VPN")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
            }
            .buttonStyle(GhostButton())
        }
        .panel()
    }

    private var legalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("ДОКУМЕНТЫ", icon: "doc.text.fill")
            NavigationLink("ПОЛИТИКА КОНФИДЕНЦИАЛЬНОСТИ") { PrivacyPolicyView() }
                .buttonStyle(GhostButton())
            NavigationLink("ПОЛЬЗОВАТЕЛЬСКОЕ СОГЛАШЕНИЕ") { TermsView() }
                .buttonStyle(GhostButton())
        }
        .panel()
    }

    private var deleteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("АККАУНТ", icon: "person.crop.circle.badge.minus")
            Text("Обычное удаление показывает подтверждение. Экстренный сброс выше работает отдельно.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Button("УДАЛИТЬ АККАУНТ И ДАННЫЕ") { showDelete = true }
                .buttonStyle(GhostButton())
        }
        .panel()
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title).font(.caption.monospaced()).tracking(2.2)
            Spacer()
        }
        .foregroundStyle(.white.opacity(0.82))
    }

    private func keyRow(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 24, weight: .black, design: .monospaced)).tracking(4).textSelection(.enabled)
            Text(detail).font(.caption2).foregroundStyle(Theme.secondary)
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        DocumentScreen(
            eyebrow: "SECURITY / E2EE",
            title: "Приватность\nбез магии.",
            sections: [
                ("Без телефона и почты", "Личность создаётся из случайных криптографических ключей на устройстве. Контакты телефона не запрашиваются."),
                ("Содержимое", "Текст, файлы, голосовые, реакции и события чатов шифруются на устройстве перед отправкой через relay."),
                ("Метаданные", "Relay может видеть сетевой IP, криптографические ID отправителя и получателя, время и размер трафика. Сквозное шифрование не скрывает эти метаданные."),
                ("Ключи", "Приватные ключи хранятся в iOS Keychain. История хранится в зашифрованном локальном vault и исключается из резервного копирования приложения."),
                ("Ограничения", "Собеседник может сохранить сообщение или сделать снимок экрана. Приложение не способно удалить такие внешние копии."),
                ("Протокол", "Текущая реализация использует X25519, HKDF-SHA256, AES-256-GCM и Ed25519 через CryptoKit. Протокол не заявляется как независимо аудированный.")
            ]
        )
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        DocumentScreen(
            eyebrow: "VO1D / PRIVACY POLICY",
            title: "Политика\nконфиденциальности",
            sections: [
                ("1. Что создаётся", "VO1D не требует номер телефона или адрес электронной почты. На устройстве создаются криптографическая личность, выбранный ник, публичный VO1D ID и локальный ключ доступа."),
                ("2. Сообщения", "Содержимое сообщений шифруется на устройстве. Relay хранит только зашифрованные конверты, необходимые для доставки, в пределах настроенного срока хранения."),
                ("3. Технические данные", "Для работы сервиса сервер неизбежно обрабатывает сетевой IP и ограниченные метаданные соединения. Они не являются содержимым переписки."),
                ("4. Локальное хранение", "Криптографические ключи хранятся в Keychain, а история — в зашифрованном vault с защитой файлов iOS."),
                ("5. Удаление", "Удаление аккаунта очищает данные приложения и запрашивает удаление серверной записи, когда relay доступен. VO1D не может уничтожить копии, которые другой пользователь сохранил отдельно."),
                ("6. Изменения", "Перед публикацией приложения владелец сервиса должен дополнить эту политику актуальными контактными данными, юрисдикцией и сроками хранения для своей инфраструктуры.")
            ]
        )
    }
}

struct TermsView: View {
    var body: some View {
        DocumentScreen(
            eyebrow: "VO1D / TERMS",
            title: "Пользовательское\nсоглашение",
            sections: [
                ("Использование", "VO1D предназначен для частного обмена сообщениями. Пользователь отвечает за законность отправляемого им содержимого и соблюдение правил своей юрисдикции."),
                ("Доступ", "Ключ доступа и криптографические ключи необходимо хранить самостоятельно. Потеря локальных ключей может означать потерю доступа к истории."),
                ("Без гарантий абсолютной анонимности", "Шифрование защищает содержимое, но сеть и relay всё равно обрабатывают технические метаданные. VO1D не обещает абсолютную сетевую анонимность."),
                ("Доступность", "Связь зависит от iOS, интернет-соединения и выбранного relay. Непрерывная доступность не гарантируется."),
                ("Безопасность", "Перед публичным запуском криптографический протокол и серверную инфраструктуру рекомендуется пройти независимый аудит."),
                ("Версия документа", "Эта встроенная версия является продуктовым черновиком для приложения и должна быть дополнена юридическими реквизитами владельца перед коммерческим релизом.")
            ]
        )
    }
}

private struct DocumentScreen: View {
    var eyebrow: String
    var title: String
    var sections: [(String, String)]

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(eyebrow).font(.caption2.monospaced()).tracking(2).foregroundStyle(Theme.secondary)
                    Text(title).font(.system(size: 36, weight: .black, design: .rounded)).tracking(-1.4)

                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(String(format: "%02d", index + 1)).font(.caption.monospaced()).foregroundStyle(Theme.secondary)
                            Text(section.0).font(.headline)
                            Text(section.1).font(.subheadline).foregroundStyle(Theme.secondary).lineSpacing(5)
                        }
                        .panel()
                    }
                }
                .padding(24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
