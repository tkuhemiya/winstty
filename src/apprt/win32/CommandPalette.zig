//! The command palette of a window: a search field above a list of commands.
//!
//! It's an owned popup rather than a child, because the app may be composited
//! with per-pixel alpha, which a child can't opt out of. The popup is created
//! the first time it's opened and then only hidden and shown, so closing it
//! never destroys a window from inside one of its own callbacks. The list is
//! painted by hand, as a native list box can't show the keybinds or the
//! hover state we want.
//!
//! Commands are copied when the palette opens. The config can be reloaded
//! while it's open, and an action may do exactly that.
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const input = @import("../../input.zig");
const Fade = @import("Fade.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");
const glass = @import("glass.zig");
const paint = @import("paint.zig");
const rex = @import("../../rex/main.zig");
const themes = @import("themes.zig");

const log = std.log.scoped(.win32);

const class_name = c.L("GhosttyPalette");

// 96 DPI lengths.
const palette_width = 560;
const palette_max_height = 400;
const palette_top = 60;
const palette_margin = 16;
const input_height = 46;
const edit_height = 24;
const padding = 16;
const row_height = 34;
const footer_height = 28;
const scrollbar_width = 4;
const swatch_size = 10;

/// Previews wait for the selection to rest, since each reloads the config.
const preview_timer = 1;
const preview_ms = 90;

const fade_timer = 2;

/// What the list is of.
const Mode = enum {
    commands,
    themes,
    shells,
    sessions,
    // These are of nothing, and what's typed is a name.
    rename_session,
    rename_tab,

    fn isName(self: Mode) bool {
        return switch (self) {
            .commands, .themes, .shells, .sessions => false,
            .rename_session, .rename_tab => true,
        };
    }
};

/// What a row shows, and what's searched.
pub const Item = struct {
    kind: Kind = .action,
    title: []const u8,
    description: []const u8,
    action: input.Binding.Action,
    /// The action in the syntax of the config. Users know actions by this
    /// name from `keybind`, so it's searchable as well as the title.
    action_text: []const u8,
    /// Empty if the action isn't bound.
    keybind: []const u8,

    /// The file of a theme, and its colors once it has been in view.
    path: []const u8 = "",
    swatch: union(enum) { unknown, none, some: themes.Swatch } = .unknown,

    /// What the programs of a session are doing.
    state: rex.status.State = .idle,

    const Kind = enum {
        action,
        /// Lists the themes.
        themes,
        /// The theme named by the title.
        theme,
        /// No theme.
        default_theme,
        /// Lists the shells.
        shells,
        /// A new tab running the command in `path`.
        shell,
        /// Lists the sessions.
        sessions,
        /// The session in `path`.
        session,
        new_session,
        /// Another window on the session.
        session_window,
        rename_session,
        rename_tab,
        destroy_session,
    };

    fn themeName(self: Item) ?[]const u8 {
        return switch (self.kind) {
            .theme => self.title,
            .default_theme => "",
            else => null,
        };
    }
};

/// The items of an open palette, and the memory they point to.
const Loaded = struct {
    arena: ArenaAllocator,
    items: []Item,
};

/// The original procedure of the EDIT class, which every subclassed field
/// shares.
var edit_proc: ?c.WNDPROC = null;

window: *Window,

/// The popup and its search field. Null until first opened, and after either
/// is destroyed.
hwnd: ?c.HWND = null,
edit: ?c.HWND = null,

edit_font: ?c.HFONT = null,
list_font: ?c.HFONT = null,
/// Background of the search field.
brush: ?c.HGDIOBJ = null,
colors: paint.Palette = undefined,
dpi: u32 = 96,

fade: Fade = .{ .timer = fade_timer },

/// True from showing until closing starts.
open: bool = false,
/// Set while closing, as hiding the popup deactivates it.
closing: bool = false,
/// Set once our window is going away.
destroying: bool = false,

mode: Mode = .commands,

/// Whether the theme in use is a preview, to be undone if it isn't chosen.
previewing: bool = false,

loaded: ?Loaded = null,
/// Indices of the items matching the query, best first.
shown: std.ArrayList(u32) = .empty,
/// Position in `shown`.
selected: usize = 0,
/// Pixels scrolled off the top of the list.
scroll: c_int = 0,
hover: ?usize = null,
/// The row a mouse button went down on.
pressed: ?usize = null,
tracking_leave: bool = false,

pub fn register(hinstance: c.HINSTANCE) !void {
    if (c.RegisterClassExW(&.{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .lpszClassName = class_name,
    }) == 0) return error.Win32Failed;
}

pub fn create(window: *Window) !*CommandPalette {
    const self = try window.app.core_app.alloc.create(CommandPalette);
    self.* = .{ .window = window };
    return self;
}

/// Called when the window is destroyed. Our popup is owned by the window, so
/// it may already be gone, or it may still be there.
pub fn destroy(self: *CommandPalette) void {
    const alloc = self.window.app.core_app.alloc;
    self.destroying = true;
    self.window.palette = null;
    if (!self.window.app.quitting) self.endPreview();
    if (self.hwnd) |v| _ = c.DestroyWindow(v);
    self.unload();
    self.shown.deinit(alloc);
    if (self.edit_font) |v| _ = c.DeleteObject(v);
    if (self.list_font) |v| _ = c.DeleteObject(v);
    if (self.brush) |v| _ = c.DeleteObject(v);
    alloc.destroy(self);
}

pub fn toggle(self: *CommandPalette) void {
    if (self.destroying) return;
    if (self.open) return self.close();
    self.show() catch |err| {
        log.warn("error opening command palette err={}", .{err});
        self.close();
    };
}

