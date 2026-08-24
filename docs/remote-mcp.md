# Remote MCP

`coding-tools-mcp` exposes Streamable HTTP at `/mcp`. The fixed tool set includes
`apply_patch` and `exec_command`; there is no reduced read-only catalog, so every
public deployment must use bearer auth, OAuth, or an external authenticated
proxy.

## Quick Start: temporary tunnel

Cloudflare Quick Tunnel, ngrok, and Microsoft Dev Tunnel are convenient for
testing. Their public URL may change when the launcher restarts, so they are not
the recommended way to keep a ChatGPT connector attached over server reboots.

```bash
curl -fsSL https://raw.githubusercontent.com/xyTom/coding-tools-mcp/main/scripts/install.sh \
  | bash -s -- --tunnel cloudflared --auto-install-tunnel --workspace /path/to/repo
```

The script generates a bearer token, starts the server on `127.0.0.1`, and
prints the HTTPS tunnel URL and header:

```text
URL: https://<tunnel-host>/mcp
Header: Authorization: Bearer <token>
```

From a checkout, the equivalent commands are:

```bash
export CODING_TOOLS_MCP_AUTH_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
CODING_TOOLS_MCP_AUTH_MODE=bearer integrations/tunnels/tunnel.sh cloudflared /path/to/repo
```

The scripts also support `ngrok` and `devtunnel`. `--tunnel none` starts only
the loopback HTTP server and is useful when a separately managed reverse proxy
already exists.

## OAuth 2.1 + dynamic registration

For clients that cannot set a static `Authorization` header but support MCP
OAuth discovery:

```bash
CODING_TOOLS_MCP_AUTH_MODE=oauth \
integrations/tunnels/tunnel.sh cloudflared /path/to/repo
```

The server implements Authorization Code + PKCE S256, refresh-token rotation,
and RFC 7591 dynamic client registration. A client discovers and registers
itself; operators do not need to invent a client ID or copy a client secret into
the MCP host. The quick-tunnel script prints the password that the operator
enters on the authorization page.

Discovery and OAuth endpoints:

- `GET /.well-known/oauth-protected-resource`
- `GET /.well-known/oauth-authorization-server`
- `POST /oauth/register`
- `GET /oauth/authorize`
- `POST /oauth/authorize`
- `POST /oauth/token`

Registration rules:

- `redirect_uris` are required, unique, and matched exactly.
- HTTPS redirects are accepted. HTTP is accepted only for `localhost`,
  `127.0.0.1`, or `::1` loopback callbacks.
- Supported token authentication methods are `none`, `client_secret_post`, and
  `client_secret_basic`. A client must use the method it registered.
- Client secrets are stored as digests. Public clients rely on mandatory PKCE.
- Dynamic registrations and refresh tokens are stored in SQLite. Authorization
  codes remain process-local, single-use, and short-lived.

Authorization codes expire after five minutes. Access tokens default to one
hour. Refresh tokens default to 90 days, are opaque random values stored only as
SHA-256 hashes, and rotate on every successful refresh. Reusing an old refresh
token revokes the remaining token family.

## Persistent Remote MCP

For long-running ChatGPT use, deploy a fixed HTTPS origin in front of a
loopback-only systemd service:

```text
ChatGPT -> https://cd.had.li -> Nginx -> http://127.0.0.1:8765 -> coding-tools-mcp
```

From this fork, the one-command installation is:

```bash
curl -fsSL https://raw.githubusercontent.com/dovetaill/coding-tools-mcp/main/scripts/install.sh | \
  CODING_TOOLS_MCP_AUTH_MODE=oauth \
  CODING_TOOLS_MCP_PERMISSION_MODE=dangerous \
  bash -s -- \
  --persistent \
  --workspace /mulu \
  --public-url https://cd.had.li
```

Persistent mode:

- binds to `127.0.0.1` unless `--host` explicitly overrides it;
- stores configuration in `/etc/coding-tools-mcp/coding-tools-mcp.env` with
  mode `0600`;
