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
Usage: scripts/build-standalone.sh [command] [options]

Build a self-contained coding-tools-mcp executable and a deployment bundle.
Running without a command opens an interactive menu.

Commands:
  build                 Build the executable and deployment archive.
  verify                Verify the existing executable in dist/.
  clean                 Remove this script's standalone build outputs.

Options:
  --with-image          Bundle Pillow and enable image tools.
  --output-dir PATH     Output directory. Default: ./dist
  --python PATH         Python 3.11+ interpreter used for the build.
  -h, --help            Show this help.

Outputs:
  dist/coding-tools-mcp
  dist/coding-tools-mcp-admin
  dist/install.sh
  dist/coding-tools-mcp-VERSION-OS-ARCH.tar.gz
  dist/SHA256SUMS
EOF
}

die() {
  echo "error: $*" >&2
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
    ""|/) die "refusing unsafe build directory: $BUILD_ROOT" ;;
  esac
  case "$OUTPUT_DIR" in
    ""|/) die "refusing unsafe output directory: $OUTPUT_DIR" ;;
  esac
}

prepare_build_directory() {
  local marker="$BUILD_ROOT/$BUILD_MARKER_NAME"
  if [[ -d "$BUILD_ROOT" && ! -f "$marker" ]] \
    && [[ -n "$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "refusing to reuse non-empty unowned build directory: $BUILD_ROOT"
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
  [[ -x "$binary" ]] || die "standalone executable not found: $binary"
  log "Verifying standalone executable"
  "$binary" --version
  "$binary" --help >/dev/null
  echo "Standalone executable is ready: $binary"
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
    log "sha256sum/shasum not found; skipping SHA256SUMS"
  }
}

build_standalone() {
  validate_output_paths
  local python version platform stage bundle_dir archive package_spec
  python="$(find_python)" || die "Python 3.11 or newer is required"
  "$python" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' \
    || die "Python 3.11 or newer is required"
  version="$(project_version)"
  [[ -n "$version" ]] || die "could not read project version"
  platform="$(platform_name)"

  log "Preparing isolated build environment"
  prepare_build_directory
  if [[ ! -x "$BUILD_ROOT/venv/bin/python" ]]; then
    "$python" -m venv "$BUILD_ROOT/venv"
  fi
  "$BUILD_ROOT/venv/bin/python" -m pip install --upgrade pip pyinstaller
  package_spec="$REPO_ROOT"
  if [[ "$WITH_IMAGE" == "1" ]]; then
    package_spec="${REPO_ROOT}[image]"
  fi
  "$BUILD_ROOT/venv/bin/python" -m pip install --upgrade "$package_spec"

  stage="$BUILD_ROOT/stage"
  rm -rf -- "$stage" "$BUILD_ROOT/work" "$BUILD_ROOT/spec"
  mkdir -p "$stage" "$BUILD_ROOT/work" "$BUILD_ROOT/spec"

  log "Building one-file executable"
  "$BUILD_ROOT/venv/bin/pyinstaller" \
    --noconfirm \
    --clean \
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

Build completed

Executable:
  $OUTPUT_DIR/coding-tools-mcp

Interactive operations:
  sudo $OUTPUT_DIR/coding-tools-mcp-admin

Deployment archive:
  $archive
EOF
}

clean_build() {
  validate_output_paths
  if [[ -f "$BUILD_ROOT/$BUILD_MARKER_NAME" ]]; then
    rm -rf -- "$BUILD_ROOT"
  else
    log "Skipping unowned build directory: $BUILD_ROOT"
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
    log "Skipping unowned output directory: $OUTPUT_DIR"
  fi
  echo "Standalone build outputs removed."
}

interactive_menu() {
  [[ -t 0 && -t 1 ]] || die "no command supplied and no interactive terminal is available; use --help"
  while true; do
    cat <<'EOF'

Coding Tools MCP standalone builder

  1) Build executable
  2) Build executable with image support
  3) Verify existing executable
  4) Clean build outputs
  0) Exit
EOF
    local choice
    read -r -p "Select [0-4]: " choice
    case "$choice" in
      1) WITH_IMAGE=0; build_standalone ;;
      2) WITH_IMAGE=1; build_standalone ;;
      3) verify_binary ;;
      4)
        read -r -p "Remove standalone build outputs? [y/N] " choice
        [[ "$choice" =~ ^[Yy]([Ee][Ss])?$ ]] && clean_build
        ;;
      0) return ;;
      *) echo "Invalid selection." >&2 ;;
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
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"
      shift
      ;;
    --python)
      [[ $# -ge 2 ]] || die "--python requires a value"
      PYTHON_BIN="$2"
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

case "$ACTION" in
  menu) interactive_menu ;;
  build) build_standalone ;;
  verify) verify_binary ;;
  clean) clean_build ;;
  *) die "unknown action: $ACTION" ;;
esac
