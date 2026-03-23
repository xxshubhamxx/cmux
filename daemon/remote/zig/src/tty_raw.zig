const std = @import("std");
const cross = @import("cross.zig");

pub const RestoreGuard = struct {
    fd: std.posix.fd_t,
    original: cross.c.struct_termios,
    active: bool,

    pub fn enter(fd: std.posix.fd_t) !RestoreGuard {
        var original: cross.c.struct_termios = undefined;
        if (cross.c.tcgetattr(fd, &original) != 0) return error.GetAttrFailed;
        var raw = original;
        cross.c.cfmakeraw(&raw);
        raw.c_cc[cross.c.VMIN] = 1;
        raw.c_cc[cross.c.VTIME] = 0;
        if (cross.c.tcsetattr(fd, cross.c.TCSAFLUSH, &raw) != 0) return error.SetAttrFailed;
        return .{
            .fd = fd,
            .original = original,
            .active = true,
        };
    }

    pub fn deinit(self: *RestoreGuard) void {
        if (!self.active or self.fd < 0) return;
        _ = cross.c.tcsetattr(self.fd, cross.c.TCSAFLUSH, &self.original);
        self.active = false;
    }
};

pub fn currentSize(fd: std.posix.fd_t) !struct { cols: u16, rows: u16 } {
    var winsize = cross.c.struct_winsize{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    if (cross.c.ioctl(fd, cross.c.TIOCGWINSZ, &winsize) != 0) return error.GetWindowSizeFailed;
    return .{
        .cols = @max(@as(u16, 1), winsize.ws_col),
        .rows = @max(@as(u16, 1), winsize.ws_row),
    };
}

pub fn isDetachSequence(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0x1c) != null;
}

test "ctrl backslash requests detach" {
    try std.testing.expect(isDetachSequence("\x1c"));
}

test "raw mode restore guard is idempotent" {
    var guard = RestoreGuard{
        .fd = -1,
        .original = undefined,
        .active = false,
    };
    guard.deinit();
    guard.deinit();
}
