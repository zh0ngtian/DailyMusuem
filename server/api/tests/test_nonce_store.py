import hashlib
import os
import unittest

from server.api.nonce_store import NonceReplayError, consume_cos_nonce


class FakeCosClient:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.requests: list[dict[str, object]] = []

    def put_object(self, **kwargs: object) -> None:
        self.requests.append(kwargs)
        if self.error:
            raise self.error


class FakeCosServiceError(Exception):
    def __init__(self, status_code: int, error_code: str) -> None:
        self.status_code = status_code
        self.error_code = error_code

    def get_status_code(self) -> int:
        return self.status_code

    def get_error_code(self) -> str:
        return self.error_code


class CosNonceStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        os.environ["MUSEUMMUSE_NONCE_COS_BUCKET"] = "museummuse-test-1250000000"

    def tearDown(self) -> None:
        os.environ.pop("MUSEUMMUSE_NONCE_COS_BUCKET", None)

    def test_cos_nonce_write_uses_hashed_key_and_forbids_overwrite(self) -> None:
        client = FakeCosClient()

        consume_cos_nonce(
            device_id="simple",
            nonce="secret-client-nonce",
            request_headers={},
            client=client,
        )

        expected_digest = hashlib.sha256(b"simple:secret-client-nonce").hexdigest()
        self.assertEqual(
            client.requests,
            [
                {
                    "Bucket": "museummuse-test-1250000000",
                    "Body": b"",
                    "Key": f"auth-nonces/{expected_digest[:2]}/{expected_digest}",
                    "ContentType": "application/octet-stream",
                    "ForbidOverwrite": "true",
                }
            ],
        )

    def test_cos_conflict_is_reported_as_replay(self) -> None:
        client = FakeCosClient(FakeCosServiceError(409, "FileAlreadyExists"))

        with self.assertRaises(NonceReplayError):
            consume_cos_nonce(
                device_id="simple",
                nonce="replayed",
                request_headers={},
                client=client,
            )


if __name__ == "__main__":
    unittest.main()