- stores the OAuth SQLite database in `/var/lib/coding-tools-mcp/oauth.db`;
- generates the OAuth login password and signing secret only when missing;
- installs and enables `coding-tools-mcp.service` with automatic restart;
- updates the binary and unit on repeat runs without deleting OAuth state.

The persistent installer from this fork installs the fork's `main` archive by
default. Use `--source /path/to/checkout`, `--source <package-url>`, or
`--version <published-version>` to select another source explicitly.

The login password is printed only when the installer generated it. Save that
first-run value. The signing secret, client secrets, access tokens, and refresh
tokens are never printed.

Check the deployment without revealing credentials:

```bash
sudo scripts/install.sh --status
systemctl status coding-tools-mcp --no-pager
journalctl -u coding-tools-mcp -n 100 --no-pager
curl https://cd.had.li/.well-known/oauth-authorization-server
curl https://cd.had.li/.well-known/oauth-protected-resource
```

Repeat the same `--persistent` command to upgrade. Existing config, signing
secret, login password, registered clients, and refresh tokens are reused.
From this fork's checkout or standalone deployment bundle, the Chinese
operations menu can update both the program and its scripts before reinstalling:

```bash
sudo ./integrations/server/manage.sh update
```

Source checkouts use a fast-forward-only pull from `origin/main`. Standalone
bundles download the stable-name archive from the latest `server-v*` GitHub
Release and verify its SHA-256 checksum. The default first-install public URL
for this fork is `https://cd.had.li`; an existing configured URL always wins.
Normal uninstall keeps them:

```bash
sudo scripts/install.sh --uninstall
```

Only an explicit purge removes credentials and OAuth state:

```bash
sudo scripts/install.sh --uninstall --purge
```

### Nginx and TLS for `cd.had.li`

