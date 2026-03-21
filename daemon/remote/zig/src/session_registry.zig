const std = @import("std");

pub const AttachmentStatus = struct {
    attachment_id: []const u8,
    cols: u16,
    rows: u16,
};

pub const SessionStatus = struct {
    session_id: []const u8,
    attachments: []AttachmentStatus,
    effective_cols: u16,
    effective_rows: u16,
    last_known_cols: u16,
    last_known_rows: u16,

    pub fn deinit(self: *SessionStatus, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.attachments);
    }
};

const AttachmentState = struct {
    cols: u16,
    rows: u16,
};

const SessionState = struct {
    attachments: std.StringHashMap(AttachmentState),
    effective_cols: u16 = 0,
    effective_rows: u16 = 0,
    last_known_cols: u16 = 0,
    last_known_rows: u16 = 0,
};

pub const Registry = struct {
    alloc: std.mem.Allocator,
    next_session_id: u64 = 1,
    next_attachment_id: u64 = 1,
    sessions: std.StringHashMap(SessionState),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{
            .alloc = alloc,
            .sessions = std.StringHashMap(SessionState).init(alloc),
        };
    }

    pub fn deinit(self: *Registry) void {
        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.attachments.deinit();
            self.alloc.free(entry.key_ptr.*);
        }
        self.sessions.deinit();
    }

    pub fn open(self: *Registry, cols: u16, rows: u16) !struct { session_id: []const u8, attachment_id: []const u8 } {
        const session_id = try std.fmt.allocPrint(self.alloc, "sess-{d}", .{self.next_session_id});
        self.next_session_id += 1;

        var session = SessionState{
            .attachments = std.StringHashMap(AttachmentState).init(self.alloc),
        };
        const attachment_id = try std.fmt.allocPrint(self.alloc, "att-{d}", .{self.next_attachment_id});
        self.next_attachment_id += 1;
        try session.attachments.put(attachment_id, .{ .cols = cols, .rows = rows });
        recompute(&session);
        try self.sessions.put(session_id, session);

        return .{
            .session_id = session_id,
            .attachment_id = attachment_id,
        };
    }

    pub fn ensure(self: *Registry, maybe_session_id: ?[]const u8) ![]const u8 {
        if (maybe_session_id) |session_id| {
            if (self.sessions.contains(session_id)) {
                return try self.alloc.dupe(u8, session_id);
            }

            const owned = try self.alloc.dupe(u8, session_id);
            const session = SessionState{
                .attachments = std.StringHashMap(AttachmentState).init(self.alloc),
            };
            try self.sessions.put(owned, session);
            return try self.alloc.dupe(u8, owned);
        }

        const opened = try self.open(0, 0);
        self.detach(opened.session_id, opened.attachment_id) catch {};
        self.alloc.free(opened.attachment_id);
        return opened.session_id;
    }

    pub fn attach(self: *Registry, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const owned_attachment = if (session.attachments.contains(attachment_id))
            null
        else
            try self.alloc.dupe(u8, attachment_id);
        errdefer if (owned_attachment) |value| self.alloc.free(value);

        try session.attachments.put(owned_attachment orelse attachment_id, .{ .cols = cols, .rows = rows });
        recompute(session);
    }

    pub fn resize(self: *Registry, session_id: []const u8, attachment_id: []const u8, cols: u16, rows: u16) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const attachment = session.attachments.getPtr(attachment_id) orelse return error.AttachmentNotFound;
        attachment.* = .{ .cols = cols, .rows = rows };
        recompute(session);
    }

    pub fn detach(self: *Registry, session_id: []const u8, attachment_id: []const u8) !void {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;
        const owned_attachment = session.attachments.fetchRemove(attachment_id) orelse return error.AttachmentNotFound;
        self.alloc.free(owned_attachment.key);
        recompute(session);
    }

    pub fn close(self: *Registry, session_id: []const u8) !void {
        const removed = self.sessions.fetchRemove(session_id) orelse return error.SessionNotFound;
        var session = removed.value;

        var iter = session.attachments.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        session.attachments.deinit();
        self.alloc.free(removed.key);
    }

    pub fn status(self: *Registry, session_id: []const u8) !SessionStatus {
        const session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;

        var attachments = std.ArrayList(AttachmentStatus).empty;
        defer attachments.deinit(self.alloc);

        var iter = session.attachments.iterator();
        while (iter.next()) |entry| {
            try attachments.append(self.alloc, .{
                .attachment_id = entry.key_ptr.*,
                .cols = entry.value_ptr.cols,
                .rows = entry.value_ptr.rows,
            });
        }
        std.mem.sort(AttachmentStatus, attachments.items, {}, struct {
            fn lessThan(_: void, a: AttachmentStatus, b: AttachmentStatus) bool {
                return std.mem.order(u8, a.attachment_id, b.attachment_id) == .lt;
            }
        }.lessThan);

        return .{
            .session_id = try self.alloc.dupe(u8, session_id),
            .attachments = try attachments.toOwnedSlice(self.alloc),
            .effective_cols = session.effective_cols,
            .effective_rows = session.effective_rows,
            .last_known_cols = session.last_known_cols,
            .last_known_rows = session.last_known_rows,
        };
    }
};

fn recompute(session: *SessionState) void {
    if (session.attachments.count() == 0) {
        session.effective_cols = session.last_known_cols;
        session.effective_rows = session.last_known_rows;
        return;
    }

    var iter = session.attachments.iterator();
    var min_cols: u16 = 0;
    var min_rows: u16 = 0;
    while (iter.next()) |entry| {
        const value = entry.value_ptr.*;
        if (min_cols == 0 or value.cols < min_cols) min_cols = value.cols;
        if (min_rows == 0 or value.rows < min_rows) min_rows = value.rows;
    }

    session.effective_cols = min_cols;
    session.effective_rows = min_rows;
    session.last_known_cols = min_cols;
    session.last_known_rows = min_rows;
}

test "open allocates session and attachment ids" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try std.testing.expectEqualStrings("sess-1", opened.session_id);
    try std.testing.expectEqualStrings("att-1", opened.attachment_id);
}

test "attach and resize recompute smallest screen wins" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.resize(opened.session_id, opened.attachment_id, 100, 30);
    try registry.attach(opened.session_id, "att-2", 80, 24);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 80), status.effective_cols);
    try std.testing.expectEqual(@as(u16, 24), status.effective_rows);
}

test "detach preserves last known size" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.detach(opened.session_id, opened.attachment_id);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 120), status.last_known_cols);
    try std.testing.expectEqual(@as(u16, 40), status.last_known_rows);
    try std.testing.expectEqual(@as(u16, 120), status.effective_cols);
    try std.testing.expectEqual(@as(u16, 40), status.effective_rows);
}

test "status attachments are sorted by id" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.attach(opened.session_id, "att-9", 90, 30);
    try registry.attach(opened.session_id, "att-2", 80, 24);

    var status = try registry.status(opened.session_id);
    defer status.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("att-1", status.attachments[0].attachment_id);
    try std.testing.expectEqualStrings("att-2", status.attachments[1].attachment_id);
    try std.testing.expectEqualStrings("att-9", status.attachments[2].attachment_id);
}

test "close removes session from registry" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const opened = try registry.open(120, 40);
    defer std.testing.allocator.free(opened.session_id);
    defer std.testing.allocator.free(opened.attachment_id);

    try registry.close(opened.session_id);
    try std.testing.expectError(error.SessionNotFound, registry.status(opened.session_id));
}
