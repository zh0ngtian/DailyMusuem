import asyncio
import os
import time
import unittest

from fastapi import HTTPException
from starlette.requests import Request

from server.api.auth import (
    DebugAuthSessionRequest,
    canonical_request_hash,
    debug_assertion_for,
    issue_challenge,
    issue_debug_session,
    require_business_auth,
    simple_auth_signature_for,
)


class AuthTests(unittest.TestCase):
    def setUp(self) -> None:
        os.environ["MUSEUMMUSE_AUTH_MODE"] = "debug"
        os.environ["MUSEUMMUSE_DEBUG_AUTH_SECRET"] = "unit-test-secret"

    def tearDown(self) -> None:
        os.environ.pop("MUSEUMMUSE_AUTH_MODE", None)
        os.environ.pop("MUSEUMMUSE_DEBUG_AUTH_SECRET", None)
        os.environ.pop("MUSEUMMUSE_SIMPLE_AUTH_SECRET", None)

    def test_debug_session_authenticates_business_request_and_rejects_replay(self) -> None:
        challenge = issue_challenge(make_request()).challenge
        session = issue_debug_session(
            make_request(),
            DebugAuthSessionRequest(
                deviceID="device-1",
                keyID="debug-key",
                challenge=challenge,
                assertion=debug_assertion_for(challenge),
                appVersion="1.0 1",
            ),
        )
        timestamp = str(int(time.time()))
        nonce = "nonce-1"
        request_hash = canonical_request_hash(
            method="GET",
            path="/v1/museums",
            query_items=[("limit", "10")],
            body=b"",
            timestamp=timestamp,
            nonce=nonce,
        )
        headers = {
            "authorization": f"Bearer {session.accessToken}",
            "x-museummuse-timestamp": timestamp,
            "x-museummuse-nonce": nonce,
            "x-museummuse-request-hash": request_hash,
            "x-museummuse-app-attest-keyid": "debug-key",
            "x-museummuse-app-attest-assertion": debug_assertion_for(request_hash),
            "x-museummuse-app-version": "1.0 1",
        }
        request = make_request(path="/v1/museums", query_string=b"limit=10", headers=headers)

        asyncio.run(require_business_auth(request))

        with self.assertRaises(HTTPException) as context:
            asyncio.run(require_business_auth(make_request(path="/v1/museums", query_string=b"limit=10", headers=headers)))
        self.assertEqual(context.exception.status_code, 401)
        self.assertEqual(context.exception.detail["code"], "replayed_request")

    def test_debug_auth_rejects_tampered_request_hash(self) -> None:
        challenge = issue_challenge(make_request()).challenge
        session = issue_debug_session(
            make_request(),
            DebugAuthSessionRequest(
                deviceID="device-2",
                keyID="debug-key",
                challenge=challenge,
                assertion=debug_assertion_for(challenge),
                appVersion="1.0 1",
            ),
        )
        timestamp = str(int(time.time()))
        request_hash = canonical_request_hash(
            method="GET",
            path="/v1/museums",
            query_items=[],
            body=b"",
            timestamp=timestamp,
            nonce="nonce-2",
        )
        headers = {
            "authorization": f"Bearer {session.accessToken}",
            "x-museummuse-timestamp": timestamp,
            "x-museummuse-nonce": "nonce-2",
            "x-museummuse-request-hash": request_hash,
            "x-museummuse-app-attest-keyid": "debug-key",
            "x-museummuse-app-attest-assertion": debug_assertion_for(request_hash),
            "x-museummuse-app-version": "1.0 1",
        }

        with self.assertRaises(HTTPException) as context:
            asyncio.run(require_business_auth(make_request(path="/v1/museums/changed", headers=headers)))
        self.assertEqual(context.exception.status_code, 401)
        self.assertEqual(context.exception.detail["code"], "invalid_request_hash")

    def test_simple_auth_authenticates_business_request_and_rejects_replay(self) -> None:
        os.environ["MUSEUMMUSE_AUTH_MODE"] = "simple"
        os.environ["MUSEUMMUSE_SIMPLE_AUTH_SECRET"] = "unit-test-simple-secret"
        timestamp = str(int(time.time()))
        nonce = "simple-nonce-1"
        request_hash = canonical_request_hash(
            method="GET",
            path="/v1/museums",
            query_items=[("limit", "10")],
            body=b"",
            timestamp=timestamp,
            nonce=nonce,
        )
        headers = {
            "authorization": f"Bearer {simple_auth_signature_for(request_hash)}",
            "x-museummuse-timestamp": timestamp,
            "x-museummuse-nonce": nonce,
            "x-museummuse-request-hash": request_hash,
            "x-museummuse-app-version": "1.0 1",
        }
        request = make_request(path="/v1/museums", query_string=b"limit=10", headers=headers)

        asyncio.run(require_business_auth(request))

        with self.assertRaises(HTTPException) as context:
            asyncio.run(require_business_auth(make_request(path="/v1/museums", query_string=b"limit=10", headers=headers)))
        self.assertEqual(context.exception.status_code, 401)
        self.assertEqual(context.exception.detail["code"], "replayed_request")

    def test_simple_auth_rejects_expired_timestamp(self) -> None:
        os.environ["MUSEUMMUSE_AUTH_MODE"] = "simple"
        os.environ["MUSEUMMUSE_SIMPLE_AUTH_SECRET"] = "unit-test-simple-secret"
        timestamp = str(int(time.time()) - 11)
        nonce = "simple-nonce-expired"
        request_hash = canonical_request_hash(
            method="GET",
            path="/v1/museums",
            query_items=[],
            body=b"",
            timestamp=timestamp,
            nonce=nonce,
        )
        headers = {
            "authorization": f"Bearer {simple_auth_signature_for(request_hash)}",
            "x-museummuse-timestamp": timestamp,
            "x-museummuse-nonce": nonce,
            "x-museummuse-request-hash": request_hash,
            "x-museummuse-app-version": "1.0 1",
        }

        with self.assertRaises(HTTPException) as context:
            asyncio.run(require_business_auth(make_request(path="/v1/museums", headers=headers)))
        self.assertEqual(context.exception.status_code, 401)
        self.assertEqual(context.exception.detail["code"], "expired_request")


def make_request(
    *,
    method: str = "GET",
    path: str = "/v1/auth/challenge",
    query_string: bytes = b"",
    headers: dict[str, str] | None = None,
    body: bytes = b"",
) -> Request:
    raw_headers = [
        (name.lower().encode("latin-1"), value.encode("latin-1"))
        for name, value in (headers or {}).items()
    ]
    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "query_string": query_string,
        "headers": raw_headers,
        "client": ("127.0.0.1", 43210),
        "server": ("127.0.0.1", 8000),
        "scheme": "http",
    }

    async def receive() -> dict[str, object]:
        return {"type": "http.request", "body": body, "more_body": False}

    return Request(scope, receive)


if __name__ == "__main__":
    unittest.main()
