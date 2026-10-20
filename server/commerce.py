"""Server-authoritative collectibles. All mutations share the relay transaction.

The v3 namespace deliberately does not revive legacy vouchers or entitlements.
Prices and quantities are integer VO1Dcoin. No mint, balance or random trait is
accepted from a client. Collections start as drafts, including on existing DBs.
"""
import hashlib
import json
import re
import secrets
import time
import uuid
from urllib.parse import parse_qs

import moderation

PREFIX = '/v3/economy'
COLLECTIONS = [
    ('singularity', 'Singularity', 'Первая точка вселенной. Абсолютная редкость.', 2000, 25000, 500),
    ('sovereign', 'Sovereign', 'Корона из света для тех, кто выбирает своё.', 5000, 10000, 350),
    ('prism', 'Prism', 'Осколок света с бесконечностью внутри.', 10000, 4000, 250),
    ('orbit', 'Orbit', 'Маленькая вселенная на собственной орбите.', 35000, 1500, 150),
    ('nova', 'Nova', 'Вспышка, с которой начинается твоя коллекция.', 55000, 500, 100),
]
# Each category rolls independently, with exact disclosed weights / 10,000.
TRAITS = {
    'backdrop': [('jade', 'Jade', 3000), ('azure', 'Azure', 2700), ('lavender', 'Lavender', 2300),
                 ('rose', 'Rose', 1400), ('midnight', 'Midnight', 450), ('obsidian', 'Obsidian', 150)],
    'pattern': [('stars', 'Stardust', 3500), ('orbits', 'Orbits', 2800), ('diamonds', 'Diamonds', 2200),
                ('runes', 'Runes', 1100), ('eclipse', 'Eclipse', 350), ('void', 'Pure Void', 50)],
    'model': [('original', 'Original', 4000), ('pearl', 'Pearl', 2800), ('aurora', 'Aurora', 2000),
              ('gold', 'Liquid Gold', 900), ('crimson', 'Crimson Chrome', 260), ('monochrome', 'Monochrome', 40)],
}
PRODUCTS = {'io.vo1d.coins.500': 500, 'io.vo1d.coins.2750': 2750,
            'io.vo1d.coins.6000': 6000, 'io.vo1d.coins.16000': 16000}
PREMIUM_PRODUCT = 'io.vo1d.premium.monthly'


def install(db):
    db.executescript('''
      CREATE TABLE IF NOT EXISTS economy_wallets (
        owner TEXT PRIMARY KEY, balance INTEGER NOT NULL DEFAULT 0 CHECK(balance>=0),
        premium_until INTEGER NOT NULL DEFAULT 0, debt INTEGER NOT NULL DEFAULT 0 CHECK(debt>=0));
      CREATE TABLE IF NOT EXISTS artifact_collections (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL,
        supply INTEGER NOT NULL CHECK(supply>0), minted INTEGER NOT NULL DEFAULT 0 CHECK(minted>=0 AND minted<=supply),
        price INTEGER NOT NULL CHECK(price>0), upgrade_price INTEGER NOT NULL CHECK(upgrade_price>0),
        published INTEGER NOT NULL DEFAULT 0, upgrades INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS artifacts (
        id TEXT PRIMARY KEY, collection TEXT NOT NULL, serial INTEGER NOT NULL,
        owner TEXT, price_paid INTEGER NOT NULL, acquired INTEGER NOT NULL,
        visible INTEGER NOT NULL DEFAULT 0, traits TEXT, UNIQUE(collection,serial));
      CREATE INDEX IF NOT EXISTS artifacts_owner ON artifacts(owner,id);
      CREATE TABLE IF NOT EXISTS artifact_listings (
        id TEXT PRIMARY KEY, artifact TEXT UNIQUE NOT NULL, seller TEXT NOT NULL,
        price INTEGER NOT NULL CHECK(price>0), created INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS economy_ledger (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT, delta INTEGER NOT NULL,
        kind TEXT NOT NULL, reference TEXT NOT NULL, created INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS ledger_owner ON economy_ledger(owner,seq);
      CREATE TABLE IF NOT EXISTS economy_operations (
        owner TEXT NOT NULL, id TEXT NOT NULL, digest TEXT NOT NULL, response TEXT NOT NULL,
        PRIMARY KEY(owner,id));
      CREATE TABLE IF NOT EXISTS economy_payments (
        id TEXT PRIMARY KEY, owner TEXT, product TEXT NOT NULL, original_id TEXT NOT NULL,
        expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS economy_admin_audit (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, actor TEXT, action TEXT NOT NULL,
        collection TEXT NOT NULL, created INTEGER NOT NULL);
    ''')
    if 'debt' not in {r[1] for r in db.execute('PRAGMA table_info(economy_wallets)')}:
        db.execute('ALTER TABLE economy_wallets ADD COLUMN debt INTEGER NOT NULL DEFAULT 0 CHECK(debt>=0)')
    if 'last_price' not in {r[1] for r in db.execute('PRAGMA table_info(artifacts)')}:
        db.execute('ALTER TABLE artifacts ADD COLUMN last_price INTEGER NOT NULL DEFAULT 0')
        db.execute('UPDATE artifacts SET last_price=price_paid')
    db.executemany('''INSERT OR IGNORE INTO artifact_collections
      (id,title,description,supply,price,upgrade_price) VALUES (?,?,?,?,?,?)''', COLLECTIONS)


