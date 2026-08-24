#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ORIGINAL_ARGS=("$@")
SERVICE_NAME="${CODING_TOOLS_MCP_SERVICE_NAME:-coding-tools-mcp}"
CONFIG_DIR="${CODING_TOOLS_MCP_CONFIG_DIR:-/etc/coding-tools-mcp}"
ENV_FILE="${CODING_TOOLS_MCP_ENV_FILE:-$CONFIG_DIR/coding-tools-mcp.env}"
DEFAULT_PUBLIC_URL="${CODING_TOOLS_MCP_DEFAULT_PUBLIC_URL:-https://mcp.example.com}"
RELEASE_REPOSITORY="${CODING_TOOLS_MCP_RELEASE_REPOSITORY:-dovetaill/coding-tools-mcp}"
RELEASE_BASE_URL="${CODING_TOOLS_MCP_RELEASE_BASE_URL:-https://github.com/$RELEASE_REPOSITORY/releases/latest/download}"
SKIP_SELF_UPDATE="${CODING_TOOLS_MCP_SKIP_SELF_UPDATE:-0}"
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
用法：integrations/server/manage.sh [命令] [选项]

用于长期运行 Coding Tools MCP systemd 服务的中文交互式运维工具。
不带参数运行时会进入运维菜单。

命令：
  install               首次安装或重新配置
  update                自动更新程序和脚本，然后安全重启
  start                 启动服务
  stop                  停止服务
  restart               重启服务
  status                查看服务和非敏感配置状态
  logs                  查看最近 100 行服务日志
  logs-follow           持续查看日志，按 Ctrl-C 退出
  configure             交互式修改持久配置
  uninstall             卸载服务和程序，保留配置及 OAuth 状态
  purge                 永久删除服务、配置、密钥和 OAuth 状态

安装/配置选项：
  --workspace 路径
  --public-url 网址
  --host 主机
  --port 端口
  --auth-mode oauth|bearer                 认证方式
  --permission-mode safe|trusted|dangerous 权限等级
  --service-user 用户
  -h, --help            显示本帮助

OAuth 管理密码可在交互式配置中以隐藏输入方式修改，也可以通过
CODING_TOOLS_MCP_OAUTH_PASSWORD 环境变量提供。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" == "0" ]]; then
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -- "$0" "$@"
  fi
  die "systemd 运维需要 root 权限，请使用 sudo 重新运行"
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
    echo "$label 为必填项。" >&2
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
    echo "请选择以下值之一：$allowed" >&2
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

  prompt_value WORKSPACE "工作目录" "${WORKSPACE:-${current_workspace:-$PWD}}" 1
  prompt_value PUBLIC_URL "固定公网网址" \
    "${PUBLIC_URL:-${current_url:-$DEFAULT_PUBLIC_URL}}" 1
  prompt_value HOST "监听地址" "${HOST:-${current_host:-127.0.0.1}}" 1
  prompt_value PORT "监听端口" "${PORT:-${current_port:-8765}}" 1
  prompt_choice AUTH_MODE "认证模式（oauth=网页登录，bearer=固定令牌）" \
    "${AUTH_MODE:-${current_auth:-oauth}}" "oauth bearer"
  prompt_choice PERMISSION_MODE "权限模式（safe=安全，trusted=信任，dangerous=危险）" \
    "${PERMISSION_MODE:-${current_permission:-safe}}" "safe trusted dangerous"
  prompt_value SERVICE_USER "服务运行用户" "${SERVICE_USER:-${current_user:-${SUDO_USER:-root}}}" 1

  if [[ "$AUTH_MODE" == "oauth" ]]; then
    read -r -p "是否修改 OAuth 管理密码？[y/N/是/否] " change_password
    if [[ "$change_password" =~ ^[Yy]([Ee][Ss])?$ || "$change_password" == "是" ]]; then
      while [[ -z "$NEW_OAUTH_PASSWORD" ]]; do
        read -r -s -p "请输入新的 OAuth 管理密码：" NEW_OAUTH_PASSWORD
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