/// Called when the window moved or changed size.
pub fn reposition(self: *CommandPalette) void {
    if (!self.open or self.destroying) return;
    const hwnd = self.hwnd orelse return;
    if (c.IsIconic(self.window.hwnd) != 0) return;

    if (self.window.getDpi() != self.dpi) self.updateFonts();
    const rect = self.placement();
    _ = c.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

/// Whether a command can be run from the palette. The palette lists every
/// entry of `command-palette-entry`, many of which only exist on another
/// platform or aren't implemented here.
pub fn supported(action: input.Binding.Action) bool {
    return switch (action) {
        // What the GTK palette leaves out.
        .close_all_windows,
        .toggle_secure_input,
        .check_for_updates,
        .redo,
        .undo,
        .reset_window_size,
        .toggle_window_float_on_top,
        => false,

        // Not available on Windows, or not implemented by this runtime.
        .show_gtk_inspector,
        .toggle_quick_terminal,
        .toggle_tab_overview,
        .show_on_screen_keyboard,
        .toggle_visibility,
        .prompt_surface_title,
        .prompt_tab_title,
        .prompt_window_title,
        .toggle_window_decorations,
        .crash,
        => false,

        // Anything for another toolkit or platform.
        else => std.mem.indexOf(u8, @tagName(action), "gtk") == null and
            std.mem.indexOf(u8, @tagName(action), "macos") == null,
    };
}

//---------------------------------------------------------------
// Opening, closing and running

fn show(self: *CommandPalette) !void {
    try self.ensureWindow();
    const hwnd = self.hwnd.?;
    const edit = self.edit.?;

    self.updateColors();
    self.updateFonts();
    try self.setMode(.commands);

    self.open = true;
    const rect = self.placement();
    _ = c.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
    self.relayoutEdit();

    self.fade.fadeIn(hwnd, self.window.animates());

    // Showing a popup activates it. That's only wanted if our window has the
    // activation, as otherwise we'd steal it from whatever else has it.
    if (c.GetActiveWindow() == self.window.hwnd) {
        _ = c.ShowWindow(hwnd, c.SW_SHOW);
        _ = c.SetFocus(edit);
    } else {
        _ = c.ShowWindow(hwnd, c.SW_SHOWNA);
    }
}

fn updateColors(self: *CommandPalette) void {
    self.colors = .init(&self.window.app.config);
    if (self.brush) |v| _ = c.DeleteObject(v);
    self.brush = c.CreateSolidBrush(self.colors.bar.ref());
    const look = self.window.look();
    if (self.hwnd) |v| glass.setPopupBacking(v, look, self.colors);
    if (self.edit) |v| {
        glass.setControlBacking(v, look, self.colors.bar);
        _ = c.InvalidateRect(v, null, 1);
    }
    self.invalidate();
}

/// Called when what the window is made of has changed.
pub fn lookChanged(self: *CommandPalette) void {
    if (self.open) self.updateColors();
}

/// Start over with a list of something.
fn setMode(self: *CommandPalette, mode: Mode) !void {
    const edit = self.edit orelse return;

    // The field notifies us of the change, which we ignore without items.
    self.unload();
    _ = c.SetWindowTextW(edit, c.L(""));
    const hint: [*:0]const u16 = switch (mode) {
        .commands => c.L("Execute a command..."),
        .themes => c.L("Choose a theme..."),
        .shells => c.L("Choose a shell..."),
        .sessions => c.L("Choose a session..."),
        .rename_session => c.L("Name of the session..."),
        .rename_tab => c.L("Title of the tab..."),
    };
    _ = c.SendMessageW(edit, c.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(hint)));
    self.mode = mode;
    self.hover = null;
    self.pressed = null;
    switch (mode) {
        .commands => {
            try self.load();
            try self.refilter();
        },
        .themes => {
            try self.loadThemes();
            try self.refilter();
            self.selectCurrentTheme();
        },
        .shells => {
            try self.loadShells();
            try self.refilter();
        },
        .sessions => {
            try self.loadSessions();
            try self.refilter();
        },
        .rename_session, .rename_tab => {
            self.shown.clearRetainingCapacity();
            try self.setName();
            self.invalidate();
        },
    }
}

/// Start out with the name there is.
fn setName(self: *CommandPalette) !void {
    const edit = self.edit orelse return;
    const session = self.window.session orelse return;
    const tab = self.window.activeTab() orelse return;
    const name = switch (self.mode) {
        .rename_session => session.label,
        .rename_tab => tab.title(),
        else => return,
    };
    const alloc = self.window.app.core_app.alloc;
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, name);
    defer alloc.free(wide);
    _ = c.SetWindowTextW(edit, wide);
    _ = c.SendMessageW(edit, c.EM_SETSEL, 0, -1);
}

/// Use what was typed as a name.
fn rename(self: *CommandPalette) void {
    var utf8: [768]u8 = undefined;
    const name = std.mem.trim(u8, self.queryText(&utf8), " ");
    const window = self.window;
    if (window.session) |session| switch (self.mode) {
        .rename_session => session.setLabel(name),
        .rename_tab => if (window.activeTab()) |tab| session.setTabLabel(tab.rex_id, name),
        else => {},
    };
    self.close();
}

/// Called when the sessions, or what programs in them are doing, have changed.
pub fn sessionsChanged(self: *CommandPalette) void {
    if (!self.open or self.mode != .sessions) return;
    const selected = self.selected;
    self.unload();
    self.loadSessions() catch return;
    self.refilter() catch return;
    if (selected < self.shown.items.len) self.select(selected);
}

fn loadSessions(self: *CommandPalette) !void {
    const session = self.window.session orelse return;
    var arena: ArenaAllocator = .init(self.window.app.core_app.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var items: std.ArrayList(Item) = .empty;
    for (session.peers.items) |peer| {
        const summary = peer.summary();
        const here = std.mem.eql(u8, peer.id, session.id);
        const does: []const u8 = switch (summary.state) {
            .idle => if (here) "Shown here." else "Enter to show it here.",
            .working => "Working.",
            .done => "Done.",
            .@"error" => "Failed.",
            .blocked => "Needs you.",
        };
        try items.append(alloc, .{
            .kind = .session,
            .title = try std.fmt.allocPrint(alloc, "{s}{s}", .{
                peer.label,
                if (here) " (shown here)" else "",
            }),
            .description = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
                does,
                if (summary.text.len > 0) " " else "",
                summary.text,
            }),
            .action = .ignore,
            .action_text = "",
            .keybind = "",
            .path = try alloc.dupe(u8, peer.id),
            .state = summary.state,
        });
    }
    self.loaded = .{ .arena = arena, .items = items.items };
}

fn selectCurrentTheme(self: *CommandPalette) void {
    const loaded = self.loaded orelse return;
    const theme = self.window.app.config.theme orelse return;
    const name = switch (self.window.app.core_app.config_conditional_state.theme) {
        .light => theme.light,
        .dark => theme.dark,
    };
    for (self.shown.items, 0..) |index, i| {
        if (!std.ascii.eqlIgnoreCase(loaded.items[index].title, name)) continue;
        self.select(i);
        break;
    }

    // It's in use already.
    self.stopPreviewTimer();
}

/// Preview the selected theme, soon.
fn schedulePreview(self: *CommandPalette) void {
    if (self.mode != .themes or !self.open) return;
    const hwnd = self.hwnd orelse return;
    _ = c.SetTimer(hwnd, preview_timer, preview_ms, null);
}

fn stopPreviewTimer(self: *CommandPalette) void {
    if (self.hwnd) |v| _ = c.KillTimer(v, preview_timer);
}

fn preview(self: *CommandPalette) void {
    self.stopPreviewTimer();
    if (self.mode != .themes) return;
    const loaded = self.loaded orelse return;
    if (self.selected >= self.shown.items.len) return;
    const name = loaded.items[self.shown.items[self.selected]].themeName() orelse return;
    self.previewing = true;
    self.window.app.previewTheme(name) catch |err|
        log.warn("error previewing theme err={}", .{err});
    self.updateColors();
}

/// Go back to the configured theme.
fn endPreview(self: *CommandPalette) void {
    self.stopPreviewTimer();
    if (!self.previewing) return;
    self.previewing = false;
    self.window.app.previewTheme(null) catch |err|
        log.warn("error restoring theme err={}", .{err});
}

