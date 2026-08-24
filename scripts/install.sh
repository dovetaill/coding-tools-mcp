#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="coding-tools-mcp"
SCRIPT_NAME="coding-tools-mcp"
METHOD="${CODING_TOOLS_MCP_INSTALL_METHOD:-auto}"
VERSION="${CODING_TOOLS_MCP_VERSION:-}"
WITH_IMAGE=0
VERIFY=1
ACTION="install"
TUNNEL_PROVIDER="${CODING_TOOLS_MCP_TUNNEL_PROVIDER:-cloudflared}"
WORKSPACE="${CODING_TOOLS_MCP_WORKSPACE:-$PWD}"
PORT="${CODING_TOOLS_MCP_PORT:-8765}"
HOST="${CODING_TOOLS_MCP_HOST:-127.0.0.1}"
AUTH_MODE="${CODING_TOOLS_MCP_AUTH_MODE:-}"
AUTH_TOKEN="${CODING_TOOLS_MCP_AUTH_TOKEN:-}"
PERMISSION_MODE="${CODING_TOOLS_MCP_PERMISSION_MODE:-safe}"
PUBLIC_URL="${CODING_TOOLS_MCP_SERVER_URL:-}"
STATE_DIR="${CODING_TOOLS_MCP_STATE_DIR:-}"
ACCESS_TOKEN_TTL="${CODING_TOOLS_MCP_OAUTH_ACCESS_TOKEN_TTL:-${CODING_TOOLS_MCP_OAUTH_TOKEN_TTL:-3600}}"
REFRESH_TOKEN_TTL="${CODING_TOOLS_MCP_OAUTH_REFRESH_TOKEN_TTL:-7776000}"
INSTALL_SOURCE="${CODING_TOOLS_MCP_INSTALL_SOURCE:-}"
SERVER_BIN="${CODING_TOOLS_MCP_SERVER_BIN:-}"
SERVER_PID=""
TUNNEL_TOOL=""
PERSISTENT=0
PURGE=0
SERVICE_NAME="${CODING_TOOLS_MCP_SERVICE_NAME:-coding-tools-mcp}"
SERVICE_USER="${CODING_TOOLS_MCP_SERVICE_USER:-${SUDO_USER:-root}}"
CONFIG_DIR="${CODING_TOOLS_MCP_CONFIG_DIR:-/etc/coding-tools-mcp}"
ENV_FILE="${CODING_TOOLS_MCP_ENV_FILE:-$CONFIG_DIR/coding-tools-mcp.env}"
UNIT_FILE="${CODING_TOOLS_MCP_UNIT_FILE:-/etc/systemd/system/$SERVICE_NAME.service}"
PERSISTENT_ROOT="${CODING_TOOLS_MCP_PERSISTENT_ROOT:-/opt/coding-tools-mcp}"
OAUTH_PASSWORD_EXPLICIT="${CODING_TOOLS_MCP_OAUTH_PASSWORD:+1}"
OAUTH_TOKEN_SECRET_EXPLICIT="${CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET:+1}"
AUTH_MODE_EXPLICIT="${CODING_TOOLS_MCP_AUTH_MODE:+1}"
WORKSPACE_EXPLICIT="${CODING_TOOLS_MCP_WORKSPACE:+1}"
HOST_EXPLICIT="${CODING_TOOLS_MCP_HOST:+1}"
PORT_EXPLICIT="${CODING_TOOLS_MCP_PORT:+1}"
PERMISSION_MODE_EXPLICIT="${CODING_TOOLS_MCP_PERMISSION_MODE:+1}"
PUBLIC_URL_EXPLICIT="${CODING_TOOLS_MCP_SERVER_URL:+1}"
STATE_DIR_EXPLICIT="${CODING_TOOLS_MCP_STATE_DIR:+1}"
ACCESS_TOKEN_TTL_EXPLICIT="${CODING_TOOLS_MCP_OAUTH_ACCESS_TOKEN_TTL:+1}${CODING_TOOLS_MCP_OAUTH_TOKEN_TTL:+1}"
REFRESH_TOKEN_TTL_EXPLICIT="${CODING_TOOLS_MCP_OAUTH_REFRESH_TOKEN_TTL:+1}"
GENERATED_OAUTH_PASSWORD=0

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options] [workspace]

Install coding-tools-mcp from PyPI, optionally start the MCP server, and
optionally expose it through a tunnel.

Default action:
  Install or update the published coding-tools-mcp command from PyPI.

Actions:
  --start                       Install, then start local HTTP MCP.
  --tunnel [provider]           Install, start local HTTP MCP, then expose it.
                                Providers: cloudflared, ngrok, devtunnel, none.
  --persistent                  Install/update a systemd service for long-term use.
  --systemd                     Alias for --persistent.
  --status                      Show persistent service and OAuth-state status.
  --uninstall                   Remove the service; preserve config and OAuth state.
  --purge                       With --uninstall, also remove config and OAuth state.
  --install-only                Install only. This is the default.

