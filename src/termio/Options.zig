//! The options that are used to configure a terminal IO implementation.

const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const Config = @import("../config.zig").Config;
const termio = @import("../termio.zig");

pub const OutputCallback = struct {
    callback: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
    userdata: ?*anyopaque = null,

    /// Invoke the host callback with raw PTY bytes. A no-op when no callback
    /// is registered, so callers don't need to repeat the null check.
    pub fn invoke(self: OutputCallback, bytes: []const u8) void {
        if (self.callback) |cb| {
            cb(self.userdata, bytes.ptr, bytes.len);
        }
    }
};

test "OutputCallback default invoke is a no-op" {
    const cb: OutputCallback = .{};
    cb.invoke("ignored");
    cb.invoke("");
}

test "OutputCallback invoke forwards bytes and userdata" {
    const Captured = struct {
        calls: usize = 0,
        last_userdata: ?*anyopaque = null,
        last_bytes: [16]u8 = .{0} ** 16,
        last_len: usize = 0,
    };
    var captured: Captured = .{};
    const Handler = struct {
        fn cb(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            const state: *Captured = @ptrCast(@alignCast(userdata.?));
            state.calls += 1;
            state.last_userdata = userdata;
            state.last_len = len;
            const copy = if (len <= state.last_bytes.len) len else state.last_bytes.len;
            @memcpy(state.last_bytes[0..copy], ptr[0..copy]);
        }
    };
    const sink: OutputCallback = .{
        .callback = Handler.cb,
        .userdata = @ptrCast(&captured),
    };
    sink.invoke("hello");
    sink.invoke("ww");

    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 2), captured.calls);
    try std.testing.expectEqual(@as(usize, 2), captured.last_len);
    try std.testing.expectEqualSlices(u8, "ww", captured.last_bytes[0..2]);
    try std.testing.expectEqual(
        @as(?*anyopaque, @ptrCast(&captured)),
        captured.last_userdata,
    );
}

test "OutputCallback invoke passes empty payload through" {
    const Captured = struct {
        calls: usize = 0,
        last_len: usize = 1, // sentinel != 0 so we can detect overwrite
    };
    var captured: Captured = .{};
    const Handler = struct {
        fn cb(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            _ = ptr;
            const state: *Captured = @ptrCast(@alignCast(userdata.?));
            state.calls += 1;
            state.last_len = len;
        }
    };
    const sink: OutputCallback = .{
        .callback = Handler.cb,
        .userdata = @ptrCast(&captured),
    };
    sink.invoke("");

    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), captured.calls);
    try std.testing.expectEqual(@as(usize, 0), captured.last_len);
}

/// All size metrics for the terminal.
size: renderer.Size,

/// The full app configuration. This is only available during initialization.
/// The memory it points to is NOT stable after the init call so any values
/// in here must be copied.
full_config: *const Config,

/// The derived configuration for this termio implementation.
config: termio.Termio.DerivedConfig,

/// The backend for termio that implements where reads/writes are sourced.
backend: termio.Backend,

/// The mailbox for the terminal. This is how messages are delivered.
/// If you're using termio.Thread this MUST be "mailbox".
mailbox: termio.Mailbox,

/// The render state. The IO implementation can modify anything here. The
/// surface thread will setup the initial "terminal" pointer but the IO impl
/// is free to change that if that is useful (i.e. doing some sort of dual
/// terminal implementation.)
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for renderer messages.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for sending the surface messages.
surface_mailbox: apprt.surface.Mailbox,

/// Optional callback notified whenever raw PTY output is read.
output_callback: OutputCallback = .{},
