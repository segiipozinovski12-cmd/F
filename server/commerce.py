"""Deletion-only compatibility for retired entitlement records.

No issuer, purchase, redemption or entitlement endpoint remains. Existing records
stay intact until their owner explicitly deletes the account.
"""

def erase(db, user):
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if 'commerce_receipts' in tables:
        db.execute('DELETE FROM commerce_receipts WHERE owner=?', (user,))
    if 'commerce_vouchers' in tables:
        db.execute("UPDATE commerce_vouchers SET owner=NULL,used_by='deleted',receipt=NULL WHERE owner=? OR used_by=?", (user, user))
