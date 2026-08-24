#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BUILD_ROOT="${CODING_TOOLS_MCP_BUILD_ROOT:-$REPO_ROOT/build/standalone}"
OUTPUT_DIR="${CODING_TOOLS_MCP_OUTPUT_DIR:-$REPO_ROOT/dist}"
PYTHON_BIN="${PYTHON:-}"
WITH_IMAGE=0
ACTION="menu"
BUILD_MARKER_NAME=".coding-tools-mcp-standalone-build"
OUTPUT_MARKER_NAME=".coding-tools-mcp-standalone-output"

usage() {
  cat <<'EOF'
用法：scripts/build-standalone.sh [命令] [选项]

构建可独立运行的 coding-tools-mcp 单文件程序和部署压缩包。
不带参数运行时会进入中文交互菜单。

命令：
  build                 构建可执行程序和部署压缩包
  verify                验证 dist/ 中现有的可执行程序
  clean                 清理本脚本生成的构建产物

选项：
  --with-image          打包 Pillow，启用可选图片工具
  --output-dir 路径     输出目录，默认为 ./dist
  --python 路径         构建所用的 Python 3.11+ 解释器
  -h, --help            显示本帮助

生成文件：
  dist/coding-tools-mcp
  dist/coding-tools-mcp-admin
  dist/install.sh
  dist/coding-tools-mcp-VERSION-OS-ARCH.tar.gz
  dist/SHA256SUMS
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

find_python() {
  if [[ -n "$PYTHON_BIN" ]]; then
    printf '%s\n' "$PYTHON_BIN"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    return 1
  fi
}

validate_output_paths() {
  case "$BUILD_ROOT" in
    ""|/) die "拒绝使用不安全的构建目录：$BUILD_ROOT" ;;
  esac
  case "$OUTPUT_DIR" in
    ""|/) die "拒绝使用不安全的输出目录：$OUTPUT_DIR" ;;
  esac
}

