import unittest
from unittest.mock import patch
from network_privacy import client_address

class NetworkPrivacyTests(unittest.TestCase):
    def test_untrusted_peer_cannot_choose_rate_bucket(self):
        env={'REMOTE_ADDR':'203.0.113.9','HTTP_X_FORWARDED_FOR':'1.2.3.4'}
        with patch.dict('os.environ',{'VO1D_TRUSTED_PROXIES':'127.0.0.1/32'}):
            self.assertEqual(client_address(env),'203.0.113.9')
    def test_rightmost_untrusted_hop_prevents_chain_spoofing(self):
        env={'REMOTE_ADDR':'127.0.0.1','HTTP_X_FORWARDED_FOR':'1.2.3.4, 203.0.113.9, 10.0.0.2'}
        with patch.dict('os.environ',{'VO1D_TRUSTED_PROXIES':'127.0.0.1/32,10.0.0.0/24'}):
            self.assertEqual(client_address(env),'203.0.113.9')
            env['HTTP_X_FORWARDED_FOR']='invalid,203.0.113.9'
            self.assertEqual(client_address(env),'127.0.0.1')
    def test_ipv6_and_missing_forwarded_address(self):
        env={'REMOTE_ADDR':'::1','HTTP_X_FORWARDED_FOR':'2001:db8::f'}
        with patch.dict('os.environ',{'VO1D_TRUSTED_PROXIES':'::1/128'}):
            self.assertEqual(client_address(env),'2001:db8::f')
            env.pop('HTTP_X_FORWARDED_FOR')
            self.assertEqual(client_address(env),'::1')
