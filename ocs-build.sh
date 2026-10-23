#!/bin/bash
#
# ocs-build.sh — build a signed, notarized macOS .pkg of the OCS Inventory
# Agent (Dart rewrite).
#
#   1. fetch a Dart SDK (checksum-verified) or use the system one
#   2. fetch the OCSInventory-Agent-Rework source at a pinned ref
#   3. dart pub get + dart compile exe
#   4. codesign every Mach-O (Developer ID Application, hardened runtime)
#   5. pkgbuild/productbuild, signed with Developer ID Installer
#   6. notarize (notarytool), staple, validate
#
# Package design: setup/macos from the repository (install.sh, uninstall.sh,
# com.ocsinventory.agent.plist) is installed under
#   /usr/local/share/ocsinventory-agent/setup/macos/
# together with the signed binary, in the SAME folder. The package installs
# nothing into /usr/local/bin: install.sh does that single copy. URL, USERNAME,
# PASSWORD, SILENT (and optionally SERVICE, NOW) from ocs-build.conf are injected
# into the staged install.sh at build time, and the package's postinstall runs it.
#
# Targets macOS's stock /bin/bash 3.2 — keep it that way (no bash 4 features).
# Settings live in ocs-build.conf. See --help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/ocs-build.conf"
DO_NOTARIZE=1
CHECK_ONLY=0
CLEAN=0

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ocs-build.sh [options]

  --config FILE    Config file (default: ocs-build.conf next to this script)
  --check          Preflight only: tools, certificates, notary credentials.
                   Builds nothing.
  --no-notarize    Build and sign, skip notarization/stapling (testing only;
                   the result will not pass Gatekeeper as a downloaded file)
  --clean          Delete WORK_DIR before building
  -h, --help       This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || die "--config needs a path"; CONFIG_FILE="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --no-notarize) DO_NOTARIZE=0; shift ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