def account_token(owner):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'https://vo1d.app/accounts/' + owner))


def wallet(db, owner):
    row = db.execute('SELECT * FROM economy_wallets WHERE owner=?', (owner,)).fetchone()
    until = row['premium_until'] if row else 0
    return {'balance': row['balance'] if row else 0, 'refundDebt': row['debt'] if row else 0, 'premiumUntil': until,
            'premium': until > int(time.time()), 'appAccountToken': account_token(owner)}


def change_balance(db, owner, delta, kind, reference, now, error):
    original_delta = delta
    db.execute('INSERT OR IGNORE INTO economy_wallets(owner) VALUES (?)', (owner,))
    row = db.execute('SELECT balance,debt FROM economy_wallets WHERE owner=?', (owner,)).fetchone()
    if delta < 0 and row['debt']:
        raise error(409, 'Сначала погаси задолженность по возврату покупки')
    if delta > 0 and row['debt']:
        offset = min(delta, row['debt'])
        db.execute('UPDATE economy_wallets SET debt=debt-? WHERE owner=?', (offset, owner))
        delta -= offset
    if db.execute('UPDATE economy_wallets SET balance=balance+? WHERE owner=? AND balance+?>=0',
                  (delta, owner, delta)).rowcount != 1:
        raise error(409, 'Недостаточно VO1Dcoin')
    db.execute('INSERT INTO economy_ledger(owner,delta,kind,reference,created) VALUES (?,?,?,?,?)',
               (owner, original_delta, kind, reference, now))


def collection(row):
    return {'id': row['id'], 'title': row['title'], 'description': row['description'],
            'supply': row['supply'], 'minted': row['minted'], 'price': row['price'],
            'upgradePrice': row['upgrade_price'], 'published': bool(row['published']),
            'upgrades': bool(row['upgrades'])}


def artifact(db, row):
    sale = db.execute('SELECT * FROM artifact_listings WHERE artifact=?', (row['id'],)).fetchone()
    name = db.execute('SELECT username FROM usernames WHERE identity=?', (row['owner'],)).fetchone()
    return {'id': row['id'], 'collection': row['collection'], 'serial': row['serial'],
            'owner': row['owner'], 'ownerUsername': name[0] if name else None,
            'pricePaid': row['price_paid'], 'lastPricePaid': row['last_price'], 'acquired': row['acquired'], 'visible': bool(row['visible']),
            'traits': json.loads(row['traits']) if row['traits'] else None,
            'listingID': sale['id'] if sale else None, 'salePrice': sale['price'] if sale else None}


def roll():
    result = {}
    for category, variants in TRAITS.items():
        ticket = secrets.randbelow(10000)
        for key, title, weight in variants:
            ticket -= weight
            if ticket < 0:
                result[category] = {'id': key, 'title': title, 'weight': weight}
                break
    return result


def estimate(db, gift):
    base = db.execute('SELECT price FROM artifact_collections WHERE id=?', (gift['collection'],)).fetchone()[0]
    traits = json.loads(gift['traits']) if gift['traits'] else None
    # A transparent heuristic, never an offer or a guaranteed sale price.
    multiplier = 1.0 if not traits else sum((10000 / t['weight']) ** 0.32 for t in traits.values()) / 3
    return int(base * multiplier)


