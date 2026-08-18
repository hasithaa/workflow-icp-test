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
#   5. its human task child workflow exists (and what the ICP listing can show)
#   6. lifecycle: an event-parked instance suspends, resumes and terminates
#   7. an offline integration answers 503 rather than serving stale data (--include-offline)
#
# Usage: scripts/smoke.sh [--include-offline]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

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
    code=$(wf GET "$cid" "definitions")
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
code=$(wf POST "$EXPENSE_ID" "workflows" \
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
        code=$(wf GET "$EXPENSE_ID" "workflows/${wfid}")
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

    # The task itself is verified in Temporal, because the ICP's human-task *listing* needs
    # Temporal visibility queries that the dev server does not serve — see the README. The
    # tunnel is not what is limited here: the command reaches the integration and executes,
    # and the answer is an empty page.
    tasks=$(docker compose exec -T temporal temporal workflow list --address 127.0.0.1:7233 --limit 50 2>/dev/null \
        | grep -c "humantask-expenseApproval.approveExpense" || true)
    [ "${tasks:-0}" -ge 1 ] \
        && ok "the human task child workflow exists in Temporal (${tasks} found)" \
        || bad "no humantask child workflow was created"

    code=$(wf GET "$EXPENSE_ID" "human-tasks?status=PENDING")
    listed=$(python3 -c 'import json,sys
try:
    print(len(json.load(open("/tmp/wf.out")).get("items",[])))
except Exception:
    print(0)')
    if [ "$code" = "200" ] && [ "${listed:-0}" -ge 1 ]; then
        ok "the ICP lists ${listed} pending human task(s)"
    elif [ "$code" = "200" ]; then
        echo "  note  human-tasks listed 0 items (HTTP 200) - expected against the Temporal dev"
        echo "        server, whose visibility queries cannot serve this listing. The command"
        echo "        itself round-tripped, which is what the tunnel is responsible for."
    else
        bad "human-tasks returned $code: $(head -c 200 /tmp/wf.out)"
    fi
fi

# ── 6. lifecycle on an event-parked instance ─────────────────────────────────
log "orderFulfilment: lifecycle on an instance parked on an event"
code=$(wf POST "$ORDERS_ID" "workflows" \
    '{"workflowType":"orderFulfilment","input":{"orderId":"ORD-SMOKE","sku":"SKU-1","quantity":2}}')
if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    oid=$(python3 -c 'import json,sys; d=json.load(open("/tmp/wf.out")); print(d.get("workflowId") or d.get("id") or "")')
    ok "started (HTTP $code) workflowId=${oid:-<none>}"
    sleep 5
    for action in suspend resume terminate; do
        code=$(wf POST "$ORDERS_ID" "workflows/${oid}/${action}" '{"reason":"smoke test"}')
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
    code=$(wf GET "$ORDERS_ID" "workflows")
    [ "$code" = "503" ] \
        && ok "workflows answered 503 with the integration down" \
        || bad "workflows answered $code with the integration down (expected 503)"
    code=$(wf GET "$ORDERS_ID" "definitions")
    [ "$code" = "200" ] \
        && ok "definitions still answer 200 — they come from the database, not the runtime" \
        || bad "definitions answered $code with the integration down (expected 200)"
    docker compose start orders > /dev/null
fi

log "smoke: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
