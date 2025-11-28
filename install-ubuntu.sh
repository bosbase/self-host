#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_INSTALL_DIR="/opt/bosbase"
readonly PROJECT_NAME="bosbase"
readonly UNIT_NAME="docker-compose@${PROJECT_NAME}.service"

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo ./install-ubuntu.sh [options]

Options:
  --domain VALUE           Fully qualified domain name for Caddy (required)
  --email VALUE            Email address for ACME/Let's Encrypt (recommended)
  --openai-key VALUE       OPENAI_API_KEY to inject into the stack
  --openai-base-url VALUE  OPENAI_BASE_URL to inject into the stack
  --encryption-key VALUE   64 character BS_ENCRYPTION_KEY (auto-generated if omitted)
  --install-dir PATH       Installation directory (default: /opt/bosbase)
  --user NAME              System user to grant docker access (defaults to invoking user)
  --non-interactive        Fail instead of prompting for missing values
  -h, --help               Show this message

Values may also be provided via environment variables:
  BOSBASE_DOMAIN, BOSBASE_ACME_EMAIL, OPENAI_API_KEY, OPENAI_BASE_URL,
  BS_ENCRYPTION_KEY, BOSBASE_INSTALL_DIR, BOSBASE_USER
EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run this script as root (e.g. sudo ./install-ubuntu.sh)"
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl is required. Please run on a systemd-based Ubuntu host."
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. Unsupported distribution."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}" in
    ubuntu)
      ;;
    *)
      die "This installer targets Ubuntu. Detected ID=${ID}."
      ;;
  esac
}

parse_args() {
  DOMAIN="${BOSBASE_DOMAIN:-}"
  ACME_EMAIL="${BOSBASE_ACME_EMAIL:-}"
  OPENAI_KEY="${OPENAI_API_KEY:-}"
  OPENAI_BASE_URL_VALUE="${OPENAI_BASE_URL:-}"
  ENCRYPTION_KEY="${BS_ENCRYPTION_KEY:-}"
  INSTALL_DIR="${BOSBASE_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  TARGET_USER="${BOSBASE_USER:-${SUDO_USER:-}}"
  NON_INTERACTIVE=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="$2"
        shift 2
        ;;
      --email)
        ACME_EMAIL="$2"
        shift 2
        ;;
      --openai-key)
        OPENAI_KEY="$2"
        shift 2
        ;;
      --openai-base-url)
        OPENAI_BASE_URL_VALUE="$2"
        shift 2
        ;;
      --encryption-key)
        ENCRYPTION_KEY="$2"
        shift 2
        ;;
      --install-dir)
        INSTALL_DIR="$2"
        shift 2
        ;;
      --user)
        TARGET_USER="$2"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        warn "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$TARGET_USER" ]] && command -v logname >/dev/null 2>&1; then
    TARGET_USER=$(logname || true)
  fi
  TARGET_USER=${TARGET_USER:-root}
}

ensure_value() {
  local name="$1"
  local prompt="$2"
  local is_required="$3"
  local current_value="$4"
  local value="$current_value"

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return
  fi

  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    if [[ "$is_required" == "required" ]]; then
      die "Missing required value for $name. Provide via flag, env var, or interactive prompt."
    fi
    printf ''
    return
  fi

  read -r -p "$prompt" value || true
  if [[ "$is_required" == "required" && -z "$value" ]]; then
    die "$name is required."
  fi
  printf '%s' "$value"
}

prompt_domain() {
  local current="$1"
  local input=""

  if [[ -n "$current" ]]; then
    printf '%s' "$current"
    return
  fi

  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    die "Domain is required when running with --non-interactive."
  fi

  while true; do
    read -r -p "Enter the domain that should point to this host: " input || true
    if [[ -n "$input" ]]; then
      printf '%s' "$input"
      return
    fi
    printf 'Domain is required.\n'
  done
}

ensure_permissions() {
  groupadd -f docker

  if [[ "$TARGET_USER" != "root" ]]; then
    if ! id "$TARGET_USER" >/dev/null 2>&1; then
      die "User '$TARGET_USER' does not exist."
    fi
    usermod -aG docker "$TARGET_USER"
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    systemctl enable --now docker
    return
  fi

  log "Installing Docker Engine..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  local arch shell_release list_file
  arch=$(dpkg --print-architecture)
  shell_release=$(lsb_release -cs)
  list_file="/etc/apt/sources.list.d/docker.list"
  cat > "$list_file" <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${shell_release} stable
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    log "Caddy already installed."
    systemctl enable caddy >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet caddy; then
      timeout 5 systemctl start caddy || warn "Caddy start timed out or failed, continuing anyway"
    fi
    return
  fi

  log "Installing Caddy..."
  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
  cat > /etc/apt/sources.list.d/caddy-stable.list <<'EOF'
deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/ubuntu any-version main
EOF
  apt-get update
  apt-get install -y caddy
  systemctl enable caddy >/dev/null 2>&1 || true
  timeout 5 systemctl start caddy || warn "Caddy start timed out or failed, continuing anyway"
}