Install options:
  --version VERSION             Install an exact package version.
  --with-image                  Install the optional image extra.
  --method auto|uv|pip          Choose installer. Default: auto.
  --source SPEC                 Install from a local path, URL, or VCS spec.
  --no-verify                   Skip the post-install command check.

Server options:
  --workspace PATH              Workspace to expose. Default: current dir.
  --host HOST                   Bind host. Persistent default: 127.0.0.1.
  --port PORT                   Local HTTP port. Default: 8765.
  --public-url URL              Stable public HTTPS origin, without /mcp.
  --auth-mode bearer|noauth|oauth
                                Defaults: noauth local, bearer tunnel. OAuth
                                public URL is inferred from tunnel requests
                                unless CODING_TOOLS_MCP_SERVER_URL is preset.
                                PASSWORD is generated and printed if unset;
                                client_id/client_secret are optional.
  --auth-token TOKEN            Bearer token. Generated if needed.
  --permission-mode MODE        safe, trusted, or dangerous.
  --state-dir PATH              Persistent OAuth state directory.
  --service-user USER           Account used by the systemd service.
  --server-bin PATH             Use an existing coding-tools-mcp binary.

Tunnel options:
  --provider PROVIDER           Same as --tunnel PROVIDER after --tunnel.
  --auto-install-tunnel         Install missing tunnel CLI without prompting.

Environment:
  CODING_TOOLS_MCP_VERSION=0.2.0
  CODING_TOOLS_MCP_INSTALL_METHOD=auto|uv|pip
  CODING_TOOLS_MCP_WORKSPACE=/path/to/repo
  CODING_TOOLS_MCP_TUNNEL_PROVIDER=cloudflared|ngrok|devtunnel
  CODING_TOOLS_MCP_INSTALL_SOURCE=/path/or/url
  CODING_TOOLS_MCP_AUTO_INSTALL_TUNNEL=1
  PYTHON=python3

Examples:
  scripts/install.sh
  scripts/install.sh --start --workspace /path/to/repo
  scripts/install.sh --tunnel cloudflared --workspace /path/to/repo
  scripts/install.sh --tunnel ngrok --auto-install-tunnel /path/to/repo
  scripts/install.sh --persistent --workspace /path/to/repo --public-url https://mcp.example.com
  scripts/install.sh --status
  scripts/install.sh --uninstall             # keeps OAuth state and secrets
  scripts/install.sh --uninstall --purge     # explicitly removes them
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

run() {
  echo "+ $*" >&2
  "$@"
}

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}

package_spec() {
  if [[ -n "$INSTALL_SOURCE" ]]; then
    printf "%s\n" "$INSTALL_SOURCE"
    return
  fi
  local name="$PACKAGE_NAME"
  if [[ "$WITH_IMAGE" == "1" ]]; then
    name="${name}[image]"
  fi
  if [[ -n "$VERSION" ]]; then
    printf "%s==%s\n" "$name" "$VERSION"
  else
    printf "%s\n" "$name"
  fi
}

find_python() {
  if [[ -n "${PYTHON:-}" ]]; then
    printf "%s\n" "$PYTHON"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return
  fi
  if command -v python >/dev/null 2>&1; then
    command -v python
    return
  fi
  return 1
}

select_method() {
  case "$METHOD" in
    auto)
      if command -v uv >/dev/null 2>&1; then
        printf "uv\n"
      else
        printf "pip\n"
      fi
      ;;
    uv|pip)
      printf "%s\n" "$METHOD"
      ;;
    *)
      die "CODING_TOOLS_MCP_INSTALL_METHOD must be auto, uv, or pip"
      ;;
  esac
}

find_installed_command() {
  if [[ -n "$SERVER_BIN" ]]; then
    printf "%s\n" "$SERVER_BIN"
    return
  fi
  if command -v "$SCRIPT_NAME" >/dev/null 2>&1; then
    command -v "$SCRIPT_NAME"
    return
  fi
  if [[ -x "$HOME/.local/bin/$SCRIPT_NAME" ]]; then
    printf "%s\n" "$HOME/.local/bin/$SCRIPT_NAME"
    return
  fi
  return 1
}

warn_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      cat >&2 <<EOF

Installed command was not found on PATH.
Add this to your shell profile if your installer placed it in ~/.local/bin:

  export PATH="\$HOME/.local/bin:\$PATH"
EOF
      ;;
  esac
}

