# Shell Installation Script Guide (Ubuntu & Rocky Linux)

This document outlines what the two shell installers (one for Ubuntu, one for Rocky Linux) must do to bootstrap the BosBase single-node stack with Docker Compose and Caddy. The goal is to make the scripts idempotent, transparent, and safe to run on freshly provisioned hosts.

## Shared Responsibilities

Both installers should perform the same high-level tasks:

1. **Collect configuration** – accept domain name, email for ACME, `OPENAI_API_KEY`, `OPENAI_BASE_URL` (optional), and a generated `BS_ENCRYPTION_KEY`. The scripts can read values from environment variables or prompt interactively.
2. **Ensure prerequisites** – install Docker Engine, Docker Compose plugin, and Caddy. Validate that `systemctl` is available and the user has sudo rights.
3. **Lay down BosBase assets** – place `docker-compose.yml`, `.env`, data directories, and `Caddyfile` into `/opt/bosbase` (or another configurable root).
4. **Create system users and permissions** – add the invoking user to the `docker` group and set directory ownership to keep `docker compose` usable without repeated sudo.
5. **Start and enable services** – launch the Docker Compose stack and Caddy, configure systemd units so they survive reboots, and report service status.
6. **Perform health checks** – curl `http://localhost:8090/api/health` and `http://localhost:4001/status` once containers are up, surfacing failures early.

### Files to Deploy

```
/opt/bosbase/
├── docker-compose.yml        # From README.md (single-node stack)
├── .env                      # Contains OPENAI / encryption values
├── Caddyfile                 # Reverse-proxy definition
├── bosbase-data/             # Persistent PocketBase data
└── bosbasedb-node1-data/     # Persistent BosBaseDB data
```

Use `install -d -m 755` to create the directory tree and `tee`/`cat <<'EOF'` to write files atomically.

### Systemd Units

- `docker-compose@bosbase.service` that runs `docker compose --project-name bosbase up -d` in `/opt/bosbase`.
- Native `caddy.service` from each distribution’s package manager; only the config file path needs to match.

## Ubuntu Installer (22.04+)

### Package Installation

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd -f docker
sudo usermod -aG docker "$SUDO_USER"
sudo systemctl enable --now docker
```

Install Caddy via the official repository:

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/caddy.gpg
echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/ubuntu any-version main" |
  sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install -y caddy
```

### Script Outline

1. Parse flags/env vars (`--domain`, `--email`, `--openai-key`, `--encryption-key`, `--install-dir`).
2. Run the package installation block above, but guard it with detection logic to skip re-installing Docker/Caddy if already present.
3. Create `/opt/bosbase` (or provided directory) and drop the Docker Compose file from the README verbatim. The script can `cat <<'EOF' > docker-compose.yml` to embed the YAML.
4. Write `.env`:
   ```bash
   cat > .env <<EOF
   OPENAI_API_KEY=${OPENAI_API_KEY}
   OPENAI_BASE_URL=${OPENAI_BASE_URL}
   BS_ENCRYPTION_KEY=${BS_ENCRYPTION_KEY}
   EOF
   ```
5. Copy the repository `Caddyfile`, but template the `example.com` host with the provided domain and point the upstream to `http://localhost:8090`.
6. Reload Caddy (`sudo systemctl reload caddy`) after writing the config.
7. Start the stack: `sudo docker compose --project-name bosbase up -d`.
8. Optionally create `/etc/systemd/system/docker-compose@bosbase.service`:
   ```ini
   [Unit]
   Description=BosBase Docker Compose stack
   Requires=docker.service
   After=docker.service

   [Service]
   WorkingDirectory=/opt/bosbase
   ExecStart=/usr/bin/docker compose --project-name bosbase up -d
   ExecStop=/usr/bin/docker compose --project-name bosbase down
   RemainAfterExit=yes
   TimeoutStartSec=0

   [Install]
   WantedBy=multi-user.target
   ```
   Enable via `sudo systemctl enable --now docker-compose@bosbase`.

## Rocky Linux Installer (9.x)

### Package Installation

```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$SUDO_USER"
```

Install Caddy from the official COPR:

```bash
sudo dnf -y install 'dnf-command(copr)'
sudo dnf -y copr enable @caddy/caddy
sudo dnf -y install caddy
sudo systemctl enable --now caddy
```

### Script Outline

1. Detect Rocky Linux via `/etc/os-release` to avoid running on unsupported platforms.
2. Execute the package installation blocks above only when the respective binaries are missing.
3. Configure SELinux and the firewall if needed:
   ```bash
   sudo setsebool -P httpd_can_network_connect 1
   sudo firewall-cmd --permanent --add-service=http
   sudo firewall-cmd --permanent --add-service=https
   sudo firewall-cmd --reload
   ```
4. Create `/opt/bosbase` and populate the same files as in the Ubuntu script.
5. For `.env` and `docker-compose.yml`, reuse the exact content; only the package-management logic differs.
6. Ensure `ExecStart=/usr/bin/docker compose ...` in the systemd unit (binary paths are identical on Rocky).
7. Reload systemd, enable the compose unit, and run health checks.

## Caddy Configuration Expectations

Use the repository `Caddyfile` as the base template:

```caddyfile
{domain} {
  encode gzip zstd
  reverse_proxy 127.0.0.1:8090
}
```

- Replace `{domain}` with the provided hostname.
- If Let’s Encrypt email is supplied, add `email you@example.com` to the global options block.
- To force HTTPS, Caddy’s defaults are enough; no extra flags needed.

After writing the file:

```bash
sudo caddy validate --config /opt/bosbase/Caddyfile
sudo caddy reload --config /opt/bosbase/Caddyfile
```

## Testing Tips

1. Run each script on a fresh VM snapshot (Ubuntu 22.04, Rocky Linux 9) to avoid cross-contamination.
2. Verify `docker compose ps` shows `bosbasedb-node` and `bosbase-node` healthy.
3. Confirm `systemctl status caddy` is active and certificates were issued (check `/var/lib/caddy/.local/share/caddy/acme`).
4. Hit `https://your-domain/_/` to confirm the admin UI loads via Caddy.

Following the instructions above ensures both shell installers provide a consistent end-to-end setup while honoring distribution-specific packaging differences.
