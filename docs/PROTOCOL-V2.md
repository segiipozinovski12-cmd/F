# Протокол сообщений v2

Новые сообщения используют официальный libsignal v0.70.0, закреплённый commit `efe13e9b363d2c115dba61b76e5e53bbfc2874bc`. Это PQXDH для начала offline-сессии и Double Ratchet для последующих сообщений, не собственная реализация ratchet. Новые версии спецификаций могут описывать алгоритмы, которых в закреплённой версии нет. Здесь не заявлены непрерывный post-quantum ratchet или совместимость с приложением Signal.

Swift API upstream предназначен прежде всего для Signal и не имеет гарантии поддержки сторонних приложений. Интеграция, outer envelope, routing и приложение не проходили независимый аудит.

## Личность и ключи

Корневая публичная карточка VO1D подписана Ed25519. Отдельный SDK identity key связан с ней подписью `VO1D-SIGNAL-IDENTITY-2` с ID владельца и public key. Проверяется также подпись полного bundle, SDK signed prekey и Kyber prekey. Первый ключ сохраняется по TOFU; последующая подмена блокирует доставку до ручной проверки. TOFU не защищает первый контакт от подмены: сравните QR/отпечаток по независимому каналу.

Каждая публикация создаёт 24 одноразовых EC/PQ bundles со сроком семь дней. Сервер хранит их только после проверки подписей; изъятие — атомарный SQL claim. Повтор публикации не воскрешает ранее изъятый ключ. Локальные ключи ограничены и очищаются по сроку; used one-time keys удаляются при успешной SDK обработке. Доступность offline ограничена retention и наличием свежих ключей.

## Транзакция отправки и приёма

1. Event без шифротекста остаётся в зашифрованном vault; API запрещено сериализовать deferred event.
2. Операция SDK выполняется на отдельной копии state. При необходимости получается проверенный prekey bundle.
3. Новое SDK state и точные готовые bytes outbox записываются одним encrypted-vault commit. Неудачный commit не разрешает отправку.
4. Retry передаёт прежние bytes. Шифрование одного pending event заново при сетевой ошибке не выполняется.
5. Получение проверяет card, binding, identity pin и SDK authentication. Ошибка оставляет предыдущее state. Успешные event/state/dedup сохраняются до ACK.

SDK ограничивает skipped keys и отвергает повторно использованные сообщения. Это не обещает доставку после произвольно большой перестановки, истечения keys или потери сессии. Group membership имеет отдельные authenticated epochs.

## Два транспорта

Обычный envelope доставляется в account inbox: relay знает routing IDs. Private QR использует одноразовое зашифрованное приглашение и отдельные capabilities для mailbox; mailbox row не содержит sender/account ID. Outer ephemeral X25519/AES-GCM seal скрывает SDK packet и подписанную карточку от mailbox relay. Это собственная неаудированная outer конструкция, а не Signal Sealed Sender.

Read/write capabilities, отправка ciphertext и blob operations используют отдельные ephemeral URLSession/SOCKS scopes. Сетевые timings, соединения, размеры buckets и общий оператор всё равно допускают корреляцию. Calls и account bootstrap не наследуют анонимность private mailbox автоматически. Strict delivery требует private route и прекращает отправку при её отсутствии.

## Группы

Для небольших групп выбран **pairwise fanout до 16 участников**, используя отдельные libsignal peer sessions. Общего sender key нет; MLS не реализован. Обновление состава подписывается/проверяется внутри E2EE событий владельца, повышает membership epoch и отменяет подготовленные сообщения старого состава. Сообщение вне известного epoch отклоняется. Эта модель не даёт MLS-конкурентного group state и не стирает прошлую историю у исключённого участника.

Независимый group profile создаёт отдельный корневой ID. Если участник использует прежнюю публичную identity, её связуемость сохраняется. Поддержка «группового псевдонима» не делает всех участников автоматически анонимными.

## Миграция и восстановление

Старая v1 история читается; v1 входящие сообщения доступны только до pin v2 для соответствующего peer. Новая отправка требует v2; сетевой сбой или отсутствие prekeys не включает downgrade.

Identity/full backup может переносить долгосрочную личность, но исключает sessions, prekeys, queued ciphertext, capabilities и delegated authorities. Старые ratchet counters не восстанавливаются. History mode не заменяет ключи и импортирует read-only archive. После восстановления или переустановки может понадобиться новый private invite и ручное повторное начало peer session; старые сообщения, отправленные в утраченную сессию, не гарантированно восстановятся.

Forward secrecy и recovery опираются на условия протокола, удаление старых message keys и новые честные ratchet inputs после прекращения компрометации. Постоянный доступ атакующего к устройству, скопированные plaintext/history, старые exported identity keys и OS memory copies остаются за этой границей.

## Подтверждение и остаток

XCTest покрывает библиотечный roundtrip, перестановку/duplicate, identity substitution, one-time keys, malformed/truncated ciphertext и rollback. Серверные тесты покрывают claims, подписи, сроки и concurrency. Это не независимый audit, длительный coverage-guided fuzz или полная interoperability certification.

Первичные спецификации: [Double Ratchet](https://signal.org/docs/specifications/doubleratchet/), [PQXDH](https://signal.org/docs/specifications/pqxdh/), [MLS RFC 9420](https://www.rfc-editor.org/rfc/rfc9420). Фактический код определяется закреплённой зависимостью, а не последней редакцией веб-страницы.
