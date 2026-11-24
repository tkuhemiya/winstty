//! The Win32 application: message loop, window class and app-level actions.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const InspectorWindow = @import("InspectorWindow.zig");
const Outline = @import("Outline.zig");
const Session = @import("Session.zig");
const Scrollbar = @import("Scrollbar.zig");
const SearchBar = @import("SearchBar.zig");
const CommandPalette = @import("CommandPalette.zig");
const Surface = @import("Surface.zig");
const Ticker = @import("Ticker.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");
const glass = @import("glass.zig");
const global = @import("../../global.zig");
const motion = @import("motion.zig");
const rex = @import("../../rex/main.zig");
const themes = @import("themes.zig");

const log = std.log.scoped(.win32);

pub const window_class = c.L("GhosttyWindow");
pub const surface_class = c.L("GhosttySurface");
const app_class = c.L("GhosttyApp");

/// Posted to the message-only window to drain the core mailbox.
const WM_WAKEUP = c.WM_APP + 1;
/// Posted to the message-only window to close every window and exit.
const WM_QUIT_APP = c.WM_APP + 2;
/// Posted to the message-only window for each frame of animation.
const WM_TICK = c.WM_APP + 3;
/// Posted to the message-only window with a `Posted`.
const WM_POSTED = c.WM_APP + 4;
/// Posted to the message-only window when a client has something to take.
const WM_CLIENT = c.WM_APP + 5;
/// Posted to the message-only window when a stream has ended.
const WM_STREAM_ENDED = c.WM_APP + 6;

core_app: *CoreApp,
config: Config,
hinstance: c.HINSTANCE,

/// Message-only window. App messages go here rather than to the thread
/// because thread messages are lost while a modal loop (window resize, menu,
/// message box) is pumping.
hwnd: c.HWND,

windows: std.ArrayList(*Window) = .empty,

/// A shell chosen from the command palette. New tabs and splits run it instead
/// of the configured `command`, until we exit.
shell_override: ?[]u8 = null,
last_tab_id: u32 = 0,

/// The number of open message boxes. They pump messages, and may have been
/// opened from inside a core callback, so nothing may be destroyed meanwhile.
modal: u32 = 0,

/// For windows with something that moves.
ticker: Ticker,

/// Signaled when a surface that's moving has been drawn.
presented: c.HANDLE,

/// Why glass can't be shown, if it can't.
blur_unavailable: ?[]const u8 = null,
high_contrast: bool = false,
/// Whether Windows is set to show animations.
animations: bool = true,
/// The note about settings that glass replaces has been made.
noted_glass: bool = false,

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
        .style = c.CS_DBLCLKS,
        .lpfnWndProc = Window.wndProc,
        .hInstance = hinstance,
        .hIcon = icon,
        .hIconSm = icon,
        .lpszClassName = window_class,
    }) == 0) return error.Win32Failed;
    if (c.RegisterClassExW(&.{
        // The WGL context holds on to the window's DC, so it must be owned.
        .style = c.CS_OWNDC,
        .lpfnWndProc = Surface.wndProc,
        .hInstance = hinstance,
        .lpszClassName = surface_class,
    }) == 0) return error.Win32Failed;
    try Scrollbar.register(hinstance);
    try SearchBar.register(hinstance);
    try CommandPalette.register(hinstance);
    try InspectorWindow.register(hinstance);
    try Outline.register(hinstance);
    _ = c.InitCommonControlsEx(&.{ .dwICC = c.ICC_BAR_CLASSES });
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
        .ticker = try .init(hwnd, WM_TICK),
        .presented = c.CreateEventW(null, 0, 0, null) orelse return error.Win32Failed,
    };
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.readSystem();
    self.logGlass();
    core_app.colorSchemeEvent(self, systemColorScheme()) catch |err|
        log.warn("error setting color scheme err={}", .{err});
}

pub fn run(self: *App) !void {
    try self.openWindow(.last);

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
    if (self.shell_override) |v| self.core_app.alloc.free(v);
    self.ticker.deinit();
    _ = c.CloseHandle(self.presented);

    // What other threads had for us.
    var msg: c.MSG = undefined;
    while (c.PeekMessageW(&msg, self.hwnd, WM_POSTED, WM_POSTED, c.PM_REMOVE) != 0) {
        const posted: *Posted = @ptrFromInt(@as(usize, @bitCast(msg.lParam)));
        posted.deinit(self.core_app.alloc);
        self.core_app.alloc.destroy(posted);
    }
    _ = c.DestroyWindow(self.hwnd);
    self.windows.deinit(self.core_app.alloc);
    self.config.deinit();
}

