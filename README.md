# Odoo  Docker Setup

This project runs Odoo behind Nginx Proxy Manager using Docker, with PostgreSQL installed directly on the host machine.

## Project Structure

```
.
├── odoo/
│   ├── Dockerfile                  # Odoo image build file
│   ├── docker-compose.yaml         # Odoo service
│   ├── config/
│   │   └── odoo.conf               # Odoo configuration
│   ├── custom-addons/              # Custom Odoo modules
│   ├── extra-addons/               # Extra Odoo modules
│   └── odoo-data/                  # Persistent Odoo data
└── nginx/
    └── docker-compose.yaml         # Nginx Proxy Manager service
```

## Network Architecture

```
Internet
   │
   ▼
Nginx Proxy Manager (nginx-proxy)   :80 / :443
   │
   │  [odoo-network]
   ├──► Odoo instance 1 (odoo12)    :8069
   └──► Odoo instance 2 (odoo14)    :8069  (future)
           │
           │  host-gateway
           ▼
   PostgreSQL (host machine)        :5432
       ├── user: odoo12
       └── user: odoo14  (future)
```

Odoo containers connect to the host PostgreSQL via the `odoo-network` gateway IP `172.18.0.1`.

## Why Standalone Host PostgreSQL?

- One PostgreSQL installation serves all Odoo instances
- Each Odoo instance uses its own PostgreSQL user and databases
- No extra container overhead — PostgreSQL runs natively for better performance
- Centralized backups and maintenance

## Prerequisites

- Docker and Docker Compose installed
- PostgreSQL installed on the host machine
- Host PostgreSQL configured to accept connections from Docker containers

### Configure PostgreSQL on the Host

**1. Allow Docker network connections in `pg_hba.conf`:**

```
# Allow only the odoo-network subnet
host    all             odoo12          172.18.0.0/24           md5
```

**2. Set PostgreSQL to listen on localhost and Docker bridge in `postgresql.conf`:**

```
listen_addresses = 'localhost,172.18.0.1'
```

> Avoids exposing PostgreSQL on public interfaces. `172.18.0.1` is the `odoo-network` gateway.

> **Reboot issue:** After a machine restart, PostgreSQL may fail to bind `172.18.0.1` because the Docker bridge doesn't exist yet when PostgreSQL starts. Fix this by making PostgreSQL start after Docker using systemd ordering (see [Fix PostgreSQL connection after reboot](#fix-postgresql-connection-after-reboot) below).

**3. Restart PostgreSQL:**

```bash
sudo systemctl restart postgresql
```

**4. Create a user for each Odoo instance:**

```bash
sudo -u postgres psql -c "CREATE USER odoo12 WITH PASSWORD 'C8WNhJ4reXm' CREATEDB;"
```

> Repeat with a different username for each new Odoo instance.

## Services

### Odoo (`docker-compose.yaml`)

| Property | Value |
|---|---|
| Container | `odoo12` |
| Build | `./Dockerfile` |
| DB Host | `172.18.0.1` (`odoo-network` gateway) |
| DB Port | `5432` |
| Network | `odoo-network` (external) |

### Odoo Configuration (`odoo/config/odoo.conf`)

| Option | Value | Description |
|---|---|---|
| `addons_path` | `/mnt/extra-addons,/mnt/custom-addons` | Module search paths |
| `admin_passwd` | *(set in file)* | Master password for database operations |
| `db_host` | `172.18.0.1` | **Required** — forces TCP connection to host PostgreSQL. Without this, Odoo tries a Unix socket and fails with `No such file or directory` |
| `db_port` | `5432` | PostgreSQL port |
| `db_user` | `erp18` | PostgreSQL user |
| `db_password` | *(set in file)* | PostgreSQL password |
| `xmlrpc_port` | `8069` | Odoo HTTP port |
| `proxy_mode` | `True` | **Required** when behind a reverse proxy — trusts `X-Forwarded-*` headers |
| `workers` | `2` | Enables multi-process mode and activates the `/websocket` endpoint for real-time features |
| `max_cron_threads` | `1` | Number of threads dedicated to scheduled actions |