fn close(self: *CommandPalette) void {
    if (!self.open or self.closing) return;
    self.closing = true;
    defer self.closing = false;

    // Hiding the popup usually activates our window, but not always, and then
    // the focus would stay with the hidden field.
    const active = self.hwnd != null and c.GetActiveWindow() == self.hwnd;
    self.open = false;
    self.endPreview();

    // The list is still there while it fades, unless something in it was run.
    const fades = self.loaded != null and !self.destroying and self.window.animates();
    if (self.hwnd) |v| self.fade.fadeOut(v, fades);
    if (!fades) self.unload();
    if (self.destroying) return;
    if (active) _ = c.SetActiveWindow(self.window.hwnd);
    self.window.focusActive();
}

/// Run the selected command.
fn run(self: *CommandPalette) void {
    if (self.mode.isName()) return self.rename();
    const loaded = self.loaded orelse return;
    if (self.selected >= self.shown.items.len) return;
    const item = loaded.items[self.shown.items[self.selected]];
    switch (item.kind) {
        .action => {},
        .themes => {
            self.setMode(.themes) catch |err| log.warn("error listing themes err={}", .{err});
            return;
        },
        .shells => {
            self.setMode(.shells) catch |err| log.warn("error listing shells err={}", .{err});
            return;
        },
        .shell => {
            const window = self.window;
            const command = alloc_dup: {
                const gpa = window.app.core_app.alloc;
                break :alloc_dup gpa.dupe(u8, item.path) catch return;
            };
            defer window.app.core_app.alloc.free(command);
            window.app.setShell(command) catch |err|
                log.warn("error remembering shell err={}", .{err});
            self.close();
            if (window.activeSurface()) |surface| {
                window.replaceSurface(surface, command) catch |err|
                    log.warn("error changing shell command={s} err={}", .{ command, err });
            } else {
                _ = window.newTabWith(.tab, command) catch |err|
                    log.warn("error opening shell command={s} err={}", .{ command, err });
            }
            return;
        },
        .sessions, .rename_session, .rename_tab => {
            self.setMode(switch (item.kind) {
                .sessions => .sessions,
                .rename_session => .rename_session,
                else => .rename_tab,
            }) catch |err| log.warn("error listing err={}", .{err});
            return;
        },
        .session, .new_session, .session_window, .destroy_session => {
            const window = self.window;
            const alloc = window.app.core_app.alloc;
            const id = alloc.dupe(u8, item.path) catch return;
            defer alloc.free(id);
            const kind = item.kind;
            self.close();
            const session = window.session orelse return;
            switch (kind) {
                .session => session.switchTo(id),
                .new_session => session.switchToNew(),
                .session_window => window.app.openWindow(.{ .id = session.id }) catch |err|
                    log.warn("error opening a window err={}", .{err}),
                else => if (window.app.confirm(
                    window.hwnd,
                    c.L("Destroy session?"),
                    c.L("Every program in the session will be terminated."),
                )) if (window.session) |v| v.destroySession(),
            }
            return;
        },
        .theme, .default_theme => {
            // It's no longer a preview, so closing won't undo it.
            self.stopPreviewTimer();
            self.previewing = false;
            self.window.app.setTheme(item.themeName().?) catch |err|
                log.warn("error setting theme err={}", .{err});
            self.close();
            return;
        },
    }
    const action = item.action;
    const window = self.window;

    // The action points to our items, so they must outlive the call. Taking
    // them out of `self` lets an action that opens the palette again build
    // its own. Nothing is destroyed from inside the call, closing is posted,
    // so `window` is still valid after it.
    self.loaded = null;
    defer loaded.arena.deinit();
    self.close();

    const surface = window.activeSurface() orelse return;
    _ = surface.core_surface.performBindingAction(action) catch |err|
        log.warn("error running palette command action={t} err={}", .{ action, err });
}

fn ensureWindow(self: *CommandPalette) !void {
    if (self.hwnd != null) return;
    const hinstance = self.window.app.hinstance;

    self.dpi = self.window.getDpi();
    const rect = self.placement();
    const hwnd = c.CreateWindowExW(
        c.WS_EX_TOOLWINDOW,
        class_name,
        c.L("Command Palette"),
        c.WS_POPUP | c.WS_CLIPCHILDREN,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        self.window.hwnd,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Failed;
    // Destroying it clears our fields.
    errdefer _ = c.DestroyWindow(hwnd);
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.hwnd = hwnd;

    const round: u32 = c.DWMWCP_ROUND;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &round, @sizeOf(u32));

    const edit = c.CreateWindowExW(
        0,
        c.L("EDIT"),
        c.L(""),
        c.WS_CHILD | c.WS_VISIBLE | c.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Failed;
    _ = c.SetWindowLongPtrW(edit, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    const previous = c.SetWindowLongPtrW(edit, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&editWndProc)));
    if (edit_proc == null) edit_proc = @ptrFromInt(@as(usize, @bitCast(previous)));
    _ = c.SendMessageW(edit, c.EM_SETLIMITTEXT, 256, 0);
    _ = c.SendMessageW(edit, c.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(c.L("Execute a command..."))));
    self.edit = edit;
    self.relayoutEdit();
}

fn updateFonts(self: *CommandPalette) void {
    self.dpi = self.window.getDpi();
    if (self.edit_font) |v| _ = c.DeleteObject(v);
    if (self.list_font) |v| _ = c.DeleteObject(v);
    self.edit_font = paint.uiFont(13, self.dpi);
    self.list_font = paint.uiFont(10, self.dpi);
    if (self.edit) |v| {
        _ = c.SendMessageW(v, c.WM_SETFONT, if (self.edit_font) |f| @intFromPtr(f) else 0, 1);
    }
}

fn sessionItem(kind: Item.Kind, title: []const u8, description: []const u8) Item {
    return .{
        .kind = kind,
        .title = title,
        .description = description,
        .action = .ignore,
        .action_text = "rex session",
        .keybind = "",
    };
}

/// For windows on a session.
const session_items = [_]Item{
    sessionItem(.sessions, "Switch Session...", "Show another session of the Rex server here."),
    sessionItem(.new_session, "New Session", "Show a new session here. This one keeps running."),
    sessionItem(.session_window, "New Window on This Session", "Show this session in another window as well."),
    sessionItem(.rename_session, "Rename Session...", "Change the name of this session."),
    sessionItem(.rename_tab, "Rename Tab...", "Change the title of this tab. Leave it empty for that of the program."),
    sessionItem(.destroy_session, "Destroy Session...", "End every program in this session."),
};

