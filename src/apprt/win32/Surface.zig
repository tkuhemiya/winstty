//! A terminal surface. Each surface is its own top-level window.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

/// Posted by `close`. wParam is whether to confirm.
const WM_CLOSE_SURFACE = c.WM_APP + 1;

app: *App,
hwnd: c.HWND,
core_surface: CoreSurface = undefined,

/// False until the core surface is initialized.
ready: bool = false,

title: ?[:0]const u8 = null,
size_limit: apprt.action.SizeLimit = .{
    .min_width = 0,
    .min_height = 0,
    .max_width = 0,
    .max_height = 0,
},

cursor: ?c.HCURSOR,
cursor_visible: bool = true,
tracking_leave: bool = false,
buttons_down: u8 = 0,

/// Placement to restore when leaving fullscreen. Non-null in fullscreen.
windowed: ?struct { placement: c.WINDOWPLACEMENT, style: isize } = null,

/// Non-zero while a message box is open. It pumps messages from inside a core
/// callback, so the surface must not be destroyed until it returns.
modal: u32 = 0,
close_pending: bool = false,

/// True if a dead key is waiting for its base character.
dead_key: bool = false,

/// High half of a surrogate pair delivered by WM_CHAR.
high_surrogate: u16 = 0,

pub fn create(app: *App, context: apprt.surface.NewSurfaceContext) !*Surface {
    const alloc = app.core_app.alloc;

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);

    // Sized in 96 DPI units until we know which monitor we landed on.
    const dpi: c_int = @intCast(c.GetDpiForSystem());
    const hwnd = c.CreateWindowExW(
        0,
        App.window_class,
        c.L("Ghostty"),
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        @divTrunc(960 * dpi, 96),
        @divTrunc(600 * dpi, 96),
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    errdefer _ = c.DestroyWindow(hwnd);

    self.* = .{
        .app = app,
        .hwnd = hwnd,
        .cursor = c.LoadCursorW(null, c.IDC_IBEAM),
    };
    self.syncTheme();

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    self.ready = true;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    _ = c.ShowWindow(hwnd, if (config.maximize) c.SW_MAXIMIZE else c.SW_SHOW);
    return self;
}

/// Called from WM_DESTROY, while the window and so its DC still exist.
pub fn deinit(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    self.ready = false;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    self.app.core_app.deleteSurface(self);
    self.core_surface.deinit();
    if (self.title) |v| alloc.free(v);
    alloc.destroy(self);
}

//---------------------------------------------------------------
// Apprt surface API

pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

pub fn rtApp(self: *const Surface) *App {
    return self.app;
}

/// Deferred because this may be called from within a core callback.
pub fn close(self: *const Surface, process_active: bool) void {
    _ = c.PostMessageW(self.hwnd, WM_CLOSE_SURFACE, @intFromBool(process_active), 0);
}

pub fn getTitle(self: *Surface) ?[:0]const u8 {
    return self.title;
}

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(self.hwnd))) / 96;
    return .{ .x = scale, .y = scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    var rect: c.RECT = .{};
    if (c.GetClientRect(self.hwnd, &rect) == 0) return error.Win32Failed;
    return .{ .width = @intCast(rect.right), .height = @intCast(rect.bottom) };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    var point: c.POINT = .{};
    if (c.GetCursorPos(&point) == 0) return error.Win32Failed;
    _ = c.ScreenToClient(self.hwnd, &point);
    return .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
}

pub fn renderDeviceOptions(_: *Surface) !renderer.Device.Options {
    return .{};
}

pub fn redrawInspector(_: *Surface) void {}

pub fn defaultTermioEnv(_: *Surface) !std.process.Environ.Map {
    return try global.environMap();
}

