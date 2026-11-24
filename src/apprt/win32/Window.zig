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
const tab_bar_height = 34;
const tab_max_width = 220;
const tab_button_width = 34;
const tab_close_width = 28;
const divider_width = 5;

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

const Hit = union(enum) {
    none,
    tab: usize,
    tab_close: usize,
    new_tab,
    bar,
    divider: usize,

    fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

const Drag = union(enum) {
    none,
    tab: struct { start_x: c_int, moving: bool = false },
    divider: usize,
};

app: *App,
hwnd: c.HWND,
tabs: std.ArrayList(Tab) = .empty,
active: usize = 0,
title_override: ?[:0]const u8 = null,

dividers: std.ArrayList(Divider) = .empty,
hover: Hit = .none,
drag: Drag = .none,
tracking_leave: bool = false,
font: ?c.HFONT = null,
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
    if (self.title_override) |v| alloc.free(v);
    if (self.font) |v| _ = c.DeleteObject(v);
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
    const alloc = self.app.core_app.alloc;
    try self.tabs.ensureUnusedCapacity(alloc, 1);

    const surface = try Surface.create(self, context, self.contentRect());
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
            if (raw < 0) return false;
            break :index @min(@as(usize, @intCast(raw)), len - 1);
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

pub fn newSplit(
    self: *Window,
    from: *Surface,
    direction: apprt.action.SplitDirection,
) !bool {
    const alloc = self.app.core_app.alloc;
    if (self.locate(from) == null) return false;

    const surface = try Surface.create(self, .split, self.contentRect());
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
    self.titleChanged(surface);
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

fn barRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.bottom = if (self.barVisible()) self.scaled(tab_bar_height) else 0;
    return rect;
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
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

fn relayout(self: *Window) void {
    self.dividers.clearRetainingCapacity();
    if (self.minimized) return;
    const tab = self.activeTab() orelse return;
    const content = self.contentRect();
    if (tab.tree.zoomed) |zoomed| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| if (entry.handle != zoomed) entry.view.setVisible(false);
        self.layoutNode(tab, zoomed, content);
    } else {
        self.layoutNode(tab, .root, content);
    }
    self.repositionOverlays();
}

fn layoutNode(self: *Window, tab: *Tab, handle: Tree.Node.Handle, area: c.RECT) void {
    switch (tab.tree.nodes[handle.idx()]) {
        .leaf => |surface| {
            _ = c.SetWindowPos(
                surface.hwnd,
                null,
                area.left,
                area.top,
                @max(1, area.right - area.left),
                @max(1, area.bottom - area.top),
                c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_NOCOPYBITS,
            );
            surface.setVisible(true);
        },

        .split => |split| {
            const gap = self.scaled(divider_width);
            const horizontal = split.layout == .horizontal;
            const start, const end = if (horizontal)
                .{ area.left, area.right }
            else
                .{ area.top, area.bottom };
            const space = @max(0, end - start - gap);
            const ratio: f32 = split.ratio;
            const at = start + @as(c_int, @intFromFloat(ratio * @as(f32, @floatFromInt(space))));

            var first = area;
            var second = area;
            var rect = area;
            if (horizontal) {
                first.right = at;
                rect.left = at;
                rect.right = at + gap;
                second.left = at + gap;
            } else {
                first.bottom = at;
                rect.top = at;
                rect.bottom = at + gap;
                second.top = at + gap;
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
    _ = c.AdjustWindowRectExForDpi(rect, style, 0, 0, self.getDpi());
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
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.configChanged();
    }
    self.refresh();
}

/// Match the frame to the configured theme.
fn syncAppearance(self: *Window) void {
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
}

fn updateFont(self: *Window) void {
    if (self.font) |v| _ = c.DeleteObject(v);
    self.font = paint.uiFont(9, self.getDpi());
}

fn invalidateBar(self: *Window) void {
    const rect = self.barRect();
    if (rect.bottom > 0) _ = c.InvalidateRect(self.hwnd, &rect, 0);
}

fn tabWidth(self: *const Window) c_int {
    const len: c_int = @intCast(@max(1, self.tabs.items.len));
    const space = self.clientRect().right - self.scaled(tab_button_width);
    return @max(1, @min(self.scaled(tab_max_width), @divTrunc(space, len)));
}

fn tabRect(self: *const Window, index: usize) c.RECT {
    const width = self.tabWidth();
    const left = width * @as(c_int, @intCast(index));
    return .{ .left = left, .top = 0, .right = left + width, .bottom = self.barRect().bottom };
}

fn onPaint(self: *Window) void {
    var ps: c.PAINTSTRUCT = .{};
    const dc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    const palette: paint.Palette = .init(&self.app.config);
    for (self.dividers.items) |divider| {
        const buf = paint.Buffer.begin(dc, divider.rect) orelse continue;
        defer buf.end();
        const r = divider.rect;
        var line: c.RECT = .{ .right = r.right - r.left, .bottom = r.bottom - r.top };
        buf.fill(line, palette.bg);
        // A thin line in the middle of a gap that's wide enough to grab.
        const thickness = @max(1, self.scaled(1));
        switch (divider.layout) {
            .horizontal => {
                line.left = @divTrunc(line.right - thickness, 2);
                line.right = line.left + thickness;
            },
            .vertical => {
                line.top = @divTrunc(line.bottom - thickness, 2);
                line.bottom = line.top + thickness;
            },
        }
        buf.fill(line, palette.divider);
    }

    const bar = self.barRect();
    if (bar.bottom == 0) return;
    const buf = paint.Buffer.begin(dc, bar) orelse return;
    defer buf.end();
    buf.fill(bar, palette.bar);

    const pad = self.scaled(10);
    for (self.tabs.items, 0..) |*tab, i| {
        const rect = self.tabRect(i);
        const active = i == self.active;
        const hovered = switch (self.hover) {
            .tab, .tab_close => |v| v == i,
            else => false,
        };
        if (active) buf.fill(rect, palette.bg) else if (hovered) buf.fill(rect, palette.hover);

        var close = rect;
        close.left = close.right - self.scaled(tab_close_width);
        var label = rect;
        label.left += pad;
        label.right = close.left;
        const color = if (active) palette.fg else palette.dim;
        buf.text(tab.title(), label, self.font, color, 0);
        if (active or hovered) {
            const on_close = self.hover.eql(.{ .tab_close = i });
            buf.text("✕", close, self.font, if (on_close) palette.fg else palette.dim, c.DT_CENTER);
        }
    }

    var plus = self.tabRect(self.tabs.items.len);
    plus.right = plus.left + self.scaled(tab_button_width);
    if (self.hover == .new_tab) buf.fill(plus, palette.hover);
    buf.text("＋", plus, self.font, palette.dim, c.DT_CENTER);
}

//---------------------------------------------------------------
// Mouse

fn contains(rect: c.RECT, x: c_int, y: c_int) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn hitTest(self: *const Window, x: c_int, y: c_int) Hit {
    if (contains(self.barRect(), x, y)) {
        const index: usize = @intCast(@divTrunc(x, self.tabWidth()));
        if (index < self.tabs.items.len) {
            const rect = self.tabRect(index);
            if (x >= rect.right - self.scaled(tab_close_width)) return .{ .tab_close = index };
            return .{ .tab = index };
        }
        const left = self.tabRect(self.tabs.items.len).left;
        if (x < left + self.scaled(tab_button_width)) return .new_tab;
        return .bar;
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
            if (drag.moving and self.tabs.items.len > 0) {
                const max = self.tabs.items.len - 1;
                const to: usize = @min(max, @as(usize, @intCast(@max(0, @divTrunc(x, self.tabWidth())))));
                self.moveTabTo(self.active, to);
            }
        },
        .divider => |index| if (index < self.dividers.items.len) {
            const divider = self.dividers.items[index];
            const tab = self.activeTab() orelse return;
            const gap = self.scaled(divider_width);
            const pos, const start, const end = switch (divider.layout) {
                .horizontal => .{ x, divider.area.left, divider.area.right },
                .vertical => .{ y, divider.area.top, divider.area.bottom },
            };
            const space = end - start - gap;
            if (space <= 0) return;
            const ratio = @as(f32, @floatFromInt(pos - start - @divTrunc(gap, 2))) /
                @as(f32, @floatFromInt(space));
            tab.tree.resizeInPlace(divider.handle, @floatCast(std.math.clamp(ratio, 0.05, 0.95)));
            self.relayout();
            _ = c.InvalidateRect(self.hwnd, null, 0);
        },
    }

    const hover = self.hitTest(x, y);
    if (!hover.eql(self.hover)) {
        self.hover = hover;
        self.invalidateBar();
    }
}

fn onLeftDown(self: *Window, x: c_int, y: c_int) !void {
    switch (self.hitTest(x, y)) {
        .none, .bar => {},
        .tab => |i| {
            self.selectTab(i);
            self.drag = .{ .tab = .{ .start_x = x } };
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
        .bar => _ = try self.newTab(.tab),
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
            _ = c.DestroyWindow(self.hwnd);
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
