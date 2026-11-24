//! The Win32 application: message loop, window class and app-level actions.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

pub const window_class = c.L("GhosttyWindow");
const app_class = c.L("GhosttyApp");

/// Posted to the message-only window to drain the core mailbox.
const WM_WAKEUP = c.WM_APP + 1;
/// Posted to the message-only window to close every window and exit.
const WM_QUIT_APP = c.WM_APP + 2;

core_app: *CoreApp,
config: Config,
hinstance: c.HINSTANCE,

/// Message-only window. App messages go here rather than to the thread
/// because thread messages are lost while a modal loop (window resize, menu,
/// message box) is pumping.
hwnd: c.HWND,

/// Set once we've started exiting, so teardown doesn't re-enter.
quitting: bool = false,

pub fn init(self: *App, core_app: *CoreApp, opts: struct {}) !void {
    _ = opts;

    var config = Config.load(core_app.alloc) catch |err| err: {
        log.err("error loading configuration, using defaults err={}", .{err});
        break :err try Config.default(core_app.alloc);
    };
    errdefer config.deinit();
    for (config._diagnostics.items()) |diag| {
        log.warn("config: {s}", .{diag.message});
    }

    // Some shells start programs with Ctrl+C ignored. Children inherit that,
    // and would make Ctrl+C useless in every terminal we open.
    _ = c.SetConsoleCtrlHandler(null, 0);

    const hinstance = c.GetModuleHandleW(null) orelse return error.Win32Failed;
    const icon = c.LoadIconW(hinstance, 1);
    if (c.RegisterClassExW(&.{
        // The WGL context holds on to the window's DC, so it must be owned.
        .style = c.CS_OWNDC,
        .lpfnWndProc = Surface.wndProc,
        .hInstance = hinstance,
        .hIcon = icon,
        .hIconSm = icon,
        .lpszClassName = window_class,
    }) == 0) return error.Win32Failed;
    if (c.RegisterClassExW(&.{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .lpszClassName = app_class,
    }) == 0) return error.Win32Failed;

    const hwnd = c.CreateWindowExW(
        0,
        app_class,
        app_class,
        0,
        0,
        0,
        0,
        0,
        c.HWND_MESSAGE,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Failed;

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .hwnd = hwnd,
    };
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    core_app.colorSchemeEvent(self, systemColorScheme()) catch |err|
        log.warn("error setting color scheme err={}", .{err});
}

