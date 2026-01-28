# Self-Hosting Guide

This guide explains how to deploy BosBase as a standalone single-node installation using Docker Compose, with optional reverse proxy configuration using NGINX or Caddy.

## Prerequisites

- Docker and Docker Compose installed
- A server with at least 0.2G RAM and 1GB disk space
- Domain name (optional, for production deployments)

## Quick Start with Docker Compose

## One-Click Install Scripts

For freshly provisioned hosts you can run the bundled installers instead of performing every step manually.

### Ubuntu 22.04+

```bash
git clone https://github.com/bosbase/self-host.git
cd self-host
chmod +x install-ubuntu.sh
sudo ./install-ubuntu.sh --domain yourdomain.com --email you@example.com
```

- **Important:** `--openai-key`/`--openai-base-url` must be set if you want to use vector and LLM document features. Example:
  ```bash
  sudo ./install-ubuntu.sh --domain yourdomain.com --email you@example.com \
    --openai-key sk-xxxxx \
    --openai-base-url https://api.openai.com/v1
  ```
  You can also set these via environment variables (`OPENAI_API_KEY`, `OPENAI_BASE_URL`) or edit `/opt/bosbase/.env` later.
- The script will prompt for any values you do not pass via flags (domain, email, `BS_ENCRYPTION_KEY`).
- `--non-interactive` forces the script to fail when required values are missing instead of prompting.
- Assets are installed under `/opt/bosbase`, Docker + Caddy are installed if missing, and `docker-compose@bosbase.service` is enabled automatically.

### Rocky Linux 9.x

```bash
git clone https://github.com/bosbase/self-host.git
cd self-host
chmod +x install-rocky.sh
sudo ./install-rocky.sh --domain yourdomain.com --email you@example.com
```

This installer mirrors the Ubuntu behavior, but uses `dnf`, enables the Caddy COPR, configures SELinux/firewalld, and manages the same `/opt/bosbase` layout. 

**Note:** `--openai-key`/`--openai-base-url` must be set if you want to use vector and LLM document features. Example:
```bash
sudo ./install-rocky.sh --domain yourdomain.com --email you@example.com \
  --openai-key sk-xxxxx \
  --openai-base-url https://api.openai.com/v1
```

### 1. Pull Docker Images

Pull the required Docker images from Docker Hub:

```bash
docker pull pgvector/pgvector:pg16
docker pull bosbase/bosbase:ve1
```

### 2. Create Docker Compose File

Create a `docker-compose.yml` file in your working directory:

**docker-compose.db.yml (database):**

```yaml
services:
  postgres-db:
    image: pgvector/pgvector:pg16
    restart: unless-stopped
    environment:
      POSTGRES_DB: pbosbase
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
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
```

**docker-compose.yml (application):**

