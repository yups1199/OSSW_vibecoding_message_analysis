"""Synthetic data only. No files from the archived project are needed."""
import unittest
from fastapi.testclient import TestClient
from app.analysis import analyze, parse
from app.main import app, APP_VERSION, MAX_BYTES

SAMPLE = '''--------------- 2026년 10월 1일 목요일 ---------------
[가상하늘] [오전 9:00] 프로젝트 회의 시작
[가상바다] [오전 9:02] 프로젝트 회의 좋아
여러 줄 본문
[가상하늘] [오전 9:05] 자료 준비
[가상바다] [오전 10:00] 다시 시작'''

class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(app)

    def post(self, content, url='/api/analyze'):
        return self.client.post(url, content=content, headers={'Content-Type': 'text/plain'})

    def test_pc_parser_and_statistics(self):
        result = analyze(SAMPLE)
        self.assertEqual((result['total'], result['participant_count'], result['sessions']), (4, 2, 2))
        self.assertEqual(result['participants'][0]['ratio'], 50)
        self.assertEqual(sum(row['value'] for row in result['hourly']), 4)
        self.assertEqual(sum(row['value'] for row in result['weekdays']), 4)
        self.assertIn('여러 줄', parse(SAMPLE)[0][1]['body'])
        pair = next(row for row in result['replies'] if row['responder'] == '가상바다')
        self.assertEqual((pair['count'], pair['median_seconds']), (1, 120))

    def test_session_threshold(self):
        self.assertEqual(analyze(SAMPLE, 60)['sessions'], 1)

    def test_mobile_and_midnight(self):
        result = analyze('2026. 10. 1. 오전 12:00, 가상하늘 : 안녕\n2026년 10월 1일 오후 12:01, 가상바다 : 반가워')
        self.assertEqual(result['start'], '2026-10-01T00:00:00')
        self.assertEqual(result['end'], '2026-10-01T12:01:00')

    def test_utf8_and_cp949_api(self):
        for encoding in ('utf-8-sig', 'cp949'):
            with self.subTest(encoding=encoding):
                response = self.post(SAMPLE.encode(encoding))
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json()['total'], 4)

    def test_validation_errors(self):
        for body, code in [(b'', 400), (b'bad format', 422), (b'\x00binary', 400), (b'\xff\xff', 400), (b'a' * (MAX_BYTES + 1), 413)]:
            with self.subTest(code=code, length=len(body)):
                self.assertEqual(self.post(body).status_code, code)
        self.assertEqual(self.client.post('/api/analyze', json={}).status_code, 415)
        self.assertEqual(self.post(SAMPLE.encode(), '/api/analyze?session_minutes=0').status_code, 400)

    def test_health_and_preserved_legacy(self):
        response = self.client.get('/health')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'status': 'ok', 'version': APP_VERSION})
        self.assertEqual(self.client.get('/api/health').json(), {'status': 'ok'})

    def test_static_security_and_docs_disabled(self):
        for path in ('/', '/static/style.css', '/static/app.js'):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.headers['cache-control'], 'no-store')
        self.assertIn("script-src 'self'", self.client.get('/').headers['content-security-policy'])
        self.assertEqual(self.client.get('/docs').status_code, 404)

if __name__ == '__main__':
    unittest.main()
