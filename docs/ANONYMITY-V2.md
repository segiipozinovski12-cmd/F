# VO1D 2: implementation record

Work branch: `codex/anonymous-v2`, based on verified 1.3. No release or deployment is implied by this branch.

## Selected protocol dependency

Signal libsignal v0.70.0, commit `efe13e9b363d2c115dba61b76e5e53bbfc2874bc`, is pinned as a Git submodule. Upstream implements Double Ratchet/PQXDH, signed and one-time prekeys and sender keys. Its Swift API is not supported for third-party products and may change; pinning and interoperability tests are required. Upstream is AGPL-3.0-only; retain notices and fulfil applicable source/licence obligations when distributing. Integration and transport remain unaudited even when using an upstream protocol implementation.

## Delivery rules

- Plaintext queued events remain inside the encrypted local vault. The HTTP API must never serialize a deferred event.
- Advance session state and persist its exact ciphertext in one vault write before sending. Retry sends those same bytes, never re-encrypts the event.
- Existing v1 history remains readable. V2 conversations must not silently downgrade; missing bundles or changed keys stop delivery and show an actionable error.
- Receipt of an authenticated ciphertext and the resulting session state must be persisted before ACK. Failed authentication rolls back state.
- Metadata-minimizing transport requires separate capability mailboxes, isolated connections and private invitations. Signal message encryption alone does not hide routing metadata.

## Проверяемый остаток из 60 пунктов

Состояние на 30 сентября 2026 года. «Код» означает, что поведение реализовано в этой ветке; это не сертификат анонимности. «Частично» означает, что остаётся конкретная работа. «Исследование» закрывает исследовательский пункт документом с решением, а не работающей сетевой функцией. «Внешняя проверка» требует оборудования или доступа, которого у этой среды нет.

Итого: **37 пунктов с реализованным кодом, 5 документированных исследовательских/подготовительных пунктов, 16 частичных, 1 открытая интеграция и 1 внешняя проверка**. Остаток до полного закрытия — **18 пунктов**. Старые функции версии 1.3 сюда повторно не засчитываются.

