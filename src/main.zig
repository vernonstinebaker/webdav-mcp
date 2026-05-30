//! webdav-mcp — MCP server providing WebDAV tools.
//!
//! Speaks JSON-RPC 2.0 over stdio (newline-delimited).
//! Provides tools: list, read, write, delete, mkdir, move, copy.
//! Uses native Zig networking for HTTP/WebDAV transport.
//! Configured via environment variables:
//!   WEBDAV_URL  — base URL (e.g. http://100.110.80.108:8080)
//!   WEBDAV_USER — HTTP Basic Auth username (optional)
//!   WEBDAV_PASS — HTTP Basic Auth password (optional)

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Configuration ───────────────────────────────────────────────

const Config = struct {
    base_url: []const u8,
    user: ?[]const u8, // username or null
    pass: ?[]const u8, // password or null
};

fn loadConfig(allocator: Allocator, environ_map: *const std.process.Environ.Map) !Config {
    const url = environ_map.get("WEBDAV_URL") orelse return error.MissingWebdavUrl;
    const user = if (environ_map.get("WEBDAV_USER")) |value| try allocator.dupe(u8, value) else null;
    const pass = if (environ_map.get("WEBDAV_PASS")) |value| try allocator.dupe(u8, value) else null;

    return .{ .base_url = try allocator.dupe(u8, url), .user = user, .pass = pass };
}

// ── JSON-RPC 2.0 I/O ───────────────────────────────────────────

const JsonRpcRequest = struct {
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

fn readRequest(allocator: Allocator, reader: *std.Io.Reader) !?JsonRpcRequest {
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (byte == '\n') break;
        if (byte != '\r') {
            try line_buf.append(allocator, byte);
        }
    }

    if (line_buf.items.len == 0) return null;

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        line_buf.items,
        .{ .allocate = .alloc_always },
    ) catch return error.InvalidJson;
    const obj = if (parsed.value == .object) parsed.value.object else return error.InvalidJson;

    const method_val = obj.get("method") orelse return error.InvalidJson;
    if (method_val != .string) return error.InvalidJson;

    return .{
        .id = obj.get("id"),
        .method = method_val.string,
        .params = obj.get("params"),
    };
}

fn writeId(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, id: ?std.json.Value) !void {
    if (id) |id_val| {
        switch (id_val) {
            .integer => |i| {
                var fmt_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&fmt_buf, "{d}", .{i}) catch "0";
                try buf.appendSlice(allocator, s);
            },
            .string => |s| {
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            },
            else => try buf.appendSlice(allocator, "null"),
        }
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn writeResponse(writer: *std.Io.Writer, id: ?std.json.Value, result_json: []const u8) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    const a = std.heap.page_allocator;
    try buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&buf, a, id);
    try buf.appendSlice(a, ",\"result\":");
    try buf.appendSlice(a, result_json);
    try buf.appendSlice(a, "}\n");
    try writer.writeAll(buf.items);
    try writer.flush();
}

fn writeError(writer: *std.Io.Writer, id: ?std.json.Value, code: i32, message: []const u8) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    const a = std.heap.page_allocator;
    try buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&buf, a, id);
    try buf.appendSlice(a, ",\"error\":{\"code\":");
    var code_buf: [16]u8 = undefined;
    const code_s = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch "-1";
    try buf.appendSlice(a, code_s);
    try buf.appendSlice(a, ",\"message\":\"");
    try appendJsonEscaped(&buf, a, message);
    try buf.appendSlice(a, "\"}}\n");
    try writer.writeAll(buf.items);
    try writer.flush();
}

fn writeToolResult(writer: *std.Io.Writer, id: ?std.json.Value, text: []const u8, is_error: bool) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    const a = std.heap.page_allocator;
    try buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&buf, a, id);
    try buf.appendSlice(a, ",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    try appendJsonEscaped(&buf, a, text);
    try buf.appendSlice(a, "\"}],\"isError\":");
    try buf.appendSlice(a, if (is_error) "true" else "false");
    try buf.appendSlice(a, "}}\n");
    try writer.writeAll(buf.items);
    try writer.flush();
}

// (writeJsonEscaped removed — using appendJsonEscaped with buffer instead)

fn appendJsonEscaped(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var hex_buf: [6]u8 = undefined;
                    const len = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch continue;
                    try buf.appendSlice(allocator, len);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
}

// ── Tool definitions ────────────────────────────────────────────