prompt_install() {
  local tool="$1"
  if [[ "${CODING_TOOLS_MCP_AUTO_INSTALL_TUNNEL:-}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "$tool is not installed and stdin is not interactive." >&2
    echo "Pass --auto-install-tunnel or install $tool manually." >&2
    return 1
  fi
  local answer
  read -r -p "$tool is not installed. Install it now? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

ensure_local_bin_on_path() {
  mkdir -p "$HOME/.local/bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
  if [[ -d "$HOME/.dotnet/tools" ]]; then
    case ":$PATH:" in
      *":$HOME/.dotnet/tools:"*) ;;
      *) export PATH="$HOME/.dotnet/tools:$PATH" ;;
    esac
  fi
}

download_to_file() {
  local url="$1"
  local output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
    return
  fi
  echo "Need curl or wget to download $url" >&2
  return 1
}

install_cloudflared() {
  if ! prompt_install cloudflared; then
    return 1
  fi
  if command -v brew >/dev/null 2>&1; then
    brew install cloudflared
    return
  fi
  ensure_local_bin_on_path
  local os arch suffix
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Linux:x86_64|Linux:amd64) suffix="linux-amd64" ;;
    Linux:aarch64|Linux:arm64) suffix="linux-arm64" ;;
    Darwin:x86_64) suffix="darwin-amd64" ;;
    Darwin:arm64) suffix="darwin-arm64" ;;
    *)
      echo "Unsupported platform for automatic cloudflared install: $os $arch" >&2
      return 1
      ;;
  esac
  download_to_file \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-$suffix" \
    "$HOME/.local/bin/cloudflared"
  chmod +x "$HOME/.local/bin/cloudflared"
}

install_ngrok() {
  if ! prompt_install ngrok; then
    return 1
  fi
  if command -v brew >/dev/null 2>&1; then
    brew install ngrok/ngrok/ngrok
    return
  fi
  if command -v npm >/dev/null 2>&1; then
    npm install -g ngrok
    return
  fi
  echo "Automatic ngrok install needs Homebrew or npm." >&2
  echo "Install manually from https://ngrok.com/download and rerun this script." >&2
  return 1
}

install_devtunnel() {
  if ! prompt_install devtunnel; then
    return 1
  fi
  if command -v winget >/dev/null 2>&1; then
    winget install Microsoft.devtunnel
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "Automatic devtunnel install needs curl." >&2
    return 1
  fi
  curl -fsSL https://aka.ms/DevTunnelCliInstall | bash
  ensure_local_bin_on_path
}

ensure_tunnel_command() {
  local provider="$1"
  local tool="$provider"
  case "$provider" in
    cloudflared|cf) tool="cloudflared" ;;
    ngrok) tool="ngrok" ;;
    devtunnel|dev-tunnel|ms-devtunnel) tool="devtunnel" ;;
    *) die "unknown tunnel provider: $provider" ;;
  esac
  if command -v "$tool" >/dev/null 2>&1; then
    TUNNEL_TOOL="$tool"
    return
  fi
  case "$tool" in
    cloudflared) install_cloudflared ;;
    ngrok) install_ngrok ;;
    devtunnel) install_devtunnel ;;
  esac
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "$tool is still not available on PATH after install"
  fi
  TUNNEL_TOOL="$tool"
}

generate_token() {
  local python_bin
  if python_bin="$(find_python)"; then
    "$python_bin" -c 'import secrets; print(secrets.token_urlsafe(32))'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
    printf "\n"
    return
  fi
  die "need python or openssl to generate an auth token"
}

generate_hex_secret() {
  local python_bin
  if python_bin="$(find_python)"; then
    "$python_bin" -c 'import secrets; print(secrets.token_hex(32))'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  die "need python or openssl to generate an OAuth signing secret"
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "persistent systemd installation requires root (run with sudo)"
}

existing_config_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  bash -c 'set -a; source "$1"; printf "%s" "${!2-}"' bash "$ENV_FILE" "$key"
}

use_existing_if_unset() {
  local variable="$1" explicit="$2" key="$3" existing
  [[ -z "$explicit" ]] || return 0
  existing="$(existing_config_value "$key")"
  if [[ -n "$existing" ]]; then
    printf -v "$variable" '%s' "$existing"
  fi
}

validate_public_url() {
  [[ -n "$PUBLIC_URL" ]] || die "--public-url is required for persistent OAuth mode"
  local python_bin
  python_bin="$(find_python)" || die "python is required to validate --public-url"
  PUBLIC_URL="$($python_bin - "$PUBLIC_URL" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1].strip().rstrip("/")
parsed = urlsplit(value)
if parsed.scheme not in {"http", "https"} or not parsed.netloc or not parsed.hostname:
    raise SystemExit("--public-url must be an absolute HTTP or HTTPS origin")
if parsed.username is not None or parsed.password is not None:
    raise SystemExit("--public-url must not contain user information")
if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
    raise SystemExit("--public-url must not contain a path, query, or fragment")
if parsed.scheme != "https" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit("a non-loopback --public-url must use HTTPS")
print(value)
PY
)" || die "invalid --public-url"
}

