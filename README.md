# webdav-mcp

A zero-dependency WebDAV MCP server — single static binary, no Node.js or Python required.

Implements the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) over JSON-RPC 2.0 via stdio, exposing 7 WebDAV operations as tools that any MCP-compatible AI agent can call.

## Why this exists

Every other WebDAV MCP server on GitHub requires a Node.js or Python runtime. This one is a single self-contained binary (~100–160 KB) compiled from Zig. It runs anywhere without installing a runtime, and it cross-compiles to all major platforms from one machine.

## Tools

| Tool | Description |
|------|-------------|
| `list` | List files and directories at a path |
| `read` | Read file contents as text |
| `write` | Write (create or overwrite) a file |
| `delete` | Delete a file or directory |
| `mkdir` | Create a directory |
| `move` | Move or rename a file or directory |
| `copy` | Copy a file or directory |

## Configuration

Set these environment variables before launching the server:

| Variable | Description | Example |
|----------|-------------|---------|
| `WEBDAV_URL` | Base URL of the WebDAV server | `http://192.168.1.10:8080` |
| `WEBDAV_USER` | Username | `admin` |
| `WEBDAV_PASS` | Password | `secret` |

## Building from source

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
# Development build
zig build

# Optimized release build (~100-160 KB)
zig build -Doptimize=ReleaseSmall

# Cross-compile for all platforms (outputs to zig-out/release/)
zig build cross
```

### Cross-compilation targets

| File | Platform |
|------|----------|
| `webdav-mcp-macos-arm64` | macOS Apple Silicon |
| `webdav-mcp-macos-x86_64` | macOS Intel |
| `webdav-mcp-linux-arm64` | Linux ARM64 (static musl) |
| `webdav-mcp-linux-x86_64` | Linux x86-64 (static musl) |
| `webdav-mcp-linux-armv7` | Linux ARMv7 / Raspberry Pi (static musl) |
| `webdav-mcp-windows-x86_64.exe` | Windows x86-64 |

## Integration with nullclaw / *Claw bots

Add an `mcp_servers` entry to your bot's `config.json`:

```json
{
  "mcp_servers": {
    "webdav": {
      "command": "/path/to/webdav-mcp",
      "args": [],
      "env": {
        "WEBDAV_URL": "http://your-webdav-server:8080",
        "WEBDAV_USER": "your-username",
        "WEBDAV_PASS": "your-password"
      }
    }
  }
}
```

The server speaks JSON-RPC 2.0 over stdio (newline-delimited), which is the standard MCP transport. Once registered, the agent can call `list`, `read`, `write`, `delete`, `mkdir`, `move`, and `copy` as normal tools.

## Running tests

```bash
zig build test --summary all
```

All 15 unit tests cover XML parsing, JSON-RPC dispatch, argument extraction, URL construction, and HTTP method routing.

## License

MIT — see [LICENSE](LICENSE).