pub fn run(self: *App) !void {
    _ = try Surface.create(self, .window);

    var msg: c.MSG = undefined;
    while (true) {
        const result = c.GetMessageW(&msg, null, 0, 0);
        if (result == 0) return;
        if (result < 0) return error.Win32Failed;

        // We translate keys to text ourselves (see Surface.key). The
        // exceptions are keys owned by the IME and synthesized Unicode input,
        // which only Windows can translate.
        switch (msg.message) {
            c.WM_KEYDOWN, c.WM_SYSKEYDOWN => switch (msg.wParam) {
                c.VK_PROCESSKEY, c.VK_PACKET => _ = c.TranslateMessage(&msg),
                else => {},
            },
            else => {},
        }
        _ = c.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.closeAll();
    _ = c.DestroyWindow(self.hwnd);
    self.config.deinit();
}

/// Called by CoreApp, from any thread, to wake up the event loop.
pub fn wakeup(self: *App) void {
    _ = c.PostMessageW(self.hwnd, WM_WAKEUP, 0, 0);
}

fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_WAKEUP => self.core_app.tick(self) catch |err|
            log.err("error in app tick err={}", .{err}),

        WM_QUIT_APP => if (!self.quitting) {
            if (self.core_app.needsConfirmQuit() and c.MessageBoxW(
                null,
                c.L("All terminal sessions will be terminated."),
                c.L("Quit Ghostty?"),
                c.MB_OKCANCEL | c.MB_ICONWARNING,
            ) != c.IDOK) return 0;
            self.closeAll();
            c.PostQuitMessage(0);
        },

        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

fn closeAll(self: *App) void {
    self.quitting = true;
    while (self.core_app.surfaces.items.len > 0) {
        const len = self.core_app.surfaces.items.len;
        _ = c.DestroyWindow(self.core_app.surfaces.items[len - 1].hwnd);

        // Destroying the window removes the surface. If it somehow didn't,
        // don't spin.
        if (self.core_app.surfaces.items.len >= len) return;
    }
}

/// The configured system theme for apps, defaulting to light like Windows.
pub fn systemColorScheme() apprt.ColorScheme {
    var light: u32 = 1;
    var size: u32 = @sizeOf(u32);
    _ = c.RegGetValueW(
        c.HKEY_CURRENT_USER,
        c.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        c.L("AppsUseLightTheme"),
        c.RRF_RT_REG_DWORD,
        null,
        &light,
        &size,
    );
    return if (light == 0) .dark else .light;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    const surface: ?*Surface = switch (target) {
        .app => null,
        .surface => |v| v.rt_surface,
    };

    switch (action) {
        // Deferred, we may be inside a callback of a surface this destroys.
        .quit => _ = c.PostMessageW(self.hwnd, WM_QUIT_APP, 0, 0),

        // There is no tray icon or other way back in, so regardless of
        // quit-after-last-window-closed an app with no windows must exit.
        .quit_timer => switch (value) {
            .start => if (!self.quitting) {
                self.quitting = true;
                c.PostQuitMessage(0);
            },
            .stop => {},
        },

        .new_window => _ = try Surface.create(self, .window),

        .close_window => _ = c.PostMessageW(
            (surface orelse return false).hwnd,
            c.WM_CLOSE,
            0,
            0,
        ),

        .close_all_windows => for (self.core_app.surfaces.items) |v| {
            _ = c.PostMessageW(v.hwnd, c.WM_CLOSE, 0, 0);
        },

        .reload_config => try self.reloadConfig(value.soft),
        .open_config => return try self.openConfig(),
        .open_url => return try self.openUrl(value),

        .set_title,
        .set_window_title,
        => try (surface orelse return false).setTitle(value.title),
        .toggle_fullscreen => (surface orelse return false).toggleFullscreen(),
        .toggle_maximize => (surface orelse return false).toggleMaximize(),
        .mouse_shape => (surface orelse return false).setMouseShape(value),
        .mouse_visibility => (surface orelse return false).setMouseVisible(value == .visible),
        .initial_size => (surface orelse return false).setClientSize(value.width, value.height),
        .size_limit => (surface orelse return false).size_limit = value,
        .present_terminal => (surface orelse return false).present(),
        .ring_bell => _ = c.MessageBeep(0),

        // The render thread presents on its own, there's nothing to queue.
        .render => {},

        else => {
            log.debug("unimplemented action={s}", .{@tagName(action)});
            return false;
        },
    }
    return true;
}

fn reloadConfig(self: *App, soft: bool) !void {
    if (!soft) {
        const config = try Config.load(self.core_app.alloc);
        self.config.deinit();
        self.config = config;
    }
    try self.core_app.updateConfig(self, &self.config);
}

fn openConfig(self: *App) !bool {
    const alloc = self.core_app.alloc;
    const path = try configpkg.edit.openPath(alloc);
    defer alloc.free(path);
    return try self.openUrl(.{ .kind = .text, .url = path });
}

fn openUrl(self: *App, value: apprt.action.OpenUrl) !bool {
    const alloc = self.core_app.alloc;
    const url = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value.url);
    defer alloc.free(url);

    switch (value.kind) {
        // ShellExecute runs executables, so text is always given to an editor
        // and is never opened by association.
        .text => {
            const params = try std.fmt.allocPrint(alloc, "\"{s}\"", .{value.url});
            defer alloc.free(params);
            const params_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, params);
            defer alloc.free(params_w);
            return shellExecute(c.L("notepad.exe"), params_w);
        },

        .html => return shellExecute(url, null),

        // Terminal output controls these. Opening an arbitrary path or scheme
        // could run a program, so only allow what goes to a browser or
        // mail client. Returning true stops the core from falling back to its
        // generic opener, which has no such checks.
        .unknown, .osc8 => {
            for ([_][]const u8{ "https://", "http://", "mailto:" }) |prefix| {
                if (std.ascii.startsWithIgnoreCase(value.url, prefix)) {
                    _ = shellExecute(url, null);
                    return true;
                }
            }
            log.warn("refusing to open untrusted link", .{});
            return true;
        },
    }
}

fn shellExecute(file: [*:0]const u16, params: ?[*:0]const u16) bool {
    // Documented as returning a fake HINSTANCE, greater than 32 on success.
    const result = c.ShellExecuteW(null, c.L("open"), file, params, null, c.SW_SHOWNORMAL);
    return @intFromPtr(result) > 32;
}

/// We don't have an IPC mechanism yet.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

/// The inspector isn't implemented yet.
pub fn redrawInspector(_: *App, _: *Surface) void {}