prepare_build_directory() {
  local marker="$BUILD_ROOT/$BUILD_MARKER_NAME"
  if [[ -d "$BUILD_ROOT" && ! -f "$marker" ]] \
    && [[ -n "$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "拒绝复用不属于本脚本的非空构建目录：$BUILD_ROOT"
  fi
  mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
  printf '%s\n' "coding-tools-mcp standalone build directory" >"$marker"
  printf '%s\n' "coding-tools-mcp standalone output directory" \
    >"$OUTPUT_DIR/$OUTPUT_MARKER_NAME"
}

project_version() {
  sed -n 's/^__version__ = "\([^"]*\)"/\1/p' "$REPO_ROOT/coding_tools_mcp/__init__.py" | head -n 1
}

platform_name() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
  esac
  printf '%s-%s\n' "$os" "$arch"
}

verify_binary() {
  local binary="$OUTPUT_DIR/coding-tools-mcp"
  [[ -x "$binary" ]] || die "未找到独立可执行程序：$binary"
  log "正在验证独立可执行程序"
  local version_output
  version_output="$("$binary" --version)"
  "$binary" --help >/dev/null
  echo "可执行程序验证成功：$binary（$version_output）"
}

write_checksums() {
  local checksum_file="$OUTPUT_DIR/SHA256SUMS"
  (
    cd "$OUTPUT_DIR"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum coding-tools-mcp coding-tools-mcp-admin install.sh ./*.tar.gz
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 coding-tools-mcp coding-tools-mcp-admin install.sh ./*.tar.gz
    else
      return 1
    fi
  ) >"$checksum_file" || {
    rm -f -- "$checksum_file"
    log "未找到 sha256sum 或 shasum，跳过生成 SHA256SUMS"
  }
}

build_standalone() {
  validate_output_paths
  local python version platform stage bundle_dir archive package_spec
  python="$(find_python)" || die "需要 Python 3.11 或更高版本"
  "$python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' \
    || die "需要 Python 3.11 或更高版本"
  version="$(project_version)"
  [[ -n "$version" ]] || die "无法读取项目版本"
  platform="$(platform_name)"

  log "正在准备隔离构建环境"
  prepare_build_directory
  if [[ ! -x "$BUILD_ROOT/venv/bin/python" ]]; then
    "$python" -m venv "$BUILD_ROOT/venv"
  fi
  "$BUILD_ROOT/venv/bin/python" -m pip install --quiet --upgrade pip pyinstaller
  package_spec="$REPO_ROOT"
  if [[ "$WITH_IMAGE" == "1" ]]; then
    package_spec="${REPO_ROOT}[image]"
  fi
  "$BUILD_ROOT/venv/bin/python" -m pip install --quiet --upgrade "$package_spec"

  stage="$BUILD_ROOT/stage"
  rm -rf -- "$stage" "$BUILD_ROOT/work" "$BUILD_ROOT/spec"
  mkdir -p "$stage" "$BUILD_ROOT/work" "$BUILD_ROOT/spec"

  log "正在构建单文件可执行程序"
  "$BUILD_ROOT/venv/bin/pyinstaller" \
    --noconfirm \
    --clean \
    --log-level WARN \
    --onefile \
    --name coding-tools-mcp \
    --distpath "$stage" \
    --workpath "$BUILD_ROOT/work" \
    --specpath "$BUILD_ROOT/spec" \
    "$SCRIPT_DIR/standalone_entry.py"

  install -m 0755 "$stage/coding-tools-mcp" "$OUTPUT_DIR/coding-tools-mcp"
  install -m 0755 "$REPO_ROOT/integrations/server/manage.sh" "$OUTPUT_DIR/coding-tools-mcp-admin"
  install -m 0755 "$REPO_ROOT/scripts/install.sh" "$OUTPUT_DIR/install.sh"
  verify_binary

  bundle_dir="$BUILD_ROOT/bundle/coding-tools-mcp-$version-$platform"
  rm -rf -- "$BUILD_ROOT/bundle"
  mkdir -p "$bundle_dir"
  install -m 0755 "$OUTPUT_DIR/coding-tools-mcp" "$bundle_dir/coding-tools-mcp"
  install -m 0755 "$OUTPUT_DIR/coding-tools-mcp-admin" "$bundle_dir/coding-tools-mcp-admin"
  install -m 0755 "$OUTPUT_DIR/install.sh" "$bundle_dir/install.sh"
  install -m 0644 "$REPO_ROOT/LICENSE" "$bundle_dir/LICENSE"
  archive="$OUTPUT_DIR/coding-tools-mcp-$version-$platform.tar.gz"
  rm -f -- "$archive"
  tar -C "$BUILD_ROOT/bundle" -czf "$archive" "$(basename "$bundle_dir")"
  write_checksums

  cat <<EOF

构建完成

可执行程序：
  $OUTPUT_DIR/coding-tools-mcp

交互式运维入口：
  sudo $OUTPUT_DIR/coding-tools-mcp-admin

部署压缩包：
  $archive
EOF
}

clean_build() {
  validate_output_paths
  if [[ -f "$BUILD_ROOT/$BUILD_MARKER_NAME" ]]; then
    rm -rf -- "$BUILD_ROOT"
  else
    log "跳过不属于本脚本的构建目录：$BUILD_ROOT"
  fi
  if [[ -f "$OUTPUT_DIR/$OUTPUT_MARKER_NAME" ]]; then
    rm -f -- \
      "$OUTPUT_DIR/coding-tools-mcp" \
      "$OUTPUT_DIR/coding-tools-mcp-admin" \
      "$OUTPUT_DIR/install.sh" \
      "$OUTPUT_DIR/SHA256SUMS" \
      "$OUTPUT_DIR/$OUTPUT_MARKER_NAME" \
      "$OUTPUT_DIR"/coding-tools-mcp-*.tar.gz
  else
    log "跳过不属于本脚本的输出目录：$OUTPUT_DIR"
  fi
  echo "独立构建产物已清理。"
}

interactive_menu() {
  [[ -t 0 && -t 1 ]] || die "未提供命令且当前没有交互终端；请使用 --help 查看用法"
  while true; do
    cat <<'EOF'

Coding Tools MCP 独立程序构建工具

  1) 构建可执行程序
  2) 构建可执行程序（包含图片支持）
  3) 验证现有可执行程序
  4) 清理构建产物
  0) 退出
EOF
    local choice
    read -r -p "请选择 [0-4]：" choice
    case "$choice" in
      1) WITH_IMAGE=0; build_standalone ;;
      2) WITH_IMAGE=1; build_standalone ;;
      3) verify_binary ;;
      4)
        read -r -p "确定清理独立构建产物吗？[y/N/是/否] " choice
        [[ "$choice" =~ ^[Yy]([Ee][Ss])?$ || "$choice" == "是" ]] && clean_build
        ;;
      0) return ;;
      *) echo "无效选项，请重新输入。" >&2 ;;
    esac
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    build|verify|clean)
      ACTION="$1"
      ;;
    --with-image)
      WITH_IMAGE=1
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir 需要提供路径"
      OUTPUT_DIR="$2"
      shift
      ;;
    --python)
      [[ $# -ge 2 ]] || die "--python 需要提供解释器路径"
      PYTHON_BIN="$2"
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

case "$ACTION" in
  menu) interactive_menu ;;
  build) build_standalone ;;
  verify) verify_binary ;;
  clean) clean_build ;;
  *) die "未知操作：$ACTION" ;;
esac
