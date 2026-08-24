from __future__ import annotations

import base64
import hashlib
import os
import re
import secrets
import sqlite3
import threading
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import jwt

from .oauth_store import SQLiteOAuthStore, StoredOAuthClient


OAUTH_CODE_TTL_SECONDS = 300
OAUTH_ACCESS_TOKEN_TTL_SECONDS = 60 * 60
OAUTH_REFRESH_TOKEN_TTL_SECONDS = 90 * 24 * 60 * 60
# Backward-compatible import name. New code and configuration call this the
# access-token TTL because refresh tokens have an independent lifetime.
OAUTH_TOKEN_TTL_SECONDS = OAUTH_ACCESS_TOKEN_TTL_SECONDS
OAUTH_MAX_BODY_BYTES = 8_192
OAUTH_GRANT_TYPE_AUTHORIZATION_CODE = "authorization_code"
OAUTH_GRANT_TYPE_REFRESH_TOKEN = "refresh_token"
OAUTH_GRANT_TYPES_SUPPORTED = (
    OAUTH_GRANT_TYPE_AUTHORIZATION_CODE,
    OAUTH_GRANT_TYPE_REFRESH_TOKEN,
)
OAUTH_RESPONSE_TYPES_SUPPORTED = ("code",)
MAX_REDIRECT_URIS = 10
MAX_REGISTERED_CLIENTS = 1_024
MAX_PENDING_CODES = 256


@dataclass(frozen=True)
class OAuthClient:
    client_id: str
    redirect_uris: tuple[str, ...]
    token_endpoint_auth_method: str
    client_name: str | None = None
    secret_digest: str | None = None
    grant_types: tuple[str, ...] = OAUTH_GRANT_TYPES_SUPPORTED
    response_types: tuple[str, ...] = OAUTH_RESPONSE_TYPES_SUPPORTED
    issued_at: int = field(default_factory=lambda: int(time.time()))
    updated_at: int = field(default_factory=lambda: int(time.time()))

    def accepts_redirect(self, redirect_uri: str) -> bool:
        return redirect_uri in self.redirect_uris

    def verifies_secret(self, secret: str) -> bool:
        if self.token_endpoint_auth_method == "none":
            return not secret
        if self.secret_digest is None or not secret:
            return False
        return secrets.compare_digest(self.secret_digest, _secret_digest(secret))

    def allows_grant(self, grant_type: str) -> bool:
        return grant_type in self.grant_types


