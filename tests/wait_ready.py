"""Bounded HTTP readiness check using only Python's standard library.

Usage: python tests/wait_ready.py http://127.0.0.1:8000 expected-version
"""
import argparse
from http.client import HTTPException
import json
import time
from urllib.error import HTTPError, URLError
from urllib.request import urlopen


def wait_ready(base, version, attempts=30, timeout=3, interval=1):
    if attempts < 1 or timeout <= 0 or interval < 0:
        raise ValueError('Invalid readiness retry settings')
    url = base.rstrip('/') + '/health'
    last_error = None
    for attempt in range(1, attempts + 1):
        try:
            with urlopen(url, timeout=timeout) as response:
                if response.status != 200:
                    raise URLError(f'HTTP {response.status}, expected 200')
                health = json.load(response)
            # A responsive but wrong service/image is a terminal failure.
            if health != {'status': 'ok', 'version': version}:
                raise ValueError('Health status/version mismatch')
            print(f'READY: HTTP 200, status=ok, version={version} (attempt {attempt}/{attempts})', flush=True)
            return
        except (OSError, HTTPException) as error:
            # Includes URLError/HTTPError, reset/refused/aborted connections,
            # timeouts, RemoteDisconnected and incomplete HTTP reads.
            last_error = error
            print(f'WAIT: attempt {attempt}/{attempts}: {type(error).__name__}: {error}', flush=True)
            if isinstance(error, HTTPError):
                error.close()
            if attempt < attempts:
                time.sleep(interval)
    raise RuntimeError(f'HTTP readiness failed after {attempts} attempts') from last_error


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base_url')
    parser.add_argument('version')
    parser.add_argument('--attempts', type=int, default=30)
    parser.add_argument('--timeout', type=float, default=3)
    parser.add_argument('--interval', type=float, default=1)
    args = parser.parse_args()
    wait_ready(args.base_url, args.version, args.attempts, args.timeout, args.interval)
