#!/usr/bin/env bash
# =============================================================================
# ocs-setup.sh - Deploy and operate the OCS Inventory 3.0 Docker stack
#
# Based on the official "Running OCS Inventory Server with Docker" guide
# (services: ocsinventory-backend / -proxy / -db / -frontend).
#
# NOTE: OCS Inventory 3.0 is currently a release candidate (testing only).
#
# Usage: sudo ./ocs-setup.sh <command> [args]     (run with no args for help)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${OCS_CONF:-$SCRIPT_DIR/ocs-setup.conf}"

# ----------------------------- defaults --------------------------------------
OCS_DIR="/opt/ocsinventory-server"
OCS_VERSION="3.0.0-rc1"
OCS_HOSTNAME=""                 # FQDN users/agents will use; empty = server's hostname
OCS_SCHEME="http"               # http | https (TLS itself is NOT set up by this script)
DB_NAME="ocsdb"
DB_USER="ocsuser"
DB_PASSWORD=""                  # empty = generate a random one on first deploy
HTTP_PORT=80                    # host port -> proxy:80   (backend API / agents)
HTTPS_PORT=443                  # host port -> proxy:443
FRONTEND_PORT=8080              # host port -> frontend:80 (web console)
BACKUP_DIR="/var/backups/ocsinventory"
BACKUP_RETENTION_DAYS=14
BACKUP_VOLUMES="true"           # also tar the frontend config/extensions volumes
MIN_DISK_GB=10
MIN_RAM_MB=2048
MANAGE_FIREWALL="true"          # open ports in ufw/firewalld if one is active

# --- TLS (used when OCS_SCHEME="https") ---
TLS_CERT_FILE=""                # host path: full-chain cert  (default: $OCS_DIR/certs/fullchain.pem)
TLS_KEY_FILE=""                 # host path: unencrypted key  (default: $OCS_DIR/certs/privkey.pem)
TLS_CA_FILE=""                  # host path: optional CA cert (default: $OCS_DIR/certs/ca.crt)
TLS_CERT_CTR="/etc/ssl/certs/ocs-server.crt"     # where each file appears INSIDE the proxy container
TLS_KEY_CTR="/etc/ssl/private/ocs-server.key"
TLS_CA_CTR="/etc/ssl/certs/ocs-ca.crt"
HTTP_MODE="redirect"            # redirect = port 80 -> HTTPS | serve = port 80 still serves the API
NGINX_MAX_BODY_SIZE=""          # e.g. 1G   (empty = nginx default of 1m)
NGINX_TIMEOUT_SECONDS=""        # e.g. 300  (empty = nginx default of 60s)

# --- Docker network ---
DOCKER_SUBNET=""                # e.g. 172.20.0.0/24. Empty = Docker picks one (can collide with your LAN!)
DOCKER_GATEWAY=""               # optional; must be inside DOCKER_SUBNET (empty = first address)
RESERVED_RANGES=""              # space-separated CIDRs in use on YOUR network, e.g. "172.16.0.0/16 172.17.0.0/16 172.18.0.0/16"
REPO_RAW_BASE="https://raw.githubusercontent.com/OCSInventory-NG/OCSInventory-Server-Packages/main/ocsinventory-server/docker"
LOG_FILE="/var/log/ocs-setup.log"

# Config file is plain bash and is sourced; only keep it root-writable.
# shellcheck disable=SC1090
[[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
: "${TLS_CERT_FILE:=$OCS_DIR/certs/fullchain.pem}"
: "${TLS_KEY_FILE:=$OCS_DIR/certs/privkey.pem}"
: "${TLS_CA_FILE:=$OCS_DIR/certs/ca.crt}"

PROJECT_NAME="ocsinventory"
SECRETS_FILE="$OCS_DIR/.ocs-secrets"
VERSION_FILE="$OCS_DIR/.ocs-version"
OVERRIDE_FILE="$OCS_DIR/docker-compose.override.yml"
TLS_CONF_FILE="$OCS_DIR/files/nginx/ocsinventory-tls.generated.conf"
TLS_CA_USE=0

# ----------------------------- helpers ---------------------------------------
_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
log()  { printf '%s [INFO ] %s\n'  "$(date '+%F %T')" "$*"; }
warn() { printf '%s %s[WARN ]%s %s\n' "$(date '+%F %T')" "$(_c 33)" "$(_c 0)" "$*" >&2; }
ok()   { printf '%s %s[ OK  ]%s %s\n' "$(date '+%F %T')" "$(_c 32)" "$(_c 0)" "$*"; }
die()  { printf '%s %s[ERROR]%s %s\n' "$(date '+%F %T')" "$(_c 31)" "$(_c 0)" "$*" >&2; exit 1; }
trap 'rc=$?; if [[ $BASHPID -eq $$ ]]; then die "Failed at line $LINENO (exit $rc). See $LOG_FILE"; fi' ERR

need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
have() { command -v "$1" >/dev/null 2>&1; }
dc() { ( cd "$OCS_DIR" && docker compose "$@" ); }
confirm() { # confirm "question"  (skipped when ASSUME_YES=1)
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]
}
version_ge() { # version_ge A B  -> true if A >= B
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}
yaml_escape() { # safe inside a double-quoted YAML scalar, and escape $ for compose
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\$/\$\$}"; printf '%s' "$s"
}
gen_secret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
port_in_use() { [[ -n "$(ss -H -ltn "sport = :$1" 2>/dev/null)" ]]; }
stack_exists() { [[ -f "$OCS_DIR/docker-compose.yml" ]] && have docker && [[ -n "$(dc ps -q 2>/dev/null || true)" ]]; }
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || true; }
local_code() { curl -sk -o /dev/null -m 5 -w '%{http_code}' "$1" 2>/dev/null || true; }  # -k: local checks only
api_url() { # URL the BROWSER uses for the API / agents
  local p
  if [[ "$OCS_SCHEME" == "https" ]]; then p="$HTTPS_PORT"; [[ "$p" == "443" ]] && p="" || p=":$p"
  else p="$HTTP_PORT"; [[ "$p" == "80" ]] && p="" || p=":$p"; fi
  printf '%s://%s%s/' "$OCS_SCHEME" "$(effective_host)" "$p"
}
console_url() { printf '%s://%s:%s' "$OCS_SCHEME" "$(effective_host)" "$FRONTEND_PORT"; }

# ---- IPv4 / CIDR helpers (pure bash) ----
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (10#$a<<24) + (10#$b<<16) + (10#$c<<8) + 10#$d )); }
cidr_valid() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1:4}"; do (( 10#$o <= 255 )) || return 1; done
}
cidr_range() { # "start end" as integers
  local ip="${1%/*}" bits="${1#*/}" s m
  s="$(ip2int "$ip")"; m=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  echo "$(( s & m )) $(( (s & m) | (~m & 0xFFFFFFFF) ))"
}
cidr_overlap() { local s1 e1 s2 e2; read -r s1 e1 <<<"$(cidr_range "$1")"; read -r s2 e2 <<<"$(cidr_range "$2")"; (( s1 <= e2 && s2 <= e1 )); }

