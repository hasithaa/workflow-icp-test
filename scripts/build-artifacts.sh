#!/usr/bin/env bash
# Stages everything the images need from your local source checkouts:
#
#   1. the ICP distribution zip                        -> icp/artifacts/
#   2. the ICP Postgres init + migration SQL           -> artifacts/db/
#   3. the workflow module and the ICP bridge          -> local bala repository
#   4. each integration built into a fat jar           -> integrations/*/artifacts/
#
# Everything is built from source on purpose: the point of this environment is to test what
# is on your branches, not what is published.
#
# Usage: scripts/build-artifacts.sh [--skip-icp] [--skip-deps] [--skip-integrations]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

# One file drives the whole environment, this script included. It was the ONE script that did
# not read .env, which is the worst place for the omission: the refs below decide which
# branches get built, so a ref set in .env was ignored and the build quietly produced
# artifacts from the defaults while reporting exactly what it had built. Sourced before the
# defaults below, so `: "${VAR:=...}"` fills in only what .env left unset.
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

# Where the sources come from.
#
# Two modes, and the default suits whoever is running this. With no checkouts present the
# script CLONES each repository at a pinned ref, so someone reviewing the PRs needs nothing
# but Docker, Ballerina and this repository. With checkouts present it builds those instead,
# because when you are iterating on a branch you want what is on disk, not what is pushed.
#
# Set CLONE=1 to clone even when checkouts exist (a clean-room build), or CLONE=0 to insist
# on local ones.
: "${SRC_ROOT:=$HOME/Source/workflow/ICP_REWAMP}"
: "${ICP_REPO:=$SRC_ROOT/integration-control-plane}"
: "${WORKFLOW_REPO:=$SRC_ROOT/module-ballerina-workflow}"
: "${BRIDGE_REPO:=$SRC_ROOT/icp-runtime-bridge}"

# What to clone, when cloning. The refs are the point of this environment: it tests the
# branches under review, against a workflow module release that already carries what they
# need.
#
# The module is taken from main: the management command API and the protocol-independent
# error code (module PRs #94 and #95) are merged there and it is already 0.9.0, which is the
# version the bridge's generated glue compiles against.
: "${WORKFLOW_GIT:=https://github.com/ballerina-platform/module-ballerina-workflow.git}"
: "${WORKFLOW_REF:=main}"
# ICP PR #834 — the workflow command tunnel, now cache-table backed.
: "${ICP_GIT:=https://github.com/hasithaa/integration-control-plane.git}"
: "${ICP_REF:=workflow-tunnel}"
# Bridge PR #44 — metadata publishing and tunneled command execution.
: "${BRIDGE_GIT:=https://github.com/hasithaa/icp-runtime-bridge.git}"
: "${BRIDGE_REF:=workflow-metadata}"
: "${CLONE_DIR:=$HERE/.sources}"
: "${ICP_DIST:=wso2-integration-control-plane-2.0.0-SNAPSHOT}"
: "${BAL_DIST_VERSION:=2201.13.4}"

SKIP_ICP=0 SKIP_DEPS=0 SKIP_INTEGRATIONS=0
for arg in "$@"; do
    case "$arg" in
        --skip-icp) SKIP_ICP=1 ;;
        --skip-deps) SKIP_DEPS=1 ;;
        --skip-integrations) SKIP_INTEGRATIONS=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '\n=== %s\n' "$*"; }

# Resolves one repository to a directory to build from: a local checkout when there is one
# (and cloning was not demanded), otherwise a clone pinned to its ref. Re-runs fetch rather
# than re-clone, so this is cheap to repeat.
#
# Prints the path on stdout; everything else goes to stderr so the caller can capture it.
resolve_repo() {
    local name="$1" local_dir="$2" url="$3" ref="$4"
    if [ "${CLONE:-auto}" != "1" ] && [ -d "$local_dir/.git" ]; then
        echo "using local checkout: $local_dir" >&2
        printf '%s' "$local_dir"
        return
    fi
    if [ "${CLONE:-auto}" = "0" ]; then
        echo "missing: $local_dir (CLONE=0 forbids cloning; set SRC_ROOT or the *_REPO vars)" >&2
        exit 1
    fi
    local dest="$CLONE_DIR/$name"
    mkdir -p "$CLONE_DIR"
    if [ -d "$dest/.git" ]; then
        echo "updating clone: $dest ($ref)" >&2
        # The URL may have changed since this clone was made — a different fork, or a ref
        # that only exists on one of them. Re-point it rather than fetching from whatever
        # origin happened to be first.
        git -C "$dest" remote set-url origin "$url"
    else
        echo "cloning $url ($ref) -> $dest" >&2
        git clone --quiet "$url" "$dest"
    fi

    # Building stamps files inside the clone — Ballerina rewrites Dependencies.toml — and a
    # dirty tree blocks the next checkout. This is a build input, not a working tree, so its
    # local changes are discarded rather than protected.
    git -C "$dest" reset --hard --quiet HEAD

    # Checked explicitly, because a failure here is the one that must not be survivable: a
    # missing ref used to leave the previous checkout in place while the log still announced
    # the ref that was asked for, so the build produced the wrong artifacts and said nothing.
    if ! git -C "$dest" fetch --quiet origin "$ref"; then
        echo "cannot fetch ref '$ref' from $url" >&2
        echo "  (a branch on a fork? set the matching *_GIT variable as well as *_REF)" >&2
        exit 1
    fi
    # Detached on purpose: this is a build input, not a branch anyone works on here.
    if ! git -C "$dest" -c advice.detachedHead=false checkout --quiet FETCH_HEAD; then
        echo "cannot check out '$ref' in $dest" >&2
        exit 1
    fi
    echo "$name at $(git -C "$dest" rev-parse --short HEAD) ($ref from $url)" >&2
    printf '%s' "$dest"
}

