#!/usr/bin/env bash
# Drives the workflow features through the ICP's own HTTP API — no browser — so a run
# either proves the tunnel works end to end across the network boundary or says where it
# stopped.
#
# What it asserts, in order:
#   1. both integrations registered, with as many runtimes as there are replicas
#   2. each was promoted to a workflow integration (display_type ballerinaWorkflow)
#   3. definitions come from stored metadata, listed per integration
#   4. a workflow starts through the tunnel and reaches RUNNING
#   5. its human task is listed, completed through the tunnel, and the workflow finishes
#   6. lifecycle: an event-parked instance suspends, resumes and terminates
#   7. an offline integration answers 503 rather than serving stale data (--include-offline)
#
# Usage: scripts/smoke.sh [--include-offline]
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

: "${CONSOLE_PORT:=9446}"
: "${ICP_ADMIN_USER:=admin}"
: "${ICP_ADMIN_PASSWORD:=admin}"
: "${ICP_ENVIRONMENT_ID:=750e8400-e29b-41d4-a716-446655440001}"
: "${EXPECTED_RUNTIMES:=1}"

CONSOLE="https://localhost:${CONSOLE_PORT}"
INCLUDE_OFFLINE=0
[ "${1:-}" = "--include-offline" ] && INCLUDE_OFFLINE=1

PASS=0 FAIL=0
log() { printf '\n=== %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

token=$(curl -sk -X POST "${CONSOLE}/auth/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ICP_ADMIN_USER}\",\"password\":\"${ICP_ADMIN_PASSWORD}\"}" \
    | jqp 'd.get("token","")')
[ -n "$token" ] || { echo "login failed" >&2; exit 1; }

wf() {  # wf <METHOD> <component> <path> [body]
    local method="$1" component="$2" path="$3" body="${4:-}"
    if [ -n "$body" ]; then
        curl -sk -o /tmp/wf.out -w '%{http_code}' -X "$method" \
            "${CONSOLE}/icp/workflow/${component}/${ICP_ENVIRONMENT_ID}/${path}" \
            -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" -d "$body"
    else
        curl -sk -o /tmp/wf.out -w '%{http_code}' -X "$method" \
            "${CONSOLE}/icp/workflow/${component}/${ICP_ENVIRONMENT_ID}/${path}" \
            -H "Authorization: Bearer ${token}"
    fi
}

# The tunnel is asynchronous, and these two helpers are what that means for a caller.
#
# No request waits on a runtime. A read is accepted with 202 {"status":"FETCHING"} and
# answered once some node's next heartbeat claims the fetch and posts the result; a mutation
# is accepted with 202 {"operationId"} and its outcome is collected from operations/<id>.
# Polling is therefore the contract, not a workaround for slowness -- asserting on the first
# response tests the 202 and nothing else. Both helpers keep `wf`'s interface: the body lands
# in /tmp/wf.out and the final HTTP code is printed, so assertions stay as they were.

wf_read() {  # wf_read <component> <path> [budget_seconds]
    local component="$1" path="$2" budget="${3:-60}" code waited=0
    while :; do
        code=$(wf GET "$component" "$path")
        [ "$code" = "202" ] || { printf '%s' "$code"; return 0; }
        [ "$waited" -ge "$budget" ] && { printf '%s' "$code"; return 0; }
        sleep 2
        waited=$((waited + 2))
    done
}

wf_mutate() {  # wf_mutate <component> <path> <body> [budget_seconds]
    local component="$1" path="$2" body="$3" budget="${4:-60}" code opid waited=0
    code=$(wf POST "$component" "$path" "$body")
    [ "$code" = "202" ] || { printf '%s' "$code"; return 0; }
    opid=$(python3 -c 'import json
try:
    print(json.load(open("/tmp/wf.out")).get("operationId") or "")
except Exception:
    print("")')
    [ -n "$opid" ] || { printf '%s' "$code"; return 0; }
    while :; do
        # 202 while PENDING or DELIVERED; then the operation's own status and body, or 504
        # if no integration ever confirmed it.
        code=$(wf GET "$component" "operations/${opid}")
        [ "$code" = "202" ] || { printf '%s' "$code"; return 0; }
        [ "$waited" -ge "$budget" ] && { printf '%s' "$code"; return 0; }
        sleep 2
        waited=$((waited + 2))
    done
}

# ── 1 & 2. registration and promotion ────────────────────────────────────────
# Read from Postgres: the GraphQL schema has no query that enumerates components, and the
# columns here are exactly what the assertions are about — display_type is the promotion,
# and the runtime rows are the multi-node count.
log "Integrations, runtimes and integration type"
rows=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" -c "
    SELECT c.name, c.component_id, c.display_type,
           count(r.runtime_id) FILTER (WHERE r.status = 'RUNNING')
      FROM components c
      LEFT JOIN runtimes r ON r.component_id = c.component_id
     WHERE c.name IN ('expense-integration', 'orders-integration')
     GROUP BY c.name, c.component_id, c.display_type
     ORDER BY c.name" | tr -d '\r')
[ -n "$rows" ] || { echo "no integrations registered yet - check: docker compose logs expense orders" >&2; exit 1; }

EXPENSE_ID="" ORDERS_ID=""
while IFS='|' read -r name cid display running; do
    [ -n "$name" ] || continue
    [ "$display" = "ballerinaWorkflow" ] \
        && ok "$name is a workflow integration (promoted on its first full heartbeat)" \
        || bad "$name display_type=$display, expected ballerinaWorkflow"
    [ "${running:-0}" -ge "$EXPECTED_RUNTIMES" ] \
        && ok "$name has $running RUNNING runtime(s)" \
        || bad "$name has ${running:-0} RUNNING runtime(s), expected >= $EXPECTED_RUNTIMES"
    case "$name" in
        expense-integration) EXPENSE_ID="$cid" ;;
        orders-integration) ORDERS_ID="$cid" ;;
    esac