/// Windows has a single clipboard, with no primary selection.
pub fn supportsClipboard(_: *const Surface, clipboard: apprt.Clipboard) bool {
    return clipboard == .standard;
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !apprt.ClipboardReadResult {
    if (clipboard != .standard) return .unavailable;

    const alloc = self.app.core_app.alloc;
    const text = try readClipboard(alloc, self.hwnd) orelse return .unavailable;
    defer alloc.free(text);

    const contents = [_]terminal.clipboard.Content{.{
        .mime = "text/plain",
        .data = text,
    }};
    const available = [_][]const u8{"text/plain"};

    self.core_surface.completeClipboardRequest(req, .{
        .contents = &contents,
        .available = &available,
    }) catch |err| switch (err) {
        error.UnsafePaste, error.UnauthorizedPaste => {
            const allowed = self.confirm(
                c.L("Allow clipboard access?"),
                if (err == error.UnsafePaste)
                    c.L("The text being pasted contains line breaks and may run commands.")
                else
                    c.L("An application is trying to access the clipboard."),
            );
            if (allowed) try self.core_surface.completeClipboardRequest(req, .{
                .contents = &contents,
                .available = &available,
                .confirmed = true,
            }) else self.core_surface.denyClipboardRequest(req);
        },
        else => return err,
    };
    return .started;
}

pub fn setClipboard(
    self: *Surface,
    clipboard: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm_write: bool,
) !void {
    if (clipboard != .standard) return;
    const text = for (contents) |v| {
        if (terminal.clipboard.isTextMime(v.mime)) break v.data;
    } else return;

    if (confirm_write and !self.confirm(
        c.L("Allow clipboard access?"),
        c.L("An application is trying to write to the clipboard."),
    )) return;

    try writeClipboard(self.app.core_app.alloc, self.hwnd, text);
}

//---------------------------------------------------------------
// Actions

pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const title_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, title);
    defer alloc.free(title_w);
    const copy = try alloc.dupeSentinel(u8, title, 0);
    if (self.title) |v| alloc.free(v);
    self.title = copy;
    _ = c.SetWindowTextW(self.hwnd, title_w);
}

pub fn setClientSize(self: *Surface, width: u32, height: u32) void {
    if (self.windowed != null or c.IsZoomed(self.hwnd) != 0) return;
    var rect: c.RECT = .{
        .right = std.math.lossyCast(c_int, width),
        .bottom = std.math.lossyCast(c_int, height),
    };
    self.adjustRect(&rect);
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// Grow a client rect to include the window frame.
fn adjustRect(self: *Surface, rect: *c.RECT) void {
    const style: u32 = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    _ = c.AdjustWindowRectExForDpi(rect, style, 0, 0, c.GetDpiForWindow(self.hwnd));
}

pub fn toggleMaximize(self: *Surface) void {
    if (self.windowed != null) return;
    _ = c.ShowWindow(self.hwnd, if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

/// Borderless fullscreen on the current monitor.
pub fn toggleFullscreen(self: *Surface) void {
    if (self.windowed) |saved| {
        self.windowed = null;
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, saved.style);
        _ = c.SetWindowPlacement(self.hwnd, &saved.placement);
        _ = c.SetWindowPos(
            self.hwnd,
            null,
            0,
            0,
            0,
            0,
            c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_FRAMECHANGED,
        );
        return;
    }

    var info: c.MONITORINFO = .{};
    const monitor = c.MonitorFromWindow(self.hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return;
    if (c.GetMonitorInfoW(monitor, &info) == 0) return;
    var placement: c.WINDOWPLACEMENT = .{};
    if (c.GetWindowPlacement(self.hwnd, &placement) == 0) return;
    const style = c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE);

    self.windowed = .{ .placement = placement, .style = style };
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWL_STYLE, style & ~@as(isize, c.WS_OVERLAPPEDWINDOW));
    const r = info.rcMonitor;
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top,
        c.SWP_NOZORDER | c.SWP_FRAMECHANGED,
    );
}

pub fn present(self: *Surface) void {
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(self.hwnd);
}

pub fn setMouseVisible(self: *Surface, visible: bool) void {
    self.cursor_visible = visible;
    self.applyCursor();
}

pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
    self.cursor = c.LoadCursorW(null, switch (shape) {
        .text, .vertical_text => c.IDC_IBEAM,
        .pointer, .grab, .grabbing => c.IDC_HAND,
        .help => c.IDC_HELP,
        .progress => c.IDC_APPSTARTING,
        .wait => c.IDC_WAIT,
        .crosshair, .cell => c.IDC_CROSS,
        .no_drop, .not_allowed => c.IDC_NO,
        .move, .all_scroll => c.IDC_SIZEALL,
        .col_resize, .e_resize, .w_resize, .ew_resize => c.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => c.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => c.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => c.IDC_SIZENWSE,
        else => c.IDC_ARROW,
    });
    self.applyCursor();
}

/// Update the pointer now if it's over our window. Otherwise it's updated by
/// the next WM_SETCURSOR.
fn applyCursor(self: *Surface) void {
    if (self.tracking_leave) _ = c.SetCursor(if (self.cursor_visible) self.cursor else null);
}

