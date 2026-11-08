"""Real HTTP smoke check, usable against local processes and containers.

Usage: python tests/smoke.py http://127.0.0.1:8000 expected-version
Only Python's standard library is required.
"""
import json
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

def check(base, version):
    base = base.rstrip('/')
    for attempt in range(60):
        try:
            with urlopen(base + '/health', timeout=2) as response:
                health = json.load(response)
                assert response.status == 200
            assert health == {'status': 'ok', 'version': version}, health
            break
        except (URLError, TimeoutError):
            if attempt == 59:
                raise
            time.sleep(1)
    for path in ('/', '/static/style.css', '/static/app.js', '/api/health'):
        with urlopen(base + path, timeout=5) as response:
            assert response.status == 200, path
    try:
        urlopen(base + '/docs', timeout=5)
    except HTTPError as error:
        assert error.code == 404
    else:
        raise AssertionError('/docs should remain disabled')
    sample = '--------------- 2026년 10월 1일 목요일 ---------------\n[가상하늘] [오전 9:00] 프로젝트 회의\n[가상바다] [오전 9:02] 프로젝트 좋아'
    for encoding in ('utf-8-sig', 'cp949'):
        request = Request(base + '/api/analyze', data=sample.encode(encoding), headers={'Content-Type': 'text/plain'})
        with urlopen(request, timeout=5) as response:
            result = json.load(response)
            assert response.status == 200
            assert (result['total'], result['participant_count']) == (2, 2)
            assert result['replies'][0]['median_seconds'] == 120
    try:
        urlopen(Request(base + '/api/analyze', data=b'invalid', headers={'Content-Type': 'text/plain'}), timeout=5)
    except HTTPError as error:
        assert error.code == 422
    else:
        raise AssertionError('Invalid input should fail')
    print('PASS: health/version, homepage, static assets, disabled docs, UTF-8/CP949 analysis, invalid input')

if __name__ == '__main__':
    check(sys.argv[1], sys.argv[2])
