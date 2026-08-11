#!/bin/bash

# Exit on error
set -e

# Postgres connection options (can be overridden by environment variables)
PG_USER="${PGUSER:-postgres}"
PG_HOST="${PGHOST:-}"
PG_PORT="${PGPORT:-}"
PG_DATABASE="${PGDATABASE:-postgres}"

# Command builder
PSQL_CMD=("psql")
if [ -n "$PG_HOST" ]; then
    PSQL_CMD+=("-h" "$PG_HOST")
fi
if [ -n "$PG_PORT" ]; then
    PSQL_CMD+=("-p" "$PG_PORT")
fi
PSQL_CMD+=("-U" "$PG_USER" "-d" "$PG_DATABASE")

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo "Error: psql command not found. Please install postgresql-client or ensure it is in your PATH."
    exit 1
fi

echo "=== Current Database Users ==="
"${PSQL_CMD[@]}" -c "\du"

echo ""
# Ask for user confirmation before making changes
read -p "Do you want to proceed with demoting all superusers (except 'postgres') to NOSUPERUSER? (y/N): " confirm
if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
    echo "Operation cancelled. No database users were modified."
    exit 0
fi

echo ""
echo "=== Demoting all superusers (except 'postgres') ==="

# Execute the PL/pgSQL block to alter roles
"${PSQL_CMD[@]}" -c "
DO \$\$
DECLARE
    r RECORD;
    demoted_count INT := 0;
BEGIN
    FOR r IN 
        SELECT rolname 
        FROM pg_roles 
        WHERE rolsuper 
          AND rolname <> 'postgres'
          AND rolname <> 'rdsadmin'
    LOOP
        RAISE NOTICE 'Demoting user % to NOSUPERUSER', r.rolname;
        EXECUTE 'ALTER ROLE ' || quote_ident(r.rolname) || ' NOSUPERUSER';
        demoted_count := demoted_count + 1;
    END LOOP;
    
    IF demoted_count = 0 THEN
        RAISE NOTICE 'No superusers (other than postgres) found to demote.';
    ELSE
        RAISE NOTICE 'Successfully demoted % superuser(s).', demoted_count;
    END IF;
END
\$\$;
"

echo ""
echo "=== Database Users After Demotion ==="
"${PSQL_CMD[@]}" -c "\du"