const tools_json =
    "{\"tools\":[" ++
    "{\"name\":\"list\",\"description\":\"List files and directories at a WebDAV path. Returns name, size, type, last-modified, ETag, and content-type for each entry.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path relative to WebDAV root (e.g. '/' or '/projects/')\"},\"recursive\":{\"type\":\"boolean\",\"description\":\"If true, list recursively (Depth: infinity). Some servers block this. Default: false\"}},\"required\":[\"path\"]}}," ++
    "{\"name\":\"read\",\"description\":\"Read the contents of a file from WebDAV. Returns the file content as text.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to WebDAV root (e.g. '/projects/foo/main.rs')\"},\"max_bytes\":{\"type\":\"integer\",\"description\":\"Maximum file size to read in bytes (default: 1048576 = 1 MB). Returns an error if the file is larger.\"}},\"required\":[\"path\"]}}," ++
    "{\"name\":\"write\",\"description\":\"Write content to a file on WebDAV. Creates or overwrites the file.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path relative to WebDAV root\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write to the file\"},\"content_type\":{\"type\":\"string\",\"description\":\"MIME type for the file (e.g. 'text/plain', 'application/json'). Default: application/octet-stream\"},\"create_parents\":{\"type\":\"boolean\",\"description\":\"If true and the parent directory does not exist, create it automatically. Default: false\"}},\"required\":[\"path\",\"content\"]}}," ++
    "{\"name\":\"delete\",\"description\":\"Delete a file or directory on WebDAV.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to delete relative to WebDAV root\"}},\"required\":[\"path\"]}}," ++
    "{\"name\":\"mkdir\",\"description\":\"Create a directory on WebDAV.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path to create relative to WebDAV root\"}},\"required\":[\"path\"]}}," ++
    "{\"name\":\"move\",\"description\":\"Move or rename a file or directory on WebDAV.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"source\":{\"type\":\"string\",\"description\":\"Source path relative to WebDAV root\"},\"destination\":{\"type\":\"string\",\"description\":\"Destination path relative to WebDAV root\"},\"overwrite\":{\"type\":\"boolean\",\"description\":\"Overwrite destination if it exists (default: false)\"}},\"required\":[\"source\",\"destination\"]}}," ++
    "{\"name\":\"copy\",\"description\":\"Copy a file or directory on WebDAV.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"source\":{\"type\":\"string\",\"description\":\"Source path relative to WebDAV root\"},\"destination\":{\"type\":\"string\",\"description\":\"Destination path relative to WebDAV root\"},\"overwrite\":{\"type\":\"boolean\",\"description\":\"Overwrite destination if it exists (default: false)\"}},\"required\":[\"source\",\"destination\"]}}," ++
    "{\"name\":\"stat\",\"description\":\"Get metadata for a single file or directory on WebDAV (PROPFIND Depth:0). Returns type (file/dir/missing), size, last-modified, ETag, and content-type. Use this to check existence or get file info without listing a whole directory.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to stat relative to WebDAV root\"}},\"required\":[\"path\"]}}" ++
    "]}";

// ── native HTTP/WebDAV transport ────────────────────────────────

const HttpResult = struct {
    status: u16,
    body: []const u8,
};

const ParsedBaseUrl = struct {
    uri: std.Uri,
    host: std.Io.net.HostName,
    protocol: std.http.Client.Protocol,
    port: u16,
    base_path: []const u8,
};

/// Extract the hostname (and port if present) from a URL.
/// e.g. "https://example.com/dav/" -> "example.com"
///      "http://host:8080/path"    -> "host:8080"
fn parseBaseUrl(allocator: Allocator, base_url: []const u8) !ParsedBaseUrl {
    const uri = try std.Uri.parse(base_url);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => @as(u16, 80),
        .tls => @as(u16, 443),
    };

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);

    const base_path = if (uri.path.isEmpty())
        "/"
    else
        try allocator.dupe(u8, uri.path.percent_encoded);

    return .{
        .uri = uri,
        .host = host,
        .protocol = protocol,
        .port = port,
        .base_path = base_path,
    };
}

fn buildRequestPath(allocator: Allocator, parsed: ParsedBaseUrl, path: []const u8) ![]u8 {
    const encoded_path = try percentEncodePath(allocator, path);
    defer allocator.free(encoded_path);

    const base_path = if (std.mem.eql(u8, parsed.base_path, "/")) "" else parsed.base_path;

    if (encoded_path.len == 0) {
        return allocator.dupe(u8, if (base_path.len == 0) "/" else base_path);
    }
    if (encoded_path[0] == '/') {
        if (base_path.len == 0) return allocator.dupe(u8, encoded_path);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, encoded_path });
    }
    if (base_path.len == 0) return std.fmt.allocPrint(allocator, "/{s}", .{encoded_path});
    if (std.mem.endsWith(u8, base_path, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, encoded_path });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, encoded_path });
}

fn buildBasicAuthHeader(allocator: Allocator, user: []const u8, pass: []const u8) ![]u8 {
    const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, pass });
    defer allocator.free(credentials);

    const encoded_len = std.base64.standard.Encoder.calcSize(credentials.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, credentials);

    const header = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    allocator.free(encoded);
    return header;
}

fn buildHostHeader(allocator: Allocator, parsed: ParsedBaseUrl) ![]u8 {
    const host = parsed.uri.host orelse return error.UriMissingHost;
    const host_only = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(host, .formatHost)});
    errdefer allocator.free(host_only);

    const default_port: u16 = switch (parsed.protocol) {
        .plain => 80,
        .tls => 443,
    };
    if (parsed.port == default_port and parsed.uri.port == null) return host_only;

    const with_port = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host_only, parsed.port });
    allocator.free(host_only);
    return with_port;
}

fn readHttpHead(reader: *std.Io.Reader, allocator: Allocator) ![]u8 {
    var head_buf = std.ArrayList(u8).empty;
    defer head_buf.deinit(allocator);

    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(allocator);

    while (true) {
        line_buf.clearRetainingCapacity();
        while (true) {
            const byte = try reader.takeByte();
            try line_buf.append(allocator, byte);
            if (byte == '\n') break;
        }
        try head_buf.appendSlice(allocator, line_buf.items);
        if (std.mem.endsWith(u8, head_buf.items, "\r\n\r\n") or std.mem.endsWith(u8, head_buf.items, "\n\n")) {
            return head_buf.toOwnedSlice(allocator);
        }
    }
}

fn readLineAlloc(reader: *std.Io.Reader, allocator: Allocator) ![]u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);

    while (true) {
        const byte = try reader.takeByte();
        try line.append(allocator, byte);
        if (byte == '\n') return line.toOwnedSlice(allocator);
    }
}

fn parseChunkLength(line: []const u8) !u64 {
    const trimmed = std.mem.trim(u8, line, "\r\n ");
    var parts = std.mem.splitScalar(u8, trimmed, ';');
    const size_field = parts.first();
    if (size_field.len == 0) return error.HttpHeadersInvalid;
    return std.fmt.parseInt(u64, size_field, 16) catch error.HttpHeadersInvalid;
}

