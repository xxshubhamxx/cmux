const std = @import("std");
const cli_relay = @import("cli_relay.zig");
const serve_stdio = @import("serve_stdio.zig");
const json_rpc = @import("json_rpc.zig");
const proxy_streams = @import("proxy_streams.zig");
const session_registry = @import("session_registry.zig");
const terminal_session = @import("terminal_session.zig");

pub fn main() !void {
    _ = json_rpc;
    _ = proxy_streams;
    _ = session_registry;
    _ = terminal_session;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const args = try std.process.argsAlloc(alloc);

    const exit_code = try run(args);
    std.process.exit(exit_code);
}

fn run(args: []const []const u8) !u8 {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const argv0 = if (args.len > 0) std.fs.path.basename(args[0]) else "cmuxd-remote";
    if (std.mem.eql(u8, argv0, "cmux")) {
        return cli_relay.run(if (args.len > 1) args[1..] else &.{}, stderr);
    }

    if (args.len <= 1) {
        try usage(stderr);
        return 2;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "version")) {
        try stdout.print("dev\n", .{});
        try stdout.flush();
        return 0;
    }
    if (std.mem.eql(u8, command, "cli")) {
        return cli_relay.run(if (args.len > 2) args[2..] else &.{}, stderr);
    }
    if (std.mem.eql(u8, command, "serve")) {
        if (args.len == 3 and std.mem.eql(u8, args[2], "--stdio")) {
            try serve_stdio.serve();
            return 0;
        }
        try stderr.print("serve requires exactly one of --stdio or --tls\n", .{});
        try stderr.flush();
        return 2;
    }

    try usage(stderr);
    return 2;
}

fn usage(stderr: anytype) !void {
    try stderr.print("Usage:\n", .{});
    try stderr.print("  cmuxd-remote version\n", .{});
    try stderr.print("  cmuxd-remote serve --stdio\n", .{});
    try stderr.print("  cmuxd-remote serve --tls --listen <addr> --server-id <id> --ticket-secret <secret> --cert-file <path> --key-file <path>\n", .{});
    try stderr.print("  cmuxd-remote cli <command> [args...]\n", .{});
    try stderr.flush();
}
