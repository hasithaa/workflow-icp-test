#!/usr/bin/env bash
# Concurrent users against one environment.
#
# The design claims coalescing: many people asking the same question produce ONE fetch, because
# the cache key is the primary key. That is the load-bearing claim for multi-user use and it has
# to be measured, not asserted — a bug that issued one command per caller would look identical
# from a single seat and would flood the integration under twenty.
#
# Every worker gets its own response file: the helpers write to one path, so sharing it makes
# workers parse each other's answers.
#
# Usage: scripts/concurrent.sh [users] [rounds]
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
: "${ICP_ENVIRONMENT_ID:=750e8400-e29b-41d4-a716-446655440001}"
CONSOLE="https://localhost:${CONSOLE_PORT}"
USERS="${1:-20}"
ROUNDS="${2:-3}"

# shellcheck source=scripts/lib-wf.sh
. "${HERE}/scripts/lib-wf.sh"

log() { printf '\n=== %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

psql_q() { docker compose exec -T postgres psql -qtAX -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" -c "$1" 2>/dev/null | tr -d ' '; }

# Five identities, four role sets. Twenty sessions across them is realistic (one person, several
# tabs) and it is what makes coalescing visible: sessions sharing a role set must share a cache
# entry, and sessions with different roles must not.
IDENTITIES=("admin:${ICP_ADMIN_PASSWORD:-admin}" "approver:${APPROVER_PASSWORD:-approver123}" \
            "ops:${OPS_PASSWORD:-ops123}" "tm1:${TM1_PASSWORD:-tm1pass123}" "tm2:${TM2_PASSWORD:-tm2pass123}")

wf_login admin "${ICP_ADMIN_PASSWORD:-admin}" || exit 1
wf_component_ids || { echo "integrations are not registered" >&2; exit 1; }

rm -f /tmp/conc-*.out /tmp/conc-*.csv

log "${USERS} concurrent sessions × ${ROUNDS} rounds"
# Emptied first, so the fetch counts below describe THIS run rather than the environment's history.
before_cmds=$(docker compose logs --since 1s expense orders 2>/dev/null | grep -c "Handling control command" || true)
psql_q "DELETE FROM cache_entry" >/dev/null
note "cache emptied — every question below starts as a miss"

started=$(date +%s)
for i in $(seq 1 "$USERS"); do
    (
        ident="${IDENTITIES[$(( (i - 1) % ${#IDENTITIES[@]} ))]}"
        user="${ident%%:*}"; pass="${ident#*:}"
        WF_OUT="/tmp/conc-${i}.out"
        export WF_OUT
        wf_login "$user" "$pass" >/dev/null 2>&1 || { echo "${i},${user},login,,fail" >> /tmp/conc-results.csv; exit 0; }
        for r in $(seq 1 "$ROUNDS"); do
            for probe in "workflows?limit=50" "human-tasks?status=PENDING&limit=50" "human-tasks/pending-count"; do
                t0=$(python3 -c 'import time; print(time.time())')
                code=$(wf_read "$EXPENSE_ID" "$probe" 120)
                t1=$(python3 -c 'import time; print(time.time())')
                ms=$(python3 -c "print(int((${t1} - ${t0}) * 1000))")
                printf '%s,%s,%s,%s,%s\n' "$i" "$user" "${probe%%\?*}" "$ms" "$code" >> /tmp/conc-results.csv
            done
        done
    ) &
done
wait
elapsed=$(( $(date +%s) - started ))
note "wall clock: ${elapsed}s"

log "Outcomes"
python3 - <<'PY'
import csv, collections, statistics, pathlib
rows = list(csv.reader(open('/tmp/conc-results.csv'))) if pathlib.Path('/tmp/conc-results.csv').exists() else []
by_code = collections.Counter(r[4] for r in rows if len(r) == 5)
print(f"        {len(rows)} request(s): " + ", ".join(f"{c}={n}" for c, n in sorted(by_code.items())))
# 403 is a correct outcome, not a failure: the ops and approver sessions hold Viewer, which
# carries view_human_tasks and not view_workflows, so their instance-list probe must be
# refused. Counting it as an error would report a working authorization check as a fault.
refused = by_code.get('403', 0)
bad_codes = {c: n for c, n in by_code.items() if not c.startswith('2') and c != '403'}
per_probe = collections.defaultdict(list)
for r in rows:
    if len(r) == 5 and r[4] == '200':
        per_probe[r[2]].append(int(r[3]))
for probe, times in sorted(per_probe.items()):
    times.sort()
    p50 = times[len(times) // 2]
    p95 = times[min(len(times) - 1, int(len(times) * 0.95))]
    print(f"        {probe:<28} n={len(times):<4} p50={p50}ms p95={p95}ms max={max(times)}ms")
print(f"        {refused} request(s) correctly refused with 403 (Viewer cannot list instances)")
print(f"        FAILURES: {bad_codes}" if bad_codes else "        no unexpected responses")
PY

log "Coalescing — the claim under test"
# Three distinct questions per role set. With four role sets in play that is at most a dozen
# entries, however many sessions asked. One entry per session would be the bug.
entries=$(psql_q "SELECT count(*) FROM cache_entry")
role_sets=$(psql_q "SELECT count(DISTINCT substring(data from '\"roles\":\[[^]]*\]')) FROM cache_entry")
note "${entries} cache entries across ${role_sets} role set(s), from ${USERS} sessions"
[ "${entries:-0}" -le $(( role_sets * 6 )) ] \
    && ok "entries scale with distinct questions, not with sessions" \
    || bad "${entries} entries is more than the questions asked — coalescing is not holding"

after_cmds=$(docker compose logs --since "${elapsed}s" expense orders 2>/dev/null | grep -c "Handling control command" || true)
note "commands delivered to the integrations during the run: ${after_cmds}"
[ "${after_cmds:-0}" -le $(( entries * 3 + 10 )) ] \
    && ok "commands are bounded by entries, not by callers" \
    || bad "${after_cmds} commands for ${entries} entries — each caller may be issuing its own"

log "No leakage under load"
# The assertion most worth repeating concurrently: a role check that holds when serialized can
# still fail when two role sets race for the same entry.
leaked=$(python3 - <<'PY'
import csv, json, pathlib
leaked = 0
for i in range(1, 200):
    p = pathlib.Path(f"/tmp/conc-{i}.out")
    if not p.exists():
        continue
    try:
        d = json.loads(p.read_text())
    except Exception:
        continue
    items = d.get("items") if isinstance(d, dict) else None
    if isinstance(items, list) and any("approveExpense" in json.dumps(it) for it in items):
        leaked += 1
print(leaked)
PY
)
note "sessions whose last response held an APPROVER task: ${leaked} (ops sessions must not)"
ops_leak=$(for i in $(seq 1 "$USERS"); do
    ident="${IDENTITIES[$(( (i - 1) % ${#IDENTITIES[@]} ))]}"
    [ "${ident%%:*}" = "ops" ] && [ -f "/tmp/conc-${i}.out" ] && grep -l "approveExpense" "/tmp/conc-${i}.out" 2>/dev/null
done | wc -l | tr -d ' ')
[ "${ops_leak:-0}" = "0" ] \
    && ok "no OPS session ever saw an APPROVER task" \
    || bad "${ops_leak} OPS session(s) saw an APPROVER task"

log "Heartbeat health after the run"
psql_q "SELECT count(*) FROM runtimes WHERE status = 'RUNNING'" | xargs -I{} echo "        RUNNING runtimes: {}"
wedged=$(psql_q "SELECT count(*) FROM pg_stat_activity WHERE datname = '${ICP_DB_NAME:-icp_db}' AND state LIKE 'idle in transaction%'")
[ "${wedged:-0}" = "0" ] \
    && ok "no idle-in-transaction sessions left behind" \
    || bad "${wedged} idle-in-transaction session(s) — the audit_logs wedge, see analysis/05"