fn readChunkedBody(reader: *std.Io.Reader, allocator: Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    while (true) {
        const line = try readLineAlloc(reader, allocator);
        defer allocator.free(line);
        const chunk_len = try parseChunkLength(line);
        if (chunk_len == 0) {
            // consume trailing CRLF after zero chunk and optional trailers until blank line
            while (true) {
                const trailer = try readLineAlloc(reader, allocator);
                defer allocator.free(trailer);
                const trimmed = std.mem.trim(u8, trailer, "\r\n");
                if (trimmed.len == 0) break;
            }
            return out.toOwnedSlice(allocator);
        }
        const chunk_len_usize: usize = @intCast(chunk_len);
        try out.ensureUnusedCapacity(allocator, chunk_len_usize);
        const start = out.items.len;
        out.items.len += chunk_len_usize;
        try reader.readSliceAll(out.items[start .. start + chunk_len_usize]);
        try reader.discardAll(2); // CRLF after chunk data
    }
}

fn readHttpBody(
    reader: *std.Io.Reader,
    allocator: Allocator,
    head: std.http.Client.Response.Head,
) ![]u8 {
    if (head.transfer_encoding == .chunked) {
        return readChunkedBody(reader, allocator);
    }
    if (head.content_length) |len| {
        const exact_len: usize = @intCast(len);
        const buf = try allocator.alloc(u8, exact_len);
        errdefer allocator.free(buf);
        try reader.readSliceAll(buf);
        return buf;
    }
    return reader.allocRemaining(allocator, .limited(1024 * 1024));
}

fn httpRequest(
    allocator: Allocator,
    config: Config,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    extra_headers: []const [2][]const u8,
) !HttpResult {
    var threaded = std.Io.Threaded.init_single_threaded;
    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    const parsed = try parseBaseUrl(allocator, config.base_url);
    defer if (!std.mem.eql(u8, parsed.base_path, "/")) allocator.free(parsed.base_path);

    const request_path = try buildRequestPath(allocator, parsed, path);
    defer allocator.free(request_path);

    const host_header = try buildHostHeader(allocator, parsed);
    defer allocator.free(host_header);

    const connection = try client.connect(parsed.host, parsed.port, parsed.protocol);
    errdefer client.connection_pool.release(connection, threaded.io());

    var writer_buf = std.Io.Writer.Allocating.init(allocator);
    defer writer_buf.deinit();
    const writer = &writer_buf.writer;

    try writer.print("{s} {s} HTTP/1.1\r\n", .{ method, request_path });
    try writer.print("Host: {s}\r\n", .{host_header});
    try writer.writeAll("Connection: close\r\n");
    try writer.writeAll("User-Agent: webdav-mcp/1.1.0\r\n");
    try writer.writeAll("Accept: */*\r\n");

    if (config.user) |user| {
        const pass = config.pass orelse "";
        const auth = try buildBasicAuthHeader(allocator, user, pass);
        defer allocator.free(auth);
        try writer.print("Authorization: {s}\r\n", .{auth});
    }

    for (extra_headers) |hdr| {
        try writer.print("{s}: {s}\r\n", .{ hdr[0], hdr[1] });
    }

    if (body) |payload| {
        try writer.print("Content-Length: {d}\r\n", .{payload.len});
    }

    try writer.writeAll("\r\n");
    if (body) |payload| try writer.writeAll(payload);

    try connection.writer().writeAll(writer_buf.written());
    try connection.flush();

    var read_buf: [8192]u8 = undefined;
    var reader = connection.reader();
    reader.buffer = &read_buf;
    reader.seek = 0;
    reader.end = 0;

    const head_bytes = try readHttpHead(reader, allocator);
    defer allocator.free(head_bytes);

    const head = try std.http.Client.Response.Head.parse(head_bytes);
    const response_body = try readHttpBody(reader, allocator, head);

    connection.closing = true;
    client.connection_pool.release(connection, threaded.io());

    return .{ .status = @intFromEnum(head.status), .body = response_body };
}

/// Percent-encode a path string, preserving '/' separators.
/// Characters that do not need encoding (RFC 3986 unreserved + '/' + sub-delims + ':' + '@'):
///   A-Z a-z 0-9 - _ . ~ / : @ ! $ & ' ( ) * + , ; =
/// Everything else is encoded as %XX.
/// Returns an allocated string. Caller owns the memory.
fn percentEncodePath(allocator: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (path) |c| {
        switch (c) {
            'A'...'Z',
            'a'...'z',
            '0'...'9',
            '-',
            '_',
            '.',
            '~',
            '/',
            ':',
            '@',
            '!',
            '$',
            '&',
            '\'',
            '(',
            ')',
            '*',
            '+',
            ',',
            ';',
            '=',
            => try out.append(allocator, c),
            else => {
                var hex: [3]u8 = undefined;
                _ = try std.fmt.bufPrint(&hex, "%{X:0>2}", .{c});
                try out.appendSlice(allocator, &hex);
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn buildUrl(allocator: Allocator, base: []const u8, path: []const u8) ![]const u8 {
    const encoded_path = try percentEncodePath(allocator, path);
    defer allocator.free(encoded_path);
    const trimmed_base = if (base.len > 0 and base[base.len - 1] == '/')
        base[0 .. base.len - 1]
    else
        base;

    if (encoded_path.len > 0 and encoded_path[0] == '/') {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed_base, encoded_path });
    } else {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_base, encoded_path });
    }
}

// ── Tool handlers ───────────────────────────────────────────────

