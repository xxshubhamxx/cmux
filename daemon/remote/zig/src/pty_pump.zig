const std = @import("std");
const builtin = @import("builtin");
const pty_host = @import("pty_host.zig");
const terminal_session = @import("terminal_session.zig");

pub const supported = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// Per-session callback hook for Phase 1b. The pump thread calls this after
/// each successful drain so subscriber lists can push to per-subscriber
/// bounded queues. MUST be non-blocking — never do network I/O here.
pub const NotifyFn = *const fn (ctx: ?*anyopaque, entry: Entry) void;

pub const Entry = struct {
    pty: *pty_host.PtyHost,
    terminal: *terminal_session.TerminalSession,
    /// Lock held by the pump while pumping; other threads must take it before
    /// touching `pty`/`terminal` to keep ghostty-vt and ring-buffer state
    /// race-free.
    lock: *std.Thread.Mutex,
    session_id: []const u8,
};

pub const Pump = if (supported) KqueuePump else StubPump;

const StubPump = struct {
    pub fn init(_: std.mem.Allocator) !StubPump {
        return error.UnsupportedPlatform;
    }
    pub fn start(_: *StubPump) !void {}
    pub fn deinit(_: *StubPump) void {}
    pub fn setNotify(_: *StubPump, _: ?*anyopaque, _: NotifyFn) void {}
    pub fn register(_: *StubPump, _: std.posix.fd_t, _: Entry) !void {}
    pub fn unregister(_: *StubPump, _: std.posix.fd_t) void {}
};

