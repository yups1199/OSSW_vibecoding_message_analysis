"""Regression tests for startup resets, HTTP readiness and terminal failures."""
from contextlib import redirect_stdout
from http.client import RemoteDisconnected
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from wait_ready import wait_ready


def response(payload=None, status=200):
    stream = io.BytesIO(json.dumps(payload if payload is not None else {'status': 'ok', 'version': 'test'}).encode())
    stream.status = status
    return stream


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.output = redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    @patch('wait_ready.time.sleep')
    @patch('wait_ready.urlopen')
    def test_reset_then_http503_then_success(self, open_url, sleep):
        open_url.side_effect = [ConnectionResetError(104, 'Connection reset by peer'), HTTPError('http://test/health', 503, 'starting', {}, None), response()]
        wait_ready('http://test', 'test', attempts=3)
        self.assertEqual(open_url.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    @patch('wait_ready.time.sleep')
    @patch('wait_ready.urlopen')
    def test_other_transient_errors(self, open_url, sleep):
        open_url.side_effect = [RemoteDisconnected(), TimeoutError(), URLError('refused'), response()]
        wait_ready('http://test', 'test', attempts=4)
        self.assertEqual(open_url.call_count, 4)

    @patch('wait_ready.time.sleep')
    @patch('wait_ready.urlopen', side_effect=ConnectionResetError(104, 'reset'))
    def test_exhaustion_fails_with_original_cause(self, open_url, sleep):
        with self.assertRaises(RuntimeError) as caught:
            wait_ready('http://test', 'test', attempts=2)
        self.assertIsInstance(caught.exception.__cause__, ConnectionResetError)
        self.assertEqual(open_url.call_count, 2)
        sleep.assert_called_once()

    @patch('wait_ready.urlopen')
    def test_wrong_version_is_terminal(self, open_url):
        open_url.return_value = response({'status': 'ok', 'version': 'old'})
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            wait_ready('http://test', 'test')
        open_url.assert_called_once()

    @patch('wait_ready.urlopen')
    def test_http200_with_bad_json_fails(self, open_url):
        data = io.BytesIO(b'not-json')
        data.status = 200
        open_url.return_value = data
        with self.assertRaises(json.JSONDecodeError):
            wait_ready('http://test', 'test')

    @patch('wait_ready.time.sleep')
    @patch('wait_ready.urlopen')
    def test_non200_is_not_ready(self, open_url, sleep):
        open_url.side_effect = [response(status=204), response()]
        wait_ready('http://test', 'test', attempts=2)
        self.assertEqual(open_url.call_count, 2)

    def test_actual_http_server_unavailable_then_ready(self):
        class Handler(BaseHTTPRequestHandler):
            calls = 0
            def do_GET(self):
                Handler.calls += 1
                if Handler.calls == 1:
                    self.send_response(503)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ok","version":"test"}')
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            wait_ready(f'http://127.0.0.1:{server.server_port}', 'test', attempts=3, interval=0)
            self.assertEqual(Handler.calls, 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())


if __name__ == '__main__':
    unittest.main()