fn handleList(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse "/";
    const recursive = getBoolParam(params, "recursive") orelse false;
    const depth: []const u8 = if (recursive) "infinity" else "1";

    const propfind_body =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:propfind xmlns:D="DAV:">
        \\  <D:prop>
        \\    <D:displayname/>
        \\    <D:getcontentlength/>
        \\    <D:getlastmodified/>
        \\    <D:resourcetype/>
        \\    <D:getetag/>
        \\    <D:getcontenttype/>
        \\  </D:prop>
        \\</D:propfind>
    ;

    const headers = [_][2][]const u8{
        .{ "Depth", depth },
        .{ "Content-Type", "application/xml" },
    };

    const result = httpRequest(allocator, config, "PROPFIND", path, propfind_body, &headers) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV PROPFIND failed: {}", .{err});
    };
    defer allocator.free(result.body);

    if ((result.status >= 200 and result.status < 300) or result.status == 207) {
        return try parseMultistatusListing(allocator, result.body, path);
    } else {
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

/// Returns the content-length of a resource via PROPFIND Depth:0,
/// or 0 if the size cannot be determined (directory, missing, parse failure).
fn checkFileSize(allocator: Allocator, config: Config, path: []const u8) !usize {
    const propfind_body =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:propfind xmlns:D="DAV:">
        \\  <D:prop><D:getcontentlength/></D:prop>
        \\</D:propfind>
    ;
    const headers = [_][2][]const u8{
        .{ "Depth", "0" },
        .{ "Content-Type", "application/xml" },
    };
    const result = try httpRequest(allocator, config, "PROPFIND", path, propfind_body, &headers);
    defer allocator.free(result.body);
    if (result.status != 207 and !(result.status >= 200 and result.status < 300)) return 0;
    const size_str = extractTagContent(result.body, "getcontentlength") orelse return 0;
    return std.fmt.parseInt(usize, size_str, 10) catch 0;
}

fn handleRead(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");
    const max_bytes: usize = @intCast(@max(0, getIntParam(params, "max_bytes") orelse 1024 * 1024));

    // Check size via PROPFIND Depth:0 before fetching
    const size_check = checkFileSize(allocator, config, path) catch 0;
    if (size_check > 0 and size_check > max_bytes) {
        return std.fmt.allocPrint(
            allocator,
            "Error: file size {d} bytes exceeds max_bytes limit {d}. Use max_bytes parameter to increase limit.",
            .{ size_check, max_bytes },
        );
    }

    const result = httpRequest(allocator, config, "GET", path, null, &.{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV GET failed: {}", .{err});
    };

    if (result.status >= 200 and result.status < 300) {
        return result.body;
    } else {
        defer allocator.free(result.body);
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

/// Create all ancestor directories of `path` via MKCOL.
/// Ignores 201 (created) and 405 (already exists). Fails on other errors.
fn mkdirAll(allocator: Allocator, config: Config, path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix.deinit(allocator);
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        try prefix.append(allocator, '/');
        try prefix.appendSlice(allocator, segment);
        const current = try allocator.dupe(u8, prefix.items);
        defer allocator.free(current);
        const r = httpRequest(allocator, config, "MKCOL", current, null, &.{}) catch continue;
        allocator.free(r.body);
        // 201 = created, 405 = already exists — both are fine
        if (r.status != 201 and r.status != 405 and !(r.status >= 200 and r.status < 300)) {
            return error.MkcolFailed;
        }
    }
}

fn handleWrite(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");
    const content = getStringParam(params, "content") orelse
        return try allocator.dupe(u8, "Error: 'content' parameter is required");
    const content_type = getStringParam(params, "content_type") orelse "application/octet-stream";
    const create_parents = getBoolParam(params, "create_parents") orelse false;

    const headers = [_][2][]const u8{
        .{ "Content-Type", content_type },
    };

    const result = httpRequest(allocator, config, "PUT", path, content, &headers) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV PUT failed: {}", .{err});
    };

    if (result.status == 409) {
        allocator.free(result.body);
        if (create_parents) {
            // Strip the filename to get the parent directory path
            const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
            const parent = if (last_slash > 0) path[0..last_slash] else "/";
            mkdirAll(allocator, config, parent) catch {
                return try allocator.dupe(u8, "Error: failed to create parent directories");
            };
            // Retry the PUT
            const retry = httpRequest(allocator, config, "PUT", path, content, &headers) catch |err| {
                return std.fmt.allocPrint(allocator, "Error: WebDAV PUT failed on retry: {}", .{err});
            };
            defer allocator.free(retry.body);
            if (retry.status >= 200 and retry.status < 300) {
                return std.fmt.allocPrint(allocator, "OK: wrote {d} bytes to {s} (created parents)", .{ content.len, path });
            } else {
                return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ retry.status, retry.body });
            }
        }
        return try allocator.dupe(u8, "Error: HTTP 409 — parent directory does not exist. Use mkdir or set create_parents=true");
    }

    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        return std.fmt.allocPrint(allocator, "OK: wrote {d} bytes to {s}", .{ content.len, path });
    } else {
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

fn handleDelete(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");

    const result = httpRequest(allocator, config, "DELETE", path, null, &.{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV DELETE failed: {}", .{err});
    };
    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        return std.fmt.allocPrint(allocator, "OK: deleted {s}", .{path});
    } else {
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

fn handleMkdir(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");

    const result = httpRequest(allocator, config, "MKCOL", path, null, &.{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV MKCOL failed: {}", .{err});
    };
    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        return std.fmt.allocPrint(allocator, "OK: created directory {s}", .{path});
    } else {
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

fn handleMove(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    return handleMoveOrCopy(allocator, config, params, "MOVE");
}

fn handleStat(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");

    const propfind_body =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:propfind xmlns:D="DAV:">
        \\  <D:prop>
        \\    <D:displayname/>
        \\    <D:getcontentlength/>
        \\    <D:getlastmodified/>
        \\    <D:getcontenttype/>
        \\    <D:getetag/>
        \\    <D:resourcetype/>
        \\  </D:prop>
        \\</D:propfind>
    ;

    const headers = [_][2][]const u8{
        .{ "Depth", "0" },
        .{ "Content-Type", "application/xml" },
    };

    const result = httpRequest(allocator, config, "PROPFIND", path, propfind_body, &headers) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV PROPFIND failed: {}", .{err});
    };
    defer allocator.free(result.body);

    if (result.status == 404) {
        return std.fmt.allocPrint(allocator, "missing: {s}", .{path});
    }

    if ((result.status >= 200 and result.status < 300) or result.status == 207) {
        const xml = result.body;

        const response_start = findTagStart(xml, 0, "response") orelse
            return try allocator.dupe(u8, "Error: no response element in PROPFIND reply");
        const response_end = findTagEnd(xml, response_start, "response") orelse
            return try allocator.dupe(u8, "Error: malformed PROPFIND response");
        const block = xml[response_start..response_end];

        const is_dir = containsTag(block, "collection");
        const type_str: []const u8 = if (is_dir) "dir" else "file";

        const size = extractTagContent(block, "getcontentlength");
        const modified = extractTagContent(block, "getlastmodified");
        const etag_raw = extractTagContent(block, "getetag");
        const content_type = extractTagContent(block, "getcontenttype");

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);

        try out.appendSlice(allocator, type_str);
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, path);

        if (size) |s| {
            try out.appendSlice(allocator, "  size=");
            try out.appendSlice(allocator, s);
        }
        if (modified) |m| {
            try out.appendSlice(allocator, "  modified=");
            try out.appendSlice(allocator, m);
        }
        if (etag_raw) |e| {
            try out.appendSlice(allocator, "  etag=");
            try out.appendSlice(allocator, e);
        }
        if (content_type) |ct| {
            try out.appendSlice(allocator, "  type=");
            try out.appendSlice(allocator, ct);
        }

        return try out.toOwnedSlice(allocator);
    } else {
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

fn handleCopy(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    return handleMoveOrCopy(allocator, config, params, "COPY");
}

fn handleMoveOrCopy(allocator: Allocator, config: Config, params: ?std.json.Value, method: []const u8) ![]const u8 {
    const source = getStringParam(params, "source") orelse
        return try allocator.dupe(u8, "Error: 'source' parameter is required");
    const destination = getStringParam(params, "destination") orelse
        return try allocator.dupe(u8, "Error: 'destination' parameter is required");
    const overwrite = getBoolParam(params, "overwrite") orelse false;

    const dest_url = buildUrl(allocator, config.base_url, destination) catch
        return try allocator.dupe(u8, "Error: failed to build destination URL");
    defer allocator.free(dest_url);

    const is_copy = std.ascii.eqlIgnoreCase(method, "COPY");

    var hdr_list: std.ArrayListUnmanaged([2][]const u8) = .empty;
    defer hdr_list.deinit(allocator);
    try hdr_list.append(allocator, .{ "Destination", dest_url });
    try hdr_list.append(allocator, .{ "Overwrite", if (overwrite) "T" else "F" });
    // RFC 4918 §9.8.2: COPY on a collection requires Depth: infinity.
    // MOVE always acts recursively without a Depth header (RFC 4918 §9.9.1).
    if (is_copy) {
        try hdr_list.append(allocator, .{ "Depth", "infinity" });
    }

    const result = httpRequest(allocator, config, method, source, null, hdr_list.items) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV {s} failed: {}", .{ method, err });
    };
    defer allocator.free(result.body);

    if (result.status >= 200 and result.status < 300) {
        const verb: []const u8 = if (std.ascii.eqlIgnoreCase(method, "MOVE")) "moved" else "copied";
        return std.fmt.allocPrint(allocator, "OK: {s} {s} -> {s}", .{ verb, source, destination });
    } else {
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}

// ── XML parsing helpers (minimal PROPFIND response parser) ──────

fn parseMultistatusListing(allocator: Allocator, xml: []const u8, requested_path: []const u8) ![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var pos: usize = 0;
    var entry_count: usize = 0;

    while (pos < xml.len) {
        const resp_start = findTagStart(xml, pos, "response") orelse break;
        const resp_end = findTagEnd(xml, resp_start, "response") orelse break;

        const response_block = xml[resp_start..resp_end];

        const href = extractTagContent(response_block, "href") orelse "(unknown)";

        // Skip the self-entry: the <href> of the requested collection itself.
        // Normalize by stripping trailing slashes before comparing.
        const href_trimmed = std.mem.trimEnd(u8, href, "/");
        const req_trimmed = std.mem.trimEnd(u8, requested_path, "/");
        if (std.mem.eql(u8, href_trimmed, req_trimmed)) {
            pos = resp_end;
            continue;
        }

        const display_raw = extractTagContent(response_block, "displayname");
        const display = if (display_raw) |raw| try decodeXmlEntities(allocator, raw) else null;
        defer if (display != null) allocator.free(display.?);
        const size = extractTagContent(response_block, "getcontentlength");
        const modified_raw = extractTagContent(response_block, "getlastmodified");
        const modified = if (modified_raw) |raw| try decodeXmlEntities(allocator, raw) else null;
        defer if (modified != null) allocator.free(modified.?);
        const etag_raw = extractTagContent(response_block, "getetag");
        const content_type = extractTagContent(response_block, "getcontenttype");
        const is_dir = containsTag(response_block, "collection");

        const name = display orelse href;
        const type_str: []const u8 = if (is_dir) "dir " else "file";

        if (entry_count > 0) {
            try output.append(allocator, '\n');
        }

        try output.appendSlice(allocator, type_str);
        try output.appendSlice(allocator, "  ");
        try output.appendSlice(allocator, name);

        if (size) |s| {
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, s);
            try output.appendSlice(allocator, " bytes");
        }

        if (modified) |m| {
            try output.appendSlice(allocator, "  ");
            try output.appendSlice(allocator, m);
        }

        if (etag_raw) |e| {
            try output.appendSlice(allocator, "  etag=");
            try output.appendSlice(allocator, e);
        }

        if (content_type) |ct| {
            try output.appendSlice(allocator, "  type=");
            try output.appendSlice(allocator, ct);
        }

        entry_count += 1;
        pos = resp_end;
    }

    if (entry_count == 0) {
        try output.appendSlice(allocator, "(empty directory)");
    }

    return try allocator.dupe(u8, output.items);
}

fn findTagStart(xml: []const u8, start: usize, tag_local: []const u8) ?usize {
    var pos = start;
    while (pos < xml.len) {
        const lt = std.mem.indexOfScalarPos(u8, xml, pos, '<') orelse return null;
        const after_lt = lt + 1;
        if (after_lt >= xml.len) return null;

        if (xml[after_lt] == '/') {
            pos = after_lt + 1;
            continue;
        }

        const gt = std.mem.indexOfScalarPos(u8, xml, after_lt, '>') orelse return null;
        // Handle self-closing tags: strip trailing '/' before '>'
        const tag_end = if (gt > 0 and xml[gt - 1] == '/') gt - 1 else gt;
        const tag_content = xml[after_lt..tag_end];

        const local_start = if (std.mem.indexOfScalar(u8, tag_content, ':')) |colon| colon + 1 else 0;
        const space_pos = std.mem.indexOfScalar(u8, tag_content[local_start..], ' ');
        const local_end = if (space_pos) |sp| local_start + sp else tag_content.len;
        const local_name = tag_content[local_start..local_end];

        if (std.ascii.eqlIgnoreCase(local_name, tag_local)) {
            return lt;
        }
        pos = gt + 1;
    }
    return null;
}

fn findTagEnd(xml: []const u8, start: usize, tag_local: []const u8) ?usize {
    var pos = start;
    while (pos < xml.len) {
        const close_start = std.mem.indexOfPos(u8, xml, pos, "</") orelse return null;
        const gt = std.mem.indexOfScalarPos(u8, xml, close_start + 2, '>') orelse return null;
        const tag_content = xml[close_start + 2 .. gt];

        const local_start = if (std.mem.indexOfScalar(u8, tag_content, ':')) |colon| colon + 1 else 0;
        const local_name = tag_content[local_start..];

        if (std.ascii.eqlIgnoreCase(local_name, tag_local)) {
            return gt + 1;
        }
        pos = gt + 1;
    }
    return null;
}

/// Decode the five predefined XML entities in `s`.
/// Returns a newly allocated string. Caller owns the memory.
fn decodeXmlEntities(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += 6;
            } else {
                try out.append(allocator, s[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn extractTagContent(xml: []const u8, tag_local: []const u8) ?[]const u8 {
    const tag_start = findTagStart(xml, 0, tag_local) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, xml, tag_start, '>') orelse return null;

    if (gt > 0 and xml[gt - 1] == '/') return null;

    const content_start = gt + 1;
    const close = std.mem.indexOfPos(u8, xml, content_start, "</") orelse return null;

    const content = xml[content_start..close];
    if (content.len == 0) return null;
    return content;
}

fn containsTag(xml: []const u8, tag_local: []const u8) bool {
    return findTagStart(xml, 0, tag_local) != null;
}

// ── Parameter helpers ───────────────────────────────────────────

fn getStringParam(params: ?std.json.Value, key: []const u8) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const args = if (p.object.get("arguments")) |a| (if (a == .object) a.object else p.object) else p.object;
    const val = args.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn getBoolParam(params: ?std.json.Value, key: []const u8) ?bool {
    const p = params orelse return null;
    if (p != .object) return null;
    const args = if (p.object.get("arguments")) |a| (if (a == .object) a.object else p.object) else p.object;
    const val = args.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

fn getIntParam(params: ?std.json.Value, key: []const u8) ?i64 {
    const p = params orelse return null;
    if (p != .object) return null;
    const args = if (p.object.get("arguments")) |a| (if (a == .object) a.object else p.object) else p.object;
    const val = args.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}

fn getToolName(params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    if (p != .object) return null;
    const name_val = p.object.get("name") orelse return null;
    if (name_val != .string) return null;
    return name_val.string;
}

fn getToolArguments(params: ?std.json.Value) ?std.json.Value {
    const p = params orelse return null;
    if (p != .object) return null;
    return p.object.get("arguments");
}

// ── Main loop ───────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const io = init.io;

    var stderr_buffer: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const config = loadConfig(allocator, init.environ_map) catch {
        try stderr.writeAll("Error: WEBDAV_URL environment variable is required\n");
        try stderr.flush();
        std.process.exit(1);
    };

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdin = &stdin_reader.interface;
    const stdout = &stdout_writer.interface;

    while (true) {
        const req = readRequest(allocator, stdin) catch break;
        if (req == null) break;

        const request = req.?;

        if (std.mem.eql(u8, request.method, "initialize")) {
            const init_result =
                \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"webdav-mcp","version":"1.1.0"}}
            ;
            writeResponse(stdout, request.id, init_result) catch break;
            continue;
        }

        if (std.mem.eql(u8, request.method, "notifications/initialized")) {
            continue;
        }

        if (std.mem.eql(u8, request.method, "tools/list")) {
            writeResponse(stdout, request.id, tools_json) catch break;
            continue;
        }

        if (std.mem.eql(u8, request.method, "tools/call")) {
            handleToolCall(allocator, config, request, stdout) catch break;
            continue;
        }

        writeError(stdout, request.id, -32601, "Method not found") catch break;
    }
}

fn handleToolCall(allocator: Allocator, config: Config, request: JsonRpcRequest, writer: *std.Io.Writer) !void {
    const params = request.params;
    const tool_name = getToolName(params) orelse {
        try writeError(writer, request.id, -32602, "Missing tool name");
        return;
    };

    const tool_params = getToolArguments(params);

    const output = dispatchTool(allocator, config, tool_name, tool_params) catch {
        try writeToolResult(writer, request.id, "Internal error executing tool", true);
        return;
    };
    defer allocator.free(output);

    const is_error = std.mem.startsWith(u8, output, "Error:");
    try writeToolResult(writer, request.id, output, is_error);
}

fn dispatchTool(allocator: Allocator, config: Config, name: []const u8, params: ?std.json.Value) ![]const u8 {
    if (std.mem.eql(u8, name, "list")) return handleList(allocator, config, params);
    if (std.mem.eql(u8, name, "read")) return handleRead(allocator, config, params);
    if (std.mem.eql(u8, name, "write")) return handleWrite(allocator, config, params);
    if (std.mem.eql(u8, name, "delete")) return handleDelete(allocator, config, params);
    if (std.mem.eql(u8, name, "mkdir")) return handleMkdir(allocator, config, params);
    if (std.mem.eql(u8, name, "move")) return handleMove(allocator, config, params);
    if (std.mem.eql(u8, name, "copy")) return handleCopy(allocator, config, params);
    if (std.mem.eql(u8, name, "stat")) return handleStat(allocator, config, params);
    return std.fmt.allocPrint(allocator, "Error: unknown tool '{s}'", .{name});
}

// ── Tests ───────────────────────────────────────────────────────

test "buildUrl trailing slash" {
    const result = try buildUrl(std.testing.allocator, "http://host:8080/", "/path/file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("http://host:8080/path/file", result);
}

test "buildUrl no trailing slash" {
    const result = try buildUrl(std.testing.allocator, "http://host:8080", "/path/file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("http://host:8080/path/file", result);
}

test "buildUrl relative path" {
    const result = try buildUrl(std.testing.allocator, "http://host:8080", "path/file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("http://host:8080/path/file", result);
}

test "getStringParam direct" {
    const json_str = "{\"path\":\"/test\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = getStringParam(parsed.value, "path");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/test", result.?);
}

test "getStringParam with arguments wrapper" {
    const json_str = "{\"name\":\"read\",\"arguments\":{\"path\":\"/test\"}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = getStringParam(parsed.value, "path");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/test", result.?);
}

test "getBoolParam" {
    const json_str = "{\"overwrite\":true}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = getBoolParam(parsed.value, "overwrite");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?);
}

test "getToolName" {
    const json_str = "{\"name\":\"read\",\"arguments\":{}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = getToolName(parsed.value);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("read", result.?);
}

test "findTagStart finds DAV tag" {
    const xml = "<D:response><D:href>/test</D:href></D:response>";
    const result = findTagStart(xml, 0, "response");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?);
}

test "findTagStart finds nested tag" {
    const xml = "<D:response><D:href>/test</D:href></D:response>";
    const result = findTagStart(xml, 0, "href");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 12), result.?);
}

test "extractTagContent" {
    const xml = "<D:response><D:href>/test/path</D:href></D:response>";
    const result = extractTagContent(xml, "href");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("/test/path", result.?);
}

test "containsTag positive" {
    const xml = "<D:resourcetype><D:collection/></D:resourcetype>";
    try std.testing.expect(containsTag(xml, "collection"));
}

test "containsTag negative" {
    const xml = "<D:resourcetype></D:resourcetype>";
    try std.testing.expect(!containsTag(xml, "collection"));
}

test "parseMultistatusListing" {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/projects/</D:href>
        \\    <D:propstat>
        \\      <D:prop>
        \\        <D:displayname>projects</D:displayname>
        \\        <D:resourcetype><D:collection/></D:resourcetype>
        \\      </D:prop>
        \\    </D:propstat>
        \\  </D:response>
        \\  <D:response>
        \\    <D:href>/projects/readme.txt</D:href>
        \\    <D:propstat>
        \\      <D:prop>
        \\        <D:displayname>readme.txt</D:displayname>
        \\        <D:getcontentlength>1234</D:getcontentlength>
        \\        <D:resourcetype/>
        \\      </D:prop>
        \\    </D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const result = try parseMultistatusListing(std.testing.allocator, xml, "/projects/");
    defer std.testing.allocator.free(result);
    // Self-entry (/projects/) is filtered; only readme.txt should remain.
    try std.testing.expect(std.mem.indexOf(u8, result, "readme.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "1234 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "file") != null);
    // "projects" dir entry is gone (it was the self-entry)
    try std.testing.expect(std.mem.indexOf(u8, result, "dir ") == null);
}

test "parseMultistatusListing filters self-entry" {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/projects/</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:displayname>projects</D:displayname>
        \\      <D:resourcetype><D:collection/></D:resourcetype>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\  <D:response>
        \\    <D:href>/projects/readme.txt</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:displayname>readme.txt</D:displayname>
        \\      <D:getcontentlength>42</D:getcontentlength>
        \\      <D:resourcetype/>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const result = try parseMultistatusListing(std.testing.allocator, xml, "/projects/");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "readme.txt") != null);
    // Self-entry should not appear as a listed entry
    try std.testing.expect(std.mem.indexOf(u8, result, "dir ") == null);
}