prepare_persistent_settings() {
  require_root
  STATE_DIR="${STATE_DIR:-/var/lib/coding-tools-mcp}"

  use_existing_if_unset WORKSPACE "$WORKSPACE_EXPLICIT" CODING_TOOLS_MCP_WORKSPACE
  use_existing_if_unset HOST "$HOST_EXPLICIT" CODING_TOOLS_MCP_HOST
  use_existing_if_unset PORT "$PORT_EXPLICIT" CODING_TOOLS_MCP_PORT
  use_existing_if_unset AUTH_MODE "$AUTH_MODE_EXPLICIT" CODING_TOOLS_MCP_AUTH_MODE
  use_existing_if_unset PERMISSION_MODE "$PERMISSION_MODE_EXPLICIT" CODING_TOOLS_MCP_PERMISSION_MODE
  use_existing_if_unset PUBLIC_URL "$PUBLIC_URL_EXPLICIT" CODING_TOOLS_MCP_SERVER_URL
  use_existing_if_unset STATE_DIR "$STATE_DIR_EXPLICIT" CODING_TOOLS_MCP_STATE_DIR
  use_existing_if_unset ACCESS_TOKEN_TTL "$ACCESS_TOKEN_TTL_EXPLICIT" CODING_TOOLS_MCP_OAUTH_ACCESS_TOKEN_TTL
  use_existing_if_unset REFRESH_TOKEN_TTL "$REFRESH_TOKEN_TTL_EXPLICIT" CODING_TOOLS_MCP_OAUTH_REFRESH_TOKEN_TTL

  AUTH_MODE="${AUTH_MODE:-oauth}"
  case "$AUTH_MODE" in
    bearer|oauth) ;;
    noauth) die "persistent public deployment refuses auth-mode=noauth; use bearer or oauth" ;;
    *) die "--auth-mode must be bearer or oauth in persistent mode" ;;
  esac
  case "$PERMISSION_MODE" in
    safe|trusted|dangerous) ;;
    *) die "--permission-mode must be safe, trusted, or dangerous" ;;
  esac
  if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "--port must be between 1 and 65535"
  fi
  [[ -d "$WORKSPACE" ]] || die "workspace does not exist: $WORKSPACE"
  WORKSPACE="$(cd "$WORKSPACE" && pwd -P)"
  id "$SERVICE_USER" >/dev/null 2>&1 || die "service user does not exist: $SERVICE_USER"

  if [[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" && "$HOST" != "::1" ]]; then
    echo "WARNING: persistent service will bind to non-loopback host $HOST; authentication and firewalling are mandatory." >&2
  fi

  if [[ "$AUTH_MODE" == "oauth" ]]; then
    validate_public_url
    if [[ -z "$OAUTH_PASSWORD_EXPLICIT" ]]; then
      CODING_TOOLS_MCP_OAUTH_PASSWORD="$(existing_config_value CODING_TOOLS_MCP_OAUTH_PASSWORD)"
    fi
    if [[ -z "${CODING_TOOLS_MCP_OAUTH_PASSWORD:-}" ]]; then
      CODING_TOOLS_MCP_OAUTH_PASSWORD="$(generate_token)"
      GENERATED_OAUTH_PASSWORD=1
    fi
    if [[ -z "$OAUTH_TOKEN_SECRET_EXPLICIT" ]]; then
      CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET="$(existing_config_value CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET)"
    fi
    if [[ -z "${CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET:-}" ]]; then
      CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET="$(generate_hex_secret)"
    fi
    [[ "$CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET" =~ ^[0-9A-Fa-f]{64,}$ ]] \
      || die "CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET must be at least 32 bytes encoded as hex"
  else
    if [[ -z "$AUTH_TOKEN" ]]; then
      AUTH_TOKEN="$(existing_config_value CODING_TOOLS_MCP_AUTH_TOKEN)"
    fi
    AUTH_TOKEN="${AUTH_TOKEN:-$(generate_token)}"
  fi

  if [[ -z "$INSTALL_SOURCE" && -z "$VERSION" && -z "$SERVER_BIN" ]]; then
    INSTALL_SOURCE="https://github.com/dovetaill/coding-tools-mcp/archive/refs/heads/main.tar.gz"
  fi
}

systemd_env_quote() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "configuration values must not contain newlines"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

systemd_unit_path() {
  local value="$1"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "systemd paths must not contain newlines"
  value="${value//%/%%}"
  value="${value//\\/\\\\}"
  value="${value// /\\x20}"
  value="${value//$'\t'/\\x09}"
  printf '%s' "$value"
}

write_persistent_environment() {
  local temp_file
  install -d -m 0700 "$CONFIG_DIR"
  temp_file="$(mktemp "$CONFIG_DIR/.coding-tools-mcp.env.XXXXXX")"
  chmod 0600 "$temp_file"
  {
    printf 'CODING_TOOLS_MCP_AUTH_MODE='; systemd_env_quote "$AUTH_MODE"; printf '\n'
    printf 'CODING_TOOLS_MCP_PERMISSION_MODE='; systemd_env_quote "$PERMISSION_MODE"; printf '\n'
    printf 'CODING_TOOLS_MCP_WORKSPACE='; systemd_env_quote "$WORKSPACE"; printf '\n'
    printf 'CODING_TOOLS_MCP_HOST='; systemd_env_quote "$HOST"; printf '\n'
    printf 'CODING_TOOLS_MCP_PORT='; systemd_env_quote "$PORT"; printf '\n'
    printf 'CODING_TOOLS_MCP_SERVER_URL='; systemd_env_quote "$PUBLIC_URL"; printf '\n'
    printf 'CODING_TOOLS_MCP_STATE_DIR='; systemd_env_quote "$STATE_DIR"; printf '\n'
    printf 'CODING_TOOLS_MCP_OAUTH_ACCESS_TOKEN_TTL='; systemd_env_quote "$ACCESS_TOKEN_TTL"; printf '\n'
    printf 'CODING_TOOLS_MCP_OAUTH_REFRESH_TOKEN_TTL='; systemd_env_quote "$REFRESH_TOKEN_TTL"; printf '\n'
    printf 'CODING_TOOLS_MCP_OAUTH_PASSWORD='; systemd_env_quote "${CODING_TOOLS_MCP_OAUTH_PASSWORD:-}"; printf '\n'
    printf 'CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET='; systemd_env_quote "${CODING_TOOLS_MCP_OAUTH_TOKEN_SECRET:-}"; printf '\n'
    printf 'CODING_TOOLS_MCP_AUTH_TOKEN='; systemd_env_quote "$AUTH_TOKEN"; printf '\n'
  } >"$temp_file"
  install -m 0600 -o root -g root "$temp_file" "$ENV_FILE"
  rm -f -- "$temp_file"
}

write_systemd_unit() {
  local bin="$1" temp_file service_group quoted_bin escaped_env escaped_workspace
  service_group="$(id -gn "$SERVICE_USER")"
  quoted_bin="$(systemd_env_quote "$bin")"
  escaped_env="$(systemd_unit_path "$ENV_FILE")"
  escaped_workspace="$(systemd_unit_path "$WORKSPACE")"
  temp_file="$(mktemp "${UNIT_FILE}.XXXXXX")"
  cat >"$temp_file" <<EOF
[Unit]
Description=Coding Tools MCP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$service_group
EnvironmentFile=$escaped_env
WorkingDirectory=$escaped_workspace
ExecStart=$quoted_bin
Restart=always
RestartSec=3
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 -o root -g root "$temp_file" "$UNIT_FILE"
  rm -f -- "$temp_file"
}

wait_for_persistent_service() {
  if ! command -v curl >/dev/null 2>&1; then
    sleep 1
    systemctl is-active --quiet "$SERVICE_NAME.service" \
      || die "$SERVICE_NAME.service failed to stay active"
    return
  fi
  local probe_host="$HOST"
  [[ "$probe_host" == "localhost" ]] && probe_host="127.0.0.1"
  [[ "$probe_host" == *:* ]] && probe_host="[$probe_host]"
  for _ in {1..20}; do
    if curl -s --max-time 2 -o /dev/null "http://$probe_host:$PORT/mcp"; then
      return
    fi
    if ! systemctl is-active --quiet "$SERVICE_NAME.service"; then
      break
    fi
    sleep 0.25
  done
  journalctl -u "$SERVICE_NAME.service" -n 30 --no-pager >&2 || true
  die "$SERVICE_NAME.service did not become ready on $HOST:$PORT"
}

install_persistent_service() {
  local bin service_group
  prepare_persistent_settings
  install_persistent_package
  bin="$(find_installed_command)" || die "could not locate ${SCRIPT_NAME} after installation"
  service_group="$(id -gn "$SERVICE_USER")"
  install -d -m 0700 -o "$SERVICE_USER" -g "$service_group" "$STATE_DIR"
  write_persistent_environment
  write_systemd_unit "$bin"
  if [[ "$GENERATED_OAUTH_PASSWORD" == "1" ]]; then
    cat <<EOF

OAuth administrator password (shown once; save it now):
  $CODING_TOOLS_MCP_OAUTH_PASSWORD
EOF
  fi
  run systemctl daemon-reload
  run systemctl enable "$SERVICE_NAME.service"
  if systemctl is-active --quiet "$SERVICE_NAME.service"; then
    run systemctl restart "$SERVICE_NAME.service"
  else
    run systemctl start "$SERVICE_NAME.service"
  fi
  wait_for_persistent_service

  cat <<EOF

Coding Tools MCP installed successfully

Service:
  $SERVICE_NAME.service

Internal:
  http://$HOST:$PORT

Public MCP:
  ${PUBLIC_URL:-http://$HOST:$PORT}/mcp

Auth:
  $AUTH_MODE

Workspace:
  $WORKSPACE

OAuth state:
  $STATE_DIR/oauth.db

Config:
  $ENV_FILE

Status:
  systemctl status $SERVICE_NAME --no-pager
  journalctl -u $SERVICE_NAME -n 100 --no-pager
EOF
}

show_persistent_status() {
  require_root
  local status_host status_port status_url status_state status_workspace status_auth status_permission
  status_host="$(existing_config_value CODING_TOOLS_MCP_HOST)"
  status_port="$(existing_config_value CODING_TOOLS_MCP_PORT)"
  status_url="$(existing_config_value CODING_TOOLS_MCP_SERVER_URL)"
  status_state="$(existing_config_value CODING_TOOLS_MCP_STATE_DIR)"
  status_workspace="$(existing_config_value CODING_TOOLS_MCP_WORKSPACE)"
  status_auth="$(existing_config_value CODING_TOOLS_MCP_AUTH_MODE)"
  status_permission="$(existing_config_value CODING_TOOLS_MCP_PERMISSION_MODE)"
  echo "Service: $SERVICE_NAME.service ($(systemctl is-active "$SERVICE_NAME.service" 2>/dev/null || true))"
  echo "Listen: ${status_host:-unknown}:${status_port:-unknown}"
  echo "Workspace: ${status_workspace:-unknown}"
  echo "Auth mode: ${status_auth:-unknown}"
  echo "Permission mode: ${status_permission:-unknown}"
  echo "Public URL: ${status_url:-unknown}"
  if [[ -n "$status_state" && -f "$status_state/oauth.db" ]]; then
    echo "OAuth database: $status_state/oauth.db (available)"
  else
    echo "OAuth database: ${status_state:-unknown}/oauth.db (missing)"
  fi
  if [[ -n "$status_url" ]] && command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "$status_url/.well-known/oauth-authorization-server" >/dev/null; then
      echo "OAuth metadata: available"
    else
      echo "OAuth metadata: unavailable"
    fi
  fi
}

safe_purge_path() {
  local target="$1"
  case "$target" in
    ""|/|/etc|/var|/var/lib|/home|/root) die "refusing unsafe purge path: $target" ;;
  esac
  rm -rf -- "$target"
}

uninstall_persistent_service() {
  require_root
  systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_FILE"
  systemctl daemon-reload
  if [[ -d "$PERSISTENT_ROOT" ]]; then
    safe_purge_path "$PERSISTENT_ROOT"
  fi
  if [[ "$PURGE" == "1" ]]; then
    local state_to_purge
    state_to_purge="$(existing_config_value CODING_TOOLS_MCP_STATE_DIR)"
    state_to_purge="${state_to_purge:-$STATE_DIR}"
    [[ -n "$state_to_purge" ]] && safe_purge_path "$state_to_purge"
    safe_purge_path "$CONFIG_DIR"
    echo "Removed service, configuration, secrets, and OAuth state."
  else
    echo "Removed $SERVICE_NAME.service and installed command."
    echo "Preserved configuration: $CONFIG_DIR"
    echo "Preserved OAuth state: $(existing_config_value CODING_TOOLS_MCP_STATE_DIR)/oauth.db"
    echo "Rerun with --uninstall --purge only when permanent credential deletion is intended."
  fi
}

resolve_runtime_defaults() {
  case "$ACTION" in
    install) ;;
    start)
      AUTH_MODE="${AUTH_MODE:-noauth}"
      ;;
    tunnel)
      AUTH_MODE="${AUTH_MODE:-bearer}"
      ;;
  esac
  case "$AUTH_MODE" in
    ""|bearer|noauth) ;;
    oauth) require_oauth_env_install ;;
    *) die "--auth-mode must be bearer, noauth, or oauth" ;;
  esac
  if [[ "$AUTH_MODE" == "bearer" && -z "$AUTH_TOKEN" ]]; then
    AUTH_TOKEN="$(generate_token)"
  fi
  if [[ -n "$PUBLIC_URL" ]]; then
    PUBLIC_URL="${PUBLIC_URL%/}"
    export CODING_TOOLS_MCP_SERVER_URL="$PUBLIC_URL"
  fi
}

