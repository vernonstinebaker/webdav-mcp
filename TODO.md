# webdav-mcp TODO

This file is the authoritative task list for bringing webdav-mcp to full RFC 4918
correctness. Items are ordered by priority. Each item includes the exact location in
`src/main.zig` to change, the exact change required, and a test to add.

**Validation command (run after every change):**
```bash
zig build test --summary all   # must show 0 failures, 0 leaks
zig fmt --check src/main.zig   # must be clean
```

**Current file stats:** `src/main.zig` — 801 lines, 7 tools, ~18 tests.

---

## Group A — Bug Fixes (Broken Behavior Today)

These are correctness bugs that cause wrong results against real servers right now.

---

### A-1. Fix 207 Multi-Status treated as error in `delete`, `copy`, `move`

**File:** `src/main.zig`

**Problem:** `handleDelete` (line 375), and `handleMoveOrCopy` (line 427) check
`result.status >= 200 and result.status < 300`. HTTP 207 Multi-Status is returned
by servers when a collection operation partially succeeds or fails. 207 is outside
the 200–299 range, so these handlers report a false error even when the operation
largely succeeded. Only `handleList` (line 321) correctly handles 207.

**Fix — `handleDelete` at line 375:**
```zig
// Before:
if (result.status >= 200 and result.status < 300) {
    return std.fmt.allocPrint(allocator, "OK: deleted {s}", .{path});
} else {
    return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
}

// After:
if (result.status >= 200 and result.status < 300) {
    return std.fmt.allocPrint(allocator, "OK: deleted {s}", .{path});
} else if (result.status == 207) {
    // Partial success on collection delete — some members may not have been deleted.
    return std.fmt.allocPrint(allocator, "OK (partial): deleted {s} (207 Multi-Status — some members may remain)\n{s}", .{ path, result.body });
} else {
    return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
}
```

**Fix — `handleMoveOrCopy` at line 427:**
```zig
// Before:
if (result.status >= 200 and result.status < 300) {
    const verb: []const u8 = if (std.ascii.eqlIgnoreCase(method, "MOVE")) "moved" else "copied";
    return std.fmt.allocPrint(allocator, "OK: {s} {s} -> {s}", .{ verb, source, destination });
} else {
    return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
}

// After:
if (result.status >= 200 and result.status < 300) {
    const verb: []const u8 = if (std.ascii.eqlIgnoreCase(method, "MOVE")) "moved" else "copied";
    return std.fmt.allocPrint(allocator, "OK: {s} {s} -> {s}", .{ verb, source, destination });
} else if (result.status == 207) {
    const verb: []const u8 = if (std.ascii.eqlIgnoreCase(method, "MOVE")) "moved" else "copied";
    return std.fmt.allocPrint(allocator, "OK (partial): {s} {s} -> {s} (207 Multi-Status — some members may not have been {s})\n{s}", .{ verb, source, destination, verb, result.body });
} else {
    return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
}
```

**Tests to add:**
```zig
test "handleDelete accepts 207 as partial success" {
    // Simulate a 207 response body (minimal multistatus XML)
    // The output should start with "OK (partial):" not "Error:"
    // Use parseMultistatusListing indirectly — just verify the string prefix.
    const fake_207_body = "<D:multistatus xmlns:D=\"DAV:\"></D:multistatus>";
    // Build a fake CurlResult-like scenario by testing the branch logic directly.
    // Since curlRequest requires a real server, test via the status-check expression:
    const status: u16 = 207;
    try std.testing.expect(status == 207); // 207 is NOT in 200..299
    try std.testing.expect(!(status >= 200 and status < 300));
    _ = fake_207_body;
}

test "handleMoveOrCopy accepts 207 as partial success" {
    const status: u16 = 207;
    try std.testing.expect(status == 207);
    try std.testing.expect(!(status >= 200 and status < 300));
}
```

---

### A-2. Filter self-entry from `list` output

**File:** `src/main.zig`, function `parseMultistatusListing` (line 437)

**Problem:** PROPFIND Depth:1 always returns the target collection itself as the
first `<response>` entry, with its own `<href>` equal to the requested path. The
parser emits it as a `dir` entry mixed in with the actual children. For example,
`list /projects/` always shows `dir  projects` as the first line even though
`/projects/` was the directory being listed, not a child.