def handle(relay, db, user, env, body, error):
    path, method = env.get('PATH_INFO', ''), env['REQUEST_METHOD']
    if not path.startswith(PREFIX + '/'):
        return None
    if env.get('HTTP_AUTHORIZATION', '').startswith('BotCapability '):
        raise error(403, 'Для коллекции нужна сессия владельца')
    route = path[len(PREFIX):]
    now = int(time.time())
    admin_row = moderation.owner(db)
    admin = admin_row is not None and admin_row['owner'] == user
    query = parse_qs(env.get('QUERY_STRING', ''))
    cursor = query.get('cursor', [''])[0]
    if len(cursor) > 80:
        raise error(400, 'Некорректная страница')
    if method == 'GET' and route == '/catalog':
        rows = db.execute('SELECT * FROM artifact_collections WHERE published=1 ORDER BY supply').fetchall()
        return {'collections': [collection(r) for r in rows], 'wallet': wallet(db, user), 'admin': admin,
                'products': list(PRODUCTS), 'premiumProduct': PREMIUM_PRODUCT}
    if method == 'GET' and route == '/admin':
        if not admin:
            raise error(403, 'Только закреплённый администратор')
        return {'collections': [collection(r) for r in db.execute('SELECT * FROM artifact_collections ORDER BY supply')]}
    if method == 'GET' and route in ('/inventory', '/market', '/history'):
        if route == '/history':
            try:
                seq = int(cursor or '9223372036854775807')
            except ValueError:
                raise error(400, 'Некорректная страница')
            rows = db.execute('SELECT * FROM economy_ledger WHERE owner=? AND seq<? ORDER BY seq DESC LIMIT 51', (user, seq)).fetchall()
            return {'entries': [dict(r) for r in rows[:50]], 'nextCursor': str(rows[49]['seq']) if len(rows) > 50 else None}
        if route == '/inventory':
            rows = db.execute('SELECT * FROM artifacts WHERE owner=? AND id>? ORDER BY id LIMIT 51', (user, cursor)).fetchall()
            total, visible = db.execute('SELECT count(*),coalesce(sum(visible),0) FROM artifacts WHERE owner=?', (user,)).fetchone()
        else:
            rows = db.execute('''SELECT a.* FROM artifacts a JOIN artifact_listings l ON a.id=l.artifact
                                  WHERE a.id>? ORDER BY a.id LIMIT 51''', (cursor,)).fetchall()
            total = visible = db.execute('SELECT count(*) FROM artifact_listings').fetchone()[0]
        return {'artifacts': [artifact(db, r) for r in rows[:50]], 'total': total, 'visibleCount': visible,
                'nextCursor': rows[49]['id'] if len(rows) > 50 else None}
    if method == 'GET' and route.startswith('/profile/'):
        owner = route.removeprefix('/profile/')
        if not re.fullmatch('[a-f0-9]{64}', owner):
            raise error(400, 'Некорректный владелец')
        if db.execute('SELECT 1 FROM blocks WHERE (owner=? AND peer=?) OR (owner=? AND peer=?)', (owner, user, user, owner)).fetchone():
            raise error(404, 'Профиль недоступен')
        rows = db.execute('SELECT * FROM artifacts WHERE owner=? AND visible=1 AND id>? ORDER BY id LIMIT 51', (owner, cursor)).fetchall()
        return {'artifacts': [artifact(db, r) for r in rows[:50]], 'nextCursor': rows[49]['id'] if len(rows) > 50 else None,
                'total': db.execute('SELECT count(*) FROM artifacts WHERE owner=? AND visible=1', (owner,)).fetchone()[0],
                'premium': wallet(db, owner)['premium']}
    if method == 'GET' and route.startswith('/artifact/'):
        row = db.execute('SELECT * FROM artifacts WHERE id=?', (route.removeprefix('/artifact/'),)).fetchone()
        if not row or (row['owner'] != user and not row['visible'] and not db.execute('SELECT 1 FROM artifact_listings WHERE artifact=?', (row['id'],)).fetchone()):
            raise error(404, 'Артефакт не найден')
        return {'artifact': artifact(db, row), 'estimatedValue': estimate(db, row)}
    if method != 'POST':
        raise error(404, 'Не найдено')
    if route == '/transcription-authorize':
        if not wallet(db, user)['premium']:
            raise error(403, 'Расшифровка доступна в VO1D_PREMIUM')
        return {'ok': True}
    if route == '/payment':
        # Verification uses Apple's current server record, not client price/coins.
        payment = env.get('vo1d.verified_payment')
        if payment is None:
            raise error(503, 'Проверка оплаты недоступна')
        return apply_payment(db, user, payment, now, error)
    request_id = body.get('requestID')
    try:
        if not isinstance(request_id, str) or str(uuid.UUID(request_id)) != request_id.lower():
            raise ValueError()
    except (ValueError, AttributeError):
        raise error(400, 'Нужен уникальный requestID')
    digest = hashlib.sha256((route + '\n' + json.dumps(body, sort_keys=True, separators=(',', ':'))).encode()).hexdigest()
    old = db.execute('SELECT * FROM economy_operations WHERE owner=? AND id=?', (user, request_id)).fetchone()
    if old:
        if old['digest'] != digest:
            raise error(409, 'requestID уже использован для другой операции')
        return json.loads(old['response'])
    result = mutate(db, user, admin, route, body, now, error)
    result['wallet'] = wallet(db, user)
    db.execute('INSERT INTO economy_operations VALUES (?,?,?,?)', (user, request_id, digest, json.dumps(result)))
    return result


