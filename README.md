# webdav-mcp

A zero-dependency WebDAV MCP server — single static binary, no Node.js or Python required.

Implements the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP) over JSON-RPC 2.0 via stdio, exposing 8 WebDAV operations as tools that any MCP-compatible AI agent can call.

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
| `copy` | Copy a file or directory (sends `Depth: infinity` per RFC 4918 §9.8.2) |
| `stat` | Get metadata for a single file or directory (PROPFIND Depth:0) |

### Tool parameters

**`list`**
- `path` (required) — directory path relative to WebDAV root
- `recursive` (boolean, default `false`) — if `true`, lists recursively using `Depth: infinity`. Note: some servers (IIS, some nginx configs) block recursive listing.

**`read`**
- `path` (required) — file path relative to WebDAV root
- `max_bytes` (integer, default `1048576`) — maximum file size to read in bytes. Returns an error if the file is larger. Increase this for large files.

**`write`**
- `path` (required) — file path relative to WebDAV root
- `content` (required) — content to write
- `content_type` (string, default `application/octet-stream`) — MIME type for the file (e.g. `text/plain`, `application/json`)
- `create_parents` (boolean, default `false`) — if `true` and the parent directory does not exist, automatically creates all missing ancestor directories via MKCOL before writing

**`stat`**
- `path` (required) — path to stat relative to WebDAV root
- Returns: `file` or `dir` or `missing`, plus `size=`, `modified=`, `etag=`, and `type=` when available

## Configuration

Set these environment variables before launching the server:

| Variable | Description | Example |
|----------|-------------|---------|
| `WEBDAV_URL` | Base URL of the WebDAV server | `http://192.168.1.10:8080` |
| `WEBDAV_USER` | Username | `admin` |
| `WEBDAV_PASS` | Password | `secret` |

### Credential security

Credentials are sent via native Zig HTTP networking using the `Authorization: Basic ...` header. No external `curl` process is spawned.

## Building from source

Requires [Zig 0.16.0](https://ziglang.org/download/).

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

The server speaks JSON-RPC 2.0 over stdio (newline-delimited), which is the standard MCP transport. Once registered, the agent can call all 8 tools as normal tool calls.

## Running tests

```bash
zig build test --summary all
```

All unit tests cover XML parsing, JSON-RPC dispatch, argument extraction, URL construction, percent-encoding, entity decoding, and HTTP method routing.

## License

MIT — see [LICENSE](LICENSE).

<!-- mcp-name: io.github.vernonstinebaker/webdav-mcp -->