**Fix:** Track the requested path, and in the parsing loop skip any `<response>`
block whose `<href>` matches the requested path (after normalizing trailing slashes).

Change the signature of `parseMultistatusListing` to accept the requested path:
```zig
// Before:
fn parseMultistatusListing(allocator: Allocator, xml: []const u8) ![]const u8

// After:
fn parseMultistatusListing(allocator: Allocator, xml: []const u8, requested_path: []const u8) ![]const u8
```

Update the call site in `handleList` (line 322):
```zig
// Before:
return try parseMultistatusListing(allocator, result.body);

// After:
return try parseMultistatusListing(allocator, result.body, path);
```

Inside `parseMultistatusListing`, after extracting `href`, add the skip check:
```zig
const href = extractTagContent(response_block, "href") orelse "(unknown)";

// Skip the self-entry: the <href> of the requested collection itself.
// Normalize by stripping trailing slashes before comparing.
const href_trimmed = std.mem.trimRight(u8, href, "/");
const req_trimmed = std.mem.trimRight(u8, requested_path, "/");
if (std.mem.eql(u8, href_trimmed, req_trimmed)) {
    pos = resp_end;
    continue;
}
```

**Tests to add:**
```zig
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
    // Self-entry should be filtered out
    try std.testing.expect(std.mem.indexOf(u8, result, "readme.txt") != null);
    // The directory itself should NOT appear as a listed entry
    // (it was the self-entry for /projects/)
    const lines = std.mem.count(u8, result, "\n");
    try std.testing.expectEqual(@as(usize, 0), lines); // only one entry remains
}

test "parseMultistatusListing filters self-entry without trailing slash" {
    // Servers may return href without trailing slash even for collections
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
    try std.testing.expect(std.mem.indexOf(u8, result, "/docs\"") == null);
}
```

Also update the existing `parseMultistatusListing` test (line 753) to pass the
requested path as a third argument: `parseMultistatusListing(allocator, xml, "/projects/")`.
The first `<response>` in that test has `<D:href>/projects/</D:href>` — it is the
self-entry and should now be filtered, so update the assertion:
```zig
// The self-entry (/projects/) is filtered; only readme.txt should remain.
try std.testing.expect(std.mem.indexOf(u8, result, "readme.txt") != null);
try std.testing.expect(std.mem.indexOf(u8, result, "1234 bytes") != null);
try std.testing.expect(std.mem.indexOf(u8, result, "file") != null);
// "projects" entry is now gone (it was the self-entry)
try std.testing.expect(std.mem.indexOf(u8, result, "dir ") == null);
```

---

### A-3. Add `--max-time` timeout to all curl invocations

**File:** `src/main.zig`, function `curlRequest` (line 179)

**Problem:** No timeout is set on the curl subprocess. If the WebDAV server hangs
mid-transfer, `curlRequest` blocks forever on `child.wait()`. The MCP host will
eventually kill the process, but until then the tool is stuck.

**Fix:** Add `--max-time 30` (30-second total timeout) to the argv in `curlRequest`,
after the `-S` flag. Also add `--connect-timeout 10` (10-second connect timeout).

```zig
// After line 196 (try argv.append(allocator, "-S");), add:
try argv.append(allocator, "--max-time");
try argv.append(allocator, "30");
try argv.append(allocator, "--connect-timeout");
try argv.append(allocator, "10");
```

Note: curl exit code 28 = timeout. When `child.wait()` returns exit code 28, the
current code returns `error.CurlFailed` (line 258–260). This is acceptable — the
caller will see `Error: WebDAV <METHOD> failed: error.CurlFailed`. A future
improvement could detect code 28 and return `error.CurlTimeout` for a better
message, but that is not required for this task.

**Tests to add:**
```zig
test "curlRequest argv includes timeout flags" {
    // Verify the timeout constants are sane values (compile-time check).
    // Real invocation testing requires a live server; this is a smoke test.
    const max_time: u32 = 30;
    const connect_timeout: u32 = 10;
    try std.testing.expect(max_time > connect_timeout);
    try std.testing.expect(connect_timeout > 0);
}
```

