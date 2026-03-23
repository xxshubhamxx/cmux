const std = @import("std");
const cross = @import("cross.zig");
const json_rpc = @import("json_rpc.zig");
const rpc_client = @import("rpc_client.zig");
const tty_raw = @import("tty_raw.zig");

const ReadOutcome = union(enum) {
    timeout,
    data: struct {
        payload: []u8,
        next_offset: u64,
        eof: bool,
    },
};

const Size = struct {
    cols: u16,
    rows: u16,
};

const default_size = Size{ .cols = 80, .rows = 24 };

pub fn run(alloc: std.mem.Allocator, socket_path: []const u8, session_name: []const u8, stderr: anytype) !u8 {
    var client = rpc_client.Client.init(alloc, socket_path);
    const stdin_fd = std.fs.File.stdin().handle;
    const stdout_file = std.fs.File.stdout();
    const fallback_size = try statusSize(&client, session_name, stderr);
    const size = preferredAttachSize(currentSizeOr(fallback_size, stdin_fd), fallback_size);
    const attachment_id = try std.fmt.allocPrint(alloc, "cli-{d}", .{cross.c.getpid()});
    defer alloc.free(attachment_id);

    try attachSession(&client, session_name, attachment_id, size.cols, size.rows, stderr);

    var guard = try tty_raw.RestoreGuard.enter(stdin_fd);
    defer guard.deinit();
    defer detachSession(&client, session_name, attachment_id, stderr) catch {};

    var last_size = size;
    var offset: u64 = 0;
    var input_buf: [4096]u8 = undefined;

    while (true) {
        const desired_size = preferredAttachSize(currentSizeOr(last_size, stdin_fd), last_size);
        if (desired_size.cols != last_size.cols or desired_size.rows != last_size.rows) {
            try resizeSession(&client, session_name, attachment_id, desired_size.cols, desired_size.rows, stderr);
            last_size = desired_size;
        }

        switch (try readTerminal(&client, session_name, offset, stderr)) {
            .timeout => {},
            .data => |read| {
                defer alloc.free(read.payload);
                if (read.payload.len > 0) try stdout_file.writeAll(read.payload);
                offset = read.next_offset;
                if (read.eof) return 0;
            },
        }

        var poll_fds = [1]std.posix.pollfd{.{
            .fd = stdin_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, 50);
        if (ready == 0) continue;

        const read_len = try std.posix.read(stdin_fd, &input_buf);
        if (read_len == 0) return 0;

        const input = input_buf[0..read_len];
        if (std.mem.indexOfScalar(u8, input, 0x1c)) |detach_idx| {
            if (detach_idx > 0) try writeTerminal(&client, session_name, input[0..detach_idx], stderr);
            return 0;
        }
        try writeTerminal(&client, session_name, input, stderr);
    }
}

fn attachSession(client: *rpc_client.Client, session_name: []const u8, attachment_id: []const u8, cols: u16, rows: u16, stderr: anytype) !void {
    var response = try call(client, .{
        .id = "1",
        .method = "session.attach",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
            .cols = cols,
            .rows = rows,
        },
    }, stderr);
    response.deinit();
}

fn resizeSession(client: *rpc_client.Client, session_name: []const u8, attachment_id: []const u8, cols: u16, rows: u16, stderr: anytype) !void {
    var response = try call(client, .{
        .id = "1",
        .method = "session.resize",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
            .cols = cols,
            .rows = rows,
        },
    }, stderr);
    response.deinit();
}

fn detachSession(client: *rpc_client.Client, session_name: []const u8, attachment_id: []const u8, stderr: anytype) !void {
    var response = try call(client, .{
        .id = "1",
        .method = "session.detach",
        .params = .{
            .session_id = session_name,
            .attachment_id = attachment_id,
        },
    }, stderr);
    response.deinit();
}

fn writeTerminal(client: *rpc_client.Client, session_name: []const u8, data: []const u8, stderr: anytype) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try client.alloc.alloc(u8, encoded_len);
    defer client.alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    var response = try call(client, .{
        .id = "1",
        .method = "terminal.write",
        .params = .{
            .session_id = session_name,
            .data = encoded,
        },
    }, stderr);
    response.deinit();
}