const KqueuePump = struct {
    // kqueue flag/filter constants. Zig's std.c only exposes EVFILT enums on
    // Darwin/BSD; the EV_/NOTE_ flag values are defined inline so we don't
    // depend on @cImport for sys/event.h.
    const EV_ADD: u16 = 0x0001;
    const EV_DELETE: u16 = 0x0002;
    const EV_CLEAR: u16 = 0x0020;
    const NOTE_TRIGGER: u32 = 0x01000000;
    const wake_ident: usize = 0xC1A551C0;

    alloc: std.mem.Allocator,
    kq: i32,
    map_mutex: std.Thread.Mutex = .{},
    entries: std.AutoHashMapUnmanaged(std.posix.fd_t, Entry) = .{},
    thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    notify_fn: ?NotifyFn = null,
    notify_ctx: ?*anyopaque = null,

    /// Held by the pump thread while it is inside the per-event processing
    /// body (dereferencing `entry.pty` / `entry.terminal`). Callers of
    /// `unregister` acquire this immediately after removing the entry from
    /// the map so they are guaranteed the pump is not currently touching
    /// the just-removed entry's backing memory before returning. This
    /// closes a UAF race where `closeSession` would deinit+destroy a
    /// `RuntimeSession` while the pump thread still had `entry.pty` /
    /// `entry.terminal` pointers into it from an iteration that started
    /// before the unregister ran.
    processing_mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator) !KqueuePump {
        const kq = try std.posix.kqueue();
        const pump: KqueuePump = .{
            .alloc = alloc,
            .kq = kq,
        };
        var changes = [_]std.posix.Kevent{makeUserEvent(EV_ADD | EV_CLEAR, 0)};
        _ = std.posix.kevent(kq, &changes, &.{}, null) catch |err| {
            std.posix.close(kq);
            return err;
        };
        return pump;
    }

    pub fn start(self: *KqueuePump) !void {
        if (self.thread != null) return;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *KqueuePump) void {
        self.shutdown.store(true, .seq_cst);
        var changes = [_]std.posix.Kevent{makeUserEvent(0, NOTE_TRIGGER)};
        _ = std.posix.kevent(self.kq, &changes, &.{}, null) catch {};
        if (self.thread) |t| t.join();
        self.thread = null;
        std.posix.close(self.kq);
        self.entries.deinit(self.alloc);
    }

    pub fn setNotify(self: *KqueuePump, ctx: ?*anyopaque, func: NotifyFn) void {
        self.notify_ctx = ctx;
        self.notify_fn = func;
    }

    pub fn register(self: *KqueuePump, fd: std.posix.fd_t, entry: Entry) !void {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();

        try self.entries.put(self.alloc, fd, entry);
        errdefer _ = self.entries.remove(fd);

        var changes = [_]std.posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = readFilter(),
            .flags = EV_ADD | EV_CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        _ = try std.posix.kevent(self.kq, &changes, &.{}, null);
    }

    pub fn unregister(self: *KqueuePump, fd: std.posix.fd_t) void {
        self.map_mutex.lock();
        const removed = self.entries.remove(fd);
        if (removed) {
            var changes = [_]std.posix.Kevent{.{
                .ident = @intCast(fd),
                .filter = readFilter(),
                .flags = EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = std.posix.kevent(self.kq, &changes, &.{}, null) catch {};
        }
        self.map_mutex.unlock();

        // Barrier: if the pump is mid-iteration on this (or any other)
        // entry, wait for it to finish that iteration before returning.
        // After this point the caller can safely free the RuntimeSession
        // backing the removed entry — the pump cannot be holding any of
        // its pointers because it's either blocked at kevent() or about
        // to look up the next entry from the now-updated map.
        if (removed) {
            self.processing_mutex.lock();
            self.processing_mutex.unlock();
        }
    }

    fn run(self: *KqueuePump) void {
        var events: [64]std.posix.Kevent = undefined;
        while (!self.shutdown.load(.seq_cst)) {
            const n = std.posix.kevent(self.kq, &.{}, &events, null) catch |err| {
                // `std.posix.kevent` already loops on EINTR internally, so
                // every surfaced error is permanent (ACCES / NOENT / NOMEM
                // / SRCH). There's no cure for a broken kqueue from this
                // thread; log + exit so deinit can join cleanly instead
                // of letting the loop spin silently.
                std.log.warn("pty_pump: kevent failed, exiting: {s}", .{@errorName(err)});
                return;
            };
            if (self.shutdown.load(.seq_cst)) return;

            // Held across the whole per-event batch so `unregister` can
            // synchronize on it — see `unregister` for the UAF rationale.
            self.processing_mutex.lock();
            defer self.processing_mutex.unlock();

            for (events[0..n]) |ev| {
                if (ev.filter == userFilter()) continue;
                if (ev.filter != readFilter()) continue;

                const fd: std.posix.fd_t = @intCast(ev.ident);
                self.map_mutex.lock();
                const maybe_entry = self.entries.get(fd);
                self.map_mutex.unlock();

                const entry = maybe_entry orelse continue;

                entry.lock.lock();
                entry.pty.pump(entry.terminal) catch |err| {
                    std.log.warn("pty_pump: pump failed for fd {d}: {s}", .{ fd, @errorName(err) });
                };
                const closed = entry.pty.isClosed();
                entry.lock.unlock();

                if (self.notify_fn) |f| f(self.notify_ctx, entry);

                if (closed) {
                    var changes = [_]std.posix.Kevent{.{
                        .ident = @intCast(fd),
                        .filter = readFilter(),
                        .flags = EV_DELETE,
                        .fflags = 0,
                        .data = 0,
                        .udata = 0,
                    }};
                    _ = std.posix.kevent(self.kq, &changes, &.{}, null) catch {};
                }
            }
        }
    }

    const FilterT = @TypeOf(@as(std.posix.Kevent, undefined).filter);

    inline fn readFilter() FilterT {
        return @intCast(std.c.EVFILT.READ);
    }

    inline fn userFilter() FilterT {
        return @intCast(std.c.EVFILT.USER);
    }

    fn makeUserEvent(flags_in: anytype, fflags: u32) std.posix.Kevent {
        const FlagsT = @TypeOf(@as(std.posix.Kevent, undefined).flags);
        return .{
            .ident = wake_ident,
            .filter = userFilter(),
            .flags = @as(FlagsT, @intCast(flags_in)),
            .fflags = fflags,
            .data = 0,
            .udata = 0,
        };
    }
};
