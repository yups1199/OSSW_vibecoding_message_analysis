"""Opt-in Windows integration checks. Real local HTTP, simulated deployment.

Requires process-only ExecutionPolicy Bypass approval. Never operates Docker.
Run: python -B tests/verify_monitoring.py
Evidence is deliberately labelled local-http-test, never deployment proof.
"""
import json
import subprocess
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OLD, NEW = 'sha-' + '1' * 40, 'sha-' + '2' * 40


def run_case(case, before, after):
    state = {'version': OLD, 'switched': False}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def respond(self, body, status=200, content_type='application/json'):
            body = body.encode()
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == '/health':
                if state['switched'] and case == 'timeout':
                    time.sleep(3)
                    return
                if state['switched'] and case == 'disconnect':
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if state['switched'] and case == 'invalid-json':
                    self.respond('invalid-json')
                    return
                self.respond(json.dumps({'status': 'ok', 'version': state['version']}),
                             503 if case == 'http503' and state['switched'] else 200)
            elif self.path == '/':
                self.respond('<article data-feature="busiest-weekday-v1"></article>', content_type='text/html')
            elif self.path == '/test-case':
                self.respond(json.dumps({'mode': case}))
            else:
                self.respond('{}', 404)

        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            if self.path == '/test-switch':
                state['switched'] = True
                if case != 'unchanged':
                    state['version'] = NEW
                self.respond('{}')
            elif self.path == '/api/analyze':
                self.respond(json.dumps({'total': 2, 'busiest_weekday': {
                    'weekday_indexes': [6], 'message_count': 2, 'ratio': 100}}))
            else:
                self.respond('{}', 404)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    evidence = ROOT / '.deploy-state' / ('http-test-' + case + '-' + uuid.uuid4().hex)
    command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
               str(ROOT / 'deploy/Invoke-MonitoredDeploy.ps1'), '-Repository', 'test/synthetic',
               '-CommitSha', '2' * 40, '-CiRunId', '1', '-CiRunNumber', '1',
               '-ImageName', 'synthetic/kakao-chat-analyzer', '-OutputDirectory', str(evidence),
               '-BaseUri', f'http://127.0.0.1:{server.server_port}',
               '-BeforeSeconds', str(before), '-AfterSeconds', str(after),
               '-Mode', 'local-http-test', '-DeploymentScript', str(ROOT / 'tests/fixture_deploy.ps1')]
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=150)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)
    (evidence / 'test-process.txt').write_bytes(result.stdout + result.stderr)
    summary = json.loads((evidence / 'summary.json').read_text(encoding='utf-8-sig'))
    assert not summary['zero_downtime_verified'], summary
    if case == 'success':
        assert result.returncode == 0 and summary['validation_passed'], summary
        assert summary['failure'] == 0 and summary['old_version'] == OLD and summary['final_version'] == NEW
        assert summary['phases']['before']['span_seconds'] >= 10
        assert summary['phases']['after']['span_seconds'] >= 30
        assert summary['post_completion_seconds'] >= 30
    else:
        assert result.returncode != 0 and not summary['validation_passed'], summary
        if case in ('http503', 'timeout', 'disconnect', 'invalid-json'):
            assert summary['failure'] > 0
        if case == 'unchanged':
            assert any('version change' in reason for reason in summary['reasons'])
        if case == 'monitor-stop':
            assert any('monitor' in reason.lower() for reason in summary['reasons'])
    print(f'PASS {case}: {summary["requests"]} real HTTP samples; '
          f'failures={summary["failure"]}; validation={summary["validation_passed"]}; {evidence}', flush=True)


if __name__ == '__main__':
    run_case('success', 10, 30)
    run_case('http503', 1, 1)
    run_case('unchanged', 1, 1)
    for case in ('timeout', 'disconnect', 'invalid-json', 'monitor-stop'):
        run_case(case, 1, 1)
