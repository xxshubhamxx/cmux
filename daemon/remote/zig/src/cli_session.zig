const std = @import("std");
const cli_attach = @import("cli_attach.zig");
const json_rpc = @import("json_rpc.zig");
const rpc_client = @import("rpc_client.zig");

const Command = enum {
    attach,
    list,
    status,
    history,
    kill,
    new,
};

const ParsedArgs = struct {
    command: Command,
    socket_path: ?[]const u8 = null,
    session_name: ?[]const u8 = null,
    detached: bool = false,
    command_text: ?[]u8 = null,

    pub fn deinit(self: *ParsedArgs, alloc: std.mem.Allocator) void {
        if (self.command_text) |command_text| alloc.free(command_text);
    }
};

pub fn run(args: []const []const u8, stderr: anytype, stdout: anytype) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = parseArgs(alloc, args) catch {
        try usage(stderr);
        return 2;
    };
    defer parsed.deinit(alloc);

    const socket_path = parsed.socket_path orelse {
        try usage(stderr);
        return 2;
    };

    var client = rpc_client.Client.init(alloc, socket_path);
    switch (parsed.command) {
        .attach => return cli_attach.run(alloc, socket_path, parsed.session_name.?, stderr),
        .list => return runList(&client, stdout, stderr),
        .status => return runStatus(&client, stdout, stderr, parsed.session_name.?),
        .history => return runHistory(&client, stdout, stderr, parsed.session_name.?),
        .kill => return runKill(&client, stdout, stderr, parsed.session_name.?),
        .new => return runNew(&client, stdout, stderr, parsed.session_name.?, parsed.command_text, parsed.detached),
    }
}

pub fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8) !ParsedArgs {
    if (args.len == 0) return error.InvalidArgs;

    var parsed = ParsedArgs{
        .command = switchCommand(args[0]) orelse return error.InvalidArgs,
    };

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        if (std.mem.eql(u8, arg, "--socket")) {
            idx += 1;
            if (idx >= args.len) return error.InvalidArgs;
            parsed.socket_path = args[idx];
            continue;
        }
        if (std.mem.eql(u8, arg, "--detached")) {
            parsed.detached = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            idx += 1;
            break;
        }
        if (parsed.session_name == null) {
            parsed.session_name = arg;
            continue;
        }
        break;
    }

    if (parsed.command == .list and parsed.session_name != null) return error.InvalidArgs;
    if (parsed.command != .list and parsed.session_name == null) return error.InvalidArgs;

    if (parsed.command == .new and idx < args.len) {
        parsed.command_text = try std.mem.join(alloc, " ", args[idx..]);
    }

    return parsed;
}

fn switchCommand(raw: []const u8) ?Command {
    if (std.mem.eql(u8, raw, "attach")) return .attach;
    if (std.mem.eql(u8, raw, "ls")) return .list;
    if (std.mem.eql(u8, raw, "status")) return .status;
    if (std.mem.eql(u8, raw, "history")) return .history;
    if (std.mem.eql(u8, raw, "kill")) return .kill;
    if (std.mem.eql(u8, raw, "new")) return .new;
    return null;
}

fn runList(client: *rpc_client.Client, stdout: anytype, stderr: anytype) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.list",
        .params = .{},
    }, stderr);
    defer response.deinit();

    const sessions = response.value.object.get("result").?.object.get("sessions").?.array;
    for (sessions.items) |item| {
        try stdout.print("{s}\n", .{item.object.get("session_id").?.string});
    }
    try stdout.flush();
    return 0;
}

fn runStatus(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.status",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try stdout.print("{s} {d}x{d}\n", .{
        result.get("session_id").?.string,
        try i64FromValue(result.get("effective_cols").?),
        try i64FromValue(result.get("effective_rows").?),
    });
    try stdout.flush();
    return 0;
}

fn runHistory(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.history",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const history = response.value.object.get("result").?.object.get("history").?.string;
    try stdout.print("{s}", .{history});
    try stdout.flush();
    return 0;
}

fn runKill(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8) !u8 {
    var response = try call(client, .{
        .id = "1",
        .method = "session.close",
        .params = .{ .session_id = session_name },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try stdout.print("{s}\n", .{result.get("session_id").?.string});
    try stdout.flush();
    return 0;
}

fn runNew(client: *rpc_client.Client, stdout: anytype, stderr: anytype, session_name: []const u8, command_text: ?[]const u8, detached: bool) !u8 {
    const command = command_text orelse "exec ${SHELL:-/bin/sh} -l";
    var response = try call(client, .{
        .id = "1",
        .method = "terminal.open",
        .params = .{
            .session_id = session_name,
            .command = command,
            .cols = 80,
            .rows = 24,
        },
    }, stderr);
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    const created_session = result.get("session_id").?.string;
    try stdout.print("{s}\n", .{created_session});
    try stdout.flush();
    if (detached) return 0;
    return cli_attach.run(client.alloc, client.socket_path, created_session, stderr);
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

fn usage(stderr: anytype) !void {
    try stderr.print("Usage: cmuxd-remote session <attach|ls|status|history|kill|new> [name] --socket <path> [--detached] [-- <command>]\n", .{});
    try stderr.flush();
}

fn i64FromValue(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |int| int,
        .float => |float| if (@floor(float) == float) @as(i64, @intFromFloat(float)) else error.InvalidResponse,
        .number_string => |raw| std.fmt.parseInt(i64, raw, 10) catch error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

test "parse session ls" {
    var parsed = try parseArgs(std.testing.allocator, &.{ "ls", "--socket", "/tmp/cmuxd.sock" });
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(Command.list, parsed.command);
    try std.testing.expectEqualStrings("/tmp/cmuxd.sock", parsed.socket_path.?);
}