class OAuthClientRegistry:
    """RFC 7591 client registry backed by a persistent SQLite store."""

    def __init__(self, database_path: Path | None = None) -> None:
        path = database_path or default_oauth_database_path()
        self.store = SQLiteOAuthStore(path)

    @property
    def database_path(self) -> Path:
        return self.store.database_path

    def add_preregistered(
        self,
        client_id: str,
        redirect_uris: tuple[str, ...],
        *,
        client_secret: str | None,
    ) -> None:
        redirects = validate_redirect_uris(list(redirect_uris))
        method = "client_secret_post" if client_secret is not None else "none"
        now = int(time.time())
        existing = self.get(client_id)
        client = OAuthClient(
            client_id=client_id,
            redirect_uris=redirects,
            token_endpoint_auth_method=method,
            secret_digest=_secret_digest(client_secret) if client_secret is not None else None,
            issued_at=existing.issued_at if existing is not None else now,
            updated_at=now,
        )
        self.store.put_client(_stored_client(client), replace=True)

    def register(self, metadata: dict[str, Any]) -> dict[str, Any]:
        redirects = validate_redirect_uris(metadata.get("redirect_uris"))
        requested_grant_types = metadata.get("grant_types", list(OAUTH_GRANT_TYPES_SUPPORTED))
        requested_response_types = metadata.get("response_types", list(OAUTH_RESPONSE_TYPES_SUPPORTED))
        if not isinstance(requested_grant_types, list) or not all(
            isinstance(item, str) for item in requested_grant_types
        ):
            raise ValueError("grant_types must be an array of strings")
        grant_types = tuple(item for item in OAUTH_GRANT_TYPES_SUPPORTED if item in requested_grant_types)
        if OAUTH_GRANT_TYPE_AUTHORIZATION_CODE not in grant_types:
            raise ValueError("grant_types must include authorization_code")
        if not isinstance(requested_response_types, list) or not all(
            isinstance(item, str) for item in requested_response_types
        ):
            raise ValueError("response_types must be an array of strings")
        response_types = tuple(item for item in OAUTH_RESPONSE_TYPES_SUPPORTED if item in requested_response_types)
        if not response_types:
            raise ValueError("response_types must include at least one supported value")
        method = str(metadata.get("token_endpoint_auth_method") or "none")
        if method not in {"none", "client_secret_post", "client_secret_basic"}:
            raise ValueError("unsupported token_endpoint_auth_method")
        if self.store.client_count() >= MAX_REGISTERED_CLIENTS:
            raise ValueError("dynamic client registration limit reached")

        client_secret = secrets.token_urlsafe(32) if method != "none" else None
        now = int(time.time())
        for _attempt in range(5):
            client = OAuthClient(
                client_id=secrets.token_urlsafe(24),
                redirect_uris=redirects,
                token_endpoint_auth_method=method,
                client_name=_optional_text(metadata.get("client_name"), 200),
                secret_digest=_secret_digest(client_secret) if client_secret is not None else None,
                grant_types=grant_types,
                response_types=response_types,
                issued_at=now,
                updated_at=now,
            )
            try:
                self.store.put_client(_stored_client(client))
                break
            except sqlite3.IntegrityError as exc:
                if "oauth_clients.client_id" not in str(exc):
                    raise
        else:
            raise RuntimeError("could not allocate a unique OAuth client_id")

        response: dict[str, Any] = {
            "client_id": client.client_id,
            "client_id_issued_at": client.issued_at,
            "redirect_uris": list(client.redirect_uris),
            "grant_types": list(client.grant_types),
            "response_types": list(client.response_types),
            "token_endpoint_auth_method": client.token_endpoint_auth_method,
        }
        if client.client_name:
            response["client_name"] = client.client_name
        if client_secret is not None:
            response["client_secret"] = client_secret
            response["client_secret_expires_at"] = 0
        return response

    def get(self, client_id: str) -> OAuthClient | None:
        stored = self.store.get_client(client_id)
        if stored is None:
            return None
        return OAuthClient(
            client_id=stored.client_id,
            redirect_uris=stored.redirect_uris,
            token_endpoint_auth_method=stored.token_endpoint_auth_method,
            client_name=stored.client_name,
            secret_digest=stored.secret_digest,
            grant_types=stored.grant_types,
            response_types=stored.response_types,
            issued_at=stored.created_at,
            updated_at=stored.updated_at,
        )

    def accepts_redirect(self, client_id: str, redirect_uri: str) -> bool:
        client = self.get(client_id)
        return client is not None and client.accepts_redirect(redirect_uri)

    def authenticates(self, client_id: str, client_secret: str, auth_method: str) -> bool:
        client = self.get(client_id)
        return (
            client is not None
            and client.token_endpoint_auth_method == auth_method
            and client.verifies_secret(client_secret)
        )


@dataclass(frozen=True)
class OAuthConfig:
    password: str
    server_url: str | None
    token_secret: bytes
    access_token_ttl: int = OAUTH_ACCESS_TOKEN_TTL_SECONDS
    refresh_token_ttl: int = OAUTH_REFRESH_TOKEN_TTL_SECONDS
    registry: OAuthClientRegistry = field(default_factory=OAuthClientRegistry)
    pending_codes: dict[str, dict[str, Any]] = field(default_factory=dict)
    pending_codes_lock: threading.Lock = field(default_factory=threading.Lock)

    @property
    def token_ttl(self) -> int:
        """Compatibility alias for integrations that used the old field."""

        return self.access_token_ttl


def default_state_dir() -> Path:
    configured = (os.environ.get("CODING_TOOLS_MCP_STATE_DIR") or "").strip()
    if configured:
        return Path(configured).expanduser()
    if os.name == "nt":
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            return Path(local_app_data) / "coding-tools-mcp" / "state"
    xdg_state_home = (os.environ.get("XDG_STATE_HOME") or "").strip()
    if xdg_state_home:
        return Path(xdg_state_home).expanduser() / "coding-tools-mcp"
    return Path.home() / ".local" / "state" / "coding-tools-mcp"