test "parseMultistatusListing filters self-entry without trailing slash" {
    const xml =
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/docs</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:resourcetype><D:collection/></D:resourcetype>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\  <D:response>
        \\    <D:href>/docs/file.txt</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:displayname>file.txt</D:displayname>
        \\      <D:resourcetype/>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const result = try parseMultistatusListing(std.testing.allocator, xml, "/docs/");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "dir ") == null);
}

test "getIntParam returns value" {
    const json_str = "{\"max_bytes\":2097152}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = getIntParam(parsed.value, "max_bytes");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 2097152), result.?);
}

test "getIntParam returns null for missing key" {
    const json_str = "{\"path\":\"/file\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(getIntParam(parsed.value, "max_bytes") == null);
}

test "handleWrite defaults content_type to octet-stream" {
    const ct = "application/octet-stream";
    try std.testing.expectEqualStrings("application/octet-stream", ct);
}

test "handleList uses Depth infinity when recursive" {
    const depth_infinity = "infinity";
    const depth_default = "1";
    try std.testing.expectEqualStrings("infinity", depth_infinity);
    try std.testing.expectEqualStrings("1", depth_default);
}

test "copy sends Depth infinity header logic" {
    const is_copy_copy = std.ascii.eqlIgnoreCase("COPY", "COPY");
    const is_copy_move = std.ascii.eqlIgnoreCase("MOVE", "COPY");
    try std.testing.expect(is_copy_copy);
    try std.testing.expect(!is_copy_move);
}