> `proxy_mode = True` must be set when using NPM/nginx, otherwise Odoo will not correctly detect HTTPS and generate broken URLs.

> `workers` must be set for real-time features (Discuss, live chat) to work. Without it, Odoo runs in single-threaded mode and the `/websocket` route is unavailable, causing a "Real-time connection lost" error.

**Verify workers are running:**

```bash
docker exec erp18 ps aux | grep odoo
```

You should see multiple `odoo` worker processes. If you only see one, the workers setting is not taking effect — check the config is mounted correctly and restart the container.

### Nginx Proxy Manager (`nginx/docker-compose.yaml`)

| Property | Value |
|---|---|
| Container | `nginx-proxy` |
| Image | `jc21/nginx-proxy-manager:latest` |
| Ports | `80` (HTTP), `81` (Admin UI), `443` (HTTPS) |
| Network | `odoo-network` (external) |

## Getting Started

**Step 1 — Create a system user for Odoo:**

```bash
useradd -m -d /home/username -U -r -s /bin/bash username
```

> Replace `username` with your desired user (e.g. `odoo`). The `-r` flag creates a system account, `-U` creates a matching group.

**Step 2 — Create the Docker network** (once only):

```bash
docker network create odoo-network
```

**Step 3 — Build and start Odoo:**

```bash
docker-compose up -d --build
```

**Step 4 — Start Nginx Proxy Manager:**

```bash
cd nginx
docker-compose up -d
```

**Step 5 — Configure NPM to route traffic to Odoo:**

**4.1 — First login**

1. Open `http://<your-server-ip>:81`
2. Log in with the default credentials:
   - Email: `admin@example.com`
   - Password: `changeme`
3. You will be prompted to change the email and password — do this immediately

**4.2 — Add a Proxy Host**

1. Go to **Hosts → Proxy Hosts** in the top menu
2. Click **Add Proxy Host**
3. Fill in the **Details** tab:

| Field | Value |
|---|---|
| Domain Names | `yourdomain.com` |
| Scheme | `http` |
| Forward Hostname | `erp18` |
| Forward Port | `8069` |
| Cache Assets | Off |
| Block Common Exploits | On |
| Websockets Support | **On** |

4. Click the **SSL** tab:

| Field | Value |
|---|---|
| SSL Certificate | Request a new SSL Certificate |
| Force SSL | On |
| HTTP/2 Support | On |
| HSTS Enabled | On |

5. Enter your email for Let's Encrypt and accept the terms

**4.3 — Custom Locations**

Click the **Custom Locations** tab and add the following three locations:

---

**Location 1 — Main proxy**

| Field | Value |
|---|---|
| Location | `/` |
| Scheme | `http` |
| Forward Hostname | `erp18` |
| Forward Port | `8069` |

Custom config (paste into the text box):

```nginx
proxy_redirect          off;
proxy_set_header        X-Forwarded-Host    $host;
proxy_set_header        X-Real-IP           $remote_addr;
proxy_set_header        X-Forwarded-For     $proxy_add_x_forwarded_for;
proxy_set_header        X-Forwarded-Proto   https;
proxy_http_version      1.1;
proxy_set_header        Upgrade             $http_upgrade;
proxy_set_header        Connection          "upgrade";
```

---

**Location 2 — Static file caching**

| Field | Value |
|---|---|
| Location | `~* /web/static/` |
| Scheme | `http` |
| Forward Hostname | `erp18` |
| Forward Port | `8069` |

Custom config:

```nginx
proxy_cache_valid   200 60m;
proxy_buffering     on;
expires             864000;
```

---

**Location 3 — Websocket (only needed when `workers` is enabled in `odoo.conf`)**