/// Copy the commands, so they stay valid while we're open.
fn load(self: *CommandPalette) !void {
    var arena: ArenaAllocator = .init(self.window.app.core_app.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const config = &self.window.app.config;
    const entries = config.@"command-palette-entry".value.items;
    var items: std.ArrayList(Item) = try .initCapacity(alloc, entries.len + 2 + session_items.len);
    if (self.window.session != null) for (session_items) |v| items.appendAssumeCapacity(v);
    items.appendAssumeCapacity(.{
        .kind = .shells,
        .title = "Change Shell...",
        .description = "Switch this pane, and new ones, to PowerShell, cmd, WSL or another shell.",
        .action = .ignore,
        .action_text = "shell",
        .keybind = "",
    });
    items.appendAssumeCapacity(.{
        .kind = .themes,
        .title = "Change Theme...",
        .description = "Preview and choose a color theme.",
        .action = .ignore,
        .action_text = "theme",
        .keybind = "",
    });
    for (entries) |entry| {
        if (!supported(entry.action)) continue;
        const command = try entry.clone(alloc);

        var action_text: std.Io.Writer.Allocating = .init(alloc);
        command.action.format(&action_text.writer) catch return error.OutOfMemory;

        var keybind: std.Io.Writer.Allocating = .init(alloc);
        if (config.keybind.set.getTrigger(command.action)) |trigger| {
            formatTrigger(&keybind.writer, trigger) catch return error.OutOfMemory;
        }

        items.appendAssumeCapacity(.{
            .title = command.title,
            .description = command.description,
            .action = command.action,
            .action_text = action_text.written(),
            .keybind = keybind.written(),
        });
    }

    self.loaded = .{ .arena = arena, .items = items.items };
}

fn addShell(
    alloc: std.mem.Allocator,
    items: *std.ArrayList(Item),
    title: []const u8,
    description: []const u8,
    command: []const u8,
) !void {
    try items.append(alloc, .{
        .kind = .shell,
        .title = title,
        .description = description,
        .action = .ignore,
        .action_text = "",
        .keybind = "",
        .path = command,
    });
}

/// The shells we can offer: the usual Windows ones, Git Bash if it's there,
/// and every WSL distribution, which we read from the registry rather than
/// starting `wsl.exe`.
fn loadShells(self: *CommandPalette) !void {
    var arena: ArenaAllocator = .init(self.window.app.core_app.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var items: std.ArrayList(Item) = .empty;
    const desc = "Enter to use it here and in new tabs and splits.";
    try addShell(alloc, &items, "PowerShell 7", desc, "pwsh.exe -NoLogo");
    try addShell(alloc, &items, "Windows PowerShell", desc, "powershell.exe -NoLogo");
    try addShell(alloc, &items, "Command Prompt", desc, "cmd.exe");

    const git_bash = "C:\\Program Files\\Git\\bin\\bash.exe";
    if (c.GetFileAttributesW(c.L(git_bash)) != 0xFFFFFFFF) {
        try addShell(alloc, &items, "Git Bash", desc, "\"" ++ git_bash ++ "\" --login -i");
    }

    try addShell(alloc, &items, "WSL", "The default WSL distribution.", "wsl.exe");

    const lxss = c.L("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss");
    var root: ?*anyopaque = null;
    if (c.RegOpenKeyExW(c.HKEY_CURRENT_USER, lxss, 0, c.KEY_READ, &root) == 0) {
        defer _ = c.RegCloseKey(root.?);
        var index: u32 = 0;
        while (index < 64) : (index += 1) {
            var guid: [128:0]u16 = undefined;
            var guid_len: u32 = guid.len;
            if (c.RegEnumKeyExW(root.?, index, &guid, &guid_len, null, null, null, null) != 0) break;
            guid[guid_len] = 0;

            var path: [320:0]u16 = undefined;
            var n: usize = 0;
            for (lxss) |ch| {
                path[n] = ch;
                n += 1;
            }
            path[n] = '\\';
            n += 1;
            for (guid[0..guid_len]) |ch| {
                path[n] = ch;
                n += 1;
            }
            path[n] = 0;

            var name: [256:0]u16 = undefined;
            var size: u32 = @sizeOf(@TypeOf(name)) - 2;
            if (c.RegGetValueW(
                c.HKEY_CURRENT_USER,
                &path,
                c.L("DistributionName"),
                c.RRF_RT_REG_SZ,
                null,
                &name,
                &size,
            ) != 0) continue;
            const name16 = std.mem.sliceTo(&name, 0);
            const name8 = std.unicode.utf16LeToUtf8Alloc(alloc, name16) catch continue;
            // Docker's own distributions aren't for logging into.
            if (std.mem.startsWith(u8, name8, "docker-desktop")) continue;
            const title = try std.fmt.allocPrint(alloc, "WSL: {s}", .{name8});
            const command = try std.fmt.allocPrint(alloc, "wsl.exe -d {s}", .{name8});
            try addShell(alloc, &items, title, "A WSL distribution.", command);
        }
    }

    self.loaded = .{ .arena = arena, .items = items.items };
}

fn loadThemes(self: *CommandPalette) !void {
    var arena: ArenaAllocator = .init(self.window.app.core_app.alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    const found = try themes.list(alloc);
    var items: std.ArrayList(Item) = try .initCapacity(alloc, found.len + 1);
    items.appendAssumeCapacity(.{
        .kind = .default_theme,
        .title = "Default",
        .description = "The colors of Ghostty itself.",
        .action = .ignore,
        .action_text = "",
        .keybind = "",
    });
    for (found) |theme| items.appendAssumeCapacity(.{
        .kind = .theme,
        .title = theme.name,
        .description = "Enter to use this theme, Escape to go back to what you had.",
        .action = .ignore,
        .action_text = "",
        .keybind = "",
        .path = theme.path,
    });
    self.loaded = .{ .arena = arena, .items = items.items };
}

fn unload(self: *CommandPalette) void {
    if (self.loaded) |v| v.arena.deinit();
    self.loaded = null;
    self.shown.clearRetainingCapacity();
    self.selected = 0;
    self.scroll = 0;
}

/// Where the popup goes, in screen coordinates: centered near the top of the
/// client area of our window, or as much as fits.
fn placement(self: *const CommandPalette) c.RECT {
    const dpi = self.dpi;
    var client: c.RECT = .{};
    _ = c.GetClientRect(self.window.hwnd, &client);
    var origin: c.POINT = .{};
    _ = c.ClientToScreen(self.window.hwnd, &origin);

    // Where the terminal is, rather than all of the window.
    const content = self.window.contentRect();
    const room = content.right - content.left;

    const margin = paint.scale(palette_margin, dpi);
    const top = @min(paint.scale(palette_top, dpi), @divTrunc(client.bottom, 5));
    const width = @max(1, @min(paint.scale(palette_width, dpi), room - 2 * margin));
    // Room for the field and a row, even if the window has less.
    const min_height = paint.scale(input_height + footer_height + row_height, dpi);
    const height = @max(min_height, @min(
        paint.scale(palette_max_height, dpi),
        client.bottom - top - margin,
    ));

    const left = origin.x + content.left + @divTrunc(room - width, 2);
    return .{
        .left = left,
        .top = origin.y + top,
        .right = left + width,
        .bottom = origin.y + top + height,
    };
}

//---------------------------------------------------------------
// Layout and selection

const Layout = struct {
    width: c_int,
    height: c_int,
    pad: c_int,
    input_h: c_int,
    row_h: c_int,
    /// The list is from here, to the footer's divider.
    list_top: c_int,
    list_bottom: c_int,

    fn viewHeight(self: Layout) c_int {
        return self.list_bottom - self.list_top;
    }
};

fn layout(self: *const CommandPalette) Layout {
    var rect: c.RECT = .{};
    if (self.hwnd) |v| _ = c.GetClientRect(v, &rect);
    const input_h = paint.scale(input_height, self.dpi);
    const list_top = input_h + 1;
    return .{
        .width = rect.right,
        .height = rect.bottom,
        .pad = paint.scale(padding, self.dpi),
        .input_h = input_h,
        .row_h = paint.scale(row_height, self.dpi),
        .list_top = list_top,
        .list_bottom = @max(list_top, rect.bottom - paint.scale(footer_height, self.dpi) - 1),
    };
}

fn relayoutEdit(self: *CommandPalette) void {
    const edit = self.edit orelse return;
    const l = self.layout();
    const height = paint.scale(edit_height, self.dpi);
    _ = c.SetWindowPos(
        edit,
        null,
        l.pad,
        @divTrunc(l.input_h - height, 2),
        @max(1, l.width - 2 * l.pad),
        height,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    );
}

fn maxScroll(self: *const CommandPalette, l: Layout) c_int {
    const content: c_int = @intCast(self.shown.items.len * @as(usize, @intCast(l.row_h)));
    return @max(0, content - l.viewHeight());
}

fn setScroll(self: *CommandPalette, value: c_int) void {
    const l = self.layout();
    self.scroll = std.math.clamp(value, 0, self.maxScroll(l));
    self.updateHover();
    self.invalidate();
}

fn select(self: *CommandPalette, index: usize) void {
    if (self.shown.items.len == 0) return;
    self.selected = @min(index, self.shown.items.len - 1);

    // Keep the row in view.
    const l = self.layout();
    const top: c_int = @intCast(self.selected * @as(usize, @intCast(l.row_h)));
    if (top < self.scroll) {
        self.scroll = top;
    } else if (top + l.row_h > self.scroll + l.viewHeight()) {
        self.scroll = top + l.row_h - l.viewHeight();
    }
    self.scroll = std.math.clamp(self.scroll, 0, self.maxScroll(l));
    self.schedulePreview();
    self.invalidate();
}

fn pageSize(self: *const CommandPalette) usize {
    const l = self.layout();
    return @intCast(@max(1, @divTrunc(l.viewHeight(), l.row_h) - 1));
}

fn invalidate(self: *const CommandPalette) void {
    if (self.hwnd) |v| _ = c.InvalidateRect(v, null, 0);
}

/// The position in `shown` of the row at the point.
fn rowAt(self: *const CommandPalette, x: c_int, y: c_int) ?usize {
    const l = self.layout();
    if (x < 0 or x >= l.width or y < l.list_top or y >= l.list_bottom) return null;
    const row: usize = @intCast(@divTrunc(y - l.list_top + self.scroll, l.row_h));
    return if (row < self.shown.items.len) row else null;
}

/// Recompute the hovered row from the cursor, after the rows moved.
fn updateHover(self: *CommandPalette) void {
    const hwnd = self.hwnd orelse return;
    var pt: c.POINT = .{};
    _ = c.GetCursorPos(&pt);
    _ = c.ScreenToClient(hwnd, &pt);
    self.hover = self.rowAt(pt.x, pt.y);
}

fn onWheel(self: *CommandPalette, wparam: c.WPARAM) void {
    const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
    const l = self.layout();
    self.setScroll(self.scroll - @divTrunc(@as(c_int, delta) * l.row_h * 3, 240));
}

fn down(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

/// Returns whether the key was ours.
fn onKey(self: *CommandPalette, vk: usize) bool {
    const ctrl = down(c.VK_CONTROL);
    const alt = down(c.VK_MENU);
    const len = self.shown.items.len;
    if (self.isToggleKey(vk)) {
        self.close();
        return true;
    }
    switch (vk) {
        c.VK_UP => self.select(step(len, self.selected, false)),
        c.VK_DOWN => self.select(step(len, self.selected, true)),
        'N', 'P' => {
            if (!ctrl or alt or down(c.VK_SHIFT)) return false;
            self.select(step(len, self.selected, vk == 'N'));
        },
        c.VK_PRIOR => self.select(self.selected -| self.pageSize()),
        c.VK_NEXT => self.select(self.selected +| self.pageSize()),
        c.VK_HOME => {
            if (!ctrl) return false;
            self.select(0);
        },
        c.VK_END => {
            if (!ctrl) return false;
            self.select(len -| 1);
        },
        c.VK_RETURN => self.run(),
        c.VK_ESCAPE => self.close(),
        else => return false,
    }
    return true;
}

/// Whether this is the key that toggles the palette. The field sees keys
/// before any binding does, so it has to close us itself. Only letter and
/// digit triggers are known, which covers the default.
fn isToggleKey(self: *const CommandPalette, vk: usize) bool {
    const trigger = self.window.app.config.keybind.set.getTrigger(.toggle_command_palette) orelse return false;
    const mods = trigger.mods;
    if (mods.ctrl != down(c.VK_CONTROL) or
        mods.shift != down(c.VK_SHIFT) or
        mods.alt != down(c.VK_MENU) or
        mods.super != (down(c.VK_LWIN) or down(c.VK_RWIN))) return false;

    const ch: u8 = switch (trigger.key) {
        .unicode => |cp| if (cp < 128) std.ascii.toUpper(@intCast(cp)) else return false,
        .physical => |key| key: {
            const tag = @tagName(key);
            if (std.mem.startsWith(u8, tag, "key_")) break :key std.ascii.toUpper(tag[4]);
            if (std.mem.startsWith(u8, tag, "digit_")) break :key tag[6];
            return false;
        },
        .catch_all => return false,
    };
    return vk == ch;
}

/// Move a selection by one, wrapping around the ends.
fn step(len: usize, current: usize, forward: bool) usize {
    if (len == 0) return 0;
    if (forward) return if (current + 1 >= len) 0 else current + 1;
    return if (current == 0) len - 1 else current - 1;
}

/// Match the field's text again, after it changed.
fn refilter(self: *CommandPalette) !void {
    const loaded = self.loaded orelse return;
    var utf8: [768]u8 = undefined;
    const text = self.queryText(&utf8);
    try filter(self.window.app.core_app.alloc, loaded.items, text, &self.shown);
    self.selected = 0;
    self.scroll = 0;
    self.updateHover();
    self.schedulePreview();
    self.invalidate();
}

fn queryText(self: *const CommandPalette, buf: *[768]u8) []const u8 {
    const edit = self.edit orelse return "";
    var wide: [256]u16 = undefined;
    const len: usize = @intCast(@max(0, c.GetWindowTextW(edit, &wide, wide.len)));
    return buf[0..std.unicode.wtf16LeToWtf8(buf, wide[0..len])];
}

//---------------------------------------------------------------
// Painting

fn measure(buf: paint.Buffer, utf8: []const u8, font: ?c.HFONT) c_int {
    var wide: [128]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&wide, utf8[0..@min(utf8.len, 64)]) catch return 0;
    if (len == 0) return 0;
    const old = if (font) |v| c.SelectObject(buf.dc, v) else null;
    defer if (old) |v| {
        _ = c.SelectObject(buf.dc, v);
    };
    var rect: c.RECT = .{};
    _ = c.DrawTextW(buf.dc, &wide, @intCast(len), &rect, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    return rect.right;
}

fn onPaint(self: *CommandPalette) void {
    const hwnd = self.hwnd orelse return;
    var ps: c.PAINTSTRUCT = .{};
    const dc = c.BeginPaint(hwnd, &ps) orelse return;
    defer _ = c.EndPaint(hwnd, &ps);

    const l = self.layout();
    var buf = paint.Buffer.begin(dc, .{ .right = l.width, .bottom = l.height }) orelse return;
    defer buf.end();
    const colors = self.colors;
    const font = self.list_font;

    if (self.window.look() == .frost) buf.base(colors.bar, glass.popup_opacity);
    buf.surface(.{ .right = l.width, .bottom = l.height }, colors.bar);

    // Rows go first, as the ones scrolled partly out of view are covered by
    // the field and footer drawn over them.
    const items: []Item = if (self.loaded) |v| v.items else &.{};
    const row_h: usize = @intCast(l.row_h);
    const first: usize = @intCast(@divTrunc(self.scroll, l.row_h));
    const last = @min(self.shown.items.len, first + @as(usize, @intCast(@divTrunc(l.viewHeight(), l.row_h))) + 2);
    const inset = paint.scale(6, self.dpi);
    // The thumb has a gutter of its own, so it never sits on a row.
    const gutter = paint.scale(12, self.dpi);
    const right_edge = l.width - gutter - paint.scale(10, self.dpi);
    var index = first;
    while (index < last) : (index += 1) {
        const item = &items[self.shown.items[index]];
        const top = l.list_top - self.scroll + @as(c_int, @intCast(index * row_h));
        const row: c.RECT = .{ .left = inset, .top = top, .right = l.width - gutter, .bottom = top + l.row_h };
        if (index == self.selected) {
            buf.glass(.from(row), @floatFromInt(paint.scale(9, self.dpi)), colors.fg, 0.14);
        } else if (self.hover == index) {
            buf.round(.from(row), @floatFromInt(paint.scale(9, self.dpi)), colors.fg, 0.05);
        }

        var title_right = right_edge;
        if (item.keybind.len > 0) {
            const width = measure(buf, item.keybind, font);
            buf.text(item.keybind, .{
                .left = right_edge - width,
                .top = top,
                .right = right_edge,
                .bottom = top + l.row_h,
            }, font, colors.dim, c.DT_RIGHT);
            title_right -= width + l.pad;
        }
        if (item.state != .idle) {
            const size = paint.scale(18, self.dpi);
            const mark_top = top + @divTrunc(l.row_h - size, 2);
            buf.statusMark(.{
                .left = right_edge - size,
                .top = mark_top,
                .right = right_edge,
                .bottom = mark_top + size,
            }, switch (item.state) {
                .idle => .none,
                .working => .{ .working = .{ .progress = null, .spinner = null } },
                .blocked => .blocked,
                .done => .done,
                .@"error" => .@"error",
            }, colors.fg, colors.bar, 1);
            title_right -= size + l.pad;
        }
        if (item.kind == .theme) {
            if (item.swatch == .unknown) {
                const read = themes.Swatch.read(self.window.app.core_app.alloc, item.path);
                item.swatch = if (read) |v| .{ .some = v } else .none;
            }
            switch (item.swatch) {
                .unknown, .none => {},
                .some => |v| title_right = self.paintSwatch(buf, v, right_edge, top, l) - l.pad,
            }
        }
        buf.text(item.title, .{
            .left = l.pad,
            .top = top,
            .right = title_right,
            .bottom = top + l.row_h,
        }, font, colors.fg, c.DT_LEFT);
    }

    if (self.shown.items.len == 0) {
        buf.text(switch (self.mode) {
            .commands => "No matching commands",
            .themes => "No matching themes",
            .shells => "No matching shells",
            .sessions => "No matching sessions",
            .rename_session, .rename_tab => "Enter to rename",
        }, .{
            .left = 0,
            .top = l.list_top,
            .right = l.width,
            .bottom = l.list_bottom,
        }, font, colors.dim, c.DT_CENTER);
    }

    // The thumb of what's scrolled.
    const max = self.maxScroll(l);
    if (max > 0) {
        const view = l.viewHeight();
        const content = view + max;
        const thumb = @max(paint.scale(24, self.dpi), @divTrunc(view * view, content));
        const top = l.list_top + @divTrunc((view - thumb) * self.scroll, max);
        const width = paint.scale(scrollbar_width, self.dpi);
        buf.round(.from(.{
            .left = l.width - width - paint.scale(4, self.dpi),
            .top = top,
            .right = l.width - paint.scale(4, self.dpi),
            .bottom = top + thumb,
        }), @floatFromInt(width), colors.fg, 0.35);
    }

    // The field, with the footer showing what the selection does.
    buf.surface(.{ .right = l.width, .bottom = l.list_top }, colors.bar);
    buf.fill(.{ .top = l.input_h, .right = l.width, .bottom = l.list_top }, colors.divider);
    buf.surface(.{ .top = l.list_bottom, .right = l.width, .bottom = l.height }, colors.bar);
    buf.fill(.{ .top = l.list_bottom, .right = l.width, .bottom = l.list_bottom + 1 }, colors.divider);
    if (self.selected < self.shown.items.len) {
        const item = items[self.shown.items[self.selected]];
        buf.text(item.description, .{
            .left = l.pad,
            .top = l.list_bottom + 1,
            .right = l.width - l.pad,
            .bottom = l.height - 1,
        }, font, colors.dim, c.DT_LEFT);
    }

    // The border.
    buf.fill(.{ .right = l.width, .bottom = 1 }, colors.divider);
    buf.fill(.{ .top = l.height - 1, .right = l.width, .bottom = l.height }, colors.divider);
    buf.fill(.{ .right = 1, .bottom = l.height }, colors.divider);
    buf.fill(.{ .left = l.width - 1, .right = l.width, .bottom = l.height }, colors.divider);
}

/// The colors of a theme, on its background. Returns the left edge.
fn paintSwatch(
    self: *const CommandPalette,
    buf: paint.Buffer,
    swatch: themes.Swatch,
    right: c_int,
    top: c_int,
    l: Layout,
) c_int {
    const size = paint.scale(swatch_size, self.dpi);
    const gap = @divTrunc(size, 2);
    const count: c_int = swatch.colors.len + 1;
    const width = count * size + (count + 1) * gap;
    const height = size + gap * 2;
    const left = right - width;
    const pill: paint.Rect = .from(.{
        .left = left,
        .top = top + @divTrunc(l.row_h - height, 2),
        .right = right,
        .bottom = top + @divTrunc(l.row_h - height, 2) + height,
    });
    buf.round(pill, pill.h / 2, swatch.background, 1);
    buf.ring(pill, pill.h / 2, self.colors.fg, 0.22, 0.12);
    const all = [_]paint.Rgb{swatch.foreground} ++ swatch.colors;
    for (all, 0..) |color, i| {
        const x = left + gap + @as(c_int, @intCast(i)) * (size + gap);
        const dot: paint.Rect = .from(.{
            .left = x,
            .top = @as(c_int, @intFromFloat(pill.y)) + gap,
            .right = x + size,
            .bottom = @as(c_int, @intFromFloat(pill.y)) + gap + size,
        });
        buf.round(dot, dot.w / 2, color, 1);
    }
    return left;
}

//---------------------------------------------------------------
// Window procedures

fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *CommandPalette = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.message(hwnd, msg, wparam, lparam) catch |err| err: {
        log.warn("error handling palette message msg=0x{x} err={}", .{ msg, err });
        break :err 0;
    } orelse c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Returns null for default processing.
fn message(self: *CommandPalette, hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) !?c.LRESULT {
    const bits: usize = @bitCast(lparam);
    const x: c_int = @as(i16, @bitCast(@as(u16, @truncate(bits))));
    const y: c_int = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));

    // It's only shown until it has faded.
    if (!self.open) switch (msg) {
        c.WM_MOUSEMOVE, c.WM_LBUTTONDOWN, c.WM_LBUTTONUP, c.WM_MOUSEWHEEL, c.WM_COMMAND => return 0,
        else => {},
    };

    switch (msg) {
        c.WM_DESTROY => {
            // The field goes next, and mustn't call back in to us.
            if (self.edit) |v| _ = c.SetWindowLongPtrW(v, c.GWLP_USERDATA, 0);
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            self.hwnd = null;
            self.edit = null;
            self.open = false;
            self.unload();
        },

        // Losing the activation closes us, like any popup.
        c.WM_ACTIVATE => if (wparam & 0xFFFF == c.WA_INACTIVE) self.close(),

        c.WM_PAINT => self.onPaint(),
        c.WM_TIMER => switch (wparam) {
            preview_timer => self.preview(),
            fade_timer => if (self.fade.onTimer(hwnd) and !self.open) self.unload(),
            else => return null,
        },
        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => {
            self.relayoutEdit();
            self.setScroll(self.scroll);
        },

        c.WM_COMMAND => {
            const edit = self.edit orelse return null;
            if (wparam >> 16 == c.EN_CHANGE and lparam == @as(c.LPARAM, @bitCast(@intFromPtr(edit)))) {
                try self.refilter();
            }
        },

        c.WM_CTLCOLOREDIT => {
            const dc: c.HDC = @ptrFromInt(wparam);
            _ = c.SetTextColor(dc, self.colors.fg.ref());
            _ = c.SetBkColor(dc, self.colors.bar.ref());
            const brush = self.brush orelse return null;
            return @as(c.LRESULT, @bitCast(@intFromPtr(brush)));
        },

        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var track: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = hwnd };
                self.tracking_leave = c.TrackMouseEvent(&track) != 0;
            }
            const row = self.rowAt(x, y);
            if (row != self.hover) {
                self.hover = row;
                self.invalidate();
            }
        },
        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            self.hover = null;
            self.invalidate();
        },
        c.WM_LBUTTONDOWN => {
            if (self.edit) |v| _ = c.SetFocus(v);
            self.pressed = self.rowAt(x, y);
            if (self.pressed) |v| self.select(v);
        },
        c.WM_LBUTTONUP => {
            const pressed = self.pressed;
            self.pressed = null;
            if (pressed != null and pressed == self.rowAt(x, y)) self.run();
        },
        c.WM_MOUSEWHEEL => self.onWheel(wparam),

        else => return null,
    }
    return 0;
}

