//! The search popup of a surface.
//!
//! It's an owned popup rather than a child of the surface, because the
//! window may be composited with per-pixel alpha and GDI can't paint that. The
//! popup holds a native EDIT control, and paints the match count and the
//! buttons itself. The core surface runs the search; we only send needles and
//! navigation, and show the totals it reports.
const SearchBar = @This();

const std = @import("std");
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");
const paint = @import("paint.zig");

const log = std.log.scoped(.win32);

const class = c.L("GhosttySearch");

/// Short needles match too much and make for expensive searches, so they're
/// sent after the user has paused. This is the same as the other apprts.
const debounce_timer = 1;
const debounce_ms = 300;
const debounce_min_len = 3;

// Sizes at 96 DPI.
const bar_width = 340;
const bar_height = 36;
const bar_margin = 8;
const pad = 8;
const button_size = 28;
const label_width = 56;
const edit_height = 20;
/// The edit shrinks before the bar does, but not below this.
const edit_min_width = 40;

const Button = enum { up, down, close };

/// The original procedure of the EDIT class, which we subclass.
var edit_proc: ?c.WNDPROC = null;

surface: *Surface,
hwnd: ?c.HWND = null,
edit: ?c.HWND = null,
font: ?c.HFONT = null,
dpi: u32 = 96,

/// For WM_CTLCOLOREDIT, which needs a brush that outlives the message.
brush: ?c.HGDIOBJ = null,
brush_color: c.COLORREF = 0,

/// Whether a search is in progress as far as the user is concerned. The popup
/// is only visible if this is set, but may be hidden even if it is, when the
/// surface isn't visible.
open: bool = false,
total: ?usize = null,
selected: ?usize = null,

/// The size we last laid out for, to know when to repaint.
size: c.POINT = .{},
hover: ?Button = null,
pressed: ?Button = null,
tracking_leave: bool = false,
timer_set: bool = false,

pub fn register(hinstance: c.HINSTANCE) !void {
    if (c.RegisterClassExW(&.{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class,
    }) == 0) return error.Win32Failed;
}

pub fn create(surface: *Surface) !*SearchBar {
    const alloc = surface.app.core_app.alloc;
    const self = try alloc.create(SearchBar);
    errdefer alloc.destroy(self);
    self.* = .{
        .surface = surface,
        .dpi = c.GetDpiForWindow(surface.window.hwnd),
    };

    const hwnd = c.CreateWindowExW(
        c.WS_EX_TOOLWINDOW,
        class,
        c.L(""),
        c.WS_POPUP | c.WS_CLIPCHILDREN,
        0,
        0,
        1,
        1,
        surface.window.hwnd,
        null,
        surface.app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    errdefer _ = c.DestroyWindow(hwnd);
    self.hwnd = hwnd;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    var corners: u32 = c.DWMWCP_ROUNDSMALL;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &corners, @sizeOf(u32));

    const edit = c.CreateWindowExW(
        0,
        c.L("EDIT"),
        c.L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.ES_AUTOHSCROLL,
        0,
        0,
        1,
        1,
        hwnd,
        null,
        surface.app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    self.edit = edit;
    self.font = paint.uiFont(10, self.dpi);
    if (self.font) |v| _ = c.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(v), 0);

    if (edit_proc == null) {
        edit_proc = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(edit, c.GWLP_WNDPROC))));
    }
    _ = c.SetWindowLongPtrW(edit, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editWndProc)));
    return self;
}

/// Called when the surface is destroyed. We can't call in to the core surface
/// anymore, and the popup may already be gone if the window was destroyed.
pub fn destroy(self: *SearchBar) void {
    self.stopTimer();
    if (self.hwnd) |v| {
        // This clears our handles through WM_NCDESTROY.
        _ = c.SetWindowLongPtrW(v, c.GWLP_USERDATA, 0);
        _ = c.DestroyWindow(v);
    }
    if (self.font) |v| _ = c.DeleteObject(v);
    if (self.brush) |v| _ = c.DeleteObject(v);
    self.surface.search = null;
    self.surface.app.core_app.alloc.destroy(self);
}