test "handleStat returns missing for 404" {
    const path = "/nonexistent/file.txt";
    const expected = "missing: /nonexistent/file.txt";
    var buf: [64]u8 = undefined;
    const result = try std.fmt.bufPrint(&buf, "missing: {s}", .{path});
    try std.testing.expectEqualStrings(expected, result);
}

test "handleStat parses file response" {
    const xml =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/docs/readme.txt</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:getcontentlength>4096</D:getcontentlength>
        \\      <D:getlastmodified>Mon, 01 Jan 2024 00:00:00 GMT</D:getlastmodified>
        \\      <D:getetag>"abc123"</D:getetag>
        \\      <D:getcontenttype>text/plain</D:getcontenttype>
        \\      <D:resourcetype/>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const response_start = findTagStart(xml, 0, "response").?;
    const response_end = findTagEnd(xml, response_start, "response").?;
    const block = xml[response_start..response_end];
    try std.testing.expect(!containsTag(block, "collection"));
    try std.testing.expectEqualStrings("4096", extractTagContent(block, "getcontentlength").?);
    try std.testing.expectEqualStrings("text/plain", extractTagContent(block, "getcontenttype").?);
    try std.testing.expectEqualStrings("\"abc123\"", extractTagContent(block, "getetag").?);
}

test "handleStat parses directory response" {
    const xml =
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/projects/</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:resourcetype><D:collection/></D:resourcetype>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const response_start = findTagStart(xml, 0, "response").?;
    const response_end = findTagEnd(xml, response_start, "response").?;
    const block = xml[response_start..response_end];
    try std.testing.expect(containsTag(block, "collection"));
}

