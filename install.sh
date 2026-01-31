#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_INSTALL_DIR="/opt/bosbase"
readonly PROJECT_NAME="bosbase"
readonly UNIT_NAME="docker-compose@${PROJECT_NAME}.service"

# Detected OS: "ubuntu" or "rocky"
DETECTED_OS=""

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
Usage: sudo ./install.sh [options]

Options:
  --domain VALUE           Fully qualified domain name for Caddy (required)
  --email VALUE            Email address for ACME/Let's Encrypt (recommended)
  --openai-key VALUE       OPENAI_API_KEY to inject into the stack
  --openai-base-url VALUE  OPENAI_BASE_URL to inject into the stack
  --encryption-key VALUE   32 character BS_ENCRYPTION_KEY (auto-generated if omitted)
  --postgres-password VALUE 16 character POSTGRES_PASSWORD (auto-generated if omitted)
  --install-dir PATH       Installation directory (default: /opt/bosbase)
  --user NAME              System user to grant docker access (defaults to invoking user)
  --non-interactive        Fail instead of prompting for missing values
  -h, --help               Show this message

Values may also be provided via environment variables:
  BOSBASE_DOMAIN, BOSBASE_ACME_EMAIL, OPENAI_API_KEY, OPENAI_BASE_URL,
  BS_ENCRYPTION_KEY, POSTGRES_PASSWORD, BOSBASE_INSTALL_DIR, BOSBASE_USER

Supported distributions:
  - Ubuntu (20.04+)
  - Rocky Linux 9.x
EOF
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die "Run this script as root (e.g. sudo ./install.sh)"
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl is required. Please run on a systemd-based host."
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
      DETECTED_OS="ubuntu"
      log "Detected Ubuntu ${VERSION_ID}"
      ;;
    rocky)
      DETECTED_OS="rocky"
      local major="${VERSION_ID%%.*}"
      if [[ "$major" != "9" ]]; then
        die "Unsupported Rocky Linux version: ${VERSION_ID}. Use Rocky Linux 9.x."
      fi
      log "Detected Rocky Linux ${VERSION_ID}"
      ;;
    *)
      die "Unsupported distribution: ${ID}. This installer supports Ubuntu and Rocky Linux 9.x."
      ;;
  esac
}

parse_args() {
  DOMAIN="${BOSBASE_DOMAIN:-}"
  ACME_EMAIL="${BOSBASE_ACME_EMAIL:-}"
  OPENAI_KEY="${OPENAI_API_KEY:-}"
  OPENAI_BASE_URL_VALUE="${OPENAI_BASE_URL:-}"
  ENCRYPTION_KEY="${BS_ENCRYPTION_KEY:-}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
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
      --postgres-password)
        POSTGRES_PASSWORD="$2"
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

# Ubuntu-specific Docker installation
ensure_docker_ubuntu() {
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

# Rocky-specific Docker installation
ensure_docker_rocky() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    systemctl enable --now docker
    return
  fi

  log "Installing Docker Engine..."
  dnf -y install curl dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_docker() {
  case "$DETECTED_OS" in
    ubuntu)
      ensure_docker_ubuntu
      ;;
    rocky)
      ensure_docker_rocky
      ;;
  esac
}

# Ubuntu-specific Caddy installation
ensure_caddy_ubuntu() {
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

# Rocky-specific Caddy installation
ensure_caddy_rocky() {
  if command -v caddy >/dev/null 2>&1; then
    log "Caddy already installed."
    systemctl enable caddy >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet caddy; then
      timeout 5 systemctl start caddy || warn "Caddy start timed out or failed, continuing anyway"
    fi
    return
  fi

  log "Installing Caddy..."
  dnf -y install 'dnf-command(copr)'
  dnf -y copr enable @caddy/caddy
  dnf -y install caddy
  systemctl enable caddy >/dev/null 2>&1 || true
  timeout 5 systemctl start caddy || warn "Caddy start timed out or failed, continuing anyway"
}

ensure_caddy() {
  case "$DETECTED_OS" in
    ubuntu)
      ensure_caddy_ubuntu
      ;;
    rocky)
      ensure_caddy_rocky
      ;;
  esac
}

# Rocky-specific SELinux and firewall configuration
configure_selinux_firewall() {
  if [[ "$DETECTED_OS" != "rocky" ]]; then
    return
  fi

  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    if command -v setsebool >/dev/null 2>&1; then
      setsebool -P httpd_can_network_connect 1
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-service=http
      firewall-cmd --permanent --add-service=https
      firewall-cmd --reload
    else
      warn "firewalld is not running; skipping firewall configuration."
    fi
  else
    warn "firewall-cmd not available; skipping firewall configuration."
  fi
}

install_openssl() {
  if command -v openssl >/dev/null 2>&1; then
    return
  fi

  case "$DETECTED_OS" in
    ubuntu)
      apt-get update
      apt-get install -y openssl
      ;;
    rocky)
      dnf -y install openssl
      ;;
  esac
}