/// Open the bar, with a needle if there's one to start with.
pub fn show(self: *SearchBar, needle: [:0]const u8) void {
    const hwnd = self.hwnd orelse return;
    const edit = self.edit orelse return;
    const was_open = self.open;
    self.open = true;
    self.reposition();

    if (needle.len > 0) {
        // This sends the needle through EN_CHANGE.
        const alloc = self.surface.app.core_app.alloc;
        if (std.unicode.wtf8ToWtf16LeAllocZ(alloc, needle)) |wide| {
            defer alloc.free(wide);
            _ = c.SetWindowTextW(edit, wide);
        } else |err| log.warn("error setting search needle err={}", .{err});
    } else if (!was_open and c.GetWindowTextLengthW(edit) > 0) {
        // The text of the last search is still there, so search for it again.
        self.stopTimer();
        self.search();
    }

    // Focusing activates the popup, which we don't do to a window that
    // wasn't in use, such as when the surface is in a background tab.
    const active = c.GetActiveWindow();
    if (c.IsWindowVisible(hwnd) != 0 and
        (active == self.surface.window.hwnd or active == hwnd))
    {
        _ = c.SetFocus(edit);
        _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
    }
}

/// Close the bar. This doesn't end the search, which is done by whoever is
/// closing us, and may be called when it's already closed.
pub fn hide(self: *SearchBar) void {
    self.open = false;
    self.total = null;
    self.selected = null;
    self.stopTimer();
    const hwnd = self.hwnd orelse return;

    const focus = c.GetFocus();
    const had_focus = focus != null and (focus == hwnd or focus == self.edit);
    if (c.IsWindowVisible(hwnd) != 0) _ = c.ShowWindow(hwnd, c.SW_HIDE);

    // Whoever had the focus is hidden now, so give it back. Not to the
    // window's active surface, which may be a different split.
    if (had_focus) {
        _ = c.SetActiveWindow(self.surface.window.hwnd);
        if (self.surface.visible) _ = c.SetFocus(self.surface.hwnd);
    }
}

pub fn setTotal(self: *SearchBar, total: ?usize) void {
    if (self.total == total) return;
    self.total = total;
    self.invalidate();
}

/// Zero-based.
pub fn setSelected(self: *SearchBar, selected: ?usize) void {
    if (self.selected == selected) return;
    self.selected = selected;
    self.invalidate();
}

/// Called when the surface or window moved, or changed size or visibility.
pub fn reposition(self: *SearchBar) void {
    const hwnd = self.hwnd orelse return;
    const surface = self.surface;
    const window = surface.window;

    // The surface moves to another window with its tab.
    const owner: isize = @bitCast(@intFromPtr(window.hwnd));
    if (c.GetWindowLongPtrW(hwnd, c.GWLP_HWNDPARENT) != owner) {
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_HWNDPARENT, owner);
    }
    self.updateDpi(c.GetDpiForWindow(window.hwnd));

    var client: c.RECT = .{};
    _ = c.GetClientRect(surface.hwnd, &client);
    const margin = paint.scale(bar_margin, self.dpi);
    const width = @min(paint.scale(bar_width, self.dpi), client.right - margin * 2);
    const height = paint.scale(bar_height, self.dpi);
    const fits = width >= self.minWidth() and client.bottom >= height + margin * 2;

    if (!self.open or !fits or !surface.visible or window.minimized or
        c.IsIconic(window.hwnd) != 0 or
        c.IsWindowVisible(surface.hwnd) == 0)
    {
        if (c.IsWindowVisible(hwnd) != 0) _ = c.ShowWindow(hwnd, c.SW_HIDE);
        return;
    }

    var origin: c.POINT = .{ .x = client.right - margin - width, .y = margin };
    _ = c.ClientToScreen(surface.hwnd, &origin);
    _ = c.SetWindowPos(
        hwnd,
        null,
        origin.x,
        origin.y,
        width,
        height,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
    );
    self.layoutEdit(width, height);
}

//---------------------------------------------------------------
// Layout and painting

const Layout = struct {
    edit: c.RECT,
    label: c.RECT,
    up: c.RECT,
    down: c.RECT,
    close: c.RECT,

    fn button(self: Layout, which: Button) c.RECT {
        return switch (which) {
            .up => self.up,
            .down => self.down,
            .close => self.close,
        };
    }
};

fn minWidth(self: *const SearchBar) c_int {
    return paint.scale(pad * 2 + button_size * 3 + edit_min_width, self.dpi);
}

