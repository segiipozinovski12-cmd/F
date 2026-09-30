"""Forwarded IPs are trusted only behind explicitly configured proxy networks."""
import ipaddress
import os


def client_address(env):
    peer=env.get('REMOTE_ADDR','')
    try: address=ipaddress.ip_address(peer)
    except ValueError: return peer[:64]
    trusted=[]
    for value in os.environ.get('VO1D_TRUSTED_PROXIES','').split(','):
        if value.strip(): trusted.append(ipaddress.ip_network(value.strip(),strict=False))
    def is_proxy(candidate): return any(candidate in network for network in trusted if candidate.version==network.version)
    if not is_proxy(address): return str(address)
    raw=env.get('HTTP_X_FORWARDED_FOR','')
    parts=raw.split(',')
    if not raw or len(parts)>10: return str(address)
    try: chain=[ipaddress.ip_address(part.strip()) for part in parts]+[address]
    except ValueError: return str(address)
    for candidate in reversed(chain):
        if not is_proxy(candidate): return str(candidate)
    return str(chain[0])
