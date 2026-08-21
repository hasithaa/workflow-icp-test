#!/usr/bin/env bash
# Gives the console user the roles the workflows' human tasks are addressed to.
#
# Human tasks are role-gated: `awaitHumanTask("approveExpense", "APPROVER", …)` is visible
# only to a caller holding APPROVER. The ICP passes the *console user's* role names into the
# tunnel, and the seeded admin holds "Super Admin" and "Project Admin" — so without this the
# human-task views are correctly empty, which looks like a bug and is not one.
#
# In a real deployment an administrator does this in Access Control. There is no GraphQL
# mutation for creating roles, so this environment seeds them in the database. Idempotent.
#
# Usage: scripts/grant-task-roles.sh [ROLE ...]   (default: APPROVER OPS)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# One file drives both compose and these scripts. Without this a port set in .env moves
# where the containers publish but not where the scripts look, and bootstrap sits waiting
# on a console that is answering somewhere else.
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

: "${POSTGRES_SUPERUSER:=postgres}"
: "${ICP_DB_NAME:=icp_db}"
: "${GRANT_TO_GROUP:=Super Admins}"

roles=("$@")
[ ${#roles[@]} -gt 0 ] || roles=(APPROVER OPS)

for role in "${roles[@]}"; do
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" -q <<SQL
-- The role itself, in the same org as the shipped roles.
INSERT INTO roles_v2 (role_id, role_name, org_id, description)
SELECT gen_random_uuid()::text, '${role}', 1, 'Workflow task role (test environment)'
 WHERE NOT EXISTS (SELECT 1 FROM roles_v2 WHERE role_name = '${role}');

-- Granted to the group the console user belongs to, so its token carries the role.
INSERT INTO group_role_mapping (group_id, role_id)
SELECT g.group_id, r.role_id
  FROM user_groups g, roles_v2 r
 WHERE g.group_name = '${GRANT_TO_GROUP}' AND r.role_name = '${role}'
   AND NOT EXISTS (
        SELECT 1 FROM group_role_mapping m
         WHERE m.group_id = g.group_id AND m.role_id = r.role_id);
SQL
    echo "granted ${role} to '${GRANT_TO_GROUP}'"
done

echo
echo "Roles now held by '${GRANT_TO_GROUP}':"
docker compose exec -T postgres psql -qtAX -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" -c "
    SELECT string_agg(r.role_name, ', ' ORDER BY r.role_name)
      FROM group_role_mapping m
      JOIN user_groups g ON g.group_id = m.group_id
      JOIN roles_v2 r ON r.role_id = m.role_id
     WHERE g.group_name = '${GRANT_TO_GROUP}'"
echo "Sign in again (or let the token expire) so a new token carries them."
