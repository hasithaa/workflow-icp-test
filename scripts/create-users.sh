#!/usr/bin/env bash
# Creates a second console user whose ROLES DIFFER from the admin's.
#
# The point is not having two logins. The read cache keys an entry on the caller's role set,
# so two users with identical roles share a cache entry and prove nothing: the multi-user
# case only becomes observable when the same view, requested by two users, must produce two
# entries. This creates an approver who holds APPROVER but not Super Admin.
#
# Uses the real endpoint (POST /auth/orgs/<handle>/users), which writes the credential to the
# credentials database and the identity to the main one -- the two-store split that direct
# SQL inserts get wrong. Roles still need SQL: there is no mutation for creating a role.
#
# Usage: scripts/create-users.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

: "${CONSOLE_PORT:=9446}"
: "${ICP_ADMIN_USER:=admin}"
: "${ICP_ADMIN_PASSWORD:=admin}"
: "${POSTGRES_SUPERUSER:=postgres}"
: "${ICP_DB_NAME:=icp_db}"
: "${ORG_HANDLE:=default}"
: "${APPROVER_USER:=approver}"
: "${APPROVER_PASSWORD:=approver123}"

CONSOLE="https://localhost:${CONSOLE_PORT}"

token=$(curl -sk -X POST "${CONSOLE}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ICP_ADMIN_USER}\",\"password\":\"${ICP_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("token") or ""))')
[ -n "$token" ] || { echo "could not sign in as ${ICP_ADMIN_USER}" >&2; exit 1; }

# A group of its own, so the approver's roles are independent of the admin's. Created in SQL
# because group creation and role creation are both administrative paths without mutations.
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" -q <<SQL
INSERT INTO user_groups (group_id, group_name, org_uuid, description)
SELECT gen_random_uuid()::text, 'Approvers', 1, 'Holds APPROVER only (test environment)'
 WHERE NOT EXISTS (SELECT 1 FROM user_groups WHERE group_name = 'Approvers');

INSERT INTO roles_v2 (role_id, role_name, org_id, description)
SELECT gen_random_uuid()::text, 'APPROVER', 1, 'Workflow task role (test environment)'
 WHERE NOT EXISTS (SELECT 1 FROM roles_v2 WHERE role_name = 'APPROVER');

-- org_uuid is what makes a grant count. Permission checks are scope-matched (org, project,
-- environment, integration), and a mapping with every scope column NULL matches nothing: the
-- user signs in, holds the role by name, and is still refused with 403. The shipped
-- 'Super Admins' -> 'Super Admin' row is org-scoped, which is what to copy.
--
-- Note the two ideas that look alike here. Viewer is an ICP role carrying
-- workflow_mgt:view_human_tasks, which is what the ICP authorizes on. APPROVER carries no
-- permission at all -- it is a role NAME tunneled to the runtime, where the workflow's
-- awaitHumanTask("approveExpense", "APPROVER", ...) decides task eligibility from it. A user
-- needs Viewer to reach the page and APPROVER to see the task on it.
INSERT INTO group_role_mapping (group_id, role_id, org_uuid)
SELECT g.group_id, r.role_id, 1
  FROM user_groups g, roles_v2 r
 WHERE g.group_name = 'Approvers' AND r.role_name IN ('APPROVER', 'Viewer')
   AND NOT EXISTS (SELECT 1 FROM group_role_mapping m
                    WHERE m.group_id = g.group_id AND m.role_id = r.role_id);
SQL

group_id=$(docker compose exec -T postgres psql -qtAX -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" \
    -c "SELECT group_id FROM user_groups WHERE group_name = 'Approvers'")

status=$(curl -sk -o /tmp/create-user.out -w '%{http_code}' -X POST \
    "${CONSOLE}/auth/orgs/${ORG_HANDLE}/users" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${token}" \
    -d "{\"username\":\"${APPROVER_USER}\",\"password\":\"${APPROVER_PASSWORD}\",\"displayName\":\"Task Approver\",\"groupIds\":[\"${group_id}\"]}")

case "$status" in
    201) echo "created ${APPROVER_USER} / ${APPROVER_PASSWORD} in 'Approvers'" ;;
    400) echo "note: ${APPROVER_USER} already exists ($(cat /tmp/create-user.out))" ;;
    *)   echo "failed to create user (HTTP ${status}): $(cat /tmp/create-user.out)" >&2; exit 1 ;;
esac

echo
echo "Roles per user:"
docker compose exec -T postgres psql -qtAX -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" -c "
    SELECT u.username || ' -> ' || coalesce(string_agg(DISTINCT r.role_name, ', ' ORDER BY r.role_name), '(none)')
      FROM users u
      LEFT JOIN group_user_mapping gu ON gu.user_uuid = u.user_id
      LEFT JOIN group_role_mapping gr ON gr.group_id = gu.group_id
      LEFT JOIN roles_v2 r ON r.role_id = gr.role_id
     GROUP BY u.username ORDER BY u.username"