/// Match the title bar to the system theme.
fn syncTheme(self: *Surface) void {
    const dark: c.BOOL = @intFromBool(App.systemColorScheme() == .dark);
    _ = c.DwmSetWindowAttribute(
        self.hwnd,
        c.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(c.BOOL),
    );
}

fn confirm(self: *Surface, title: [*:0]const u16, text: [*:0]const u16) bool {
    self.modal += 1;
    const result = c.MessageBoxW(self.hwnd, text, title, c.MB_OKCANCEL | c.MB_ICONWARNING);
    self.modal -= 1;
    if (self.modal == 0 and self.close_pending) self.close(false);
    return result == c.IDOK;
}

//---------------------------------------------------------------
// Window procedure

pub fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Surface = @ptrFromInt(@as(usize, @bitCast(ptr)));
    if (!self.ready) return c.DefWindowProcW(hwnd, msg, wparam, lparam);

    return self.message(msg, wparam, lparam) catch |err| err: {
        log.warn("error handling message msg=0x{x} err={}", .{ msg, err });
        break :err 0;
    } orelse c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Returns null for default processing. Once a core callback has returned,
/// self is still valid: destruction only happens via a posted message.
fn message(self: *Surface, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) !?c.LRESULT {
    const surface = &self.core_surface;
    switch (msg) {
        c.WM_CLOSE => surface.close(),

        WM_CLOSE_SURFACE => {
            // A message box is on the stack above a core callback.
            if (self.modal > 0) {
                self.close_pending = true;
                return 0;
            }
            if (wparam != 0 and !self.confirm(
                c.L("Close terminal?"),
                c.L("The running process in this terminal will be terminated."),
            )) return 0;
            _ = c.DestroyWindow(self.hwnd);
        },

        c.WM_DESTROY => self.deinit(),

        c.WM_PAINT => {
            _ = c.ValidateRect(self.hwnd, null);
            try surface.refreshCallback();
        },

        // We paint every pixel, erasing only causes flicker.
        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => {
            const minimized = wparam == c.SIZE_MINIMIZED;
            try surface.occlusionCallback(!minimized);
            if (!minimized) {
                const size = try self.getSize();
                if (size.width > 0 and size.height > 0) try surface.sizeCallback(size);
            }
        },

        c.WM_GETMINMAXINFO => {
            const info: *c.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (self.windowed != null) return null;
            const limit = self.size_limit;
            if (limit.min_width > 0 and limit.min_height > 0) {
                var rect: c.RECT = .{
                    .right = std.math.lossyCast(c_int, limit.min_width),
                    .bottom = std.math.lossyCast(c_int, limit.min_height),
                };
                self.adjustRect(&rect);
                info.ptMinTrackSize = .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
            }
        },

        c.WM_DPICHANGED => {
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            try surface.contentScaleCallback(try self.getContentScale());
            _ = c.SetWindowPos(
                self.hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
        },

        c.WM_SETTINGCHANGE => {
            self.syncTheme();
            const scheme = App.systemColorScheme();
            try self.app.core_app.colorSchemeEvent(self.app, scheme);
            try surface.colorSchemeCallback(scheme);
        },

        c.WM_ACTIVATEAPP => self.app.core_app.focusEvent(wparam != 0),
        c.WM_SETFOCUS => try surface.focusCallback(true),
        c.WM_KILLFOCUS => try surface.focusCallback(false),

        c.WM_SETCURSOR => {
            if (lparam & 0xFFFF != c.HTCLIENT) return null;
            _ = c.SetCursor(if (self.cursor_visible) self.cursor else null);
            return 1;
        },

        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var track: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
                self.tracking_leave = c.TrackMouseEvent(&track) != 0;
            }
            try surface.cursorPosCallback(mousePos(lparam), currentMods());
        },
        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            try surface.cursorPosCallback(.{ .x = -1, .y = -1 }, currentMods());
        },

        c.WM_LBUTTONDOWN => try self.button(.left, .press, lparam),
        c.WM_LBUTTONUP => try self.button(.left, .release, lparam),
        c.WM_RBUTTONDOWN => try self.button(.right, .press, lparam),
        c.WM_RBUTTONUP => try self.button(.right, .release, lparam),
        c.WM_MBUTTONDOWN => try self.button(.middle, .press, lparam),
        c.WM_MBUTTONUP => try self.button(.middle, .release, lparam),
        c.WM_XBUTTONDOWN, c.WM_XBUTTONUP => {
            // Back and forward. Terminals number these 8 and 9 because 4-7
            // are the scroll wheel.
            try self.button(
                if (hiword(wparam) == 1) .eight else .nine,
                if (msg == c.WM_XBUTTONDOWN) .press else .release,
                lparam,
            );
            return 1;
        },

        c.WM_MOUSEWHEEL => try surface.scrollCallback(0, wheelTicks(wparam), .{}),
        // Positive is right for both Windows and Ghostty.
        c.WM_MOUSEHWHEEL => try surface.scrollCallback(wheelTicks(wparam), 0, .{}),

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (wparam == c.VK_PROCESSKEY or wparam == c.VK_PACKET) return 0;
            const repeat = lparam & (1 << 30) != 0;
            const effect = try self.key(if (repeat) .repeat else .press, wparam, lparam);

            // Alt+Space opens the system menu unless the terminal bound it.
            // DefWindowProc does that in response to WM_SYSCHAR.
            if (effect == .ignored and msg == c.WM_SYSKEYDOWN and wparam == c.VK_SPACE)
                return c.DefWindowProcW(self.hwnd, c.WM_SYSCHAR, c.VK_SPACE, lparam);
        },
        c.WM_KEYUP, c.WM_SYSKEYUP => _ = try self.key(.release, wparam, lparam),

        // Only for VK_PACKET, see App.run.
        c.WM_CHAR => try self.char(@truncate(wparam)),

        c.WM_IME_STARTCOMPOSITION => self.positionIme(),
        c.WM_IME_COMPOSITION => try self.imeComposition(lparam),
        c.WM_IME_ENDCOMPOSITION => try surface.preeditCallback(null),

        else => return null,
    }
    return 0;
}

