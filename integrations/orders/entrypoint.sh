#!/usr/bin/env bash
# Renders Config.toml from the environment. The org secret cannot be baked into the image:
# it is created against a running ICP by scripts/bootstrap.sh.
set -euo pipefail

: "${ICP_SERVER_URL:=https://edge:9445}"
: "${ICP_ORG_SECRET:?ICP_ORG_SECRET is required - run scripts/bootstrap.sh}"
: "${ICP_PROJECT:=workflow_icp_test}"
: "${ICP_ENVIRONMENT:=dev}"
: "${TEMPORAL_URL:=temporal:7233}"
: "${HEARTBEAT_INTERVAL:=10}"

sed -e "s|@ICP_SERVER_URL@|${ICP_SERVER_URL}|g" \
    -e "s|@ICP_ORG_SECRET@|${ICP_ORG_SECRET}|g" \
    -e "s|@ICP_PROJECT@|${ICP_PROJECT}|g" \
    -e "s|@ICP_ENVIRONMENT@|${ICP_ENVIRONMENT}|g" \
    -e "s|@TEMPORAL_URL@|${TEMPORAL_URL}|g" \
    -e "s|@HEARTBEAT_INTERVAL@|${HEARTBEAT_INTERVAL}|g" \
    /app/Config.toml.tmpl > /app/Config.toml

echo "[entrypoint] $(hostname): temporal=${TEMPORAL_URL} icp=${ICP_SERVER_URL} project=${ICP_PROJECT}"
export BAL_CONFIG_FILES=/app/Config.toml
exec java -jar /app/app.jar
