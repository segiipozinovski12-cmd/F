#!/usr/bin/env python3
"""Run on the relay host after verified payment; never accept a client tx hash as proof."""
import argparse
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))
from app import Relay
import commerce

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--db', required=True)
    p.add_argument('--kind', choices=['premium', 'collectible'], default='premium')
    p.add_argument('--days', type=int, default=30)
    p.add_argument('--label', default='VO1D PREMIUM')
    p.add_argument('--symbol', default='sparkles')
    p.add_argument('--owner', help='Optional identity binding')
    args = p.parse_args()
    if commerce.signing_key() is None:
        p.error('Set VO1D_COMMERCE_SIGNING_KEY on the host first')
    with Relay(args.db).db() as db:
        print(commerce.issue(db, args.kind, args.days, args.label, args.symbol, args.owner))