/// The search field, to give it the keys of a list.
fn editWndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const original = edit_proc orelse return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.CallWindowProcW(original, hwnd, msg, wparam, lparam);
    const self: *CommandPalette = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (!self.open or self.onKey(wparam)) return 0;

            // The message loop only translates keys that belong to an IME,
            // as the surfaces do it themselves. We have no use for that, so
            // the field has to be given its characters here.
            switch (wparam) {
                c.VK_PROCESSKEY, c.VK_PACKET => {},
                else => {
                    const translate: c.MSG = .{
                        .hwnd = hwnd,
                        .message = msg,
                        .wParam = wparam,
                        .lParam = lparam,
                        .time = 0,
                        .pt = .{},
                    };
                    _ = c.TranslateMessage(&translate);
                },
            }
        },

        // The keys we act on, and others that the field would show as a box.
        c.WM_CHAR => switch (wparam) {
            '\r', '\n', 0x1B, 0x0E, 0x10, 0x7F, '\t' => return 0,
            else => {},
        },

        c.WM_MOUSEWHEEL => {
            self.onWheel(wparam);
            return 0;
        },

        else => {},
    }
    return c.CallWindowProcW(original, hwnd, msg, wparam, lparam);
}

//---------------------------------------------------------------
// Matching

/// Find the items that match the query, best first.
///
/// Every word of the query must be in the title, or in the action's name.
/// Words are matched anywhere, ignoring ASCII case. Titles that start with the
/// first word come first, then those where every word starts a word of the
/// title, then the rest. Items of the same kind keep their order, and so does
/// everything if the query is empty.
pub fn filter(
    alloc: Allocator,
    items: []const Item,
    query: []const u8,
    out: *std.ArrayList(u32),
) Allocator.Error!void {
    out.clearRetainingCapacity();
    for (0..3) |wanted| {
        for (items, 0..) |item, i| {
            if (rank(item, query) == wanted) try out.append(alloc, @intCast(i));
        }
    }
}

