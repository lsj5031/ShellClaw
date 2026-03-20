import unittest
from unittest.mock import Mock, patch, mock_open
import io
import os

import services.webhook_server as webhook_server

class TestWebhookValidation(unittest.TestCase):
    def test_validation_logic(self):
        # We want to test if the secret validation works as expected.
        # Since we are going to use hmac.compare_digest, we want to ensure
        # that valid tokens still work and invalid ones still fail.

        test_cases = [
            ("secret123", "secret123", True),
            ("secret123", "wrong", False),
            ("secret123", "", False),
            ("", "anything", True), # If SECRET is empty, validation is skipped
        ]

        for secret, token, expected_pass in test_cases:
            with self.subTest(secret=secret, token=token):
                with patch('services.webhook_server.SECRET', secret):
                    mock_handler = Mock()
                    mock_handler.headers = {"X-Telegram-Bot-Api-Secret-Token": token}
                    mock_handler.rfile = io.BytesIO(b'{"message": {"text": "hello"}}')
                    mock_handler.headers["Content-Length"] = "29"
                    mock_handler.wfile = io.BytesIO()

                    # Mocking file operations and other side effects in do_POST
                    with patch('builtins.open', mock_open()):
                        with patch('os.open', return_value=1):
                            with patch('os.write'):
                                with patch('os.close'):
                                    with patch('fcntl.flock'):
                                        try:
                                            webhook_server.Handler.do_POST(mock_handler)
                                        except Exception as e:
                                            # If it fails later in do_POST it's fine as long as
                                            # it passed the secret check.
                                            pass

                    if expected_pass:
                        # If it passed, send_response(403) should NOT be called
                        # Wait, if SECRET is empty, it skips the check.
                        if secret != "":
                            # if secret is set and token is correct, it should NOT send 403
                            for call in mock_handler.send_response.call_args_list:
                                self.assertNotEqual(call[0][0], 403)
                    else:
                        # If it should fail, send_response(403) should be called
                        mock_handler.send_response.assert_any_call(403)
                        self.assertEqual(mock_handler.wfile.getvalue(), b"forbidden")

if __name__ == '__main__':
    unittest.main()
