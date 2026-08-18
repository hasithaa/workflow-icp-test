#!/usr/bin/env bash
# Applies the ICP's real Postgres init scripts, staged into /opt/icp-db by
# scripts/build-artifacts.sh. Running the shipped scripts — rather than copies maintained
# here — is what makes bringing this environment up a test of them.
#
# Two databases, because the server opens two connections:
#   icp_db          the control plane's own schema
#   credentials_db  the default auth backend's user store, including the seeded admin
#
# The credentials client sets no schema, so its tables have to be reachable on the default
# search_path of the database named by credentialsDbName — hence a separate database rather
# than a `credentials` schema inside icp_db.
set -euo pipefail

echo "[initdb] applying postgresql_init.sql to ${POSTGRES_DB}"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /opt/icp-db/postgresql_init.sql

echo "[initdb] creating credentials_db and applying credentials_postgresql_init.sql"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c "CREATE DATABASE credentials_db OWNER icp_user"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d credentials_db -f /opt/icp-db/credentials_postgresql_init.sql
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d credentials_db \
    -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO icp_user" \
    -c "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO icp_user" \
    -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO icp_user"
