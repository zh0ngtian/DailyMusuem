#!/usr/bin/env python3
"""Probe MuseumMuse backend /v1 endpoints with simple HMAC auth."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


DEFAULT_PATHS = (
    "/v1/museums/metadata",
    "/v1/museums",
    "/v1/widget/candidate?scope=all",
)


def form_urlencode(value: str) -> str:
    return urllib.parse.quote(value, safe="-._~").replace("%20", "+")


def canonical_query(query: str) -> str:
    pairs = urllib.parse.parse_qsl(query, keep_blank_values=True)
    pairs.sort(key=lambda item: (item[0], item[1]))
    return "&".join(f"{form_urlencode(name)}={form_urlencode(value)}" for name, value in pairs)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def signed_headers(method: str, url: str, secret: str) -> dict[str, str]:
    parsed = urllib.parse.urlparse(url)
    timestamp = str(int(time.time()))
    nonce = str(uuid.uuid4())
    body = b""
    canonical = "\n".join(
        (
            method.upper(),
            parsed.path or "/",
            canonical_query(parsed.query),
            sha256_hex(body),
            timestamp,
            nonce,
        )
    )
    request_hash = sha256_hex(canonical.encode("utf-8"))
    signature = hmac.new(secret.encode("utf-8"), request_hash.encode("utf-8"), hashlib.sha256).hexdigest()
    return {
        "Accept": "application/json",
        "Authorization": f"Bearer {signature}",
        "User-Agent": "MuseumMuseBackendProbe/1.0",
        "X-MuseumMuse-Timestamp": timestamp,
        "X-MuseumMuse-Nonce": nonce,
        "X-MuseumMuse-Request-Hash": request_hash,
        "X-MuseumMuse-App-Version": "backend-probe",
    }


def join_url(base_url: str, path: str) -> str:
    return urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))


def request_status(url: str, headers: dict[str, str] | None, timeout: float) -> tuple[int, str]:
    request_headers = {"User-Agent": "MuseumMuseBackendProbe/1.0"}
    if headers:
        request_headers.update(headers)
    request = urllib.request.Request(url, headers=request_headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(200).decode("utf-8", errors="replace")
            return response.status, body
    except urllib.error.HTTPError as error:
        body = error.read(200).decode("utf-8", errors="replace")
        return error.code, body


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="Backend base URL, for example http://127.0.0.1:8000")
    parser.add_argument(
        "--path",
        action="append",
        dest="paths",
        help="Path to probe. Can be repeated. Defaults cover metadata, museums, and widget candidate.",
    )
    parser.add_argument(
        "--unsigned-check-path",
        default="/v1/museums/metadata",
        help="Path used to verify unsigned /v1 requests are rejected before signed probes run.",
    )
    parser.add_argument("--timeout", type=float, default=12.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    secret = os.getenv("MUSEUMMUSE_SIMPLE_AUTH_SECRET", "").strip() or os.getenv("SIMPLE_AUTH_SECRET", "").strip()
    if not secret:
        print("MUSEUMMUSE_SIMPLE_AUTH_SECRET or SIMPLE_AUTH_SECRET is required for backend probes.", file=sys.stderr)
        return 2

    unsigned_url = join_url(args.base_url, args.unsigned_check_path)
    unsigned_status, unsigned_body = request_status(unsigned_url, headers=None, timeout=args.timeout)
    if unsigned_status not in (401, 403):
        print(
            f"unsigned GET {args.unsigned_check_path} -> HTTP {unsigned_status}; expected 401/403. "
            f"Body prefix: {unsigned_body!r}",
            file=sys.stderr,
        )
        return 1
    print(f"unsigned GET {args.unsigned_check_path} -> HTTP {unsigned_status}")

    for path in args.paths or DEFAULT_PATHS:
        url = join_url(args.base_url, path)
        headers = signed_headers("GET", url, secret)
        status, body = request_status(url, headers=headers, timeout=args.timeout)
        print(f"signed GET {path} -> HTTP {status}")
        if status < 200 or status >= 300:
            print(f"Body prefix: {body!r}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