fn layout(self: *const SearchBar, width: c_int, height: c_int) Layout {
    const dpi = self.dpi;
    const side = paint.scale(pad, dpi);
    const button = paint.scale(button_size, dpi);
    const gap = paint.scale(4, dpi);
    const top = @divTrunc(height - button, 2);

    var close: c.RECT = .{ .left = width - gap - button, .top = top, .bottom = top + button };
    close.right = close.left + button;
    var down = close;
    down.left -= button;
    down.right -= button;
    var up = down;
    up.left -= button;
    up.right -= button;

    // The label gives way to the edit when there's no room for both.
    const room = @max(0, up.left - side - gap - paint.scale(edit_min_width, dpi));
    const label_w = @min(paint.scale(label_width, dpi), room);
    const label: c.RECT = .{
        .left = up.left - label_w,
        .top = 0,
        .right = up.left,
        .bottom = height,
    };

    const edit_h = paint.scale(edit_height, dpi);
    const edit_top = @divTrunc(height - edit_h, 2);
    return .{
        .edit = .{
            .left = side,
            .top = edit_top,
            .right = @max(side + 1, label.left - gap),
            .bottom = edit_top + edit_h,
        },
        .label = label,
        .up = up,
        .down = down,
        .close = close,
    };
}

fn layoutEdit(self: *SearchBar, width: c_int, height: c_int) void {
    const edit = self.edit orelse return;
    const l = self.layout(width, height);
    _ = c.SetWindowPos(
        edit,
        null,
        l.edit.left,
        l.edit.top,
        l.edit.right - l.edit.left,
        l.edit.bottom - l.edit.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
    if (self.size.x != width or self.size.y != height) {
        self.size = .{ .x = width, .y = height };
        self.invalidate();
    }
}

fn updateDpi(self: *SearchBar, dpi: u32) void {
    if (dpi == 0 or dpi == self.dpi) return;
    self.dpi = dpi;
    const old = self.font;
    self.font = paint.uiFont(10, dpi);
    if (self.edit) |v| {
        _ = c.SendMessageW(v, c.WM_SETFONT, if (self.font) |f| @intFromPtr(f) else 0, 1);
    }
    if (old) |v| _ = c.DeleteObject(v);
    self.invalidate();
}

fn invalidate(self: *SearchBar) void {
    const hwnd = self.hwnd orelse return;
    _ = c.InvalidateRect(hwnd, null, 0);
}

fn clientSize(hwnd: c.HWND) c.POINT {
    var rect: c.RECT = .{};
    _ = c.GetClientRect(hwnd, &rect);
    return .{ .x = rect.right, .y = rect.bottom };
}

fn onPaint(self: *SearchBar, hwnd: c.HWND) void {
    var ps: c.PAINTSTRUCT = .{};
    const dc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    const size = clientSize(hwnd);
    const full: c.RECT = .{ .right = size.x, .bottom = size.y };
    const buf = paint.Buffer.begin(dc, full) orelse return;
    defer buf.end();

    const palette: paint.Palette = .init(&self.surface.app.config);
    buf.fill(full, palette.bar);

    // The border.
    buf.fill(.{ .right = size.x, .bottom = 1 }, palette.divider);
    buf.fill(.{ .top = size.y - 1, .right = size.x, .bottom = size.y }, palette.divider);
    buf.fill(.{ .right = 1, .bottom = size.y }, palette.divider);
    buf.fill(.{ .left = size.x - 1, .right = size.x, .bottom = size.y }, palette.divider);

    const l = self.layout(size.x, size.y);
    var text: [48]u8 = undefined;
    const label: []const u8 = if (self.total) |total| label: {
        break :label (if (self.selected) |selected|
            std.fmt.bufPrint(&text, "{}/{}", .{ selected + 1, total })
        else
            std.fmt.bufPrint(&text, "{}", .{total})) catch "";
    } else "";
    buf.text(label, l.label, self.font, palette.dim, c.DT_RIGHT);

    inline for (.{
        .{ Button.up, "↑" },
        .{ Button.down, "↓" },
        .{ Button.close, "✕" },
    }) |entry| {
        const which, const glyph = entry;
        const rect = l.button(which);
        const pressed = self.pressed == which;
        const hovered = self.hover == which and (self.pressed == null or pressed);
        if (pressed) buf.fill(rect, palette.selected) else if (hovered) buf.fill(rect, palette.hover);
        buf.text(glyph, rect, self.font, if (hovered) palette.fg else palette.dim, c.DT_CENTER);
    }
}

fn hit(self: *const SearchBar, hwnd: c.HWND, x: c_int, y: c_int) ?Button {
    const size = clientSize(hwnd);
    const l = self.layout(size.x, size.y);
    inline for (comptime std.enums.values(Button)) |which| {
        const r = l.button(which);
        if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return which;
    }
    return null;
}

//---------------------------------------------------------------
// Searching

fn perform(self: *SearchBar, action: input.Binding.Action) void {
    if (!self.surface.ready) return;
    _ = self.surface.core_surface.performBindingAction(action) catch |err|
        log.warn("error performing search action err={}", .{err});
}

fn fire(self: *SearchBar, button: Button) void {
    // Up goes to the next match, as in the other apprts: the search starts
    // from the bottom of the screen and works its way up.
    switch (button) {
        .up => self.perform(.{ .navigate_search = .next }),
        .down => self.perform(.{ .navigate_search = .previous }),
        .close => self.perform(.end_search),
    }
}

/// The text of the edit, which the caller owns.
fn readNeedle(self: *const SearchBar) ![]u8 {
    const alloc = self.surface.app.core_app.alloc;
    const edit = self.edit orelse return error.Win32Failed;
    const len: usize = @intCast(@max(0, c.GetWindowTextLengthW(edit)));
    const wide = try alloc.alloc(u16, len + 1);
    defer alloc.free(wide);
    const n: usize = @intCast(@max(0, c.GetWindowTextW(edit, wide.ptr, @intCast(wide.len))));
    return try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..@min(n, len)]);
}

