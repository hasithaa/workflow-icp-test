#!/usr/bin/env bash
# Edge cases the happy-path smoke test cannot reach.
#
# These are the assertions from analysis/05 §9 that need more than one user, more than one
# node, or two things happening at once. Each prints ok/FAIL and the script exits non-zero if
# any failed, so it can gate a change rather than being eyeballed.
#
# Usage: scripts/edge-cases.sh [A1|A3|A4|A11|A13|A17|all]
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
psql_q() { docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" -c "$1" 2>/dev/null | tr -d ' '; }
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

# ── A3b. Two users deciding DIFFERENTLY on one task ──────────────────────────
# A3 shows a lost race being reported inconsistently — 500 on one run, 200 on the next,
# depending on whether the second signal arrives before the task workflow closes. This asks the
# question that makes the ambiguity matter: one user approves, the other rejects. Only one
# decision can take effect. If both callers are told 200, one of them believes they decided
# something they did not, and nothing in the response says which way it went.
if [ "$WANT" = "all" ] || [ "$WANT" = "A3b" ]; then
    log "A3b — one approves, one rejects, at the same time"

    token="$ADMIN_TOKEN"
    stamp=$(date +%H%M%S)
    code=$(wf_mutate "$EXPENSE_ID" "workflows" \
        "{\"workflowType\":\"expenseApproval\",\"input\":{\"id\":\"EXP-SPLIT-${stamp}\",\"amount\":555,\"submittedBy\":\"split\"}}" 120)
    wfid=$(python3 -c 'import json; print(json.load(open("/tmp/wf.out")).get("workflowId",""))' 2>/dev/null)
    taskId=""
    if [ -n "$wfid" ]; then
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
    fi

    if [ -z "$taskId" ]; then
        bad "could not prepare a task for the split-decision case"
    else
        note "task ${taskId} on instance ${wfid}"
        tm1_token=$(token_for "$TM1_USER" "$TM1_PASSWORD")
        tm2_token=$(token_for "$TM2_USER" "$TM2_PASSWORD")

        (
            token="$tm1_token" WF_OUT=/tmp/wf-s1.out
            c=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" \
                '{"result":{"approved":true,"comment":"approve"}}' 120)
            printf '%s' "$c" > /tmp/split_yes
        ) &
        (
            token="$tm2_token" WF_OUT=/tmp/wf-s2.out
            c=$(wf_mutate "$EXPENSE_ID" "human-tasks/${taskId}/complete" \
                '{"result":{"approved":false,"comment":"reject"}}' 120)
            printf '%s' "$c" > /tmp/split_no
        ) &
        wait
        token="$ADMIN_TOKEN"

        yes=$(cat /tmp/split_yes 2>/dev/null)
        no=$(cat /tmp/split_no 2>/dev/null)
        note "approve=${yes} reject=${no}"

        # The workflow returns an error when rejected, so its final status tells us which
        # decision actually took effect: COMPLETED means approve won, FAILED means reject did.
        status=""
        for _ in $(seq 1 20); do
            code=$(wf_read "$EXPENSE_ID" "workflows/${wfid}" 90)
            status=$(python3 -c '
import json
try:
    print(json.load(open("/tmp/wf.out")).get("status",""))
except Exception:
    print("")')
            case "$status" in COMPLETED|FAILED|TERMINATED) break ;; esac
            sleep 3
        done
        case "$status" in
            COMPLETED) note "the approval took effect" ;;
            FAILED)    note "the rejection took effect" ;;
            *)         note "the instance is '${status}'" ;;
        esac
        case "$status" in
            COMPLETED|FAILED) ok "exactly one decision took effect (instance ${status})" ;;
            *) bad "the instance never settled (${status})" ;;
        esac

        # The point of the case: was the user whose decision was discarded told so?
        told=0
        for c in "$yes" "$no"; do
            case "$c" in 2*) told=$((told+1)) ;; esac
        done
        if [ "$told" = "2" ]; then
            bad "both users were told their decision succeeded, but only one did — a silent lost update"
            note "whichever of them lost has no way to know: same status, same body shape"
        elif [ "$told" = "1" ]; then
            ok "one user was told it succeeded and the other was not"
        else
            bad "neither user was told their decision succeeded (${yes}/${no})"
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