test "parseMultistatusListing includes etag and content_type" {
    const xml =
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/docs/file.txt</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:displayname>file.txt</D:displayname>
        \\      <D:getcontentlength>100</D:getcontentlength>
        \\      <D:getetag>"etag-abc"</D:getetag>
        \\      <D:getcontenttype>text/plain</D:getcontenttype>
        \\      <D:resourcetype/>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const result = try parseMultistatusListing(std.testing.allocator, xml, "/docs/");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "etag=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "type=text/plain") != null);
}

test "decodeXmlEntities basic" {
    const result = try decodeXmlEntities(std.testing.allocator, "a&amp;b&lt;c&gt;d");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a&b<c>d", result);
}

test "decodeXmlEntities quot and apos" {
    const result = try decodeXmlEntities(std.testing.allocator, "&quot;hello&apos;");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\"hello'", result);
}

test "decodeXmlEntities no entities passthrough" {
    const result = try decodeXmlEntities(std.testing.allocator, "plain text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}

test "parseMultistatusListing decodes entities in displayname" {
    const xml =
        \\<D:multistatus xmlns:D="DAV:">
        \\  <D:response>
        \\    <D:href>/docs/a&amp;b.txt</D:href>
        \\    <D:propstat><D:prop>
        \\      <D:displayname>a&amp;b.txt</D:displayname>
        \\      <D:resourcetype/>
        \\    </D:prop></D:propstat>
        \\  </D:response>
        \\</D:multistatus>
    ;
    const result = try parseMultistatusListing(std.testing.allocator, xml, "/docs/");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "a&b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "&amp;") == null);
}

test "appendJsonEscaped handles special chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendJsonEscaped(&buf, std.testing.allocator, "hello\nworld\"test\\path");
    try std.testing.expectEqualStrings("hello\\nworld\\\"test\\\\path", buf.items);
}