done <<< "$rows"

[ -n "$EXPENSE_ID" ] || { echo "expense-integration never registered - check: docker compose logs expense" >&2; exit 1; }
[ -n "$ORDERS_ID" ] || { echo "orders-integration never registered - check: docker compose logs orders" >&2; exit 1; }

# Every runtime must have published its descriptor, or definitions would come from nowhere.
meta=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" -c "
    SELECT count(*) FROM bi_workflow_metadata WHERE capabilities LIKE '%workflowCommands%'" | tr -d '\r')
[ "${meta:-0}" -ge 2 ] \
    && ok "$meta runtime(s) published workflow metadata and advertise workflowCommands" \
    || bad "only ${meta:-0} runtime(s) published workflow metadata"

# ── 3. definitions from stored metadata ──────────────────────────────────────
log "Workflow definitions (served from heartbeat metadata, no call into the runtime)"
for pair in "expense:$EXPENSE_ID:expenseApproval,expenseAudit" "orders:$ORDERS_ID:orderFulfilment,orderReconciliation,bulkOrderIntake"; do
    label="${pair%%:*}"; rest="${pair#*:}"; cid="${rest%%:*}"; want="${rest#*:}"
    code=$(wf_read "$cid" "definitions")
    body=$(cat /tmp/wf.out)
    if [ "$code" = "200" ]; then
        names=$(printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); items=d if isinstance(d,list) else d.get("items",d.get("definitions",[])); print(",".join(sorted(i.get("name",i.get("workflowType","?")) for i in items)))' 2>/dev/null || echo "?")
        ok "$label definitions: $names"
        for one in ${want//,/ }; do
            case "$names" in *"$one"*) ok "  $label declares $one" ;; *) bad "  $label is missing $one" ;; esac
        done
    else
        bad "$label definitions returned $code: $(head -c 200 /tmp/wf.out)"
    fi
done

# ── 4 & 5. a full round trip through the tunnel ──────────────────────────────
log "expenseApproval: start, find the human task, complete it"
code=$(wf_mutate "$EXPENSE_ID" "workflows" \
    '{"workflowType":"expenseApproval","input":{"id":"EXP-SMOKE","amount":250,"submittedBy":"alice"}}')
if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    wfid=$(python3 -c 'import json,sys; d=json.load(open("/tmp/wf.out")); print(d.get("workflowId") or d.get("id") or "")')
    ok "started (HTTP $code) workflowId=${wfid:-<none>}"
else
    bad "start returned $code: $(head -c 300 /tmp/wf.out)"
    wfid=""
fi

