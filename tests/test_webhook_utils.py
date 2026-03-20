import unittest
from unittest.mock import patch

import services.webhook_server as webhook_server

class TestWebhookUtils(unittest.TestCase):
    def test_chat_id_from_message(self):
        test_cases = [
            ({"chat": {"id": 12345}}, "12345"),
            ({"chat": {"id": 0}}, "0"),
            ({"chat": {"id": -100}}, "-100"),
            ({"chat": "not a dict"}, ""),
            ({}, ""),
            (None, ""),
            ([], ""),
            ("not a dict", ""),
        ]
        for msg, expected in test_cases:
            with self.subTest(msg=msg):
                self.assertEqual(webhook_server._chat_id_from_message(msg), expected)

    def test_is_allowed_chat_permissive(self):
        with patch('services.webhook_server.CHAT_ID', ''):
            self.assertTrue(webhook_server._is_allowed_chat("12345"))
            self.assertTrue(webhook_server._is_allowed_chat("anything"))
            self.assertTrue(webhook_server._is_allowed_chat(""))

    def test_is_allowed_chat_restricted(self):
        with patch('services.webhook_server.CHAT_ID', '12345'):
            self.assertTrue(webhook_server._is_allowed_chat("12345"))
            self.assertFalse(webhook_server._is_allowed_chat("67890"))
            self.assertFalse(webhook_server._is_allowed_chat(""))

if __name__ == '__main__':
    unittest.main()