fn hiword(v: usize) u16 {
    return @truncate(v >> 16);
}

fn wheelTicks(wparam: c.WPARAM) f64 {
    const delta: i16 = @bitCast(hiword(wparam));
    return @as(f64, @floatFromInt(delta)) / 120;
}

fn mousePos(lparam: c.LPARAM) apprt.CursorPos {
    const bits: usize = @bitCast(lparam);
    const x: i16 = @bitCast(@as(u16, @truncate(bits)));
    const y: i16 = @bitCast(hiword(bits));
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

fn button(
    self: *Surface,
    btn: input.MouseButton,
    action: input.MouseButtonState,
    lparam: c.LPARAM,
) !void {
    // Capture so that drags and releases outside the window reach us.
    switch (action) {
        .press => {
            self.buttons_down +|= 1;
            _ = c.SetCapture(self.hwnd);
        },
        .release => {
            self.buttons_down -|= 1;
            if (self.buttons_down == 0) _ = c.ReleaseCapture();
        },
    }

    const mods = currentMods();
    try self.core_surface.cursorPosCallback(mousePos(lparam), mods);
    _ = try self.core_surface.mouseButtonCallback(action, btn, mods);
}

//---------------------------------------------------------------
// Keyboard

fn down(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

fn toggled(vk: c_int) bool {
    return c.GetKeyState(vk) & 1 != 0;
}

fn currentMods() input.Mods {
    return .{
        .shift = down(c.VK_SHIFT),
        .ctrl = down(c.VK_CONTROL),
        .alt = down(c.VK_MENU),
        .super = down(c.VK_LWIN) or down(c.VK_RWIN),
        .caps_lock = toggled(c.VK_CAPITAL),
        .num_lock = toggled(c.VK_NUMLOCK),
        .sides = .{
            .shift = if (down(c.VK_RSHIFT)) .right else .left,
            .ctrl = if (down(c.VK_RCONTROL)) .right else .left,
            .alt = if (down(c.VK_RMENU)) .right else .left,
            .super = if (down(c.VK_RWIN)) .right else .left,
        },
    };
}

fn physicalKey(vk: u32, lparam: c.LPARAM) input.Key {
    const bits: usize = @bitCast(lparam);

    // With Num Lock off, the numpad sends navigation keys. Only the lack of
    // the extended flag tells these apart from the dedicated ones.
    if (bits & (1 << 24) == 0) switch (vk) {
        c.VK_CLEAR => return .numpad_begin,
        c.VK_PRIOR => return .numpad_page_up,
        c.VK_NEXT => return .numpad_page_down,
        c.VK_END => return .numpad_end,
        c.VK_HOME => return .numpad_home,
        c.VK_LEFT => return .numpad_left,
        c.VK_UP => return .numpad_up,
        c.VK_RIGHT => return .numpad_right,
        c.VK_DOWN => return .numpad_down,
        c.VK_INSERT => return .numpad_insert,
        c.VK_DELETE => return .numpad_delete,
        else => {},
    };

    const scancode: u32 = @intCast((bits >> 16) & 0xFF);
    const native = if (bits & (1 << 24) != 0) 0xE000 | scancode else scancode;
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}

fn key(
    self: *Surface,
    action: input.Action,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !CoreSurface.InputEffect {
    const vk: u32 = @intCast(wparam);
    const scancode: u32 = @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0xFF);

    // MapVirtualKey flags dead keys in the top bit, and gives letters in
    // upper case.
    const unshifted: u21 = cp: {
        const v = c.MapVirtualKeyW(vk, c.MAPVK_VK_TO_CHAR) & 0x7FFFFFFF;
        if (v < 0x20 or v == 0x7F) break :cp 0;
        break :cp if (v < 0x80) std.ascii.toLower(@intCast(v)) else std.math.cast(u21, v) orelse 0;
    };

    var event: input.KeyEvent = .{
        .action = action,
        .key = physicalKey(vk, lparam),
        .mods = currentMods(),
        .unshifted_codepoint = unshifted,
    };

    var utf8_buf: [64]u8 = undefined;
    if (action != .release) {
        const text = translate(vk, scancode, event.mods);
        event.consumed_mods = text.consumed;
        switch (text.result) {
            .none => {},

            .dead => |cp| {
                self.dead_key = true;
                event.composing = true;
                event.consumed_mods = .{};
                const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 0;
                try self.core_surface.preeditCallback(utf8_buf[0..len]);
            },

            .text => |v| {
                const len = std.unicode.wtf16LeToWtf8(&utf8_buf, v.buf[0..v.len]);
                event.utf8 = utf8_buf[0..len];
                if (self.dead_key) {
                    self.dead_key = false;
                    try self.core_surface.preeditCallback(null);
                }
            },
        }
    }

    return try self.core_surface.keyCallback(event);
}

const Translation = struct {
    consumed: input.Mods = .{},
    result: union(enum) {
        none,
        dead: u21,
        text: struct { buf: [16]u16, len: usize },
    } = .none,
};

/// Determine the text a key press produces with the current layout.
fn translate(vk: u32, scancode: u32, mods: input.Mods) Translation {
    var state: [256]u8 = undefined;
    if (c.GetKeyboardState(&state) == 0) return .{};

    // Bit 2 of the flags leaves the kernel's dead key state alone.
    const peek = 1 << 2;
    var buf: [16]u16 = undefined;

    var consumed: input.Mods = .{ .shift = mods.shift };

    // Ctrl+Alt is AltGr, if the layout has something for this key. Otherwise,
    // Ctrl and Alt aren't part of the text: the core encodes them itself.
    const altgr = mods.ctrl and mods.alt and altgr: {
        const len = c.ToUnicode(vk, scancode, &state, &buf, buf.len, peek);
        break :altgr len < 0 or (len > 0 and buf[0] >= 0x20 and buf[0] != 0x7F);
    };
    if (altgr) {
        consumed.ctrl = true;
        consumed.alt = true;
    } else for ([_]usize{
        c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL,
        c.VK_MENU,    c.VK_LMENU,    c.VK_RMENU,
    }) |i| {
        state[i] = 0;
    }

    const len = c.ToUnicode(vk, scancode, &state, &buf, buf.len, 0);
    if (len == 0) return .{};
    if (len < 0) return .{ .consumed = consumed, .result = .{ .dead = buf[0] } };

    // Control characters (enter, tab, escape, backspace) are encoded by the
    // core from the physical key.
    if (buf[0] < 0x20 or buf[0] == 0x7F) return .{};
    return .{
        .consumed = consumed,
        .result = .{ .text = .{ .buf = buf, .len = @intCast(len) } },
    };
}

/// Send text that has no associated key.
fn commit(self: *Surface, text: []const u8) !void {
    if (text.len == 0) return;
    _ = try self.core_surface.keyCallback(.{ .utf8 = text });
}

fn char(self: *Surface, unit: u16) !void {
    if (std.unicode.utf16IsHighSurrogate(unit)) {
        self.high_surrogate = unit;
        return;
    }
    const units = [_]u16{ self.high_surrogate, unit };
    const slice = if (std.unicode.utf16IsLowSurrogate(unit)) &units else units[1..];
    self.high_surrogate = 0;
    var buf: [8]u8 = undefined;
    try self.commit(buf[0..std.unicode.wtf16LeToWtf8(&buf, slice)]);
}

//---------------------------------------------------------------
// IME

fn positionIme(self: *Surface) void {
    const imc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, imc);
    const pos = self.core_surface.imePointScaled(.{ .x = 1, .y = 1 });
    _ = c.ImmSetCompositionWindow(imc, &.{
        .dwStyle = c.CFS_POINT,
        .ptCurrentPos = .{ .x = @intFromFloat(pos.x), .y = @intFromFloat(pos.y) },
    });
}

fn imeComposition(self: *Surface, lparam: c.LPARAM) !void {
    const imc = c.ImmGetContext(self.hwnd) orelse return;
    defer _ = c.ImmReleaseContext(self.hwnd, imc);

    const alloc = self.app.core_app.alloc;
    if (lparam & c.GCS_RESULTSTR != 0) {
        const text = try imeString(alloc, imc, c.GCS_RESULTSTR);
        defer alloc.free(text);
        try self.core_surface.preeditCallback(null);
        try self.commit(text);
    }
    if (lparam & c.GCS_COMPSTR != 0) {
        const text = try imeString(alloc, imc, c.GCS_COMPSTR);
        defer alloc.free(text);
        try self.core_surface.preeditCallback(if (text.len > 0) text else null);
    }
}

fn imeString(alloc: Allocator, imc: c.HIMC, kind: u32) ![]u8 {
    // The length is in bytes, and negative for errors.
    const bytes = c.ImmGetCompositionStringW(imc, kind, null, 0);
    if (bytes <= 0) return try alloc.alloc(u8, 0);
    const buf = try alloc.alloc(u16, @as(usize, @intCast(bytes)) / 2);
    defer alloc.free(buf);
    const written = c.ImmGetCompositionStringW(imc, kind, buf.ptr, @intCast(bytes));
    if (written <= 0) return try alloc.alloc(u8, 0);
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, buf[0 .. @as(usize, @intCast(written)) / 2]);
}

