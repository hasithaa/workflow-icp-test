#!/usr/bin/env bash
# Creates console users whose ROLE SETS DIFFER from the admin's and from each other.
#
# The point is not having more logins. The read cache keys an entry on the caller's role set,
# so users holding identical roles share one entry and prove nothing: the multi-user case
# only becomes observable when one view, requested by several users, must produce several
# entries. Three sets is the minimum that can catch a leak — with two, "everyone sees
# everything" and "roles work" look the same whenever both users can see the same task.
#
#   approver  APPROVER + Viewer      sees the expense human tasks (addressed to APPROVER)
#   ops       OPS + Viewer           must see NONE of them, and is the leak detector
#   tm1, tm2  APPROVER + Developer    both entitled to COMPLETE, for the two-users-one-task race
#   admin     Super Admin + …        sees everything, via the synthetic admin role
#
# Viewer and Developer are not interchangeable. Viewer carries workflow_mgt:view_human_tasks
# only, so `approver` can see a task and is refused when completing it — which is correct, and
# is why the race needs Developer (workflow_mgt:manage_human_tasks) instead. A race between a
# caller who may act and one who may not is not a race; it is an authorization check.
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
: "${OPS_USER:=ops}"
: "${OPS_PASSWORD:=ops123}"
: "${TM1_USER:=tm1}"
: "${TM1_PASSWORD:=tm1pass123}"
: "${TM2_USER:=tm2}"
: "${TM2_PASSWORD:=tm2pass123}"

CONSOLE="https://localhost:${CONSOLE_PORT}"

token=$(curl -sk -X POST "${CONSOLE}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ICP_ADMIN_USER}\",\"password\":\"${ICP_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import json,sys; print((json.load(sys.stdin).get("token") or ""))')
[ -n "$token" ] || { echo "could not sign in as ${ICP_ADMIN_USER}" >&2; exit 1; }

# A group of its own, so the approver's roles are independent of the admin's. Created in SQL
# because group creation and role creation are both administrative paths without mutations.
# One group per role set, so each user's roles are independent of the others'.
# Created in SQL because group creation and role creation have no mutations.
seed_group() {  # seed_group <group> <description> <role> [role ...]
    local group="$1" description="$2"; shift 2
    local roles="'$1'"; shift
    for role in "$@"; do roles="${roles}, '${role}'"; done

    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" -q <<SQL
INSERT INTO user_groups (group_id, group_name, org_uuid, description)
SELECT gen_random_uuid()::text, '${group}', 1, '${description}'
 WHERE NOT EXISTS (SELECT 1 FROM user_groups WHERE group_name = '${group}');

INSERT INTO roles_v2 (role_id, role_name, org_id, description)
SELECT gen_random_uuid()::text, v.name, 1, 'Workflow task role (test environment)'
  FROM (VALUES (${roles})) AS v(name)
 WHERE NOT EXISTS (SELECT 1 FROM roles_v2 WHERE role_name = v.name);

-- org_uuid is what makes a grant count. Permission checks are scope-matched (org, project,
-- environment, integration), and a mapping with every scope column NULL matches nothing: the
-- user signs in, holds the role by name, and is still refused with 403. The shipped
-- 'Super Admins' -> 'Super Admin' row is org-scoped, which is what to copy.
--
-- Note the two ideas that look alike here. Viewer is an ICP role carrying
-- workflow_mgt:view_human_tasks, which is what the ICP authorizes on. APPROVER and OPS carry
-- no permission at all -- they are role NAMES tunneled to the runtime, where the workflow's
-- awaitHumanTask("approveExpense", "APPROVER", ...) decides task eligibility from them. A
-- user needs Viewer to reach the page and APPROVER to see that task on it.
INSERT INTO group_role_mapping (group_id, role_id, org_uuid)
SELECT g.group_id, r.role_id, 1
  FROM user_groups g, roles_v2 r
 WHERE g.group_name = '${group}' AND r.role_name IN (${roles})
   AND NOT EXISTS (SELECT 1 FROM group_role_mapping m
                    WHERE m.group_id = g.group_id AND m.role_id = r.role_id);
SQL
}

# Uses the real endpoint, because the credential and the identity live in two different
# databases and a direct SQL insert populates only one of them.
create_user() {  # create_user <username> <password> <displayName> <group>
    local username="$1" password="$2" display="$3" group="$4" group_id status
    group_id=$(docker compose exec -T postgres psql -qtAX -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" \
        -c "SELECT group_id FROM user_groups WHERE group_name = '${group}'")
    group_id="${group_id//[[:space:]]/}"
    [ -n "$group_id" ] || { echo "group ${group} was not created" >&2; return 1; }

    status=$(curl -sk -o /tmp/create-user.out -w '%{http_code}' -X POST \
        "${CONSOLE}/auth/orgs/${ORG_HANDLE}/users" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${token}" \
        -d "{\"username\":\"${username}\",\"password\":\"${password}\",\"displayName\":\"${display}\",\"groupIds\":[\"${group_id}\"]}")

    case "$status" in
        201) echo "created ${username} / ${password} in '${group}'" ;;
        400) echo "note: ${username} already exists ($(cat /tmp/create-user.out))" ;;
        *)   echo "failed to create ${username} (HTTP ${status}): $(cat /tmp/create-user.out)" >&2; return 1 ;;
    esac
}

seed_group Approvers 'Holds APPROVER only (test environment)' APPROVER Viewer
seed_group Ops 'Holds OPS only -- the cross-role leak detector' OPS Viewer
seed_group 'Task Managers' 'APPROVER plus Developer: entitled to complete tasks' APPROVER Developer

create_user "$APPROVER_USER" "$APPROVER_PASSWORD" 'Task Approver' Approvers
create_user "$OPS_USER" "$OPS_PASSWORD" 'Ops Reviewer' Ops
create_user "$TM1_USER" "$TM1_PASSWORD" 'Task Manager One' 'Task Managers'
create_user "$TM2_USER" "$TM2_PASSWORD" 'Task Manager Two' 'Task Managers'

echo
echo "Roles per user:"
docker compose exec -T postgres psql -qtAX -U "$POSTGRES_SUPERUSER" -d "$ICP_DB_NAME" -c "
    SELECT u.username || ' -> ' || coalesce(string_agg(DISTINCT r.role_name, ', ' ORDER BY r.role_name), '(none)')
      FROM users u
      LEFT JOIN group_user_mapping gu ON gu.user_uuid = u.user_id
      LEFT JOIN group_role_mapping gr ON gr.group_id = gu.group_id
      LEFT JOIN roles_v2 r ON r.role_id = gr.role_id
     GROUP BY u.username ORDER BY u.username"