write_compose_file() {
  cat > "$INSTALL_DIR/docker-compose.db.yml" <<EOF
services:
  postgres-db:
    image: pgvector/pgvector:pg16
    restart: unless-stopped
    environment:
      POSTGRES_DB: pbosbase
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    networks:
      - basenode
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d pbosbase"]
      interval: 2s
      timeout: 5s
      retries: 10
      start_period: 10s

networks:
  basenode:
    driver: bridge
    name: basenode
EOF

  cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  bosbase-node:
    image: bosbase/bosbase:ve1
    restart: unless-stopped
    environment:
      SASSPB_POSTGRES_URL: postgres://postgres:${POSTGRES_PASSWORD}@postgres-db:5432/pbosbase?sslmode=disable
      BS_ENCRYPTION_KEY: ${ENCRYPTION_KEY}
      OPENAI_API_KEY: \${OPENAI_API_KEY:-sk-af61vU1kIT0uw5YzOM7VRM3KGrxBAfuhVgJX9ghtkHfdRVsu}
      OPENAI_BASE_URL: \${OPENAI_BASE_URL:-https://api.chatanywhere.org/v1}
      PB_ACTIVATION_VERIFY_URL: \${PB_ACTIVATION_VERIFY_URL:-https://ve.bosbase.com/verify}
      # REDIS_URL: \${REDIS_URL:-192.168.1.60:6379}
      # REDIS_PASSWORD: \${REDIS_PASSWORD:-}
      WASM_ENABLE: \${WASM_ENABLE:-true}
      WASM_INSTANCE_NUM: \${WASM_INSTANCE_NUM:-32}
      SCRIPT_CONCURRENCY: \${SCRIPT_CONCURRENCY:-32}
      FUNCTION_CONN_NUM: \${FUNCTION_CONN_NUM:-10}
      EXECUTE_PATH: \${EXECUTE_PATH:-/pb/functions}
      # BOOSTER_PATH: \${BOOSTER_PATH:-/pb/booster-wasm}
      # BOOSTER_POOL_MAX: \${BOOSTER_POOL_MAX:-2}
      # BOOSTER_WASMTIME_MEMORY_GUARD_SIZE: \${BOOSTER_WASMTIME_MEMORY_GUARD_SIZE:-65536}
      # BOOSTER_WASMTIME_MEMORY_RESERVATION: \${BOOSTER_WASMTIME_MEMORY_RESERVATION:-0}
      # BOOSTER_WASMTIME_MEMORY_RESERVATION_FOR_GROWTH: \${BOOSTER_WASMTIME_MEMORY_RESERVATION_FOR_GROWTH:-1048576}
      PB_DATA_MAX_OPEN_CONNS: \${PB_DATA_MAX_OPEN_CONNS:-30}
      PB_DATA_MAX_IDLE_CONNS: \${PB_DATA_MAX_IDLE_CONNS:-15}
      PB_AUX_MAX_OPEN_CONNS: \${PB_AUX_MAX_OPEN_CONNS:-10}
      PB_AUX_MAX_IDLE_CONNS: \${PB_AUX_MAX_IDLE_CONNS:-3}
      PB_QUERY_TIMEOUT: \${PB_QUERY_TIMEOUT:-300s}
    ports:
      - "8090:8090"
      - "2678:2678"
    volumes:
      - ./bosbase-data:/pb/pb_data
      - ./pb_hooks:/pb_hooks
    networks:
      - basenode

networks:
  basenode:
    external: true
    name: basenode
EOF
}

write_env_file() {
  local env_path="$INSTALL_DIR/.env"
  cat > "$env_path" <<EOF
OPENAI_API_KEY=${OPENAI_KEY}
OPENAI_BASE_URL=${OPENAI_BASE_URL_VALUE}
BS_ENCRYPTION_KEY=${ENCRYPTION_KEY}
PB_ACTIVATION_VERIFY_URL=\${PB_ACTIVATION_VERIFY_URL:-https://ve.bosbase.com/verify}
WASM_ENABLE=\${WASM_ENABLE:-true}
WASM_INSTANCE_NUM=\${WASM_INSTANCE_NUM:-32}
SCRIPT_CONCURRENCY=\${SCRIPT_CONCURRENCY:-32}
FUNCTION_CONN_NUM=\${FUNCTION_CONN_NUM:-10}
EXECUTE_PATH=\${EXECUTE_PATH:-/pb/functions}
PB_DATA_MAX_OPEN_CONNS=\${PB_DATA_MAX_OPEN_CONNS:-30}
PB_DATA_MAX_IDLE_CONNS=\${PB_DATA_MAX_IDLE_CONNS:-15}
PB_AUX_MAX_OPEN_CONNS=\${PB_AUX_MAX_OPEN_CONNS:-10}
PB_AUX_MAX_IDLE_CONNS=\${PB_AUX_MAX_IDLE_CONNS:-3}
PB_QUERY_TIMEOUT=\${PB_QUERY_TIMEOUT:-300s}
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


  handle /booster* {
    reverse_proxy 127.0.0.1:2678 {
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
  }



  handle {
    reverse_proxy 127.0.0.1:8090 {
      header_up X-Real-IP {remote_host}
      header_up X-Forwarded-For {remote_host}
      header_up X-Forwarded-Proto {scheme}
      header_up X-Forwarded-Host {host}

      transport http {
        max_conns_per_host 0
      }
    }
  }
}

www.${DOMAIN} {
  redir https://${DOMAIN}{uri} permanent
}
EOF
  ln -sf "$caddy_path" /etc/caddy/Caddyfile
  log "Reloading Caddy with new configuration..."
  if systemctl is-active --quiet caddy; then
    # Reload with timeout to prevent hanging
    if timeout 10 systemctl reload caddy >/dev/null 2>&1; then
      log "Caddy reloaded successfully"
    else
      warn "Caddy reload timed out or failed, will restart instead"
      timeout 10 systemctl restart caddy >/dev/null 2>&1 || warn "Caddy restart also failed, continuing anyway"
    fi
  else
    # Start with timeout to prevent hanging
    if timeout 10 systemctl start caddy >/dev/null 2>&1; then
      log "Caddy started successfully"
    else
      warn "Caddy start timed out or failed, continuing anyway"
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
ExecStart=/bin/sh -c 'docker compose --project-name ${PROJECT_NAME} -f docker-compose.db.yml up -d && docker compose --project-name ${PROJECT_NAME} -f docker-compose.yml up -d'
ExecStop=/bin/sh -c 'docker compose --project-name ${PROJECT_NAME} -f docker-compose.yml down && docker compose --project-name ${PROJECT_NAME} -f docker-compose.db.yml down'
TimeoutStartSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME"
}

stop_existing_containers() {
  if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    log "Stopping existing containers..."
    (cd "$INSTALL_DIR" && docker compose --project-name "$PROJECT_NAME" down 2>/dev/null || true)
  fi
}

prepare_directories() {
  install -d -m 755 "$INSTALL_DIR"
  # Remove existing data directories for clean install
  if [[ -d "$INSTALL_DIR/bosbase-data" ]]; then
    log "Removing existing bosbase-data directory..."
    rm -rf "$INSTALL_DIR/bosbase-data"
  fi
  if [[ -d "$INSTALL_DIR/postgres-data" ]]; then
    log "Removing existing postgres-data directory..."
    rm -rf "$INSTALL_DIR/postgres-data"
  fi
  if [[ -d "$INSTALL_DIR/pb_hooks" ]]; then
    log "Preserving existing pb_hooks directory..."
  else
    install -d -m 755 "$INSTALL_DIR/pb_hooks"
  fi
  install -d -m 755 "$INSTALL_DIR/bosbase-data" "$INSTALL_DIR/postgres-data"
}

run_compose() {
  log "Starting Docker Compose stack..."
  (cd "$INSTALL_DIR" && docker compose --project-name "$PROJECT_NAME" -f docker-compose.db.yml up -d)
  (cd "$INSTALL_DIR" && docker compose --project-name "$PROJECT_NAME" -f docker-compose.yml up -d)
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
    install_openssl
    ENCRYPTION_KEY=$(openssl rand -hex 16)
  fi

  if [[ ${#ENCRYPTION_KEY} -ne 32 ]]; then
    die "BS_ENCRYPTION_KEY must be exactly 32 characters (got ${#ENCRYPTION_KEY})."
  fi

  if [[ -z "$POSTGRES_PASSWORD" ]]; then
    log "Generating POSTGRES_PASSWORD..."
    install_openssl
    POSTGRES_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
  fi

  if [[ ${#POSTGRES_PASSWORD} -ne 16 ]]; then
    die "POSTGRES_PASSWORD must be exactly 16 characters (got ${#POSTGRES_PASSWORD})."
  fi

  log "Installing prerequisites..."
  ensure_docker
  ensure_permissions
  ensure_caddy
  configure_selinux_firewall

  stop_existing_containers
  prepare_directories
  write_compose_file
  write_env_file
  write_caddyfile
  chown -R "$TARGET_USER":docker "$INSTALL_DIR"

  run_compose
  write_systemd_unit

  health_check "http://localhost:8090/api/health" "BosBase API"

  log "Installation complete."
  log "Files installed under $INSTALL_DIR"
  log "Domain ${DOMAIN} is now proxied via Caddy."
  log ""
  log "========================================"
  log "PostgreSQL Password: ${POSTGRES_PASSWORD}"
  log "========================================"
  log ""
  log "IMPORTANT: Save this password securely! It is required for database access."
  log ""
  log "To set up a superuser account, run:"
  log "  docker exec bosbase-bosbase-node-1 /pb/bosbase superuser upsert yourloginemail yourpassword"
  log ""
  log "To see dashboard login instructions, run:"
  log "  docker logs bosbase-bosbase-node-1"
}

main "$@"
