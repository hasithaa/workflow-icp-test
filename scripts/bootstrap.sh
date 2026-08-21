#!/usr/bin/env bash
# Brings up the control-plane half, then mints the organization secret the integrations
# need and writes it to .env — the one value that cannot be baked into an image, because it
# only exists once a running ICP has issued it.
#
# Usage: scripts/bootstrap.sh [--cluster]
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

CLUSTER=0
[ "${1:-}" = "--cluster" ] && CLUSTER=1

# Two nodes means round-robin, which is the case the tunnel is built for; one node means the
# pinned config, because nginx resolves upstreams at startup and a config naming icp-2 cannot
# start without it. Set EDGE_CONF yourself to override either way.
# The HTTP round-robin config terminates TLS at the edge, so it needs a certificate of its
# own. Self-signed, and regenerating is harmless: nothing pins it, and both the browser and
# the integrations skip verification because the distribution's certificate is self-signed too.
mkdir -p edge/certs
if [ ! -f edge/certs/edge.crt ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout edge/certs/edge.key \
        -out edge/certs/edge.crt -days 825 -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,DNS:edge,IP:127.0.0.1" 2>/dev/null
    echo "generated edge/certs/edge.crt"
fi

if [ "$CLUSTER" -eq 1 ] && [ -z "${EDGE_CONF:-}" ]; then
    EDGE_CONF=nginx.roundrobin.conf
    export EDGE_CONF
fi

: "${CONSOLE_PORT:=9446}"
: "${ICP_ADMIN_USER:=admin}"
: "${ICP_ADMIN_PASSWORD:=admin}"
# Seeded by postgresql_init.sql as the 'dev' environment.
: "${ICP_ENVIRONMENT_ID:=750e8400-e29b-41d4-a716-446655440001}"

CONSOLE="https://localhost:${CONSOLE_PORT}"
COMPOSE=(docker compose)
[ "$CLUSTER" -eq 1 ] && COMPOSE=(docker compose --profile cluster)

log() { printf '\n=== %s\n' "$*"; }

log "Starting Postgres, the ICP node(s) and the edge proxy"
# ICP_ORG_SECRET is required by the integration services; a placeholder keeps compose happy
# while we bring up only the control-plane half.
ICP_EXPENSE_SECRET=bootstrap ICP_ORDERS_SECRET=bootstrap "${COMPOSE[@]}" up -d --build postgres icp-1 edge
[ "$CLUSTER" -eq 1 ] && ICP_EXPENSE_SECRET=bootstrap ICP_ORDERS_SECRET=bootstrap "${COMPOSE[@]}" up -d --build icp-2
# Recreated after icp-2 exists: nginx resolved its upstreams when it first started, so an
# edge that came up alongside a single node cannot see the second one. The placeholder
# secrets are needed for the same reason as above — compose interpolates the whole file, so
# the integrations' required ICP_*_SECRET must have *a* value even when starting the edge.
[ "$CLUSTER" -eq 1 ] && ICP_EXPENSE_SECRET=bootstrap ICP_ORDERS_SECRET=bootstrap \
    "${COMPOSE[@]}" up -d --force-recreate edge

log "Waiting for the console to answer on ${CONSOLE}"
for i in $(seq 1 60); do
    if curl -sk --max-time 3 "${CONSOLE}/auth/capabilities" >/dev/null 2>&1; then
        echo "console is up after ${i} attempt(s)"
        break
    fi
    [ "$i" -eq 60 ] && { echo "console did not come up; try: docker compose logs icp-1" >&2; exit 1; }
    sleep 5
done

log "Signing in as ${ICP_ADMIN_USER}"
token=$(curl -sk -X POST "${CONSOLE}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ICP_ADMIN_USER}\",\"password\":\"${ICP_ADMIN_PASSWORD}\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')
[ -n "$token" ] || { echo "login failed - check the admin credentials" >&2; exit 1; }

log "Creating one unbound organization secret per integration"
# Unbound (no componentId) is what makes an integration self-register: the project,
# integration and environment named in its Config.toml are created on first heartbeat.
# One secret each, because a secret binds to the first project/component that presents it —
# a second integration reusing it is rejected with "already bound to a different
# project/component", and it registers no runtime at all.
mint_secret() {
    local response secret
    response=$(curl -sk -X POST "${CONSOLE}/graphql" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer ${token}" \
        -d "{\"query\":\"mutation { createOrgSecret(environmentId: \\\"${ICP_ENVIRONMENT_ID}\\\") }\"}")
    secret=$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
except ValueError:
    sys.exit("not JSON: " + sys.stdin.read()[:200])
if payload.get("errors"):
    sys.exit("graphql errors: " + json.dumps(payload["errors"]))
print((payload.get("data") or {}).get("createOrgSecret") or "")
')
    [ -n "$secret" ] || { echo "could not create an org secret" >&2; return 1; }
    printf '%s' "$secret"
}

expense_secret=$(mint_secret) || exit 1
orders_secret=$(mint_secret) || exit 1

log "Writing the secrets to .env"
touch .env
grep -vE '^ICP_(EXPENSE|ORDERS)_SECRET=' .env > .env.next 2>/dev/null || : > .env.next
printf 'ICP_EXPENSE_SECRET=%s\n' "$expense_secret" >> .env.next
printf 'ICP_ORDERS_SECRET=%s\n' "$orders_secret" >> .env.next
mv .env.next .env
echo "ICP_EXPENSE_SECRET=${expense_secret:0:12}… ICP_ORDERS_SECRET=${orders_secret:0:12}… (written to .env)"

log "Starting Temporal and the integrations"
if [ "$CLUSTER" -eq 1 ]; then
    INTEGRATION_REPLICAS=${INTEGRATION_REPLICAS:-2} "${COMPOSE[@]}" up -d --build temporal expense orders
else
    "${COMPOSE[@]}" up -d --build temporal expense orders
fi

log "Up. Console: ${CONSOLE} (admin/admin) · Temporal UI: http://localhost:${TEMPORAL_UI_PORT:-8233}"
echo "Give it one heartbeat interval, then: scripts/smoke.sh"
