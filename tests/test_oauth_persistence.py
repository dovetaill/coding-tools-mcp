from __future__ import annotations

import sqlite3
import unittest
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory

from coding_tools_mcp.oauth import OAuthClientRegistry


class OAuthPersistenceTests(unittest.TestCase):
    def test_registered_client_survives_registry_recreation(self) -> None:
        with TemporaryDirectory() as tmp:
            database = Path(tmp) / "oauth.db"
            first = OAuthClientRegistry(database)
            registration = first.register(
                {
                    "client_name": "Persistent Client",
                    "redirect_uris": ["https://chatgpt.com/connector/callback"],
                    "grant_types": ["authorization_code", "refresh_token"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "client_secret_post",
                }
            )
            client_id = str(registration["client_id"])
            client_secret = str(registration["client_secret"])

            second = OAuthClientRegistry(database)
            client = second.get(client_id)

            self.assertIsNotNone(client)
            assert client is not None
            self.assertEqual(client.client_name, "Persistent Client")
            self.assertEqual(client.grant_types, ("authorization_code", "refresh_token"))
            self.assertTrue(second.authenticates(client_id, client_secret, "client_secret_post"))
            self.assertFalse(second.authenticates(client_id, "wrong", "client_secret_post"))

            with closing(sqlite3.connect(database)) as connection:
                stored_digest = connection.execute(
                    "SELECT client_secret_digest FROM oauth_clients WHERE client_id = ?",
                    (client_id,),
                ).fetchone()[0]
                version = connection.execute("PRAGMA user_version").fetchone()[0]
            self.assertNotEqual(stored_digest, client_secret)
            self.assertEqual(version, 1)

    def test_revoked_refresh_token_is_rejected_without_plaintext_storage(self) -> None:
        with TemporaryDirectory() as tmp:
            registry = OAuthClientRegistry(Path(tmp) / "oauth.db")
            registration = registry.register(
                {
                    "redirect_uris": ["http://127.0.0.1/callback"],
                    "grant_types": ["authorization_code", "refresh_token"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "none",
                }
            )
            client_id = str(registration["client_id"])
            refresh_token, _expires_at = registry.store.issue_refresh_token(
                client_id=client_id,
                resource="https://mcp.example.com",
                ttl_seconds=3600,
                now=100,
            )
            self.assertTrue(registry.store.revoke_refresh_token(refresh_token, now=101))

            restarted = OAuthClientRegistry(Path(tmp) / "oauth.db")
            result = restarted.store.rotate_refresh_token(
                refresh_token,
                client_id=client_id,
                resource="https://mcp.example.com",
                ttl_seconds=3600,
                now=102,
            )
            self.assertEqual(result.status, "revoked")

            with closing(sqlite3.connect(restarted.database_path)) as connection:
                stored_hash = connection.execute("SELECT token_hash FROM refresh_tokens").fetchone()[0]
            self.assertNotEqual(stored_hash, refresh_token)


if __name__ == "__main__":
    unittest.main()
