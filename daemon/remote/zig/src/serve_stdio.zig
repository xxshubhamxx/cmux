const std = @import("std");
const json_rpc = @import("json_rpc.zig");
const proxy_streams = @import("proxy_streams.zig");
const pty_host = @import("pty_host.zig");
const session_registry = @import("session_registry.zig");
const terminal_session = @import("terminal_session.zig");

const AttachmentResult = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

const ReadResult = struct {
    data: []u8,
    offset: u64,
    base_offset: u64,
    truncated: bool,
    eof: bool,
};

const RuntimeSession = struct {
    pty: pty_host.PtyHost,
    terminal: terminal_session.TerminalSession,

    fn init(alloc: std.mem.Allocator, command: []const u8, cols: u16, rows: u16) !RuntimeSession {
        return .{
            .pty = try pty_host.PtyHost.init(alloc, command, cols, rows),
            .terminal = try terminal_session.TerminalSession.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = 100_000,
            }),
        };
    }

    fn deinit(self: *RuntimeSession) void {
        self.terminal.deinit();
        self.pty.deinit();
    }

    fn resize(self: *RuntimeSession, cols: u16, rows: u16) !void {
        try self.pty.resize(cols, rows);
        try self.terminal.resize(cols, rows);
    }

    fn read(self: *RuntimeSession, alloc: std.mem.Allocator, offset: u64, max_bytes: usize, timeout_ms: i32) !ReadResult {
        const start_ms = std.time.milliTimestamp();

        while (true) {
            try self.pty.pump(&self.terminal);

            const window = self.terminal.offsetWindow();
            var effective_offset = offset;
            const truncated = effective_offset < window.base_offset;
            if (effective_offset < window.base_offset) effective_offset = window.base_offset;

            if (effective_offset < window.next_offset) {
                const raw = try self.terminal.readRaw(alloc, offset, max_bytes);
                return .{
                    .data = raw.data,
                    .offset = raw.offset,
                    .base_offset = raw.base_offset,
                    .truncated = raw.truncated,
                    .eof = self.pty.isClosed() and raw.offset >= window.next_offset,
                };
            }

            if (self.pty.isClosed()) {
                return .{
                    .data = try alloc.dupe(u8, ""),
                    .offset = window.next_offset,
                    .base_offset = window.base_offset,
                    .truncated = truncated,
                    .eof = true,
                };
            }

            const wait_ms = if (timeout_ms <= 0) -1 else blk: {
                const elapsed = std.time.milliTimestamp() - start_ms;
                const remaining = @as(i64, timeout_ms) - elapsed;
                if (remaining <= 0) return error.ReadTimeout;
                break :blk @as(i32, @intCast(remaining));
            };
            const ready = try self.pty.waitReadable(wait_ms);
            if (!ready) return error.ReadTimeout;
        }
    }
};

const State = struct {
    alloc: std.mem.Allocator,
    proxies: proxy_streams.Manager,
    registry: session_registry.Registry,
    runtimes: std.StringHashMap(*RuntimeSession),

    fn init(alloc: std.mem.Allocator) State {
        return .{
            .alloc = alloc,
            .proxies = proxy_streams.Manager.init(alloc),
            .registry = session_registry.Registry.init(alloc),
            .runtimes = std.StringHashMap(*RuntimeSession).init(alloc),
        };
    }

    fn deinit(self: *State) void {
        var iter = self.runtimes.valueIterator();
        while (iter.next()) |runtime| {
            runtime.*.deinit();
            self.alloc.destroy(runtime.*);
        }
        self.runtimes.deinit();
        self.proxies.deinit();
        self.registry.deinit();
    }
};