/// Lower is better. Null if the item doesn't match.
fn rank(item: Item, query: []const u8) ?usize {
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    const first = words.peek() orelse return 0;

    var at_word_starts = true;
    while (words.next()) |word| {
        const in_title = std.ascii.findIgnoreCase(item.title, word) != null;
        if (!in_title and std.ascii.findIgnoreCase(item.action_text, word) == null) return null;
        if (!in_title or !startsWord(item.title, word)) at_word_starts = false;
    }

    if (std.ascii.startsWithIgnoreCase(item.title, first)) return 0;
    return if (at_word_starts) 1 else 2;
}

/// Whether the word is at the start of a word of the text.
fn startsWord(text: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, from, word)) |i| {
        if (i == 0 or !std.ascii.isAlphanumeric(text[i - 1])) return true;
        from = i + 1;
    }
    return false;
}

/// Write a trigger the way Windows shows shortcuts, such as `Ctrl+Shift+P`.
pub fn formatTrigger(writer: *std.Io.Writer, trigger: input.Binding.Trigger) std.Io.Writer.Error!void {
    if (trigger.mods.ctrl) try writer.writeAll("Ctrl+");
    if (trigger.mods.alt) try writer.writeAll("Alt+");
    if (trigger.mods.shift) try writer.writeAll("Shift+");
    if (trigger.mods.super) try writer.writeAll("Win+");

    switch (trigger.key) {
        .physical => |key| try formatKey(writer, key),
        .unicode => |cp| if (cp < 128) {
            try writer.writeByte(std.ascii.toUpper(@intCast(cp)));
        } else {
            try writer.print("{u}", .{cp});
        },
        .catch_all => try writer.writeAll("Any key"),
    }
}