write_compose_file() {
  local compose_path="$INSTALL_DIR/docker-compose.yml"
  cat > "$compose_path" <<'EOF'
version: "3.8"

services:
  bosbasedb-node:
    image: bosbasedb:vb1
    restart: unless-stopped
    environment:
      HTTP_ADDR: 0.0.0.0:4001
      RAFT_ADDR: 0.0.0.0:4002
      HTTP_ADV_ADDR: bosbasedb-node:4001
      RAFT_ADV_ADDR: bosbasedb-node:4002
      NODE_ID: node1
    volumes:
      - ./bosbasedb-node1-data:/bosbasedb/file
    command: ["-bootstrap-expect", "1"]

  bosbase-node:
    image: bosbase:vb1
    restart: unless-stopped
    environment:
      SASSPB_BOSBASEDB_URL: http://bosbasedb-node:4001
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      BS_ENCRYPTION_KEY: ${BS_ENCRYPTION_KEY}
    ports:
      - "8090:8090"
    volumes:
      - ./bosbase-data:/pb/pb_data
    depends_on:
      - bosbasedb-node
    command: ["/pb/bosbase", "serve", "--http=0.0.0.0:8090", "--encryptionEnv", "BS_ENCRYPTION_KEY"]
EOF
}

write_env_file() {
  local env_path="$INSTALL_DIR/.env"
  cat > "$env_path" <<EOF
OPENAI_API_KEY=${OPENAI_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL_VALUE}
BS_ENCRYPTION_KEY=${ENCRYPTION_KEY}
EOF
  chmod 600 "$env_path"
}

write_caddyfile() {
  local caddy_path="$INSTALL_DIR/Caddyfile"
  local email_block=""
  if [[ -n "$ACME_EMAIL" ]]; then
    email_block=$'{\n\temail '"$ACME_EMAIL"$'\n}\n\n'
  fi

  cat > "$caddy_path" <<EOF
${email_block}${DOMAIN} {
  encode gzip zstd

  reverse_proxy 127.0.0.1:8090 {
    header_up Upgrade {http.upgrade}
    header_up Connection {http.connection}
    header_up X-Real-IP {remote_host}
    header_up X-Forwarded-For {remote_host}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Host {host}

    transport http {
      max_conns_per_host 0
    }
  }

  header {
    X-Frame-Options "SAMEORIGIN"
    X-Content-Type-Options "nosniff"
    X-XSS-Protection "1; mode=block"
    Referrer-Policy "no-referrer-when-downgrade"
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
  }

  log {
    output file /var/log/caddy/bosbase.log
    format json
  }
}

www.${DOMAIN} {
  redir https://${DOMAIN}{uri} permanent
}
EOF
  ln -sf "$caddy_path" /etc/caddy/Caddyfile
  log "Reloading Caddy with new configuration..."
  if systemctl is-active --quiet caddy; then
    # Reload will fail if config is invalid, so we don't need separate validation
    if ! systemctl reload caddy; then
      die "Failed to reload Caddy - check Caddyfile configuration"
    fi
  else
    # Start will fail if config is invalid
    if ! systemctl start caddy; then
      die "Failed to start Caddy - check Caddyfile configuration"
    fi
  fi
}

write_systemd_unit() {
  local unit_path="/etc/systemd/system/${UNIT_NAME}"
  cat > "$unit_path" <<EOF
[Unit]
Description=BosBase Docker Compose stack
Requires=docker.service
After=docker.service

[Service]
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose --project-name ${PROJECT_NAME} up -d
ExecStop=/usr/bin/docker compose --project-name ${PROJECT_NAME} down
TimeoutStartSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME"
}

prepare_directories() {
  install -d -m 755 "$INSTALL_DIR"
  install -d -m 755 "$INSTALL_DIR/bosbase-data" "$INSTALL_DIR/bosbasedb-node1-data"
}

run_compose() {
  log "Starting Docker Compose stack..."
  (cd "$INSTALL_DIR" && docker compose --project-name "$PROJECT_NAME" up -d)
}

health_check() {
  local url="$1"
  local label="$2"
  local attempts=20

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "$label is healthy ($url)"
      return 0
    fi
    sleep 3
  done
  warn "Unable to verify $label at $url"
  return 1
}

main() {
  parse_args "$@"
  require_root
  require_systemd
  detect_os

  DOMAIN=$(prompt_domain "$DOMAIN")
  ACME_EMAIL=$(ensure_value "email" "Enter email for ACME (optional, press Enter to skip): " "optional" "$ACME_EMAIL")

  if [[ -z "$ENCRYPTION_KEY" ]]; then
    log "Generating BS_ENCRYPTION_KEY..."
    if ! command -v openssl >/dev/null 2>&1; then
      apt-get update
      apt-get install -y openssl
    fi
    ENCRYPTION_KEY=$(openssl rand -hex 32)
  fi

  if [[ ${#ENCRYPTION_KEY} -lt 32 ]]; then
    die "BS_ENCRYPTION_KEY must be at least 32 characters."
  fi

  log "Installing prerequisites..."
  ensure_docker
  ensure_permissions
  ensure_caddy

  prepare_directories
  write_compose_file
  write_env_file
  write_caddyfile
  chown -R "$TARGET_USER":docker "$INSTALL_DIR"

  run_compose
  write_systemd_unit

  health_check "http://localhost:8090/api/health" "BosBase API"
  health_check "http://localhost:4001/status" "BosBaseDB"

  log "Installation complete."
  log "Files installed under $INSTALL_DIR"
  log "Domain ${DOMAIN} is now proxied via Caddy."
}

main "$@"
