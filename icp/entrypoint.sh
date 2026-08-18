#!/usr/bin/env bash
# Renders conf/deployment.toml from the template, then runs the server in the foreground so
# Docker owns the process lifecycle (bin/icp.sh start would daemonise and exit).
set -euo pipefail

: "${ICP_DB_HOST:=postgres}"
: "${ICP_DB_NAME:=icp_db}"
: "${ICP_DB_USER:=icp_user}"
: "${ICP_DB_PASSWORD:=icp_password}"
: "${ICP_PUBLIC_BASE_URL:=https://localhost:9446}"
: "${ICP_NODE_ID:=icp-1}"

sed -e "s|@ICP_DB_HOST@|${ICP_DB_HOST}|g" \
    -e "s|@ICP_DB_NAME@|${ICP_DB_NAME}|g" \
    -e "s|@ICP_DB_USER@|${ICP_DB_USER}|g" \
    -e "s|@ICP_DB_PASSWORD@|${ICP_DB_PASSWORD}|g" \
    -e "s|@ICP_PUBLIC_BASE_URL@|${ICP_PUBLIC_BASE_URL}|g" \
    /opt/icp/conf/deployment.toml.tmpl > /opt/icp/conf/deployment.toml

echo "[entrypoint] ${ICP_NODE_ID}: postgresql://${ICP_DB_USER}@${ICP_DB_HOST}/${ICP_DB_NAME}, public ${ICP_PUBLIC_BASE_URL}"
exec /opt/icp/bin/icp.sh run