require_oauth_env_install() {
  if [[ -z "${CODING_TOOLS_MCP_OAUTH_PASSWORD:-}" ]]; then
    CODING_TOOLS_MCP_OAUTH_PASSWORD="$(generate_token)"
  fi
  export CODING_TOOLS_MCP_OAUTH_PASSWORD
}

server_args() {
  local args=(
    --workspace "$WORKSPACE"
    --host "$HOST"
    --port "$PORT"
    --permission-mode "$PERMISSION_MODE"
  )
  case "$AUTH_MODE" in
    bearer) args+=(--auth-token "$AUTH_TOKEN") ;;
    oauth) args+=(--oauth-mode) ;;
  esac
  printf "%s\0" "${args[@]}"
}

print_local_config() {
  cat <<EOF
coding-tools-mcp will listen on http://$HOST:$PORT/mcp
Workspace: $WORKSPACE
Auth mode: $AUTH_MODE
EOF
  case "$AUTH_MODE" in
    bearer)
      cat <<EOF
Header: Authorization: Bearer $AUTH_TOKEN
EOF
      ;;
    oauth)
      local base="${CODING_TOOLS_MCP_SERVER_URL:-http://127.0.0.1:$PORT}"
      base="${base%/}"
      cat <<EOF
OAuth issuer: $base
OAuth password: $CODING_TOOLS_MCP_OAUTH_PASSWORD
Client registration: $base/oauth/register (RFC 7591)
Authorization metadata: $base/.well-known/oauth-authorization-server
Protected resource:     $base/.well-known/oauth-protected-resource
EOF
      ;;
  esac
}

