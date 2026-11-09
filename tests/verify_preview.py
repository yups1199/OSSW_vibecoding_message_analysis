"""Opt-in isolated browser preview; requires Playwright + installed Edge.

Never starts/replaces production containers. Uses a random local port.
"""
import os
from pathlib import Path
import socket
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.environ['APP_VERSION'] = 'sha-' + 'a' * 40
import uvicorn
from app.main import app
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(ROOT / 'tests'))
from smoke import check

out = ROOT / '.deploy-state/evidence'
out.mkdir(parents=True, exist_ok=True)
sock = socket.socket()
sock.bind(('127.0.0.1', 0))
port = sock.getsockname()[1]
server = uvicorn.Server(uvicorn.Config(app, log_level='error', access_log=False))
thread = threading.Thread(target=lambda: server.run(sockets=[sock]), daemon=True)
thread.start()
try:
    deadline = time.monotonic() + 10
    while not server.started:
        if time.monotonic() > deadline:
            raise RuntimeError('Preview failed to start')
        time.sleep(.05)
    base = f'http://127.0.0.1:{port}'
    check(base, os.environ['APP_VERSION'])
    with sync_playwright() as p:
        browser = p.chromium.launch(channel='msedge', headless=True)
        try:
            page = browser.new_page(viewport={'width': 1440, 'height': 1000}, device_scale_factor=1)
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.goto(base)
            page.locator('#deployment-version[data-version]').wait_for()
            assert page.locator('#deployment-version').get_attribute('data-version') == os.environ['APP_VERSION']
            page.locator('#sample').click()
            page.locator('#analyze').click()
            page.locator('#results:not([hidden])').wait_for()
            assert page.locator('#busiest-days').inner_text() == '목요일'
            assert '6개 메시지' in page.locator('#busiest-detail').inner_text()
            assert '50%' in page.locator('#busiest-detail').inner_text()
            page.screenshot(path=str(out / 'local-preview-dashboard.png'), full_page=True)
            page.set_viewport_size({'width': 390, 'height': 844})
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
            page.screenshot(path=str(out / 'local-preview-mobile.png'), full_page=True)
            page.locator('#reset').click()
            sample = '2026. 11. 8. 09:00, SyntheticA : hello\n2026. 11. 9. 09:00, SyntheticB : friend'
            page.locator('#file').set_input_files({'name': 'synthetic.txt', 'mimeType': 'text/plain', 'buffer': sample.encode()})
            page.locator('#analyze').click()
            page.locator('#results:not([hidden])').wait_for()
            assert page.locator('#busiest-days').inner_text() == '월요일 · 일요일'
            assert '공동 1위' in page.locator('#busiest-detail').inner_text()
            page.goto(base + '/docs')
            page.locator('.swagger-ui .opblock').first.wait_for()
            assert not errors, errors
            print('PASS: isolated browser sample, file upload, weekday tie, version badge, mobile and Swagger; no JS errors')
        finally:
            browser.close()
finally:
    server.should_exit = True
    thread.join(10)
    sock.close()
    assert not thread.is_alive(), 'Preview did not stop'
    with socket.socket() as probe:
        assert probe.connect_ex(('127.0.0.1', port)) != 0, 'Preview port still open'
    print(f'PASS: isolated preview stopped and port {port} released')