/// Make `command` the shell of every surface created from now on.
pub fn setShell(self: *App, command: []const u8) !void {
    const copy = try self.core_app.alloc.dupe(u8, command);
    if (self.shell_override) |v| self.core_app.alloc.free(v);
    self.shell_override = copy;
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

        WM_TICK => self.tick(),

        WM_POSTED => {
            const posted: *Posted = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const value = posted.*;
            self.core_app.alloc.destroy(posted);
            self.handlePosted(value);
        },
        WM_CLIENT => for (self.windows.items) |window| {
            if (window.session) |v| v.receive();
        },
        WM_STREAM_ENDED => for (self.windows.items) |window| {
            if (window.session) |v| v.streamsEnded();
        },

        WM_QUIT_APP => if (!self.quitting and self.modal == 0) {
            const needs_confirm = for (self.windows.items) |window| {
                if (window.needsConfirm()) break true;
            } else false;
            if (needs_confirm and !self.confirm(
                null,
                c.L("Quit Ghostty?"),
                c.L("All terminal sessions will be terminated."),
            )) return 0;
            self.closeAll();
            c.PostQuitMessage(0);
        },

        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

//---------------------------------------------------------------
// Rex

/// What other threads have us do.
pub const Posted = union(enum) {
    connected: *Connecting,
    opened: *Session.Opened,
    failed: struct { window: ?c.HWND, err: anyerror },
    tell: struct { window: c.HWND, title: [*:0]const u16, text: [:0]u16 },

    fn deinit(self: Posted, alloc: Allocator) void {
        switch (self) {
            .connected => |v| v.destroy(),
            .opened => |v| v.destroy(),
            .failed => {},
            .tell => |v| alloc.free(v.text),
        }
    }
};

/// A connection on its way, for a new window, or for one that lost its own.
pub const Connecting = struct {
    app: *App,
    alloc: Allocator,
    target: Session.Target,
    window: ?c.HWND,
    delay_ms: u32,
    path_buf: [260:0]u16 = undefined,
    path: [:0]const u16 = undefined,
    result: anyerror!*rex.Client = error.Unexpected,

    fn run(self: *Connecting) void {
        if (self.delay_ms > 0) c.Sleep(self.delay_ms);
        self.result = self.connect();
        self.app.post(.{ .connected = self });
    }

    fn connect(self: *Connecting) !*rex.Client {
        self.path = try rex.launch.path(self.alloc, &self.path_buf);
        return try rex.Client.connect(self.alloc, self.path, .{
            .context = self.app,
            .func = clientNotified,
        });
    }

    fn destroy(self: *Connecting) void {
        self.target.deinit(self.alloc);
        if (self.result) |v| v.leave() else |_| {}
        self.alloc.destroy(self);
    }
};

/// From any thread.
pub fn post(self: *App, value: Posted) void {
    const alloc = self.core_app.alloc;
    const posted = alloc.create(Posted) catch return;
    posted.* = value;
    if (c.PostMessageW(self.hwnd, WM_POSTED, 0, @bitCast(@intFromPtr(posted))) != 0) return;

    // We're gone.
    alloc.destroy(posted);
    value.deinit(alloc);
}

fn clientNotified(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    _ = c.PostMessageW(self.hwnd, WM_CLIENT, 0, 0);
}

pub fn streamEnded(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    _ = c.PostMessageW(self.hwnd, WM_STREAM_ENDED, 0, 0);
}

fn windowOf(self: *const App, hwnd: ?c.HWND) ?*Window {
    const v = hwnd orelse return null;
    for (self.windows.items) |window| if (window.hwnd == v) return window;
    return null;
}

fn handlePosted(self: *App, value: Posted) void {
    switch (value) {
        .connected => |job| self.connected(job),
        .opened => |job| {
            defer job.destroy();
            const window = self.windowOf(job.window) orelse return;
            const session = window.session orelse return;
            if (session.client == job.client) session.opened(job);
        },
        .failed => |v| self.rexFailed(v.window, v.err),
        .tell => |v| {
            defer self.core_app.alloc.free(v.text);
            if (self.modal > 0) return;
            self.modal += 1;
            _ = c.MessageBoxW(v.window, v.text, v.title, c.MB_ICONWARNING);
            self.modal -= 1;
            self.modalClosed();
        },
    }
}

/// A window on a session, or a terminal of our own, as configured.
pub fn openWindow(self: *App, target: Session.Target) !void {
    if (!self.config.@"win32-rex") {
        _ = try Window.create(self);
        return;
    }
    const copy = try target.dupe(self.core_app.alloc);
    errdefer copy.deinit(self.core_app.alloc);
    try self.connectRex(copy, null);
}

/// Takes over the target if this doesn't fail.
pub fn connectRex(self: *App, target: Session.Target, window: ?c.HWND) !void {
    try self.connectRexIn(target, window, 0);
}

fn connectRexIn(self: *App, target: Session.Target, window: ?c.HWND, delay_ms: u32) !void {
    const alloc = self.core_app.alloc;
    const job = try alloc.create(Connecting);
    errdefer alloc.destroy(job);
    job.* = .{
        .app = self,
        .alloc = alloc,
        .target = target,
        .window = window,
        .delay_ms = delay_ms,
    };
    const thread = try std.Thread.spawn(.{}, Connecting.run, .{job});
    thread.detach();
}

fn connected(self: *App, job: *Connecting) void {
    defer job.destroy();
    if (self.quitting) return;
    const client = job.result catch |err| {
        log.warn("error connecting to the server err={}", .{err});
        const window = self.windowOf(job.window);
        if (job.window != null and window == null) return;
        if (window) |v| if (v.session) |session| {
            // The server may be about to be back.
            const max_reconnects = 10;
            const reconnect_ms = 1000;
            session.reconnects += 1;
            if (session.reconnects < max_reconnects) {
                const target = job.target;
                job.target = .last;
                self.connectRexIn(target, job.window, reconnect_ms) catch target.deinit(self.core_app.alloc);
                return;
            }
        };
        return self.rexFailed(job.window, err);
    };
    const target = job.target;
    if (job.window) |hwnd| {
        const window = self.windowOf(hwnd) orelse return;
        const session = window.session orelse return;
        job.result = error.Taken;
        job.target = .last;
        session.@"resume"(client, job.path, target);
        return;
    }
    Window.createFor(self, client, job.path, target) catch |err| {
        log.warn("error creating a window err={}", .{err});
        return;
    };
    job.result = error.Taken;
    job.target = .last;
}

/// There's no server to show anything of, and the user should know why.
fn rexFailed(self: *App, hwnd: ?c.HWND, err: anyerror) void {
    @setEvalBranchQuota(20_000);
    const why: [*:0]const u16 = switch (err) {
        error.NotInstalled => c.L("Rex Server isn't installed. To install it, run:\n\n" ++
            "winget source add --name rex --arg https://pkgs.superlogical.com/rex/winget --type Microsoft.Rest --explicit\n" ++
            "winget install Superlogical.RexServer.Preview --source rex\n\n" ++
            "Or set win32-rex to false, to go without it.\n\n" ++
            "Open a local terminal now?"),
        error.NotLocal => c.L("The Rex server isn't on this machine, and winstty only connects to one that is.\n\n" ++
            "Open a local terminal now?"),
        error.StartFailed => c.L("The Rex server couldn't be started.\n\n" ++
            "Open a local terminal now?"),
        else => c.L("The Rex server can't be reached.\n\n" ++
            "Open a local terminal now?"),
    };
    log.warn("there's no server to use err={}", .{err});
    if (self.modal > 0) return;
    const local = self.confirm(hwnd, c.L("Rex"), why);
    if (local) _ = Window.create(self) catch |e| log.warn("error creating a window err={}", .{e});
    if (self.windowOf(hwnd)) |window| window.destroy();
    if (self.windows.items.len == 0) c.PostQuitMessage(1);
}

/// Say something, once we're done with what we're doing.
pub fn tell(self: *App, window: c.HWND, comptime title: []const u8, text: []const u8) void {
    const alloc = self.core_app.alloc;
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(alloc, text) catch return;
    self.post(.{ .tell = .{ .window = window, .title = c.L(title), .text = wide } });
}

const last_session_name = "rex-session";
const max_last_session = 256;

fn lastSessionPath(self: *App) ![]u8 {
    const alloc = self.core_app.alloc;
    const config = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(config);
    const dir = std.fs.path.dirname(config) orelse return error.NoDirectory;
    return try std.fs.path.join(alloc, &.{ dir, last_session_name });
}

/// The session that was last shown. The caller owns it.
pub fn lastSession(self: *App) !?[]u8 {
    const alloc = self.core_app.alloc;
    const path = self.lastSessionPath() catch return null;
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(
        global.io(),
        path,
        alloc,
        .limited(max_last_session),
    ) catch null;
}

pub fn setLastSession(self: *App, id: []const u8) void {
    self.writeLastSession(id) catch |err|
        log.info("error remembering the session err={}", .{err});
}

fn writeLastSession(self: *App, id: []const u8) !void {
    const path = try self.lastSessionPath();
    defer self.core_app.alloc.free(path);
    const io = global.io();
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [max_last_session]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(id);
    try writer.interface.flush();
}

/// A frame of animation.
fn tick(self: *App) void {
    self.ticker.handled();
    var more = false;
    for (self.windows.items) |window| {
        if (window.frame()) more = true;
    }
    if (!more) self.ticker.stop();
}

/// How things move at the moment.
pub fn motionStyle(self: *const App) motion.Style {
    return if (self.animations) self.config.@"win32-animation" else .off;
}

/// How windows look, unless they've been made to look otherwise.
pub fn look(self: *const App) glass.Look {
    if (!self.config.@"win32-glass") return .off;
    return if (self.blur_unavailable == null) .frost else .solid;
}

fn readSystem(self: *App) void {
    self.blur_unavailable = glass.unavailable();
    self.high_contrast = glass.highContrast();
    var animations: c.BOOL = 1;
    _ = c.SystemParametersInfoW(c.SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
    self.animations = animations != 0;
}

/// Called when a setting of Windows may have changed. Every window is told of
/// that, so usually nothing has.
pub fn systemChanged(self: *App) void {
    const before = .{ self.look(), self.high_contrast };
    self.readSystem();
    if (self.look() == before[0] and self.high_contrast == before[1]) return;
    if (self.look() != before[0]) self.logGlass();
    for (self.windows.items) |window| window.lookChanged();
}

fn logGlass(self: *App) void {
    const config = &self.config;
    if (!config.@"win32-glass") return;
    if (self.blur_unavailable) |why| log.info("glass is solid because {s}", .{why});

    if (self.noted_glass) return;
    const blur = switch (config.@"background-blur") {
        .false => false,
        .radius => |v| v > 0,
        else => true,
    };
    if (config.@"background-opacity" < 1 or blur) {
        self.noted_glass = true;
        log.info("background-opacity and background-blur are ignored because of win32-glass", .{});
    }
}

fn closeAll(self: *App) void {
    self.quitting = true;
    while (self.windows.items.len > 0) {
        const len = self.windows.items.len;
        self.windows.items[len - 1].destroy();

        // Destroying the window removes it. If it somehow didn't, don't spin.
        if (self.windows.items.len >= len) return;
    }
}

pub fn nextTabId(self: *App) u32 {
    self.last_tab_id += 1;
    return self.last_tab_id;
}

/// Ask the user to confirm something. Other messages are handled meanwhile.
pub fn confirm(
    self: *App,
    owner: ?c.HWND,
    title: [*:0]const u16,
    text: [*:0]const u16,
) bool {
    self.modal += 1;
    const result = c.MessageBoxW(owner, text, title, c.MB_OKCANCEL | c.MB_ICONWARNING);
    self.modal -= 1;
    self.modalClosed();
    return result == c.IDOK;
}

fn modalClosed(self: *App) void {
    // Surfaces that wanted to close can, now.
    if (self.modal == 0) for (self.core_app.surfaces.items) |surface| {
        if (!surface.close_pending) continue;
        surface.close_pending = false;
        surface.close(false);
    };
}

pub fn colorSchemeChanged(self: *App) !void {
    const scheme = systemColorScheme();
    try self.core_app.colorSchemeEvent(self, scheme);
    for (self.core_app.surfaces.items) |surface| {
        try surface.core_surface.colorSchemeCallback(scheme);
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

        .new_window => try self.openWindow(.new),

        .new_tab => {
            const v = surface orelse {
                try self.openWindow(.new);
                return true;
            };
            try v.window.openTab();
        },
        .close_tab => return (surface orelse return false).window.requestCloseTab(surface.?, value),
        .goto_tab => return (surface orelse return false).window.gotoTab(value),
        .move_tab => return (surface orelse return false).window.moveTab(surface.?, value.amount),
        .move_tab_to_new_window => return try (surface orelse return false).window.moveTabToNewWindow(surface.?),
        .new_split => return try (surface orelse return false).window.newSplit(surface.?, value),
        .goto_split => return try (surface orelse return false).window.gotoSplit(surface.?, value),
        .resize_split => return try (surface orelse return false).window.resizeSplit(surface.?, value),
        .equalize_splits => return try (surface orelse return false).window.equalizeSplits(surface.?),
        .toggle_split_zoom => return (surface orelse return false).window.toggleZoom(surface.?),
        .goto_window => return self.gotoWindow(surface orelse return false, value),

        .scrollbar => (surface orelse return false).setScrollbar(value),

        .start_search => {
            const v = surface orelse return false;
            if (v.search == null) v.search = try SearchBar.create(v);
            v.search.?.show(value.needle);
        },
        .end_search => if ((surface orelse return false).search) |v| v.hide(),
        .search_total => if ((surface orelse return false).search) |v| v.setTotal(value.total),
        .search_selected => if ((surface orelse return false).search) |v| v.setSelected(value.selected),

        .toggle_command_palette => {
            const window = (surface orelse return false).window;
            if (window.palette == null) window.palette = try CommandPalette.create(window);
            window.palette.?.toggle();
        },

        .inspector => {
            const v = surface orelse return false;
            const show = switch (value) {
                .toggle => v.inspector == null,
                .show => true,
                .hide => false,
            };
            if (show == (v.inspector != null)) return false;
            if (show) {
                v.inspector = try InspectorWindow.create(v);
            } else {
                // Deferred, the inspector may be what we're being called from.
                v.inspector.?.close();
            }
        },
        .render_inspector => if ((surface orelse return false).inspector) |v| v.queueRender(),

        .close_window => _ = c.PostMessageW(
            (surface orelse return false).window.hwnd,
            c.WM_CLOSE,
            0,
            0,
        ),

        .close_all_windows => for (self.windows.items) |v| {
            _ = c.PostMessageW(v.hwnd, c.WM_CLOSE, 0, 0);
        },

        .reload_config => try self.reloadConfig(value.soft),
        .open_config => return try self.openConfig(),
        .open_url => return try self.openUrl(value),

        .set_title => try (surface orelse return false).setTitle(value.title),
        .set_tab_title => return try (surface orelse return false).window.setTabTitle(surface.?, value.title),
        .set_window_title => try (surface orelse return false).window.setWindowTitle(value.title),
        .toggle_fullscreen => (surface orelse return false).window.toggleFullscreen(),
        .toggle_background_opacity => return (surface orelse return false).window.toggleOpacity(),
        .toggle_side_panel => return (surface orelse return false).window.togglePanel(),
        .toggle_maximize => (surface orelse return false).window.toggleMaximize(),
        .mouse_shape => (surface orelse return false).setMouseShape(value),
        .mouse_visibility => (surface orelse return false).setMouseVisible(value == .visible),
        .initial_size => (surface orelse return false).window.setSurfaceSize(surface.?, value.width, value.height),
        .size_limit => (surface orelse return false).window.size_limit = value,
        .present_terminal => (surface orelse return false).window.present(surface.?),
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

fn gotoWindow(self: *App, from: *Surface, to: apprt.action.GotoWindow) bool {
    const len = self.windows.items.len;
    if (len < 2) return false;
    const index = std.mem.indexOfScalar(*Window, self.windows.items, from.window) orelse return false;
    const window = self.windows.items[
        switch (to) {
            .next => (index + 1) % len,
            .previous => (index + len - 1) % len,
        }
    ];
    window.present(window.activeSurface() orelse return false);
    return true;
}

fn reloadConfig(self: *App, soft: bool) !void {
    if (!soft) {
        const config = try Config.load(self.core_app.alloc);
        self.config.deinit();
        self.config = config;
        self.logGlass();
    }
    try self.applyConfig();
}

fn applyConfig(self: *App) !void {
    try self.core_app.updateConfig(self, &self.config);
    for (self.windows.items) |window| window.configChanged();
}

/// Show a theme without saving it, or go back to the configured one.
pub fn previewTheme(self: *App, name: ?[]const u8) !void {
    const alloc = self.core_app.alloc;
    const config = if (name) |v| try themes.loadConfig(alloc, v) else try Config.load(alloc);
    self.config.deinit();
    self.config = config;
    try self.applyConfig();
}

/// Save a theme to the configuration, and use it. An empty name is none.
pub fn setTheme(self: *App, name: []const u8) !void {
    try themes.save(self.core_app.alloc, name);
    try self.previewTheme(null);
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