pub fn serve() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var state = State.init(alloc);
    defer state.deinit();

    const stdin = std.fs.File.stdin();
    var output_buf: [64 * 1024]u8 = undefined;
    var output_writer = std.fs.File.stdout().writer(&output_buf);
    const output = &output_writer.interface;

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(alloc);

    var read_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try stdin.read(&read_buf);
        if (n == 0) break;

        try pending.appendSlice(alloc, read_buf[0..n]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
            try handleLine(&state, output, pending.items[0..newline_index]);

            const remaining = pending.items[newline_index + 1 ..];
            std.mem.copyForwards(u8, pending.items[0..remaining.len], remaining);
            pending.items.len = remaining.len;
        }
    }

    if (pending.items.len > 0) {
        try handleLine(&state, output, pending.items);
    }
}

fn handleLine(state: *State, output: anytype, raw_line: []const u8) !void {
    const alloc = state.alloc;
    const trimmed = std.mem.trimRight(u8, raw_line, "\r");
    if (trimmed.len == 0) return;

    var req = json_rpc.decodeRequest(alloc, trimmed) catch {
        return writeResponse(output, alloc, try json_rpc.encodeResponse(alloc, .{
            .ok = false,
            .@"error" = .{
                .code = "invalid_request",
                .message = "invalid JSON request",
            },
        }));
    };
    defer req.deinit(alloc);

    const response = try dispatch(state, &req);
    try writeResponse(output, alloc, response);
}

fn dispatch(state: *State, req: *const json_rpc.Request) ![]u8 {
    const alloc = state.alloc;

    if (std.mem.eql(u8, req.method, "hello")) {
        return try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{
                .name = "cmuxd-remote",
                .version = "dev",
                .capabilities = .{
                    "session.basic",
                    "session.resize.min",
                    "terminal.stream",
                    "proxy.http_connect",
                    "proxy.socks5",
                    "proxy.stream",
                },
            },
        });
    }
    if (std.mem.eql(u8, req.method, "ping")) {
        return try json_rpc.encodeResponse(alloc, .{
            .id = req.id,
            .ok = true,
            .result = .{ .pong = true },
        });
    }
    if (std.mem.eql(u8, req.method, "proxy.open")) return handleProxyOpen(state, req);
    if (std.mem.eql(u8, req.method, "proxy.close")) return handleProxyClose(state, req);
    if (std.mem.eql(u8, req.method, "proxy.write")) return handleProxyWrite(state, req);
    if (std.mem.eql(u8, req.method, "proxy.read")) return handleProxyRead(state, req);
    if (std.mem.eql(u8, req.method, "session.open")) return handleSessionOpen(state, req);
    if (std.mem.eql(u8, req.method, "session.close")) return handleSessionClose(state, req);
    if (std.mem.eql(u8, req.method, "session.attach")) return handleSessionAttach(state, req);
    if (std.mem.eql(u8, req.method, "session.resize")) return handleSessionResize(state, req);
    if (std.mem.eql(u8, req.method, "session.detach")) return handleSessionDetach(state, req);
    if (std.mem.eql(u8, req.method, "session.status")) return handleSessionStatus(state, req);
    if (std.mem.eql(u8, req.method, "terminal.open")) return handleTerminalOpen(state, req);
    if (std.mem.eql(u8, req.method, "terminal.read")) return handleTerminalRead(state, req);
    if (std.mem.eql(u8, req.method, "terminal.write")) return handleTerminalWrite(state, req);

    return try json_rpc.encodeResponse(alloc, .{
        .id = req.id,
        .ok = false,
        .@"error" = .{
            .code = "method_not_found",
            .message = "unknown method",
        },
    });
}

fn handleProxyOpen(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "proxy.open requires params");
    const host = getRequiredStringParam(params, "host", "proxy.open requires host") catch |err| return paramError(state.alloc, req.id, err);
    const port = getRequiredPositiveU16Param(params, "port", "proxy.open requires port in range 1-65535") catch |err| return paramError(state.alloc, req.id, err);

    const stream_id = state.proxies.open(host, port) catch |err| {
        return errorResponse(state.alloc, req.id, "open_failed", @errorName(err));
    };

    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .stream_id = stream_id,
        },
    });
}

