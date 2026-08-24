from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import time
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1


@dataclass(frozen=True)
class StoredOAuthClient:
    client_id: str
    redirect_uris: tuple[str, ...]
    token_endpoint_auth_method: str
    client_name: str | None
    secret_digest: str | None
    grant_types: tuple[str, ...]
    response_types: tuple[str, ...]
    created_at: int
    updated_at: int


@dataclass(frozen=True)
class RefreshTokenRotation:
    status: str
    client_id: str | None = None
    resource: str | None = None
    refresh_token: str | None = None
    expires_at: int | None = None


class SQLiteOAuthStore:
    """Small, process-safe SQLite store for OAuth clients and refresh tokens."""

    def __init__(self, database_path: Path) -> None:
        self.database_path = database_path.expanduser().resolve()
        self.database_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            self.database_path.parent.chmod(0o700)
        except OSError:
            pass
        fd = os.open(self.database_path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        try:
            self.database_path.chmod(0o600)
        except OSError:
            pass
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    def _initialize(self) -> None:
        with closing(self._connect()) as connection, connection:
            version = int(connection.execute("PRAGMA user_version").fetchone()[0])
            if version > SCHEMA_VERSION:
                raise RuntimeError(
                    f"OAuth database schema {version} is newer than supported schema {SCHEMA_VERSION}"
                )
            if version < 1:
                connection.executescript(
                    """
                    CREATE TABLE oauth_clients (
                        client_id TEXT PRIMARY KEY,
                        client_secret_digest TEXT,
                        redirect_uris TEXT NOT NULL,
                        token_endpoint_auth_method TEXT NOT NULL,
                        client_name TEXT,
                        grant_types TEXT NOT NULL,
                        response_types TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        updated_at INTEGER NOT NULL
                    );

                    CREATE TABLE refresh_tokens (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        client_id TEXT NOT NULL REFERENCES oauth_clients(client_id),
                        token_hash TEXT NOT NULL UNIQUE,
                        family_id TEXT NOT NULL,
                        parent_id INTEGER REFERENCES refresh_tokens(id),
                        replaced_by_id INTEGER REFERENCES refresh_tokens(id),
                        resource TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        expires_at INTEGER NOT NULL,
                        revoked_at INTEGER,
                        used_at INTEGER
                    );

                    CREATE INDEX refresh_tokens_client_id_idx
                        ON refresh_tokens(client_id);
                    CREATE INDEX refresh_tokens_family_id_idx
                        ON refresh_tokens(family_id);
                    PRAGMA user_version = 1;
                    """
                )

    def client_count(self) -> int:
        with closing(self._connect()) as connection, connection:
            row = connection.execute("SELECT COUNT(*) FROM oauth_clients").fetchone()
        return int(row[0])

    def put_client(self, client: StoredOAuthClient, *, replace: bool = False) -> None:
        values = (
            client.client_id,
            client.secret_digest,
            json.dumps(client.redirect_uris, separators=(",", ":")),
            client.token_endpoint_auth_method,
            client.client_name,
            json.dumps(client.grant_types, separators=(",", ":")),
            json.dumps(client.response_types, separators=(",", ":")),
            client.created_at,
            client.updated_at,
        )
        with closing(self._connect()) as connection, connection:
            if replace:
                connection.execute(
                    """
                    INSERT INTO oauth_clients (
                        client_id, client_secret_digest, redirect_uris,
                        token_endpoint_auth_method, client_name, grant_types,
                        response_types, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(client_id) DO UPDATE SET
                        client_secret_digest = excluded.client_secret_digest,
                        redirect_uris = excluded.redirect_uris,
                        token_endpoint_auth_method = excluded.token_endpoint_auth_method,
                        client_name = excluded.client_name,
                        grant_types = excluded.grant_types,
                        response_types = excluded.response_types,
                        updated_at = excluded.updated_at
                    """,
                    values,
                )
            else:
                connection.execute(
                    """
                    INSERT INTO oauth_clients (
                        client_id, client_secret_digest, redirect_uris,
                        token_endpoint_auth_method, client_name, grant_types,
                        response_types, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    values,
                )

    def get_client(self, client_id: str) -> StoredOAuthClient | None:
        with closing(self._connect()) as connection, connection:
            row = connection.execute(
                "SELECT * FROM oauth_clients WHERE client_id = ?",
                (client_id,),
            ).fetchone()
        if row is None:
            return None
        return StoredOAuthClient(
            client_id=str(row["client_id"]),
            redirect_uris=tuple(json.loads(row["redirect_uris"])),
            token_endpoint_auth_method=str(row["token_endpoint_auth_method"]),
            client_name=row["client_name"],
            secret_digest=row["client_secret_digest"],
            grant_types=tuple(json.loads(row["grant_types"])),
            response_types=tuple(json.loads(row["response_types"])),
            created_at=int(row["created_at"]),
            updated_at=int(row["updated_at"]),
        )

    def issue_refresh_token(
        self,
        *,
        client_id: str,
        resource: str,
        ttl_seconds: int,
        now: int | None = None,
    ) -> tuple[str, int]:
        issued_at = int(time.time()) if now is None else now
        expires_at = issued_at + ttl_seconds
        token = secrets.token_urlsafe(48)
        token_hash = _token_hash(token)
        family_id = secrets.token_urlsafe(24)
        with closing(self._connect()) as connection, connection:
            connection.execute(
                """
                INSERT INTO refresh_tokens (
                    client_id, token_hash, family_id, resource, created_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (client_id, token_hash, family_id, resource, issued_at, expires_at),
            )
        return token, expires_at

    def rotate_refresh_token(
        self,
        token: str,
        *,
        client_id: str,
        resource: str | None,
        ttl_seconds: int,
        now: int | None = None,
    ) -> RefreshTokenRotation:
        rotated_at = int(time.time()) if now is None else now
        token_hash = _token_hash(token)
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT * FROM refresh_tokens WHERE token_hash = ?",
                (token_hash,),
            ).fetchone()
            if row is None or not secrets.compare_digest(str(row["client_id"]), client_id):
                connection.rollback()
                return RefreshTokenRotation("invalid")
            if row["used_at"] is not None:
                connection.execute(
                    """
                    UPDATE refresh_tokens
                    SET revoked_at = COALESCE(revoked_at, ?)
                    WHERE family_id = ? AND revoked_at IS NULL
                    """,
                    (rotated_at, row["family_id"]),
                )
                connection.commit()
                return RefreshTokenRotation("reused")
            if row["revoked_at"] is not None:
                connection.rollback()
                return RefreshTokenRotation("revoked")
            if int(row["expires_at"]) <= rotated_at:
                connection.rollback()
                return RefreshTokenRotation("expired")
            stored_resource = str(row["resource"])
            if resource and not secrets.compare_digest(stored_resource, resource):
                connection.rollback()
                return RefreshTokenRotation("invalid_target")

            replacement = secrets.token_urlsafe(48)
            replacement_hash = _token_hash(replacement)
            expires_at = rotated_at + ttl_seconds
            cursor = connection.execute(
                """
                INSERT INTO refresh_tokens (
                    client_id, token_hash, family_id, parent_id, resource,
                    created_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    client_id,
                    replacement_hash,
                    row["family_id"],
                    row["id"],
                    stored_resource,
                    rotated_at,
                    expires_at,
                ),
            )
            if cursor.lastrowid is None:
                connection.rollback()
                raise RuntimeError("SQLite did not return the replacement refresh-token ID")
            replacement_id = cursor.lastrowid
            updated = connection.execute(
                """
                UPDATE refresh_tokens
                SET used_at = ?, revoked_at = ?, replaced_by_id = ?
                WHERE id = ? AND used_at IS NULL AND revoked_at IS NULL
                """,
                (rotated_at, rotated_at, replacement_id, row["id"]),
            )
            if updated.rowcount != 1:
                connection.rollback()
                return RefreshTokenRotation("invalid")
            connection.commit()
            return RefreshTokenRotation(
                "rotated",
                client_id=client_id,
                resource=stored_resource,
                refresh_token=replacement,
                expires_at=expires_at,
            )
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def revoke_refresh_token(self, token: str, *, now: int | None = None) -> bool:
        revoked_at = int(time.time()) if now is None else now
        with closing(self._connect()) as connection, connection:
            cursor = connection.execute(
                """
                UPDATE refresh_tokens SET revoked_at = COALESCE(revoked_at, ?)
                WHERE token_hash = ?
                """,
                (revoked_at, _token_hash(token)),
            )
        return cursor.rowcount == 1

    def refresh_token_record(self, token: str) -> dict[str, Any] | None:
        """Return non-secret state for diagnostics and tests."""

        with closing(self._connect()) as connection, connection:
            row = connection.execute(
                """
                SELECT id, client_id, family_id, parent_id, replaced_by_id,
                       resource, created_at, expires_at, revoked_at, used_at
                FROM refresh_tokens WHERE token_hash = ?
                """,
                (_token_hash(token),),
            ).fetchone()
        return dict(row) if row is not None else None


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