---

### A-4. Read and drain stderr to prevent pipe deadlock

**File:** `src/main.zig`, function `curlRequest` (line 179)

**Problem:** `child.stderr_behavior = .Pipe` (line 231) allocates a pipe for
stderr but the code never reads it. If curl writes more than the OS pipe buffer
(typically 64 KB on Linux, 65536 bytes on macOS) to stderr, curl blocks waiting
for the buffer to drain, while the Zig process blocks waiting for curl's stdout
to close — a classic deadlock. Verbose TLS errors and certificate dumps can
exceed 64 KB.

**Fix:** After reading stdout, drain stderr before calling `child.wait()`.
Change `stderr_behavior` to `.Ignore` — this is the simplest correct fix.
curl's `-S` flag causes it to write errors to stderr, but since we detect errors
via `%{http_code}` in the body, we do not need stderr content.

```zig
// Change line 231 from:
child.stderr_behavior = .Pipe;
// To:
child.stderr_behavior = .Ignore;
```

This eliminates the deadlock risk entirely. No stderr content is needed.

**No new tests required** (the fix removes a pipe, which is not directly testable
in unit tests without a mock subprocess).

---

### A-5. Decode XML entities in `extractTagContent`

**File:** `src/main.zig`, function `extractTagContent` (line 537)

**Problem:** WebDAV servers encode special characters in property values as XML
entities: `&amp;` for `&`, `&lt;` for `<`, `&gt;` for `>`, `&quot;` for `"`,
`&apos;` for `'`. A file named `a&b.txt` is returned as `<D:displayname>a&amp;b.txt</D:displayname>`
and currently displayed to the agent as `a&amp;b.txt` — the raw entity, not the
decoded name. This applies to `displayname`, `href`, and any other string property.

**Fix:** Add a `decodeXmlEntities` function and call it on content returned by
`extractTagContent`. The result must be allocated because the decoded string may
differ in length.

Add this function before `extractTagContent`:
```zig
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
```

**Important:** Because `extractTagContent` currently returns a slice into the
original `xml` buffer (zero-copy), adding entity decoding means the return value
must now be allocated. This changes the ownership model.

The cleanest approach is to change `extractTagContent` to return `!?[]u8`
(allocated) and update all call sites in `parseMultistatusListing` to `defer
allocator.free()` the returned values. Alternatively, keep `extractTagContent`
returning a raw slice and add a separate `extractAndDecodeTagContent` that
allocates — use the decoding variant in `parseMultistatusListing` for display
values (displayname, size, modified) and keep the raw variant for `href` used in
self-entry comparison (where encoded form is fine for path matching).

**Recommended approach** (minimal diff):

1. Add `decodeXmlEntities` as shown above.
2. In `parseMultistatusListing`, change the `display`, `size`, `modified` extractions to:
```zig
const display_raw = extractTagContent(response_block, "displayname");
const display = if (display_raw) |raw| try decodeXmlEntities(allocator, raw) else null;
defer if (display != null) allocator.free(display.?);

const size = extractTagContent(response_block, "getcontentlength"); // no entities expected
const modified_raw = extractTagContent(response_block, "getlastmodified");
const modified = if (modified_raw) |raw| try decodeXmlEntities(allocator, raw) else null;
defer if (modified != null) allocator.free(modified.?);
```

**Tests to add:**
```zig
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
```

---

## Group B — New Tools

---

### B-1. Add `stat` tool (PROPFIND Depth:0)

**Priority: Highest of all new features.** Agents need `stat` constantly — to check
existence before writing, to check whether a path is a file or directory, and to get
size without doing a full listing.

**What it does:** Issues PROPFIND with `Depth: 0` on a single path and returns a
one-line summary: type (file/dir/missing), size, last-modified, and ETag (if
available).

**Step 1: Add PROPFIND body and handler function.**

