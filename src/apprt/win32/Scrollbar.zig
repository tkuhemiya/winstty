//! The scrollbar of a surface, a sibling window to its right.
//!
//! This isn't a standard scrollbar because those can't be themed with
//! documented APIs, and aren't painted with an alpha channel.
const Scrollbar = @This();

const std = @import("std");
const terminal = @import("../../terminal/main.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");
const paint = @import("paint.zig");

const log = std.log.scoped(.win32);

const class = c.L("GhosttyScrollbar");

// 96 DPI lengths.
const bar_width = 12;
const thumb_min = 28;
const thumb_margin = 3;

surface: *Surface,
hwnd: c.HWND,
state: terminal.Scrollbar = .zero,
hover: bool = false,

/// Distance from the top of the thumb to the pointer, while dragging it.
drag: ?c_int = null,

pub fn register(hinstance: c.HINSTANCE) !void {
    if (c.RegisterClassExW(&.{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .lpszClassName = class,
    }) == 0) return error.Win32Failed;
}

pub fn create(surface: *Surface) !*Scrollbar {
    const alloc = surface.app.core_app.alloc;
    const self = try alloc.create(Scrollbar);
    errdefer alloc.destroy(self);
    const hwnd = c.CreateWindowExW(
        0,
        class,
        class,
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        0,
        0,
        1,
        1,
        surface.window.hwnd,
        null,
        surface.app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    self.* = .{ .surface = surface, .hwnd = hwnd };
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    return self;
}

pub fn destroy(self: *Scrollbar) void {
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    _ = c.DestroyWindow(self.hwnd);
    self.surface.app.core_app.alloc.destroy(self);
}

pub fn width(dpi: u32) c_int {
    return paint.scale(bar_width, dpi);
}

pub fn set(self: *Scrollbar, state: terminal.Scrollbar) void {
    if (std.meta.eql(self.state, state)) return;
    self.state = state;
    self.invalidate();
}

pub fn invalidate(self: *Scrollbar) void {
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

fn maxOffset(self: *const Scrollbar) usize {
    return self.state.total -| self.state.len;
}

const Thumb = struct { top: c_int, height: c_int, travel: c_int };

/// Null if there's nothing to scroll.
fn thumb(self: *const Scrollbar) ?Thumb {
    if (self.maxOffset() == 0) return null;
    var rect: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &rect);
    if (rect.bottom <= 0) return null;

    const track: f64 = @floatFromInt(rect.bottom);
    const total: f64 = @floatFromInt(self.state.total);
    const len: f64 = @floatFromInt(self.state.len);
    const min = paint.scale(thumb_min, c.GetDpiForWindow(self.hwnd));
    const height = @min(rect.bottom, @max(min, @as(c_int, @intFromFloat(track * len / total))));
    const travel = rect.bottom - height;
    const offset: f64 = @floatFromInt(@min(self.state.offset, self.maxOffset()));
    const max: f64 = @floatFromInt(self.maxOffset());
    return .{
        .top = @intFromFloat(@round(@as(f64, @floatFromInt(travel)) * offset / max)),
        .height = height,
        .travel = travel,
    };
}

fn onPaint(self: *Scrollbar) void {
    var ps: c.PAINTSTRUCT = .{};
    const dc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);
    var rect: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &rect);
    const buf = paint.Buffer.begin(dc, rect) orelse return;
    defer buf.end();

    const palette: paint.Palette = .init(&self.surface.app.config);
    buf.fill(rect, palette.bg);
    const t = self.thumb() orelse return;
    const margin = paint.scale(thumb_margin, c.GetDpiForWindow(self.hwnd));
    const strength: u8 = if (self.drag != null) 130 else if (self.hover) 100 else 60;
    buf.fill(.{
        .left = margin,
        .top = t.top + @min(margin, @divTrunc(t.height, 4)),
        .right = rect.right - margin,
        .bottom = t.top + t.height - @min(margin, @divTrunc(t.height, 4)),
    }, palette.bg.mix(palette.fg, strength));
}

fn scrollTo(self: *Scrollbar, row: usize) !void {
    const target = @min(row, self.maxOffset());
    if (target == self.state.offset) return;

    // The terminal reports back too, but only once it has rendered, and the
    // thumb should stick to the pointer.
    self.state.offset = target;
    self.invalidate();
    _ = try self.surface.core_surface.performBindingAction(.{ .scroll_to_row = target });
}

fn onDrag(self: *Scrollbar, grab: c_int, y: c_int) !void {
    const t = self.thumb() orelse return;
    if (t.travel <= 0) return;
    const top: f64 = @floatFromInt(std.math.clamp(y - grab, 0, t.travel));
    const max: f64 = @floatFromInt(self.maxOffset());
    try self.scrollTo(@intFromFloat(@round(top / @as(f64, @floatFromInt(t.travel)) * max)));
}

fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Scrollbar = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.message(msg, wparam, lparam) catch |err| err: {
        log.warn("error handling scrollbar message msg=0x{x} err={}", .{ msg, err });
        break :err 0;
    } orelse c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn message(self: *Scrollbar, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) !?c.LRESULT {
    const y: c_int = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));
    switch (msg) {
        c.WM_PAINT => self.onPaint(),
        c.WM_ERASEBKGND => return 1,
        c.WM_SIZE => self.invalidate(),
        c.WM_SETCURSOR => {
            _ = c.SetCursor(c.LoadCursorW(null, c.IDC_ARROW));
            return 1;
        },

        c.WM_MOUSEMOVE => {
            if (!self.hover) {
                var track: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
                self.hover = c.TrackMouseEvent(&track) != 0;
                self.invalidate();
            }
            if (self.drag) |grab| try self.onDrag(grab, y);
        },
        c.WM_MOUSELEAVE => {
            self.hover = false;
            self.invalidate();
        },

        c.WM_LBUTTONDOWN => if (self.thumb()) |t| {
            if (y < t.top) {
                try self.scrollTo(self.state.offset -| self.state.len);
            } else if (y >= t.top + t.height) {
                try self.scrollTo(self.state.offset + self.state.len);
            } else {
                self.drag = y - t.top;
                _ = c.SetCapture(self.hwnd);
                self.invalidate();
            }
        },
        c.WM_LBUTTONUP => if (self.drag != null) {
            _ = c.ReleaseCapture();
        },
        c.WM_CAPTURECHANGED => {
            self.drag = null;
            self.invalidate();
        },

        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => return c.SendMessageW(
            self.surface.hwnd,
            msg,
            wparam,
            lparam,
        ),

        else => return null,
    }
    return 0;
}
