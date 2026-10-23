import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: ChatStore
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

                        NavigationLink { ProfileScreenView(owner: store.myID) } label: {
                            HStack(spacing: 14) {
                                Avatar(name: store.state.nickname, size: 58, imageData: store.state.profileAvatar)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(store.state.nickname).font(.headline)
                                    Text("Профиль, истории и подарки").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.panel()
                        }.buttonStyle(MotionButtonStyle()).softAppear(index: 0)
                        NavigationLink { AppearanceSettingsView() } label: {
                            Label("ОФОРМЛЕНИЕ И ТЕМЫ", systemImage: "paintpalette")
                                .frame(maxWidth: .infinity, alignment: .leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        NavigationLink { ProfilesView() } label: {
                            Label("НЕЗАВИСИМЫЕ ЛИЧНОСТИ",systemImage:"person.crop.rectangle.stack")
                                .frame(maxWidth:.infinity,alignment:.leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        keysCard.softAppear(index: 1)
                        NavigationLink { NearbyView() } label: {
                            Label("СВЯЗЬ РЯДОМ БЕЗ ИНТЕРНЕТА", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity, alignment: .leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        NavigationLink { BotFatherView() } label: {
                            Label("@vo1d_bot_father · МОИ БОТЫ", systemImage: "terminal")
                                .frame(maxWidth: .infinity, alignment: .leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        NavigationLink { ReportCenterView() } label: {
                            Label("ЖАЛОБЫ И МОДЕРАЦИЯ", systemImage: "flag")
                                .frame(maxWidth: .infinity, alignment: .leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        NavigationLink { NextSecurityCenterView() } label: {
                            Label("SECURITY CHECK И TRUST CIRCLE", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity, alignment: .leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        NavigationLink {
                            ToolsCenterView()
                        } label: {
                            Label("ПРИВАТНОСТЬ И ИНСТРУМЕНТЫ",systemImage:"lock.shield")
                                .frame(maxWidth:.infinity,alignment:.leading).panel()
                        }.buttonStyle(MotionButtonStyle())
                        privacyCard.softAppear(index: 2)
                        retentionCard.softAppear(index: 3)
                        voiceCard.softAppear(index: 4)
                        callsCard.softAppear(index: 5)
                        relayCard.softAppear(index: 6)
                        emergencyCard.softAppear(index: 7)
                        vpnCard.softAppear(index: 8)
                        legalCard.softAppear(index: 9)
                        deleteCard.softAppear(index: 10)

                        HStack {
                            Spacer()
                            VStack(spacing: 5) {
                                Wordmark(compact: true)
                                Text("PRIVATE MESSAGING LAYER · 2.0").font(.system(size: 8, design: .monospaced)).tracking(1.6).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }
                    .padding(22)
                    .softAppear()
                }
            }
            .navigationBarHidden(true)
            .labelStyle(FeatureLabelStyle())
            .task { await store.refreshPushStatus() }
            .confirmationDialog("Удалить аккаунт?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Удалить аккаунт и локальные ключи", role: .destructive) {
                    Task { await store.deleteAccount() }
                }
            } message: {
                Text("Будет отправлен запрос на удаление серверной записи, затем локальное зашифрованное хранилище и Keychain будут очищены. Копии, сохранённые другими людьми, приложение удалить не может.")
            }
        }
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

            Toggle("Запрашивать ключ при запуске", isOn: Binding(
                get: { store.preferences.requireAccessKey },
                set: { store.setRequireAccessKey($0) }
            ))
            Text("Если выключить, история откроется сразу после запуска. Face ID можно оставить включённым отдельно.")
                .font(.caption2).foregroundStyle(Theme.secondary)

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

            Toggle("Уведомления о новых сообщениях", isOn: Binding(
                get: { store.state.notificationsEnabled == true },
                set: { value in Task { await store.setNotifications(value) } }
            ))
            .tint(.white)

            Text(store.pushStatus.isEmpty ? "Проверяем готовность уведомлений…" : store.pushStatus)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)

            NavigationLink("КОМПОНЕНТЫ И ЛИЦЕНЗИИ") { DependencyNoticesView() }
            NavigationLink("КАК ЗАЩИЩЕНЫ СООБЩЕНИЯ") { PrivacyView() }
                .buttonStyle(GhostButton())
        }
        .panel()
    }

    private var retentionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("АВТОУДАЛЕНИЕ ЧАТОВ", icon: "timer")
            Picker("После отсутствия новых сообщений", selection: store.preferenceBinding(\.autoDeleteChatsSeconds)) {
                Text("Выключено").tag(0)
                Text("1 час").tag(3600)
                Text("24 часа").tag(86400)
                Text("7 дней").tag(604800)
                Text("30 дней").tag(2592000)
            }.tint(.white)
            Text("Удаляет неактивный чат и его историю на этом устройстве при следующем открытии или синхронизации. Открытый чат, черновики и неотправленные сообщения сохраняются. Копии у собеседника остаются.")
                .font(.caption2).foregroundStyle(Theme.secondary)
        }.panel()
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
                .buttonStyle(MotionButtonStyle())

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

    private var callsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("ЗВОНКИ", icon: "phone.fill")

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("История звонков")
                        .font(.subheadline.bold())
                    Text("\(store.callRecords().count) записей на этом устройстве")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.secondary)
            }

            NavigationLink {
                CallHistoryView()
            } label: {
                HStack {
                    Text("ОТКРЫТЬ ИСТОРИЮ")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }
            .buttonStyle(GhostButton())

            Text("История звонков хранится локально в зашифрованном хранилище VO1D.")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
        }
        .panel()
    }

    private var relayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("СОЕДИНЕНИЕ", icon: "point.3.connected.trianglepath.dotted")

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.08))
                        .frame(width: 42, height: 42)
                    Circle()
                        .fill(store.connection == "Подключён" ? .white : .white.opacity(0.28))
                        .frame(width: 9, height: 9)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.connection == "Подключён" ? "VO1D ONLINE" : "VO1D CONNECTION")
                        .font(.subheadline.bold().monospaced())
                    Text(store.connection.uppercased())
                        .font(.caption2.monospaced())
                        .tracking(1.4)
                        .foregroundStyle(Theme.secondary)
                }

                Spacer()
            }

            HStack {
                Text("Очередь отправки")
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(store.state.outbox.count)")
                    .font(.caption.monospaced())
            }

            Button(store.busy ? "ПОДКЛЮЧЕНИЕ…" : "ПЕРЕПОДКЛЮЧИТЬ") {
                Task { await store.connectProductionRelay() }
            }
            .buttonStyle(GhostButton())
            .disabled(store.busy)
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
            Text("Жалобы передают только выбранные с согласия доказательства. Боты могут читать адресованные им сообщения. Relay хранит идентификаторы, маршрутизацию и данные согласия на звонки.")
                .font(.caption).foregroundStyle(Theme.secondary)
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
            Image(systemName: icon).symbolVariant(.fill)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
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