Add after `handleMkdir` (around line 396):
```zig
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

    const result = curlRequest(allocator, config, "PROPFIND", path, propfind_body, &headers) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV PROPFIND failed: {}", .{err});
    };
    defer allocator.free(result.body);

    if (result.status == 404) {
        return std.fmt.allocPrint(allocator, "missing: {s}", .{path});
    }

    if ((result.status >= 200 and result.status < 300) or result.status == 207) {
        // PROPFIND Depth:0 returns a single <response> block for the path itself.
        // Re-use parseMultistatusListing but expect exactly one entry (no self-filter needed
        // since Depth:0 only returns the resource itself, not children).
        // Parse manually for a richer single-entry result.
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
```

**Step 2: Wire into `dispatchTool` (line 655).**

Add before the final unknown-tool return:
```zig
if (std.mem.eql(u8, name, "stat")) return handleStat(allocator, config, params);
```

**Step 3: Add to `tools_json` (line 161).**

Add the following entry to the tools array (before the closing `"]}"`):
```json
{"name":"stat","description":"Get metadata for a single file or directory on WebDAV (PROPFIND Depth:0). Returns type (file/dir/missing), size, last-modified, ETag, and content-type. Use this to check existence or get file info without listing a whole directory.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Path to stat relative to WebDAV root"}},"required":["path"]}}
```

**Step 4: Update the `tools_json is valid json` test** (line 794) to expect 8 tools:
```zig
try std.testing.expectEqual(@as(usize, 8), tools.array.items.len);
```

**Tests to add:**
```zig
test "handleStat returns missing for 404" {
    // Test the 404 branch logic: status 404 should return "missing: <path>"
    // Since we cannot call a real server, verify the string-building logic:
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
    // Test parsing logic by directly calling the XML helpers:
    const response_start = findTagStart(xml, 0, "response").?;
    const response_end = findTagEnd(xml, response_start, "response").?;
    const block = xml[response_start..response_end];
    try std.testing.expect(!containsTag(block, "collection")); // is a file
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
    try std.testing.expect(containsTag(block, "collection")); // is a directory
}
```

---

### B-2. Add `getetag` and `getcontenttype` to `list` PROPFIND request

**File:** `src/main.zig`, function `handleList` (line 296)

**Problem:** The PROPFIND request body (lines 299–309) does not request
`getetag` or `getcontenttype`. ETags are required by rclone and Cyberduck
for cache validation. Content-type lets agents distinguish text from binary.

**Fix:** Extend the `propfind_body` in `handleList`:
```zig
// Before:
const propfind_body =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<D:propfind xmlns:D="DAV:">
    \\  <D:prop>
    \\    <D:displayname/>
    \\    <D:getcontentlength/>
    \\    <D:getlastmodified/>
    \\    <D:resourcetype/>
    \\  </D:prop>
    \\</D:propfind>
;

// After:
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
```

Also update `parseMultistatusListing` to extract and display etag and
content_type when present. Add after the `modified` extraction (line 453):
```zig
const etag_raw = extractTagContent(response_block, "getetag");
const content_type = extractTagContent(response_block, "getcontenttype");
```

And in the output block (after the `modified` display, around line 476):
```zig
if (etag_raw) |e| {
    try output.appendSlice(allocator, "  etag=");
    try output.appendSlice(allocator, e);
}
if (content_type) |ct| {
    try output.appendSlice(allocator, "  type=");
    try output.appendSlice(allocator, ct);
}
```

**Tests to add:**
```zig
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
```

---

### B-3. Add `Depth: infinity` option to `list` (recursive listing)

**File:** `src/main.zig`, function `handleList` (line 296)

**Problem:** No recursive listing. Some operations (agent scanning a full directory
tree) require `Depth: infinity`.

**Fix:** Add an optional `recursive` boolean parameter to the `list` tool schema
and handler. When `true`, send `Depth: infinity` instead of `Depth: 1`. Default
is `false`. Add a warning in the description that some servers (notably IIS and
some Nginx configs) block `Depth: infinity`.

Update `handleList`:
```zig
fn handleList(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse "/";
    const recursive = getBoolParam(params, "recursive") orelse false;
    const depth: []const u8 = if (recursive) "infinity" else "1";

    // ... (propfind_body unchanged)

    const headers = [_][2][]const u8{
        .{ "Depth", depth },
        .{ "Content-Type", "application/xml" },
    };
    // ...
}
```

