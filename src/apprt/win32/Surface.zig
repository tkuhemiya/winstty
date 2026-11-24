//! A terminal surface: a child window of a Window, rendered to by OpenGL.
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
const InspectorWindow = @import("InspectorWindow.zig");
const Scrollbar = @import("Scrollbar.zig");
const SearchBar = @import("SearchBar.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

/// Posted by `close`. wParam is whether to confirm.
const WM_CLOSE_SURFACE = c.WM_APP + 1;

app: *App,
window: *Window,
hwnd: c.HWND,

/// The number of split trees holding this surface.
refs: usize = 0,
core_surface: CoreSurface = undefined,

/// False until the core surface is initialized.
ready: bool = false,

title: ?[:0]const u8 = null,

/// Whether we're shown: in the selected tab, and not hidden by a zoomed split.
visible: bool = false,

search: ?*SearchBar = null,
inspector: ?*InspectorWindow = null,
/// The color (0xAARRGGBB) drawn over this surface, for splits without focus.
/// Read by the render thread.
dim: std.atomic.Value(u32) = .init(0),

/// Read by the render thread.
smooth_scroll: std.atomic.Value(bool) = .init(false),

scrollbar: ?*Scrollbar = null,
scrollbar_state: terminal.Scrollbar = .zero,

cursor: ?c.HCURSOR,
cursor_visible: bool = true,
tracking_leave: bool = false,
buttons_down: u8 = 0,

/// A close was requested while a message box was open.
close_pending: bool = false,

/// True if a dead key is waiting for its base character.
dead_key: bool = false,

/// High half of a surrogate pair delivered by WM_CHAR.
high_surrogate: u16 = 0,

/// Create a hidden surface. It's destroyed when no longer in any split tree.
pub fn create(
    window: *Window,
    context: apprt.surface.NewSurfaceContext,
    rect: c.RECT,
    command: ?[]const u8,
) !*Surface {
    const app = window.app;
    const alloc = app.core_app.alloc;
    const parent = window.activeSurface() orelse parent: {
        const core_surface = app.core_app.focusedSurface() orelse break :parent null;
        break :parent core_surface.rt_surface;
    };

    const self = try alloc.create(Surface);
    errdefer alloc.destroy(self);

    const hwnd = c.CreateWindowExW(
        0,
        App.surface_class,
        c.L(""),
        c.WS_CHILD | c.WS_CLIPSIBLINGS,
        rect.left,
        rect.top,
        @max(1, rect.right - rect.left - if (app.config.scrollbar == .system)
            Scrollbar.width(window.getDpi())
        else
            0),
        @max(1, rect.bottom - rect.top),
        window.hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    errdefer _ = c.DestroyWindow(hwnd);

    self.* = .{
        .app = app,
        .window = window,
        .hwnd = hwnd,
        .cursor = c.LoadCursorW(null, c.IDC_IBEAM),
    };
    self.smooth_scroll.store(app.config.@"win32-smooth-scroll", .release);
    try self.syncScrollbar();
    errdefer if (self.scrollbar) |v| v.destroy();

    var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
    defer config.deinit();
    if (command orelse app.shell_override) |cmd| {
        const arena = config._arena.?.allocator();
        config.command = .{ .shell = try arena.dupeSentinel(u8, cmd, 0) };
    }
    if (window.force_opaque) config.@"background-opacity" = 1;
    if (app.config.@"window-inherit-font-size") {
        if (parent) |v| config.@"font-size" = v.core_surface.font_size.points;
    }

    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    try self.core_surface.init(alloc, &config, app.core_app, app, self);
    self.ready = true;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    return self;
}

/// Must not be called within one of our callbacks.
pub fn destroy(self: *Surface) void {
    const alloc = self.app.core_app.alloc;
    self.ready = false;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    if (self.search) |v| v.destroy();
    if (self.inspector) |v| v.destroy();
    if (self.scrollbar) |v| v.destroy();
    self.app.core_app.deleteSurface(self);

    // This joins the render thread and deletes its GL context, so must come
    // before the window, and so its DC, is gone.
    self.core_surface.deinit();
    _ = c.DestroyWindow(self.hwnd);
    if (self.title) |v| alloc.free(v);
    alloc.destroy(self);
}

/// Required by CoreApp, for surfaces left when it shuts down. There are none,
/// because `App.terminate` destroys all windows first.
pub fn deinit(self: *Surface) void {
    self.destroy();
}

//---------------------------------------------------------------
// SplitTree view API

pub fn ref(self: *Surface) *Surface {
    self.refs += 1;
    return self;
}

pub fn unref(self: *Surface) void {
    self.refs -= 1;
    if (self.refs == 0) self.destroy();
}

pub fn eql(a: *const Surface, b: *const Surface) bool {
    return a == b;
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
            const allowed = self.app.confirm(
                self.window.hwnd,
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

    if (confirm_write and !self.app.confirm(
        self.window.hwnd,
        c.L("Allow clipboard access?"),
        c.L("An application is trying to write to the clipboard."),
    )) return;

    try writeClipboard(self.app.core_app.alloc, self.hwnd, text);
}

//---------------------------------------------------------------
// Actions

pub fn setTitle(self: *Surface, title: [:0]const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy = try alloc.dupeSentinel(u8, title, 0);
    if (self.title) |v| alloc.free(v);
    self.title = copy;
    self.window.titleChanged(self);
}

/// Move to another window.
pub fn setWindow(self: *Surface, window: *Window) void {
    self.window = window;
    _ = c.SetParent(self.hwnd, window.hwnd);
    if (self.scrollbar) |v| _ = c.SetParent(v.hwnd, window.hwnd);
}

pub fn setVisible(self: *Surface, visible: bool) void {
    if (self.visible == visible) return;
    self.visible = visible;
    const show: c_int = if (visible) c.SW_SHOWNA else c.SW_HIDE;
    _ = c.ShowWindow(self.hwnd, show);
    if (self.scrollbar) |v| _ = c.ShowWindow(v.hwnd, show);
    self.setOccluded(!visible or self.window.minimized);
    if (self.search) |v| v.reposition();
}

pub fn setDimmed(self: *Surface, dimmed: bool) void {
    const config = &self.app.config;
    const value: u32 = value: {
        if (!dimmed) break :value 0;
        const opacity = std.math.clamp(config.@"unfocused-split-opacity", 0, 1);
        const color = config.@"unfocused-split-fill" orelse config.background;
        const alpha: u32 = @intFromFloat(@round((1 - opacity) * 255));
        break :value alpha << 24 | @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
    };
    if (self.dim.swap(value, .acq_rel) == value) return;
    self.core_surface.refreshCallback() catch |err|
        log.warn("error refreshing surface err={}", .{err});
}

/// Whether there's any point in rendering.
pub fn setOccluded(self: *Surface, occluded: bool) void {
    self.core_surface.occlusionCallback(!occluded) catch |err|
        log.warn("error in occlusion callback err={}", .{err});
}

pub fn dpiChanged(self: *Surface) void {
    const scale = self.getContentScale() catch return;
    self.core_surface.contentScaleCallback(scale) catch |err|
        log.warn("error in content scale callback err={}", .{err});
}

/// Position within the window.
pub fn place(self: *Surface, area: c.RECT) void {
    const flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOCOPYBITS;
    const height = @max(1, area.bottom - area.top);
    const bar = self.scrollbarWidth();
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        area.left,
        area.top,
        @max(1, area.right - area.left - bar),
        height,
        flags,
    );
    if (self.scrollbar) |v| _ = c.SetWindowPos(
        v.hwnd,
        null,
        @max(area.left, area.right - bar),
        area.top,
        bar,
        height,
        flags,
    );
}

pub fn configChanged(self: *Surface) void {
    self.smooth_scroll.store(self.app.config.@"win32-smooth-scroll", .release);
    self.syncScrollbar() catch |err| log.warn("error creating scrollbar err={}", .{err});
    if (self.scrollbar) |v| v.invalidate();
}

/// The background is drawn premultiplied, so it must be redrawn to be opaque.
pub fn updateOpacity(self: *Surface) void {
    var config = self.app.config.shallowClone(self.app.core_app.alloc);
    defer config.deinit();
    if (self.window.force_opaque) config.@"background-opacity" = 1;
    self.core_surface.updateConfig(&config) catch |err|
        log.warn("error updating opacity err={}", .{err});
}

pub fn scrollbarWidth(self: *const Surface) c_int {
    if (self.scrollbar == null) return 0;
    return Scrollbar.width(c.GetDpiForWindow(self.hwnd));
}

pub fn setScrollbar(self: *Surface, value: terminal.Scrollbar) void {
    self.scrollbar_state = value;
    if (self.scrollbar) |v| v.set(value);
}

/// Create or destroy the scrollbar as configured.
fn syncScrollbar(self: *Surface) !void {
    switch (self.app.config.scrollbar) {
        .system => if (self.scrollbar == null) {
            const v: *Scrollbar = try .create(self);
            v.state = self.scrollbar_state;
            if (self.visible) _ = c.ShowWindow(v.hwnd, c.SW_SHOWNA);
            self.scrollbar = v;
        },
        .never => if (self.scrollbar) |v| {
            v.destroy();
            self.scrollbar = null;
        },
    }
}

//---------------------------------------------------------------
// Mouse appearance

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

/// Returns null for default processing. After a core callback, self is still
/// valid, because destruction only ever happens via a posted message.
fn message(self: *Surface, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) !?c.LRESULT {
    const surface = &self.core_surface;
    switch (msg) {
        WM_CLOSE_SURFACE => {
            // A message box is open, likely above a core callback.
            if (self.app.modal > 0) {
                self.close_pending = true;
                return 0;
            }
            if (wparam != 0 and !self.app.confirm(
                self.window.hwnd,
                c.L("Close terminal?"),
                c.L("The running process in this terminal will be terminated."),
            )) return 0;
            try self.window.closeSurface(self);
        },

        c.WM_NCHITTEST => {
            const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16)));
            if (self.window.inResizeBand(y)) return c.HTTRANSPARENT;
            return null;
        },

        c.WM_PAINT => {
            _ = c.ValidateRect(self.hwnd, null);
            try surface.refreshCallback();
        },

        // We paint every pixel, erasing only causes flicker.
        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => {
            const size = try self.getSize();
            if (size.width > 0 and size.height > 0) try surface.sizeCallback(size);
            if (self.search) |v| v.reposition();
        },

        c.WM_SETFOCUS => {
            self.window.surfaceFocused(self);
            try surface.focusCallback(true);
        },
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
            if (self.app.config.@"focus-follows-mouse" and
                c.GetForegroundWindow() == self.window.hwnd and
                c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
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
            if (effect == .ignored and msg == c.WM_SYSKEYDOWN and wparam == c.VK_SPACE)
                _ = c.PostMessageW(self.window.hwnd, c.WM_SYSCOMMAND, c.SC_KEYMENU, c.VK_SPACE);
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
            if (c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
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
