//! Calls for a frame of animation, each time the screen is updated.
//!
//! A timer message isn't delivered while there's anything else to handle, and a
//! terminal may have a lot to handle.
const Ticker = @This();

const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

hwnd: c.HWND,
message: u32,

/// Signaled while frames are wanted.
running: c.HANDLE,
quit: std.atomic.Value(bool) = .init(false),
/// Whether the message is still waiting to be handled.
pending: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,

pub fn init(hwnd: c.HWND, message: u32) !Ticker {
    return .{
        .hwnd = hwnd,
        .message = message,
        .running = c.CreateEventW(null, 1, 0, null) orelse return error.Win32Failed,
    };
}

pub fn deinit(self: *Ticker) void {
    self.quit.store(true, .release);
    _ = c.SetEvent(self.running);
    if (self.thread) |v| v.join();
    _ = c.CloseHandle(self.running);
}

/// Returns whether there will be frames. Must not move after this.
pub fn start(self: *Ticker) bool {
    if (self.thread == null) self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
        log.warn("error starting animation thread err={}", .{err});
        return false;
    };
    _ = c.SetEvent(self.running);
    return true;
}

pub fn stop(self: *Ticker) void {
    _ = c.ResetEvent(self.running);
}

/// Must be called when the message is handled.
pub fn handled(self: *Ticker) void {
    self.pending.store(false, .release);
}

fn run(self: *Ticker) void {
    const infinite = 0xFFFFFFFF;
    while (true) {
        _ = c.WaitForSingleObject(self.running, infinite);
        if (self.quit.load(.acquire)) return;
        const before = now();
        const result = c.DwmFlush();

        // It doesn't wait if there's nothing to wait for.
        if (result != 0 or milliseconds(before, now()) < 2) c.Sleep(8);
        if (self.quit.load(.acquire)) return;
        if (self.pending.swap(true, .acq_rel)) continue;
        if (c.PostMessageW(self.hwnd, self.message, 0, 0) == 0) self.handled();
    }
}

pub fn now() i64 {
    var v: i64 = 0;
    _ = c.QueryPerformanceCounter(&v);
    return v;
}

pub fn milliseconds(from: i64, to: i64) f32 {
    var frequency: i64 = 1;
    _ = c.QueryPerformanceFrequency(&frequency);
    return @floatCast(@as(f64, @floatFromInt(to - from)) * 1000 / @as(f64, @floatFromInt(frequency)));
}