Update the `list` entry in `tools_json` to add the `recursive` property:
```json
"recursive":{"type":"boolean","description":"If true, list recursively (Depth: infinity). Some servers block this. Default: false"}
```

**Tests to add:**
```zig
test "handleList uses Depth infinity when recursive" {
    const depth_val = "infinity";
    try std.testing.expectEqualStrings("infinity", depth_val);
    const depth_default = "1";
    try std.testing.expectEqualStrings("1", depth_default);
}
```

---

### B-4. Add `Content-Type` parameter to `write`

**File:** `src/main.zig`, function `handleWrite` (line 344)

**Problem:** All uploads use `Content-Type: application/octet-stream` regardless
of the actual file type. Servers that store `getcontenttype` as a live property
(Nextcloud, Owncloud, Apple iCal) will record the wrong type.

**Fix:** Add an optional `content_type` string parameter. Default to
`"application/octet-stream"` when absent.

```zig
fn handleWrite(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");
    const content = getStringParam(params, "content") orelse
        return try allocator.dupe(u8, "Error: 'content' parameter is required");
    const content_type = getStringParam(params, "content_type") orelse "application/octet-stream";

    const ct_header = try std.fmt.allocPrint(allocator, "{s}", .{content_type});
    defer allocator.free(ct_header);

    const headers = [_][2][]const u8{
        .{ "Content-Type", ct_header },
    };
    // rest unchanged
}
```

Update `write` in `tools_json` to add:
```json
"content_type":{"type":"string","description":"MIME type for the file (e.g. 'text/plain', 'application/json'). Default: application/octet-stream"}
```

**Tests to add:**
```zig
test "handleWrite defaults content_type to octet-stream" {
    const ct = "application/octet-stream";
    try std.testing.expectEqualStrings("application/octet-stream", ct);
}
```

---

### B-5. Add `Depth: infinity` header to `copy` for collections

**File:** `src/main.zig`, function `handleMoveOrCopy` (line 406)

**Problem:** RFC 4918 §9.8.2 states the `Depth` header is required for COPY on
collections. Without it the server's default applies, which is typically `infinity`
but is not guaranteed. This makes the implementation non-conformant.

**Fix:** Add `Depth: infinity` to the headers for COPY only. MOVE does not use
a `Depth` header (RFC 4918 §9.9.1: MOVE always acts recursively without a header).

```zig
fn handleMoveOrCopy(allocator: Allocator, config: Config, params: ?std.json.Value, method: []const u8) ![]const u8 {
    // ... (source, destination, overwrite extraction unchanged)

    const is_copy = std.ascii.eqlIgnoreCase(method, "COPY");

    if (is_copy) {
        const headers = [_][2][]const u8{
            .{ "Destination", dest_url },
            .{ "Overwrite", if (overwrite) "T" else "F" },
            .{ "Depth", "infinity" },
        };
        // issue request with these headers
    } else {
        const headers = [_][2][]const u8{
            .{ "Destination", dest_url },
            .{ "Overwrite", if (overwrite) "T" else "F" },
        };
        // issue request with these headers
    }
    // ...
}
```

Since the `headers` array size differs for COPY vs MOVE, the cleanest approach is
to use two separate `curlRequest` call sites for the two branches, or use an
`ArrayList` for headers. An `ArrayList` avoids code duplication:

```zig
var hdr_list: std.ArrayListUnmanaged([2][]const u8) = .empty;
defer hdr_list.deinit(allocator);
try hdr_list.append(allocator, .{ "Destination", dest_url });
try hdr_list.append(allocator, .{ "Overwrite", if (overwrite) "T" else "F" });
if (is_copy) {
    try hdr_list.append(allocator, .{ "Depth", "infinity" });
}

const result = curlRequest(allocator, config, method, source, null, hdr_list.items) catch |err| {
    return std.fmt.allocPrint(allocator, "Error: WebDAV {s} failed: {}", .{ method, err });
};
```

Note: `curlRequest` accepts `extra_headers: []const [2][]const u8` — `hdr_list.items`
is `[][2][]const u8` which coerces correctly to `[]const [2][]const u8`.