# ── A11. A mutation whose target dies ────────────────────────────────────────
# The outbox addresses ONE runtime. If that runtime never confirms, the operation must end
# EXPIRED and say so — and must never be re-run somewhere else. Re-running is the tempting
# repair and the wrong one: the ICP cannot know whether the original took effect, and a
# completion applied twice is worse than one reported as unconfirmed.
#
# Sequencing matters. The workers are stopped first, but the mutation is submitted while their
# rows still read RUNNING (within heartbeatTimeoutSeconds) — otherwise target selection fails
# and the ICP refuses the request with 503, which is a different path entirely.
if [ "$WANT" = "all" ] || [ "$WANT" = "A11" ]; then
    log "A11 — a mutation whose target dies before confirming"

    token="$ADMIN_TOKEN"
    stamp=$(date +%H%M%S)
    code=$(wf_mutate "$EXPENSE_ID" "workflows" \
        "{\"workflowType\":\"expenseApproval\",\"input\":{\"id\":\"EXP-DEAD-${stamp}\",\"amount\":31,\"submittedBy\":\"dead\"}}" 120)
    wfid=$(python3 -c 'import json; print(json.load(open("/tmp/wf.out")).get("workflowId",""))' 2>/dev/null)
    taskId=""
    if [ -n "$wfid" ]; then
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
    fi

    if [ -z "$taskId" ]; then
        bad "could not prepare a pending task for the dead-target case"
    else
        note "task ${taskId} on instance ${wfid}"
        docker compose stop expense >/dev/null 2>&1
        note "both expense workers stopped; their runtime rows still read RUNNING for now"

        # Queued, not delivered: nothing is listening on that task queue any more.
        code=$(wf POST "$EXPENSE_ID" "human-tasks/${taskId}/complete" '{"result":{"approved":true,"comment":"dead-target"}}')
        opid=$(python3 -c 'import json
try:
    print(json.load(open("/tmp/wf.out")).get("operationId") or "")
except Exception:
    print("")')
        if [ "$code" != "202" ] || [ -z "$opid" ]; then
            bad "the mutation was not queued (HTTP ${code}) — the runtimes were already OFFLINE, so this tested nothing"
        else
            ok "the mutation was accepted and queued as ${opid}"

            # Its real deadline is 30 minutes. Brought forward so the give-up path runs now;
            # the sweep interval is 30s in this environment for the same reason.
            psql_q "UPDATE cache_operation_outbox SET deadline = extract(epoch from now())::bigint - 5 WHERE operation_id = '${opid}'" >/dev/null
            note "deadline brought forward; waiting for a sweep"

            status=""
            for _ in $(seq 1 20); do
                status=$(psql_q "SELECT status FROM cache_operation_outbox WHERE operation_id = '${opid}'")
                [ "$status" = "EXPIRED" ] && break
                sleep 5
            done
            [ "$status" = "EXPIRED" ] \
                && ok "the sweep expired the unconfirmed operation" \
                || bad "the operation is '${status}' — the sweep did not give up on it"

            # The caller polling it must be told what is and is not known.
            code=$(wf GET "$EXPENSE_ID" "operations/${opid}")
            body=$(head -c 300 /tmp/wf.out)
            case "$code" in
                504) ok "polling it answers 504" ;;
                *)   bad "polling it answered ${code}" ;;
            esac
            case "$body" in
                *"not confirm"*|*"may or may not"*) ok "and says the outcome is unconfirmed, not that it failed" ;;
                *) bad "the message does not say the outcome is unknown: ${body}" ;;
            esac

            # An operator has to be able to find it. A 5xx or an expiry raises an unresolved
            # notification precisely because nobody knows whether the action took effect.
            # metadata is jsonb, so LIKE needs the cast. Without it the query errors, psql_q
            # swallows stderr, and the empty result reads as "no notification" — the assertion
            # failing rather than the thing it asserts.
            events=$(psql_q "SELECT count(*) FROM system_events WHERE metadata::text LIKE '%${opid}%'")
            [ "${events:-0}" -ge 1 ] \
                && ok "an operator notification was raised (${events})" \
                || bad "no notification names this operation — it disappeared silently"

            docker compose start expense >/dev/null 2>&1
            note "workers restarted; watching for a re-delivery that must not happen"
            sleep 25

            redelivered=$(docker compose logs --since 40s expense 2>/dev/null | grep -c "$opid" || true)
            [ "${redelivered:-0}" = "0" ] \
                && ok "the expired operation was not re-delivered" \
                || bad "the expired operation was delivered ${redelivered} time(s) after expiry"

            final=$(psql_q "SELECT status FROM cache_operation_outbox WHERE operation_id = '${opid}'")
            [ "$final" = "EXPIRED" ] \
                && ok "it stayed EXPIRED after the target came back" \
                || bad "its status became '${final}' after the target came back"

            # And the action itself must not have happened.
            still_pending=$(wf_read "$EXPENSE_ID" "human-tasks?status=PENDING&refresh=true" 120 >/dev/null; python3 -c '
import json, sys
want = sys.argv[1]
try:
    items = json.load(open("/tmp/wf.out")).get("items", [])
except Exception:
    items = []
print("yes" if any(t.get("taskId") == want for t in items) else "no")
' "$taskId")
            [ "$still_pending" = "yes" ] \
                && ok "the task is still pending — the unconfirmed completion was not applied" \
                || note "the task is no longer pending; it may have been completed by another case in this run"
        fi
    fi
fi

# ── A13. A change made outside the ICP becomes visible ───────────────────────
# Nothing guarantees every change arrives through the tunnel. An operator with the Temporal CLI,
# another tool, or the workflow itself can move an instance, and the console must catch up
# rather than serving its cached answer indefinitely. This terminates an instance behind the
# ICP's back and waits for the listing to notice.
if [ "$WANT" = "all" ] || [ "$WANT" = "A13" ]; then
    log "A13 — an instance terminated outside the ICP must become visible"

    token="$ADMIN_TOKEN"
    code=$(wf_read "$ORDERS_ID" "workflows?limit=100" 120)
    victim=$(python3 -c '
import json
try:
    items = json.load(open("/tmp/wf.out")).get("items", [])
except Exception:
    items = []
# An event-parked orderFulfilment: RUNNING and staying that way until something moves it.
print(next((i["workflowId"] for i in items
            if i.get("status") == "RUNNING" and i.get("workflowType") == "orderFulfilment"), ""))
')
    if [ -z "$victim" ]; then
        bad "no RUNNING orderFulfilment instance to terminate — run scripts/populate.sh"
    else
        note "terminating ${victim} with the Temporal CLI, not through the ICP"
        docker compose exec -T temporal temporal workflow terminate \
            --address temporal:7233 --namespace default \
            --workflow-id "$victim" --reason "A13 external change" >/dev/null 2>&1
        killed=$?
        [ "$killed" = "0" ] \
            && ok "the CLI terminated it" \
            || bad "the CLI could not terminate it"

        # No refresh, no cache-busting: the question is whether an ordinary reader finds out.
        # The bound is the listing TTL plus a heartbeat, so this waits rather than polling once.
        seen=""
        for _ in $(seq 1 24); do
            code=$(wf_read "$ORDERS_ID" "workflows?limit=100" 120)
            seen=$(python3 -c '
import json, sys
want = sys.argv[1]
try:
    items = json.load(open("/tmp/wf.out")).get("items", [])
except Exception:
    items = []
print(next((i.get("status", "") for i in items if i.get("workflowId") == want), ""))
' "$victim")
            [ "$seen" = "TERMINATED" ] && break
            sleep 5
        done
        [ "$seen" = "TERMINATED" ] \
            && ok "an unforced read reports it TERMINATED — the cache caught up on its own" \
            || bad "the listing still reports '${seen}' after ~2 minutes"

        # And the explicit refresh must not be slower than waiting.
        code=$(wf_read "$ORDERS_ID" "workflows?limit=100&refresh=true" 120)
        forced=$(python3 -c '
import json, sys
want = sys.argv[1]
try:
    items = json.load(open("/tmp/wf.out")).get("items", [])
except Exception:
    items = []
print(next((i.get("status", "") for i in items if i.get("workflowId") == want), ""))
' "$victim")
        [ "$forced" = "TERMINATED" ] \
            && ok "a forced refresh agrees" \
            || bad "a forced refresh reports '${forced}'"
    fi
fi

# ── A15. A late result cannot resurrect an invalidated row ───────────────────
# The fencing story: a command id carries the attempt that asked for it, so an answer whose
# attempt the row no longer holds belongs to a superseded or invalidated fetch and must be
# thrown away. Without this, a slow runtime's reply lands after a mutation invalidated the
# entry and re-caches pre-mutation state for a full TTL — the user completes a task, watches it
# reappear, and the cache insists for minutes.
#
# Posted through the real /icp/commandResult with a real runtime JWT (scripts/late-result.py),
# so the ICP rejects it on its merits rather than because the call was malformed.
if [ "$WANT" = "all" ] || [ "$WANT" = "A15" ]; then
    log "A15 — a result for a superseded attempt must be discarded"

    token="$ADMIN_TOKEN"
    probe="human-tasks?status=PENDING&taskName=a15-$(date +%H%M%S)"
    code=$(wf GET "$EXPENSE_ID" "$probe")
    if [ "$code" != "202" ]; then
        bad "the probe read did not start a fetch (HTTP ${code})"
    else
        row=$(psql_q "SELECT cache_key || ':' || coalesce(token,'') FROM cache_entry
                       WHERE status = 'FETCHING' ORDER BY created_at DESC LIMIT 1")
        cache_key="${row%%:*}"; stale_token="${row##*:}"
        if [ -z "$cache_key" ] || [ -z "$stale_token" ]; then
            note "the fetch was answered before it could be superseded — rerun for this case"
            note "(the runtime beat the test, which is not a failure of the fencing)"
        else
            note "attempt ${stale_token} on ${cache_key:0:16}…"

            # Supersede it exactly as a re-claim would: a new attempt token on the same row.
            new_token="a15-superseded-$(date +%s)"
            psql_q "UPDATE cache_entry SET token = '${new_token}' WHERE cache_key = '${cache_key}'" >/dev/null
            ok "the row now belongs to a newer attempt"

            runtime=$(psql_q "SELECT m.runtime_id FROM bi_workflow_metadata m
                              JOIN runtimes r ON r.runtime_id = m.runtime_id
                             WHERE r.component_id = '${EXPENSE_ID}' AND r.status = 'RUNNING' LIMIT 1")
            marker="a15-must-not-be-cached"
            out=$(ICP_ORG_SECRET="${ICP_EXPENSE_SECRET}" ICP_RUNTIME_URL="https://localhost:${RUNTIME_PORT:-9445}" \
                python3 scripts/late-result.py "$runtime" "wfr-${cache_key}.${stale_token}" 200 \
                "{\"items\":[{\"taskId\":\"${marker}\"}]}" 2>&1)
            note "the ICP answered: ${out}"

            # Accepting the POST is fine — the runtime did its job and the transport worked.
            # What must not happen is the payload being stored.
            stored=$(psql_q "SELECT count(*) FROM cache_entry
                              WHERE cache_key = '${cache_key}' AND data LIKE '%${marker}%'")
            [ "${stored:-0}" = "0" ] \
                && ok "the superseded answer was not stored" \
                || bad "the superseded answer WAS stored — a late reply can resurrect an invalidated row"

            held=$(psql_q "SELECT coalesce(token,'') FROM cache_entry WHERE cache_key = '${cache_key}'")
            [ "$held" = "$new_token" ] \
                && ok "the row still belongs to the newer attempt" \
                || note "the row's attempt is now '${held}'"

            code=$(wf GET "$EXPENSE_ID" "$probe")
            body=$(head -c 200 /tmp/wf.out)
            case "$body" in
                *"$marker"*) bad "a reader was served the superseded payload" ;;
                *) ok "a reader is not served it either (HTTP ${code})" ;;
            esac
        fi
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