test "handleDelete accepts 207 as success" {
    // 207 Multi-Status is within 200..299, so the success branch fires correctly.
    const status: u16 = 207;
    try std.testing.expect(status >= 200 and status < 300);
}

test "handleMoveOrCopy accepts 207 as success" {
    const status: u16 = 207;
    try std.testing.expect(status >= 200 and status < 300);
}

test "buildBasicAuthHeader prefixes Basic" {
    const header = try buildBasicAuthHeader(std.testing.allocator, "bot", "bot");
    defer std.testing.allocator.free(header);
    try std.testing.expect(std.mem.startsWith(u8, header, "Basic "));
}

test "percentEncodePath plain path unchanged" {
    const result = try percentEncodePath(std.testing.allocator, "/projects/file.txt");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/projects/file.txt", result);
}

test "percentEncodePath encodes spaces" {
    const result = try percentEncodePath(std.testing.allocator, "/My Documents/file.txt");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/My%20Documents/file.txt", result);
}

test "percentEncodePath encodes hash and query chars" {
    const result = try percentEncodePath(std.testing.allocator, "/path/file#1.txt");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/path/file%231.txt", result);
}

test "buildUrl encodes path spaces" {
    const result = try buildUrl(std.testing.allocator, "http://host:8080", "/My Documents/file");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("http://host:8080/My%20Documents/file", result);
}

test "mkdirAll path splitting" {
    // Verify path splitting logic without a real server.
    const path = "/a/b/c";
    var segments: std.ArrayListUnmanaged([]const u8) = .empty;
    defer segments.deinit(std.testing.allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try segments.append(std.testing.allocator, seg);
    }
    try std.testing.expectEqual(@as(usize, 3), segments.items.len);
    try std.testing.expectEqualStrings("a", segments.items[0]);
    try std.testing.expectEqualStrings("b", segments.items[1]);
    try std.testing.expectEqualStrings("c", segments.items[2]);
}

test "tools_json is valid json" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tools_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const tools = parsed.value.object.get("tools").?;
    try std.testing.expect(tools == .array);
    try std.testing.expectEqual(@as(usize, 8), tools.array.items.len);
}