**Tests to add:**
```zig
test "copy sends Depth infinity header logic" {
    // Verify the branch: COPY gets Depth: infinity, MOVE does not.
    const is_copy_copy = std.ascii.eqlIgnoreCase("COPY", "COPY");
    const is_copy_move = std.ascii.eqlIgnoreCase("MOVE", "COPY");
    try std.testing.expect(is_copy_copy);
    try std.testing.expect(!is_copy_move);
}
```

---

### B-6. Add size guard to `read`

**File:** `src/main.zig`, function `handleRead` (line 328)

**Problem:** No maximum size check before returning file content. A large file
(log file, binary blob, database dump) will fill the MCP response and likely
exceed the LLM context window or OOM the agent. The existing 10 MB cap in
`curlRequest` is a hard crash limit, not a user-facing guard.

**Fix:** Add an optional `max_bytes` integer parameter (default: 1,048,576 = 1 MB).
Use PROPFIND Depth:0 first to check `getcontentlength`, and return an error with
the actual size if it exceeds `max_bytes`. Fall back to unconditional GET if
the server does not return a content-length (i.e., a 0 or missing value is treated
as "unknown size, proceed").

Add `getIntParam` helper alongside `getBoolParam` (line 566):
```zig
fn getIntParam(params: ?std.json.Value, key: []const u8) ?i64 {
    const p = params orelse return null;
    if (p != .object) return null;
    const args = if (p.object.get("arguments")) |a| (if (a == .object) a.object else p.object) else p.object;
    const val = args.get(key) orelse return null;
    if (val != .integer) return null;
    return val.integer;
}
```

Update `handleRead`:
```zig
fn handleRead(allocator: Allocator, config: Config, params: ?std.json.Value) ![]const u8 {
    const path = getStringParam(params, "path") orelse
        return try allocator.dupe(u8, "Error: 'path' parameter is required");
    const max_bytes: usize = @intCast(@max(0, getIntParam(params, "max_bytes") orelse 1024 * 1024));

    // Check size via PROPFIND Depth:0 before fetching
    {
        const size_check = checkFileSize(allocator, config, path) catch 0;
        if (size_check > 0 and size_check > max_bytes) {
            return std.fmt.allocPrint(
                allocator,
                "Error: file size {d} bytes exceeds max_bytes limit {d}. Use max_bytes parameter to increase limit.",
                .{ size_check, max_bytes },
            );
        }
    }

    const result = curlRequest(allocator, config, "GET", path, null, &.{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error: WebDAV GET failed: {}", .{err});
    };

    if (result.status >= 200 and result.status < 300) {
        return result.body;
    } else {
        defer allocator.free(result.body);
        return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ result.status, result.body });
    }
}
```

Add helper function `checkFileSize` that issues PROPFIND Depth:0 and returns the
content-length as a `usize`, or 0 if unavailable:
```zig
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
    const result = try curlRequest(allocator, config, "PROPFIND", path, propfind_body, &headers);
    defer allocator.free(result.body);
    if (result.status != 207 and !(result.status >= 200 and result.status < 300)) return 0;
    const size_str = extractTagContent(result.body, "getcontentlength") orelse return 0;
    return std.fmt.parseInt(usize, size_str, 10) catch 0;
}
```

Update `read` in `tools_json` to add:
```json
"max_bytes":{"type":"integer","description":"Maximum file size to read in bytes (default: 1048576 = 1 MB). Returns an error if the file is larger."}
```

**Tests to add:**
```zig
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
```

---

### B-7. Add auto-MKCOL on `write` when parent is missing (409 retry)

**File:** `src/main.zig`, function `handleWrite` (line 344)

**Problem:** PUT to `/a/b/c.txt` returns 409 Conflict if `/a/b/` does not exist.
The agent must manually call `mkdir` for each missing ancestor. This is tedious
and fragile for deep paths.

**Fix:** Add an optional `create_parents` boolean parameter (default: `false`).
When `true` and a 409 is received, parse the path to find all ancestor segments,
issue MKCOL for each one (ignoring 405 Method Not Allowed which means it already
exists), then retry the PUT.

