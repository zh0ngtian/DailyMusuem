import base64
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from ipaddress import ip_address
from urllib.parse import urlencode

from fastapi import HTTPException, Request, status
from pydantic import BaseModel, Field


LOCAL_HOSTS = {"127.0.0.1", "::1", "localhost"}
CHALLENGE_TTL_SECONDS = 300
SESSION_TTL_SECONDS = 30 * 60
NONCE_TTL_SECONDS = 10 * 60
MAX_TIMESTAMP_SKEW_SECONDS = 5 * 60

_lock = threading.Lock()
_challenges: dict[str, float] = {}
_nonces: dict[str, float] = {}


class AuthChallengeDTO(BaseModel):
    challenge: str
    expiresAt: int
    mode: str


class DebugAuthRegistrationRequest(BaseModel):
    deviceID: str = Field(min_length=1)
    keyID: str = Field(min_length=1)
    challenge: str = Field(min_length=1)
    assertion: str = Field(min_length=1)
    appVersion: str = Field(min_length=1)


class DebugAuthRegistrationDTO(BaseModel):
    deviceID: str
    keyID: str
    registered: bool


class DebugAuthSessionRequest(BaseModel):
    deviceID: str = Field(min_length=1)
    keyID: str = Field(min_length=1)
    challenge: str = Field(min_length=1)
    assertion: str = Field(min_length=1)
    appVersion: str = Field(min_length=1)


class AuthSessionDTO(BaseModel):
    accessToken: str
    tokenType: str = "Bearer"
    expiresAt: int


def _is_local_host(host: str | None) -> bool:
    if not host:
        return False
    if host in LOCAL_HOSTS:
        return True
    try:
        return ip_address(host).is_loopback
    except ValueError:
        return False


async def require_business_auth(request: Request) -> None:
    auth_mode = _auth_mode()
    is_local = _is_local_host(request.client.host if request.client else None)
    if auth_mode == "disabled" and is_local:
        return
    if auth_mode == "debug" and is_local:
        await _require_debug_auth(request)
        return

    _require_headers_present(request)
    raise HTTPException(
        status_code=status.HTTP_501_NOT_IMPLEMENTED,
        detail={
            "code": "app_attest_not_configured",
            "message": "App Attest verification is not configured for this server.",
        },
    )


def issue_challenge(request: Request) -> AuthChallengeDTO:
    _require_debug_mode(request)
    now = int(time.time())
    challenge = secrets.token_urlsafe(32)
    expires_at = now + CHALLENGE_TTL_SECONDS
    with _lock:
        _prune_locked(now)
        _challenges[challenge] = expires_at
    return AuthChallengeDTO(challenge=challenge, expiresAt=expires_at, mode="debug")


def register_debug_device(request: Request, payload: DebugAuthRegistrationRequest) -> DebugAuthRegistrationDTO:
    _require_debug_mode(request)
    _consume_challenge(payload.challenge)
    _verify_debug_assertion(payload.challenge, payload.assertion)
    return DebugAuthRegistrationDTO(deviceID=payload.deviceID, keyID=payload.keyID, registered=True)


def issue_debug_session(request: Request, payload: DebugAuthSessionRequest) -> AuthSessionDTO:
    _require_debug_mode(request)
    _consume_challenge(payload.challenge)
    _verify_debug_assertion(payload.challenge, payload.assertion)
    now = int(time.time())
    expires_at = now + SESSION_TTL_SECONDS
    token = _encode_token(
        {
            "device_id": payload.deviceID,
            "key_id": payload.keyID,
            "app_version": payload.appVersion,
            "iat": now,
            "exp": expires_at,
            "mode": "debug",
        }
    )
    return AuthSessionDTO(accessToken=token, expiresAt=expires_at)


def debug_assertion_for(value: str) -> str:
    return hmac.new(_debug_secret(), value.encode("utf-8"), hashlib.sha256).hexdigest()