require_dir() { [ -d "$1" ] || { echo "missing: $1 (set SRC_ROOT or the individual *_REPO vars)" >&2; exit 1; }; }

mkdir -p icp/artifacts artifacts/db integrations/expense/artifacts integrations/orders/artifacts

log "Resolving sources"
ICP_REPO="$(resolve_repo integration-control-plane "$ICP_REPO" "$ICP_GIT" "$ICP_REF")"
WORKFLOW_REPO="$(resolve_repo module-ballerina-workflow "$WORKFLOW_REPO" "$WORKFLOW_GIT" "$WORKFLOW_REF")"
BRIDGE_REPO="$(resolve_repo icp-runtime-bridge "$BRIDGE_REPO" "$BRIDGE_GIT" "$BRIDGE_REF")"

# ── 1. ICP distribution ──────────────────────────────────────────────────────
if [ "$SKIP_ICP" -eq 0 ]; then
    log "Assembling the ICP distribution"
    # CI=true because assembleICP runs `pnpm install`, and pnpm refuses to recreate a
    # node_modules directory it did not create without a TTY —
    # ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY. This build is non-interactive by
    # definition, which is exactly what that variable declares.
    # Drop prior frontend output first: gradle has packed a dist/ older than the
    # checked-out sources before, shipping a stale console into the zip.
    (cd "$ICP_REPO" && rm -rf frontend/dist www/assets www/index.html && CI=true ./gradlew assembleICP)
    cp "$ICP_REPO/build/distribution/${ICP_DIST}.zip" "icp/artifacts/${ICP_DIST}.zip"
    echo "staged icp/artifacts/${ICP_DIST}.zip"
fi

# ── 2. SQL scripts, staged so Postgres initialises from the real ones ────────
log "Staging the ICP SQL scripts"
cp "$ICP_REPO/icp_server/resources/db/init-scripts/postgresql_init.sql" artifacts/db/
cp "$ICP_REPO/icp_server/resources/db/init-scripts/credentials_postgresql_init.sql" artifacts/db/
# Every PostgreSQL migration the ref ships, by glob rather than by name. A fresh database
# gets its schema from postgresql_init.sql; these are the scripts an existing deployment
# runs, staged so that path can be exercised here too. Naming one file explicitly means a
# rename upstream stages nothing and reports it as the branch being old -- which is how
# add_workflow_tunnel_*.sql kept "succeeding" after it became add_cache_tables_*.sql.
# Stale copies are cleared first so a rename cannot leave both names in place.
rm -f artifacts/db/add_*_postgresql.sql
migrations=("$ICP_REPO"/icp_server/resources/db/migration-scripts/*_postgresql.sql)
[ -e "${migrations[0]}" ] || { echo "no *_postgresql.sql migrations in $ICP_REF" >&2; exit 1; }
cp "${migrations[@]}" artifacts/db/
echo "staged artifacts/db: $(ls artifacts/db | tr '\n' ' ')"

# ── 3. Dependencies into the local bala repository ────────────────────────────
if [ "$SKIP_DEPS" -eq 0 ]; then
    log "Publishing the workflow module to the local repository"
    (cd "$WORKFLOW_REPO" && ./gradlew :workflow-ballerina:build -x test)
    (cd "$WORKFLOW_REPO/ballerina" && bal pack)
    # A stale cache entry fails later with "unexpected type: other" while loading the BIR.
    rm -rf "$HOME/.ballerina/repositories/local/cache-${BAL_DIST_VERSION}/ballerina/workflow"
    (cd "$WORKFLOW_REPO/ballerina" && bal push --repository=local)

    log "Publishing the ICP bridge to the local repository"
    # The bridge builds as a connector, which needs Docker.
    (cd "$BRIDGE_REPO" && ./gradlew build -x test)
    bala=$(find "$BRIDGE_REPO/ballerina/build/bal_build_target/bala" -name "wso2-icp.runtime.bridge-*.bala" | head -1)
    [ -n "$bala" ] || { echo "no bridge bala found - did the gradle build succeed?" >&2; exit 1; }
    rm -rf "$HOME/.ballerina/repositories/local/cache-${BAL_DIST_VERSION}/wso2/icp.runtime.bridge"
    bal push --repository=local "$bala"
fi

# ── 4. Integrations ──────────────────────────────────────────────────────────
if [ "$SKIP_INTEGRATIONS" -eq 0 ]; then
    for name in expense orders; do
        log "Building the ${name} integration"
        (cd "integrations/${name}" && rm -rf target && bal build)
        jar=$(find "integrations/${name}/target/bin" -name "*.jar" | head -1)
        [ -n "$jar" ] || { echo "no jar produced for ${name}" >&2; exit 1; }
        cp "$jar" "integrations/${name}/artifacts/${name}_integration.jar"
        echo "staged integrations/${name}/artifacts/${name}_integration.jar"
    done
fi

log "Done. Next: scripts/bootstrap.sh"