print_tunnel_config() {
  local label="$1"
  local host_placeholder="$2"
  cat <<EOF
coding-tools-mcp is listening on http://127.0.0.1:$PORT/mcp
Workspace: $WORKSPACE
Auth mode: $AUTH_MODE

$label will print an HTTPS URL.
EOF
  case "$AUTH_MODE" in
    bearer)
      cat <<EOF

Generic MCP clients that support custom headers should use:
URL: https://<$host_placeholder>/mcp
Header: Authorization: Bearer $AUTH_TOKEN
EOF
      ;;
    oauth)
      local base="${CODING_TOOLS_MCP_SERVER_URL:-https://<$host_placeholder>}"
      base="${base%/}"
      cat <<EOF

OAuth 2.1 Authorization Code + PKCE is active. Configure your MCP client
with the HTTPS URL printed by $label after it starts. The server derives
its OAuth issuer from that request URL unless CODING_TOOLS_MCP_SERVER_URL
is preset.

OAuth password: $CODING_TOOLS_MCP_OAUTH_PASSWORD
Client registration: $base/oauth/register (RFC 7591)

Authorization metadata: $base/.well-known/oauth-authorization-server
Protected resource:     $base/.well-known/oauth-protected-resource
MCP endpoint:           $base/mcp
EOF
      ;;
    *)
      cat <<EOF