def canonical_request_hash(
    *,
    method: str,
    path: str,
    query_items: list[tuple[str, str]],
    body: bytes,
    timestamp: str,
    nonce: str,
) -> str:
    canonical_query = urlencode(sorted(query_items), doseq=True)
    body_hash = hashlib.sha256(body).hexdigest()
    canonical = "\n".join(
        [
            method.upper(),
            path,
            canonical_query,
            body_hash,
            timestamp,
            nonce,
        ]
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


async def _require_debug_auth(request: Request) -> None:
    _require_headers_present(request)
    authorization = request.headers["authorization"]
    timestamp = request.headers["x-museummuse-timestamp"]
    nonce = request.headers["x-museummuse-nonce"]
    request_hash = request.headers["x-museummuse-request-hash"]
    key_id = request.headers["x-museummuse-app-attest-keyid"]
    assertion = request.headers["x-museummuse-app-attest-assertion"]
    app_version = request.headers["x-museummuse-app-version"]

    token_payload = _decode_token(authorization.removeprefix("Bearer ").strip())
    if token_payload.get("mode") != "debug":
        _raise_auth("invalid_token", "Invalid auth token.")
    if token_payload.get("key_id") != key_id:
        _raise_auth("invalid_token", "Token key id does not match request header.")
    if token_payload.get("app_version") != app_version:
        _raise_auth("invalid_token", "Token app version does not match request header.")

    now = int(time.time())
    try:
        request_time = int(timestamp)
    except ValueError:
        _raise_auth("invalid_timestamp", "Invalid request timestamp.")
    if abs(now - request_time) > MAX_TIMESTAMP_SKEW_SECONDS:
        _raise_auth("expired_request", "Request timestamp is outside the allowed window.")

    body = await request.body()
    expected_hash = canonical_request_hash(
        method=request.method,
        path=request.url.path,
        query_items=[(key, value) for key, value in request.query_params.multi_items()],
        body=body,
        timestamp=timestamp,
        nonce=nonce,
    )
    if not hmac.compare_digest(request_hash, expected_hash):
        _raise_auth("invalid_request_hash", "Request hash does not match request.")
    _verify_debug_assertion(request_hash, assertion)
    _consume_nonce(device_id=str(token_payload["device_id"]), nonce=nonce, now=now)


def _auth_mode() -> str:
    return os.getenv("MUSEUMMUSE_AUTH_MODE", "").strip().lower()


def _require_debug_mode(request: Request) -> None:
    if _auth_mode() != "debug" or not _is_local_host(request.client.host if request.client else None):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "debug_auth_unavailable", "message": "Debug auth is only available on loopback in debug mode."},
        )


def _require_headers_present(request: Request) -> None:
    authorization = request.headers.get("authorization", "")
    required_values = [
        authorization.startswith("Bearer "),
        bool(request.headers.get("x-museummuse-timestamp")),
        bool(request.headers.get("x-museummuse-nonce")),
        bool(request.headers.get("x-museummuse-request-hash")),
        bool(request.headers.get("x-museummuse-app-attest-keyid")),
        bool(request.headers.get("x-museummuse-app-attest-assertion")),
        bool(request.headers.get("x-museummuse-app-version")),
    ]
    if not all(required_values):
        _raise_auth("authentication_required", "Authentication is required.")


def _debug_secret() -> bytes:
    secret = os.getenv("MUSEUMMUSE_DEBUG_AUTH_SECRET", "").strip()
    if not secret:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"code": "debug_auth_secret_missing", "message": "MUSEUMMUSE_DEBUG_AUTH_SECRET is required in debug auth mode."},
        )
    return secret.encode("utf-8")


def _encode_token(payload: dict[str, object]) -> str:
    payload_part = _base64url(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8"))
    signature = _base64url(hmac.new(_debug_secret(), payload_part.encode("ascii"), hashlib.sha256).digest())
    return f"{payload_part}.{signature}"


def _decode_token(token: str) -> dict[str, object]:
    try:
        payload_part, signature = token.split(".", 1)
    except ValueError:
        _raise_auth("invalid_token", "Invalid auth token.")
    expected_signature = _base64url(hmac.new(_debug_secret(), payload_part.encode("ascii"), hashlib.sha256).digest())
    if not hmac.compare_digest(signature, expected_signature):
        _raise_auth("invalid_token", "Invalid auth token.")
    try:
        payload = json.loads(_base64url_decode(payload_part).decode("utf-8"))
    except (ValueError, json.JSONDecodeError):
        _raise_auth("invalid_token", "Invalid auth token.")
    if int(payload.get("exp", 0)) <= int(time.time()):
        _raise_auth("expired_token", "Auth token has expired.")
    return payload


def _verify_debug_assertion(value: str, assertion: str) -> None:
    if not hmac.compare_digest(assertion, debug_assertion_for(value)):
        _raise_auth("invalid_assertion", "Invalid debug assertion.")


def _consume_challenge(challenge: str) -> None:
    now = int(time.time())
    with _lock:
        _prune_locked(now)
        expires_at = _challenges.pop(challenge, None)
    if expires_at is None or expires_at <= now:
        _raise_auth("invalid_challenge", "Challenge is invalid or expired.")


def _consume_nonce(*, device_id: str, nonce: str, now: int) -> None:
    nonce_key = f"{device_id}:{nonce}"
    with _lock:
        _prune_locked(now)
        if nonce_key in _nonces:
            _raise_auth("replayed_request", "Request nonce has already been used.")
        _nonces[nonce_key] = now + NONCE_TTL_SECONDS


def _prune_locked(now: int) -> None:
    for challenge, expires_at in list(_challenges.items()):
        if expires_at <= now:
            _challenges.pop(challenge, None)
    for nonce, expires_at in list(_nonces.items()):
        if expires_at <= now:
            _nonces.pop(nonce, None)


def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _base64url_decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def _raise_auth(code: str, message: str) -> None:
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail={"code": code, "message": message},
    )
