#!/usr/bin/env bash
# Edge cases the happy-path smoke test cannot reach.
#
# These are the assertions from analysis/05 §9 that need more than one user, more than one
# node, or two things happening at once. Each prints ok/FAIL and the script exits non-zero if
# any failed, so it can gate a change rather than being eyeballed.
#
# Usage: scripts/edge-cases.sh [A1|A3|A4|A17|all]
set -uo pipefail

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
: "${APPROVER_USER:=approver}"
: "${APPROVER_PASSWORD:=approver123}"
: "${OPS_USER:=ops}"
: "${OPS_PASSWORD:=ops123}"
: "${TM1_USER:=tm1}"
: "${TM1_PASSWORD:=tm1pass123}"
: "${TM2_USER:=tm2}"
: "${TM2_PASSWORD:=tm2pass123}"
: "${ICP_ENVIRONMENT_ID:=750e8400-e29b-41d4-a716-446655440001}"
CONSOLE="https://localhost:${CONSOLE_PORT}"

# shellcheck source=scripts/lib-wf.sh
. "${HERE}/scripts/lib-wf.sh"

WANT="${1:-all}"
PASS=0 FAIL=0
log() { printf '\n=== %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$*"; }

wf_login "$ICP_ADMIN_USER" "$ICP_ADMIN_PASSWORD" || exit 1
wf_component_ids || { echo "integrations are not registered" >&2; exit 1; }
ADMIN_TOKEN="$token"

# Signs in as a user and prints their token, without disturbing $token.
token_for() {  # token_for <user> <password>
    local saved="$token" result
    wf_login "$1" "$2" >/dev/null || { token="$saved"; return 1; }
    result="$token"; token="$saved"; printf '%s' "$result"
}

# ── A1. Cross-role leakage ───────────────────────────────────────────────────
# The expense human task is addressed to APPROVER. An OPS-only user must not see it. This is
# the assertion that matters most about role-keyed caching: a bug that ignored roles, or that
# collided two role sets onto one cache entry, would show one user another user's work — and
# would look exactly like a working cache from the admin's seat.
if [ "$WANT" = "all" ] || [ "$WANT" = "A1" ]; then
    log "A1 — an OPS-only user must not see APPROVER tasks"

    approver_token=$(token_for "$APPROVER_USER" "$APPROVER_PASSWORD")
    ops_token=$(token_for "$OPS_USER" "$OPS_PASSWORD")

    count_tasks() {  # count_tasks <token>
        token="$1"
        local code
        code=$(wf_read "$EXPENSE_ID" "human-tasks?status=PENDING" 90)
        [ "$code" = "200" ] || { printf 'HTTP %s' "$code"; return 1; }
        python3 -c '
import json
items = json.load(open("/tmp/wf.out")).get("items", [])
print(len(items))
'
    }

    admin_count=$(count_tasks "$ADMIN_TOKEN") || admin_count="err:$admin_count"
    approver_count=$(count_tasks "$approver_token") || approver_count="err:$approver_count"
    ops_count=$(count_tasks "$ops_token") || ops_count="err:$ops_count"
    token="$ADMIN_TOKEN"

    note "admin=${admin_count} approver=${approver_count} ops=${ops_count}"
    case "$admin_count" in
        ''|*[!0-9]*) bad "the admin's task list did not load (${admin_count})" ;;
        0) bad "no pending tasks exist — run scripts/populate.sh first, this proves nothing" ;;
        *) ok "the admin sees ${admin_count} pending task(s)" ;;
    esac
    case "$approver_count" in
        ''|*[!0-9]*) bad "the approver's task list did not load (${approver_count})" ;;
        0) bad "the approver holds APPROVER and sees nothing — role names are not reaching the runtime" ;;
        *) ok "the approver sees ${approver_count} pending task(s)" ;;
    esac
    case "$ops_count" in
        ''|*[!0-9]*) bad "the ops user's task list did not load (${ops_count})" ;;
        0) ok "the OPS-only user sees none of them — no cross-role leakage" ;;
        *) bad "LEAK: the OPS-only user sees ${ops_count} APPROVER task(s)" ;;
    esac

    # And the cache must hold a separate entry per role set, not one shared answer.
    sets=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" \
        -d "${ICP_DB_NAME:-icp_db}" -c \
        "SELECT count(DISTINCT substring(data from '\"roles\":\[[^]]*\]'))
           FROM cache_entry WHERE data LIKE '%humanTasks.list%'" 2>/dev/null | tr -d ' ')
    [ "${sets:-0}" -ge 3 ] \
        && ok "one view, ${sets} cache entries — one per role set" \
        || bad "expected 3 role sets in the cache for this view, found ${sets:-0}"
