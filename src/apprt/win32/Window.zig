//! A top-level window: a tab bar, and tabs that each hold a tree of splits.
//!
//! Surfaces are child windows. They're owned by the split trees, which are
//! reference counted, so dropping a surface from its tree destroys it. That
//! must never happen inside a callback of the surface, so everything that
//! closes things goes through a posted message.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const Config = @import("../../config.zig").Config;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const App = @import("App.zig");
const CommandPalette = @import("CommandPalette.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");
const paint = @import("paint.zig");

const log = std.log.scoped(.win32);

pub const Tree = SplitTree(Surface);

/// Posted by `requestCloseTab`. wParam is the tab ID, lParam the mode.
const WM_CLOSE_TAB = c.WM_APP + 1;

// 96 DPI lengths.
const title_height = 40;
const strip_height = 44;
const strip_margin = 8;
const pill_height = 32;
const pill_inset = 3;
const button_size = 13;
const button_gap = 9;
const button_margin = 15;
const close_size = 18;
const divider_width = 8;
const card_margin = 8;
const card_radius = 12;
const outline = 1;
const outline_focused = 2;

/// Enough for the corners of the terminal to be inside of the rounded ones.
const card_inset = 5;
const resize_band = 5;

const animation_timer = 1;
const animation_ms = 15;

pub const Tab = struct {
    /// Unique for the life of the app, so it can be posted in messages.
    id: u32,
    tree: Tree,

    /// The surface with focus when the tab is selected. Always in the tree.
    focused: *Surface,
    title_override: ?[:0]const u8 = null,

    fn deinit(self: *Tab, alloc: Allocator) void {
        if (self.title_override) |v| alloc.free(v);
        self.tree.deinit();
    }

    pub fn title(self: *const Tab) []const u8 {
        return self.title_override orelse self.focused.title orelse "Ghostty";
    }

    fn needsConfirm(self: *const Tab) bool {
        var it = self.tree.iterator();
        while (it.next()) |entry| if (entry.view.core_surface.needsConfirmQuit()) return true;
        return false;
    }
};

/// A draggable boundary of the current layout.
const Divider = struct {
    rect: c.RECT,
    handle: Tree.Node.Handle,
    layout: Tree.Split.Layout,

    /// The area of the split it divides.
    area: c.RECT,
};

/// A pane of a split tab.
const Card = struct {
    surface: *const Surface,

    /// What it occupies, along with half of the gaps around it.
    area: c.RECT,
    /// The rounded rectangle.
    card: c.RECT,
    /// The terminal inside of it.
    hole: c.RECT,
};

const Hit = union(enum) {
    none,
    tab: usize,
    tab_close: usize,
    new_tab,
    button: Button,

    /// Anywhere else at the top, which moves the window.
    caption,
    divider: usize,

    fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

const Button = enum { close, minimize, zoom };

const Drag = union(enum) {
    none,
    tab: struct { start_x: c_int, start_y: c_int, moving: bool = false },
    divider: usize,
};

app: *App,
hwnd: c.HWND,
tabs: std.ArrayList(Tab) = .empty,
active: usize = 0,
title_override: ?[:0]const u8 = null,

dividers: std.ArrayList(Divider) = .empty,
cards: std.ArrayList(Card) = .empty,
hover: Hit = .none,
drag: Drag = .none,
tracking_leave: bool = false,
font: ?c.HFONT = null,
font_bold: ?c.HFONT = null,
font_icon: ?c.HFONT = null,

/// Where the selection is drawn, as a tab index. It moves towards `active`.
selection: f32 = 0,
animating: bool = false,

/// Whether we look active. That's also so while one of our popups is.
is_active: bool = true,
tracking_nc_leave: bool = false,
size_limit: apprt.action.SizeLimit = .{
    .min_width = 0,
    .min_height = 0,
    .max_width = 0,
    .max_height = 0,
},
minimized: bool = false,

/// True if background-opacity is toggled off.
force_opaque: bool = false,

/// Placement to restore when leaving fullscreen. Non-null in fullscreen.
windowed: ?struct { placement: c.WINDOWPLACEMENT, style: isize } = null,

palette: ?*CommandPalette = null,

/// Create a window with a single new tab.
pub fn create(app: *App) !*Window {
    const self = try createEmpty(app);
    errdefer _ = c.DestroyWindow(self.hwnd);
    _ = try self.newTab(.window);
    self.show();
    return self;
}

/// Create a hidden window with no tabs.
fn createEmpty(app: *App) !*Window {
    const alloc = app.core_app.alloc;
    const dpi = c.GetDpiForSystem();
    const hwnd = c.CreateWindowExW(
        0,
        App.window_class,
        c.L("Ghostty"),
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        paint.scale(960, dpi),
        paint.scale(600, dpi),
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    errdefer _ = c.DestroyWindow(hwnd);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    self.* = .{ .app = app, .hwnd = hwnd };
    try app.windows.append(alloc, self);

    // From here, destroying the window deinitializes us.
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateFont();
    self.syncAppearance();
    return self;
}

fn show(self: *Window) void {
    const config = &self.app.config;
    _ = c.ShowWindow(self.hwnd, if (config.maximize) c.SW_MAXIMIZE else c.SW_SHOW);
    if (config.fullscreen != .false) self.toggleFullscreen();
}

/// Destroy the window and everything in it.
///
/// Surfaces are destroyed while the window is still whole. If that's left to
/// WM_DESTROY, the GPU driver never frees some of the memory for their buffers.
pub fn destroy(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    _ = c.ShowWindow(self.hwnd, c.SW_HIDE);
    while (self.tabs.pop()) |popped| {
        // Nothing may be found through a tab that's going away.
        var tab = popped;
        self.active = 0;
        tab.deinit(alloc);
    }
    _ = c.DestroyWindow(self.hwnd);
}

/// Called from WM_DESTROY, when child windows still exist.
fn deinit(self: *Window) void {
    const alloc = self.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);
    for (self.app.windows.items, 0..) |window, i| if (window == self) {
        _ = self.app.windows.swapRemove(i);
        break;
    };

    if (self.palette) |v| v.destroy();
    for (self.tabs.items) |*tab| tab.deinit(alloc);
    self.tabs.deinit(alloc);
    self.dividers.deinit(alloc);
    self.cards.deinit(alloc);
    if (self.title_override) |v| alloc.free(v);
    for ([_]?c.HFONT{ self.font, self.font_bold, self.font_icon }) |font| {
        if (font) |v| _ = c.DeleteObject(v);
    }
    alloc.destroy(self);
}

//---------------------------------------------------------------
// Tabs

pub fn activeTab(self: *Window) ?*Tab {
    if (self.tabs.items.len == 0) return null;
    return &self.tabs.items[self.active];
}

pub fn activeSurface(self: *Window) ?*Surface {
    const tab = self.activeTab() orelse return null;
    return tab.focused;
}

const Location = struct { index: usize, tab: *Tab, handle: Tree.Node.Handle };

fn locate(self: *Window, surface: *const Surface) ?Location {
    for (self.tabs.items, 0..) |*tab, i| {
        const handle = tab.tree.locate(surface) orelse continue;
        return .{ .index = i, .tab = tab, .handle = handle };
    }
    return null;
}

pub fn newTab(self: *Window, context: apprt.surface.NewSurfaceContext) !*Surface {
    return self.newTabWith(context, null);
}

/// A new tab running `command` instead of the configured one, if given.
pub fn newTabWith(self: *Window, context: apprt.surface.NewSurfaceContext, command: ?[]const u8) !*Surface {
    const alloc = self.app.core_app.alloc;
    try self.tabs.ensureUnusedCapacity(alloc, 1);

    const surface = try Surface.create(self, context, self.contentRect(), command);
    const tree = Tree.init(alloc, surface) catch |err| {
        surface.destroy();
        return err;
    };
    const index = switch (self.app.config.@"window-new-tab-position") {
        .current => @min(self.active + 1, self.tabs.items.len),
        .end => self.tabs.items.len,
    };
    self.insertTab(index, .{
        .id = self.app.nextTabId(),
        .tree = tree,
        .focused = surface,
    });
    return surface;
}

/// Assumes capacity.
fn insertTab(self: *Window, index: usize, tab: Tab) void {
    if (self.activeTab()) |v| setTabVisible(v, false);
    self.tabs.insertAssumeCapacity(index, tab);
    self.active = index;
    if (self.tabs.items.len == 1) self.selection = 0;
    self.refresh();
    self.focusActive();
}

pub fn selectTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len or index == self.active) return;
    setTabVisible(&self.tabs.items[self.active], false);
    self.active = index;
    self.refresh();
    self.focusActive();
}

