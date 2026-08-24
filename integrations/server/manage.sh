#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ORIGINAL_ARGS=("$@")
SERVICE_NAME="${CODING_TOOLS_MCP_SERVICE_NAME:-coding-tools-mcp}"
CONFIG_DIR="${CODING_TOOLS_MCP_CONFIG_DIR:-/etc/coding-tools-mcp}"
ENV_FILE="${CODING_TOOLS_MCP_ENV_FILE:-$CONFIG_DIR/coding-tools-mcp.env}"
ACTION="menu"
WORKSPACE=""
PUBLIC_URL=""
HOST=""
PORT=""
AUTH_MODE=""
PERMISSION_MODE=""
SERVICE_USER=""
NEW_OAUTH_PASSWORD=""

if [[ -x "$SCRIPT_DIR/install.sh" && -x "$SCRIPT_DIR/coding-tools-mcp" ]]; then
  INSTALLER="$SCRIPT_DIR/install.sh"
  INSTALL_KIND="binary"
  INSTALL_VALUE="$SCRIPT_DIR/coding-tools-mcp"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
  INSTALLER="$REPO_ROOT/scripts/install.sh"
  INSTALL_KIND="source"
  INSTALL_VALUE="$REPO_ROOT"
fi

usage() {
  cat <<'EOF'
Usage: integrations/server/manage.sh [command] [options]

Interactive systemd operations for a persistent Coding Tools MCP server.
Running without a command opens the operations menu.

Commands:
  install               Interactive first install or reconfiguration.
  update                Update from this checkout/bundle and restart safely.
  start                 Start the service.
  stop                  Stop the service.
  restart               Restart the service.
  status                Show service and non-secret configuration status.
  logs                  Show the latest 100 service log lines.
  logs-follow           Follow service logs until Ctrl-C.
  configure             Interactively modify persistent configuration.
  uninstall             Remove service/binary; preserve config and OAuth state.
  purge                 Remove service, config, secrets, and OAuth state.

Install/configure options:
  --workspace PATH
  --public-url URL
  --host HOST
  --port PORT
  --auth-mode oauth|bearer
  --permission-mode safe|trusted|dangerous
  --service-user USER
  -h, --help

OAuth passwords can be changed through the hidden-input interactive
configuration flow, or supplied through CODING_TOOLS_MCP_OAUTH_PASSWORD.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" == "0" ]]; then
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- "$0" "$@"
  fi
  die "systemd operations require root; rerun with sudo"
}

config_value() {
  local key="$1"
  [[ -r "$ENV_FILE" ]] || return 0
  bash -c 'set -a; source "$1"; printf "%s" "${!2-}"' bash "$ENV_FILE" "$key"
}

unit_value() {
  local key="$1"
  local unit_file="${CODING_TOOLS_MCP_UNIT_FILE:-/etc/systemd/system/$SERVICE_NAME.service}"
  [[ -r "$unit_file" ]] || return 0
  sed -n "s/^${key}=//p" "$unit_file" | head -n 1
}

prompt_value() {
  local variable="$1" label="$2" default="$3" required="${4:-0}" value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$label [$default]: " value
      value="${value:-$default}"
    else
      read -r -p "$label: " value
    fi
    if [[ "$required" != "1" || -n "$value" ]]; then
      printf -v "$variable" '%s' "$value"
      return
    fi
    echo "$label is required." >&2
  done
}

prompt_choice() {
  local variable="$1" label="$2" default="$3" allowed="$4" value
  while true; do
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
    if [[ " $allowed " == *" $value "* ]]; then
      printf -v "$variable" '%s' "$value"
      return
    fi
    echo "Choose one of: $allowed" >&2
  done
}

