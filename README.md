# VO1D Messenger 2 · work branch

Нативный мессенджер для iPhone и iPad, SwiftUI, iOS 17+. Личность без номера, почты и загрузки адресной книги. Новые сообщения используют официальный libsignal PQXDH/Double Ratchet; есть встроенный Tor и private capability delivery. Интерфейс — глубокий чёрный и белый. Независимый аудит не проводился, полная анонимность не гарантируется.

## Запуск

```bash
git clone --recurse-submodules --branch codex/anonymous-v2 https://github.com/segiipozinovski12-cmd/F.git VO1D-Messenger
cd VO1D-Messenger
brew install protobuf cmake ninja
rustup toolchain install nightly-2025-02-25
rustup target add --toolchain nightly-2025-02-25 aarch64-apple-ios-sim aarch64-apple-ios
bash scripts/build_signal.sh aarch64-apple-ios-sim debug
open ios/VO1DMessenger.xcodeproj
```

Нужны macOS, Xcode и Rust/rustup. Выбери схему `VO1DMessenger` и arm64 симулятор; Debug связывается с собранным native SDK. Для Release устройства сначала выполни `bash scripts/build_signal.sh aarch64-apple-ios release`, затем настрой Team/Bundle Identifier/Push Notifications. Apple credentials отсутствуют. Relay должен быть из этой же ветки и отвечать на `/v2/capabilities`; публикация исходников не обновляет production-сервер. Закреплённый libsignal имеет AGPL-3.0-only; notices включены в приложение.

Статус всех 60 пунктов и оставшаяся работа: **[docs/ANONYMITY-V2.md](docs/ANONYMITY-V2.md)**. Там отдельно отмечены работающий код, исследования, частичные функции и внешние проверки.

## Возможности

- Личные чаты, управляемые группы и каналы, роли, опросы, текст, фото, файлы до 50 МБ, голосовые, аудиозвонки через зашифрованный WSS.
- Ответы, реакции, правки, удаление, пересылка, отложенная отправка, сохранённая очередь, повтор с задержкой, ошибки и отмена, продолжение загрузки ciphertext через HTTP Range.
- Папки, избранные контакты, закладки, черновики, шаблоны, локальные напоминания, ссылки, поиск, фильтры и переход к сообщению.
- Запросы от незнакомцев, согласие на группы, одноразовые приглашения со сроком и числом использований, отзыв, замена кода, отключение поиска.
- Псевдоним для каждого личного контакта, QR проверки ключей, скрытые чаты, нейтральные уведомления, настройки receipts/typing, временный буфер обмена.
- Проверка метаданных, фото без EXIF, редактор закрытия областей и поиска лиц, OCR на устройстве, подтверждение ссылок и удаление известных tracking-параметров.
- Официальный libsignal, атомарные one-time prekeys, сохранение ratchet state и ciphertext до отправки, запрет downgrade.
- Встроенный Tor/SOCKS5 для HTTP, файлов и WSS без прямого обхода при ошибке; отдельные scopes для capability соединений.
- Private QR, отдельные mailbox адреса разговоров, read/write capabilities и encrypted blobs без account bearer. Account bootstrap и звонки всё ещё раскрывают метаданные.
- До 12 независимых профилей с отдельными ключами; scoped contact/group profiles для раздельных личностей.
- Групповой pairwise fanout до 16 участников, epochs, подписанные приглашения с audience/expiry/отзывом; MLS не реализован.
- Режимы encrypted backup identity/history/full без старых ratchet sessions, локальная диагностика, protected temp cleanup и удаление одного профиля.
- Двусторонняя привязка второго устройства и отзыв; ручной E2EE перенос ограниченной text/poll истории в read-only archive, без live sync.
- Скрытый состав подписчиков в канале с одним публикующим владельцем; обычные группы раскрывают состав. В приватных опросах участники видят только счётчики, создатель видит индивидуальные голоса.

Полный перечень и фактический статус: [docs/FEATURES.md](docs/FEATURES.md).

## Локальный relay

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --require-hashes -r server/requirements.lock
VO1D_DB=/tmp/vo1d.sqlite3 VO1D_BLOB_DIR=/tmp/vo1d-blobs python3 server/realtime.py
```

В двух arm64 симуляторах укажи `http://127.0.0.1:8080`, создай разные личности и обменяйся private QR приглашениями. HTTP доступен для loopback в Debug. Физическому iPhone нужен HTTPS либо v3 onion в явном Tor режиме.

## Сервер и push

```bash
cp .env.example .env
# Укажи свой домен в .env
docker compose up -d --build
```

Инструкции: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), [server/RAILWAY.md](server/RAILWAY.md). Опциональный onion origin — `compose.onion.yaml`. APNs/PushKit требуют ключ Apple, корректные entitlement/topic и physical QA. Фоновые звонки используют ограниченный делегированный calls-only ключ после первого разблокирования; корневые и message/vault keys остаются `WhenUnlockedThisDeviceOnly`. APNs и внешний браузер не используют прокси приложения. Private mailbox delivery без account association не имеет account push.

## Проверки

```bash
python3 -m unittest discover -s server/tests -v
python3 scripts/generate_project.py
xcodebuild test -project ios/VO1DMessenger.xcodeproj -scheme VO1DMessenger \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/scripts/Simulator.entitlements" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  LIBRARY_SEARCH_PATHS="$(pwd)/Vendor/libsignal/artifacts/iphonesimulator/Debug" \
  OTHER_LDFLAGS='-lsignal_ffi -lc++ -lresolv'
```

Выбери имя установленного симулятора. CI проверяет generated project, Debug/XCTest/unsigned device Release, сервер и Docker. Simulator использует отдельную локальную ad-hoc подпись для доступа к Keychain: `scripts/Simulator.entitlements` предназначен только для симулятора и не даёт Apple provisioning или APNs. Проверяется запуск хранилища и повторное чтение Keychain, а не только операции на созданных в памяти ключах. Python pins проходят dependency audit; build manifest и device archive публикуются как artifacts. Provenance не означает аудит безопасности или Apple подпись. Native/системные зависимости и Tor binary не дают полной bit-reproducibility.

## Ограничения

Новая переписка использует libsignal; legacy v1 history не приобретает forward secrecy задним числом. Outer mailbox encryption, profile/group/device integration и звонки ещё не прошли независимый аудит. Голос — собственный PCM/WSS transport с Apple resampling, а не RingRTC/WebRTC SDK. Wi-Fi/mobile reconnect реализован, но physical handover не проверен.

Private mailboxes не передают plaintext sender/account ID, но время, buckets, соединения и операторская корреляция остаются. Account discovery/обычная доставка/звонки сохраняют routing IDs. Padding/Tor не являются доказательством устойчивости к глобальному наблюдателю; нужны реальные DNS/packet captures. Удаление не стирает копии у получателей и host backups. Отложенная отправка и private inbox polling требуют возможности работы приложения. APNs/CallKit, visual QA и полный live multi-device sync ещё не завершены.

Модель угроз: [docs/SECURITY.md](docs/SECURITY.md). Протокол: [docs/PROTOCOL-V2.md](docs/PROTOCOL-V2.md). Пакет аудита: [docs/AUDIT-PACK.md](docs/AUDIT-PACK.md).