pub fn gotoTab(self: *Window, target: apprt.action.GotoTab) bool {
    const len = self.tabs.items.len;
    if (len == 0) return false;
    const index = switch (target) {
        .previous => (self.active + len - 1) % len,
        .next => (self.active + 1) % len,
        .last => len - 1,
        _ => index: {
            const raw = @backingInt(target);
            // Despite what its documentation says, this counts from one.
            if (raw < 1) return false;
            break :index @min(@as(usize, @intCast(raw)) - 1, len - 1);
        },
    };
    if (index == self.active) return false;
    self.selectTab(index);
    return true;
}

/// Move the tab with the given surface, wrapping around.
pub fn moveTab(self: *Window, surface: *const Surface, amount: isize) bool {
    const loc = self.locate(surface) orelse return false;
    const len: isize = @intCast(self.tabs.items.len);
    if (len < 2) return false;
    self.moveTabTo(loc.index, @intCast(@mod(@as(isize, @intCast(loc.index)) +% amount, len)));
    return true;
}

fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    const active_id = self.tabs.items[self.active].id;
    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, tab);
    for (self.tabs.items, 0..) |v, i| {
        if (v.id == active_id) self.active = i;
    }
    self.invalidateBar();
}

/// Move the tab with the given surface to a window of its own.
pub fn moveTabToNewWindow(self: *Window, surface: *const Surface) !bool {
    const loc = self.locate(surface) orelse return false;
    if (self.tabs.items.len < 2) return false;

    const other = try createEmpty(self.app);
    errdefer _ = c.DestroyWindow(other.hwnd);
    try other.tabs.ensureUnusedCapacity(self.app.core_app.alloc, 1);

    const tab = self.takeTab(loc.index);
    var it = tab.tree.iterator();
    while (it.next()) |entry| entry.view.setWindow(other);
    other.insertTab(0, tab);
    other.show();
    return true;
}

/// Remove a tab from the window without destroying it. If it was the last tab
/// the caller must destroy the window.
fn takeTab(self: *Window, index: usize) Tab {
    // The removed surfaces may be about to be destroyed, which moves the focus
    // and so can't be left to happen by itself.
    const was_active = index == self.active;
    if (was_active) setTabVisible(&self.tabs.items[index], false);
    const tab = self.tabs.orderedRemove(index);
    if (index < self.active or self.active == self.tabs.items.len) self.active -|= 1;
    if (self.tabs.items.len > 0) {
        self.refresh();
        if (was_active) self.focusActive();
    }
    return tab;
}

fn closeTabAt(self: *Window, index: usize) void {
    var tab = self.takeTab(index);
    tab.deinit(self.app.core_app.alloc);
}

/// Close tabs relative to the one with the given surface. Deferred.
pub fn requestCloseTab(
    self: *Window,
    surface: *const Surface,
    mode: apprt.action.CloseTabMode,
) bool {
    const loc = self.locate(surface) orelse return false;
    self.postCloseTab(loc.tab.id, mode);
    return true;
}

fn postCloseTab(self: *Window, id: u32, mode: apprt.action.CloseTabMode) void {
    _ = c.PostMessageW(self.hwnd, WM_CLOSE_TAB, id, @backingInt(mode));
}

fn closeTabs(self: *Window, id: u32, mode: apprt.action.CloseTabMode) void {
    const Match = struct {
        fn match(m: apprt.action.CloseTabMode, i: usize, base: usize) bool {
            return switch (m) {
                .this => i == base,
                .other => i != base,
                .right => i > base,
            };
        }
    };

    const base = for (self.tabs.items, 0..) |tab, i| {
        if (tab.id == id) break i;
    } else return;

    const needs_confirm = for (self.tabs.items, 0..) |*tab, i| {
        if (Match.match(mode, i, base) and tab.needsConfirm()) break true;
    } else false;
    if (needs_confirm) {
        if (!self.app.confirm(
            self.hwnd,
            c.L("Close tab?"),
            c.L("Running processes will be terminated."),
        )) return;

        // Tabs may have come and gone while the message box was open.
        return self.closeTabsConfirmed(id, mode, Match);
    }
    self.closeTabsConfirmed(id, mode, Match);
}

fn closeTabsConfirmed(
    self: *Window,
    id: u32,
    mode: apprt.action.CloseTabMode,
    comptime Match: type,
) void {
    const base = for (self.tabs.items, 0..) |tab, i| {
        if (tab.id == id) break i;
    } else return;

    var i = self.tabs.items.len;
    while (i > 0) {
        i -= 1;
        if (Match.match(mode, i, base)) self.closeTabAt(i);
    }
    if (self.tabs.items.len == 0) _ = c.DestroyWindow(self.hwnd);
}

/// Remove and destroy a surface, closing its tab and the window if empty.
/// Must not be called within a callback of the surface.
pub fn closeSurface(self: *Window, surface: *Surface) !void {
    const alloc = self.app.core_app.alloc;
    const loc = self.locate(surface) orelse return;
    if (!loc.tab.tree.isSplit()) {
        self.closeTabAt(loc.index);
        if (self.tabs.items.len == 0) _ = c.DestroyWindow(self.hwnd);
        return;
    }

    const next = next: {
        if (loc.tab.focused != surface) break :next loc.tab.focused;
        const handle = try loc.tab.tree.goto(alloc, loc.handle, .previous) orelse
            try loc.tab.tree.goto(alloc, loc.handle, .next) orelse
            return;
        break :next loc.tab.tree.nodes[handle.idx()].leaf;
    };
    const tree = try loc.tab.tree.remove(alloc, loc.handle);
    surface.setVisible(false);
    var old = loc.tab.tree;
    loc.tab.tree = tree;
    loc.tab.focused = next;
    self.refresh();
    if (loc.index == self.active) self.focusActive();

    // This drops the last reference to the surface.
    old.deinit();
}

pub fn needsConfirm(self: *const Window) bool {
    for (self.tabs.items) |*tab| if (tab.needsConfirm()) return true;
    return false;
}

fn setTabVisible(tab: *Tab, visible: bool) void {
    var it = tab.tree.iterator();
    while (it.next()) |entry| entry.view.setVisible(visible);
}

//---------------------------------------------------------------
// Splits

/// Replace a tab's tree with one derived from it.
fn setTree(tab: *Tab, tree: Tree) void {
    var old = tab.tree;
    tab.tree = tree;
    old.deinit();
}

