#!/bin/bash
# ============================================================
# Odoo Module Updater
# Updates a module across all databases owned by a given user
# ============================================================

# ---------- Configuration ----------
DB_USER="odoo12"
MODULE="ksa_zatca_integration"
DEPLOY_TYPE="onpremise"          # "docker" or "onpremise"

# Docker-specific settings (used when DEPLOY_TYPE=docker)
DOCKER_CONTAINER="erp18"
DOCKER_CONFIG="/etc/odoo/odoo.conf"

# On-premise settings (used when DEPLOY_TYPE=onpremise)
ONPREMISE_BIN="/usr/bin/odoo12-server"
ONPREMISE_CONFIG="/etc/default/odoo12-server.conf"
# -----------------------------------

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---- Validate DEPLOY_TYPE ----
if [[ "$DEPLOY_TYPE" != "docker" && "$DEPLOY_TYPE" != "onpremise" ]]; then
    error "DEPLOY_TYPE must be 'docker' or 'onpremise'. Got: '$DEPLOY_TYPE'"
    exit 1
fi

# ---- Fetch databases owned by DB_USER ----
log "Fetching databases owned by user '$DB_USER'..."

DATABASES=$(psql -U "$DB_USER" -d postgres -t -A -c \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false
       AND datname NOT IN ('postgres')
       AND pg_catalog.pg_get_userbyid(datdba) = '${DB_USER}'
     ORDER BY datname;" 2>/dev/null) || {
    error "Failed to connect to PostgreSQL as user '$DB_USER'. Check credentials and pg_hba.conf."
    exit 1
}

if [[ -z "$DATABASES" ]]; then
    warn "No databases found owned by '$DB_USER'. Nothing to update."
    exit 0
fi

DB_COUNT=$(echo "$DATABASES" | wc -l | tr -d ' ')
log "Found ${DB_COUNT} database(s): $(echo "$DATABASES" | tr '\n' ' ')"
echo ""

# ---- Run update for each database ----
SUCCESS=0
FAILED=0

for DB in $DATABASES; do
    echo -e "──────────────────────────────────────────"
    log "Updating module '${MODULE}' on database '${DB}'..."

    if [[ "$DEPLOY_TYPE" == "docker" ]]; then
        CMD="docker exec -i ${DOCKER_CONTAINER} odoo -c ${DOCKER_CONFIG} -u ${MODULE} -d ${DB} --stop-after-init"
    else
        CMD="${ONPREMISE_BIN} -c ${ONPREMISE_CONFIG} -u ${MODULE} -d ${DB} --stop-after-init"
    fi

    log "Running: $CMD"

    if $CMD; then
        log "${GREEN}SUCCESS${NC}: ${DB}"
        (( SUCCESS++ )) || true
    else
        error "FAILED: ${DB}"
        (( FAILED++ )) || true
    fi

    echo ""
done

# ---- Summary ----
echo -e "══════════════════════════════════════════"
log "Done. Success: ${SUCCESS} | Failed: ${FAILED} | Total: ${DB_COUNT}"

if (( FAILED > 0 )); then
    exit 1
fi