run_logged_command() {
  local success_message="$1" log_file status generated_password
  shift
  log_file="$(mktemp "${TMPDIR:-/tmp}/coding-tools-mcp-manage.XXXXXX")"
  chmod 0600 "$log_file"
  trap 'rm -f -- "$log_file"; exit 130' INT TERM HUP
  echo "==> 正在执行，请稍候……"
  if "$@" >"$log_file" 2>&1; then
    generated_password="$(sed -n '/OAuth administrator password (shown once/{n;s/^[[:space:]]*//;p;q;}' "$log_file")"
    if [[ -n "$generated_password" ]]; then
      cat <<EOF

首次生成的 OAuth 管理密码（仅显示这一次，请立即保存）：
  $generated_password
EOF
    fi
    trap - INT TERM HUP
    rm -f -- "$log_file"
    echo "$success_message"
    return 0
  else
    status=$?
  fi
  echo "操作失败，下面是原始诊断信息：" >&2
  cat "$log_file" >&2
  trap - INT TERM HUP
  rm -f -- "$log_file"
  return "$status"
}

download_file() {
  local url="$1" output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    die "自动更新需要 curl 或 wget"
  fi
}

release_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    *) die "GitHub 自动发布包目前仅支持 x86_64，当前架构为：$arch" ;;
  esac
  [[ "$os" == "linux" ]] || die "独立包自动更新目前仅支持 Linux"
  printf '%s-%s\n' "$os" "$arch"
}

verify_download_checksum() {
  local archive="$1" checksums="$2" asset_name="$3" expected actual
  expected="$(awk -v name="$asset_name" '$2 == name || $2 == "./" name {print $1; exit}' "$checksums")"
  [[ -n "$expected" ]] || die "发布校验文件中找不到 $asset_name"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$archive" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  else
    die "校验更新包需要 sha256sum 或 shasum"
  fi
  [[ "$actual" == "$expected" ]] || die "更新包 SHA-256 校验失败"
}

atomic_install() {
  local mode="$1" source="$2" target="$3" temporary
  temporary="${target}.new.$$"
  install -m "$mode" "$source" "$temporary"
  mv -f -- "$temporary" "$target"
}