def default_oauth_database_path() -> Path:
    configured = (os.environ.get("CODING_TOOLS_MCP_OAUTH_DB") or "").strip()
    return Path(configured).expanduser() if configured else default_state_dir() / "oauth.db"


def load_or_create_private_value(path: Path, generator: Callable[[], str]) -> tuple[str, bool]:
    path = path.expanduser()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        value = path.read_text(encoding="utf-8").strip()
        if not value:
            raise ValueError(f"persistent secret file is empty: {path}")
        try:
            path.chmod(0o600)
        except OSError:
            pass
        return value, False

    value = generator()
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(value)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return value, True


def normalize_server_url(value: str) -> str:
    normalized = value.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(normalized)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
        raise ValueError("server URL must be an absolute HTTP or HTTPS origin")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("server URL must not contain user information")
    if parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
        raise ValueError("server URL must be an origin without a path, query, or fragment")
    hostname = (parsed.hostname or "").lower()
    if parsed.scheme != "https" and hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("non-loopback server URL must use HTTPS")
    return normalized


def validate_redirect_uris(value: Any) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or len(value) > MAX_REDIRECT_URIS:
        raise ValueError(f"redirect_uris must contain between 1 and {MAX_REDIRECT_URIS} entries")
    redirects: list[str] = []
    for item in value:
        if not isinstance(item, str) or len(item) > 2048:
            raise ValueError("redirect_uri must be a string of at most 2048 characters")
        parsed = urllib.parse.urlsplit(item)
        if parsed.fragment or not parsed.scheme or not parsed.netloc or not parsed.hostname:
            raise ValueError("redirect_uri must be an absolute URI without a fragment")
        if parsed.username is not None or parsed.password is not None:
            raise ValueError("redirect_uri must not contain user information")
        hostname = (parsed.hostname or "").lower()
        if parsed.scheme == "http" and hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise ValueError("HTTP redirect_uri is allowed only for loopback hosts")
        if parsed.scheme not in {"http", "https"}:
            raise ValueError("redirect_uri must use HTTPS or loopback HTTP")
        redirects.append(item)
    if len(set(redirects)) != len(redirects):
        raise ValueError("redirect_uris must be unique")
    return tuple(redirects)


def verify_pkce(code_verifier: str, code_challenge: str) -> bool:
    if not re.fullmatch(r"[A-Za-z0-9\-._~]{43,128}", code_verifier):
        return False
    digest = hashlib.sha256(code_verifier.encode("ascii")).digest()
    expected = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return secrets.compare_digest(expected, code_challenge)


def valid_pkce_challenge(code_challenge: str) -> bool:
    return re.fullmatch(r"[A-Za-z0-9_-]{43}", code_challenge) is not None


def create_access_token(config: OAuthConfig, server_url: str, *, client_id: str) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "iss": server_url,
            "aud": server_url,
            "sub": client_id,
            "client_id": client_id,
            "iat": now,
            "exp": now + config.access_token_ttl,
            "scope": "mcp",
        },
        config.token_secret,
        algorithm="HS256",
    )


def validate_access_token(token: str, config: OAuthConfig, server_url: str) -> bool:
    try:
        claims = jwt.decode(
            token,
            config.token_secret,
            algorithms=["HS256"],
            audience=server_url,
            issuer=server_url,
        )
    except jwt.PyJWTError:
        return False
    client_id = claims.get("client_id")
    return isinstance(client_id, str) and config.registry.get(client_id) is not None


def _stored_client(client: OAuthClient) -> StoredOAuthClient:
    return StoredOAuthClient(
        client_id=client.client_id,
        redirect_uris=client.redirect_uris,
        token_endpoint_auth_method=client.token_endpoint_auth_method,
        client_name=client.client_name,
        secret_digest=client.secret_digest,
        grant_types=client.grant_types,
        response_types=client.response_types,
        created_at=client.issued_at,
        updated_at=client.updated_at,
    )


def _secret_digest(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def _optional_text(value: Any, maximum: int) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    return value.strip()[:maximum]