Remote MCP client URL:
https://<$host_placeholder>/mcp

No Authorization header is used. The fixed tool set includes mutation and
command execution; do not expose this tunnel publicly without authentication.
EOF
      ;;
  esac
}

install_package() {
  if [[ -n "$SERVER_BIN" ]]; then
    [[ -x "$SERVER_BIN" ]] || die "--server-bin is not executable: $SERVER_BIN"
    log "Using existing command: $SERVER_BIN"
    if [[ "$VERIFY" == "1" ]]; then
      run "$SERVER_BIN" --help >/dev/null
    fi
    return
  fi
  local spec installer
  spec="$(package_spec)"
  installer="$(select_method)"
  log "Installing ${spec} with ${installer}"
  case "$installer" in
    uv)
      command -v uv >/dev/null 2>&1 || die "uv is not installed; rerun with --method pip or install uv"
      run uv tool install --force "$spec"
      ;;
    pip)
      local python_bin
      python_bin="$(find_python)" || die "python3 or python is required for pip install"
      run "$python_bin" -m pip install --user --upgrade "$spec"
      ;;
    *)
      die "unknown installer: $installer"
      ;;
  esac
  if [[ "$VERIFY" == "1" ]]; then
    local bin
    if bin="$(find_installed_command)"; then
      run "$bin" --help >/dev/null
      log "Installed command: $bin"
    else
      warn_path
      die "installed package but could not locate ${SCRIPT_NAME}"
    fi
  fi
}

install_persistent_package() {
  if [[ -n "$SERVER_BIN" ]]; then
    local source_bin target_bin source_real target_real
    [[ -x "$SERVER_BIN" ]] || die "--server-bin is not executable: $SERVER_BIN"
    source_bin="$SERVER_BIN"
    source_real="$(cd "$(dirname "$source_bin")" && pwd -P)/$(basename "$source_bin")"
    install -d -m 0755 -o root -g root "$PERSISTENT_ROOT/bin"
    target_bin="$PERSISTENT_ROOT/bin/$SCRIPT_NAME"
    target_real="$(cd "$(dirname "$target_bin")" && pwd -P)/$(basename "$target_bin")"
    if [[ "$source_real" != "$target_real" ]]; then
      run install -m 0755 -o root -g root "$source_bin" "$target_bin"
    fi
    SERVER_BIN="$target_bin"
    if [[ "$VERIFY" == "1" ]]; then
      run "$SERVER_BIN" --help >/dev/null
    fi
    return
  fi
  local python_bin spec venv_python
  python_bin="$(find_python)" || die "python3 or python is required for persistent installation"
  spec="$(package_spec)"
  install -d -m 0755 -o root -g root "$PERSISTENT_ROOT"
  if [[ ! -x "$PERSISTENT_ROOT/venv/bin/python" ]]; then
    run "$python_bin" -m venv "$PERSISTENT_ROOT/venv"
  fi
  venv_python="$PERSISTENT_ROOT/venv/bin/python"
  run "$venv_python" -m pip install --upgrade pip
  run "$venv_python" -m pip install --upgrade "$spec"
  if [[ "$WITH_IMAGE" == "1" && -n "$INSTALL_SOURCE" ]]; then
    run "$venv_python" -m pip install --upgrade "Pillow>=10.0"
  fi
  SERVER_BIN="$PERSISTENT_ROOT/venv/bin/$SCRIPT_NAME"
  [[ -x "$SERVER_BIN" ]] || die "persistent install did not create $SERVER_BIN"
  if [[ "$VERIFY" == "1" ]]; then
    run "$SERVER_BIN" --help >/dev/null
  fi
}

start_local_server() {
  local bin
  bin="$(find_installed_command)" || die "could not locate ${SCRIPT_NAME}; install failed or PATH is missing"
  [[ -d "$WORKSPACE" ]] || die "workspace does not exist: $WORKSPACE"
  print_local_config
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(server_args)
  exec "$bin" "${args[@]}"
}