```yaml
services:
  bosbase-node:
    image: bosbase/bosbase:ve1
    restart: unless-stopped
    environment:
      SASSPB_POSTGRES_URL: postgres://postgres:postgres@postgres-db:5432/pbosbase?sslmode=disable
      BS_ENCRYPTION_KEY: your-32-character-encryption-key-here
      OPENAI_API_KEY: ${OPENAI_API_KEY:-sk-af61vU1kIT0uw5YzOM7VRM3KGrxBAfuhVgJX9ghtkHfdRVsu}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-https://api.chatanywhere.org/v1}
      PB_ACTIVATION_VERIFY_URL: ${PB_ACTIVATION_VERIFY_URL:-https://ve.bosbase.com/verify}
      # REDIS_URL: ${REDIS_URL:-192.168.1.60:6379}
      # REDIS_PASSWORD: ${REDIS_PASSWORD:-}
      WASM_ENABLE: ${WASM_ENABLE:-true}
      WASM_INSTANCE_NUM: ${WASM_INSTANCE_NUM:-32}
      SCRIPT_CONCURRENCY: ${SCRIPT_CONCURRENCY:-32}
      FUNCTION_CONN_NUM: ${FUNCTION_CONN_NUM:-10}
      EXECUTE_PATH: ${EXECUTE_PATH:-/pb/functions}
      # BOOSTER_PATH: ${BOOSTER_PATH:-/pb/booster-wasm}
      # BOOSTER_POOL_MAX: ${BOOSTER_POOL_MAX:-2}
      # BOOSTER_WASMTIME_MEMORY_GUARD_SIZE: ${BOOSTER_WASMTIME_MEMORY_GUARD_SIZE:-65536}
      # BOOSTER_WASMTIME_MEMORY_RESERVATION: ${BOOSTER_WASMTIME_MEMORY_RESERVATION:-0}
      # BOOSTER_WASMTIME_MEMORY_RESERVATION_FOR_GROWTH: ${BOOSTER_WASMTIME_MEMORY_RESERVATION_FOR_GROWTH:-1048576}
      PB_DATA_MAX_OPEN_CONNS: ${PB_DATA_MAX_OPEN_CONNS:-30}
      PB_DATA_MAX_IDLE_CONNS: ${PB_DATA_MAX_IDLE_CONNS:-15}
      PB_AUX_MAX_OPEN_CONNS: ${PB_AUX_MAX_OPEN_CONNS:-10}
      PB_AUX_MAX_IDLE_CONNS: ${PB_AUX_MAX_IDLE_CONNS:-3}
      PB_QUERY_TIMEOUT: ${PB_QUERY_TIMEOUT:-300s}
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
```

**Important:** Generate a strong encryption key and replace `your-32-character-encryption-key-here`:

```bash
openssl rand -hex 16
```

Create a `.env` file for environment variables:

```bash
OPENAI_API_KEY=sk-your-key-here
OPENAI_BASE_URL=https://api.openai.com/v1
```

### 3. Start the Services

Start the services using Docker Compose:

```bash
docker compose -f docker-compose.db.yml up -d
docker compose -f docker-compose.yml up -d
```

This will start:
- **postgres-db**: PostgreSQL database with pgvector extension (port 5432)
- **bosbase-node**: BosBase application server (ports 8090, 2678)

### 4. Access the Application

- **Admin UI**: http://localhost:8090/_/
- **API**: http://localhost:8090/api/

Create your first admin user by accessing the admin UI and following the setup wizard.

Alternatively, create a superuser via command line:

```bash
docker exec docker-bosbase-node-1 /pb/bosbase superuser upsert yourloginemail yourpassword
```

### 5. Stop the Services

```bash
docker compose -f docker-compose.yml down
docker compose -f docker-compose.db.yml down
```

To also remove volumes (⚠️ **deletes all data**):
```bash
docker compose -f docker-compose.yml down -v
docker compose -f docker-compose.db.yml down -v
```

## Reverse Proxy Configuration

For production deployments, it's recommended to use a reverse proxy (NGINX or Caddy) to:
- Handle SSL/TLS certificates
- Provide a custom domain
- Add security headers
- Enable load balancing (if scaling later)

### Option 1: NGINX Reverse Proxy

#### 1. Install NGINX

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install nginx

# CentOS/RHEL
sudo yum install nginx
```

#### 2. Create NGINX Configuration

Create `/etc/nginx/sites-available/bosbase` (or `/etc/nginx/conf.d/bosbase.conf` on CentOS):

```nginx
server {
    listen 80;
    server_name yourdomain.com www.yourdomain.com;

    # Redirect HTTP to HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name yourdomain.com www.yourdomain.com;

    # SSL Certificate (use Let's Encrypt)
    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    
    # SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;

    # Proxy Settings
    client_max_body_size 50M;
    proxy_read_timeout 300s;
    proxy_connect_timeout 75s;

    location / {
        proxy_pass http://localhost:8090;
        proxy_http_version 1.1;
        
        # WebSocket support (for realtime subscriptions)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Standard proxy headers
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        # Disable buffering for realtime features
        proxy_buffering off;
    }
}
```

#### 3. Enable the Site

```bash
# Ubuntu/Debian
sudo ln -s /etc/nginx/sites-available/bosbase /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# CentOS/RHEL
sudo nginx -t
sudo systemctl reload nginx
```

#### 4. Obtain SSL Certificate with Let's Encrypt

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
```