own_bridge() { # name of the Linux bridge of OUR compose network (so we never conflict with ourselves)
  have docker || return 0
  local nid; nid="$(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" 2>/dev/null | head -n1 || true)"
  [[ -n "$nid" ]] && printf 'br-%s' "${nid:0:12}"
  return 0
}
existing_subnets() { # lines: "<cidr><TAB><description>"  (RESERVED_RANGES + host routes, excluding our own bridge)
  local r; for r in $RESERVED_RANGES; do printf '%s\treserved in config (RESERVED_RANGES)\n' "$r"; done
  have ip || return 0
  local own cidr rest; own="$(own_bridge)"
  ip -4 route show 2>/dev/null | while read -r cidr rest; do
    [[ "$cidr" == */* ]] || continue
    [[ -n "$own" && "$rest" == *"dev $own"* ]] && continue
    printf '%s\t%s\n' "$cidr" "route: $cidr $rest"
  done
}
subnet_conflicts() { # print conflicting entries; return 0 if there ARE conflicts
  local found=1 cidr desc
  while IFS=$'\t' read -r cidr desc; do
    [[ -n "$cidr" ]] && cidr_valid "$cidr" || continue
    if cidr_overlap "$1" "$cidr"; then printf '    %s\n' "$desc"; found=0; fi
  done < <(existing_subnets)
  return "$found"
}
effective_host() { printf '%s' "${OCS_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"; }

detect_os() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_VERSION="${VERSION_ID:-?}"
  case "$OS_ID" in
    ubuntu|debian) OS_FAMILY="debian"; OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
    rhel|rocky|almalinux|centos) OS_FAMILY="rhel" ;;
    *) OS_FAMILY="unsupported" ;;
  esac
}

# ----------------------------- preflight -------------------------------------
cmd_preflight() {
  need_root
  local fail=0
  log "Running preflight checks..."
  detect_os
  if [[ "$OS_FAMILY" == "unsupported" ]]; then
    warn "OS '$OS_ID' not supported by install-docker (supported: ubuntu, debian, rhel, rocky, almalinux, centos)."
    warn "If Docker + Compose plugin are already installed you can continue."
  else ok "OS: $OS_ID $OS_VERSION ($OS_FAMILY family)"; fi

  [[ "$(uname -m)" == "x86_64" ]] || warn "Architecture $(uname -m): verify the OCS images publish this platform."

  for c in curl ss awk df; do have "$c" || { warn "Missing command: $c"; fail=1; }; done

  local ram_mb disk_gb
  ram_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
  (( ram_mb >= MIN_RAM_MB )) && ok "RAM: ${ram_mb} MB" || { warn "RAM ${ram_mb} MB < ${MIN_RAM_MB} MB"; fail=1; }
  local probe="$OCS_DIR"; [[ -d "$probe" ]] || probe="$(dirname "$OCS_DIR")"
  disk_gb=$(df -BG --output=avail "$probe" | tail -n1 | tr -dc '0-9')
  (( disk_gb >= MIN_DISK_GB )) && ok "Free disk at $probe: ${disk_gb} GB" || { warn "Disk ${disk_gb} GB < ${MIN_DISK_GB} GB"; fail=1; }

  if have ss; then
    for p in "$HTTP_PORT" "$HTTPS_PORT" "$FRONTEND_PORT"; do
      if port_in_use "$p"; then
        if stack_exists; then log "Port $p in use (assumed to be the running OCS stack)."
        else warn "Port $p is already in use by another process."; fail=1; fi
      else ok "Port $p is free"; fi
    done
  fi

  if [[ -n "$DOCKER_SUBNET" ]]; then
    if ! cidr_valid "$DOCKER_SUBNET"; then warn "DOCKER_SUBNET '$DOCKER_SUBNET' is not valid CIDR (e.g. 172.20.0.0/24)."; fail=1
    elif subnet_conflicts "$DOCKER_SUBNET" >/tmp/.ocs-conf.$$; then
      warn "DOCKER_SUBNET $DOCKER_SUBNET overlaps existing routes on this host:"; cat /tmp/.ocs-conf.$$ >&2; fail=1
    else ok "Docker subnet $DOCKER_SUBNET does not overlap any host route"; fi
    rm -f /tmp/.ocs-conf.$$
  else
    warn "DOCKER_SUBNET not set: Docker will auto-pick a range (172.x / 192.168.x) that may collide with your LAN. Set one in the config."
    [[ -n "$RESERVED_RANGES" ]] || warn "RESERVED_RANGES is empty: collision checks only see this host's routing table, not LAN ranges behind the gateway."
  fi

  if [[ "$OCS_SCHEME" == "https" ]]; then
    install -d -m 700 "$OCS_DIR/certs"
    log "TLS enabled. Expecting cert=$TLS_CERT_FILE key=$TLS_KEY_FILE ca=$TLS_CA_FILE"
    tls_validate || warn "TLS files not ready yet. Place them (see README), then re-run; 'configure' will not continue until they validate."
  fi

  if [[ -n "$OCS_HOSTNAME" ]]; then
    getent hosts "$OCS_HOSTNAME" >/dev/null && ok "DNS resolves $OCS_HOSTNAME" \
      || warn "OCS_HOSTNAME '$OCS_HOSTNAME' does not resolve from this host."
  else warn "OCS_HOSTNAME not set; will use '$(effective_host)'. Set it to the name agents/users will use."; fi

  if have curl; then
    [[ "$(http_code "$REPO_RAW_BASE/$OCS_VERSION/docker-compose.yml")" == "200" ]] \
      && ok "Can download compose file for version $OCS_VERSION" \
      || { warn "Cannot download compose file for $OCS_VERSION (network/proxy or wrong version)."; fail=1; }
    local rc; rc="$(http_code https://registry-1.docker.io/v2/)"
    [[ "$rc" == "401" || "$rc" == "200" ]] && ok "Docker Hub reachable" \
      || warn "Docker Hub not reachable (HTTP $rc); image pulls will fail unless you use a mirror."
  fi

  (( fail == 0 )) || die "Preflight failed. Fix the issues above and re-run."
  ok "Preflight passed."
}

# ----------------------------- docker install --------------------------------
cmd_install_docker() {
  need_root; detect_os
  if have docker && docker compose version >/dev/null 2>&1; then
    ok "Docker and Compose plugin already installed ($(docker compose version --short))."
  else
    log "Installing Docker Engine from Docker's official repository..."
    case "$OS_FAMILY" in
      debian)
        apt-get update -y
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
          > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
      rhel)
        local repo="centos"; [[ "$OS_ID" == "rhel" ]] && repo="rhel"
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo "https://download.docker.com/linux/${repo}/docker-ce.repo"
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
      *) die "Unsupported OS for automatic Docker install. Install Docker 20.10+ and the compose plugin manually." ;;
    esac
    systemctl enable --now docker
  fi
  systemctl is-active --quiet docker || die "Docker service is not running."
  ok "Docker ready: $(docker --version) / compose $(docker compose version --short)"
}

# ----------------------------- firewall --------------------------------------
cmd_firewall() {
  need_root
  [[ "$MANAGE_FIREWALL" == "true" ]] || { log "MANAGE_FIREWALL=false, skipping."; return 0; }
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "$HTTP_PORT" "$HTTPS_PORT" "$FRONTEND_PORT"; do ufw allow "${p}/tcp" >/dev/null; done
    ok "ufw: opened $HTTP_PORT, $HTTPS_PORT, $FRONTEND_PORT/tcp"
  elif have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    for p in "$HTTP_PORT" "$HTTPS_PORT" "$FRONTEND_PORT"; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null; done
    firewall-cmd --reload >/dev/null
    ok "firewalld: opened $HTTP_PORT, $HTTPS_PORT, $FRONTEND_PORT/tcp"
  else
    log "No active ufw/firewalld detected; not touching firewall."
  fi
  warn "Docker-published ports bypass ufw rules by default; restrict access upstream (network firewall) if needed."
}

# ----------------------------- fetch -----------------------------------------
download_official() { # download_official <version> <dest_dir>
  local ver="$1" dest="$2" base
  base="$REPO_RAW_BASE/$ver"
  mkdir -p "$dest/files/nginx"
  curl -fsSL "$base/docker-compose.yml" -o "$dest/docker-compose.yml" \
    || die "Could not download $base/docker-compose.yml (is '$ver' a valid version?)"
  curl -fsSL "$base/files/nginx/ocsinventory-backend.conf" -o "$dest/files/nginx/ocsinventory-backend.conf" \
    || die "Could not download nginx config for $ver"
  grep -q 'ocsinventory-backend' "$dest/docker-compose.yml" \
    || die "Downloaded compose file does not look right (no ocsinventory-backend service)."
}

cmd_fetch() {
  need_root
  mkdir -p "$OCS_DIR"; chmod 750 "$OCS_DIR"
  install -d -m 700 "$OCS_DIR/certs"
  local tmp; tmp="$(mktemp -d)"
  log "Downloading official stack files for $OCS_VERSION..."
  download_official "$OCS_VERSION" "$tmp"
  if [[ -f "$OCS_DIR/docker-compose.yml" ]] && ! cmp -s "$tmp/docker-compose.yml" "$OCS_DIR/docker-compose.yml"; then
    cp -a "$OCS_DIR/docker-compose.yml" "$OCS_DIR/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    warn "Existing compose file differed; previous copy saved as .bak"
  fi
  mkdir -p "$OCS_DIR/files/nginx"
  cp -f "$tmp/docker-compose.yml" "$OCS_DIR/docker-compose.yml"
  cp -f "$tmp/files/nginx/ocsinventory-backend.conf" "$OCS_DIR/files/nginx/ocsinventory-backend.conf"
  rm -rf "$tmp"
  echo "$OCS_VERSION" > "$VERSION_FILE"
  ok "Stack files installed in $OCS_DIR"
}

# ----------------------------- TLS -------------------------------------------
tls_validate() { # 0 = cert/key look usable for the server hostname; sets TLS_CA_USE
  local bad=0 host f c k perm
  host="$(effective_host)"; TLS_CA_USE=0
  have openssl || { warn "openssl not installed; cannot validate certificates."; return 1; }
  for f in "$TLS_CERT_FILE" "$TLS_KEY_FILE"; do
    [[ -r "$f" ]] || { warn "Missing or unreadable: $f"; bad=1; }
  done
  (( bad == 0 )) || return 1
  openssl x509 -in "$TLS_CERT_FILE" -noout >/dev/null 2>&1 || { warn "Not a valid PEM certificate: $TLS_CERT_FILE"; return 1; }

  c="$(openssl x509 -in "$TLS_CERT_FILE" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null || true)"
  k="$(openssl pkey -in "$TLS_KEY_FILE" -passin pass: -pubout 2>/dev/null | openssl sha256 2>/dev/null || true)"
  if [[ -n "$c" && "$c" == "$k" ]]; then ok "Private key matches certificate"
  else warn "Private key does not match the certificate, or is passphrase-protected (nginx needs an unencrypted key)."; bad=1; fi

  if ! openssl x509 -in "$TLS_CERT_FILE" -noout -checkend 0 >/dev/null 2>&1; then
    warn "Certificate has EXPIRED ($(openssl x509 -in "$TLS_CERT_FILE" -noout -enddate))"; bad=1
  elif ! openssl x509 -in "$TLS_CERT_FILE" -noout -checkend $((30*86400)) >/dev/null 2>&1; then
    warn "Certificate expires within 30 days ($(openssl x509 -in "$TLS_CERT_FILE" -noout -enddate))"
  else ok "Certificate not expired ($(openssl x509 -in "$TLS_CERT_FILE" -noout -enddate))"; fi

  if openssl x509 -in "$TLS_CERT_FILE" -noout -checkhost "$host" 2>/dev/null | grep -q 'does match'; then
    ok "Certificate covers hostname $host"
  else
    warn "Certificate does NOT cover '$host'. Set OCS_HOSTNAME to a name the certificate covers (e.g. ocs.<your-wildcard-domain>)."; bad=1
  fi

  [[ "$(grep -c 'BEGIN CERTIFICATE' "$TLS_CERT_FILE" || true)" -ge 2 ]] \
    || warn "$TLS_CERT_FILE holds a single certificate; use the FULL chain (leaf + intermediates) or some agents may reject it."

  perm="$(stat -c %a "$TLS_KEY_FILE" 2>/dev/null || true)"
  [[ -z "$perm" || "${perm: -1}" == "0" ]] || warn "Private key is readable by other users (mode $perm). Run: chmod 600 $TLS_KEY_FILE"

  if [[ -n "$TLS_CA_FILE" && -r "$TLS_CA_FILE" ]] && openssl x509 -in "$TLS_CA_FILE" -noout >/dev/null 2>&1; then
    TLS_CA_USE=1; ok "CA file found: $TLS_CA_FILE"
  elif [[ -n "$TLS_CA_FILE" ]]; then
    warn "CA file missing or invalid ($TLS_CA_FILE); continuing without it (the full chain should already include intermediates)."
  fi
  return "$bad"
}

cmd_tlscheck() {
  need_root
  if tls_validate; then ok "TLS files look good."; else die "TLS problems found (see warnings above)."; fi
}

cmd_selfsigned() { # TEST ONLY: self-signed cert so the https path can be exercised before real certs exist
  need_root; have openssl || die "openssl is required."
  local host; host="$(effective_host)"
  if [[ -e "$TLS_CERT_FILE" || -e "$TLS_KEY_FILE" ]]; then die "Refusing to overwrite existing $TLS_CERT_FILE / $TLS_KEY_FILE"; fi
  install -d -m 700 "$(dirname "$TLS_CERT_FILE")" "$(dirname "$TLS_KEY_FILE")"
  ( umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 90 -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" \
      -subj "/CN=$host" -addext "subjectAltName=DNS:$host" >/dev/null 2>&1 )
  chmod 600 "$TLS_KEY_FILE"
  warn "Generated a SELF-SIGNED certificate for $host (90 days). For testing only: browsers and agents will not trust it."
}

nginx_ssl_lines() {
  echo "    ssl_certificate     $TLS_CERT_CTR;"
  echo "    ssl_certificate_key $TLS_KEY_CTR;"
  if (( TLS_CA_USE )); then echo "    ssl_trusted_certificate $TLS_CA_CTR;"; fi
  echo "    ssl_protocols TLSv1.2 TLSv1.3;"
  echo "    ssl_session_cache shared:SSL:10m;"
  echo "    ssl_session_timeout 1d;"
  echo "    ssl_session_tickets off;"
}

# Derive the TLS nginx config from the OFFICIAL one so upstream changes (new locations, etc.)
# carry over on upgrade. Refuses to guess if the official layout changed.
gen_nginx_tls_conf() {
  local off="$OCS_DIR/files/nginx/ocsinventory-backend.conf" body host hp extra="" tmp
  [[ -f "$off" ]] || die "Official nginx config missing ($off); run 'fetch'."
  if ! { [[ "$(grep -cE '^server[[:space:]]*\{' "$off" || true)" == "1" ]] \
         && grep -qE '^[[:space:]]*listen[[:space:]]+80[[:space:]]*;' "$off" \
         && grep -q 'uwsgi_pass' "$off"; }; then
    die "Official nginx config has an unexpected layout (expected one 'server' block on port 80 using uwsgi_pass). Not generating TLS config automatically; review $off."
  fi
  body="$(awk '/^server[[:space:]]*\{/ && !s {s=1; next} s {l[++n]=$0; if ($0 ~ /^\}/) last=n} END {for(i=1;i<last;i++) print l[i]}' "$off" \
          | grep -vE '^[[:space:]]*(listen|server_name)[[:space:]]' || true)"
  [[ -n "$body" ]] || die "Could not parse the official nginx config."

  host="$(effective_host)"; hp=""; [[ "$HTTPS_PORT" == "443" ]] || hp=":$HTTPS_PORT"
  if [[ -n "$NGINX_MAX_BODY_SIZE" ]]; then
    [[ "$NGINX_MAX_BODY_SIZE" =~ ^[0-9]+[kKmMgG]?$ ]] || die "NGINX_MAX_BODY_SIZE must look like 100m or 1G."
    extra+="    client_max_body_size ${NGINX_MAX_BODY_SIZE};"$'\n'
  fi
  if [[ -n "$NGINX_TIMEOUT_SECONDS" ]]; then
    [[ "$NGINX_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "NGINX_TIMEOUT_SECONDS must be a number."
    extra+="    uwsgi_connect_timeout ${NGINX_TIMEOUT_SECONDS}s;"$'\n'
    extra+="    uwsgi_send_timeout ${NGINX_TIMEOUT_SECONDS}s;"$'\n'
    extra+="    uwsgi_read_timeout ${NGINX_TIMEOUT_SECONDS}s;"$'\n'
  fi

  tmp="$(mktemp)"
  {
    echo "# GENERATED by ocs-setup.sh from the official nginx config. Do not edit; re-run 'configure'."
    echo "# --- HTTP (port 80), mode: $HTTP_MODE ---"
    echo "server {"
    echo "    listen 80;"
    echo "    server_name _;"
    if [[ "$HTTP_MODE" == "redirect" ]]; then
      echo "    server_tokens off;"
      echo "    location / { return 301 https://${host}${hp}\$request_uri; }"
    else
      printf '%s\n' "$body"
    fi
    echo "}"
    echo
    echo "# --- HTTPS API / agent endpoint (port 443) ---"
    echo "server {"
    echo "    listen 443 ssl;"
    echo "    server_name _;"
    nginx_ssl_lines
    printf '%s' "$extra"
    printf '%s\n' "$body"
    echo "}"
    echo
    echo "# --- HTTPS web console (container port 8080 -> published as FRONTEND_PORT) ---"
    echo "server {"
    echo "    listen 8080 ssl;"
    echo "    server_name _;"
    echo "    server_tokens off;"
    nginx_ssl_lines
    echo "    resolver 127.0.0.11 valid=10s ipv6=off;   # Docker DNS; lets nginx start before the frontend is up"
    echo "    location / {"
    echo "        set \$ocs_frontend http://ocsinventory-frontend:80;"
    echo "        proxy_pass \$ocs_frontend;"
    echo "        proxy_set_header Host \$host;"
    echo "        proxy_set_header X-Real-IP \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "    }"
    echo "}"
  } > "$tmp"
  install -m 644 "$tmp" "$TLS_CONF_FILE"; rm -f "$tmp"
  ok "Generated $TLS_CONF_FILE"
}

nginx_selftest() { # run `nginx -t` in the real proxy image with the real merged mounts
  log "Testing generated nginx config inside the proxy image..."
  if ! dc pull ocsinventory-proxy >/dev/null 2>&1; then
    warn "Could not pull the proxy image; skipping nginx -t self-test."; return 0
  fi
  local out
  if out="$(dc run --rm --no-deps -T ocsinventory-proxy nginx -t 2>&1)"; then ok "nginx -t passed"
  else printf '%s\n' "$out" >&2; die "nginx rejected the generated configuration (output above)."; fi
}

# ----------------------------- configure -------------------------------------
cmd_configure() {
  need_root
  [[ -f "$OCS_DIR/docker-compose.yml" ]] || die "Run 'fetch' first."
  [[ "$OCS_SCHEME" == "http" || "$OCS_SCHEME" == "https" ]] || die "OCS_SCHEME must be 'http' or 'https'."
  [[ "$HTTP_MODE" == "redirect" || "$HTTP_MODE" == "serve" ]] || die "HTTP_MODE must be 'redirect' or 'serve'."
  if [[ -n "$DOCKER_SUBNET" ]]; then
    cidr_valid "$DOCKER_SUBNET" || die "DOCKER_SUBNET '$DOCKER_SUBNET' is not valid CIDR (e.g. 172.20.0.0/24)."
    if subnet_conflicts "$DOCKER_SUBNET" >/tmp/.ocs-conf.$$; then
      warn "DOCKER_SUBNET $DOCKER_SUBNET overlaps existing routes on this host:"; cat /tmp/.ocs-conf.$$ >&2; rm -f /tmp/.ocs-conf.$$
      die "Choose a subnet that does not collide with your network."
    fi
    rm -f /tmp/.ocs-conf.$$
    if [[ -n "$DOCKER_GATEWAY" ]]; then
      cidr_valid "$DOCKER_GATEWAY/32" && cidr_overlap "$DOCKER_SUBNET" "$DOCKER_GATEWAY/32" \
        || die "DOCKER_GATEWAY '$DOCKER_GATEWAY' is not a valid address inside $DOCKER_SUBNET."
    fi
  fi

  # --- Database credentials. Postgres only applies POSTGRES_USER/PASSWORD/DB when its data volume is first
  # created, so credentials must never silently diverge from what an existing volume was initialised with.
  local prev_pw="" prev_user="" prev_name=""
  if [[ -f "$SECRETS_FILE" ]]; then
    prev_pw="$(read_secret DB_PASSWORD)"; prev_user="$(read_secret DB_USER)"; prev_name="$(read_secret DB_NAME)"
  fi
  if db_volume_exists && [[ "${OCS_ALLOW_DB_MISMATCH:-0}" != "1" ]]; then
    if [[ ! -f "$SECRETS_FILE" ]]; then
      die "A database volume from an earlier run exists but $SECRETS_FILE is missing, so the password it was created with is unknown (a new one would fail with 'password authentication failed'). Restore that file, or reset the database (DELETES inventory data): sudo bash ocs-setup.sh cleanup --volumes --purge"
    fi
    local diffs=()
    [[ -z "$DB_PASSWORD" || "$DB_PASSWORD" == "$prev_pw" ]] || diffs+=("DB_PASSWORD")
    [[ -z "$prev_user" || "$DB_USER" == "$prev_user" ]] || diffs+=("DB_USER")
    [[ -z "$prev_name" || "$DB_NAME" == "$prev_name" ]] || diffs+=("DB_NAME")
    (( ${#diffs[@]} == 0 )) || die "Changed (${diffs[*]}) but the existing database volume was created with the old values, and Postgres ignores changes after first start ('password authentication failed'). Revert the change in your config, or reset the database (DELETES inventory data): sudo bash ocs-setup.sh cleanup --volumes"
  fi
  [[ -n "$DB_PASSWORD" ]] || DB_PASSWORD="$prev_pw"
  [[ -n "$DB_PASSWORD" ]] || { DB_PASSWORD="$(gen_secret)"; log "Generated random DB password."; }
  ( umask 077; { printf 'DB_USER=%q\n' "$DB_USER"; printf 'DB_NAME=%q\n' "$DB_NAME"; printf 'DB_PASSWORD=%q\n' "$DB_PASSWORD"; } > "$SECRETS_FILE" )
  chmod 600 "$SECRETS_FILE"

  local tls=0 custom_ports=0 custom_db=0 cv
  if [[ "$OCS_SCHEME" == "https" ]]; then tls=1; fi
  if [[ "$HTTP_PORT" != "80" || "$HTTPS_PORT" != "443" || "$FRONTEND_PORT" != "8080" ]]; then custom_ports=1; fi
  if [[ "$DB_USER" != "ocsuser" || "$DB_NAME" != "ocsdb" ]]; then custom_db=1; fi
  if (( tls || custom_ports || custom_db )); then
    cv="$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)"
    version_ge "${cv:-0}" "2.24.0" || die "These settings need Docker Compose >= 2.24 (uses !override/!reset); found '${cv:-none}'."
  fi

  TLS_CA_USE=0
  if (( tls )); then
    tls_validate || die "Certificate problems (see above). Fix them, or set OCS_SCHEME=\"http\" for now."
    gen_nginx_tls_conf
  else
    rm -f "$TLS_CONF_FILE"
  fi

  local n u pw fe_url be_url
  n="$(yaml_escape "$DB_NAME")"; u="$(yaml_escape "$DB_USER")"; pw="$(yaml_escape "$DB_PASSWORD")"
  be_url="$(api_url)"; fe_url="$(console_url)"

  log "Writing $OVERRIDE_FILE"
  ( umask 077; {
    echo "# Generated by ocs-setup.sh - do not edit by hand; change ocs-setup.conf and re-run 'configure'."
    echo "services:"
    echo "  ocsinventory-db:"
    echo "    environment:"
    echo "      POSTGRES_USER: \"$u\""
    echo "      POSTGRES_PASSWORD: \"$pw\""
    echo "      POSTGRES_DB: \"$n\""
    if (( custom_db )); then
      # The official healthcheck hard-codes 'ocsuser'/'ocsdb'; make it follow the real credentials.
      cat <<'YAML'
    healthcheck:
      test: !override ["CMD-SHELL", "pg_isready -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\""]
YAML
    fi
    echo "  ocsinventory-backend:"
    echo "    environment:"
    echo "      DB_NAME_ENV: \"$n\""
    echo "      DB_USER_ENV: \"$u\""
    echo "      DB_PASSWORD_ENV: \"$pw\""
    echo "      FRONTEND_REDIRECT_ENV: \"$fe_url\""
    echo "      DEBUG_ENV: \"False\""
    echo "  ocsinventory-frontend:"
    echo "    environment:"
    echo "      BACKEND_API_ROUTE_ENV: \"$be_url\""
    if (( tls )); then
      echo "    ports: !reset []              # console is served over TLS by the proxy instead"
    elif [[ "$FRONTEND_PORT" != "8080" ]]; then
      echo "    ports: !override"
      echo "      - \"${FRONTEND_PORT}:80\""
    fi
    if (( tls || custom_ports )); then
      echo "  ocsinventory-proxy:"
      if (( tls )); then
        echo "    volumes:"
        echo "      - \"$(yaml_escape "$TLS_CONF_FILE"):/etc/nginx/conf.d/default.conf:ro\""
        echo "      - \"$(yaml_escape "$TLS_CERT_FILE"):$TLS_CERT_CTR:ro\""
        echo "      - \"$(yaml_escape "$TLS_KEY_FILE"):$TLS_KEY_CTR:ro\""
        if (( TLS_CA_USE )); then echo "      - \"$(yaml_escape "$TLS_CA_FILE"):$TLS_CA_CTR:ro\""; fi
      fi
      echo "    ports: !override"
      echo "      - \"${HTTP_PORT}:80\""
      echo "      - \"${HTTPS_PORT}:443\""
      if (( tls )); then echo "      - \"${FRONTEND_PORT}:8080\""; fi
    fi
    if [[ -n "$DOCKER_SUBNET" ]]; then
      echo "networks:"
      echo "  ocsinventory-network:"
      echo "    ipam:"
      echo "      config:"
      echo "        - subnet: \"$DOCKER_SUBNET\""
      if [[ -n "$DOCKER_GATEWAY" ]]; then echo "          gateway: \"$DOCKER_GATEWAY\""; fi
    fi
  } > "$OVERRIDE_FILE" )
  chmod 600 "$OVERRIDE_FILE"
  printf 'COMPOSE_PROJECT_NAME=%s\n' "$PROJECT_NAME" > "$OCS_DIR/.env"

  dc config -q || die "Compose validation failed - check $OVERRIDE_FILE"
  if (( tls )); then
    # The generated conf must REPLACE the official default.conf mount (merged by target path), not add a second one.
    local merged; merged="$(dc config 2>/dev/null || true)"
    [[ "$(grep -c 'target: /etc/nginx/conf.d/default.conf' <<<"$merged" || true)" == "1" ]] \
      && grep -q 'ocsinventory-tls.generated.conf' <<<"$merged" \
      || die "Merged compose config does not mount the TLS nginx config as expected. Inspect: cd $OCS_DIR && docker compose config"
    nginx_selftest
  else
    warn "OCS_SCHEME=http: all traffic is unencrypted. Set OCS_SCHEME=\"https\" and provide certificates (see README)."
  fi
  ok "Configuration valid. Console: $fe_url  |  API: $be_url"
}

# ----------------------------- network ---------------------------------------
ocs_network_id() { docker network ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter "label=com.docker.compose.network=ocsinventory-network" 2>/dev/null | head -n1 || true; }

cmd_netcheck() { # diagnose Docker network collisions
  need_root
  log "Configured DOCKER_SUBNET : ${DOCKER_SUBNET:-<not set - Docker auto-assigns>}"
  local nid cur c bad=0; nid="$(ocs_network_id)"
  if [[ -z "$nid" ]]; then log "No OCS Docker network exists yet."; return 0; fi
  cur="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$nid")"
  log "Actual network subnet    : $cur"
  log "Container addresses:"
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}' | while read -r c; do
    printf '    %-28s %s\n' "$c" "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")"
  done
  for c in $cur; do
    if subnet_conflicts "$c" >/tmp/.ocs-conf.$$; then
      warn "The OCS network $c OVERLAPS other routes on this host/LAN:"; cat /tmp/.ocs-conf.$$ >&2; bad=1
    fi; rm -f /tmp/.ocs-conf.$$
  done
  if (( bad )); then
    warn "Set DOCKER_SUBNET in the config to an unused range, then run: configure && up (the network is recreated; data volumes are kept)."
    return 1
  fi
  ok "No overlap with this host's routing table${RESERVED_RANGES:+ or RESERVED_RANGES}."
  if [[ -z "$RESERVED_RANGES" ]]; then
    warn "This host can only see ranges present in its own routing table. LAN ranges reached via the default gateway are invisible to it."
    warn "List the ranges your network uses in RESERVED_RANGES (e.g. \"172.16.0.0/16 172.17.0.0/16 172.18.0.0/16\") for a reliable check."
  fi
  if [[ -n "$DOCKER_SUBNET" && "$cur" != *"$DOCKER_SUBNET"* ]]; then
    warn "Running network ($cur) differs from DOCKER_SUBNET ($DOCKER_SUBNET). Run 'up' to recreate it."
  fi
}

# Compose will not change the subnet of an existing network; recreate it (volumes untouched).
ensure_network_subnet() {
  [[ -n "$DOCKER_SUBNET" ]] || return 0
  local nid cur; nid="$(ocs_network_id)"; [[ -n "$nid" ]] || return 0
  cur="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$nid")"
  [[ "$cur" == *"$DOCKER_SUBNET"* ]] && return 0
  warn "Existing OCS network uses $cur but DOCKER_SUBNET is $DOCKER_SUBNET."
  warn "Containers will be stopped and recreated on the new network. Data volumes are NOT deleted."
  confirm "Recreate the network now?" || die "Aborted. The old subnet remains in use."
  dc down        # deliberately NO -v : keeps the database and console volumes
}

# ----------------------------- up / health -----------------------------------
cmd_up() {
  need_root
  log "Pulling images and starting stack..."
  dc pull
  ensure_network_subnet
  dc up -d
  cmd_health --wait
}

cmd_health() {
  local wait=0 tries=1; [[ "${1:-}" == "--wait" ]] && { wait=1; tries=36; }
  local s="http" ap="$HTTP_PORT" i be fe
  if [[ "$OCS_SCHEME" == "https" ]]; then s="https"; ap="$HTTPS_PORT"; fi
  for ((i=1; i<=tries; i++)); do
    be="$(local_code "${s}://127.0.0.1:${ap}/")"
    fe="$(local_code "${s}://127.0.0.1:${FRONTEND_PORT}/")"
    if [[ "$be" =~ ^[1-4][0-9][0-9]$ && "$fe" =~ ^[1-4][0-9][0-9]$ ]]; then break; fi
    if (( wait )); then log "Waiting for services... (${i}/${tries}) api=$be console=$fe"; sleep 5; fi
  done
  echo; dc ps || true; echo
  local bad=0
  if [[ "$be" =~ ^[1-4][0-9][0-9]$ ]]; then ok "API proxy responds (HTTP $be) on ${s}://:${ap}"; else warn "API proxy not healthy (HTTP $be)"; bad=1; fi
  if [[ "$fe" =~ ^[1-4][0-9][0-9]$ ]]; then ok "Console responds (HTTP $fe) on ${s}://:${FRONTEND_PORT}"; else warn "Console not healthy (HTTP $fe)"; bad=1; fi

  if [[ "$OCS_SCHEME" == "https" ]]; then
    local host rd; host="$(effective_host)"
    # Strict check (no -k): does the certificate actually validate against this host's trust store?
    if curl -s -o /dev/null -m 5 --resolve "${host}:${HTTPS_PORT}:127.0.0.1" "https://${host}:${HTTPS_PORT}/"; then
      ok "TLS certificate validates for ${host}"
    else
      warn "TLS certificate did NOT validate for ${host} (curl exit $?). Check chain (fullchain.pem) and hostname."; bad=1
    fi
    rd="$(local_code "http://127.0.0.1:${HTTP_PORT}/")"
    if [[ "$HTTP_MODE" == "redirect" ]]; then
      [[ "$rd" == "301" ]] && ok "HTTP :${HTTP_PORT} redirects to HTTPS" || warn "Expected 301 redirect on :${HTTP_PORT}, got $rd"
    else
      log "HTTP :${HTTP_PORT} still serves the API (HTTP_MODE=serve), status $rd"
    fi
  fi
  if (( bad )); then
    local blog; blog="$(dc logs --tail 60 ocsinventory-backend 2>&1 || true)"
    warn "Recent backend logs:"; printf '%s\n' "$blog" | tail -n 30 >&2
    if grep -qi 'password authentication failed' <<<"$blog"; then
      warn "The database rejected the password: its volume was initialised with different credentials."
      warn "Fix: restore the original .ocs-secrets, or reset the database (DELETES data): sudo bash ocs-setup.sh cleanup --volumes"
    fi
    return 1
  fi
}

# ----------------------------- cleanup ---------------------------------------
read_secret() { # read one variable from the secrets file in a clean environment
  env -i bash -c '. "$1" 2>/dev/null; printf "%s" "${!2-}"' _ "$SECRETS_FILE" "$1"
}
db_volume_exists() {
  have docker || return 1
  [[ -n "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" \
            --filter "label=com.docker.compose.volume=ocsinventory-db" 2>/dev/null | head -n1 || true)" ]]
}

PROJECTS=(); C_IDS=(); N_IDS=(); V_IDS=()
collect_containers() { # containers of THIS stack: by compose project label, or started from OCS_DIR
  local id pr
  mapfile -t C_IDS < <({ docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME"
                         docker ps -aq --filter "label=com.docker.compose.project.working_dir=$OCS_DIR"; } | sort -u)
  PROJECTS+=("$PROJECT_NAME")
  for id in "${C_IDS[@]}"; do   # earlier runs may have used another project name (e.g. the folder name)
    pr="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null || true)"
    if [[ -n "$pr" ]]; then PROJECTS+=("$pr"); fi
  done
  mapfile -t PROJECTS < <(printf '%s\n' "${PROJECTS[@]}" | sort -u)
}
collect_net_vol() {
  local pr; N_IDS=(); V_IDS=()
  for pr in "${PROJECTS[@]}"; do
    mapfile -t -O "${#N_IDS[@]}" N_IDS < <(docker network ls -q --filter "label=com.docker.compose.project=$pr")
    mapfile -t -O "${#V_IDS[@]}" V_IDS < <(docker volume ls -q --filter "label=com.docker.compose.project=$pr")
  done
}
foreign_clashes() { # containers using OCS's fixed names that are NOT part of this stack (e.g. a 2.x stack)
  local id name
  while read -r id name; do
    [[ "$name" =~ ^ocsinventory-(backend|frontend|proxy|db)$ ]] || continue
    if printf '%s\n' "${C_IDS[@]}" | grep -q "^${id}"; then continue; fi
    printf '%s (%s)\n' "$name" "$id"
  done < <(docker ps -a --format '{{.ID}} {{.Names}}')
}
dname() { docker inspect -f '{{.Name}}' "$1" 2>/dev/null | sed 's#^/##'; }
nname() { docker network inspect -f '{{.Name}}' "$1" 2>/dev/null; }

cleanup_usage() { cat <<EOF
Usage: sudo $0 cleanup [options]

Removes ONLY this OCS stack's Docker resources (found by compose project label / working dir $OCS_DIR).
It never touches other containers, networks or volumes on this host, and never runs 'docker system prune'.

  (no option)   remove containers + network. KEEPS volumes (database and console data survive).
  --volumes     ALSO delete the stack's volumes (database, console config/extensions). DESTROYS DATA.
  --purge       --volumes + delete generated files (.ocs-secrets, override, .env, generated nginx conf).
                Keeps your ocs-setup.conf, certs/, and the official compose/nginx files. Full reset.
  --dry-run,-n  show what would be removed; change nothing
  --no-backup   skip the automatic database backup that normally precedes --volumes
  --yes,-y      do not ask for confirmation (use with care)

Password errors ('password authentication failed') come from the DATABASE VOLUME, not from containers or
networks: Postgres only reads its password when the volume is first created. Use --volumes to reset it.
EOF
}

cmd_cleanup() {
  local vols=0 purge=0 dry=0 backup=1 a
  for a in "$@"; do case "$a" in
    --volumes) vols=1 ;;  --purge) purge=1; vols=1 ;;  --dry-run|-n) dry=1 ;;
    --yes|-y) ASSUME_YES=1 ;;  --no-backup) backup=0 ;;
    -h|--help) cleanup_usage; return 0 ;;
    *) cleanup_usage >&2; die "Unknown option: $a" ;;
  esac; done
  need_root; have docker || die "Docker is not installed."

  PROJECTS=(); collect_containers; collect_net_vol
  local files=() f clash
  if (( purge )); then
    for f in "$OVERRIDE_FILE" "$OCS_DIR/.env" "$SECRETS_FILE" "$VERSION_FILE" "$TLS_CONF_FILE"; do [[ -e "$f" ]] && files+=("$f"); done
  fi

  echo
  log "Scope: compose project(s) [${PROJECTS[*]}] and containers started from $OCS_DIR. Nothing else is touched."
  log "Containers (${#C_IDS[@]}):"; for a in "${C_IDS[@]}"; do printf '    %s\n' "$(dname "$a")"; done
  log "Networks   (${#N_IDS[@]}):"; for a in "${N_IDS[@]}"; do printf '    %s\n' "$(nname "$a")"; done
  if (( vols )); then
    log "Volumes    (${#V_IDS[@]}): WILL BE DELETED"; for a in "${V_IDS[@]}"; do printf '    %s\n' "$a"; done
  else
    log "Volumes    (${#V_IDS[@]}): kept"; for a in "${V_IDS[@]}"; do printf '    %s\n' "$a"; done
  fi
  if (( purge )); then log "Files to delete (${#files[@]}):"; for f in "${files[@]}"; do printf '    %s\n' "$f"; done; fi
  clash="$(foreign_clashes || true)"
  if [[ -n "$clash" ]]; then
    warn "These containers use OCS's fixed container names but are NOT part of this stack. They will NOT be touched"
    warn "(and they will block this stack from starting until they are renamed or removed by you):"
    printf '%s\n' "$clash" | sed 's/^/    /' >&2
  fi
  if (( ${#C_IDS[@]} + ${#N_IDS[@]} + ${#V_IDS[@]} + ${#files[@]} == 0 )); then ok "Nothing to clean."; return 0; fi
  if (( dry )); then log "Dry run: nothing was changed."; return 0; fi

  # Safety backup before destroying data, if the database is up and answering.
  if (( vols && backup )) && [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" \
         --filter "label=com.docker.compose.service=ocsinventory-db" 2>/dev/null)" ]]; then
    log "Taking a safety backup before deleting volumes..."
    if ! OCS_CONF="$CONF_FILE" bash "${BASH_SOURCE[0]}" backup; then
      warn "Backup FAILED (the database may be unusable, e.g. password errors)."
      confirm "Continue WITHOUT a backup?" || die "Aborted."
    fi
  elif (( vols && backup )); then
    warn "Database container is not running; no automatic backup is possible."
  fi

  if (( vols )) && [[ "${ASSUME_YES:-0}" != "1" ]]; then
    read -r -p "Type DELETE to permanently remove the volumes listed above: " a
    [[ "$a" == "DELETE" ]] || die "Aborted."
  else
    confirm "Proceed with the cleanup above?" || die "Aborted."
  fi

  log "Stopping and removing containers..."
  if [[ -f "$OCS_DIR/docker-compose.yml" ]]; then dc down --remove-orphans >/dev/null 2>&1 || true; fi
  if (( ${#C_IDS[@]} )); then docker rm -f "${C_IDS[@]}" >/dev/null 2>&1 || true; fi

  collect_net_vol   # re-read: compose down may already have removed some
  for a in "${N_IDS[@]}"; do
    docker network rm "$a" >/dev/null 2>&1 && log "Removed network $a" \
      || warn "Could not remove network $a (a container outside this stack may still be attached)."
  done
  if (( vols )); then
    for a in "${V_IDS[@]}"; do
      docker volume rm "$a" >/dev/null 2>&1 && log "Removed volume $a" || warn "Could not remove volume $a (still in use?)"
    done
  fi
  if (( purge )); then for f in "${files[@]}"; do rm -f "$f" && log "Deleted $f"; done; fi

  collect_containers; collect_net_vol
  local left=$(( ${#C_IDS[@]} + ${#N_IDS[@]} ))
  (( vols )) && left=$(( left + ${#V_IDS[@]} ))
  if (( left == 0 )); then ok "Cleanup complete."; else warn "$left resource(s) remain; re-run, or inspect with: docker ps -a / docker network ls / docker volume ls"; fi
  log "Next: sudo bash ocs-setup.sh $( (( purge )) && echo 'configure && sudo bash ocs-setup.sh up' || echo 'up' )"
}

# ----------------------------- backup / restore ------------------------------
cmd_backup() {
  need_root
  stack_exists || die "Stack does not appear to be running."
  local ts dest; ts="$(date +%Y%m%d-%H%M%S)"; dest="$BACKUP_DIR/$ts"
  ( umask 077; mkdir -p "$dest" )
  log "Backing up database..."
  if ! dc exec -T ocsinventory-db sh -c 'pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "$dest/db.sql.gz"; then
    rm -rf "$dest"; die "Database dump failed."
  fi
  [[ -s "$dest/db.sql.gz" ]] || { rm -rf "$dest"; die "Database dump is empty."; }

  log "Backing up configuration..."
  local f files=()
  for f in docker-compose.yml docker-compose.override.yml .env .ocs-secrets .ocs-version files certs; do
    [[ -e "$OCS_DIR/$f" ]] && files+=("$f")
  done
  ( umask 077; tar -czf "$dest/config.tar.gz" -C "$OCS_DIR" "${files[@]}" )

  if [[ "$BACKUP_VOLUMES" == "true" ]]; then
    local v vols
    vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT_NAME" | grep -Ev 'socket|ocsinventory-db' || true)"
    for v in $vols; do
      docker run --rm -v "$v":/data:ro -v "$dest":/backup alpine tar -czf "/backup/vol-$v.tar.gz" -C /data . \
        && log "Saved volume $v" || warn "Could not back up volume $v (non-fatal)."
    done
  fi
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} +
  ok "Backup complete: $dest ($(du -sh "$dest" | cut -f1)); retention ${BACKUP_RETENTION_DAYS}d"
}

cmd_restore() {
  need_root
  local file="${1:-}"; [[ -f "$file" ]] || die "Usage: $0 restore /path/to/db.sql.gz"
  warn "This REPLACES the current OCS database with the contents of $file."
  confirm "Continue?" || die "Aborted."
  log "Taking a safety backup first..."; cmd_backup
  dc stop ocsinventory-backend
  gunzip -c "$file" | dc exec -T ocsinventory-db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null
  dc start ocsinventory-backend
  cmd_health --wait
  ok "Restore complete."
}

# ----------------------------- upgrade ---------------------------------------
cmd_upgrade() {
  need_root
  local new="${1:-}"; [[ -n "$new" ]] || die "Usage: $0 upgrade <version>   (e.g. 3.0.0-rc2)"
  local cur; cur="$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)"
  log "Upgrading $cur -> $new"
  local tmp; tmp="$(mktemp -d)"; download_official "$new" "$tmp"
  echo "------ diff of official compose file ($cur -> $new) ------"
  diff -u "$OCS_DIR/docker-compose.yml" "$tmp/docker-compose.yml" || true
  diff -u "$OCS_DIR/files/nginx/ocsinventory-backend.conf" "$tmp/files/nginx/ocsinventory-backend.conf" || true
  echo "------------------------------------------------------------"
  warn "Check the diff for database image changes (e.g. a new postgres MAJOR version needs a dump/restore, not just a pull)."
  confirm "Back up and apply upgrade to $new?" || { rm -rf "$tmp"; die "Aborted."; }
  cmd_backup
  cp -a "$OCS_DIR/docker-compose.yml" "$OCS_DIR/docker-compose.yml.bak.$cur"
  cp -f "$tmp/docker-compose.yml" "$OCS_DIR/docker-compose.yml"
  cp -f "$tmp/files/nginx/ocsinventory-backend.conf" "$OCS_DIR/files/nginx/ocsinventory-backend.conf"
  rm -rf "$tmp"; echo "$new" > "$VERSION_FILE"
  OCS_VERSION="$new"
  cmd_configure
  cmd_up
  ok "Upgraded to $new. Rollback: restore docker-compose.yml.bak.$cur and the DB dump in $BACKUP_DIR."
}

# ----------------------------- orchestration ---------------------------------
cmd_all() {
  cmd_preflight; cmd_install_docker; cmd_firewall; cmd_fetch; cmd_configure; cmd_up
  echo
  ok "OCS Inventory $OCS_VERSION deployed."
  log "Console : $(console_url)"
  log "API     : $(api_url)  (agent endpoint)"
  log "DB creds: $SECRETS_FILE (root-only). Initial admin login: see the official OCS 3.0 docs."
  log "Next    : schedule '$0 backup' via cron, see README."
}

usage() { cat <<EOF
OCS Inventory 3.0 Docker deployment helper

  sudo $0 <command>

Commands:
  all              preflight + install-docker + firewall + fetch + configure + up
  preflight        check OS, resources, ports, DNS, connectivity
  install-docker   install Docker Engine + compose plugin (Ubuntu/Debian/RHEL family)
  firewall         open required ports in ufw/firewalld (if active)
  tlscheck         validate certificate/key/hostname/expiry without changing anything
  selfsigned       generate a SELF-SIGNED cert (testing only)
  netcheck         diagnose Docker network/subnet collisions with your LAN
  fetch            download official compose + nginx files for OCS_VERSION
  configure        generate docker-compose.override.yml from ocs-setup.conf
  up               pull images, start stack, wait for health
  health           check containers and HTTP endpoints
  cleanup [opts]   remove THIS stack's containers/network (--volumes / --purge also reset the database; --dry-run to preview)
  backup           dump DB + config (+ volumes) to \$BACKUP_DIR, prune old
  restore <file>   restore a db.sql.gz produced by 'backup'
  upgrade <ver>    backup, show diff, switch to a new official version

Config: $CONF_FILE (copy ocs-setup.conf.example)   Log: $LOG_FILE
EOF
}

# ----------------------------- main ------------------------------------------
cmd="${1:-help}"; shift || true
if [[ $EUID -eq 0 && "$cmd" != "help" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"; exec > >(tee -a "$LOG_FILE") 2>&1
fi
case "$cmd" in
  all) cmd_all ;;
  preflight) cmd_preflight ;;
  install-docker) cmd_install_docker ;;
  firewall) cmd_firewall ;;
  tlscheck) cmd_tlscheck ;;
  selfsigned) cmd_selfsigned ;;
  netcheck) cmd_netcheck ;;
  cleanup) cmd_cleanup "$@" ;;
  fetch) cmd_fetch ;;
  configure) cmd_configure ;;
  up) cmd_up ;;
  health) cmd_health "$@" ;;
  backup) cmd_backup ;;
  restore) cmd_restore "$@" ;;
  upgrade) cmd_upgrade "$@" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