start_tunnel() {
  local bin tool
  bin="$(find_installed_command)" || die "could not locate ${SCRIPT_NAME}; install failed or PATH is missing"
  [[ -d "$WORKSPACE" ]] || die "workspace does not exist: $WORKSPACE"
  ensure_tunnel_command "$TUNNEL_PROVIDER"
  tool="$TUNNEL_TOOL"
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(server_args)
  "$bin" "${args[@]}" &
  SERVER_PID=$!
  trap cleanup EXIT INT TERM
  sleep 1
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    die "coding-tools-mcp exited before the tunnel started"
  fi
  case "$tool" in
    cloudflared)
      print_tunnel_config "cloudflared" "cloudflared-host"
      cloudflared tunnel --url "http://127.0.0.1:$PORT"
      ;;
    ngrok)
      print_tunnel_config "ngrok" "ngrok-host"
      ngrok http "http://127.0.0.1:$PORT"
      ;;
    devtunnel)
      print_tunnel_config "Microsoft Dev Tunnel" "devtunnel-host"
      devtunnel host --port "$PORT" --protocol http --allow-anonymous
      ;;
    *)
      die "unknown tunnel tool: $tool"
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      VERSION="$2"
      shift
      ;;
    --with-image)
      WITH_IMAGE=1
      ;;
    --method)
      [[ $# -ge 2 ]] || die "--method requires a value"
      METHOD="$2"
      shift
      ;;
    --source)
      [[ $# -ge 2 ]] || die "--source requires a value"
      INSTALL_SOURCE="$2"
      shift
      ;;
    --no-verify)
      VERIFY=0
      ;;
    --start)
      ACTION="start"
      ;;
    --persistent|--systemd)
      PERSISTENT=1
      ACTION="persistent"
      ;;
    --status)
      ACTION="status"
      ;;
    --uninstall)
      ACTION="uninstall"
      ;;
    --purge)
      PURGE=1
      ;;
    --install-only)
      ACTION="install"
      ;;
    --tunnel)
      ACTION="tunnel"
      if [[ $# -ge 2 && "$2" != --* ]]; then
        TUNNEL_PROVIDER="$2"
        shift
      fi
      if [[ "$TUNNEL_PROVIDER" == "none" ]]; then
        ACTION="start"
      fi
      ;;
    --provider)
      [[ $# -ge 2 ]] || die "--provider requires a value"
      TUNNEL_PROVIDER="$2"
      shift
      ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE="$2"
      WORKSPACE_EXPLICIT=1
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      HOST="$2"
      HOST_EXPLICIT=1
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      PORT="$2"
      PORT_EXPLICIT=1
      shift
      ;;
    --public-url)
      [[ $# -ge 2 ]] || die "--public-url requires a value"
      PUBLIC_URL="$2"
      PUBLIC_URL_EXPLICIT=1
      shift
      ;;
    --auth-mode)
      [[ $# -ge 2 ]] || die "--auth-mode requires a value"
      AUTH_MODE="$2"
      AUTH_MODE_EXPLICIT=1
      shift
      ;;
    --auth-token)
      [[ $# -ge 2 ]] || die "--auth-token requires a value"
      AUTH_TOKEN="$2"
      shift
      ;;
    --permission-mode)
      [[ $# -ge 2 ]] || die "--permission-mode requires a value"
      PERMISSION_MODE="$2"
      PERMISSION_MODE_EXPLICIT=1
      shift
      ;;
    --state-dir)
      [[ $# -ge 2 ]] || die "--state-dir requires a value"
      STATE_DIR="$2"
      STATE_DIR_EXPLICIT=1
      shift
      ;;
    --service-user)
      [[ $# -ge 2 ]] || die "--service-user requires a value"
      SERVICE_USER="$2"
      shift
      ;;
    --server-bin)
      [[ $# -ge 2 ]] || die "--server-bin requires a value"
      SERVER_BIN="$2"
      shift
      ;;
    --auto-install-tunnel)
      export CODING_TOOLS_MCP_AUTO_INSTALL_TUNNEL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown argument: $1"
      ;;
    *)
      WORKSPACE="$1"
      WORKSPACE_EXPLICIT=1
      ;;
  esac
  shift
done

if [[ "$PURGE" == "1" && "$ACTION" != "uninstall" ]]; then
  die "--purge is valid only with --uninstall"
fi
if [[ "$ACTION" == "tunnel" && "$TUNNEL_PROVIDER" == "none" ]]; then
  ACTION="start"
fi
if [[ "$PERSISTENT" == "1" && "$ACTION" != "status" && "$ACTION" != "uninstall" ]]; then
  ACTION="persistent"
fi

case "$ACTION" in
  install)
    resolve_runtime_defaults
    install_package
    log "Install completed"
    ;;
  start)
    resolve_runtime_defaults
    install_package
    start_local_server
    ;;
  tunnel)
    resolve_runtime_defaults
    install_package
    start_tunnel
    ;;
  persistent)
    install_persistent_service
    ;;
  status)
    show_persistent_status
    ;;
  uninstall)
    uninstall_persistent_service
    ;;
  *)
    die "unknown action: $ACTION"
    ;;
esac
