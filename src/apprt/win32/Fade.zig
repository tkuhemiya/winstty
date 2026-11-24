//! A popup that fades in and out.
const Fade = @This();

const std = @import("std");
const Ticker = @import("Ticker.zig");
const c = @import("c.zig");

const step_ms = 10;
const in_ms = 110;
const out_ms = 80;

/// The timer of the popup that's for this.
timer: usize,
state: State = .none,
last: i64 = 0,
/// From 0 to 1.
amount: f32 = 1,

const State = enum { none, in, out };

/// Called before the popup is shown. It's shown at once if not animated.
pub fn fadeIn(self: *Fade, hwnd: c.HWND, animated: bool) void {
    if (!animated) return self.finish(hwnd);
    if (self.state == .none) self.amount = 0;
    self.begin(hwnd, .in);
}

/// Hide the popup, when it has faded.
pub fn fadeOut(self: *Fade, hwnd: c.HWND, animated: bool) void {
    if (!animated or c.IsWindowVisible(hwnd) == 0) {
        _ = c.ShowWindow(hwnd, c.SW_HIDE);
        return self.finish(hwnd);
    }
    if (self.state == .none) self.amount = 1;
    self.begin(hwnd, .out);
}

/// Whether the popup is only shown because it fades.
pub fn leaving(self: *const Fade) bool {
    return self.state == .out;
}

fn begin(self: *Fade, hwnd: c.HWND, state: State) void {
    self.state = state;
    self.last = Ticker.now();
    setLayered(hwnd, true);
    self.apply(hwnd);
    if (c.SetTimer(hwnd, self.timer, step_ms, null) == 0) self.end(hwnd);
}

/// Called for the timer. Returns whether it's done.
pub fn onTimer(self: *Fade, hwnd: c.HWND) bool {
    const now = Ticker.now();
    const elapsed = Ticker.milliseconds(self.last, now);
    self.last = now;
    switch (self.state) {
        .none => {},
        .in => self.amount = @min(1, self.amount + elapsed / in_ms),
        .out => self.amount = @max(0, self.amount - elapsed / out_ms),
    }
    const done = switch (self.state) {
        .none => true,
        .in => self.amount >= 1,
        .out => self.amount <= 0,
    };
    if (done) self.end(hwnd) else self.apply(hwnd);
    return done;
}

fn end(self: *Fade, hwnd: c.HWND) void {
    if (self.state == .out) _ = c.ShowWindow(hwnd, c.SW_HIDE);
    self.finish(hwnd);
}

/// Stop, as if it had never started.
fn finish(self: *Fade, hwnd: c.HWND) void {
    if (self.state == .none) return;
    self.state = .none;
    self.amount = 1;
    _ = c.KillTimer(hwnd, self.timer);
    setLayered(hwnd, false);
}

fn apply(self: *const Fade, hwnd: c.HWND) void {
    // Fast at first, with no abrupt end.
    const eased = self.amount * (2 - self.amount);
    _ = c.SetLayeredWindowAttributes(hwnd, 0, @intFromFloat(eased * 255), c.LWA_ALPHA);
}

fn setLayered(hwnd: c.HWND, layered: bool) void {
    const style: u32 = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE))));
    const want = if (layered) style | c.WS_EX_LAYERED else style & ~c.WS_EX_LAYERED;
    if (want == style) return;
    _ = c.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, want);
    if (!layered) _ = c.RedrawWindow(hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ALLCHILDREN);
}
