#!/bin/bash
# build-and-deploy.sh — build webdav-mcp for macOS (native), aarch64, and
# riscv64, then deploy binaries to localhost, radxa, and orangepi.
#
# Environment variables (all optional):
#   RADXA_HOST          — ssh host for aarch64 deploy         (default: radxa)
#   ORANGEPI_HOST       — ssh host for riscv64 deploy         (default: orangepi)
#   DEPLOY_BIN_DIR      — bin directory on remote hosts       (default: ~/bin)
#   LOCAL_BIN_DIR       — bin directory on the local machine  (default: ~/bin)
set -euo pipefail
cd "$(dirname "$0")"

RADXA_HOST=${RADXA_HOST:-radxa}
ORANGEPI_HOST=${ORANGEPI_HOST:-orangepi}
DEPLOY_BIN_DIR=${DEPLOY_BIN_DIR:-~/bin}
LOCAL_BIN_DIR=${LOCAL_BIN_DIR:-~/bin}

echo "=== Building native ($(uname -m)) ==="
zig build -Doptimize=ReleaseSmall
rm -f "${LOCAL_BIN_DIR}/webdav-mcp"
cp zig-out/bin/webdav-mcp "${LOCAL_BIN_DIR}/webdav-mcp"
echo "    Installed: ${LOCAL_BIN_DIR}/webdav-mcp ($(du -h "${LOCAL_BIN_DIR}/webdav-mcp" | cut -f1))"

echo ""
echo "=== Building aarch64-linux-musl ==="
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
cp zig-out/bin/webdav-mcp zig-out/bin/webdav-mcp-aarch64

echo ""
echo "=== Building riscv64-linux-musl ==="
zig build -Dtarget=riscv64-linux-musl -Doptimize=ReleaseSmall
cp zig-out/bin/webdav-mcp zig-out/bin/webdav-mcp-riscv64

echo ""
echo "=== Deploying aarch64 to ${RADXA_HOST}:${DEPLOY_BIN_DIR}/ ==="
ssh "${RADXA_HOST}" "mkdir -p ${DEPLOY_BIN_DIR} && rm -f ${DEPLOY_BIN_DIR}/webdav-mcp"
scp zig-out/bin/webdav-mcp-aarch64 "${RADXA_HOST}:${DEPLOY_BIN_DIR}/webdav-mcp"
echo "    Deployed."

echo ""
echo "=== Deploying riscv64 to ${ORANGEPI_HOST}:${DEPLOY_BIN_DIR}/ ==="
ssh "${ORANGEPI_HOST}" "mkdir -p ${DEPLOY_BIN_DIR} && rm -f ${DEPLOY_BIN_DIR}/webdav-mcp"
scp zig-out/bin/webdav-mcp-riscv64 "${ORANGEPI_HOST}:${DEPLOY_BIN_DIR}/webdav-mcp"
echo "    Deployed."

echo ""
echo "=== Restoring native build ==="
zig build -Doptimize=ReleaseSmall

echo ""
echo "=== Done ==="
ls -lh zig-out/bin/webdav-mcp*
file zig-out/bin/webdav-mcp*