###############################################################################
# Config
###############################################################################
[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
perm="$(stat -f '%Lp' "$CONFIG_FILE" 2>/dev/null)" || die "Cannot stat $CONFIG_FILE (is this macOS?)"
if [ $(( 8#$perm & 8#022 )) -ne 0 ]; then
  die "$CONFIG_FILE is group/world-writable (mode $perm). It is executed as shell code; run: chmod 600 \"$CONFIG_FILE\""
fi
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${APP_SIGN_IDENTITY:=}" "${INSTALLER_SIGN_IDENTITY:=}" "${TEAM_ID:=}"
: "${APP_CERT_P12:=}" "${INSTALLER_CERT_P12:=}" "${P12_PASSWORD_ENV:=OCS_P12_PASSWORD}"
: "${SIGNING_KEYCHAIN:=}" "${SIGNING_KEYCHAIN_PASSWORD_ENV:=}"
: "${NOTARY_KEYCHAIN_PROFILE:=}" "${NOTARY_KEYCHAIN:=}"
: "${NOTARY_API_KEY_PATH:=}" "${NOTARY_API_KEY_ID:=}" "${NOTARY_API_ISSUER:=}"
: "${OCS_REPO_URL:=https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework.git}"
: "${OCS_REF:=main}"
: "${DART_SOURCE:=download}" "${DART_CHANNEL:=stable}" "${DART_VERSION:=latest}"
: "${DART_MIRROR_BASE:=https://storage.googleapis.com/dart-archive}"
: "${TARGET_ARCHS:=arm64}"
: "${BINARY_NAME:=ocsinventory-cli}" "${BINARY_CODESIGN_ID:=com.ocsinventory.agent.cli}"
: "${PKG_IDENTIFIER:=com.ocsinventory.agent}" "${PKG_TITLE:=OCS Inventory Agent}"
: "${PKG_VERSION:=auto}" "${ENTITLEMENTS_FILE:=}"
: "${URL:=}" "${USERNAME:=}" "${PASSWORD:=}" "${SILENT:=true}" "${SERVICE:=false}" "${NOW:=false}"
# The password may be supplied through the environment instead of the config file.
if [ -n "${OCS_PASSWORD:-}" ]; then PASSWORD="$OCS_PASSWORD"; fi
: "${WORK_DIR:=$HOME/ocs-build-work}" "${OUTPUT_DIR:=$HOME/ocs-build-out}"

###############################################################################
# Cleanup / temporary keychain handling
###############################################################################
TEMP_KC=""
ORIG_KCS=()
KC=""
KC_ARGS=()

cleanup() {
  local rc=$?
  if [ -n "$TEMP_KC" ]; then
    if [ ${#ORIG_KCS[@]} -gt 0 ]; then
      security list-keychains -d user -s "${ORIG_KCS[@]}" >/dev/null 2>&1 || true
    fi
    security delete-keychain "$TEMP_KC" >/dev/null 2>&1 || true
  fi
  exit $rc
}
trap cleanup EXIT

setup_keychain() {
  if [ -n "$APP_CERT_P12" ] || [ -n "$INSTALLER_CERT_P12" ]; then
    local p12pw="${!P12_PASSWORD_ENV:-}"
    [ -n "$p12pw" ] || die "Environment variable $P12_PASSWORD_ENV is empty or unset (needed to import .p12 files)."
    local kcpw
    kcpw="$(uuidgen)"
    TEMP_KC="$WORK_DIR/ocs-build.keychain-db"
    rm -f "$TEMP_KC"
    while IFS= read -r line; do
      ORIG_KCS+=("$line")
    done < <(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
    security create-keychain -p "$kcpw" "$TEMP_KC"
    security set-keychain-settings -lut 7200 "$TEMP_KC"
    security unlock-keychain -p "$kcpw" "$TEMP_KC"
    local p
    for p in "$APP_CERT_P12" "$INSTALLER_CERT_P12"; do
      [ -n "$p" ] || continue
      [ -f "$p" ] || die "Certificate file not found: $p"
      security import "$p" -k "$TEMP_KC" -P "$p12pw" \
        -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/pkgbuild -T /usr/bin/productsign >/dev/null \
        || die "Failed to import $p (wrong password, or file lacks the private key?)"
    done
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpw" "$TEMP_KC" >/dev/null
    security list-keychains -d user -s "$TEMP_KC" ${ORIG_KCS[@]+"${ORIG_KCS[@]}"}
    KC="$TEMP_KC"
  elif [ -n "$SIGNING_KEYCHAIN" ]; then
    [ -f "$SIGNING_KEYCHAIN" ] || die "SIGNING_KEYCHAIN not found: $SIGNING_KEYCHAIN"
    KC="$SIGNING_KEYCHAIN"
    if [ -n "$SIGNING_KEYCHAIN_PASSWORD_ENV" ]; then
      security unlock-keychain -p "${!SIGNING_KEYCHAIN_PASSWORD_ENV:-}" "$KC" \
        || die "Could not unlock $KC"
    fi
  fi
  if [ -n "$KC" ]; then KC_ARGS=(--keychain "$KC"); fi
}

###############################################################################
# Preflight
###############################################################################
have_identity() {
  # $1 = exact identity string
  security find-identity -v ${KC:+"$KC"} 2>/dev/null | grep -F "\"$1\"" >/dev/null
}

is_placeholder() {
  case "$1" in ""|*REPLACE_ME*) return 0 ;; *) return 1 ;; esac
}

notary_auth=()
build_notary_auth() {
  notary_auth=()
  if [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
    notary_auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    if [ -n "$NOTARY_KEYCHAIN" ]; then notary_auth+=(--keychain "$NOTARY_KEYCHAIN"); fi
  elif [ -n "$NOTARY_API_KEY_PATH" ]; then
    [ -f "$NOTARY_API_KEY_PATH" ] || die "NOTARY_API_KEY_PATH not found: $NOTARY_API_KEY_PATH"
    [ -n "$NOTARY_API_KEY_ID" ] || die "NOTARY_API_KEY_ID is required with an API key."
    notary_auth=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID")
    if [ -n "$NOTARY_API_ISSUER" ]; then notary_auth+=(--issuer "$NOTARY_API_ISSUER"); fi
  elif [ "$DO_NOTARIZE" -eq 1 ]; then
    die "No notary credentials: set NOTARY_KEYCHAIN_PROFILE or NOTARY_API_KEY_* in $CONFIG_FILE"
  fi
}

host_arch() { uname -m; }   # arm64 or x86_64

validate_setup_values() {
  case "$SILENT" in true|false) ;; *) die "SILENT must be true or false (got '$SILENT')." ;; esac
  case "$SERVICE" in true|false) ;; *) die "SERVICE must be true or false (got '$SERVICE')." ;; esac
  case "$NOW" in true|false) ;; *) die "NOW must be true or false (got '$NOW')." ;; esac

  if [ "$SILENT" != "true" ]; then
    info "SILENT=false: the package installs the files only; the postinstall does not run setup."
    return 0
  fi

  local v
  for v in "$URL" "$USERNAME" "$PASSWORD"; do
    if is_placeholder "$v"; then
      die "URL, USERNAME and PASSWORD must be set in $CONFIG_FILE (PASSWORD may come from \$OCS_PASSWORD) when SILENT=true."
    fi
  done
  case "$URL" in http://?*|https://?*) ;; *) die "URL must start with http:// or https:// (got '$URL')." ;; esac
  # install.sh writes these into config.json with a bare echo: a double quote or
  # backslash would corrupt the JSON and the agent would not start.
  case "$URL$USERNAME$PASSWORD" in
    *\"*|*\\*) die "URL, USERNAME and PASSWORD must not contain a double quote or backslash (install.sh does not escape them in config.json)." ;;
  esac
  case "$URL$USERNAME$PASSWORD" in
    *$'\n'*|*$'\r'*) die "URL, USERNAME and PASSWORD must not contain line breaks." ;;
  esac
  # --now makes install.sh run the agent with the values pasted UNQUOTED into a command
  # string (word splitting and globbing apply; older versions of the script used eval).
  if [ "$NOW" = "true" ]; then
    case "$URL$USERNAME$PASSWORD" in
      *[[:space:]]*|*'*'*|*'?'*|*'['*|*'$'*|*'`'*)
        die "With NOW=true, URL/USERNAME/PASSWORD must not contain whitespace or any of * ? [ \$ \` (install.sh passes them unquoted to a command)." ;;
    esac
  fi
  if [ "$SERVICE" != "true" ]; then
    warn "SERVICE=false: in silent mode install.sh then registers NO LaunchDaemon, so the agent is installed and configured but never scheduled. Set SERVICE=true in $CONFIG_FILE if the agent should run."
  fi
}

