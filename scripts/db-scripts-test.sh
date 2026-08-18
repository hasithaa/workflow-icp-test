#!/usr/bin/env bash
# Tests the ICP SQL scripts against a real Postgres — both paths that ship:
#
#   fresh    postgresql_init.sql on an empty database
#   upgrade  a pre-workflow database, then add_workflow_feature_postgresql.sql
#
# and then asserts the two end states agree on everything the workflow feature adds. The
# "pre-workflow" database is made by initialising fresh and then *removing* the workflow
# parts, which is the only honest way to build one from a repo that no longer contains the
# older schema.
#
# This is the check that would have caught shipping a `bi_workflow_metadata` migration that
# nobody applied: without the table, every full heartbeat fails.
#
# Requires the postgres service to be running (scripts/bootstrap.sh does that).
# Usage: scripts/db-scripts-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

: "${POSTGRES_SUPERUSER:=postgres}"
: "${FRESH_DB:=icp_fresh_test}"
: "${UPGRADE_DB:=icp_upgrade_test}"

INIT_SQL=/opt/icp-db/postgresql_init.sql
MIGRATION_SQL=/opt/icp-db/add_workflow_feature_postgresql.sql

for f in artifacts/db/postgresql_init.sql artifacts/db/add_workflow_feature_postgresql.sql; do
    [ -f "$f" ] || { echo "missing $f - run scripts/build-artifacts.sh first" >&2; exit 1; }
done

psql_super() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" "$@"; }
in_db() { psql_super -d "$1" -qtAX -c "$2"; }
log() { printf '\n=== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

log "Recreating the two scratch databases"
psql_super -d postgres -q -c "DROP DATABASE IF EXISTS ${FRESH_DB}" -c "DROP DATABASE IF EXISTS ${UPGRADE_DB}"
psql_super -d postgres -q -c "CREATE DATABASE ${FRESH_DB}" -c "CREATE DATABASE ${UPGRADE_DB}"

# ── Path 1: fresh install ─────────────────────────────────────────────────────
log "fresh: applying postgresql_init.sql"
psql_super -d "$FRESH_DB" -q -f "$INIT_SQL" > /dev/null
echo "applied cleanly"

# ── Path 2: a pre-workflow database, then the migration ───────────────────────
log "upgrade: building a pre-workflow database"
psql_super -d "$UPGRADE_DB" -q -f "$INIT_SQL" > /dev/null
# Undo exactly what the workflow feature migration is responsible for adding.
psql_super -d "$UPGRADE_DB" -q <<'SQL' > /dev/null
DROP TABLE IF EXISTS bi_workflow_metadata;
ALTER TABLE runtimes DROP COLUMN IF EXISTS callback_url;
DELETE FROM role_permission_mapping
 WHERE permission_id IN (SELECT permission_id FROM permissions WHERE permission_name LIKE 'workflow_mgt:%');
DELETE FROM permissions WHERE permission_name LIKE 'workflow_mgt:%';
SQL
pre_meta=$(in_db "$UPGRADE_DB" "SELECT count(*) FROM information_schema.tables WHERE table_name='bi_workflow_metadata'")
pre_perms=$(in_db "$UPGRADE_DB" "SELECT count(*) FROM permissions WHERE permission_name LIKE 'workflow_mgt:%'")
[ "$pre_meta" = "0" ] || fail "the pre-workflow database still has bi_workflow_metadata"
[ "$pre_perms" = "0" ] || fail "the pre-workflow database still has workflow permissions"
echo "pre-workflow state confirmed: no table, no workflow permissions"

log "upgrade: applying add_workflow_feature_postgresql.sql"
psql_super -d "$UPGRADE_DB" -q -f "$MIGRATION_SQL" > /dev/null
echo "applied cleanly"

log "upgrade: applying it a second time (it claims to be idempotent)"
psql_super -d "$UPGRADE_DB" -q -f "$MIGRATION_SQL" > /dev/null
echo "re-ran cleanly"

# ── Compare the two end states ────────────────────────────────────────────────
log "Comparing the migrated database against a fresh install"
compare() {
    local what="$1" query="$2"
    local fresh upgraded
    fresh=$(in_db "$FRESH_DB" "$query")
    upgraded=$(in_db "$UPGRADE_DB" "$query")
    if [ "$fresh" = "$upgraded" ]; then
        printf '  ok    %-38s fresh=%s upgraded=%s\n' "$what" "$fresh" "$upgraded"
    else
        printf '  FAIL  %-38s fresh=%s upgraded=%s\n' "$what" "$fresh" "$upgraded"
        FAILED=1
    fi
}
FAILED=0

compare "bi_workflow_metadata columns" \
    "SELECT string_agg(column_name || ':' || data_type, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_name='bi_workflow_metadata'"
compare "bi_workflow_metadata primary key" \
    "SELECT string_agg(a.attname, ',' ORDER BY a.attname) FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=ANY(i.indkey) WHERE i.indrelid='bi_workflow_metadata'::regclass AND i.indisprimary"
compare "bi_workflow_metadata FK to runtimes" \
    "SELECT count(*) FROM information_schema.table_constraints WHERE table_name='bi_workflow_metadata' AND constraint_type='FOREIGN KEY'"
compare "runtimes.callback_url present" \
    "SELECT count(*) FROM information_schema.columns WHERE table_name='runtimes' AND column_name='callback_url'"
compare "workflow_mgt permissions" \
    "SELECT string_agg(permission_name, ',' ORDER BY permission_name) FROM permissions WHERE permission_name LIKE 'workflow_mgt:%'"
compare "workflow permission domain" \
    "SELECT count(*) FROM permissions WHERE permission_domain='Workflow-Management'"
compare "workflow role grants" \
    "SELECT count(*) FROM role_permission_mapping m JOIN permissions p USING (permission_id) WHERE p.permission_name LIKE 'workflow_mgt:%'"

# The regression this environment exists to prevent: heartbeat processing deletes the
# reporting runtime's metadata row before it checks whether the heartbeat carries any, so a
# missing table takes down every full heartbeat — MI runtimes included.
log "Checking the statement that heartbeat processing runs unconditionally"
if in_db "$UPGRADE_DB" "DELETE FROM bi_workflow_metadata WHERE runtime_id = 'no-such-runtime'" > /dev/null 2>&1; then
    echo "  ok    DELETE FROM bi_workflow_metadata succeeds on the migrated database"
else
    fail "the migrated database cannot serve a full heartbeat"
fi

if [ "$FAILED" -eq 0 ]; then
    log "PASS: a migrated database matches a fresh install on every workflow object"
else
    log "FAIL: differences above"
    exit 1
fi