/// Run `command` in place of `old`, in the same spot of the layout. The old
/// process ends. Must not be called within a callback of `old`.
pub fn replaceSurface(self: *Window, old: *Surface, command: []const u8) !void {
    const alloc = self.app.core_app.alloc;
    const first = self.locate(old) orelse return;

    const surface = try Surface.create(self, .split, self.contentRect(), command);
    var insert = Tree.init(alloc, surface) catch |err| {
        surface.destroy();
        return err;
    };
    defer insert.deinit();

    // Put the new surface beside the old one, then take the old one out.
    setTree(first.tab, try first.tab.tree.split(alloc, first.handle, .right, 0.5, &insert));
    first.tab.focused = surface;

    const loc = self.locate(old) orelse return;
    const tree = try loc.tab.tree.remove(alloc, loc.handle);
    old.setVisible(false);
    var old_tree = loc.tab.tree;
    loc.tab.tree = tree;
    loc.tab.focused = surface;
    self.refresh();
    if (loc.index == self.active) self.focusActive();

    // This drops the last reference to the old surface.
    old_tree.deinit();
}

pub fn newSplit(
    self: *Window,
    from: *Surface,
    direction: apprt.action.SplitDirection,
) !bool {
    const alloc = self.app.core_app.alloc;
    if (self.locate(from) == null) return false;

    const surface = try Surface.create(self, .split, self.contentRect(), null);
    var insert = Tree.init(alloc, surface) catch |err| {
        surface.destroy();
        return err;
    };
    defer insert.deinit();

    const loc = self.locate(from) orelse return false;
    setTree(loc.tab, try loc.tab.tree.split(
        alloc,
        loc.handle,
        switch (direction) {
            .right => .right,
            .down => .down,
            .left => .left,
            .up => .up,
        },
        0.5,
        &insert,
    ));
    loc.tab.focused = surface;
    self.refresh();
    self.focusActive();
    return true;
}

pub fn gotoSplit(self: *Window, from: *Surface, to: apprt.action.GotoSplit) !bool {
    const loc = self.locate(from) orelse return false;
    const handle = try loc.tab.tree.goto(self.app.core_app.alloc, loc.handle, switch (to) {
        .previous => .previous_wrapped,
        .next => .next_wrapped,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    }) orelse return false;
    if (handle == loc.handle) return false;

    if (loc.tab.tree.zoomed != null) {
        loc.tab.tree.zoom(if (self.app.config.@"split-preserve-zoom".navigation) handle else null);
    }
    loc.tab.focused = loc.tab.tree.nodes[handle.idx()].leaf;
    self.refresh();
    self.focusActive();
    return true;
}

pub fn resizeSplit(self: *Window, from: *Surface, value: apprt.action.ResizeSplit) !bool {
    const loc = self.locate(from) orelse return false;
    if (!loc.tab.tree.isSplit()) return false;

    const content = self.contentRect();
    const axis: Tree.Split.Layout, const total: c_int, const sign: f32 = switch (value.direction) {
        .left => .{ .horizontal, content.right - content.left, -1 },
        .right => .{ .horizontal, content.right - content.left, 1 },
        .up => .{ .vertical, content.bottom - content.top, -1 },
        .down => .{ .vertical, content.bottom - content.top, 1 },
    };
    if (total <= 0) return false;
    const ratio = sign * @as(f32, @floatFromInt(value.amount)) / @as(f32, @floatFromInt(total));
    setTree(loc.tab, try loc.tab.tree.resize(
        self.app.core_app.alloc,
        loc.handle,
        axis,
        @floatCast(std.math.clamp(ratio, -1, 1)),
    ));
    self.refresh();
    return true;
}

pub fn equalizeSplits(self: *Window, from: *Surface) !bool {
    const loc = self.locate(from) orelse return false;
    if (!loc.tab.tree.isSplit()) return false;
    setTree(loc.tab, try loc.tab.tree.equalize(self.app.core_app.alloc));
    self.refresh();
    return true;
}

pub fn toggleZoom(self: *Window, from: *Surface) bool {
    const loc = self.locate(from) orelse return false;
    if (!loc.tab.tree.isSplit()) return false;
    loc.tab.tree.zoom(if (loc.tab.tree.zoomed == null) loc.handle else null);
    loc.tab.focused = from;
    self.refresh();
    return true;
}

//---------------------------------------------------------------
// Focus and titles

pub fn focusActive(self: *Window) void {
    const surface = self.activeSurface() orelse return;

    // Focusing a child would activate us. Don't steal activation from another
    // window just because, say, a background tab closed. We focus the active
    // surface ourselves once we're activated.
    if (c.GetActiveWindow() == self.hwnd) _ = c.SetFocus(surface.hwnd);
}

/// Called when a surface gains the keyboard focus.
pub fn surfaceFocused(self: *Window, surface: *Surface) void {
    const loc = self.locate(surface) orelse return;
    if (loc.tab.focused == surface) return;
    loc.tab.focused = surface;
    syncDimming(loc.tab);
    self.titleChanged(surface);
    if (self.hasCards()) _ = c.InvalidateRect(self.hwnd, null, 0);
}

pub fn titleChanged(self: *Window, surface: *const Surface) void {
    const loc = self.locate(surface) orelse return;
    self.invalidateBar();
    if (loc.index == self.active) self.updateTitle();
}

pub fn setTabTitle(self: *Window, surface: *const Surface, title: []const u8) !bool {
    const loc = self.locate(surface) orelse return false;
    try self.replaceTitle(&loc.tab.title_override, title);
    self.titleChanged(surface);
    return true;
}

pub fn setWindowTitle(self: *Window, title: []const u8) !void {
    try self.replaceTitle(&self.title_override, title);
    self.updateTitle();
}

/// An empty title removes the override.
fn replaceTitle(self: *Window, slot: *?[:0]const u8, title: []const u8) !void {
    const alloc = self.app.core_app.alloc;
    const copy: ?[:0]const u8 = if (title.len == 0) null else try alloc.dupeSentinel(u8, title, 0);
    if (slot.*) |v| alloc.free(v);
    slot.* = copy;
}

fn updateTitle(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const alloc = self.app.core_app.alloc;
    const title = std.unicode.wtf8ToWtf16LeAllocZ(
        alloc,
        self.title_override orelse tab.title(),
    ) catch return;
    defer alloc.free(title);
    _ = c.SetWindowTextW(self.hwnd, title);
}

//---------------------------------------------------------------
// Layout

pub fn getDpi(self: *const Window) u32 {
    return c.GetDpiForWindow(self.hwnd);
}

fn scaled(self: *const Window, v: c_int) c_int {
    return paint.scale(v, self.getDpi());
}

fn clientRect(self: *const Window) c.RECT {
    var rect: c.RECT = .{};
    _ = c.GetClientRect(self.hwnd, &rect);
    return rect;
}

fn barVisible(self: *const Window) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.tabs.items.len > 1,
        .never => false,
    };
}

const Style = @FieldType(Config, "macos-titlebar-style");

/// The macOS styles make as much sense here, so we share the configuration.
fn titlebarStyle(self: *const Window) Style {
    const config = &self.app.config;
    if (config.@"window-decoration" == .none) return .hidden;
    return config.@"macos-titlebar-style";
}

/// Whether we draw the title bar, rather than Windows.
fn customFrame(self: *const Window) bool {
    return self.windowed == null and self.titlebarStyle() != .native;
}

/// The title bar if we're the one drawing it.
fn titleRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.bottom = if (self.windowed != null) 0 else switch (self.titlebarStyle()) {
        .native, .hidden => 0,
        // Tabs take the place of the title.
        .transparent => self.scaled(if (self.barVisible()) strip_height else title_height),
        .tabs => self.scaled(strip_height),
    };
    return rect;
}