Certbot will automatically configure NGINX and set up auto-renewal.

### Option 2: Caddy Reverse Proxy

Caddy automatically handles SSL certificates and is easier to configure.

#### 1. Install Caddy

```bash
# Ubuntu/Debian
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy

# Or use the official installer
curl https://getcaddy.com | bash
```

#### 2. Create Caddyfile

Create `/etc/caddy/Caddyfile`:

```caddy
yourdomain.com {
    reverse_proxy localhost:8090 {
        # WebSocket support
        header_up Upgrade {http.upgrade}
        header_up Connection {http.connection}
        
        # Standard headers
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    
    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "no-referrer-when-downgrade"
    }
    
    # File upload size limit
    reverse_proxy localhost:8090 {
        transport http {
            max_conns_per_host 0
        }
    }
}

www.yourdomain.com {
    redir https://yourdomain.com{uri} permanent
}
```

#### 3. Start Caddy

```bash
sudo systemctl enable caddy
sudo systemctl start caddy
```

Caddy will automatically:
- Obtain SSL certificates from Let's Encrypt
- Configure HTTPS
- Renew certificates automatically

## Docker Compose Configuration

The single-node setup includes two compose files:

### Services

1. **postgres-db**: PostgreSQL database with pgvector extension
   - Image: pgvector/pgvector:pg16
   - Port: 5432
   - Data: `./postgres-data`
   - Health check enabled

2. **bosbase-node**: BosBase application
   - Image: bosbase/bosbase:ve1
   - Connected to PostgreSQL via `SASSPB_POSTGRES_URL`
   - Ports: 8090 (main API), 2678 (additional service)
   - Data: `./bosbase-data`, `./pb_hooks`

### Environment Variables

Key environment variables you can customize:

```yaml
environment:
  # PostgreSQL connection (for bosbase-node)
  SASSPB_POSTGRES_URL: postgres://postgres:postgres@postgres-db:5432/pbosbase?sslmode=disable

  # Encryption key (32 hex characters)
  BS_ENCRYPTION_KEY: your-encryption-key-here

  # OpenAI API (optional, for vector and LLM features)
  OPENAI_API_KEY: sk-your-key-here
  OPENAI_BASE_URL: https://api.openai.com/v1

  # Activation verification
  PB_ACTIVATION_VERIFY_URL: https://ve.bosbase.com/verify

  # Optional: Redis configuration
  # REDIS_URL: 192.168.1.60:6379
  # REDIS_PASSWORD:

  # WASM and Script execution
  WASM_ENABLE: true
  WASM_INSTANCE_NUM: 32
  SCRIPT_CONCURRENCY: 32
  FUNCTION_CONN_NUM: 10
  EXECUTE_PATH: /pb/functions

  # Optional: Booster configuration
  # BOOSTER_PATH: /pb/booster-wasm
  # BOOSTER_POOL_MAX: 2
  # BOOSTER_WASMTIME_MEMORY_GUARD_SIZE: 65536
  # BOOSTER_WASMTIME_MEMORY_RESERVATION: 0
  # BOOSTER_WASMTIME_MEMORY_RESERVATION_FOR_GROWTH: 1048576

  # Database connection pool settings
  PB_DATA_MAX_OPEN_CONNS: 30
  PB_DATA_MAX_IDLE_CONNS: 15
  PB_AUX_MAX_OPEN_CONNS: 10
  PB_AUX_MAX_IDLE_CONNS: 3
  PB_QUERY_TIMEOUT: 300s
```

### Volumes

Data persistence is handled via Docker volumes:

- `./postgres-data` - PostgreSQL database files with pgvector
- `./bosbase-data` - BosBase application data
- `./pb_hooks` - Custom hooks directory (preserved on reinstall)

**Important:** Make regular backups of these directories!

## Backup and Restore

### Backup

```bash
# Backup PostgreSQL database
docker exec $(docker compose -f docker-compose.db.yml ps -q postgres-db) pg_dump -U postgres pbosbase > database-backup.sql

# Or backup entire data directory
docker exec $(docker compose -f docker-compose.db.yml ps -q postgres-db) tar czf - /var/lib/postgresql/data > postgres-backup.tar.gz

# Backup bosbase data
docker exec $(docker compose -f docker-compose.yml ps -q bosbase-node) tar czf - /pb/pb_data > bosbase-backup.tar.gz
```

Or use BosBase's built-in backup API:
```bash
curl -X POST http://localhost:8090/api/backups \
  -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  -o backup.zip
```

### Restore

```bash
# Restore PostgreSQL database
docker exec -i $(docker compose -f docker-compose.db.yml ps -q postgres-db) psql -U postgres -d pbosbase < database-backup.sql

# Restore bosbase
docker exec -i $(docker compose -f docker-compose.yml ps -q bosbase-node) tar xzf - < bosbase-backup.tar.gz
```

## Updating

To update to a new version:

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
```

Or rebuild if using local builds:

```bash
docker compose -f docker-compose.yml build
docker compose -f docker-compose.yml up -d
```

## Monitoring and Logs

### View Logs

```bash
# All services
docker compose -f docker-compose.yml logs -f
docker compose -f docker-compose.db.yml logs -f

# Specific service
docker compose -f docker-compose.yml logs -f bosbase-node
docker compose -f docker-compose.db.yml logs -f postgres-db
```

### Health Checks

```bash
# BosBase health
curl http://localhost:8090/api/health

# PostgreSQL health
docker exec $(docker compose -f docker-compose.db.yml ps -q postgres-db) pg_isready -U postgres -d pbosbase
```

## Troubleshooting

### Port Already in Use

If port 8090, 2678, or 5432 is already in use:

```yaml
# In docker-compose.yml or docker-compose.db.yml, change:
ports:
  - "8091:8090"  # Change 8090 to 8091
  - "5433:5432"  # Change 5432 to 5433
```

### Permission Issues

If you encounter permission errors:

```bash
sudo chown -R $USER:$USER bosbase-data postgres-data pb_hooks
```

### Database Connection Issues

Check if database is ready:

```bash
docker compose -f docker-compose.db.yml logs postgres-db | grep "ready to accept connections"
```

Wait for the message "ready to accept connections" before accessing bosbase-node.

### Reset Everything

⚠️ **Warning: This deletes all data!**

```bash
docker compose -f docker-compose.yml down -v
docker compose -f docker-compose.db.yml down -v
rm -rf bosbase-data postgres-data pb_hooks
docker compose -f docker-compose.db.yml up -d
docker compose -f docker-compose.yml up -d
```

## Production Recommendations

1. **Use Environment Variables**: Store sensitive keys in `.env` files (not in git)
2. **Enable Backups**: Set up automated backups using cron or a backup service
3. **Monitor Resources**: Use tools like `docker stats` or monitoring services
4. **Keep Updated**: Regularly update Docker images and dependencies
5. **Use Reverse Proxy**: Always use NGINX or Caddy with SSL in production
6. **Firewall**: Only expose ports 80 and 443 (via reverse proxy), not 8090 directly
7. **Resource Limits**: Add resource limits in docker-compose.yml:

```yaml
services:
  bosbase-node:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 1G
        reservations:
          cpus: '1'
          memory: 1G
```

## Support

For issues and questions:
- Check the [main README.md](README.md)
- Review Docker Compose logs
- Check doc.bosbase.com

## Next Steps

- Configure your first collection in the Admin UI
- Set up authentication and user management
- Configure file storage (S3 recommended for production)
- Review API documentation