fn handleProxyClose(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "proxy.close requires params");
    const stream_id = getRequiredStringParam(params, "stream_id", "proxy.close requires stream_id") catch |err| return paramError(state.alloc, req.id, err);

    state.proxies.close(stream_id) catch {
        return errorResponse(state.alloc, req.id, "not_found", "stream not found");
    };
    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .closed = true },
    });
}

fn handleProxyWrite(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "proxy.write requires params");
    const stream_id = getRequiredStringParam(params, "stream_id", "proxy.write requires stream_id") catch |err| return paramError(state.alloc, req.id, err);
    const encoded = getRequiredStringParam(params, "data_base64", "proxy.write requires data_base64") catch |err| return paramError(state.alloc, req.id, err);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
        return invalidParams(state.alloc, req.id, "data_base64 must be valid base64");
    };
    const decoded = try state.alloc.alloc(u8, decoded_len);
    defer state.alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        return invalidParams(state.alloc, req.id, "data_base64 must be valid base64");
    };

    const written = state.proxies.write(stream_id, decoded) catch |err| switch (err) {
        error.StreamNotFound => return errorResponse(state.alloc, req.id, "not_found", "stream not found"),
        else => return errorResponse(state.alloc, req.id, "stream_error", @errorName(err)),
    };
    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{ .written = written },
    });
}

fn handleProxyRead(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "proxy.read requires params");
    const stream_id = getRequiredStringParam(params, "stream_id", "proxy.read requires stream_id") catch |err| return paramError(state.alloc, req.id, err);
    const max_bytes = getOptionalPositiveIntParam(params, "max_bytes") orelse 32_768;
    if (max_bytes > 262_144) {
        return invalidParams(state.alloc, req.id, "max_bytes must be in range 1-262144");
    }
    const timeout_ms = if (getOptionalNonNegativeIntParam(params, "timeout_ms")) |value| @as(i32, @intCast(value)) else 50;

    const read = state.proxies.read(state.alloc, stream_id, @intCast(max_bytes), timeout_ms) catch |err| switch (err) {
        error.StreamNotFound => return errorResponse(state.alloc, req.id, "not_found", "stream not found"),
        else => return errorResponse(state.alloc, req.id, "stream_error", @errorName(err)),
    };
    defer state.alloc.free(read.data);

    const encoded_len = std.base64.standard.Encoder.calcSize(read.data.len);
    const encoded = try state.alloc.alloc(u8, encoded_len);
    defer state.alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, read.data);

    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .data_base64 = encoded,
            .eof = read.eof,
        },
    });
}

fn handleSessionOpen(state: *State, req: *const json_rpc.Request) ![]u8 {
    const alloc = state.alloc;
    const params = getParamsObject(req);
    const requested_id = if (params) |object| getOptionalStringParam(object, "session_id") else null;
    const session_id = try state.registry.ensure(requested_id);
    var status = try state.registry.status(session_id);
    defer status.deinit(alloc);

    return encodeStatusResponse(alloc, req.id, status, null, null);
}

fn handleSessionClose(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "session.close requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.close requires session_id") catch |err| return paramError(state.alloc, req.id, err);

    state.registry.close(session_id) catch |err| return sessionErrorResponse(state.alloc, req.id, err);
    removeRuntime(state, session_id);
    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .closed = true,
        },
    });
}

fn handleSessionAttach(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "session.attach requires params");
    const parsed = parseAttachmentParams(params, "session.attach") catch |err| return paramError(state.alloc, req.id, err);

    state.registry.attach(parsed.session_id, parsed.attachment_id, parsed.cols, parsed.rows) catch |err| return sessionErrorResponse(state.alloc, req.id, err);
    var status = try state.registry.status(parsed.session_id);
    defer status.deinit(state.alloc);
    try resizeRuntimeIfPresent(state, &status);
    return encodeStatusResponse(state.alloc, req.id, status, null, null);
}