//---------------------------------------------------------------
// Clipboard

/// Only one process can have the clipboard open, and clipboard managers open
/// it whenever it changes, so retry for a little while.
fn openClipboard(hwnd: c.HWND) !void {
    for (0..10) |_| {
        if (c.OpenClipboard(hwnd) != 0) return;
        c.Sleep(5);
    }
    return error.ClipboardBusy;
}

/// The clipboard's text as UTF-8 with LF line endings, if it has any.
fn readClipboard(alloc: Allocator, hwnd: c.HWND) !?[]u8 {
    try openClipboard(hwnd);
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
    const ptr: [*]const u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse return null));
    defer _ = c.GlobalUnlock(handle);

    // Don't trust the owner of the data to have terminated it.
    const all = ptr[0 .. c.GlobalSize(handle) / 2];
    const text = try std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.sliceTo(all, 0));
    defer alloc.free(text);
    return try std.mem.replaceOwned(u8, alloc, text, "\r\n", "\n");
}

fn writeClipboard(alloc: Allocator, hwnd: c.HWND, text: []const u8) !void {
    // Windows applications expect CRLF.
    const lf = try std.mem.replaceOwned(u8, alloc, text, "\r\n", "\n");
    defer alloc.free(lf);
    const crlf = try std.mem.replaceOwned(u8, alloc, lf, "\n", "\r\n");
    defer alloc.free(crlf);
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, crlf);
    defer alloc.free(wide);

    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, (wide.len + 1) * 2) orelse return error.OutOfMemory;
    // Owned by the system once SetClipboardData succeeds.
    errdefer _ = c.GlobalFree(handle);
    {
        const dst: [*]u16 = @ptrCast(@alignCast(c.GlobalLock(handle) orelse return error.OutOfMemory));
        defer _ = c.GlobalUnlock(handle);
        @memcpy(dst[0 .. wide.len + 1], wide.ptr[0 .. wide.len + 1]);
    }

    try openClipboard(hwnd);
    defer _ = c.CloseClipboard();
    _ = c.EmptyClipboard();
    if (c.SetClipboardData(c.CF_UNICODETEXT, handle) == null) return error.ClipboardWriteFailed;
}
