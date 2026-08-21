# Shared helpers for driving workflow management through the ICP tunnel.
#
# Sourced by smoke.sh and populate.sh. Expects CONSOLE, ICP_ENVIRONMENT_ID and a $token
# already in scope, and leaves each response body in /tmp/wf.out while printing the HTTP code
# — so a caller reads like a plain curl even though every call may have been asynchronous.

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
# Polling is therefore the contract, not a workaround for slowness — asserting on the first
# response tests the 202 and nothing else.

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

# Signs in and sets $token. The response field is "token", not "accessToken".
wf_login() {  # wf_login <username> <password>
    token=$(curl -sk -X POST "${CONSOLE}/auth/login" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')
    [ -n "$token" ] || { echo "login failed for $1" >&2; return 1; }
}

# Resolves the component ids of the two integrations from the database: the GraphQL schema
# has no query that enumerates components.
wf_component_ids() {  # sets EXPENSE_ID and ORDERS_ID
    local rows
    rows=$(docker compose exec -T postgres psql -qtAX \
        -U "${POSTGRES_SUPERUSER:-postgres}" -d "${ICP_DB_NAME:-icp_db}" -c "
        SELECT c.name, c.component_id
          FROM components c
         WHERE c.name IN ('expense-integration', 'orders-integration')")
    EXPENSE_ID=""; ORDERS_ID=""
    while IFS='|' read -r name cid; do
        case "$name" in
            expense-integration) EXPENSE_ID="$cid" ;;
            orders-integration) ORDERS_ID="$cid" ;;
        esac
    done <<< "$rows"
    [ -n "$EXPENSE_ID" ] && [ -n "$ORDERS_ID" ]
}