def mutate(db, user, admin, route, body, now, error):
    if route in ('/admin/publish', '/admin/upgrades'):
        if not admin:
            raise error(403, 'Только закреплённый администратор')
        if body.get('confirmed') is not True:
            raise error(400, 'Подтверди публикацию')
        row = db.execute('SELECT * FROM artifact_collections WHERE id=?', (body.get('collection'),)).fetchone()
        if not row:
            raise error(404, 'Коллекция не найдена')
        if route == '/admin/upgrades' and not row['published']:
            raise error(409, 'Сначала опубликуй подарок')
        column = 'published' if route == '/admin/publish' else 'upgrades'
        if not row[column]:
            db.execute(f'UPDATE artifact_collections SET {column}=1 WHERE id=?', (row['id'],))
            db.execute('INSERT INTO economy_admin_audit(actor,action,collection,created) VALUES (?,?,?,?)', (user, column, row['id'], now))
        return {'ok': True}
    if route == '/buy':
        row = db.execute('SELECT * FROM artifact_collections WHERE id=? AND published=1', (body.get('collection'),)).fetchone()
        if not row:
            raise error(404, 'Подарок ещё не опубликован')
        if body.get('expectedPrice') != row['price']:
            raise error(409, 'Цена изменилась, обнови витрину')
        if row['minted'] >= row['supply']:
            raise error(409, 'Тираж распродан')
        identifier = str(uuid.uuid4())
        change_balance(db, user, -row['price'], 'purchase', identifier, now, error)
        db.execute('UPDATE artifact_collections SET minted=minted+1 WHERE id=?', (row['id'],))
        db.execute('''INSERT INTO artifacts(id,collection,serial,owner,price_paid,acquired,last_price)
                      VALUES (?,?,?,?,?,?,?)''', (identifier, row['id'], row['minted'] + 1, user, row['price'], now, row['price']))
        return {'ok': True, 'artifact': artifact(db, db.execute('SELECT * FROM artifacts WHERE id=?', (identifier,)).fetchone())}
    if route == '/market/buy':
        sale = db.execute('SELECT * FROM artifact_listings WHERE id=?', (body.get('listingID'),)).fetchone()
        if not sale:
            raise error(409, 'Объявление уже снято или продано')
        if sale['seller'] == user:
            raise error(409, 'Это твой артефакт')
        if body.get('expectedPrice') != sale['price']:
            raise error(409, 'Цена изменилась')
        gift = db.execute('SELECT * FROM artifacts WHERE id=? AND owner=?', (sale['artifact'], sale['seller'])).fetchone()
        if not gift:
            raise error(409, 'Владелец изменился')
        change_balance(db, user, -sale['price'], 'market_purchase', gift['id'], now, error)
        change_balance(db, sale['seller'], sale['price'], 'sale', gift['id'], now, error)
        db.execute('UPDATE artifacts SET owner=?,visible=0,acquired=?,last_price=? WHERE id=?', (user, now, sale['price'], gift['id']))
        db.execute('DELETE FROM artifact_listings WHERE id=?', (sale['id'],))
        return {'ok': True, 'artifact': artifact(db, db.execute('SELECT * FROM artifacts WHERE id=?', (gift['id'],)).fetchone())}
    gift = db.execute('SELECT * FROM artifacts WHERE id=? AND owner=?', (body.get('artifactID'), user)).fetchone()
    if not gift:
        raise error(404, 'Артефакт не принадлежит тебе')
    sale = db.execute('SELECT * FROM artifact_listings WHERE artifact=?', (gift['id'],)).fetchone()
    if route == '/visibility':
        if type(body.get('visible')) is not bool:
            raise error(400, 'Укажи видимость')
        db.execute('UPDATE artifacts SET visible=? WHERE id=?', (body['visible'], gift['id']))
    elif route == '/unlist':
        db.execute('DELETE FROM artifact_listings WHERE artifact=? AND seller=?', (gift['id'], user))
    elif route in ('/upgrade', '/transfer', '/list'):
        if sale:
            raise error(409, 'Сначала сними артефакт с продажи')
        if route == '/upgrade':
            row = db.execute('SELECT * FROM artifact_collections WHERE id=?', (gift['collection'],)).fetchone()
            if not row['upgrades'] or gift['traits']:
                raise error(409, 'Улучшение недоступно или уже выполнено')
            if body.get('expectedPrice') != row['upgrade_price']:
                raise error(409, 'Цена улучшения изменилась')
            change_balance(db, user, -row['upgrade_price'], 'upgrade', gift['id'], now, error)
            db.execute('UPDATE artifacts SET traits=? WHERE id=?', (json.dumps(roll()), gift['id']))
        elif route == '/transfer':
            if wallet(db, user)['refundDebt']:
                raise error(409, 'Сначала погаси задолженность по возврату покупки')
            recipient = body.get('recipient', '')
            if isinstance(recipient, str) and recipient.startswith('@'):
                row = db.execute('SELECT identity FROM usernames WHERE username=?', (recipient[1:].lower(),)).fetchone()
                recipient = row[0] if row else ''
            if not isinstance(recipient, str) or recipient == user or not db.execute('SELECT 1 FROM identities WHERE id=?', (recipient,)).fetchone():
                raise error(400, 'Получатель не найден или совпадает с владельцем')
            if db.execute('SELECT 1 FROM blocks WHERE (owner=? AND peer=?) OR (owner=? AND peer=?)', (user, recipient, recipient, user)).fetchone():
                raise error(403, 'Передача этому пользователю недоступна')
            db.execute('UPDATE artifacts SET owner=?,visible=0,acquired=?,last_price=0 WHERE id=?', (recipient, now, gift['id']))
            for owner, kind in ((user, 'transfer_sent'), (recipient, 'transfer_received')):
                db.execute('INSERT INTO economy_ledger(owner,delta,kind,reference,created) VALUES (?,0,?,?,?)', (owner, kind, gift['id'], now))
        else:
            price = body.get('price')
            if type(price) is not int or not 1 <= price <= 1000000000:
                raise error(400, 'Цена должна быть от 1 до 1 000 000 000 VO1Dcoin')
            db.execute('INSERT INTO artifact_listings VALUES (?,?,?,?,?)', (str(uuid.uuid4()), gift['id'], user, price, now))
    else:
        raise error(404, 'Операция не найдена')
    return {'ok': True, 'artifact': artifact(db, db.execute('SELECT * FROM artifacts WHERE id=?', (gift['id'],)).fetchone())}