update_bundle_source() {
  local platform asset base_url temp_dir archive checksums bundle_dir
  platform="$(release_platform)"
  asset="coding-tools-mcp-$platform.tar.gz"
  base_url="$RELEASE_BASE_URL"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/coding-tools-mcp-update.XXXXXX")"
  archive="$temp_dir/$asset"
  checksums="$temp_dir/SHA256SUMS"
  trap 'rm -rf -- "$temp_dir"; exit 130' INT TERM HUP
  echo "==> 正在从 GitHub Release 下载最新版程序和脚本……"
  download_file "$base_url/$asset" "$archive"
  download_file "$base_url/SHA256SUMS" "$checksums"
  verify_download_checksum "$archive" "$checksums" "$asset"
  tar -C "$temp_dir" -xzf "$archive"
  bundle_dir="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d -name 'coding-tools-mcp-*' -print -quit)"
  [[ -n "$bundle_dir" ]] || die "更新包目录结构无效"
  [[ -x "$bundle_dir/coding-tools-mcp" ]] || die "更新包缺少服务器程序"
  [[ -x "$bundle_dir/coding-tools-mcp-admin" ]] || die "更新包缺少运维脚本"
  [[ -x "$bundle_dir/install.sh" ]] || die "更新包缺少安装脚本"
  atomic_install 0755 "$bundle_dir/coding-tools-mcp" "$SCRIPT_DIR/coding-tools-mcp"
  atomic_install 0755 "$bundle_dir/coding-tools-mcp-admin" "$SCRIPT_DIR/coding-tools-mcp-admin"
  atomic_install 0755 "$bundle_dir/install.sh" "$SCRIPT_DIR/install.sh"
  trap - INT TERM HUP
  rm -rf -- "$temp_dir"
  INSTALLER="$SCRIPT_DIR/install.sh"
  INSTALL_VALUE="$SCRIPT_DIR/coding-tools-mcp"
  echo "程序和运维脚本已更新到最新 Release。"
  if [[ ${#ORIGINAL_ARGS[@]} -gt 0 ]]; then
    exec env CODING_TOOLS_MCP_SKIP_SELF_UPDATE=1 \
      "$SCRIPT_DIR/coding-tools-mcp-admin" "${ORIGINAL_ARGS[@]}"
  fi
}

update_repository_source() {
  command -v git >/dev/null 2>&1 || die "源码模式自动更新需要 git"
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
    die "仓库存在未提交修改；为防止覆盖，请先提交或处理后再更新"
  fi
  run_logged_command "源码和运维脚本已更新。" \
    git -C "$REPO_ROOT" pull --ff-only origin main
  if [[ ${#ORIGINAL_ARGS[@]} -gt 0 ]]; then
    exec env CODING_TOOLS_MCP_SKIP_SELF_UPDATE=1 \
      "$REPO_ROOT/integrations/server/manage.sh" "${ORIGINAL_ARGS[@]}"
  fi
}

update_program_and_scripts() {
  [[ "$SKIP_SELF_UPDATE" == "1" ]] && return
  if [[ "$INSTALL_KIND" == "source" ]]; then
    update_repository_source
  else
    update_bundle_source
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
  run_logged_command "安装或更新完成，服务已重新启动。" \
    env "${env_args[@]}" "$INSTALLER" "${args[@]}"
}

state_zh() {
  case "$1" in
    active) echo "运行中" ;;
    inactive) echo "已停止" ;;
    failed) echo "启动失败" ;;
    activating) echo "正在启动" ;;
    deactivating) echo "正在停止" ;;
    enabled) echo "已启用" ;;
    disabled) echo "未启用" ;;
    *) echo "未知（$1）" ;;
  esac
}

show_status() {
  local service_state enabled_state status_host status_port status_url
  local status_state status_workspace status_auth status_permission metadata_state database_state
  service_state="$(systemctl is-active "$SERVICE_NAME.service" 2>/dev/null || true)"
  enabled_state="$(systemctl is-enabled "$SERVICE_NAME.service" 2>/dev/null || true)"
  status_host="$(config_value CODING_TOOLS_MCP_HOST)"
  status_port="$(config_value CODING_TOOLS_MCP_PORT)"
  status_url="$(config_value CODING_TOOLS_MCP_SERVER_URL)"
  status_state="$(config_value CODING_TOOLS_MCP_STATE_DIR)"
  status_workspace="$(config_value CODING_TOOLS_MCP_WORKSPACE)"
  status_auth="$(config_value CODING_TOOLS_MCP_AUTH_MODE)"
  status_permission="$(config_value CODING_TOOLS_MCP_PERMISSION_MODE)"
  database_state="不存在"
  if [[ -n "$status_state" && -f "$status_state/oauth.db" ]]; then
    database_state="可用"
  fi
  metadata_state="不可用"
  if [[ -n "$status_url" ]] && command -v curl >/dev/null 2>&1 \
    && curl -fsS --max-time 5 "$status_url/.well-known/oauth-authorization-server" \
      >/dev/null 2>&1; then
    metadata_state="可用"
  fi
  cat <<EOF
服务名称：    $SERVICE_NAME.service
当前状态：    $(state_zh "$service_state")
开机启动：    $(state_zh "$enabled_state")
监听地址：    ${status_host:-未知}:${status_port:-未知}
工作目录：    ${status_workspace:-未知}
认证模式：    ${status_auth:-未知}
权限模式：    ${status_permission:-未知}
公网网址：    ${status_url:-未知}
OAuth 数据库：${status_state:-未知}/oauth.db（$database_state）
OAuth 元数据：$metadata_state
EOF
}