fn tabsInTitle(self: *const Window) bool {
    return self.titleRect().bottom > 0;
}

/// The strip that holds the tabs.
fn stripRect(self: *const Window) c.RECT {
    var rect = self.titleRect();
    if (!self.barVisible()) {
        rect.top = rect.bottom;
        return rect;
    }
    if (self.tabsInTitle()) {
        rect.left = self.buttonsWidth();
        return rect;
    }
    rect.top = rect.bottom;
    rect.bottom = rect.top + self.scaled(strip_height);
    return rect;
}

/// Everything we draw above the surfaces.
fn barRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.bottom = @max(self.titleRect().bottom, self.stripRect().bottom);
    return rect;
}

fn buttonsVisible(self: *const Window) bool {
    return self.titleRect().bottom > 0 and self.app.config.@"macos-window-buttons" == .visible;
}

fn buttonsWidth(self: *const Window) c_int {
    if (!self.buttonsVisible()) return 0;
    return self.scaled(button_margin * 2 + button_size * 3 + button_gap * 2 - strip_margin);
}

fn buttonRect(self: *const Window, button: Button) c.RECT {
    const size = self.scaled(button_size);
    const index: c_int = @backingInt(button);
    const left = self.scaled(button_margin) + index * (size + self.scaled(button_gap));
    const top = @divTrunc(self.titleRect().bottom - size, 2);
    return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
}

/// The capsule that holds the tabs.
fn pillRect(self: *const Window) c.RECT {
    const strip = self.stripRect();
    const height = self.scaled(pill_height);
    const margin = self.scaled(strip_margin);
    const top = strip.top + @divTrunc(strip.bottom - strip.top - height, 2);
    return .{
        .left = strip.left + margin,
        .top = top,
        // The button to make a new tab is a circle next to it.
        .right = @max(strip.left + margin + 1, strip.right - margin * 2 - height),
        .bottom = top + height,
    };
}

fn newTabRect(self: *const Window) c.RECT {
    const pill = self.pillRect();
    const left = pill.right + self.scaled(strip_margin);
    return .{ .left = left, .top = pill.top, .right = left + pill.bottom - pill.top, .bottom = pill.bottom };
}

/// The area of the client that holds surfaces.
fn contentRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.top = self.barRect().bottom;
    return rect;
}

/// Bring the child windows, tab bar and title in line with our state.
pub fn refresh(self: *Window) void {
    self.relayout();
    self.updateTitle();
    self.invalidateBar();
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

fn relayout(self: *Window) void {
    self.dividers.clearRetainingCapacity();
    self.cards.clearRetainingCapacity();
    if (self.minimized) return;
    const tab = self.activeTab() orelse return;
    syncDimming(tab);
    const content = self.contentRect();
    if (tab.tree.zoomed) |zoomed| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| if (entry.handle != zoomed) entry.view.setVisible(false);
        self.layoutNode(tab, zoomed, content);
    } else if (tab.tree.isSplit()) {
        self.layoutNode(tab, .root, self.cardsRect(content));
    } else {
        self.layoutNode(tab, .root, content);
    }
    self.repositionOverlays();
}

/// Whether the panes of the active tab are cards. One that fills the window
/// isn't.
fn hasCards(self: *const Window) bool {
    if (self.tabs.items.len == 0) return false;
    const tree = &self.tabs.items[self.active].tree;
    return tree.isSplit() and tree.zoomed == null;
}

/// The part of the content that's divided between the cards. They keep half of
/// a gap to the edges of it.
fn cardsRect(self: *const Window, content: c.RECT) c.RECT {
    const band = self.scaled(card_margin) - @divTrunc(self.scaled(divider_width), 2);
    return .{
        .left = content.left + band,
        .top = content.top + if (self.barVisible() or self.titleRect().bottom > 0) 0 else band,
        .right = content.right - band,
        .bottom = content.bottom - band,
    };
}

fn insetRect(rect: c.RECT, by: c_int) c.RECT {
    return .{
        .left = rect.left + by,
        .top = rect.top + by,
        .right = @max(rect.left + by + 1, rect.right - by),
        .bottom = @max(rect.top + by + 1, rect.bottom - by),
    };
}

fn layoutNode(self: *Window, tab: *Tab, handle: Tree.Node.Handle, area: c.RECT) void {
    switch (tab.tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            if (self.hasCards()) {
                const card = insetRect(area, @divTrunc(self.scaled(divider_width), 2));
                const hole = insetRect(card, self.scaled(card_inset));
                self.cards.append(self.app.core_app.alloc, .{
                    .surface = surface,
                    .area = area,
                    .card = card,
                    .hole = hole,
                }) catch {};
                surface.place(hole);
            } else {
                surface.place(area);
            }
            surface.setVisible(true);
        },

        .split => |split| {
            const half = @divTrunc(self.scaled(divider_width), 2);
            const horizontal = split.layout == .horizontal;
            const start, const end = if (horizontal)
                .{ area.left, area.right }
            else
                .{ area.top, area.bottom };
            const ratio: f32 = split.ratio;
            const at = start + @as(c_int, @intFromFloat(ratio * @as(f32, @floatFromInt(@max(0, end - start)))));

            var first = area;
            var second = area;
            var rect = area;
            if (horizontal) {
                first.right = at;
                second.left = at;
                rect.left = at - half;
                rect.right = at + half;
            } else {
                first.bottom = at;
                second.top = at;
                rect.top = at - half;
                rect.bottom = at + half;
            }
            self.dividers.append(self.app.core_app.alloc, .{
                .rect = rect,
                .handle = handle,
                .layout = split.layout,
                .area = area,
            }) catch {};
            self.layoutNode(tab, split.left, first);
            self.layoutNode(tab, split.right, second);
        },
    }
}

/// Dim the splits that don't have the focus.
fn syncDimming(tab: *Tab) void {
    const split = tab.tree.isSplit();
    var it = tab.tree.iterator();
    while (it.next()) |entry| entry.view.setDimmed(split and entry.view != tab.focused);
}

/// Popups we own don't move with us.
fn repositionOverlays(self: *Window) void {
    if (self.palette) |v| v.reposition();
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| if (entry.view.search) |v| v.reposition();
    }
}

/// Resize the window so that a surface filling it has the given size.
pub fn setSurfaceSize(self: *Window, surface: *const Surface, width: u32, height: u32) void {
    if (self.windowed != null or c.IsZoomed(self.hwnd) != 0) return;
    var rect: c.RECT = .{
        .right = std.math.lossyCast(c_int, width),
        .bottom = std.math.lossyCast(c_int, height),
    };
    rect.right += surface.scrollbarWidth();
    rect.bottom += self.barRect().bottom;
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
fn adjustRect(self: *const Window, rect: *c.RECT) void {
    const style: u32 = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(self.hwnd, c.GWL_STYLE))));
    const top = rect.top;
    _ = c.AdjustWindowRectExForDpi(rect, style, 0, 0, self.getDpi());
    if (self.customFrame()) rect.top = top;
}