if [ -n "$wfid" ]; then
    # The instance must reach RUNNING and stay there: expenseApproval parks on its human
    # task, so RUNNING after a few seconds *is* the "parked" state. instances.get queries the
    # workflow directly, so this needs no visibility support.
    status=""
    for i in $(seq 1 10); do
        code=$(wf_read "$EXPENSE_ID" "workflows/${wfid}")
        status=$(python3 -c 'import json,sys
try:
    print(json.load(open("/tmp/wf.out")).get("status",""))
except Exception:
    print("")')
        [ "$status" = "RUNNING" ] && break
        sleep 3
    done
    [ "$status" = "RUNNING" ] \
        && ok "the instance is RUNNING, parked on its human task" \
        || bad "the instance reported status='${status}' (expected RUNNING; GET returned $code)"

    # The human task must be listed, and completing it must drive the workflow to COMPLETED.
    # Listings are role-gated: the console user needs the role the task is addressed to
    # (APPROVER here) or the page is correctly empty — scripts/grant-task-roles.sh.
    taskId=""
    for i in $(seq 1 10); do
        code=$(wf_read "$EXPENSE_ID" "human-tasks?status=PENDING")
        # This instance's task, not merely the first pending one: earlier runs leave their
        # own tasks pending, and completing one of those proves nothing about this workflow.
        taskId=$(python3 -c '
import json, sys
want = sys.argv[1]
try:
    items = json.load(open("/tmp/wf.out")).get("items", [])
except Exception:
    items = []
print(next((t["taskId"] for t in items if t.get("parentWorkflowId") == want), ""))
' "$wfid")
        [ -n "$taskId" ] && break
        sleep 3
    done
    if [ -n "$taskId" ]; then
        ok "the ICP lists the pending human task ($taskId)"

        code=$(wf_read "$EXPENSE_ID" "human-tasks/pending-count")
        count=$(python3 -c 'import json,sys
try:
    print(json.load(open("/tmp/wf.out")).get("count",0))
except Exception:
    print(0)')
        [ "${count:-0}" -ge 1 ] && ok "pending-count reports ${count}" || bad "pending-count reported ${count}"

        code=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" '{"result":{"approved":true,"comment":"smoke"}}')
        [ "$code" = "200" ] && ok "the task was completed through the tunnel" \
            || bad "complete returned $code: $(head -c 200 /tmp/wf.out)"

        # The workflow resumes, runs its activity and finishes.
        status=""
        for i in $(seq 1 15); do
            code=$(wf_read "$EXPENSE_ID" "workflows/${wfid}")
            status=$(python3 -c 'import json,sys
try:
    print(json.load(open("/tmp/wf.out")).get("status",""))
except Exception:
    print("")')
            [ "$status" = "COMPLETED" ] && break
            sleep 3
        done
        [ "$status" = "COMPLETED" ] \
            && ok "the workflow completed after the human decision" \
            || bad "the workflow reported status='${status}' after completion (expected COMPLETED)"
    else
        bad "no pending human task was listed within ~30s. If the page is empty, check the"
        echo "        console user's roles: human tasks are role-gated, and this one needs"
        echo "        APPROVER — run scripts/grant-task-roles.sh, then sign in again."
    fi
fi

# ── 6. lifecycle on an event-parked instance ─────────────────────────────────
log "orderFulfilment: lifecycle on an instance parked on an event"
code=$(wf_mutate "$ORDERS_ID" "workflows" \
    '{"workflowType":"orderFulfilment","input":{"orderId":"ORD-SMOKE","sku":"SKU-1","quantity":2}}')
if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    oid=$(python3 -c 'import json,sys; d=json.load(open("/tmp/wf.out")); print(d.get("workflowId") or d.get("id") or "")')
    ok "started (HTTP $code) workflowId=${oid:-<none>}"
    sleep 5
    for action in suspend resume terminate; do
        code=$(wf_mutate "$ORDERS_ID" "workflows/${oid}/${action}" '{"reason":"smoke test"}')
        [ "$code" = "200" ] && ok "$action accepted" || bad "$action returned $code: $(head -c 200 /tmp/wf.out)"
        sleep 2
    done
else
    bad "start returned $code: $(head -c 300 /tmp/wf.out)"
fi

# ── 7. no stale reads ────────────────────────────────────────────────────────
if [ "$INCLUDE_OFFLINE" -eq 1 ]; then
    log "Offline integration: views must answer 503, not stale data"
    docker compose stop orders > /dev/null
    # Past heartbeatTimeoutSeconds the runtime is no longer RUNNING and no target qualifies.
    sleep 40
    code=$(wf_read "$ORDERS_ID" "workflows")
    [ "$code" = "503" ] \
        && ok "workflows answered 503 with the integration down" \
        || bad "workflows answered $code with the integration down (expected 503)"
    code=$(wf_read "$ORDERS_ID" "definitions")
    [ "$code" = "200" ] \
        && ok "definitions still answer 200 — they come from the database, not the runtime" \
        || bad "definitions answered $code with the integration down (expected 200)"
    docker compose start orders > /dev/null
fi

log "smoke: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