collect_configuration() {
  local current_workspace current_url current_host current_port current_auth
  local current_permission current_user change_password
  current_workspace="$(config_value CODING_TOOLS_MCP_WORKSPACE)"
  current_url="$(config_value CODING_TOOLS_MCP_SERVER_URL)"
  current_host="$(config_value CODING_TOOLS_MCP_HOST)"
  current_port="$(config_value CODING_TOOLS_MCP_PORT)"
  current_auth="$(config_value CODING_TOOLS_MCP_AUTH_MODE)"
  current_permission="$(config_value CODING_TOOLS_MCP_PERMISSION_MODE)"
  current_user="$(unit_value User)"

  prompt_value WORKSPACE "Workspace" "${WORKSPACE:-${current_workspace:-$PWD}}" 1
  prompt_value PUBLIC_URL "Stable public URL (for example https://mcp.example.com)" \
    "${PUBLIC_URL:-$current_url}" 1
  prompt_value HOST "Listen host" "${HOST:-${current_host:-127.0.0.1}}" 1
  prompt_value PORT "Listen port" "${PORT:-${current_port:-8765}}" 1
  prompt_choice AUTH_MODE "Authentication mode" "${AUTH_MODE:-${current_auth:-oauth}}" "oauth bearer"
  prompt_choice PERMISSION_MODE "Permission mode" \
    "${PERMISSION_MODE:-${current_permission:-safe}}" "safe trusted dangerous"
  prompt_value SERVICE_USER "Service user" "${SERVICE_USER:-${current_user:-${SUDO_USER:-root}}}" 1

  if [[ "$AUTH_MODE" == "oauth" ]]; then
    read -r -p "Change the OAuth administrator password? [y/N] " change_password
    if [[ "$change_password" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      while [[ -z "$NEW_OAUTH_PASSWORD" ]]; do
        read -r -s -p "New OAuth administrator password: " NEW_OAUTH_PASSWORD
        printf '\n'
      done
    fi
  fi
}

install_source_args() {
  if [[ "$INSTALL_KIND" == "binary" ]]; then
    printf '%s\0%s\0' --server-bin "$INSTALL_VALUE"
  else
    printf '%s\0%s\0' --source "$INSTALL_VALUE"
  fi
}

run_install() {
  local interactive="${1:-0}" args=() source_args=() env_args=()
  if [[ "$interactive" == "1" ]]; then
    collect_configuration
  fi
  while IFS= read -r -d '' value; do
    source_args+=("$value")
  done < <(install_source_args)
  args=(--persistent "${source_args[@]}")
  [[ -n "$WORKSPACE" ]] && args+=(--workspace "$WORKSPACE")
  [[ -n "$PUBLIC_URL" ]] && args+=(--public-url "$PUBLIC_URL")
  [[ -n "$HOST" ]] && args+=(--host "$HOST")
  [[ -n "$PORT" ]] && args+=(--port "$PORT")
  [[ -n "$AUTH_MODE" ]] && args+=(--auth-mode "$AUTH_MODE")
  [[ -n "$PERMISSION_MODE" ]] && args+=(--permission-mode "$PERMISSION_MODE")
  [[ -n "$SERVICE_USER" ]] && args+=(--service-user "$SERVICE_USER")
  if [[ -n "$NEW_OAUTH_PASSWORD" ]]; then
    env_args+=("CODING_TOOLS_MCP_OAUTH_PASSWORD=$NEW_OAUTH_PASSWORD")
  fi
  env "${env_args[@]}" "$INSTALLER" "${args[@]}"
}

show_status() {
  "$INSTALLER" --status
  echo
  systemctl status "$SERVICE_NAME.service" --no-pager --lines=12 || true
}

confirm_purge() {
  local answer
  cat <<EOF
This permanently deletes:
  $CONFIG_DIR
  the OAuth client registry, refresh tokens, password, and signing secret

Type PURGE to continue.
EOF
  read -r answer
  [[ "$answer" == "PURGE" ]] || {
    echo "Purge cancelled."
    return 1
  }
}

run_action() {
  case "$ACTION" in
    install|configure)
      run_install 1
      ;;
    update)
      if [[ ! -f "$ENV_FILE" ]]; then
        echo "No persistent installation found; starting first-time setup."
        run_install 1
      else
        run_install 0
      fi
      ;;
    start|stop|restart)
      systemctl "$ACTION" "$SERVICE_NAME.service"
      systemctl is-active "$SERVICE_NAME.service" || true
      ;;
    status)
      show_status
      ;;
    logs)
      journalctl -u "$SERVICE_NAME.service" -n 100 --no-pager
      ;;
    logs-follow)
      journalctl -u "$SERVICE_NAME.service" -n 100 -f
      ;;
    uninstall)
      "$INSTALLER" --uninstall
      ;;
    purge)
      confirm_purge && "$INSTALLER" --uninstall --purge
      ;;
    *)
      die "unknown action: $ACTION"
      ;;
  esac
}

interactive_menu() {
  [[ -t 0 && -t 1 ]] || die "no command supplied and no interactive terminal is available; use --help"
  while true; do
    cat <<'EOF'

Coding Tools MCP server operations

  1) Install / update
  2) Start
  3) Stop
  4) Restart
  5) Status
  6) View logs
  7) Follow logs
  8) Modify configuration
  9) Uninstall (keep OAuth state and config)
 10) Purge (permanently delete OAuth state and config)
  0) Exit
EOF
    local choice
    read -r -p "Select [0-10]: " choice
    case "$choice" in
      1) ACTION="update"; run_action ;;
      2) ACTION="start"; run_action ;;
      3) ACTION="stop"; run_action ;;
      4) ACTION="restart"; run_action ;;
      5) ACTION="status"; run_action ;;
      6) ACTION="logs"; run_action ;;
      7) ACTION="logs-follow"; run_action ;;
      8) ACTION="configure"; run_action ;;
      9)
        read -r -p "Remove the service but keep OAuth state and config? [y/N] " choice
        if [[ "$choice" =~ ^[Yy]([Ee][Ss])?$ ]]; then
          ACTION="uninstall"
          run_action
        fi
        ;;
      10) ACTION="purge"; run_action || true ;;
      0) return ;;
      *) echo "Invalid selection." >&2 ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|start|stop|restart|status|logs|logs-follow|configure|uninstall|purge)
      ACTION="$1"
      ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace requires a value"
      WORKSPACE="$2"
      shift
      ;;
    --public-url)
      [[ $# -ge 2 ]] || die "--public-url requires a value"
      PUBLIC_URL="$2"
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      HOST="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      PORT="$2"
      shift
      ;;
    --auth-mode)
      [[ $# -ge 2 ]] || die "--auth-mode requires a value"
      AUTH_MODE="$2"
      shift
      ;;
    --permission-mode)
      [[ $# -ge 2 ]] || die "--permission-mode requires a value"
      PERMISSION_MODE="$2"
      shift
      ;;
    --service-user)
      [[ $# -ge 2 ]] || die "--service-user requires a value"
      SERVICE_USER="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "$ACTION" == "menu" ]]; then
  require_root
  interactive_menu
else
  require_root "${ORIGINAL_ARGS[@]}"
  run_action
fi