fn handleSessionResize(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "session.resize requires params");
    const parsed = parseAttachmentParams(params, "session.resize") catch |err| return paramError(state.alloc, req.id, err);

    state.registry.resize(parsed.session_id, parsed.attachment_id, parsed.cols, parsed.rows) catch |err| return sessionErrorResponse(state.alloc, req.id, err);
    var status = try state.registry.status(parsed.session_id);
    defer status.deinit(state.alloc);
    try resizeRuntimeIfPresent(state, &status);
    return encodeStatusResponse(state.alloc, req.id, status, null, null);
}

fn handleSessionDetach(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "session.detach requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.detach requires session_id") catch |err| return paramError(state.alloc, req.id, err);
    const attachment_id = getRequiredStringParam(params, "attachment_id", "session.detach requires attachment_id") catch |err| return paramError(state.alloc, req.id, err);

    state.registry.detach(session_id, attachment_id) catch |err| return sessionErrorResponse(state.alloc, req.id, err);
    var status = try state.registry.status(session_id);
    defer status.deinit(state.alloc);
    try resizeRuntimeIfPresent(state, &status);
    return encodeStatusResponse(state.alloc, req.id, status, null, null);
}

fn handleSessionStatus(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "session.status requires params");
    const session_id = getRequiredStringParam(params, "session_id", "session.status requires session_id") catch |err| return paramError(state.alloc, req.id, err);

    var status = state.registry.status(session_id) catch |err| return sessionErrorResponse(state.alloc, req.id, err);
    defer status.deinit(state.alloc);
    return encodeStatusResponse(state.alloc, req.id, status, null, null);
}

fn handleTerminalOpen(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "terminal.open requires params");
    const command = getRequiredStringParam(params, "command", "terminal.open requires command") catch |err| return paramError(state.alloc, req.id, err);
    const cols = getRequiredPositiveU16Param(params, "cols", "terminal.open requires cols > 0") catch |err| return paramError(state.alloc, req.id, err);
    const rows = getRequiredPositiveU16Param(params, "rows", "terminal.open requires rows > 0") catch |err| return paramError(state.alloc, req.id, err);

    const opened = try state.registry.open(cols, rows);
    var status = try state.registry.status(opened.session_id);
    defer status.deinit(state.alloc);

    const runtime = try state.alloc.create(RuntimeSession);
    errdefer state.alloc.destroy(runtime);
    runtime.* = try RuntimeSession.init(state.alloc, command, status.effective_cols, status.effective_rows);
    errdefer runtime.deinit();
    errdefer state.registry.close(opened.session_id) catch {};

    try state.runtimes.put(opened.session_id, runtime);
    return encodeStatusResponse(state.alloc, req.id, status, opened.attachment_id, 0);
}

fn handleTerminalRead(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "terminal.read requires params");
    const session_id = getRequiredStringParam(params, "session_id", "terminal.read requires session_id") catch |err| return paramError(state.alloc, req.id, err);
    const offset = getRequiredU64Param(params, "offset", "terminal.read requires offset >= 0") catch |err| return paramError(state.alloc, req.id, err);
    const max_bytes = if (getOptionalPositiveIntParam(params, "max_bytes")) |value| @as(usize, @intCast(value)) else 65_536;
    const timeout_ms = if (getOptionalNonNegativeIntParam(params, "timeout_ms")) |value| @as(i32, @intCast(value)) else 0;

    const runtime = state.runtimes.getPtr(session_id) orelse return terminalNotFound(state.alloc, req.id);
    const read = runtime.*.*.read(state.alloc, offset, max_bytes, timeout_ms) catch |err| switch (err) {
        error.ReadTimeout => return deadlineExceeded(state.alloc, req.id, "terminal read timed out"),
        else => return internalError(state.alloc, req.id, err),
    };
    defer state.alloc.free(read.data);

    const encoded_len = std.base64.standard.Encoder.calcSize(read.data.len);
    const encoded = try state.alloc.alloc(u8, encoded_len);
    defer state.alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, read.data);

    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .offset = read.offset,
            .base_offset = read.base_offset,
            .truncated = read.truncated,
            .eof = read.eof,
            .data = encoded,
        },
    });
}