fn readTerminal(client: *rpc_client.Client, session_name: []const u8, offset: u64, stderr: anytype) !ReadOutcome {
    const request_json = try json_rpc.encodeResponse(client.alloc, .{
        .id = "1",
        .method = "terminal.read",
        .params = .{
            .session_id = session_name,
            .offset = offset,
            .max_bytes = 65536,
            .timeout_ms = 50,
        },
    });
    defer client.alloc.free(request_json);

    var response = try client.call(request_json);
    errdefer response.deinit();

    const root = response.value;
    if (root != .object) return error.InvalidResponse;
    const ok_value = root.object.get("ok") orelse return error.InvalidResponse;
    if (ok_value != .bool) return error.InvalidResponse;
    if (!ok_value.bool) {
        const err_obj = root.object.get("error") orelse return error.InvalidResponse;
        if (err_obj != .object) return error.InvalidResponse;
        const code = err_obj.object.get("code") orelse return error.InvalidResponse;
        if (code == .string and std.mem.eql(u8, code.string, "deadline_exceeded")) {
            response.deinit();
            return .timeout;
        }
        const message = err_obj.object.get("message") orelse return error.InvalidResponse;
        if (message != .string) return error.InvalidResponse;
        try stderr.print("{s}\n", .{message.string});
        try stderr.flush();
        return error.RemoteError;
    }

    const result = root.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const encoded = result.object.get("data") orelse return error.InvalidResponse;
    const next_offset_value = result.object.get("offset") orelse return error.InvalidResponse;
    const eof_value = result.object.get("eof") orelse return error.InvalidResponse;
    if (encoded != .string or eof_value != .bool) return error.InvalidResponse;

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded.string) catch return error.InvalidResponse;
    const decoded = try client.alloc.alloc(u8, decoded_len);
    errdefer client.alloc.free(decoded);
    std.base64.standard.Decoder.decode(decoded, encoded.string) catch return error.InvalidResponse;

    const next_offset = try u64FromValue(next_offset_value);
    response.deinit();
    return .{
        .data = .{
            .payload = decoded,
            .next_offset = next_offset,
            .eof = eof_value.bool,
        },
    };
}

fn statusSize(client: *rpc_client.Client, session_name: []const u8, stderr: anytype) !Size {
    var response = try call(client, .{
        .id = "1",
        .method = "session.status",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    return preferredAttachSize(.{
        .cols = try u16FromValue(result.get("effective_cols").?),
        .rows = try u16FromValue(result.get("effective_rows").?),
    }, default_size);
}

fn currentSizeOr(fallback: Size, fd: std.posix.fd_t) Size {
    const observed = tty_raw.currentSize(fd) catch return fallback;
    return .{ .cols = observed.cols, .rows = observed.rows };
}

fn preferredAttachSize(observed: Size, fallback: Size) Size {
    if (isUsableLocalSize(observed)) return observed;
    if (isUsableLocalSize(fallback)) return fallback;
    return default_size;
}

fn isUsableLocalSize(size: Size) bool {
    return size.cols >= 4 and size.rows >= 2;
}

fn call(client: *rpc_client.Client, request: anytype, stderr: anytype) !std.json.Parsed(std.json.Value) {
    const request_json = try json_rpc.encodeResponse(client.alloc, request);
    defer client.alloc.free(request_json);

    var response = try client.call(request_json);
    const root = response.value;
    if (root != .object) return error.InvalidResponse;
    if ((root.object.get("ok") orelse return error.InvalidResponse) != .bool) return error.InvalidResponse;
    if (root.object.get("ok").?.bool) return response;

    const err_obj = root.object.get("error") orelse return error.InvalidResponse;
    if (err_obj != .object) return error.InvalidResponse;
    const message = err_obj.object.get("message") orelse return error.InvalidResponse;
    if (message != .string) return error.InvalidResponse;

    try stderr.print("{s}\n", .{message.string});
    try stderr.flush();
    response.deinit();
    return error.RemoteError;
}

fn u64FromValue(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @intCast(int) else error.InvalidResponse,
        .float => |float| if (float >= 0 and @floor(float) == float) @as(u64, @intFromFloat(float)) else error.InvalidResponse,
        .number_string => |raw| std.fmt.parseInt(u64, raw, 10) catch error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

fn u16FromValue(value: std.json.Value) !u16 {
    const raw = try u64FromValue(value);
    if (raw > std.math.maxInt(u16)) return error.InvalidResponse;
    return @intCast(raw);
}

test "preferred attach size uses local tty when sane" {
    const size = preferredAttachSize(.{ .cols = 120, .rows = 40 }, .{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(@as(u16, 120), size.cols);
    try std.testing.expectEqual(@as(u16, 40), size.rows);
}

test "preferred attach size falls back for tiny tty" {
    const size = preferredAttachSize(.{ .cols = 1, .rows = 1 }, .{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(@as(u16, 80), size.cols);
    try std.testing.expectEqual(@as(u16, 24), size.rows);
}