Before requesting a certificate, create an HTTP virtual host so Certbot can
complete the ACME challenge:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name cd.had.li;

    location / {
        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

Validate, reload, and let Certbot add the HTTPS listener and redirect:

```bash
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d cd.had.li
sudo certbot renew --dry-run
```

After Certbot finishes, keep the same `location /` proxy directives inside the
TLS server block. No WebSocket upgrade headers are required: this server uses
HTTP POST responses and deliberately does not expose an SSE `GET /mcp` stream.
The explicit `CODING_TOOLS_MCP_SERVER_URL=https://cd.had.li` is canonical, so
OAuth issuer and metadata do not depend on untrusted `Forwarded` or
`X-Forwarded-*` values.

## OAuth configuration

```bash
# Generated and printed when omitted:
CODING_TOOLS_MCP_OAUTH_PASSWORD=<authorize-page-password>

# Stable public origin, without /mcp:
CODING_TOOLS_MCP_SERVER_URL=https://mcp.example.com

# Optional explicit stable HS256 key; hex-encoded bytes. If omitted, the
# runtime creates and reuses a private file under STATE_DIR:
CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET=<hex-key>

# Persistent SQLite and fallback-secret directory:
CODING_TOOLS_MCP_STATE_DIR=~/.local/state/coding-tools-mcp

# Token lifetimes in seconds; defaults 3600 and 7776000 (90 days):
CODING_TOOLS_MCP_OAUTH_ACCESS_TOKEN_TTL=3600
CODING_TOOLS_MCP_OAUTH_REFRESH_TOKEN_TTL=7776000

# Backward-compatible alias for the access-token TTL:
CODING_TOOLS_MCP_OAUTH_TOKEN_TTL=3600
```

With an ephemeral tunnel, omit `CODING_TOOLS_MCP_SERVER_URL`; the server derives
the external origin from the request. For a stable hostname, pin it so issuer,
audience, resource, and discovery URLs remain constant. The URL must be an
origin without `/mcp`, a query, or a fragment; non-loopback origins require
HTTPS.

The server ignores `Forwarded` and `X-Forwarded-*` by default. Set
`CODING_TOOLS_MCP_TRUST_PROXY_HEADERS=1` only behind a proxy you control. You can
also set exact browser origins with the comma-separated
`CODING_TOOLS_MCP_ALLOWED_ORIGINS` variable.

### Optional pre-registered client

Dynamic registration is the default. An operator may additionally pre-register
one known client:

```bash
CODING_TOOLS_MCP_OAUTH_CLIENT_ID=<client-id>
CODING_TOOLS_MCP_OAUTH_REDIRECT_URIS=https://client.example/callback,http://127.0.0.1/callback
CODING_TOOLS_MCP_OAUTH_CLIENT_SECRET=<optional-confidential-secret>
```

If a client ID is configured, its redirect URI list is required operational
configuration; do not rely on the loopback fallback for a production client.

## HTTP session behavior

There are none. Since 0.3.0 this endpoint is stateless: no response carries an
`Mcp-Session-Id`, an `Mcp-Session-Id` a client kept from an older server is
ignored rather than refused, and `DELETE /mcp` returns `405` with `Allow: POST`
because there is nothing to terminate. Every request is answered by the one
runtime that owns the workspace, so a client may reconnect, change transport,
or run beside another client without losing anything. Commands are workspace
resources with their own timeout, count, output, and retention limits: any
authenticated client of the workspace can continue one with the `command_id`
that `exec_command` returned.

A handshake-era client needs no change for this. It still sends `initialize`,
still gets the same `InitializeResult`, and simply has no session header to
echo back.

A `2026-07-28` client sends no handshake at all. Each request states its
version in `params._meta` and mirrors that version and its method in headers
(`Mcp-Name` as well, for `tools/call`, `resources/read`, and `prompts/get`):

```bash
curl "$BASE_URL/mcp" \
  -H "Authorization: Bearer $CODING_TOOLS_MCP_AUTH_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: server/discover" \
  --data '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'

curl "$BASE_URL/mcp" \
  -H "Authorization: Bearer $CODING_TOOLS_MCP_AUTH_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: read_file" \
  --data '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"README.md"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}'
```

A header that contradicts the body, or a missing one, is `400` with `-32020`.
An unknown method in this era is `404` with `-32601`. Handshake-era errors stay
`200` with the JSON-RPC error, as they always did.

This implementation returns `405` for `GET /mcp` because it does not provide an
SSE stream. It rejects JSON-RPC batches and accepts `notifications/cancelled`
in both eras, answering with nothing; the notification does not terminate the
command the cancelled request started, which `kill_command` does.

## Local checks

Replace `BASE_URL` with the HTTPS origin, without `/mcp`:

```bash
curl "$BASE_URL/.well-known/mcp.json"
curl "$BASE_URL/.well-known/oauth-protected-resource"
curl "$BASE_URL/.well-known/oauth-authorization-server"
```

For bearer mode, an unauthenticated request must return `401` and a correct token
must reach MCP initialization:

```bash
curl "$BASE_URL/mcp" \
  -H "Authorization: Bearer $CODING_TOOLS_MCP_AUTH_TOKEN" \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
```

## Security notes

- Never publish `CODING_TOOLS_MCP_AUTH_MODE=noauth`. It is suitable only for a
  loopback-only local process.
- Use HTTPS, rotate static bearer tokens, and keep OAuth passwords/signing keys
  out of committed files.
- Keep the MCP runtime in `safe` or `trusted`; use `dangerous` only inside an
  isolated container or VM with a trusted client.
- An HTTPS tunnel authenticates transport, not code execution. The server's
  policy and Landlock protections do not replace an external sandbox for
  untrusted repositories.
- Avoid `--dangerously-fake-readonly-annotations` on a published endpoint. It
  reports mutating tools as read-only, so a client on the far side of the tunnel
  cannot tell from `tools/list` that `apply_patch` and `exec_command` are exposed.
  The server requires authentication before allowing it over HTTP, but on a shared
  endpoint the operator who set it and the client who connects may not be the same
  party. Check `server_info.annotation_override` or the server card's
  `tools.annotationOverride` to see whether an endpoint is doing this.