pub fn toggleMaximize(self: *Window) void {
    if (self.windowed != null) return;
    _ = c.ShowWindow(self.hwnd, if (c.IsZoomed(self.hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

/// Borderless fullscreen on the current monitor.
pub fn toggleFullscreen(self: *Window) void {
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

pub fn present(self: *Window, surface: *Surface) void {
    const loc = self.locate(surface) orelse return;
    self.selectTab(loc.index);
    loc.tab.focused = surface;
    if (c.IsIconic(self.hwnd) != 0) _ = c.ShowWindow(self.hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(self.hwnd);
    self.focusActive();
}

//---------------------------------------------------------------
// Appearance

pub fn configChanged(self: *Window) void {
    self.syncAppearance();
    self.updateFont();
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            entry.view.configChanged();
            if (self.force_opaque) entry.view.updateOpacity();
        }
    }
    self.refresh();
}

/// Match the frame to the configured theme.
fn syncAppearance(self: *Window) void {
    self.syncTransparency();
    const config = &self.app.config;
    const palette: paint.Palette = .init(config);
    const dark: c.BOOL = @intFromBool(switch (config.@"window-theme") {
        .dark => true,
        .light => false,
        .system => App.systemColorScheme() == .dark,
        .auto, .ghostty => palette.bg.isDark(),
    });
    _ = c.DwmSetWindowAttribute(
        self.hwnd,
        c.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(c.BOOL),
    );

    var caption: u32 = c.DWMWA_COLOR_DEFAULT;
    var caption_text: u32 = c.DWMWA_COLOR_DEFAULT;
    if (config.@"window-theme" == .ghostty) {
        caption = (if (config.@"window-titlebar-background") |v| paint.Rgb.from(v) else palette.bg).ref();
        caption_text = (if (config.@"window-titlebar-foreground") |v| paint.Rgb.from(v) else palette.fg).ref();
    }
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_CAPTION_COLOR, &caption, @sizeOf(u32));
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_TEXT_COLOR, &caption_text, @sizeOf(u32));

    // A hairline that suits the background, and the largest corners there are.
    const border = palette.bg.mix(palette.fg, 45).ref();
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_BORDER_COLOR, &border, @sizeOf(u32));
    const corners: u32 = c.DWMWCP_ROUND;
    _ = c.DwmSetWindowAttribute(self.hwnd, c.DWMWA_WINDOW_CORNER_PREFERENCE, &corners, @sizeOf(u32));

    // The frame depends on the style.
    _ = c.SetWindowPos(
        self.hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
}

/// The opacity (0 to 255) of the terminal background.
pub fn backgroundOpacity(self: *const Window) u8 {
    if (self.force_opaque) return 255;
    return @intFromFloat(@round(std.math.clamp(self.app.config.@"background-opacity", 0, 1) * 255));
}

pub fn toggleOpacity(self: *Window) bool {
    if (self.app.config.@"background-opacity" >= 1) return false;
    self.force_opaque = !self.force_opaque;
    self.syncTransparency();

    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.updateOpacity();
    }
    _ = c.RedrawWindow(self.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ALLCHILDREN);
    return true;
}

/// Have the compositor use the alpha channel of what's drawn, or not.
fn syncTransparency(self: *Window) void {
    const transparent = self.backgroundOpacity() < 255;

    // An empty region enables alpha without any blur. Since Windows 8 the
    // blur this is named for doesn't exist anyway.
    const region = if (transparent) c.CreateRectRgn(0, 0, -1, -1) else null;
    defer if (region) |v| {
        _ = c.DeleteObject(v);
    };
    _ = c.DwmEnableBlurBehindWindow(self.hwnd, &.{
        .dwFlags = c.DWM_BB_ENABLE | @as(u32, if (transparent) c.DWM_BB_BLURREGION else 0),
        .fEnable = @intFromBool(transparent),
        .hRgnBlur = region,
    });

    // The documented backdrops (DWMWA_SYSTEMBACKDROP_TYPE) are opaque
    // materials that don't show what's behind the window. This is
    // undocumented, so look it up and do without if it's ever removed.
    const blur = transparent and switch (self.app.config.@"background-blur") {
        .false => false,
        .radius => |v| v > 0,
        .true, .@"macos-glass-regular", .@"macos-glass-clear" => true,
    };
    const user32 = c.GetModuleHandleW(c.L("user32.dll")) orelse return;
    const proc = c.GetProcAddress(user32, "SetWindowCompositionAttribute") orelse return;
    const func: *const fn (
        c.HWND,
        *const c.WINDOWCOMPOSITIONATTRIBDATA,
    ) callconv(.winapi) c.BOOL = @ptrCast(@alignCast(proc));
    const policy: c.ACCENT_POLICY = .{
        .state = if (blur) c.ACCENT_ENABLE_BLURBEHIND else c.ACCENT_DISABLED,
    };
    _ = func(self.hwnd, &.{
        .attribute = c.WCA_ACCENT_POLICY,
        .data = &policy,
        .size = @sizeOf(c.ACCENT_POLICY),
    });
}

fn updateFont(self: *Window) void {
    for ([_]?c.HFONT{ self.font, self.font_bold, self.font_icon }) |font| {
        if (font) |v| _ = c.DeleteObject(v);
    }
    const value = self.getDpi();
    const alloc = self.app.core_app.alloc;
    const custom: ?[:0]u16 = if (self.app.config.@"window-title-font-family") |v|
        std.unicode.wtf8ToWtf16LeAllocZ(alloc, v) catch null
    else
        null;
    defer if (custom) |v| alloc.free(v);
    const family: [*:0]const u16 = if (custom) |v| v.ptr else c.L("Segoe UI Variable Text");
    self.font = paint.font(family, 9, 400, value);
    self.font_bold = paint.font(family, 9, 600, value);
    self.font_icon = paint.iconFont(7, value);
}

fn invalidateBar(self: *Window) void {
    const rect = self.barRect();
    if (rect.bottom > 0) _ = c.InvalidateRect(self.hwnd, &rect, 0);

    const target: f32 = @floatFromInt(self.active);
    if (self.selection != target and !self.animating) {
        self.animating = c.SetTimer(self.hwnd, animation_timer, animation_ms, null) != 0;
    }
}

/// Move the selection a step closer to the active tab.
fn animate(self: *Window) void {
    const target: f32 = @floatFromInt(self.active);
    const remaining = target - self.selection;
    if (@abs(remaining) < 0.01) {
        self.selection = target;
        self.animating = false;
        _ = c.KillTimer(self.hwnd, animation_timer);
    } else {
        self.selection += remaining * 0.3;
    }
    const rect = self.barRect();
    _ = c.InvalidateRect(self.hwnd, &rect, 0);
}

fn tabWidth(self: *const Window) f32 {
    const pill = self.pillRect();
    return @as(f32, @floatFromInt(pill.right - pill.left)) /
        @as(f32, @floatFromInt(@max(1, self.tabs.items.len)));
}

/// The area of a tab, which may be between two.
fn tabArea(self: *const Window, position: f32) paint.Rect {
    const pill: paint.Rect = .from(self.pillRect());
    const width = self.tabWidth();
    return .{ .x = pill.x + width * position, .y = pill.y, .w = width, .h = pill.h };
}

fn tabRect(self: *const Window, index: usize) c.RECT {
    const r = self.tabArea(@floatFromInt(index));
    return .{
        .left = @intFromFloat(r.x),
        .top = @intFromFloat(r.y),
        .right = @intFromFloat(r.x + r.w),
        .bottom = @intFromFloat(r.y + r.h),
    };
}

fn closeRect(self: *const Window, index: usize) c.RECT {
    const tab = self.tabRect(index);
    const size = self.scaled(close_size);
    const top = tab.top + @divTrunc(tab.bottom - tab.top - size, 2);
    const left = tab.left + @divTrunc(tab.bottom - tab.top - size, 2);
    return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
}

fn onPaint(self: *Window) void {
    var ps: c.PAINTSTRUCT = .{};
    const dc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    const palette: paint.Palette = .init(&self.app.config);
    if (self.hasCards()) self.paintCards(dc, palette);

    const bar = self.barRect();
    if (bar.bottom == 0) return;
    var buf = paint.Buffer.begin(dc, bar) orelse return;
    defer buf.end();
    self.paintBase(&buf, palette);
    if (self.buttonsVisible()) self.paintButtons(buf, palette);
    if (self.barVisible()) self.paintTabs(buf, palette) else self.paintTitle(buf, palette);
}

/// Cards are on something that's a little further back than they are.
fn paintBase(self: *const Window, buf: *paint.Buffer, palette: paint.Palette) void {
    const opacity = self.backgroundOpacity();
    if (!self.hasCards()) return buf.base(palette.bg, opacity);

    // More of what's behind the window is seen between cards.
    buf.base(palette.backdrop, if (opacity == 255) 255 else @intCast(@as(u32, opacity) * 7 / 10));
}

fn paintCards(self: *Window, dc: c.HDC, palette: paint.Palette) void {
    const content = self.contentRect();
    const inner = self.cardsRect(content);
    for ([_]c.RECT{
        .{ .left = content.left, .top = content.top, .right = content.right, .bottom = inner.top },
        .{ .left = content.left, .top = inner.bottom, .right = content.right, .bottom = content.bottom },
        .{ .left = content.left, .top = inner.top, .right = inner.left, .bottom = inner.bottom },
        .{ .left = inner.right, .top = inner.top, .right = content.right, .bottom = inner.bottom },
    }) |rect| {
        var buf = paint.Buffer.begin(dc, rect) orelse continue;
        self.paintBase(&buf, palette);
        buf.end();
    }

    const focused = self.activeSurface();
    for (self.cards.items) |card| {
        // Only what's around the terminal, which covers the rest. Filling
        // all of it would be slow.
        const a = card.area;
        const h = card.hole;
        for ([_]c.RECT{
            .{ .left = a.left, .top = a.top, .right = a.right, .bottom = h.top },
            .{ .left = a.left, .top = h.bottom, .right = a.right, .bottom = a.bottom },
            .{ .left = a.left, .top = h.top, .right = h.left, .bottom = h.bottom },
            .{ .left = h.right, .top = h.top, .right = a.right, .bottom = h.bottom },
        }) |rect| {
            var buf = paint.Buffer.begin(dc, rect) orelse continue;
            defer buf.end();
            self.paintBase(&buf, palette);
            self.paintCard(buf, rect, card.card, palette, card.surface == focused);
        }
    }
}

/// The part of a card that's in a buffer for the given part of the window.
fn paintCard(
    self: *const Window,
    buf: paint.Buffer,
    part: c.RECT,
    card: c.RECT,
    palette: paint.Palette,
    focused: bool,
) void {
    const radius: f32 = @floatFromInt(self.scaled(card_radius));
    var r: paint.Rect = .from(card);
    r.x -= @floatFromInt(part.left);
    r.y -= @floatFromInt(part.top);
    buf.replaceRound(r, radius, palette.bg, self.backgroundOpacity());

    // The outline is in the gap around the card, and takes nothing of it.
    const thickness: f32 = @floatFromInt(self.scaled(if (focused) outline_focused else outline));
    const color = if (!focused)
        palette.divider
    else if (self.is_active)
        palette.accent
    else
        palette.accent.mix(palette.backdrop, 128);
    buf.outline(r.inset(-thickness), radius + thickness, thickness, color);
}

/// Scales alpha down for windows that aren't active.
fn emphasis(self: *const Window) f32 {
    return if (self.is_active) 1 else 0.5;
}

fn paintTitle(self: *Window, buf: paint.Buffer, palette: paint.Palette) void {
    var rect = self.titleRect();
    if (rect.bottom == 0) return;
    const tab = self.activeTab() orelse return;

    // Centered in the window, as long as it stays clear of the buttons.
    const side = @max(self.buttonsWidth(), self.scaled(strip_margin));
    rect.left += side;
    rect.right -= side;
    if (rect.right <= rect.left) return;
    buf.blendText(
        self.title_override orelse tab.title(),
        rect,
        self.font_bold,
        palette.fg,
        0.85 * self.emphasis(),
        c.DT_CENTER,
    );
}

fn paintButtons(self: *Window, buf: paint.Buffer, palette: paint.Palette) void {
    const over = self.hover == .button;
    for (std.enums.values(Button)) |button| {
        const r: paint.Rect = .from(self.buttonRect(button));
        const radius = r.w / 2;
        if (!self.is_active and !over) {
            buf.round(r, radius, palette.fg, 0.2);
            continue;
        }
        const color: paint.Rgb = switch (button) {
            .close => .{ .r = 0xFF, .g = 0x5F, .b = 0x57 },
            .minimize => .{ .r = 0xFE, .g = 0xBC, .b = 0x2E },
            .zoom => .{ .r = 0x28, .g = 0xC8, .b = 0x40 },
        };
        const black: paint.Rgb = .{ .r = 0, .g = 0, .b = 0 };
        buf.round(r, radius, color, 1);
        buf.ring(r, radius, black, 0.08, 0.18);
        if (!over) continue;

        // The symbols are shown all at once, for hovering any.
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        const arm = r.w * 0.27;
        const line = @max(1.2, r.w * 0.11);
        switch (button) {
            .close => {
                buf.stroke(cx - arm, cy - arm, cx + arm, cy + arm, line, black, 0.55);
                buf.stroke(cx - arm, cy + arm, cx + arm, cy - arm, line, black, 0.55);
            },
            .minimize => buf.stroke(cx - arm * 1.2, cy, cx + arm * 1.2, cy, line, black, 0.55),
            .zoom => {
                buf.stroke(cx - arm * 1.2, cy, cx + arm * 1.2, cy, line, black, 0.55);
                buf.stroke(cx, cy - arm * 1.2, cx, cy + arm * 1.2, line, black, 0.55);
            },
        }
    }
}

fn paintTabs(self: *Window, buf: paint.Buffer, palette: paint.Palette) void {
    const strength = self.emphasis();
    const pill: paint.Rect = .from(self.pillRect());
    buf.glass(pill, pill.h / 2, palette.fg, 0.09);

    // The selection is a smaller capsule, concentric with the outer one.
    const inset: f32 = @floatFromInt(self.scaled(pill_inset));
    const last: f32 = @floatFromInt(self.tabs.items.len - 1);
    const selection = self.tabArea(std.math.clamp(self.selection, 0, last)).inset(inset);
    if (palette.bg.isDark()) {
        buf.glass(selection, selection.h / 2, palette.fg, 0.07 + 0.08 * strength);
    } else {
        // On a light background, what's raised is brighter than its surroundings.
        buf.round(selection, selection.h / 2, .{ .r = 255, .g = 255, .b = 255 }, 0.45 + 0.5 * strength);
        buf.ring(selection, selection.h / 2, palette.fg, 0.05, 0.16);
    }

    for (self.tabs.items, 0..) |*tab, i| {
        const active = i == self.active;
        const hovered = switch (self.hover) {
            .tab, .tab_close => |v| v == i,
            else => false,
        };
        const area = self.tabArea(@floatFromInt(i));
        if (hovered and !active) {
            const r = area.inset(inset);
            buf.round(r, r.h / 2, palette.fg, 0.05);
        }

        // Between tabs that are both plain.
        if (i > 0 and !active and i - 1 != self.active and !self.animating) {
            buf.round(.{ .x = @floor(area.x), .y = area.y + area.h * 0.3, .w = 1, .h = area.h * 0.4 }, 0, palette.fg, 0.14);
        }

        // Centered, so leave the same space as the close button on the right.
        const close = self.closeRect(i);
        var label = self.tabRect(i);
        const side = close.right - label.left + self.scaled(2);
        label.left += side;
        label.right -= side;
        var number: [8]u8 = undefined;
        const title = std.mem.trim(u8, tab.title(), " ");
        if (label.right > label.left) buf.blendText(
            // A fixed blank title is a way of hiding the one of the window, but
            // tabs need something to tell them apart.
            if (title.len > 0) title else std.fmt.bufPrint(&number, "{}", .{i + 1}) catch "",
            label,
            if (active) self.font_bold else self.font,
            palette.fg,
            (if (active) @as(f32, 0.95) else 0.6) * strength,
            c.DT_CENTER,
        );

        if (hovered) {
            const on_close = self.hover.eql(.{ .tab_close = i });
            const r: paint.Rect = .from(close);
            if (on_close) buf.round(r, r.w / 2, palette.fg, 0.16);
            buf.blendText(paint.icon.cancel, close, self.font_icon, palette.fg, if (on_close) 0.95 else 0.6, c.DT_CENTER);
        }
    }

    const plus = self.newTabRect();
    const r: paint.Rect = .from(plus);
    buf.glass(r, r.w / 2, palette.fg, if (self.hover == .new_tab) 0.18 else 0.09);
    buf.blendText(paint.icon.add, plus, self.font_icon, palette.fg, 0.8 * strength, c.DT_CENTER);
}

//---------------------------------------------------------------
// Mouse

fn contains(rect: c.RECT, x: c_int, y: c_int) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn hitTest(self: *const Window, x: c_int, y: c_int) Hit {
    if (contains(self.barRect(), x, y)) {
        if (self.buttonsVisible()) {
            // The gaps belong to the buttons, to make them easier to hit.
            for (std.enums.values(Button)) |button| {
                var r = self.buttonRect(button);
                const gap = @divTrunc(self.scaled(button_gap) + 1, 2);
                r.left -= gap;
                r.right += gap;
                r.top -= gap;
                r.bottom += gap;
                if (contains(r, x, y)) return .{ .button = button };
            }
        }
        if (self.barVisible()) {
            const pill = self.pillRect();
            if (contains(pill, x, y)) {
                const offset: f32 = @floatFromInt(x - pill.left);
                const index: usize = @min(
                    self.tabs.items.len - 1,
                    @as(usize, @intFromFloat(@max(0, offset / self.tabWidth()))),
                );
                if (contains(self.closeRect(index), x, y)) return .{ .tab_close = index };
                return .{ .tab = index };
            }
            if (contains(self.newTabRect(), x, y)) return .new_tab;
        }
        return .caption;
    }
    for (self.dividers.items, 0..) |divider, i| {
        if (contains(divider.rect, x, y)) return .{ .divider = i };
    }
    return .none;
}

fn onMouseMove(self: *Window, x: c_int, y: c_int) void {
    if (!self.tracking_leave) {
        var track: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
        self.tracking_leave = c.TrackMouseEvent(&track) != 0;
    }

    switch (self.drag) {
        .none => {},
        .tab => |*drag| {
            if (!drag.moving and @abs(x - drag.start_x) > self.scaled(6)) drag.moving = true;

            // Tabs leave little of the title bar to take hold of.
            if (!drag.moving and self.customFrame() and @abs(y - drag.start_y) > self.scaled(8)) {
                self.drag = .none;
                _ = c.ReleaseCapture();
                var point: c.POINT = .{};
                _ = c.GetCursorPos(&point);
                const px: u16 = @bitCast(@as(i16, @truncate(point.x)));
                const py: u16 = @bitCast(@as(i16, @truncate(point.y)));
                _ = c.PostMessageW(
                    self.hwnd,
                    c.WM_NCLBUTTONDOWN,
                    c.HTCAPTION,
                    @as(c.LPARAM, py) << 16 | px,
                );
                return;
            }
            if (drag.moving and self.tabs.items.len > 0) {
                const max = self.tabs.items.len - 1;
                const offset: f32 = @floatFromInt(@max(0, x - self.pillRect().left));
                const to: usize = @min(max, @as(usize, @intFromFloat(offset / self.tabWidth())));
                self.moveTabTo(self.active, to);
            }
        },
        .divider => |index| if (index < self.dividers.items.len) {
            const divider = self.dividers.items[index];
            const tab = self.activeTab() orelse return;
            const pos, const start, const end = switch (divider.layout) {
                .horizontal => .{ x, divider.area.left, divider.area.right },
                .vertical => .{ y, divider.area.top, divider.area.bottom },
            };
            const space = end - start;
            if (space <= 0) return;
            const ratio = @as(f32, @floatFromInt(pos - start)) /
                @as(f32, @floatFromInt(space));
            tab.tree.resizeInPlace(divider.handle, @floatCast(std.math.clamp(ratio, 0.05, 0.95)));
            self.relayout();
            _ = c.InvalidateRect(self.hwnd, null, 0);
        },
    }

    self.setHover(self.hitTest(x, y));
}

fn setHover(self: *Window, hover: Hit) void {
    if (hover.eql(self.hover)) return;
    self.hover = hover;
    self.invalidateBar();
}

/// The button a non-client message is about.
fn ncButton(hit: c.WPARAM) ?Button {
    return switch (hit) {
        c.HTCLOSE => .close,
        c.HTMINBUTTON => .minimize,
        c.HTMAXBUTTON => .zoom,
        else => null,
    };
}

fn frameThickness(self: *const Window) c_int {
    const SM_CYSIZEFRAME = 33;
    const SM_CXPADDEDBORDER = 92;
    return c.GetSystemMetricsForDpi(SM_CYSIZEFRAME, self.getDpi()) +
        c.GetSystemMetricsForDpi(SM_CXPADDEDBORDER, self.getDpi());
}

/// Whether a screen position is at the top edge, which resizes the window. The
/// other edges are outside of the client area.
pub fn inResizeBand(self: *const Window, y: c_int) bool {
    if (!self.customFrame() or c.IsZoomed(self.hwnd) != 0) return false;
    var rect: c.RECT = .{};
    _ = c.GetWindowRect(self.hwnd, &rect);
    return y >= rect.top and y < rect.top + self.scaled(resize_band);
}

fn onLeftDown(self: *Window, x: c_int, y: c_int) !void {
    switch (self.hitTest(x, y)) {
        .none, .caption, .button => {},
        .tab => |i| {
            self.selectTab(i);
            self.drag = .{ .tab = .{ .start_x = x, .start_y = y } };
            _ = c.SetCapture(self.hwnd);
        },
        .tab_close => |i| self.postCloseTab(self.tabs.items[i].id, .this),
        .new_tab => _ = try self.newTab(.tab),
        .divider => |i| {
            self.drag = .{ .divider = i };
            _ = c.SetCapture(self.hwnd);
        },
    }
    self.focusActive();
}

fn onDoubleClick(self: *Window, x: c_int, y: c_int) !void {
    switch (self.hitTest(x, y)) {
        .caption => _ = try self.newTab(.tab),
        .divider => if (self.activeSurface()) |v| {
            _ = try self.equalizeSplits(v);
        },
        // Every other press of a fast series of clicks is a double click.
        else => try self.onLeftDown(x, y),
    }
}

//---------------------------------------------------------------
// Window procedure

pub fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.message(msg, wparam, lparam) catch |err| err: {
        log.warn("error handling window message msg=0x{x} err={}", .{ msg, err });
        break :err 0;
    } orelse c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Returns null for default processing. Self may be destroyed on return.
fn message(self: *Window, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) !?c.LRESULT {
    const bits: usize = @bitCast(lparam);
    const x: c_int = @as(i16, @bitCast(@as(u16, @truncate(bits))));
    const y: c_int = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));

    switch (msg) {
        c.WM_CLOSE => {
            // A message box may be open above a callback of our surfaces.
            if (self.app.modal > 0) return 0;
            if (self.needsConfirm() and !self.app.confirm(
                self.hwnd,
                c.L("Close window?"),
                c.L("All terminal sessions in this window will be terminated."),
            )) return 0;
            self.destroy();
        },

        WM_CLOSE_TAB => {
            if (self.app.modal > 0) return 0;
            self.closeTabs(
                @truncate(wparam),
                std.enums.fromInt(apprt.action.CloseTabMode, lparam) orelse return 0,
            );
        },

        c.WM_DESTROY => self.deinit(),
        c.WM_PAINT => self.onPaint(),
        c.WM_TIMER => if (wparam == animation_timer) self.animate(),

        c.WM_NCCALCSIZE => {
            if (wparam == 0 or !self.customFrame()) return null;

            // Keep the borders that Windows uses for resizing and the shadow,
            // but have the client area reach the top.
            const rect: *c.RECT = @ptrFromInt(bits);
            const top = rect.top;
            const result = c.DefWindowProcW(self.hwnd, msg, wparam, lparam);
            if (result != 0) return result;
            rect.top = top;

            // A maximized window's borders are outside of the monitor.
            if (c.IsZoomed(self.hwnd) != 0) rect.top += self.frameThickness();
            return 0;
        },

        c.WM_NCACTIVATE => {
            if (!self.customFrame()) return null;
            // This parameter keeps Windows from drawing the title bar.
            return c.DefWindowProcW(self.hwnd, msg, wparam, -1);
        },

        c.WM_ACTIVATE => {
            const other: ?c.HWND = @ptrFromInt(bits);
            self.is_active = wparam & 0xFFFF != 0 or
                (other != null and c.GetWindow(other.?, c.GW_OWNER) == self.hwnd);
            _ = c.InvalidateRect(self.hwnd, null, 0);
            return null;
        },

        c.WM_NCHITTEST => {
            const result = c.DefWindowProcW(self.hwnd, msg, wparam, lparam);
            if (result != c.HTCLIENT or !self.customFrame()) return result;
            var point: c.POINT = .{ .x = x, .y = y };
            if (self.inResizeBand(y)) return c.HTTOP;
            _ = c.ScreenToClient(self.hwnd, &point);
            return switch (self.hitTest(point.x, point.y)) {
                .caption => c.HTCAPTION,
                .button => |v| switch (v) {
                    .close => c.HTCLOSE,
                    .minimize => c.HTMINBUTTON,
                    // This is what makes Windows offer snap layouts.
                    .zoom => c.HTMAXBUTTON,
                },
                else => c.HTCLIENT,
            };
        },

        c.WM_NCMOUSEMOVE => {
            if (!self.customFrame()) return null;
            if (!self.tracking_nc_leave) {
                var track: c.TRACKMOUSEEVENT = .{
                    .dwFlags = c.TME_LEAVE | c.TME_NONCLIENT,
                    .hwndTrack = self.hwnd,
                };
                self.tracking_nc_leave = c.TrackMouseEvent(&track) != 0;
            }
            self.setHover(if (ncButton(wparam)) |v| .{ .button = v } else .caption);
            return null;
        },
        c.WM_NCMOUSELEAVE => {
            self.tracking_nc_leave = false;
            self.setHover(.none);
            return null;
        },

        // Windows would draw its own buttons as pressed.
        c.WM_NCLBUTTONDOWN, c.WM_NCLBUTTONDBLCLK => {
            if (!self.customFrame() or ncButton(wparam) == null) return null;
        },
        c.WM_NCLBUTTONUP => {
            if (!self.customFrame()) return null;
            switch (ncButton(wparam) orelse return null) {
                .close => _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0),
                .minimize => _ = c.ShowWindow(self.hwnd, c.SW_MINIMIZE),
                .zoom => self.toggleMaximize(),
            }
        },
        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => {
            self.minimized = wparam == c.SIZE_MINIMIZED;
            if (self.minimized) {
                if (self.activeTab()) |tab| {
                    var it = tab.tree.iterator();
                    while (it.next()) |entry| entry.view.setOccluded(true);
                }
            } else {
                if (self.activeTab()) |tab| {
                    var it = tab.tree.iterator();
                    while (it.next()) |entry| entry.view.setOccluded(!entry.view.visible);
                }
                self.relayout();
            }
            _ = c.InvalidateRect(self.hwnd, null, 0);
        },

        c.WM_WINDOWPOSCHANGED => {
            // DefWindowProc turns this in to WM_SIZE.
            self.repositionOverlays();
            return null;
        },

        c.WM_GETMINMAXINFO => {
            if (self.windowed != null) return null;
            const info: *c.MINMAXINFO = @ptrFromInt(bits);
            const limit = self.size_limit;
            if (limit.min_width > 0 and limit.min_height > 0) {
                var rect: c.RECT = .{
                    .right = std.math.lossyCast(c_int, limit.min_width),
                    .bottom = std.math.lossyCast(c_int, limit.min_height),
                };
                rect.bottom += self.barRect().bottom;
                self.adjustRect(&rect);
                info.ptMinTrackSize = .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
            }
        },

        c.WM_DPICHANGED => {
            const rect: *const c.RECT = @ptrFromInt(bits);
            self.updateFont();
            for (self.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| entry.view.dpiChanged();
            }
            _ = c.SetWindowPos(
                self.hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            self.refresh();
        },

        c.WM_SETTINGCHANGE => {
            self.syncAppearance();
            try self.app.colorSchemeChanged();
        },

        c.WM_ACTIVATEAPP => self.app.core_app.focusEvent(wparam != 0),
        c.WM_SETFOCUS => if (self.activeSurface()) |v| {
            _ = c.SetFocus(v.hwnd);
        },

        c.WM_SETCURSOR => {
            if (lparam & 0xFFFF != c.HTCLIENT) return null;
            const divider: ?usize = switch (self.drag) {
                .divider => |i| i,
                else => switch (self.hover) {
                    .divider => |i| i,
                    else => null,
                },
            };
            const id: usize = if (divider) |i| id: {
                if (i >= self.dividers.items.len) break :id c.IDC_ARROW;
                break :id switch (self.dividers.items[i].layout) {
                    .horizontal => c.IDC_SIZEWE,
                    .vertical => c.IDC_SIZENS,
                };
            } else c.IDC_ARROW;
            _ = c.SetCursor(c.LoadCursorW(null, id));
            return 1;
        },

        c.WM_MOUSEMOVE => self.onMouseMove(x, y),
        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            self.hover = .none;
            self.invalidateBar();
        },
        c.WM_LBUTTONDOWN => try self.onLeftDown(x, y),
        c.WM_LBUTTONDBLCLK => try self.onDoubleClick(x, y),
        c.WM_LBUTTONUP => {
            self.drag = .none;
            if (c.GetCapture() == self.hwnd) _ = c.ReleaseCapture();
        },
        c.WM_CAPTURECHANGED => self.drag = .none,
        c.WM_MBUTTONDOWN => switch (self.hitTest(x, y)) {
            .tab, .tab_close => |i| self.postCloseTab(self.tabs.items[i].id, .this),
            else => {},
        },

        else => return null,
    }
    return 0;
}