fn handleTerminalWrite(state: *State, req: *const json_rpc.Request) ![]u8 {
    const params = getParamsObject(req) orelse return invalidParams(state.alloc, req.id, "terminal.write requires params");
    const session_id = getRequiredStringParam(params, "session_id", "terminal.write requires session_id") catch |err| return paramError(state.alloc, req.id, err);
    const encoded = getRequiredStringParam(params, "data", "terminal.write requires data") catch |err| return paramError(state.alloc, req.id, err);

    const runtime = state.runtimes.getPtr(session_id) orelse return terminalNotFound(state.alloc, req.id);

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
        return invalidParams(state.alloc, req.id, "terminal.write data must be base64");
    };
    const decoded = try state.alloc.alloc(u8, decoded_len);
    defer state.alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded) catch {
        return invalidParams(state.alloc, req.id, "terminal.write data must be base64");
    };

    runtime.*.*.pty.write(decoded) catch |err| return internalError(state.alloc, req.id, err);
    return try json_rpc.encodeResponse(state.alloc, .{
        .id = req.id,
        .ok = true,
        .result = .{
            .session_id = session_id,
            .written = decoded.len,
        },
    });
}

fn resizeRuntimeIfPresent(state: *State, status: *const session_registry.SessionStatus) !void {
    const runtime = state.runtimes.getPtr(status.session_id) orelse return;
    runtime.*.*.resize(status.effective_cols, status.effective_rows) catch |err| return err;
}

fn removeRuntime(state: *State, session_id: []const u8) void {
    const removed = state.runtimes.fetchRemove(session_id) orelse return;
    removed.value.deinit();
    state.alloc.destroy(removed.value);
}

fn encodeStatusResponse(
    alloc: std.mem.Allocator,
    id: ?std.json.Value,
    status: session_registry.SessionStatus,
    attachment_id: ?[]const u8,
    offset: ?u64,
) ![]u8 {
    var attachments = std.ArrayList(AttachmentResult).empty;
    defer attachments.deinit(alloc);

    for (status.attachments) |attachment| {
        try attachments.append(alloc, .{
            .attachment_id = attachment.attachment_id,
            .cols = attachment.cols,
            .rows = attachment.rows,
        });
    }

    return try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = true,
        .result = .{
            .session_id = status.session_id,
            .attachments = attachments.items,
            .effective_cols = status.effective_cols,
            .effective_rows = status.effective_rows,
            .last_known_cols = status.last_known_cols,
            .last_known_rows = status.last_known_rows,
            .attachment_id = attachment_id,
            .offset = offset,
        },
    });
}