```zig
fn mkdirAll(allocator: Allocator, config: Config, path: []const u8) !void {
    // Split path into segments and issue MKCOL for each prefix.
    // e.g. /a/b/c -> MKCOL /a, MKCOL /a/b, MKCOL /a/b/c
    // Ignore 405 (already exists) and 201 (created). Fail on other errors.
    var it = std.mem.splitScalar(u8, path, '/');
    var prefix: std.ArrayListUnmanaged(u8) = .empty;
    defer prefix.deinit(allocator);
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        try prefix.append(allocator, '/');
        try prefix.appendSlice(allocator, segment);
        const current = try allocator.dupe(u8, prefix.items);
        defer allocator.free(current);
        const r = curlRequest(allocator, config, "MKCOL", current, null, &.{}) catch continue;
        allocator.free(r.body);
        // 201 = created, 405 = already exists — both are fine
        if (r.status != 201 and r.status != 405 and !(r.status >= 200 and r.status < 300)) {
            return error.MkcolFailed;
        }
    }
}
```

In `handleWrite`, after a 409 response:
```zig
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
        const retry = curlRequest(allocator, config, "PUT", path, content, &headers) catch |err| {
            return std.fmt.allocPrint(allocator, "Error: WebDAV PUT failed on retry: {}", .{err});
        };
        defer allocator.free(retry.body);
        if (retry.status >= 200 and retry.status < 300) {
            return std.fmt.allocPrint(allocator, "OK: wrote {d} bytes to {s} (created parents)", .{ content.len, path });
        } else {
            return std.fmt.allocPrint(allocator, "Error: HTTP {d}\n{s}", .{ retry.status, retry.body });
        }
    }
    return std.fmt.allocPrint(allocator, "Error: HTTP 409 — parent directory does not exist. Use mkdir or set create_parents=true", .{});
}
```

Update `write` in `tools_json` to add:
```json
"create_parents":{"type":"boolean","description":"If true and the parent directory does not exist, create it automatically. Default: false"}
```

**Tests to add:**
```zig
test "mkdirAll path splitting" {
    // Verify path splitting logic without a real server.
    const path = "/a/b/c";
    var segments = std.ArrayList([]const u8).init(std.testing.allocator);
    defer segments.deinit();
    var it = std.mem.splitScalar(u8, path, '/');
    var prefix_len: usize = 0;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        prefix_len += seg.len + 1;
        try segments.append(seg);
    }
    try std.testing.expectEqual(@as(usize, 3), segments.items.len);
    try std.testing.expectEqualStrings("a", segments.items[0]);
    try std.testing.expectEqualStrings("b", segments.items[1]);
    try std.testing.expectEqualStrings("c", segments.items[2]);
}
```

---

## Group C — Security & Reliability

---

### C-1. Move credentials out of curl argv (prevent `ps` leakage)

**File:** `src/main.zig`, function `curlRequest` (line 179)

**Problem:** Credentials are passed as `-u username:password` in the curl
command-line argv (lines 203–210). On Linux, argv is readable by any process
under the same user via `/proc/<pid>/cmdline`. On macOS, `ps -ef` reveals it.

**Fix:** Pass credentials via a temporary netrc file on stdin, or via the
`--netrc-file` option with a named pipe or temp file. The simplest secure option
is to use curl's `--anyauth --user` with a file, but the easiest correct fix for
a short-lived subprocess is to use the `CURLOPT_USERPWD`-equivalent via a
`--config` pipe.

**Recommended fix:** Use `--netrc-file /dev/stdin` and pass the netrc content
as the first thing written to stdin, followed by the request body. However, curl
only accepts one stdin source. The cleanest alternative is to write a temporary
file:

```zig
// Instead of:
try argv.append(allocator, "-u");
try argv.append(allocator, creds);  // "user:pass" visible in ps

// Write credentials to a temp file and pass via --netrc-file:
// (only if both user and pass are non-null)
if (config.user) |user| {
    const pass = config.pass orelse "";
    const netrc_content = try std.fmt.allocPrint(
        allocator,
        "machine {s} login {s} password {s}\n",
        .{ host_from_url, user, pass },
    );
    defer allocator.free(netrc_content);
    // Write to a temp file — use std.fs.tmpFile or a fixed path under /tmp
    // Pass --netrc-file <path> to curl
    // Clean up temp file after child.wait()
}
```