fn formatKey(writer: *std.Io.Writer, key: input.Key) std.Io.Writer.Error!void {
    const name: ?[]const u8 = switch (key) {
        .arrow_up => "Up",
        .arrow_down => "Down",
        .arrow_left => "Left",
        .arrow_right => "Right",
        .escape => "Esc",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .delete => "Del",
        .insert => "Ins",
        .backquote => "`",
        .backslash => "\\",
        .bracket_left => "[",
        .bracket_right => "]",
        .comma => ",",
        .equal => "=",
        .minus => "-",
        .period => ".",
        .quote => "'",
        .semicolon => ";",
        .slash => "/",
        else => null,
    };
    if (name) |v| return writer.writeAll(v);

    // key_a is A and digit_1 is 1.
    const tag = @tagName(key);
    if (std.mem.startsWith(u8, tag, "key_")) return writer.writeByte(std.ascii.toUpper(tag[4]));
    if (std.mem.startsWith(u8, tag, "digit_")) return writer.writeAll(tag["digit_".len..]);

    // The rest read as words: numpad_add is Numpad Add, f5 is F5.
    var word_start = true;
    for (tag) |ch| {
        if (ch == '_') {
            try writer.writeByte(' ');
            word_start = true;
            continue;
        }
        try writer.writeByte(if (word_start) std.ascii.toUpper(ch) else ch);
        word_start = false;
    }
}