fi

# ── A3. Two users completing one task ────────────────────────────────────────
# Both racers hold APPROVER (so the runtime considers them eligible) AND Developer (so the
# ICP lets them act). Both matter: `approver`, who holds Viewer, is refused with 403 before
# any race can happen, and a race against a caller who may not act tests authorization
# instead of concurrency.
#
# Exactly one completion may take effect. The other must be TOLD it lost — not silently
# dropped, not double-applied, and not handed a 500 it cannot interpret.
if [ "$WANT" = "all" ] || [ "$WANT" = "A3" ]; then
    log "A3 — two entitled users complete the same task at once"

    token="$ADMIN_TOKEN"
    stamp=$(date +%H%M%S)
    code=$(wf_mutate "$EXPENSE_ID" "workflows" \
        "{\"workflowType\":\"expenseApproval\",\"input\":{\"id\":\"EXP-RACE-${stamp}\",\"amount\":777,\"submittedBy\":\"race\"}}" 120)
    wfid=$(python3 -c 'import json; print(json.load(open("/tmp/wf.out")).get("workflowId",""))' 2>/dev/null)
    if [ -z "$wfid" ]; then
        bad "could not start the race instance (HTTP ${code})"
    else
        note "instance ${wfid}"
        taskId=""
        for _ in $(seq 1 12); do
            code=$(wf_read "$EXPENSE_ID" "human-tasks?status=PENDING" 90)
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

        if [ -z "$taskId" ]; then
            bad "the race instance never produced a pending task"
        else
            note "task ${taskId}"
            tm1_token=$(token_for "$TM1_USER" "$TM1_PASSWORD")
            tm2_token=$(token_for "$TM2_USER" "$TM2_PASSWORD")

            if [ -z "$tm1_token" ] || [ -z "$tm2_token" ]; then
                bad "could not sign in as both task managers — run scripts/create-users.sh"
            else
                # Two processes, each with its OWN response file: the helpers write the body to
                # one path, so sharing it would have each parse the other's answer. Separate
                # idempotency keys too — the same key collapses them into one operation by
                # design, which is the opposite of what this needs.
                (
                    token="$tm1_token" WF_OUT=/tmp/wf-tm1.out
                    c=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" \
                        '{"result":{"approved":true,"comment":"tm1"}}' 120)
                    printf '%s' "$c" > /tmp/race_tm1
                ) &
                (
                    token="$tm2_token" WF_OUT=/tmp/wf-tm2.out
                    c=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" \
                        '{"result":{"approved":true,"comment":"tm2"}}' 120)
                    printf '%s' "$c" > /tmp/race_tm2
                ) &
                wait
                token="$ADMIN_TOKEN"

                a=$(cat /tmp/race_tm1 2>/dev/null)
                b=$(cat /tmp/race_tm2 2>/dev/null)
                note "tm1=${a} tm2=${b}"

                # 202 is not an outcome: it means the poll gave up while the operation was
                # still in flight. Counting it as a win once made this test report a pass
                # while proving nothing.
                inconclusive=0
                for c in "$a" "$b"; do
                    [ "$c" = "202" ] && inconclusive=1
                done
                if [ "$inconclusive" = "1" ]; then
                    bad "an operation was still pending at the deadline (${a}/${b}) — inconclusive, not a pass"
                else
                    winners=0
                    for c in "$a" "$b"; do
                        case "$c" in 2*) winners=$((winners+1)) ;; esac
                    done
                    [ "$winners" = "1" ] \
                        && ok "exactly one completion took effect (${a}/${b})" \
                        || bad "expected exactly one winner, got ${winners} (${a}/${b})"

                    loser=""
                    case "$a" in 2*) loser="$b" ;; *) loser="$a" ;; esac
                    case "$loser" in
                        409) ok "the loser was told it conflicted (409)" ;;
                        4*)  ok "the loser got a 4xx explaining it (${loser})" ;;
                        5*)  bad "the loser got ${loser} — it cannot tell 'someone else did it' from 'it broke'" ;;
                        *)   bad "the loser's outcome was ${loser}" ;;
                    esac
                fi

                # Whatever the callers were told, the instance must finish once.
                status=""
                for _ in $(seq 1 15); do
                    code=$(wf_read "$EXPENSE_ID" "workflows/${wfid}" 90)
                    status=$(python3 -c '
import json
try:
    print(json.load(open("/tmp/wf.out")).get("status",""))
except Exception:
    print("")')
                    [ "$status" = "COMPLETED" ] && break
                    sleep 3
                done
                [ "$status" = "COMPLETED" ] \
                    && ok "the instance completed once, on one decision" \
                    || bad "the instance reported '${status}' after the race (expected COMPLETED)"

                # And exactly one completion reached the runtime, whatever the HTTP answers were.
                completions=$(docker compose exec -T postgres psql -qtAX \
                    -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" -c "
                    SELECT count(*) FROM cache_operation_outbox
                     WHERE data LIKE '%${taskId}%' AND status = 'COMPLETED'
                       AND result LIKE '%\"httpStatus\":200%'" 2>/dev/null | tr -d ' ')
                [ "${completions:-0}" = "1" ] \
                    && ok "one operation succeeded against this task in the outbox" \
                    || bad "${completions:-0} operations succeeded against this task (expected 1)"
            fi
        fi
    fi
fi

# ── A4. Node independence ────────────────────────────────────────────────────
# The row is the queue, so no node owns a request. This kills the node that accepted a read
# while that read is still in flight: another node's heartbeat must claim it, deliver it, and
# store the result, and the answer must come back through whoever is left. Under the old
# in-memory design this was the failure mode — the waiter lived in one process.
if [ "$WANT" = "all" ] || [ "$WANT" = "A4" ]; then
    log "A4 — kill the node that accepted an in-flight read"

    token="$ADMIN_TOKEN"
    # A cache key nobody has asked for, so the read genuinely has to be materialized.
    probe="human-tasks?status=PENDING&taskName=a4-$(date +%H%M%S)"
    code=$(wf GET "$EXPENSE_ID" "$probe")
    if [ "$code" != "202" ]; then
        note "first response was ${code}, not 202 — cannot test the in-flight case"
        bad "the probe read did not start a fetch (HTTP ${code})"
    else
        ok "the read was accepted with 202 while it is materialized"
        docker compose stop icp-1 >/dev/null 2>&1
        note "icp-1 stopped; only icp-2 can deliver and answer now"

        code=$(wf_read "$EXPENSE_ID" "$probe" 120)
        [ "$code" = "200" ] \
            && ok "the surviving node delivered and served the answer (200)" \
            || bad "the read never completed with a node down (HTTP ${code})"

        docker compose start icp-1 >/dev/null 2>&1
        note "icp-1 restarted"
        # It must rejoin without anything special happening: no state to rebuild.
        for _ in $(seq 1 20); do
            up=$(docker compose ps --format '{{.Service}} {{.Status}}' 2>/dev/null | grep -c "icp-1 Up")
            [ "${up:-0}" = "1" ] && break
            sleep 3
        done
        [ "${up:-0}" = "1" ] \
            && ok "icp-1 rejoined with no state to rebuild" \
            || bad "icp-1 did not come back up"
    fi
fi

# ── A17. Exactly one outcome record per operation ────────────────────────────
# Four workers heartbeat independently and a result can be redelivered, so "record the
# outcome" must be idempotent. Two nodes seeing the same result must not both write it.
if [ "$WANT" = "all" ] || [ "$WANT" = "A17" ]; then
    log "A17 — one audit record per operation, however many nodes see the result"

    dupes=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" \
        -d "${ICP_DB_NAME:-icp_db}" -c "
        SELECT count(*) FROM (
            SELECT details, count(*) AS n
              FROM audit_logs
             WHERE action LIKE '%orkflow%' AND details LIKE '%wfo-%'
             GROUP BY details HAVING count(*) > 1
        ) d" 2>/dev/null | tr -d ' ')
    [ "${dupes:-0}" = "0" ] \
        && ok "no workflow operation was recorded twice" \
        || bad "${dupes} workflow operation(s) have more than one audit record"

    completed=$(docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" \
        -d "${ICP_DB_NAME:-icp_db}" -c \
        "SELECT count(*) FROM cache_operation_outbox WHERE status = 'COMPLETED'" 2>/dev/null | tr -d ' ')
    note "completed operations in the outbox: ${completed:-0}"
fi

echo
echo "=== edge cases: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
