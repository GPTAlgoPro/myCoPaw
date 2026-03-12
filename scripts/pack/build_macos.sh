#!/usr/bin/env bash
# One-click build: console -> conda-pack -> CoPaw.app. Run from repo root.
# Requires: conda, node/npm (for console). Optional: icon.icns in assets/.

set -e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PACK_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST:-dist}"
ARCHIVE="${DIST}/copaw-env.tar.gz"
APP_NAME="CoPaw"
APP_DIR="${DIST}/${APP_NAME}.app"

# --- progress helpers ---
STEP=0
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "▶ [Step ${STEP}] $*"
}
ok() { echo "  ✓ $*"; }
info() { echo "  · $*"; }

step "Pre-build: check dist/ output directory"
if [[ -d "${DIST}" ]] && [[ -n "$(ls -A "${DIST}" 2>/dev/null)" ]]; then
  info "dist/ is not empty — clearing to avoid stale artifacts"
  rm -rf "${DIST:?}"/*
  ok "dist/ cleared"
else
  info "dist/ is empty or does not exist, nothing to clean"
fi
mkdir -p "${DIST}"

step "Building wheel (includes console frontend)"
# Skip wheel_build if dist already has a wheel for current version
VERSION_FILE="${REPO_ROOT}/src/copaw/__version__.py"
CURRENT_VERSION=""
if [[ -f "${VERSION_FILE}" ]]; then
  CURRENT_VERSION="$(
    sed -n 's/^__version__[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      "${VERSION_FILE}" 2>/dev/null
  )"
fi
if [[ -n "${CURRENT_VERSION}" ]]; then
  shopt -s nullglob
  whls=("${REPO_ROOT}/dist/copaw-${CURRENT_VERSION}-"*.whl)
  if [[ ${#whls[@]} -gt 0 ]]; then
    ok "dist/ already has wheel for version ${CURRENT_VERSION}, skipping build"
  else
    info "No wheel found for ${CURRENT_VERSION}, building..."
    bash scripts/wheel_build.sh
    ok "Wheel built"
  fi
else
  info "Version unknown, building wheel unconditionally..."
  bash scripts/wheel_build.sh
  ok "Wheel built"
fi

step "Building conda-packed environment → ${ARCHIVE}"
python "${PACK_DIR}/build_common.py" --output "$ARCHIVE" --format tar.gz
ok "conda env packed: ${ARCHIVE}"

step "Assembling .app bundle → ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
ok "Bundle skeleton created"

info "Unpacking conda env into Resources/env (this may take a while)..."
mkdir -p "${APP_DIR}/Contents/Resources/env"
tar -xzf "$ARCHIVE" -C "${APP_DIR}/Contents/Resources/env" --strip-components=0
ok "conda env unpacked"

info "Running conda-unpack to fix embedded paths..."
if [[ -x "${APP_DIR}/Contents/Resources/env/bin/conda-unpack" ]]; then
  (cd "${APP_DIR}/Contents/Resources/env" && ./bin/conda-unpack)
  ok "conda-unpack completed"
else
  info "conda-unpack not found, skipping"
fi

# Launcher: force packed env; when no TTY log to ~/.copaw/desktop.log (no exec so we see errors)
cat > "${APP_DIR}/Contents/MacOS/${APP_NAME}" << 'LAUNCHER'
#!/usr/bin/env bash
ENV_DIR="$(cd "$(dirname "$0")/../Resources/env" && pwd)"
LOG="$HOME/.copaw/desktop.log"
unset PYTHONPATH
export PYTHONHOME="$ENV_DIR"
export COPAW_DESKTOP_APP=1

# Preserve system PATH for accessing system commands (e.g. imsg, brew)
# Prepend packaged env/bin so packaged Python takes precedence
export PATH="$ENV_DIR/bin:$PATH"

# Set SSL certificate paths for packaged environment
# Query certifi path from the packaged Python interpreter
if [ -x "$ENV_DIR/bin/python" ]; then
  CERT_FILE=$("$ENV_DIR/bin/python" -c \
    "import certifi; print(certifi.where())" 2>/dev/null)
  if [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ]; then
    export SSL_CERT_FILE="$CERT_FILE"
    export REQUESTS_CA_BUNDLE="$CERT_FILE"
    export CURL_CA_BUNDLE="$CERT_FILE"
  fi
fi

cd "$HOME" || true

# Log level: env var COPAW_LOG_LEVEL or default to "info"
LOG_LEVEL="${COPAW_LOG_LEVEL:-info}"

if [ ! -t 2 ]; then
  mkdir -p "$HOME/.copaw"
  { echo "=== $(date) CoPaw starting ==="
    echo "ENV_DIR=$ENV_DIR"
    echo "Python: $ENV_DIR/bin/python (exists=$([ -x "$ENV_DIR/bin/python" ] && echo yes || echo no))"
    echo "PATH=$PATH"
    echo "LOG_LEVEL=$LOG_LEVEL"
    echo "SSL_CERT_FILE=${SSL_CERT_FILE:-not set}"
    if [ -n "$SSL_CERT_FILE" ] && [ -f "$SSL_CERT_FILE" ]; then
      echo "SSL certificate file found at $SSL_CERT_FILE"
    elif [ -n "$SSL_CERT_FILE" ]; then
      echo "WARNING: SSL_CERT_FILE set but file does not exist: $SSL_CERT_FILE"
    else
      echo "WARNING: SSL_CERT_FILE not set, SSL connections may fail"
    fi
  } >> "$LOG"
  exec 2>> "$LOG"
  exec 1>> "$LOG"
  if [ ! -x "$ENV_DIR/bin/python" ]; then
    echo "ERROR: python not executable at $ENV_DIR/bin/python"
    exit 1
  fi
  if [ ! -f "$HOME/.copaw/config.json" ]; then
    "$ENV_DIR/bin/python" -u -m copaw init --defaults --accept-security
  fi
  echo "Launching python with log-level=$LOG_LEVEL..."
  "$ENV_DIR/bin/python" -u -m copaw desktop --log-level "$LOG_LEVEL"
  EXIT=$?
  if [ $EXIT -ge 128 ]; then
    SIG=$((EXIT - 128))
    echo "Exit code: $EXIT (killed by signal $SIG, e.g. 9=SIGKILL 15=SIGTERM)"
  else
    echo "Exit code: $EXIT"
  fi
  echo "--- Full log: $LOG (scroll up for Python traceback if app exited early) ---"
  exit $EXIT
fi
if [ ! -f "$HOME/.copaw/config.json" ]; then
  "$ENV_DIR/bin/python" -u -m copaw init --defaults --accept-security
fi
exec "$ENV_DIR/bin/python" -u -m copaw desktop --log-level "$LOG_LEVEL"
LAUNCHER
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
ok "Launcher script written and marked executable"

step "Configuring icon"
if [[ -f "${PACK_DIR}/assets/icon.icns" ]]; then
  ok "Using pre-generated icon.icns"
else
  echo "  ⚠ icon.icns not found at ${PACK_DIR}/assets/icon.icns"
  echo "    Generate it first: bash scripts/pack/generate_icons.sh"
fi

step "Writing Info.plist"
# Prioritize version from __version__.py to ensure accuracy
VERSION="${CURRENT_VERSION}"
if [[ -z "${VERSION}" ]]; then
  # Fallback: try to get version from packed env metadata
  VERSION="$("${APP_DIR}/Contents/Resources/env/bin/python" -c \
    "from importlib.metadata import version; print(version('copaw'))" 2>/dev/null \
    || echo "0.0.0")"
  info "Version from packed env metadata: ${VERSION}"
else
  info "Version from __version__.py: ${VERSION}"
fi
ICON_PLIST=""
if [[ -f "${PACK_DIR}/assets/icon.icns" ]]; then
  cp "${PACK_DIR}/assets/icon.icns" "${APP_DIR}/Contents/Resources/"
  ICON_PLIST="<key>CFBundleIconFile</key><string>icon.icns</string>
  "
fi
cat > "${APP_DIR}/Contents/Info.plist" << INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>com.copaw.desktop</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  ${ICON_PLIST}<key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSDesktopFolderUsageDescription</key><string>CoPaw may access files in your Desktop folder if you use file-related features. You can choose Don'\''t Allow; the app will still run with limited file access.</string>
</dict>
</plist>
INFOPLIST

ok "Info.plist written"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Build complete: ${APP_DIR}"
echo "  Version: ${VERSION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Optional: create zip for distribution (set CREATE_ZIP=1)
if [[ -n "${CREATE_ZIP}" ]]; then
  step "Creating distribution zip"
  ZIP_NAME="${DIST}/CoPaw-${VERSION}-macOS.zip"
  ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP_NAME}"
  ok "Created ${ZIP_NAME}"
fi