/// Send the text of the edit to the core surface. Empty text stops the search.
fn search(self: *SearchBar) void {
    const text = self.readNeedle() catch |err| {
        log.warn("error reading search needle err={}", .{err});
        return;
    };
    defer self.surface.app.core_app.alloc.free(text);
    self.perform(.{ .search = text });
}

fn onChange(self: *SearchBar, hwnd: c.HWND) void {
    const text = self.readNeedle() catch |err| {
        log.warn("error reading search needle err={}", .{err});
        return;
    };
    defer self.surface.app.core_app.alloc.free(text);

    const count = std.unicode.utf8CountCodepoints(text) catch text.len;
    if (count == 0 or count >= debounce_min_len) {
        self.stopTimer();
        self.perform(.{ .search = text });
    } else {
        // This restarts the timer if it's running.
        self.timer_set = c.SetTimer(hwnd, debounce_timer, debounce_ms, null) != 0;
    }
}

fn stopTimer(self: *SearchBar) void {
    if (!self.timer_set) return;
    self.timer_set = false;
    if (self.hwnd) |v| _ = c.KillTimer(v, debounce_timer);
}

//---------------------------------------------------------------
// The popup

fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *SearchBar = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.message(hwnd, msg, wparam, lparam) orelse
        c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Returns null for default processing.
fn message(self: *SearchBar, hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    const bits: usize = @bitCast(lparam);
    const x: c_int = @as(i16, @bitCast(@as(u16, @truncate(bits))));
    const y: c_int = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));

    switch (msg) {
        c.WM_NCDESTROY => {
            self.stopTimer();
            self.hwnd = null;
            self.edit = null;
            return null;
        },

        c.WM_ERASEBKGND => return 1,
        c.WM_PAINT => self.onPaint(hwnd),

        c.WM_COMMAND => {
            const code: u16 = @truncate(wparam >> 16);
            const from: usize = bits;
            if (code == c.EN_CHANGE and self.edit != null and from == @intFromPtr(self.edit.?)) {
                self.onChange(hwnd);
            }
            return 0;
        },

        c.WM_TIMER => {
            if (wparam != debounce_timer) return null;
            self.stopTimer();
            self.search();
            return 0;
        },

        c.WM_CTLCOLOREDIT => {
            const palette: paint.Palette = .init(&self.surface.app.config);
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, palette.fg.ref());
            _ = c.SetBkColor(dc, palette.bar.ref());
            if (self.brush == null or self.brush_color != palette.bar.ref()) {
                if (self.brush) |v| _ = c.DeleteObject(v);
                self.brush_color = palette.bar.ref();
                self.brush = c.CreateSolidBrush(self.brush_color);
            }
            const v = self.brush orelse return null;
            return @bitCast(@intFromPtr(v));
        },

        // Clicking a button shouldn't take the keyboard from the terminal.
        c.WM_MOUSEACTIVATE => {
            var pos: c.POINT = .{};
            _ = c.GetCursorPos(&pos);
            _ = c.ScreenToClient(hwnd, &pos);
            if (self.hit(hwnd, pos.x, pos.y) != null) return c.MA_NOACTIVATE;
            return null;
        },

        c.WM_SETCURSOR => {
            if (lparam & 0xFFFF != c.HTCLIENT or self.hover == null) return null;
            _ = c.SetCursor(c.LoadCursorW(null, c.IDC_HAND));
            return 1;
        },

        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var track: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                self.tracking_leave = c.TrackMouseEvent(&track) != 0;
            }
            const hover = self.hit(hwnd, x, y);
            if (hover != self.hover) {
                self.hover = hover;
                self.invalidate();
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            if (self.hover != null) {
                self.hover = null;
                self.invalidate();
            }
            return 0;
        },

        c.WM_LBUTTONDOWN => {
            self.pressed = self.hit(hwnd, x, y);
            if (self.pressed != null) {
                _ = c.SetCapture(hwnd);
                self.invalidate();
            }
            return 0;
        },

        c.WM_LBUTTONUP => {
            const pressed = self.pressed orelse return 0;
            self.pressed = null;
            _ = c.ReleaseCapture();
            self.invalidate();
            if (self.hit(hwnd, x, y) == pressed) self.fire(pressed);
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            if (self.pressed != null) {
                self.pressed = null;
                self.invalidate();
            }
            return 0;
        },

        else => return null,
    }
    return 0;
}