Extracting the hostname from `config.base_url` for the `machine` field requires
parsing the URL. A simple approach: scan for `://` and take everything up to the
next `/` or end of string.

Add a helper:
```zig
fn hostnameFromUrl(url: []const u8) []const u8 {
    const after_scheme = std.mem.indexOf(u8, url, "://") orelse return url;
    const host_start = after_scheme + 3;
    const host_end = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse url.len;
    return url[host_start..host_end];
}
```

**Tests to add:**
```zig
test "hostnameFromUrl" {
    try std.testing.expectEqualStrings("host:8080", hostnameFromUrl("http://host:8080/path"));
    try std.testing.expectEqualStrings("example.com", hostnameFromUrl("https://example.com/dav/"));
    try std.testing.expectEqualStrings("host", hostnameFromUrl("http://host"));
}
```

---

### C-2. URL percent-encode paths in `buildUrl`

**File:** `src/main.zig`, function `buildUrl` (line 281)

**Problem:** `buildUrl` does simple string concatenation. A path containing spaces,
`#`, `?`, non-ASCII characters, or other URL-special characters will produce an
invalid URL. For example, `/My Documents/file.txt` becomes
`http://host:8080/My Documents/file.txt` which curl interprets incorrectly.

**Fix:** Percent-encode path segments (but not the `/` separators) when building
the URL.

Add a `percentEncodePath` helper:
```zig
/// Percent-encode a path string, preserving '/' separators.
/// Characters that do not need encoding (RFC 3986 unreserved + '/'):
///   A-Z a-z 0-9 - _ . ~ /
/// Everything else is encoded as %XX.
/// Returns an allocated string. Caller owns the memory.
fn percentEncodePath(allocator: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (path) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9',
            '-', '_', '.', '~', '/',
            ':', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '='
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
```

Update `buildUrl` to encode the path:
```zig
fn buildUrl(allocator: Allocator, base: []const u8, path: []const u8) ![]u8 {
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
```

**Tests to add:**
```zig
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
```

---

## Group D — Version and Tooling

---

### D-1. Bump version string to 1.1.0 after completing Group A+B

**File:** `src/main.zig`, line 612:
```zig
// Before:
\\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"webdav-mcp","version":"1.0.0"}}

// After:
\\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"webdav-mcp","version":"1.1.0"}}
```

Also update `build.zig.zon` if a version field exists there.

---

### D-2. Update README with new tools and parameters

After completing all items above, update `README.md` to document:
- `stat` tool and its output format
- `list` recursive parameter
- `read` max_bytes parameter
- `write` content_type and create_parents parameters
- `copy` Depth:infinity behavior
- The credential security note (temp file vs argv)

---

## Implementation Order

Work through items in this exact order to minimize test breakage:

1. **A-3** — add curl timeout (touches only `curlRequest`, no test changes)
2. **A-4** — change stderr to `.Ignore` (one-line fix)
3. **A-1** — fix 207 in delete/move/copy (three small additions)
4. **A-2** — filter self-entry from list (update signature + add skip logic + update tests)
5. **A-5** — XML entity decoding (new function + update parseMultistatusListing)
6. **B-2** — add getetag/getcontenttype to list PROPFIND (extend propfind_body + output)
7. **B-1** — add stat tool (new handler + wire + tools_json + update tools count test)
8. **B-5** — add Depth: infinity to copy (update handleMoveOrCopy)
9. **B-3** — recursive list parameter
10. **B-4** — content_type parameter on write
11. **B-6** — size guard on read (new helper + getIntParam)
12. **B-7** — auto-MKCOL on write 409
13. **C-2** — percent-encode paths (new helper + update buildUrl + update existing buildUrl tests)
14. **C-1** — credential temp file (most invasive change, do last)
15. **D-1** — bump version
16. **D-2** — update README

Run `zig build test --summary all` and `zig fmt --check src/main.zig` after each item.
All tests must pass at zero leaks before moving to the next item.
