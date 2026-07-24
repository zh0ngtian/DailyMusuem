import asyncio
import hashlib
import os
import threading
from collections.abc import Mapping


class NonceReplayError(Exception):
    pass


class NonceStoreUnavailableError(Exception):
    pass


_memory_lock = threading.Lock()
_memory_nonces: dict[str, float] = {}


async def consume_nonce(
    *,
    device_id: str,
    nonce: str,
    now: int,
    ttl_seconds: int,
    request_headers: Mapping[str, str],
) -> None:
    store = os.getenv("MUSEUMMUSE_NONCE_STORE", "memory").strip().lower()
    if store == "memory":
        _consume_memory_nonce(device_id=device_id, nonce=nonce, now=now, ttl_seconds=ttl_seconds)
        return
    if store == "cos":
        await asyncio.to_thread(
            consume_cos_nonce,
            device_id=device_id,
            nonce=nonce,
            request_headers=request_headers,
        )
        return
    raise NonceStoreUnavailableError(f"Unsupported nonce store: {store}")


def consume_cos_nonce(
    *,
    device_id: str,
    nonce: str,
    request_headers: Mapping[str, str],
    client: object | None = None,
) -> None:
    bucket = os.getenv("MUSEUMMUSE_NONCE_COS_BUCKET", "").strip()
    region = (
        os.getenv("MUSEUMMUSE_NONCE_COS_REGION", "").strip()
        or os.getenv("TENCENTCLOUD_REGION", "").strip()
    )
    if not bucket:
        raise NonceStoreUnavailableError("MUSEUMMUSE_NONCE_COS_BUCKET is required.")
    if client is None:
        if not region:
            raise NonceStoreUnavailableError("MUSEUMMUSE_NONCE_COS_REGION is required.")
        client = _build_cos_client(region=region, request_headers=request_headers)

    digest = hashlib.sha256(f"{device_id}:{nonce}".encode("utf-8")).hexdigest()
    object_key = f"auth-nonces/{digest[:2]}/{digest}"
    try:
        client.put_object(
            Bucket=bucket,
            Body=b"",
            Key=object_key,
            ContentType="application/octet-stream",
            ForbidOverwrite="true",
        )
    except Exception as exc:
        status_code = _cos_error_value(exc, "get_status_code")
        error_code = _cos_error_value(exc, "get_error_code")
        if status_code == 409 and error_code == "FileAlreadyExists":
            raise NonceReplayError from exc
        raise NonceStoreUnavailableError(
            f"COS nonce write failed: {error_code or status_code or type(exc).__name__}"
        ) from exc


def _consume_memory_nonce(*, device_id: str, nonce: str, now: int, ttl_seconds: int) -> None:
    nonce_key = f"{device_id}:{nonce}"
    with _memory_lock:
        for existing_nonce, expires_at in list(_memory_nonces.items()):
            if expires_at <= now:
                _memory_nonces.pop(existing_nonce, None)
        if nonce_key in _memory_nonces:
            raise NonceReplayError
        _memory_nonces[nonce_key] = now + ttl_seconds


def _build_cos_client(*, region: str, request_headers: Mapping[str, str]) -> object:
    try:
        from qcloud_cos import CosConfig, CosS3Client
        from qcloud_cos.cos_client import maplist
    except ImportError as exc:
        raise NonceStoreUnavailableError("Tencent COS SDK is unavailable.") from exc

    secret_id = _credential_value(request_headers, "x-scf-secret-id", "TENCENTCLOUD_SECRETID")
    secret_key = _credential_value(request_headers, "x-scf-secret-key", "TENCENTCLOUD_SECRETKEY")
    token = _credential_value(request_headers, "x-scf-session-token", "TENCENTCLOUD_SESSIONTOKEN")
    if not secret_id or not secret_key or not token:
        raise NonceStoreUnavailableError("SCF runtime role credentials are unavailable.")

    # cos-python-sdk-v5 1.9.x does not yet expose this current COS header
    # through its public parameter map.
    maplist.setdefault("ForbidOverwrite", "x-cos-forbid-overwrite")
    config = CosConfig(
        Region=region,
        SecretId=secret_id,
        SecretKey=secret_key,
        Token=token,
        Scheme="https",
        Timeout=3,
    )
    return CosS3Client(config)


def _credential_value(
    request_headers: Mapping[str, str],
    header_name: str,
    environment_name: str,
) -> str:
    header_value = request_headers.get(header_name, "")
    return str(header_value).strip() or os.getenv(environment_name, "").strip()


def _cos_error_value(exc: Exception, method_name: str) -> object | None:
    method = getattr(exc, method_name, None)
    if not callable(method):
        return None
    try:
        return method()
    except Exception:
        return None
