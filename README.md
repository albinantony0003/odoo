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
| `db_user` | `erp18` | PostgreSQL user |
| `db_password` | *(set in file)* | PostgreSQL password |
| `xmlrpc_port` | `8069` | Odoo HTTP port |
| `proxy_mode` | `True` | **Required** when behind a reverse proxy — trusts `X-Forwarded-*` headers |

> `proxy_mode = True` must be set when using NPM/nginx, otherwise Odoo will not correctly detect HTTPS and generate broken URLs.

To enable multithreading (activates `/websocket` location), add to `odoo.conf`:

```ini
workers = 2
max_cron_threads = 1
```

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

**Location 3 — Websocket (only if workers/multithreading enabled in Odoo)**

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

> Port `8072` is the Odoo longpolling port. Make sure it is mapped in `docker-compose.yaml` (`8062:8072`).

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

## Rebuild Odoo Image

```bash
docker-compose build --no-cache
docker-compose up -d
```
