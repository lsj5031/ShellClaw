import unittest
from unittest.mock import Mock
import io
import os
import sys

# Add the root directory to sys.path so we can import services
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import services.webhook_server as webhook_server

class TestWebhookServerGet(unittest.TestCase):
    def test_do_GET_health(self):
        mock_handler = Mock()
        mock_handler.path = "/health"
        mock_handler.wfile = io.BytesIO()

        webhook_server.Handler.do_GET(mock_handler)

        mock_handler.send_response.assert_called_once_with(200)
        mock_handler.end_headers.assert_called()
        self.assertEqual(mock_handler.wfile.getvalue(), b"ok")

    def test_do_GET_404_root(self):
        mock_handler = Mock()
        mock_handler.path = "/"
        mock_handler.wfile = io.BytesIO()

        webhook_server.Handler.do_GET(mock_handler)

        mock_handler.send_response.assert_called_once_with(404)
        mock_handler.end_headers.assert_called()

    def test_do_GET_404_other(self):
        mock_handler = Mock()
        mock_handler.path = "/other"
        mock_handler.wfile = io.BytesIO()

        webhook_server.Handler.do_GET(mock_handler)

        mock_handler.send_response.assert_called_once_with(404)
        mock_handler.end_headers.assert_called()

if __name__ == '__main__':
    unittest.main()
