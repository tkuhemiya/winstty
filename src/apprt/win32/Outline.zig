//! The outline of the focused pane, on its way to another pane.
//!
//! On its way it's over terminals, which the window can't draw on. So it's a
//! window of its own, which is only shown while it moves.
const Outline = @This();

const std = @import("std");
const c = @import("c.zig");
const paint = @import("paint.zig");

const class = c.L("GhosttyOutline");

hwnd: c.HWND,

pub fn register(hinstance: c.HINSTANCE) !void {
    if (c.RegisterClassExW(&.{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .lpszClassName = class,
    }) == 0) return error.Win32Failed;
}

/// It's destroyed along with its owner.
pub fn create(owner: c.HWND, hinstance: c.HINSTANCE) !Outline {
    return .{ .hwnd = c.CreateWindowExW(
        c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE | c.WS_EX_TOOLWINDOW,
        class,
        c.L(""),
        c.WS_POPUP,
        0,
        0,
        1,
        1,
        owner,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Failed };
}

/// Show around a rectangle, in the coordinates of the owner.
pub fn show(
    self: Outline,
    owner: c.HWND,
    r: paint.Rect,
    radius: f32,
    thickness: f32,
    color: paint.Rgb,
) void {
    const outer = r.inset(-thickness);
    const left = @floor(outer.x);
    const top = @floor(outer.y);
    const rect: c.RECT = .{
        .right = @intFromFloat(@ceil(outer.x + outer.w) - left),
        .bottom = @intFromFloat(@ceil(outer.y + outer.h) - top),
    };
    const screen = c.GetDC(null) orelse return;
    defer _ = c.ReleaseDC(null, screen);
    var buf = paint.Buffer.begin(screen, rect) orelse return;
    defer buf.discard();

    // The pixels start out as zeroes.
    buf.has_alpha = true;
    buf.outline(
        .{ .x = outer.x - left, .y = outer.y - top, .w = outer.w, .h = outer.h },
        radius + thickness,
        thickness,
        color,
    );
    _ = c.GdiFlush();

    var position: c.POINT = .{ .x = @intFromFloat(left), .y = @intFromFloat(top) };
    _ = c.ClientToScreen(owner, &position);
    _ = c.UpdateLayeredWindow(
        self.hwnd,
        null,
        &position,
        &.{ .cx = rect.right, .cy = rect.bottom },
        buf.dc,
        &.{},
        0,
        &.{},
        c.ULW_ALPHA,
    );
    if (c.IsWindowVisible(self.hwnd) == 0) _ = c.ShowWindow(self.hwnd, c.SW_SHOWNA);
}

pub fn hide(self: Outline) void {
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
}

fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    if (msg == c.WM_NCHITTEST) return c.HTTRANSPARENT;
    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