| № | Пункт | Статус | Реализация / что осталось |
|---|---|---|---|
| 1 | Поддерживаемый Double Ratchet | Код | Закреплённый официальный libsignal, `SignalProtocol.swift`; сторонняя интеграция ещё не аудирована. |
| 2 | Подписанные и одноразовые offline prekeys | Код | PQXDH bundles; атомарное изъятие на сервере; тест конкурентных claims. |
| 3 | Удаление использованных ключей | Код | Удаление one-time prekeys в SDK; ограничение и очистка истёкших локальных prekeys. Без обещания физического стирания памяти. |
| 4 | Восстановление защиты после компрометации | Код | Ratchet выбранной версии libsignal. Условия протокола описаны в `PROTOCOL-V2.md`; активный захват устройства этим не устраняется. |
| 5 | Перестановки, дубликаты, пропуски | Код | Ограниченный skipped-key cache SDK, ciphertext dedup, rollback при ошибке проверки. XCTest. |
| 6 | Атомарное состояние и точный ciphertext | Код | Один encrypted-vault commit до отправки; повтор использует прежние байты. |
| 7 | Запрет незаметного downgrade | Код | После v2 pin старые v1 сообщения отклоняются; отсутствие ключей не включает v1 отправку. |
| 8 | Миграция истории и резервных копий | Код | Чтение старой истории; форматы identity/history/full; ratchet-сессии в экспорт не попадают. |
| 9 | Встроенный Tor | Код | Закреплённый Tor binary, защищённая директория, bootstrap gate, отсутствие прямого fallback. |
| 10 | Onion relay | Частично | `compose.onion.yaml` и v3 конфигурация готовы. Живой onion endpoint не развёрнут и не проверен. |
| 11 | Проверка DNS-утечек | Частично | URL/proxy validation и failover=false. Нужен packet capture на устройстве, включая DNS, TLS и WSS. |
| 12 | Fail closed | Код | Ошибка Tor/proxy прекращает соединение. Redirects запрещены во всех сетевых сессиях приложения. |
| 13 | Изоляция потоков | Код | Раздельные ephemeral URLSession и SOCKS credentials для профилей и capabilities. Не обещает отдельный guard на каждый чат. |
| 14 | Bridges | Частично | Обычные IP bridges поддерживаются. Obfs4/Snowflake требуют дополнительных transport binaries и проверки блокировок. |
| 15 | Проверка всех сетевых операций | Частично | HTTP, blobs, WSS используют конфигурацию маршрута. Runtime capture нужен; APNs и внешний браузер вне маршрута приложения. |
| 16 | Независимые узлы и задержки | Исследование | `RESEARCH-DECISIONS.md`: нужен настоящий mixnet с независимыми операторами; второй URL сам по себе не решает корреляцию. |
| 17 | Скрытие ID отправителя от relay | Код | В capability mailbox нет plaintext sender/account ID. 4-символьный код оставлен как явно публичный поиск и ограничен rate limit; он не считается анонимным адресом. Account lookup, legacy bootstrap и звонки сохраняют метаданные; для скрытия нужен private QR. |
| 18 | Отдельные адреса разговоров | Код | Локальные mailboxes и reply routes привязаны к собеседнику и room ID; проверяется область входящих событий. |
| 19 | Ротация адресов | Частично | Новые адреса заранее создаются при активном общении; диагностика показывает срок и позволяет вручную подготовить свежие overlap-маршруты. Новый адрес передаётся peer внутри следующего E2EE-события. После долгого offline и истечения последнего известного адреса нужен новый обмен приглашениями. |
| 20 | Независимые права на mailbox | Код | Случайные read/write/delete capabilities; на сервере только digest, без поля owner ID. |
| 21 | Размерные buckets | Код | Фиксированные buckets до 5 MiB для сообщения; сообщение и padding шифруются. Это не скрывает число отправлений. |
| 22 | Пакетная доставка и jitter | Код | Ограниченные batches, настраиваемая задержка исходящей очереди и случайная задержка повторов. Нет заявления о защите от глобальной корреляции. |
| 23 | Ограниченный cover traffic | Исследование | `RESEARCH-DECISIONS.md`: не выдавать редкие dummy packets за защиту; нужна модель нагрузки и iOS background бюджета. |
| 24 | Раздельные права на файлы | Код | Private blob capabilities без account bearer; независимые upload/read/delete keys и соединения. |
| 25 | Нейтральный push без fromID | Код | VoIP payload содержит event token; данные собеседника берутся из проверенного зашифрованного/подписанного канала. |
| 26 | Аудит инфраструктурных логов | Частично | Код не пишет тела/ключи, конфигурация без access log. Railway, CDN, host snapshots и реальные retention policies не инспектировались. |
| 27 | Независимые профили | Код | До 12 отдельных identity/vault/Keychain namespaces; отмена задач и очистка состояния при переключении. |
| 28 | Независимые личности для контактов | Частично | Отдельный scoped contact profile. Нет бесшовной независимой identity каждого контакта внутри одного общего профиля. |
| 29 | Выбор группового протокола | Код | Выбран pairwise libsignal fanout до 16 участников. Решение и границы описаны; MLS не реализован. |
| 30 | Обновление защиты при смене состава | Код | Authenticated membership epochs, проверка владельца, отмена старой очереди. Общего группового ключа нет; старую историю у исключённого участника не стереть. |
| 31 | Групповые псевдонимы без общего ID | Частично | Scoped group profile с отдельным ключом. Каждый участник должен выбрать такую личность; общий профиль остаётся связуемым. |
| 32 | Опросы, тайные от создателя | Исследование | `RESEARCH-DECISIONS.md`: threshold trustees и проверяемое tally. Текущие опросы не скрывают индивидуальные голоса от создателя. |
| 33 | Подписанные и отзывные приглашения в группы | Код | Audience, expiry, scope, epoch, single use, local revocation и отмена уже подготовленной отправки. |
| 34 | Ограниченная фоновая authority | Код | Делегированный calls-only signing key, сертификат с expiry, серверные scope checks; message/vault keys остаются WhenUnlocked. |
| 35 | Очистка plaintext temp после сбоя | Код | Защищённые preview/transient directories; очистка при старте, background и закрытии. OS копии и screenshots вне контроля. |
| 36 | Минимизация ключей в памяти | Частично | Ограничение жизни объектов и временных файлов. Для Swift/SDK копий нет подтверждённой zeroization. |
| 37 | Режимы резервной копии | Код | Identity/history/full, шифрование с паролем, подтверждение замены, проверка целостности и границ импорта. |
| 38 | Не экспортировать старые ratchet keys | Код | Sessions/prekeys/outbox/capabilities/device authorities удаляются из экспортируемого состояния. |
| 39 | Удаление одного профиля | Код | Отдельные vault и Keychain namespaces; удаление не стирает остальные личности. |
| 40 | Локальная диагностика утечек | Код | Реальная конфигурация маршрута, ключи/сессии, temp counters, очистка и ограничения показаны пользователю. Не заменяет сетевой capture. |
| 41 | Поддерживаемый голосовой движок | Открыто | Apple AVAudioConverter исправляет resampling, но голос всё ещё PCM/WSS. RingRTC/WebRTC SDK и совместимый безопасный relay transport не интегрированы. |
| 42 | Звонки только через relay | Код | WSS с E2EE; прямых peer sockets/UDP нет. Relay знает стороны звонка. |
| 43 | Физические тесты звонков | Внешняя проверка | Нужны два iPhone, signing/provisioning и APNs credentials; матрица в `AUDIT-PACK.md`. |
| 44 | Восстановление Wi-Fi/mobile звонка | Частично | Resume по существующему ключу, свежие counters, timeout и серверные тесты. Реальный handover и CallKit не проверены. |
| 45 | Режим без APNs | Код | Push/background permissions отключаемы; объясняется получение при открытии приложения. |
| 46 | Раздельные разрешения | Код | Messages, notifications, microphone и background-call authority управляются отдельно. |
| 47 | Ограничение регистрации и спама | Код | Rate buckets, proof-of-work для private tickets, bounded queues/quota и локальное согласие. Не устраняет Sybil abuse. |
| 48 | Анонимные quota credentials | Исследование | `RESEARCH-DECISIONS.md`: Privacy Pass / blind issuance с отдельными issuer и attester. Production протокол не подменён самодельным токеном. |
| 49 | Trusted reverse proxy | Код | Только явно заданные CIDRs, rightmost untrusted hop; тесты spoofing и IPv6. Оператор должен задать свою сеть. |
| 50 | Конкурентные uploads и cleanup/delete | Код | Резервирование quota, lease, atomic finalization, удаление не воскрешает blob; диапазоны читают открытый авторизованный fd. |
| 51 | Нагрузочные проверки | Частично | 100 конкурентных сообщений, files/calls regression scenarios. Нет production throughput/RAM/latency benchmark и multi-process routing. |
| 52 | Fuzzing парсеров | Частично | Детерминированные HTTP/WS и native ciphertext mutation cases. Coverage-guided длительный fuzz campaign не выполнен. |
| 53 | Сборки, зависимости и подпись | Частично | Hash-locked Python, Cargo/SPM pins, GitHub action SHAs, audit evidence, manifest/provenance. Tor/system layers не bit-reproducible; Apple device archive unsigned. |
| 54 | Подготовка независимого аудита | Исследование | `AUDIT-PACK.md`, актуальная модель угроз, тестовая матрица и перечень неизвестного. Сам внешний аудит не проведён. |
| 55 | Профили privacy/speed/battery | Код | Everyday/private delivery/максимальная защита. Максимальный профиль включает Tor, private delivery, свежую stream isolation, padding+jitter, немедленную блокировку после background, скрытые медиа и выключает APNs/receipts/typing; корреляцию времени это не устраняет. |
| 56 | Индикатор фактического маршрута | Код | Состояние активного клиента и Tor bootstrap; не выдаёт выбранную настройку за доказательство соединения. |
| 57 | Предупреждение при выходе из маршрута | Код | Явное подтверждение открытия внешнего браузера при защищённом режиме. |
| 58 | Связывание/отзыв второго устройства | Частично | Двусторонняя проверка, подписанный certificate, expiry, revoke tombstones. Требуется physical pairing QA и полноценная device model. |
| 59 | E2EE синхронизация устройств | Частично | Ручная передача 200 последних text/poll сообщений на отдельную identity в read-only archive. Автоматический live sync, attachments и fanout всех новых сообщений не реализованы. |
| 60 | Доработка интерфейса и восстановления | Частично | Глубокая чёрно-белая тема, onboarding, расширенные параметры скрыты, backup/diagnostics/device tools. Нужны visual QA, VoiceOver и реальные сценарии нового пользователя. |

## Что проверено

- Последняя завершённая native сборка: [GitHub Actions 36719818897](https://github.com/segiipozinovski12-cmd/F/actions/runs/36719818897), commit `a066dadd570ff993da6e3a94703697ed37525caa`: сервер, Debug, XCTest и unsigned Release — success.
- После неё локально прошли **75 серверных тестов**, включая повторную регистрацию с корректной подписью и отказ при подписанной подмене agreement key. Последние native изменения проверяются отдельным запуском CI; результат нельзя приписывать предыдущему commit.
- Python audit: 21 закреплённая зависимость, нет известных уязвимостей в используемой базе на дату проверки. [Запись](evidence/python-dependencies-2026-09-30.json). Это не аудит приложения или native libraries.

## Оценка сроков

Ближайшая проверенная версия и draft PR: ориентир 40–60 минут от текущей проверки состояния, если native CI не выявит ошибки. Это оценка следующего проверяемого результата, не всех 60 пунктов. Крупные интеграции voice SDK и live multi-device sync требуют отдельных циклов разработки и проверки; физические тесты, настройка production/onion и независимый аудит зависят от доступа к оборудованию и операторам. Их нельзя честно оценить по длительности одной сборки.