preflight() {
  log "Preflight"
  [ "$(uname -s)" = "Darwin" ] || die "This script must run on macOS."

  local t
  for t in curl unzip git shasum security codesign pkgbuild productbuild pkgutil xcrun lipo file uuidgen; do
    command -v "$t" >/dev/null 2>&1 || die "Required tool missing: $t (install Xcode Command Line Tools: xcode-select --install)"
  done
  xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode 13+ or matching Command Line Tools)."
  xcrun --find stapler >/dev/null 2>&1 || die "stapler not found (install Xcode Command Line Tools)."

  local a
  for a in $TARGET_ARCHS; do
    case "$a" in
      arm64)
        [ "$(host_arch)" = "arm64" ] || die "Cannot build arm64 on an Intel host." ;;
      x86_64)
        if [ "$(host_arch)" = "arm64" ]; then
          arch -x86_64 /usr/bin/true 2>/dev/null \
            || die "x86_64 build on Apple silicon needs Rosetta: softwareupdate --install-rosetta --agree-to-license"
        fi ;;
      *) die "Unsupported arch in TARGET_ARCHS: $a (use arm64 and/or x86_64)" ;;
    esac
  done

  for t in "$APP_SIGN_IDENTITY" "$INSTALLER_SIGN_IDENTITY"; do
    if is_placeholder "$t"; then die "Certificate identity still a placeholder in $CONFIG_FILE"; fi
  done
  if [ -n "$TEAM_ID" ] && ! is_placeholder "$TEAM_ID"; then
    case "$APP_SIGN_IDENTITY" in *"($TEAM_ID)"*) ;; *) warn "APP_SIGN_IDENTITY does not contain TEAM_ID ($TEAM_ID)" ;; esac
    case "$INSTALLER_SIGN_IDENTITY" in *"($TEAM_ID)"*) ;; *) warn "INSTALLER_SIGN_IDENTITY does not contain TEAM_ID ($TEAM_ID)" ;; esac
  fi

  validate_setup_values

  mkdir -p "$WORK_DIR"
  setup_keychain

  have_identity "$APP_SIGN_IDENTITY" \
    || die "Signing identity not found (cert + private key): $APP_SIGN_IDENTITY"
  have_identity "$INSTALLER_SIGN_IDENTITY" \
    || die "Signing identity not found (cert + private key): $INSTALLER_SIGN_IDENTITY"
  info "Found both signing identities."

  if [ -n "$ENTITLEMENTS_FILE" ]; then
    [ -f "$ENTITLEMENTS_FILE" ] || die "ENTITLEMENTS_FILE not found: $ENTITLEMENTS_FILE"
    plutil -lint "$ENTITLEMENTS_FILE" >/dev/null || die "Invalid entitlements plist: $ENTITLEMENTS_FILE"
  fi

  build_notary_auth
  if [ "$CHECK_ONLY" -eq 1 ] && [ "$DO_NOTARIZE" -eq 1 ]; then
    info "Validating notary credentials (network)..."
    xcrun notarytool history ${notary_auth[@]+"${notary_auth[@]}"} >/dev/null \
      || die "notarytool rejected the credentials."
    info "Notary credentials accepted."
  fi
}

###############################################################################
# Dart SDK
###############################################################################
DART_VERSION_RESOLVED=""
DART_BIN=""
RUN_PREFIX=()

resolve_dart_version() {
  if [ "$DART_VERSION" = "latest" ]; then
    local v
    v="$(curl -fsSL "$DART_MIRROR_BASE/channels/$DART_CHANNEL/release/latest/VERSION" \
        | tr -d '\n' | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')" \
      || die "Could not read latest Dart version from $DART_MIRROR_BASE"
    [ -n "$v" ] || die "Could not parse Dart version from mirror response."
    DART_VERSION_RESOLVED="$v"
  else
    DART_VERSION_RESOLVED="$DART_VERSION"
  fi
  info "Dart SDK version: $DART_VERSION_RESOLVED ($DART_CHANNEL)"
}

