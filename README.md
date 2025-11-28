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
git clone https://github.com/<your-org>/self-host.git
cd self-host
chmod +x install-ubuntu.sh
sudo ./install-ubuntu.sh --domain yourdomain.com --email you@example.com
```

- Pass `--openai-key`/`--openai-base-url` (or set env vars) if you want the installer to populate `.env`; otherwise you can edit `/opt/bosbase/.env` or the compose file later.
- The script will prompt for any values you do not pass via flags (domain, email, `BS_ENCRYPTION_KEY`).
- `--non-interactive` forces the script to fail when required values are missing instead of prompting.
- Assets are installed under `/opt/bosbase`, Docker + Caddy are installed if missing, and `docker-compose@bosbase.service` is enabled automatically.

### Rocky Linux 9.x

```bash
git clone https://github.com/<your-org>/self-host.git
cd self-host
chmod +x install-rocky.sh
sudo ./install-rocky.sh --domain yourdomain.com --email you@example.com
```

This installer mirrors the Ubuntu behavior, but uses `dnf`, enables the Caddy COPR, configures SELinux/firewalld, and manages the same `/opt/bosbase` layout. Add optional flags/env vars for OpenAI settings just like the Ubuntu installer.

### 1. Pull Docker Images

Pull the required Docker images from Docker Hub:

```bash
docker pull bosbasedb:vb1
docker pull bosbase:vb1
```

Or if the images are in a different registry:

```bash
docker pull <registry>/bosbasedb:vb1
docker pull <registry>/bosbase:vb1
```

### 2. Create Docker Compose File

Create a `docker-compose.yml` file in your working directory:

```yaml
version: "3.8"

services:
  bosbasedb-node:
    image: bosbase/bosbasedb:vb1
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
    image: bosbase/bosbase:vb1
    restart: unless-stopped
    environment:
      SASSPB_BOSBASEDB_URL: http://bosbasedb-node:4001
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      BS_ENCRYPTION_KEY: your-32-character-encryption-key-here
    ports:
      - "8090:8090"
    volumes:
      - ./bosbase-data:/pb/pb_data
    depends_on:
      - bosbasedb-node
    command: ["/pb/bosbase", "serve", "--http=0.0.0.0:8090", "--encryptionEnv", "BS_ENCRYPTION_KEY"]
```

**Important:** Generate a strong encryption key and replace `your-32-character-encryption-key-here`:

```bash
openssl rand -hex 32
```

### 3. Start the Services

Start the services using Docker Compose:

```bash
docker-compose up -d
```

This will start:
- **bosbasedb-node**: Single-node database database (port 4001)
- **bosbase-node**: BosBase application server (port 8090)

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
docker-compose down
```

To also remove volumes (⚠️ **deletes all data**):
```bash
docker-compose down -v
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

The single-node `docker-compose.yml` includes:

### Services

1. **bosbasedb-node**: database
   - Single-node configuration with `-bootstrap-expect=1`
   - Port: 4001 (internal)
   - Data: `./bosbasedb-node1-data`

2. **bosbase-node**: BosBase application
   - Connected to database via `SASSPB_BOSBASEDB_URL`
   - Port: 8090
   - Data: `./bosbase-data`

### Environment Variables

Key environment variables you can customize:

```yaml
environment:
  # database connection (for bosbase-node)
  SASSPB_BOSBASEDB_URL: http://bosbasedb-node:4001
  
  # Encryption key (32+ characters)
  BS_ENCRYPTION_KEY: your-encryption-key-here
  
  # Optional: Custom encryption env var name
  # SASSPB_ENCRYPTION_ENV: BS_ENCRYPTION_KEY
```

### Volumes

Data persistence is handled via Docker volumes:

- `./bosbasedb-node1-data` - database files
- `./bosbase-data` - BosBase application data (if using local storage)

**Important:** Make regular backups of these directories!

## Backup and Restore

### Backup

```bash
# Backup database data
docker exec $(docker-compose ps -q bosbasedb-node) tar czf - /bosbasedb/file > database-backup.tar.gz

# Backup bosbase data
docker exec $(docker-compose ps -q bosbase-node) tar czf - /pb/pb_data > bosbase-backup.tar.gz
```

Or use BosBase's built-in backup API:
```bash
curl -X POST http://localhost:8090/api/backups \
  -H "Authorization: Bearer YOUR_ADMIN_TOKEN" \
  -o backup.zip
```

### Restore

```bash
# Restore database
docker exec -i $(docker-compose ps -q bosbasedb-node) tar xzf - < database-backup.tar.gz

# Restore bosbase
docker exec -i $(docker-compose ps -q bosbase-node) tar xzf - < bosbase-backup.tar.gz
```

## Updating

To update to a new version:

```bash
docker-compose pull
docker-compose up -d
```

Or rebuild if using local builds:

```bash
docker-compose build
docker-compose up -d
```

## Monitoring and Logs

### View Logs

```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f bosbase-node
docker-compose logs -f bosbasedb-node
```

### Health Checks

```bash
# BosBase health
curl http://localhost:8090/api/health

# database status
curl http://localhost:4001/status
```

## Troubleshooting

### Port Already in Use

If port 8090 or 4001 is already in use:

```yaml
# In docker-compose.yml, change:
ports:
  - "8091:8090"  # Change 8090 to 8091
```

### Permission Issues

If you encounter permission errors:

```bash
sudo chown -R $USER:$USER bosbase-data bosbasedb-node1-data
```

### Database Connection Issues

Check if database is ready:

```bash
docker-compose logs bosbasedb-node | grep "node ready"
```

Wait for the message "node ready" before starting bosbase-node.

### Reset Everything

⚠️ **Warning: This deletes all data!**

```bash
docker-compose down -v
rm -rf bosbase-data bosbasedb-node1-data
docker-compose up -d
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