//---------------------------------------------------------------
// Tests

fn testItem(title: []const u8, action_text: []const u8) Item {
    return .{
        .title = title,
        .description = "",
        .action = .new_tab,
        .action_text = action_text,
        .keybind = "",
    };
}

fn expectFilter(items: []const Item, query: []const u8, expected: []const u32) !void {
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(std.testing.allocator);
    try filter(std.testing.allocator, items, query, &out);
    try std.testing.expectEqualSlices(u32, expected, out.items);
}

test "palette: empty query keeps the order" {
    const items = [_]Item{
        testItem("Zebra", "a"),
        testItem("Apple", "b"),
        testItem("Mango", "c"),
    };
    try expectFilter(&items, "", &.{ 0, 1, 2 });
    try expectFilter(&items, "  \t", &.{ 0, 1, 2 });
}

test "palette: every word must match" {
    const items = [_]Item{
        testItem("Split Right", "new_split:right"),
        testItem("Split Down", "new_split:down"),
        testItem("Close Tab", "close_tab:this"),
    };
    try expectFilter(&items, "split", &.{ 0, 1 });
    try expectFilter(&items, "split right", &.{0});
    try expectFilter(&items, "right split", &.{0});
    try expectFilter(&items, "  down   SPLIT ", &.{1});
    try expectFilter(&items, "split tab", &.{});
    try expectFilter(&items, "nothing", &.{});
}

test "palette: matching is case insensitive and also uses the action" {
    const items = [_]Item{
        testItem("Reload Configuration", "reload_config"),
        testItem("Open the file", "open_config:new_window"),
    };
    try expectFilter(&items, "RELOAD", &.{0});
    try expectFilter(&items, "config", &.{ 0, 1 });
    try expectFilter(&items, "open_config", &.{1});
    try expectFilter(&items, "file config", &.{1});
}

test "palette: prefix matches come first, then word starts, then the rest" {
    const items = [_]Item{
        testItem("Toggle Fullscreen", "toggle_fullscreen"), // inside a word
        testItem("Scroll to Bottom", "scroll_to_bottom"), // inside a word
        testItem("Open Tab", "x"), // word start
        testItem("Tab Overview", "y"), // prefix
        testItem("Reset Table", "z"), // word start
        testItem("Tab Bar", "w"), // prefix
    };
    try expectFilter(&items, "tab", &.{ 3, 5, 2, 4 });
    try expectFilter(&items, "ll", &.{ 0, 1 });
    // Words may be in any order for the word start rank.
    try expectFilter(&items, "ov tab", &.{3});
}

test "palette: ranking is stable" {
    const items = [_]Item{
        testItem("Beta Go", "a"),
        testItem("Go Alpha", "b"),
        testItem("Go Beta", "c"),
        testItem("Gamma Go", "d"),
    };
    try expectFilter(&items, "go", &.{ 1, 2, 0, 3 });
}

test "palette: step wraps" {
    try std.testing.expectEqual(@as(usize, 0), step(0, 0, true));
    try std.testing.expectEqual(@as(usize, 1), step(3, 0, true));
    try std.testing.expectEqual(@as(usize, 0), step(3, 2, true));
    try std.testing.expectEqual(@as(usize, 2), step(3, 0, false));
    try std.testing.expectEqual(@as(usize, 1), step(3, 2, false));
}

fn expectTrigger(expected: []const u8, trigger: input.Binding.Trigger) !void {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatTrigger(&writer, trigger);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "palette: format a trigger" {
    try expectTrigger("Ctrl+Shift+P", .{
        .key = .{ .physical = .key_p },
        .mods = .{ .ctrl = true, .shift = true },
    });
    try expectTrigger("Ctrl+Alt+Shift+Win+Left", .{
        .key = .{ .physical = .arrow_left },
        .mods = .{ .ctrl = true, .alt = true, .shift = true, .super = true },
    });
    try expectTrigger("Alt+1", .{
        .key = .{ .physical = .digit_1 },
        .mods = .{ .alt = true },
    });
    try expectTrigger("Ctrl+PgDn", .{
        .key = .{ .physical = .page_down },
        .mods = .{ .ctrl = true },
    });
    try expectTrigger("Ctrl+=", .{
        .key = .{ .physical = .equal },
        .mods = .{ .ctrl = true },
    });
    try expectTrigger("F11", .{ .key = .{ .physical = .f11 } });
    try expectTrigger("Enter", .{ .key = .{ .physical = .enter } });
    try expectTrigger("Win+Numpad Add", .{
        .key = .{ .physical = .numpad_add },
        .mods = .{ .super = true },
    });
    try expectTrigger("Ctrl+Shift+Q", .{
        .key = .{ .unicode = 'q' },
        .mods = .{ .ctrl = true, .shift = true },
    });
    try expectTrigger("Ctrl+\u{e9}", .{
        .key = .{ .unicode = 0xe9 },
        .mods = .{ .ctrl = true },
    });
}

test "palette: supported actions" {
    try std.testing.expect(supported(.new_tab));
    try std.testing.expect(supported(.{ .new_split = .right }));
    try std.testing.expect(supported(.toggle_command_palette));
    try std.testing.expect(!supported(.undo));
    try std.testing.expect(!supported(.redo));
    try std.testing.expect(!supported(.show_gtk_inspector));
    try std.testing.expect(!supported(.toggle_quick_terminal));
    try std.testing.expect(!supported(.{ .crash = .main }));
    try std.testing.expect(!supported(.close_all_windows));
}
