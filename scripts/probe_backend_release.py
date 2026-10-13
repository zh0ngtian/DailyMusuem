#!/usr/bin/env python3
"""Read-only six-museum release acceptance, including authenticated nonce replay."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

try:
    from .probe_backend_simple_auth import signed_headers
except ImportError:
    from probe_backend_simple_auth import signed_headers

FORMAL_MUSEUMS = {'nmc', 'shm', 'met', 'tnm', 'nnm', 'guimet'}


def load_secret(repository=None):
    secret = os.getenv('MUSEUMMUSE_SIMPLE_AUTH_SECRET', '').strip() or os.getenv('SIMPLE_AUTH_SECRET', '').strip()
    if not secret and repository:
        path = Path(repository) / 'Config/Secrets.local.xcconfig'
        if path.exists():
            match = re.search(r'^\s*MUSEUMMUSE_SIMPLE_AUTH_SECRET\s*=\s*(.*?)\s*$', path.read_text(), re.MULTILINE)
            if match:
                secret = match.group(1).strip().strip('"')
    if not secret:
        raise RuntimeError('MUSEUMMUSE_SIMPLE_AUTH_SECRET is required (environment or private Config/Secrets.local.xcconfig)')
    return secret


def request_json(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {}, method='GET')
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            body = json.load(error)
        except ValueError:
            body = {}
        return error.code, body


def probe_release(base_url, secret, expected_marker=None, data_version=None, request=request_json):
    base = base_url.rstrip('/')
    def get(path, signed=True):
        url = base + path
        status, body = request(url, signed_headers('GET', url, secret) if signed else {})
        if status != 200:
            raise RuntimeError('Backend required channel failed: ' + path.split('?')[0] + ' HTTP ' + str(status))
        return body
    health = get('/health', signed=False)
    if not health.get('ok') or not health.get('databaseReadable'):
        raise RuntimeError('Backend health/readability failed')
    if data_version and health.get('dataVersion') != data_version:
        raise RuntimeError('Backend dataVersion differs from frozen input')
    if expected_marker and health.get('releaseMarker') != expected_marker:
        raise RuntimeError('Backend releaseMarker differs from frozen source/input')
    status, _ = request(base + '/v1/museums/metadata', {})
    if status not in (401, 403):
        raise RuntimeError('Unsigned business endpoint was not rejected')
    metadata = get('/v1/museums/metadata')
    museums = metadata['data']['museums']
    actual = {item['museumID'] for item in museums}
    if actual != FORMAL_MUSEUMS:
        raise RuntimeError('Metadata formal six-museum set differs')
    listing = get('/v1/museums')['data']
    if not isinstance(listing, list) or {item['museumID'] for item in listing} != FORMAL_MUSEUMS:
        raise RuntimeError('Museum list differs from formal six-museum set')
    checked = []
    for museum in museums:
        mid = urllib.parse.quote(museum['museumID'], safe='')
        source = urllib.parse.quote(museum['defaultSourceKey'], safe='')
        rows = get('/v1/museums/' + mid + '/artworks?source=' + source + '&limit=1')['data']['items']
        if not rows:
            raise RuntimeError('Museum list has no artwork: ' + mid)
        oid = urllib.parse.quote(rows[0]['objectID'], safe='')
        detail = get('/v1/museums/' + mid + '/artworks/' + oid + '?source=' + source)['data']
        if detail.get('objectID') != rows[0]['objectID'] or detail.get('museumID') != museum['museumID']:
            raise RuntimeError('Museum detail reference differs: ' + mid)
        checked.append(museum['museumID'])
    candidate = get('/v1/widget/candidate?scope=all')['data'].get('artwork')
    if not isinstance(candidate, dict) or candidate.get('museumID') not in FORMAL_MUSEUMS or not candidate.get('objectID'):
        raise RuntimeError('Widget candidate required channel failed')
    url = base + '/v1/museums/metadata'
    headers = signed_headers('GET', url, secret)
    first, _ = request(url, headers)
    second, body = request(url, headers)  # Deliberately exactly the same signed headers.
    if first != 200 or second != 401 or body.get('error', {}).get('code') != 'replayed_request':
        raise RuntimeError('Nonce replay required channel failed')
    return {'passed': True, 'baseURL': base, 'dataVersion': health['dataVersion'],
            'releaseMarker': health.get('releaseMarker', {}), 'museumsVerified': sorted(checked),
            'checks': ['health', 'unsigned-rejection', 'metadata-six-museums', 'museum-list', 'six-museum-list-detail', 'widget-candidate', 'nonce-replay-401'],
            'nonceReplayStatus': second}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--repository')
    parser.add_argument('--expected-marker')
    parser.add_argument('--data-version')
    args = parser.parse_args()
    try:
        marker = json.loads(Path(args.expected_marker).read_text()) if args.expected_marker else None
        result = probe_release(args.base_url, load_secret(args.repository), marker, args.data_version)
    except Exception as exc:
        message = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        print(message, file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
