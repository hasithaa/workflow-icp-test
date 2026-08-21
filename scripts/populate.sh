#!/usr/bin/env bash
# Fills the environment with instances in every state the console has a view for.
#
# The point is variety, not volume. Each block below exists because some view or operation is
# empty and untestable without it: pending human tasks for the task views, a rejected run for
# a FAILED instance, a review activity for the review views, a parent with children for the
# instance tree, and long-lived event-parked instances for the lifecycle actions.
#
# Every call goes through the tunnel, so this doubles as load: each start is an outbox row
# delivered on some worker's next heartbeat, and each read is a cache entry claimed by
# whichever node answers next. Run it more than once — nothing here is idempotent by design,
# because repeated runs are what make the cache's coalescing visible.
#
# Usage: scripts/populate.sh [--quiet]
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
: "${ICP_ENVIRONMENT_ID:=750e8400-e29b-41d4-a716-446655440001}"
CONSOLE="https://localhost:${CONSOLE_PORT}"

# shellcheck source=scripts/lib-wf.sh
. "${HERE}/scripts/lib-wf.sh"

log() { printf '\n=== %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

wf_login "$ICP_ADMIN_USER" "$ICP_ADMIN_PASSWORD"
wf_component_ids || { echo "integrations are not registered yet - check: docker compose logs expense orders" >&2; exit 1; }

stamp=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" \
    -d "${ICP_DB_NAME:-icp_db}" -c "SELECT to_char(now(), 'HH24MISS')")
stamp="${stamp//[[:space:]]/}"

start_expense() {  # start_expense <suffix> <amount> <who>
    local code wfid
    code=$(wf_mutate "$EXPENSE_ID" "workflows" \
        "{\"workflowType\":\"expenseApproval\",\"input\":{\"id\":\"EXP-${stamp}-$1\",\"amount\":$2,\"submittedBy\":\"$3\"}}")
    if [ "$code" = "201" ] || [ "$code" = "200" ]; then
        wfid=$(python3 -c 'import json; print(json.load(open("/tmp/wf.out")).get("workflowId",""))')
        printf '%s' "$wfid"
    else
        echo "  start EXP-${stamp}-$1 failed: $code $(head -c 160 /tmp/wf.out)" >&2
        printf ''
    fi
}

# Finds this instance's own pending task. Earlier runs leave their tasks pending, and acting
# on one of those would report success while doing nothing to the instance in hand.
task_of() {  # task_of <workflowId>
    local want="$1" i code
    for i in $(seq 1 12); do
        code=$(wf_read "$EXPENSE_ID" "human-tasks?status=PENDING")
        [ "$code" = "200" ] || { sleep 3; continue; }
        python3 -c '
import json, sys
want = sys.argv[1]
try:
    items = json.load(open("/tmp/wf.out")).get("items", [])
except Exception:
    items = []
print(next((t["taskId"] for t in items if t.get("parentWorkflowId") == want), ""))
' "$want" > /tmp/task_id
        [ -s /tmp/task_id ] && [ -n "$(cat /tmp/task_id)" ] && { cat /tmp/task_id; return 0; }
        sleep 3
    done
    printf ''
}

# ── Expense: parked, approved, rejected ──────────────────────────────────────
log "expenseApproval — three left parked on their human task"
for n in 1 2 3; do
    wfid=$(start_expense "PARK${n}" "$((100 * n))" "alice")
    [ -n "$wfid" ] && note "parked: $wfid"
done

log "expenseApproval — one approved, so an instance reaches COMPLETED"
wfid=$(start_expense "OK" 4200 "bob")
if [ -n "$wfid" ]; then
    taskId=$(task_of "$wfid")
    if [ -n "$taskId" ]; then
        code=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" \
            '{"result":{"approved":true,"comment":"within policy"}}')
        note "approved $wfid (HTTP $code)"
    else
        note "no task appeared for $wfid — human tasks are role-gated, see scripts/grant-task-roles.sh"
    fi
fi

log "expenseApproval — one rejected, so an instance reaches FAILED"
# The workflow returns an error when approval.approved is false, so rejecting the task is
# what produces a genuinely failed instance rather than a terminated one.
wfid=$(start_expense "NO" 99000 "carol")
if [ -n "$wfid" ]; then
    taskId=$(task_of "$wfid")
    if [ -n "$taskId" ]; then
        code=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" \
            '{"result":{"approved":false,"comment":"over budget"}}')
        note "rejected $wfid (HTTP $code)"
    fi
fi

log "expenseAudit — two straight-through runs, no human step"
for n in 1 2; do
    code=$(wf_mutate "$EXPENSE_ID" "workflows" \
        "{\"workflowType\":\"expenseAudit\",\"input\":\"EXP-${stamp}-AUDIT${n}\"}")
    note "expenseAudit ${n}: HTTP $code"
done

# ── Orders: event-parked, review, parent/child ────────────────────────────────
log "orderFulfilment — three parked on the paymentReceived event"
# Nothing signals these. There is no signal route through the tunnel, which makes them
# exactly what the lifecycle operations need: instances that stay RUNNING indefinitely.
for n in 1 2 3; do
    code=$(wf_mutate "$ORDERS_ID" "workflows" \
        "{\"workflowType\":\"orderFulfilment\",\"input\":{\"orderId\":\"ORD-${stamp}-${n}\",\"sku\":\"SKU-${n}\",\"quantity\":${n}}}")
    if [ "$code" = "201" ] || [ "$code" = "200" ]; then
        note "parked: $(python3 -c 'import json; print(json.load(open("/tmp/wf.out")).get("workflowId",""))')"
    else
        note "orderFulfilment ${n} failed: HTTP $code"
    fi
done

log "orderFulfilment — one out-of-stock, which fails after its event"
# SKU-OOS is the deterministic out-of-stock path in checkStock. It stays parked until
# signalled, so this is a failure waiting to happen rather than one already recorded.
code=$(wf_mutate "$ORDERS_ID" "workflows" \
    "{\"workflowType\":\"orderFulfilment\",\"input\":{\"orderId\":\"ORD-${stamp}-OOS\",\"sku\":\"SKU-OOS\",\"quantity\":1}}")
note "out-of-stock instance: HTTP $code"

log "orderReconciliation — raises a review activity"
for n in 1 2; do
    code=$(wf_mutate "$ORDERS_ID" "workflows" \
        "{\"workflowType\":\"orderReconciliation\",\"input\":\"ORD-${stamp}-REC${n}\"}")
    note "orderReconciliation ${n}: HTTP $code"
done

log "bulkOrderIntake — a parent with children"
code=$(wf_mutate "$ORDERS_ID" "workflows" \
    "{\"workflowType\":\"bulkOrderIntake\",\"input\":[{\"orderId\":\"ORD-${stamp}-B1\",\"sku\":\"SKU-1\",\"quantity\":1},{\"orderId\":\"ORD-${stamp}-B2\",\"sku\":\"SKU-2\",\"quantity\":2}]}")
note "bulkOrderIntake: HTTP $code"

# ── What the console should now show ─────────────────────────────────────────
log "Instance counts per status, straight from the tunnel"
for pair in "expense:$EXPENSE_ID" "orders:$ORDERS_ID"; do
    label="${pair%%:*}"; cid="${pair#*:}"
    code=$(wf_read "$cid" "workflows?pageSize=100")
    if [ "$code" = "200" ]; then
        python3 -c '
import json, sys, collections
label = sys.argv[1]
d = json.load(open("/tmp/wf.out"))
items = d.get("items", d if isinstance(d, list) else [])
counts = collections.Counter(i.get("status", "?") for i in items)
print("  %-8s %d instance(s): %s" % (label, len(items),
      ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))))
' "$label"
    else
        note "$label workflows returned HTTP $code"
    fi
done

code=$(wf_read "$EXPENSE_ID" "human-tasks?status=PENDING")
[ "$code" = "200" ] && python3 -c '
import json
items = json.load(open("/tmp/wf.out")).get("items", [])
print("  pending human tasks: %d" % len(items))
for t in items[:8]:
    print("    - %s  %s" % (t.get("taskId", "?")[:28], t.get("title", "")))
'

code=$(wf_read "$ORDERS_ID" "review-activities")
[ "$code" = "200" ] && python3 -c '
import json
d = json.load(open("/tmp/wf.out"))
items = d.get("items", d if isinstance(d, list) else [])
print("  pending review activities: %d" % len(items))
'

echo
echo "Console: ${CONSOLE}  (admin/admin, and approver/approver123 for the second role set)"