fetch_dart() {
  local arch="$1" darch dir dl base zip expected actual
  RUN_PREFIX=()
  if [ "$DART_SOURCE" = "system" ]; then
    [ "$arch" = "$(host_arch)" ] || die "DART_SOURCE=system only supports the host architecture."
    DART_BIN="$(command -v dart)" || die "No 'dart' on PATH."
    info "Using system Dart: $DART_BIN"
    return
  fi
  [ "$DART_SOURCE" = "download" ] || die "DART_SOURCE must be 'download' or 'system'."

  case "$arch" in arm64) darch=arm64 ;; x86_64) darch=x64 ;; esac
  if [ "$arch" = "x86_64" ] && [ "$(host_arch)" = "arm64" ]; then RUN_PREFIX=(arch -x86_64); fi

  dir="$WORK_DIR/dart-sdk/$DART_VERSION_RESOLVED-$arch"
  DART_BIN="$dir/dart-sdk/bin/dart"
  if [ -x "$DART_BIN" ]; then info "Dart SDK ($arch) cached."; return; fi

  dl="$WORK_DIR/downloads/$DART_VERSION_RESOLVED"
  base="$DART_MIRROR_BASE/channels/$DART_CHANNEL/release/$DART_VERSION_RESOLVED/sdk"
  zip="dartsdk-macos-$darch-release.zip"
  mkdir -p "$dl" "$dir"

  info "Downloading $zip"
  curl -fSL --retry 3 -o "$dl/$zip" "$base/$zip" || die "Download failed: $base/$zip"
  curl -fSL --retry 3 -o "$dl/$zip.sha256sum" "$base/$zip.sha256sum" \
    || die "Could not download checksum file; refusing to use an unverified SDK."
  expected="$(awk '{print $1}' "$dl/$zip.sha256sum" | head -n1)"
  actual="$(shasum -a 256 "$dl/$zip" | awk '{print $1}')"
  case "$expected" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) rm -rf "$dir"; die "Unexpected checksum file contents for $zip" ;;
  esac
  if [ "$expected" != "$actual" ]; then
    rm -rf "$dir" "$dl/$zip"
    die "SHA-256 mismatch for $zip (expected $expected, got $actual)"
  fi
  info "Checksum verified."
  unzip -q "$dl/$zip" -d "$dir"
  [ -x "$DART_BIN" ] || die "Dart binary not found after unzip: $DART_BIN"
}

run_dart() {
  PUB_CACHE="$WORK_DIR/pub-cache" \
    ${RUN_PREFIX[@]+"${RUN_PREFIX[@]}"} "$DART_BIN" "$@"
}

###############################################################################
# Source
###############################################################################
SRC_DIR=""
SRC_COMMIT=""

fetch_source() {
  SRC_DIR="$WORK_DIR/src/OCSInventory-Agent-Rework"
  log "Fetching OCS Inventory source ($OCS_REF)"
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  git -C "$SRC_DIR" init -q
  git -C "$SRC_DIR" remote add origin "$OCS_REPO_URL"
  # Works for branches, tags, and full commit SHAs.
  git -C "$SRC_DIR" fetch -q --depth 1 origin "$OCS_REF" \
    || die "git fetch failed for ref '$OCS_REF' from $OCS_REPO_URL"
  git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD
  SRC_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
  info "Checked out commit $SRC_COMMIT"
  [ -f "$SRC_DIR/lib/app/app.dart" ] || die "lib/app/app.dart not found in checkout."
  [ -d "$SRC_DIR/setup/macos" ] || die "setup/macos not found in this checkout; it must contain install.sh, uninstall.sh and the LaunchDaemon plist."
  if [ ! -f "$SRC_DIR/pubspec.lock" ]; then
    warn "No pubspec.lock in the repository: dependency versions float. The resolved lockfile will be saved with the build manifest."
  fi
}

###############################################################################
# Build / sign / package per architecture
###############################################################################
sign_file() {
  # $1 = file, $2 = identifier (optional), $3 = entitlements (optional)
  local f="$1" ident="${2:-}" ent="${3:-}"
  local args=(--force --timestamp --options runtime --sign "$APP_SIGN_IDENTITY")
  if [ -n "$ident" ]; then args+=(--identifier "$ident"); fi
  if [ -n "$ent" ]; then args+=(--entitlements "$ent"); fi
  codesign "${args[@]}" ${KC_ARGS[@]+"${KC_ARGS[@]}"} "$f"
  codesign --verify --strict --verbose=2 "$f"
  codesign -dvv "$f" 2>&1 | grep -E 'flags=.*runtime' >/dev/null \
    || die "Hardened runtime flag missing on $f"
  codesign -dvv "$f" 2>&1 | grep -E '^Timestamp=' >/dev/null \
    || die "Secure timestamp missing on $f"
}