fn getParamsObject(req: *const json_rpc.Request) ?std.json.ObjectMap {
    const value = req.parsed.value.object.get("params") orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn getOptionalStringParam(params: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = params.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getRequiredStringParam(params: std.json.ObjectMap, key: []const u8, message: []const u8) ![]const u8 {
    if (getOptionalStringParam(params, key)) |value| return value;
    _ = message;
    return error.InvalidStringParam;
}

fn getOptionalNonNegativeIntParam(params: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = params.get(key) orelse return null;
    return intFromValue(value);
}

fn getOptionalPositiveIntParam(params: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = intFromValue(params.get(key) orelse return null) orelse return null;
    if (value <= 0) return null;
    return value;
}

fn getRequiredPositiveU16Param(params: std.json.ObjectMap, key: []const u8, message: []const u8) !u16 {
    const value = getOptionalPositiveIntParam(params, key) orelse {
        _ = message;
        return error.InvalidPositiveParam;
    };
    if (value > std.math.maxInt(u16)) return error.InvalidPositiveParam;
    return @intCast(value);
}

fn getRequiredU64Param(params: std.json.ObjectMap, key: []const u8, message: []const u8) !u64 {
    const raw = params.get(key) orelse {
        _ = message;
        return error.InvalidUnsignedParam;
    };
    const value = intFromValue(raw) orelse {
        _ = message;
        return error.InvalidUnsignedParam;
    };
    if (value < 0) return error.InvalidUnsignedParam;
    return @intCast(value);
}

fn intFromValue(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |int| int,
        .float => |float| if (@floor(float) == float) @as(i64, @intFromFloat(float)) else null,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch null,
        else => null,
    };
}

const ParsedAttachmentParams = struct {
    session_id: []const u8,
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

fn parseAttachmentParams(params: std.json.ObjectMap, method: []const u8) !ParsedAttachmentParams {
    const session_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires session_id", .{method});
    defer std.heap.page_allocator.free(session_message);
    const attachment_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires attachment_id", .{method});
    defer std.heap.page_allocator.free(attachment_message);
    const cols_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires cols > 0", .{method});
    defer std.heap.page_allocator.free(cols_message);
    const rows_message = try std.fmt.allocPrint(std.heap.page_allocator, "{s} requires rows > 0", .{method});
    defer std.heap.page_allocator.free(rows_message);

    return .{
        .session_id = try getRequiredStringParam(params, "session_id", session_message),
        .attachment_id = try getRequiredStringParam(params, "attachment_id", attachment_message),
        .cols = try getRequiredPositiveU16Param(params, "cols", cols_message),
        .rows = try getRequiredPositiveU16Param(params, "rows", rows_message),
    };
}

fn paramError(alloc: std.mem.Allocator, id: ?std.json.Value, err: anyerror) ![]u8 {
    return switch (err) {
        error.InvalidStringParam => invalidParams(alloc, id, "missing required string parameter"),
        error.InvalidPositiveParam => invalidParams(alloc, id, "missing required positive integer parameter"),
        error.InvalidUnsignedParam => invalidParams(alloc, id, "missing required unsigned integer parameter"),
        else => internalError(alloc, id, err),
    };
}

fn sessionErrorResponse(alloc: std.mem.Allocator, id: ?std.json.Value, err: anyerror) ![]u8 {
    return switch (err) {
        error.SessionNotFound => errorResponse(alloc, id, "not_found", "session not found"),
        error.AttachmentNotFound => errorResponse(alloc, id, "not_found", "attachment not found"),
        else => errorResponse(alloc, id, "invalid_params", "cols and rows must be greater than zero"),
    };
}

fn terminalNotFound(alloc: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    return errorResponse(alloc, id, "not_found", "terminal session not found");
}

fn deadlineExceeded(alloc: std.mem.Allocator, id: ?std.json.Value, message: []const u8) ![]u8 {
    return errorResponse(alloc, id, "deadline_exceeded", message);
}

fn invalidParams(alloc: std.mem.Allocator, id: ?std.json.Value, message: []const u8) ![]u8 {
    return errorResponse(alloc, id, "invalid_params", message);
}

fn internalError(alloc: std.mem.Allocator, id: ?std.json.Value, err: anyerror) ![]u8 {
    return errorResponse(alloc, id, "internal_error", @errorName(err));
}

fn errorResponse(alloc: std.mem.Allocator, id: ?std.json.Value, code: []const u8, message: []const u8) ![]u8 {
    return try json_rpc.encodeResponse(alloc, .{
        .id = id,
        .ok = false,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    });
}

fn writeResponse(output: anytype, alloc: std.mem.Allocator, payload: []u8) !void {
    defer alloc.free(payload);
    try output.print("{s}\n", .{payload});
    try output.flush();
}