struct CallHistoryView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var showClear = false

    var body: some View {
        ZStack {
            VoidBackground()

            if store.callRecords().isEmpty {
                ContentUnavailableView(
                    "История пуста",
                    systemImage: "phone",
                    description: Text("Здесь появятся входящие, исходящие и пропущенные VO1D-звонки.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.callRecords()) { record in
                            HStack(spacing: 13) {
                                ZStack {
                                    Circle()
                                        .fill(.white.opacity(0.07))
                                        .frame(width: 46, height: 46)
                                    Image(systemName: icon(record))
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.peerName)
                                        .font(.headline)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        Text(title(record))
                                        if record.duration > 0 {
                                            Text("·")
                                            Text(String(format: "%d:%02d", record.duration / 60, record.duration % 60))
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondary)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(record.endedAt, style: .time)
                                        .font(.caption2.monospaced())
                                    Text(record.endedAt, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                            .panel()
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Звонки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.callRecords().isEmpty {
                Button("Очистить") { showClear = true }
            }
        }
        .confirmationDialog("Очистить локальную историю звонков?", isPresented: $showClear) {
            Button("Очистить", role: .destructive) {
                store.clearCallHistory()
            }
        }
    }

    private func icon(_ record: CallRecord) -> String {
        if record.status == "missed" { return "phone.down.fill" }
        return record.incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"
    }

    private func title(_ record: CallRecord) -> String {
        switch record.status {
        case "completed":
            return record.incoming ? "Входящий" : "Исходящий"
        case "missed":
            return "Пропущенный"
        case "declined":
            return "Отклонён"
        case "unanswered":
            return "Без ответа"
        case "cancelled":
            return "Отменён"
        case "interrupted":
            return "Прерван"
        default:
            return "Ошибка"
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
                ("Метаданные", "Приватные адреса скрывают ID участников от очереди. Обычная доставка, поиск по коду и регистрация используют ID. Relay видит адрес подключения, время и размеры; Tor уменьшает раскрытие IP, но не устраняет корреляцию."),
                ("Ключи", "Приватные ключи хранятся в iOS Keychain. История хранится в зашифрованном локальном vault и исключается из резервного копирования приложения."),
                ("Ограничения", "Собеседник может сохранить сообщение или сделать снимок экрана. Приложение не способно удалить такие внешние копии."),
                ("Протокол", "Новые сообщения используют PQXDH и Double Ratchet из libsignal. Приватная доставка дополняет их оболочкой CryptoKit. Интеграция приложения пока не проходила независимый аудит.")
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
                ("2. Сообщения", "Содержимое переписки шифруется на устройстве. Relay хранит шифротекст и ограниченные данные доставки, регистрации, поиска, звонков и согласия. Модерация не получает общий ключ к перепискам."),
                ("3. Технические данные", "Для работы сервиса сервер неизбежно обрабатывает сетевой IP и ограниченные метаданные соединения. Они не являются содержимым переписки."),
                ("4. Локальное хранение", "Криптографические ключи хранятся в Keychain, а история — в зашифрованном vault с защитой файлов iOS."),
                ("5. Удаление", "Удаление аккаунта очищает локальные данные и запрашивает удаление серверной записи при доступном relay. Решения и ограниченный аудит могут сохраняться для безопасности и апелляций. Для @vo1d сохраняются публичное закрепление владельца и проверенная MFA. Копии у других пользователей не уничтожаются."),
                ("Жалобы", "Ты сам выбираешь доказательства и даёшь согласие. Выбранный текст, комментарий и файлы шифруются для @vo1d; модератор сможет их прочитать и сохранить. Relay видит ID, причину, время и размер жалобы. Доказательства на relay хранятся до 7 дней, сведения о деле — до 90 дней. Аудит ограничен 50 000 событиями."),
                ("Боты", "Бот является отдельным участником: его владелец и исполнитель могут читать сообщения, адресованные боту. Это не даёт им доступ к другим чатам. Relay видит регистрацию бота и связь с владельцем."),
                ("Подарки и платежи", "Сервер хранит баланс VO1Dcoin, владение, номера и свойства артефактов, операции и идентификаторы подтверждённых покупок App Store. Подарки в профиле и объявления на маркете доступны другим пользователям вместе с ID или username владельца. При удалении аккаунта платёжные номера остаются обезличенными для защиты от повторного зачисления."),
                ("Расшифровка голосовых", "В VO1D_PREMIUM речь распознаётся на устройстве. На сервер отправляется запрос проверки подписки без аудио и текста. При отсутствии локальной языковой модели запись не загружается в облачный сервис распознавания."),
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
                ("VO1Dcoin и подарки", "Монеты используются для покупок и улучшений внутри VO1D. Перед оплатой указана цена; списание и переход владения подтверждаются сервером. Продажа приносит VO1Dcoin. Вывод в деньги и перенос в блокчейн в этой версии не предусмотрены. Вероятности каждого свойства показаны перед улучшением; повторно изменить выпавшее сочетание нельзя. Оценка редкости не гарантирует цену продажи."),
                ("VO1D_PREMIUM", "Месячная подписка оплачивается и автоматически продлевается через App Store. Цена показана в валюте региона магазина. Управлять продлением можно в настройках подписок Apple. Расшифровка включена без дополнительного списания монет и зависит от доступности локальной модели языка на устройстве."),
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
