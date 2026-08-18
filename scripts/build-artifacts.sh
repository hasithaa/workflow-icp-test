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

# Where your checkouts are. Override if your layout differs.
: "${SRC_ROOT:=$HOME/Source/workflow/ICP_REWAMP}"
: "${ICP_REPO:=$SRC_ROOT/integration-control-plane}"
: "${WORKFLOW_REPO:=$SRC_ROOT/module-ballerina-workflow}"
: "${BRIDGE_REPO:=$SRC_ROOT/icp-runtime-bridge}"
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
require_dir() { [ -d "$1" ] || { echo "missing: $1 (set SRC_ROOT or the individual *_REPO vars)" >&2; exit 1; }; }

mkdir -p icp/artifacts artifacts/db integrations/expense/artifacts integrations/orders/artifacts

# ── 1. ICP distribution ──────────────────────────────────────────────────────
if [ "$SKIP_ICP" -eq 0 ]; then
    require_dir "$ICP_REPO"
    log "Assembling the ICP distribution"
    (cd "$ICP_REPO" && ./gradlew assembleICP)
    cp "$ICP_REPO/build/distribution/${ICP_DIST}.zip" "icp/artifacts/${ICP_DIST}.zip"
    echo "staged icp/artifacts/${ICP_DIST}.zip"
fi

# ── 2. SQL scripts, staged so Postgres initialises from the real ones ────────
require_dir "$ICP_REPO"
log "Staging the ICP SQL scripts"
cp "$ICP_REPO/icp_server/resources/db/init-scripts/postgresql_init.sql" artifacts/db/
cp "$ICP_REPO/icp_server/resources/db/init-scripts/credentials_postgresql_init.sql" artifacts/db/
cp "$ICP_REPO/icp_server/resources/db/migration-scripts/add_workflow_feature_postgresql.sql" artifacts/db/
echo "staged artifacts/db: $(ls artifacts/db | tr '\n' ' ')"

# ── 3. Dependencies into the local bala repository ────────────────────────────
if [ "$SKIP_DEPS" -eq 0 ]; then
    require_dir "$WORKFLOW_REPO"
    require_dir "$BRIDGE_REPO"

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