confirm_purge() {
  local answer
  cat <<EOF
此操作将永久删除：
  $CONFIG_DIR
  OAuth client 注册信息、refresh token、管理密码和签名密钥

请输入【确认清除】继续：
EOF
  read -r answer
  [[ "$answer" == "确认清除" ]] || {
    echo "已取消永久清除。"
    return 1
  }
}

run_action() {
  case "$ACTION" in
    install|configure)
      run_install 1
      ;;
    update)
      update_program_and_scripts
      if [[ ! -f "$ENV_FILE" ]]; then
        echo "未找到持久安装，将进入首次配置。"
        run_install 1
      else
        run_install 0
      fi
      ;;
    start|stop|restart)
      systemctl "$ACTION" "$SERVICE_NAME.service"
      echo "服务当前状态：$(state_zh "$(systemctl is-active "$SERVICE_NAME.service" 2>/dev/null || true)")"
      ;;
    status)
      show_status
      ;;
    logs)
      echo "最近 100 行服务日志："
      journalctl -u "$SERVICE_NAME.service" -n 100 --no-pager
      ;;
    logs-follow)
      echo "正在持续显示服务日志，按 Ctrl-C 退出："
      journalctl -u "$SERVICE_NAME.service" -n 100 -f
      ;;
    uninstall)
      run_logged_command "卸载完成；OAuth 状态和配置已保留。" "$INSTALLER" --uninstall
      ;;
    purge)
      confirm_purge \
        && run_logged_command "永久清除完成。" "$INSTALLER" --uninstall --purge
      ;;
    *)
      die "未知操作：$ACTION"
      ;;
  esac
}

interactive_menu() {
  [[ -t 0 && -t 1 ]] || die "未提供命令且当前没有交互终端；请使用 --help 查看用法"
  while true; do
    cat <<'EOF'

Coding Tools MCP 服务器运维

  1) 安装 / 更新
  2) 启动服务
  3) 停止服务
  4) 重启服务
  5) 查看状态
  6) 查看最近日志
  7) 持续查看日志
  8) 修改配置
  9) 卸载（保留 OAuth 状态和配置）
 10) 永久清除（删除 OAuth 状态和配置）
  0) 退出
EOF
    local choice
    read -r -p "请选择 [0-10]：" choice
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
        read -r -p "确定卸载服务但保留 OAuth 状态和配置吗？[y/N/是/否] " choice
        if [[ "$choice" =~ ^[Yy]([Ee][Ss])?$ || "$choice" == "是" ]]; then
          ACTION="uninstall"
          run_action
        fi
        ;;
      10) ACTION="purge"; run_action || true ;;
      0) return ;;
      *) echo "无效选项，请重新输入。" >&2 ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|update|start|stop|restart|status|logs|logs-follow|configure|uninstall|purge)
      ACTION="$1"
      ;;
    --workspace)
      [[ $# -ge 2 ]] || die "--workspace 需要提供路径"
      WORKSPACE="$2"
      shift
      ;;
    --public-url)
      [[ $# -ge 2 ]] || die "--public-url 需要提供网址"
      PUBLIC_URL="$2"
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host 需要提供监听地址"
      HOST="$2"
      shift
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port 需要提供端口"
      PORT="$2"
      shift
      ;;
    --auth-mode)
      [[ $# -ge 2 ]] || die "--auth-mode 需要提供认证模式"
      AUTH_MODE="$2"
      shift
      ;;
    --permission-mode)
      [[ $# -ge 2 ]] || die "--permission-mode 需要提供权限模式"
      PERMISSION_MODE="$2"
      shift
      ;;
    --service-user)
      [[ $# -ge 2 ]] || die "--service-user 需要提供用户名"
      SERVICE_USER="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
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