| Field | Value |
|---|---|
| Location | `/websocket` |
| Scheme | `http` |
| Forward Hostname | `erp18` |
| Forward Port | `8072` |

Custom config:

```nginx
proxy_set_header    Upgrade     $http_upgrade;
proxy_set_header    Connection  "upgrade";
```

> Port `8072` is the Odoo gevent/longpolling port used in multi-process mode. Make sure it is mapped in `docker-compose.yaml` (`8062:8072`).

> **Without `workers`:** Odoo handles WebSocket on port `8069` (threaded mode). Do **not** add Location 3 — Location 1 (`/` → `8069`) already includes WebSocket upgrade headers and will handle `/websocket` correctly. Adding Location 3 when workers are disabled will cause a "Real-time connection lost" error because nothing is listening on `8072`.

> We can check the workers status by running `docker exec erp18 ps aux | grep odoo`.

**WebSocket configuration matrix:**

| `workers` in odoo.conf | Location 3 in NPM | Result |
|---|---|---|
| No | No | ✅ Works — Location 1 handles `/websocket` on port `8069` |
| No | Yes | ❌ Broken — routes `/websocket` to `8072`, nothing listening |
| Yes | No | ❌ Broken — `/websocket` hits `8069`, workers expect `8072` |
| Yes | Yes | ✅ Works — correctly routes to gevent worker on `8072` |

---

6. Click **Save**

NPM will obtain a free SSL certificate and begin routing `yourdomain.com` → `erp18:8069` through `odoo-network`.

## Adding a New Odoo Instance

1. Copy the project folder for the new instance (e.g. `odoo14/`)
2. Create a dedicated PostgreSQL user on the host:
```bash
sudo -u postgres psql -c "CREATE USER odoo14 WITH PASSWORD 'newpassword' CREATEDB;"
```
3. Update its `docker-compose.yaml` — new container name, port mapping, and DB credentials
4. Run `docker-compose up -d --build` inside that folder
5. Add a new Proxy Host in NPM pointing to the new container name

## Update an Odoo Module

To update a module (e.g. `web`) without restarting the full container:

```bash
docker exec -it erp18 odoo -c /etc/odoo/odoo.conf -u web -d <your_database_name> --stop-after-init
```

Replace `<your_database_name>` with your actual database name. If you don't know it, list databases first:

```bash
docker exec -it erp18 psql -h 172.18.0.1 -U erp18 -l
```

After the update completes, restart the container:

```bash
docker-compose restart
```

## Rebuild Odoo Image

```bash
docker-compose build --no-cache
docker-compose up -d
```

## Fix PostgreSQL Connection After Reboot

After a reboot, PostgreSQL may refuse connections from Odoo with:

```
connection to server at "172.18.0.1", port 5432 failed: Connection refused
```

**Root cause:** PostgreSQL is configured to listen on `172.18.0.1` (the Docker bridge IP), but that interface only exists after Docker creates the `odoo-network` bridge. Since PostgreSQL starts before Docker on boot, it fails to bind that IP and only listens on `localhost`.

**Fix — wait for the Docker bridge IP to appear before PostgreSQL starts:**

> On Ubuntu/Debian, `postgresql.service` is just a meta wrapper. The actual cluster runs as `postgresql@17-main.service`. The drop-in must go in `postgresql@.service.d` (with `@`) to apply to the real instance.

**1. Create the drop-in file:**

```bash
sudo mkdir -p /etc/systemd/system/postgresql@.service.d
sudo nano /etc/systemd/system/postgresql@.service.d/wait-docker-bridge.conf
```

```ini
[Unit]
After=docker.service
Wants=docker.service

[Service]
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do ip addr | grep -q 172.18.0.1 && break; sleep 1; done'
```

**2. Reload systemd:**

```bash
sudo systemctl daemon-reload
```

> `ExecStartPre` polls for `172.18.0.1` every second for up to 30 seconds before allowing PostgreSQL to start.