resolve_pkg_version() {
  if [ "$PKG_VERSION" != "auto" ]; then PKG_VERSION_RESOLVED="$PKG_VERSION"; return; fi
  local v
  v="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$SRC_DIR/pubspec.yaml" | head -n1)"
  v="${v%%+*}"
  if [ -z "$v" ]; then v="$(date +%Y.%m.%d)"; warn "No version in pubspec.yaml; using build date $v"; fi
  PKG_VERSION_RESOLVED="$v"
}

PLIST_NAME="com.ocsinventory.agent.plist"

inject_setup_values() {
  # $1 = staged install.sh. Inserts the config values just before the
  # "Guards" section, i.e. after the defaults and command-line parsing, so
  # anything given on the command line still wins.
  local f="$1" marker='### ---------- Guards ----------' blk
  grep -qxF "$marker" "$f" \
    || die "install.sh has no '$marker' line, so setup values cannot be injected (did the script layout change?)."
  blk="### ---------- Values injected by ocs-build.sh (command-line options still win) ----------"$'\n'
  if [ "$SILENT" = "true" ]; then
    blk="${blk}SILENT=\"true\""$'\n'
    blk="${blk}$(printf 'if [[ -z "$URL" ]]; then URL=%q; fi' "$URL")"$'\n'
    blk="${blk}$(printf 'if [[ -z "$USERNAME" ]]; then USERNAME=%q; fi' "$USERNAME")"$'\n'
    blk="${blk}$(printf 'if [[ -z "$PASSWORD" ]]; then PASSWORD=%q; fi' "$PASSWORD")"$'\n'
    if [ "$SERVICE" = "true" ]; then blk="${blk}"'if [[ "$SERVICE" = "false" ]]; then SERVICE="true"; fi'$'\n'; fi
    if [ "$NOW" = "true" ]; then blk="${blk}"'if [[ "$NOW" = "false" ]]; then NOW="true"; fi'$'\n'; fi
  fi
  blk="${blk}### ---------- end injected values ----------"$'\n'
  # ENVIRON keeps backslashes and $ in the values verbatim (awk -v would not).
  BLK="$blk" MARKER="$marker" awk '
    $0 == ENVIRON["MARKER"] { printf "%s\n", ENVIRON["BLK"] }
    { print }' "$f" > "$f.new" || die "Injecting setup values failed."
  mv "$f.new" "$f"
  bash -n "$f" || die "install.sh no longer parses after injecting the setup values."
  grep -q 'Values injected by ocs-build.sh' "$f" || die "Injection marker missing after edit."
}

find_credential_files() {
  # Files under the given directories that contain the password, either raw or in the
  # shell-escaped (%q) form that inject_setup_values writes into install.sh.
  local pw_q
  pw_q="$(printf '%q' "$PASSWORD")"
  grep -rlF -e "$PASSWORD" -e "$pw_q" "$@" 2>/dev/null || true
}

check_install_sh_layout() {
  # Warn about a latent problem in install.sh: a reference to the local variable
  # $plist_source_file outside register_service(). With "set -u" that aborts
  # silent runs on a Mac that already has an agent.
  local f="$1" rs
  rs="$(grep -n '^register_service()' "$f" | head -n1 | cut -d: -f1)"
  if [ -n "$rs" ] && awk -v rs="$rs" 'NR < rs && /plist_source_file/ && $0 !~ /^[[:space:]]*#/ { found = 1 } END { exit !found }' "$f"; then
    warn "install.sh uses \$plist_source_file before register_service() defines it (see check_installed_agent). Under 'set -u' install.sh aborts at that line whenever its silent mode finds an existing agent, so re-installing over an existing agent fails until that line is fixed. Fresh installs are unaffected. The package's postinstall defers entirely to install.sh and only reports its exit status."
  fi
}