//---------------------------------------------------------------
// The edit

fn editWndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const original = edit_proc.?;
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.CallWindowProcW(original, hwnd, msg, wparam, lparam);
    const self: *SearchBar = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.editMessage(hwnd, msg, wparam, lparam) orelse
        c.CallWindowProcW(original, hwnd, msg, wparam, lparam);
}

/// Returns null for the EDIT's own processing.
fn editMessage(self: *SearchBar, hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    switch (msg) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            const ctrl = c.GetKeyState(c.VK_CONTROL) < 0;
            const shift = c.GetKeyState(c.VK_SHIFT) < 0;
            // We handle these, so there's no character to follow.
            switch (wparam) {
                c.VK_RETURN => {
                    self.fire(if (shift) .down else .up);
                    return 0;
                },
                c.VK_UP => {
                    self.fire(.up);
                    return 0;
                },
                c.VK_DOWN => {
                    self.fire(.down);
                    return 0;
                },
                c.VK_ESCAPE => {
                    self.fire(.close);
                    return 0;
                },
                'A' => if (ctrl) {
                    _ = c.SendMessageW(hwnd, c.EM_SETSEL, 0, -1);
                    return 0;
                },
                c.VK_BACK => if (ctrl) {
                    deleteWord(hwnd);
                    return 0;
                },
                else => {},
            }

            // The message loop leaves it to us to make characters of keys,
            // except the ones it already translated for the IME.
            switch (wparam) {
                c.VK_PROCESSKEY, c.VK_PACKET => {},
                else => {
                    const key: c.MSG = .{
                        .hwnd = hwnd,
                        .message = msg,
                        .wParam = wparam,
                        .lParam = lparam,
                        .time = 0,
                        .pt = .{},
                    };
                    _ = c.TranslateMessage(&key);
                },
            }
        },

        c.WM_CHAR => switch (wparam) {
            // Enter, escape, tab and ctrl+backspace don't belong in a needle,
            // and the EDIT would beep.
            '\r', '\n', 0x1B, '\t', 0x7F => return 0,
            else => {},
        },

        // Alt+key would be a menu mnemonic. AltGr is also this, on some
        // layouts, and does produce text.
        c.WM_SYSCHAR => {
            if (c.GetKeyState(c.VK_CONTROL) < 0) {
                return c.CallWindowProcW(edit_proc.?, hwnd, c.WM_CHAR, wparam, lparam);
            }
            return 0;
        },

        else => {},
    }
    return null;
}

/// Delete from the caret back to the start of the word, or the selection.
fn deleteWord(edit: c.HWND) void {
    var start: u32 = 0;
    var end: u32 = 0;
    _ = c.SendMessageW(edit, c.EM_GETSEL, @intFromPtr(&start), @bitCast(@intFromPtr(&end)));
    if (start == end) {
        var buf: [1024]u16 = undefined;
        const len: usize = @intCast(@max(0, c.GetWindowTextW(edit, &buf, buf.len)));
        var i: usize = @min(end, len);
        while (i > 0 and buf[i - 1] == ' ') i -= 1;
        while (i > 0 and buf[i - 1] != ' ') i -= 1;
        _ = c.SendMessageW(edit, c.EM_SETSEL, i, @intCast(@min(end, len)));
    }
    _ = c.SendMessageW(edit, c.EM_REPLACESEL, 1, @bitCast(@intFromPtr(c.L(""))));
}