def apply_payment(db, user, payment, now, error):
    identifier, product = payment['transactionId'], payment['productId']
    if product not in PRODUCTS and product != PREMIUM_PRODUCT:
        raise error(400, 'Неизвестный продукт')
    old = db.execute('SELECT * FROM economy_payments WHERE id=?', (identifier,)).fetchone()
    if old and (old['owner'] != user or old['product'] != product):
        raise error(409, 'Платёж уже привязан к другому аккаунту')
    revoked = payment.get('revocationDate') is not None
    expires = int(payment.get('expiresDate', 0)) // 1000
    if not old:
        db.execute('INSERT INTO economy_payments VALUES (?,?,?,?,?,?)', (identifier, user, product, payment.get('originalTransactionId', identifier), expires, int(revoked)))
        if product in PRODUCTS and not revoked:
            change_balance(db, user, PRODUCTS[product], 'topup', identifier, now, error)
    elif revoked and not old['revoked']:
        db.execute('UPDATE economy_payments SET revoked=1 WHERE id=?', (identifier,))
        if product in PRODUCTS:
            db.execute('INSERT OR IGNORE INTO economy_wallets(owner) VALUES (?)', (user,))
            balance = wallet(db, user)['balance']
            debit = min(balance, PRODUCTS[product])
            db.execute('UPDATE economy_wallets SET balance=balance-?,debt=debt+? WHERE owner=?', (debit, PRODUCTS[product] - debit, user))
            db.execute('INSERT INTO economy_ledger(owner,delta,kind,reference,created) VALUES (?,?,?,?,?)', (user, -PRODUCTS[product], 'refund', identifier, now))
    if product == PREMIUM_PRODUCT:
        db.execute('INSERT OR IGNORE INTO economy_wallets(owner) VALUES (?)', (user,))
        until = db.execute('SELECT coalesce(max(expires),0) FROM economy_payments WHERE owner=? AND product=? AND revoked=0', (user, PREMIUM_PRODUCT)).fetchone()[0]
        db.execute('UPDATE economy_wallets SET premium_until=? WHERE owner=?', (until, user))
    return {'ok': True, 'wallet': wallet(db, user)}