write_postinstall() {
  # Build-time flags are baked in with %q; the body is static and contains NO credentials
  # (the values live only in the staged install.sh).
  {
    echo '#!/bin/bash'
    printf 'RUN_SETUP=%q\n' "$SILENT"
    printf 'BINARY_NAME=%q\n' "$BINARY_NAME"
    printf 'PLIST_NAME=%q\n' "$PLIST_NAME"
    cat <<'EOF'
# Package postinstall (runs as root; installer passes $3 = target volume).
# 1. normalises ownership/permissions of the staged setup folder
# 2. runs install.sh (values were injected at build time) -> it copies the binary
#    from this folder to /usr/local/bin, writes config, optionally registers the service.
#    install.sh alone decides how to handle an existing agent (reinstall, removal of
#    old startup items/plist, ...); this script never uninstalls or blocks.
# 3. verifies the installed binary is the signed one from this package
umask 022
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SHARE="/usr/local/share/ocsinventory-agent"
SETUP="$SHARE/setup/macos"
BIN="/usr/local/bin/$BINARY_NAME"
CONFIG_DIR="/etc/ocsinventory-agent"
LOG_FILE="/var/log/ocsinventory-agent-pkg-install.log"
TARGET_VOL="${3:-/}"

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
log() { printf '%s [postinstall] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

# --- permissions ---------------------------------------------------------------------
chown -R root:wheel "$SHARE"
[ -f "$SETUP/uninstall.sh" ]     && chmod 0755 "$SETUP/uninstall.sh"
[ -f "$SETUP/$BINARY_NAME" ]     && chmod 0755 "$SETUP/$BINARY_NAME"
[ -f "$SETUP/$PLIST_NAME" ]      && chmod 0644 "$SETUP/$PLIST_NAME"
# install.sh may contain the server credentials: readable by root only.
[ -f "$SETUP/install.sh" ]       && chmod 0700 "$SETUP/install.sh"

# /usr/local/bin may not exist on a clean Apple silicon Mac; install.sh's
# "cp <binary> /usr/local/bin" would then create a FILE named "bin". Create the
# directory only if absent and never touch an existing one (Intel Homebrew may own it).
if [ ! -d /usr/local/bin ]; then
  mkdir -p /usr/local/bin && chown root:wheel /usr/local/bin && chmod 0755 /usr/local/bin
fi

if [ "$RUN_SETUP" != "true" ]; then
  log "Built with SILENT=false: files installed to $SETUP; setup not run."
  exit 0
fi
if [ "$TARGET_VOL" != "/" ]; then
  log "Target volume is '$TARGET_VOL', not '/': files installed, setup not run."
  exit 0
fi

# --- note (do not act on) an existing agent -----------------------------------------------------
# Purely diagnostic: install.sh owns install/reinstall/removal logic. This only records
# what was there before it ran, to make a failure easier to understand.
PRE_EXISTING=""
for m in "$BIN" "/Library/LaunchDaemons/$PLIST_NAME" "$CONFIG_DIR" /var/log/ocsinventory-agent.log; do
  [ -e "$m" ] && PRE_EXISTING="$PRE_EXISTING $m"
done
if [ -n "$PRE_EXISTING" ]; then
  log "Existing agent files found before setup:$PRE_EXISTING. install.sh decides how to handle it."
fi

# --- run install.sh ---------------------------------------------------------------------------
cd "$SETUP" || { log "ERROR: cannot cd to $SETUP"; exit 1; }
log "Running install.sh (non-interactive; stdin closed)."
./install.sh < /dev/null >> "$LOG_FILE" 2>&1
rc=$?
# install.sh's --now path writes the full agent command line, password included, to
# install.log. Keep the setup logs readable by root only.
for lf in "$SETUP/install.log" "$SETUP/uninstall.log"; do
  [ -f "$lf" ] && chmod 600 "$lf"
done

if [ "$rc" -ne 0 ]; then
  log "ERROR: install.sh exited with status $rc (see $SETUP/install.log and this log)."
  if [ -n "$PRE_EXISTING" ]; then
    log "It failed on a Mac that already had an agent; in that case install.sh runs uninstall.sh itself - see install.log and uninstall.log in $SETUP."
  fi
  exit "$rc"
fi

# config.json holds the server password in clear text.
if [ -f "$CONFIG_DIR/config.json" ]; then
  chown root:wheel "$CONFIG_DIR/config.json"
  chmod 600 "$CONFIG_DIR/config.json"
fi

# --- verify the single installed binary is the signed build from this package ------------------
if [ ! -x "$BIN" ]; then
  log "ERROR: install.sh finished but $BIN is missing."
  exit 1
fi
if ! cmp -s "$SETUP/$BINARY_NAME" "$BIN"; then
  log "ERROR: $BIN differs from the binary shipped in this package."
  exit 1
fi
if ! codesign --verify --strict "$BIN" >> "$LOG_FILE" 2>&1; then
  log "ERROR: codesign verification failed for $BIN."
  exit 1
fi
log "OK: $BIN installed once by install.sh and matches the signed package build."
exit 0
EOF
  } > "$1"
  chmod 0755 "$1"
}

build_arch() {
  local arch="$1"
  log "Building for $arch"
  fetch_dart "$arch"

  local out_bin="$WORK_DIR/build/$arch/$BINARY_NAME"
  mkdir -p "$WORK_DIR/build/$arch"
  ( cd "$SRC_DIR" && run_dart pub get && run_dart compile exe lib/app/app.dart -o "$out_bin" ) \
    || die "Dart build failed for $arch"
  [ "$(lipo -archs "$out_bin")" = "$arch" ] \
    || die "Built binary architecture is '$(lipo -archs "$out_bin")', expected '$arch'."
  cp "$SRC_DIR/pubspec.lock" "$WORK_DIR/build/$arch/pubspec.lock" 2>/dev/null || true

  # ---- stage payload -------------------------------------------------------
  local stage="$WORK_DIR/stage/$arch"
  local payload="$stage/payload"
  rm -rf "$stage"
  local share_dst="$payload/usr/local/share/ocsinventory-agent"
  local setup_dst="$share_dst/setup/macos"
  mkdir -p "$share_dst/setup" "$stage/scripts"

  # The macOS setup folder: install.sh, uninstall.sh, the plist ... and, below, the binary.
  [ -f "$SRC_DIR/setup/macos/install.sh" ] || die "setup/macos/install.sh not found in the source checkout."
  [ -f "$SRC_DIR/setup/macos/uninstall.sh" ] || warn "setup/macos/uninstall.sh not found in the source checkout."
  if [ ! -f "$SRC_DIR/setup/macos/$PLIST_NAME" ]; then
    if [ "$SERVICE" = "true" ]; then die "setup/macos/$PLIST_NAME not found, but SERVICE=true needs it beside install.sh."; fi
    warn "setup/macos/$PLIST_NAME not found in the source checkout."
  fi
  cp -R "$SRC_DIR/setup/macos" "$setup_dst"
  # Never ship a binary (or build leftovers) from the repository's folder.
  rm -f "$setup_dst/$BINARY_NAME" "$setup_dst/install.log" "$setup_dst/uninstall.log"
  find "$share_dst" -name '.DS_Store' -delete
  find "$share_dst" -type f -name '*.sh' -exec chmod 0755 {} +
  [ -f "$setup_dst/$PLIST_NAME" ] && chmod 0644 "$setup_dst/$PLIST_NAME"

  # Inject URL/USERNAME/PASSWORD/SILENT(/SERVICE/NOW) into the STAGED install.sh only.
  check_install_sh_layout "$setup_dst/install.sh"
  inject_setup_values "$setup_dst/install.sh"
  if [ "$SILENT" = "true" ]; then chmod 0700 "$setup_dst/install.sh"; fi

  # The binary lives in the same folder as install.sh; install.sh copies it to
  # /usr/local/bin. The package itself installs NOTHING into /usr/local/bin.
  install -m 0755 "$out_bin" "$setup_dst/$BINARY_NAME"
  find "$payload" -type d -exec chmod 0755 {} +
  write_postinstall "$stage/scripts/postinstall"

  # ---- sign every Mach-O in the payload, nested code first, main binary last
  log "Signing ($arch)"
  local main="$setup_dst/$BINARY_NAME" f
  while IFS= read -r f; do
    [ "$f" = "$main" ] && continue
    if file -b "$f" | grep -q 'Mach-O'; then
      info "nested Mach-O: ${f#"$payload"/}"
      sign_file "$f"
    fi
  done < <(find "$payload" -type f)
  sign_file "$main" "$BINARY_CODESIGN_ID" "$ENTITLEMENTS_FILE"

  # ---- payload sanity: single binary, nothing in /usr/local/bin, credentials only in install.sh
  [ ! -e "$payload/usr/local/bin" ] || die "Payload must not contain /usr/local/bin (install.sh installs the binary)."
  if [ "$SILENT" = "true" ]; then
    local leaks
    leaks="$(find_credential_files "$payload" "$stage/scripts")"
    if [ "$leaks" != "$setup_dst/install.sh" ]; then
      die "Credential placement check failed; files containing the password:"$'\n'"$leaks"
    fi
    info "Credentials appear only in the staged install.sh (mode $(stat -f '%Lp' "$setup_dst/install.sh"))."
  fi

  # ---- package -------------------------------------------------------------
  log "Packaging ($arch)"
  local hostarch="$arch"
  local comp="$stage/component.pkg"
  local dist="$stage/distribution.xml"
  local final="$stage/${PKG_IDENTIFIER##*.}-$PKG_VERSION_RESOLVED-$arch.pkg"

  pkgbuild --root "$payload" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$PKG_VERSION_RESOLVED" \
    --install-location / \
    --scripts "$stage/scripts" \
    --ownership recommended \
    "$comp"

  local listing count
  listing="$(pkgutil --payload-files "$comp" | grep -E "(^|/)${BINARY_NAME}\$" || true)"
  count="$(printf '%s\n' "$listing" | grep -c . || true)"
  if [ "$count" != "1" ]; then
    die "Expected '$BINARY_NAME' exactly once in the package payload, found $count:"$'\n'"$listing"
  fi
  case "$listing" in
    *"usr/local/share/ocsinventory-agent/setup/macos/$BINARY_NAME") ;;
    *) die "Binary is at an unexpected path in the payload: $listing" ;;
  esac
  if pkgutil --payload-files "$comp" | grep -qE '(^|/)usr/local/bin(/|$)'; then
    die "The payload contains an entry under /usr/local/bin; only install.sh may install there."
  fi
  info "Confirmed: '$BINARY_NAME' is in the payload once ($listing) and nothing is installed into /usr/local/bin by the package."

  cat > "$dist" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>$PKG_TITLE</title>
  <options customize="never" rootVolumeOnly="true" hostArchitectures="$hostarch"/>
  <choices-outline>
    <line choice="default">
      <line choice="$PKG_IDENTIFIER"/>
    </line>
  </choices-outline>
  <choice id="default"/>
  <choice id="$PKG_IDENTIFIER" visible="false">
    <pkg-ref id="$PKG_IDENTIFIER"/>
  </choice>
  <pkg-ref id="$PKG_IDENTIFIER" version="$PKG_VERSION_RESOLVED" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF
  xmllint --noout "$dist" 2>/dev/null || warn "xmllint unavailable or distribution.xml invalid; productbuild will report errors."

  productbuild --distribution "$dist" --package-path "$stage" \
    --sign "$INSTALLER_SIGN_IDENTITY" --timestamp \
    ${KC_ARGS[@]+"${KC_ARGS[@]}"} \
    "$final"
  pkgutil --check-signature "$final"

  # ---- notarize + staple -----------------------------------------------------
  if [ "$DO_NOTARIZE" -eq 1 ]; then
    log "Notarizing ($arch) — this uploads the .pkg to Apple"
    if [ "$SILENT" = "true" ]; then
      warn "This package contains the OCS URL/USERNAME/PASSWORD (in the staged install.sh) and is being uploaded to Apple for notarization. Use a dedicated low-privilege OCS account."
    fi
    local nlog="$stage/notary-submit.log"
    xcrun notarytool submit "$final" ${notary_auth[@]+"${notary_auth[@]}"} --wait 2>&1 | tee "$nlog"
    if ! grep -E '^[[:space:]]*status:[[:space:]]*Accepted' "$nlog" >/dev/null; then
      local sid
      sid="$(sed -n 's/^[[:space:]]*id:[[:space:]]*\([0-9a-fA-F-]\{36\}\).*/\1/p' "$nlog" | head -n1)"
      if [ -n "$sid" ]; then
        warn "Notarization was not accepted. Fetching Apple's log for $sid:"
        xcrun notarytool log "$sid" ${notary_auth[@]+"${notary_auth[@]}"} || true
      fi
      die "Notarization did not return Accepted for $arch."
    fi
    xcrun stapler staple "$final"
    xcrun stapler validate "$final"
    spctl --assess --type install -vv "$final" 2>&1 || warn "spctl assessment did not pass; inspect the output above."
  else
    warn "Skipping notarization (--no-notarize). Package is signed but NOT notarized."
  fi

  # ---- publish outputs ---------------------------------------------------------
  mkdir -p "$OUTPUT_DIR"
  cp "$final" "$OUTPUT_DIR/"
  local base="$OUTPUT_DIR/$(basename "$final")"
  {
    echo "package:        $(basename "$final")"
    echo "sha256:         $(shasum -a 256 "$final" | awk '{print $1}')"
    echo "pkg version:    $PKG_VERSION_RESOLVED"
    echo "architecture:   $arch"
    if [ "$SILENT" = "true" ]; then
      echo "setup values:   baked into install.sh (silent=true, url=$URL, username=$USERNAME, service=$SERVICE, now=$NOW; password NOT recorded here)"
    else
      echo "setup values:   none (SILENT=false; setup not run by the package)"
    fi
    echo "source repo:    $OCS_REPO_URL"
    echo "source ref:     $OCS_REF"
    echo "source commit:  $SRC_COMMIT"
    echo "dart sdk:       $DART_VERSION_RESOLVED ($DART_CHANNEL, source=$DART_SOURCE)"
    echo "notarized:      $([ "$DO_NOTARIZE" -eq 1 ] && echo yes || echo NO)"
    echo "built:          $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$base.manifest.txt"
  cp "$WORK_DIR/build/$arch/pubspec.lock" "$base.pubspec.lock" 2>/dev/null || true
  info "Output: $base"
}

###############################################################################
# Main
###############################################################################
if [ "$CLEAN" -eq 1 ]; then
  log "Cleaning $WORK_DIR"
  rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR"

preflight
if [ "$CHECK_ONLY" -eq 1 ]; then
  log "Preflight passed."
  exit 0
fi

log "Resolving toolchain"
if [ "$DART_SOURCE" = "download" ]; then resolve_dart_version; else DART_VERSION_RESOLVED="system"; fi
fetch_source
PKG_VERSION_RESOLVED=""
resolve_pkg_version

for a in $TARGET_ARCHS; do
  build_arch "$a"
done

log "Done. Artifacts in $OUTPUT_DIR"
