#!/bin/bash
# build-and-deploy.sh — build webdav-mcp for macOS (native) and OrangePi (riscv64),
# then deploy binaries to ~/bin/ and orangepi:~/bin/.
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Building native ($(uname -m)) ==="
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/webdav-mcp ~/bin/webdav-mcp
echo "    Installed: ~/bin/webdav-mcp ($(du -h ~/bin/webdav-mcp | cut -f1))"

echo ""
echo "=== Building riscv64-linux-musl ==="
zig build -Dtarget=riscv64-linux-musl -Doptimize=ReleaseSmall
cp zig-out/bin/webdav-mcp zig-out/bin/webdav-mcp-riscv64

echo ""
echo "=== Deploying to orangepi:~/bin/ ==="
scp zig-out/bin/webdav-mcp-riscv64 orangepi:~/bin/webdav-mcp
echo "    Deployed."

echo ""
echo "=== Restoring native build ==="
zig build -Doptimize=ReleaseSmall

echo ""
echo "=== Done ==="
ls -lh zig-out/bin/webdav-mcp*
file zig-out/bin/webdav-mcp*
