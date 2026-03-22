#!/bin/bash
# build-and-deploy.sh — build webdav-mcp for macOS (native) and riscv64 (remote),
# then deploy binaries locally and to a remote host via scp.
#
# Environment variables (all optional):
#   DEPLOY_HOST     — ssh host to deploy riscv64 binary to  (default: orangepi)
#   DEPLOY_BIN_DIR  — bin directory on the remote host       (default: ~/bin)
#   LOCAL_BIN_DIR   — bin directory on the local machine     (default: ~/bin)
set -euo pipefail
cd "$(dirname "$0")"

DEPLOY_HOST=${DEPLOY_HOST:-orangepi}
DEPLOY_BIN_DIR=${DEPLOY_BIN_DIR:-~/bin}
LOCAL_BIN_DIR=${LOCAL_BIN_DIR:-~/bin}

echo "=== Building native ($(uname -m)) ==="
zig build -Doptimize=ReleaseSmall
rm -f "${LOCAL_BIN_DIR}/webdav-mcp"
cp zig-out/bin/webdav-mcp "${LOCAL_BIN_DIR}/webdav-mcp"
echo "    Installed: ${LOCAL_BIN_DIR}/webdav-mcp ($(du -h "${LOCAL_BIN_DIR}/webdav-mcp" | cut -f1))"

echo ""
echo "=== Building riscv64-linux-musl ==="
zig build -Dtarget=riscv64-linux-musl -Doptimize=ReleaseSmall
cp zig-out/bin/webdav-mcp zig-out/bin/webdav-mcp-riscv64

echo ""
echo "=== Deploying to ${DEPLOY_HOST}:${DEPLOY_BIN_DIR}/ ==="
ssh "${DEPLOY_HOST}" "rm -f ${DEPLOY_BIN_DIR}/webdav-mcp"
scp zig-out/bin/webdav-mcp-riscv64 "${DEPLOY_HOST}:${DEPLOY_BIN_DIR}/webdav-mcp"
echo "    Deployed."

echo ""
echo "=== Restoring native build ==="
zig build -Doptimize=ReleaseSmall

echo ""
echo "=== Done ==="
ls -lh zig-out/bin/webdav-mcp*
file zig-out/bin/webdav-mcp*
