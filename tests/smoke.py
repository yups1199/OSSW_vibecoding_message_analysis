"""Real HTTP smoke check, usable against local processes and containers.

Usage: python tests/smoke.py http://127.0.0.1:8000 expected-version
Only Python's standard library is required.
"""
import json
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from wait_ready import wait_ready

def check(base, version):
    base = base.rstrip('/')
    # Also wait during standalone use or a transient drop after CI readiness.
    wait_ready(base, version)
    for path in ('/', '/static/style.css', '/static/app.js', '/api/health', '/docs', '/openapi.json', '/static/docs.js', '/static/vendor/swagger-ui/swagger-ui-bundle.js', '/static/vendor/swagger-ui/swagger-ui.css'):
        with urlopen(base + path, timeout=5) as response:
            assert response.status == 200, path
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
        with error:
            assert error.code == 422
    else:
        raise AssertionError('Invalid input should fail')
    print('PASS: health/version, homepage, static assets, local Swagger docs, UTF-8/CP949 analysis, invalid input')

if __name__ == '__main__':
    check(sys.argv[1], sys.argv[2])