def prepare_payment(relay, user, env, body, error):
    """Perform network I/O before entering the serialized write transaction."""
    import storekit
    if env['PATH_INFO'] == PREFIX + '/payment':
        env['vo1d.verified_payment'] = storekit.verify_transaction(body.get('transactionID'), account_token(user), error)
    elif env['PATH_INFO'] == PREFIX + '/transcription-authorize':
        with relay.db() as db:
            row = db.execute('SELECT id FROM economy_payments WHERE owner=? AND product=? AND revoked=0 ORDER BY expires DESC LIMIT 1', (user, PREMIUM_PRODUCT)).fetchone()
        if row:
            payment = storekit.verify_transaction(row['id'], account_token(user), error)
            with relay.db() as db:
                db.execute('BEGIN IMMEDIATE')
                if db.execute('SELECT 1 FROM identities WHERE id=?', (user,)).fetchone():
                    apply_payment(db, user, payment, int(time.time()), error)


def notification(relay, body, error):
    """Notification JWS is an untrusted lookup hint; Apple confirms all claims."""
    import base64
    import storekit
    def payload(value):
        if not isinstance(value, str) or len(value) > 64000:
            raise error(400, 'Invalid notification')
        parts = value.split('.')
        if len(parts) != 3:
            raise error(400, 'Invalid notification')
        decoded = json.loads(base64.b64decode(parts[1] + '=' * (-len(parts[1]) % 4), altchars=b'-_', validate=True))
        if not isinstance(decoded, dict):
            raise error(400, 'Invalid notification object')
        return decoded
    hint = payload(payload(body.get('signedPayload'))['data']['signedTransactionInfo'])
    original = hint.get('originalTransactionId')
    if not isinstance(original, str) or not re.fullmatch('[0-9]{1,30}', original):
        raise error(400, 'Invalid notification transaction')
    with relay.db() as db:
        row = db.execute('SELECT owner FROM economy_payments WHERE original_id=? AND owner IS NOT NULL LIMIT 1', (original,)).fetchone()
    if not row:
        return {'ok': True}
    payment = storekit.verify_transaction(hint.get('transactionId'), account_token(row['owner']), error)
    if payment.get('originalTransactionId', payment['transactionId']) != original:
        raise error(400, 'Notification transaction mismatch')
    with relay.db() as db:
        db.execute('BEGIN IMMEDIATE')
        if db.execute('SELECT 1 FROM identities WHERE id=?', (row['owner'],)).fetchone():
            apply_payment(db, row['owner'], payment, int(time.time()), error)
    return {'ok': True}


def erase(db, user):
    # Called only by the existing explicit/inactivity account deletion policy.
    # Serial numbers and minted counters remain spent; no new deployment deletes users.
    db.execute('DELETE FROM artifact_listings WHERE seller=?', (user,))
    db.execute('UPDATE artifacts SET owner=NULL,visible=0 WHERE owner=?', (user,))
    db.execute('DELETE FROM economy_wallets WHERE owner=?', (user,))
    db.execute('DELETE FROM economy_operations WHERE owner=?', (user,))
    db.execute('UPDATE economy_payments SET owner=NULL WHERE owner=?', (user,))
    db.execute('UPDATE economy_ledger SET owner=NULL WHERE owner=?', (user,))
    db.execute('UPDATE economy_admin_audit SET actor=NULL WHERE actor=?', (user,))
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if 'commerce_receipts' in tables:
        db.execute('DELETE FROM commerce_receipts WHERE owner=?', (user,))
    if 'commerce_vouchers' in tables:
        db.execute("UPDATE commerce_vouchers SET owner=NULL,used_by='deleted',receipt=NULL WHERE owner=? OR used_by=?", (user, user))
