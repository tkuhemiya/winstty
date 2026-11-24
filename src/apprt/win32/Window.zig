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
const Outline = @import("Outline.zig");
const Session = @import("Session.zig");
const Surface = @import("Surface.zig");
const Ticker = @import("Ticker.zig");
const c = @import("c.zig");
const glass = @import("glass.zig");
const layoutpkg = @import("layout.zig");
const motion = @import("motion.zig");
const paint = @import("paint.zig");
const rex = @import("../../rex/main.zig");

const log = std.log.scoped(.win32);

pub const Tree = SplitTree(Surface);
const Layout = layoutpkg.Layout(Surface);

/// Posted by `requestCloseTab`. wParam is the tab ID, lParam the mode.
const WM_CLOSE_TAB = c.WM_APP + 1;

/// Posted to destroy the surfaces that the layout is done with.
const WM_BURY = c.WM_APP + 2;

/// Posted to close the window because there's nothing left to show.
pub const WM_SESSION_ENDED = c.WM_APP + 3;

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

// Of the side panel.
const panel_width = 200;
const panel_min_width = 64;
const panel_pad = 6;
const row_height = 34;
const row_gap = 2;
const row_radius = 9;
const row_pad = 10;
const thumb_width = 3;

/// The panel gives way to the terminal.
const terminal_min_width = 280;

/// The size of a terminal doesn't follow its area below this while it moves.
const moving_min_width = 160;
const moving_min_height = 80;

/// At most this long before anything moves, for the first frames to be drawn.
const prepare_ms = 120;

/// At most this long in each frame, for the frames of panes.
const await_ms = 5;

/// Retries destroying surfaces while a message box is open.
const bury_timer = 1;

/// Turns what shows that programs are working.
const spinner_timer = 3;
const spinner_ms = 80;

/// Closes the window once there's no message box open.
const ended_timer = 4;
const ended_ms = 100;
const bury_ms = 100;

/// Glass is taken away after everything on it is opaque.
const backing_timer = 2;
const backing_ms = 120;

pub const Tab = struct {
    /// Unique for the life of the app, so it can be posted in messages.
    id: u32,
    tree: Tree,

    /// The surface with focus when the tab is selected. Always in the tree.
    focused: *Surface,
    title_override: ?[:0]const u8 = null,

    /// Where it is in the side panel, in rows.
    row: motion.Spring = .at(0),

    /// The window of the session that this is, if it's one.
    rex_id: []const u8 = "",

    fn deinit(self: *Tab, alloc: Allocator) void {
        if (self.rex_id.len > 0) alloc.free(self.rex_id);
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

/// The title of a tab as it's shown. A blank one is a way of hiding the title
/// of the window, but tabs need something to tell them apart.
fn tabLabel(self: *const Window, index: usize, buf: *[8]u8) []const u8 {
    const title = std.mem.trim(u8, self.tabs.items[index].title(), " ");
    if (title.len > 0) return title;
    return std.fmt.bufPrint(buf, "{}", .{index + 1}) catch "";
}

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
    /// Whether there's room for more than the gap.
    shown: bool,
};

const Hit = union(enum) {
    none,
    tab: usize,
    tab_close: usize,
    new_tab,
    button: Button,

    /// Anywhere else at the top, which moves the window.
    caption,

    /// Anywhere else in the side panel.
    panel,
    divider: usize,

    fn eql(a: Hit, b: Hit) bool {
        return std.meta.eql(a, b);
    }
};

const Button = enum { close, minimize, zoom };

const Drag = union(enum) {
    none,
    tab: struct { start_x: c_int, start_y: c_int, moving: bool = false },
    row: RowDrag,
    divider: usize,
};

/// A tab being moved in the side panel.
const RowDrag = struct {
    id: u32,
    /// Where on the row it was taken hold of.
    grab: c_int,
    start_y: c_int,
    moving: bool = false,
    /// Where it would be dropped.
    to: usize,
};

app: *App,
hwnd: c.HWND,
tabs: std.ArrayList(Tab) = .empty,
active: usize = 0,
title_override: ?[:0]const u8 = null,

/// Where the panes of the active tab are.
layout: Layout,
/// The tab that the layout is of.
layout_tab: u32 = 0,
placements: std.ArrayList(Layout.Placement) = .empty,
boundaries: std.ArrayList(Layout.Boundary) = .empty,
dividers: std.ArrayList(Divider) = .empty,
cards: std.ArrayList(Card) = .empty,

/// How much of a card panes are, from filling the window to being one.
card_amount: motion.Spring = .at(0),

/// What's drawn of the window.
back: ?paint.Back = null,

/// How much of the side panel is in view.
panel: motion.Spring = .at(0),
/// Whether it has been shown or hidden by hand.
panel_override: ?bool = null,
/// Pixels scrolled off the top of the list of tabs.
panel_scroll: c_int = 0,
tooltip: ?c.HWND = null,
/// What the tooltip is of, as `setHover` last saw it.
tooltip_tab: ?usize = null,

/// The pane that has the outline. Only for comparing.
outlined: ?*const Surface = null,
/// The outline on its way from where it was.
outline_from: paint.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
outline_amount: motion.Spring = .at(1),
outline_window: ?Outline = null,

hover: Hit = .none,
drag: Drag = .none,
tracking_leave: bool = false,
font: ?c.HFONT = null,
font_bold: ?c.HFONT = null,
font_icon: ?c.HFONT = null,

/// Where the selection is drawn, as a tab index. It moves towards `active`.
selection: motion.Spring = .at(0),

/// Frames of animation are wanted, the last of which was at this time.
animating: bool = false,
last_frame: ?i64 = null,
started: i64 = 0,

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

/// What's shown, if it's a session of a server.
session: ?*Session = null,

/// The angle of what shows that programs are working, in steps.
spinner: u8 = 0,
spinning: bool = false,

/// True if background-opacity is toggled off.
force_opaque: bool = false,

/// Whether we're glass as far as the compositor knows.
frosted: bool = false,
power_notification: ?c.HANDLE = null,

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

/// Create a window on a session, which is shown once there's something in it.
/// Takes over the client and the target if this doesn't fail.
pub fn createFor(app: *App, client: *rex.Client, path: [:0]const u16, target: Session.Target) !void {
    const self = try createEmpty(app);
    errdefer _ = c.DestroyWindow(self.hwnd);
    self.session = try .create(app, self, client, path, target);
    self.session.?.start();
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
    self.* = .{ .app = app, .hwnd = hwnd, .layout = .init(alloc) };
    try app.windows.append(alloc, self);

    // From here, destroying the window deinitializes us.
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateFont();
    self.syncAppearance();
    self.power_notification = c.RegisterPowerSettingNotification(hwnd, &c.GUID_POWER_SAVING_STATUS, 0);
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
    self.forgetLayout();
    while (self.tabs.pop()) |popped| {
        // Nothing may be found through a tab that's going away.
        var tab = popped;
        self.active = 0;
        tab.deinit(alloc);
    }
    self.leaveSession();
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
    if (self.power_notification) |v| _ = c.UnregisterPowerSettingNotification(v);
    self.forgetLayout();
    for (self.tabs.items) |*tab| tab.deinit(alloc);
    self.tabs.deinit(alloc);
    self.leaveSession();
    if (self.back) |v| v.deinit();
    self.layout.deinit();
    self.placements.deinit(alloc);
    self.boundaries.deinit(alloc);
    self.dividers.deinit(alloc);
    self.cards.deinit(alloc);
    if (self.title_override) |v| alloc.free(v);
    for ([_]?c.HFONT{ self.font, self.font_bold, self.font_icon }) |font| {
        if (font) |v| _ = c.DeleteObject(v);
    }
    alloc.destroy(self);
}

/// What's in the session keeps running.
fn leaveSession(self: *Window) void {
    const session = self.session orelse return;
    self.session = null;
    session.destroy();
}

//---------------------------------------------------------------
// Sessions

/// The tab of a window of the session.
fn tabOf(self: *const Window, rex_id: []const u8) ?usize {
    for (self.tabs.items, 0..) |tab, i| {
        if (std.mem.eql(u8, tab.rex_id, rex_id)) return i;
    }
    return null;
}

/// Be like the session, except for what can't be shown yet, and what has been
/// changed here since.
pub fn followView(self: *Window, session: *Session, view: *const rex.view.View) !void {
    const alloc = self.app.core_app.alloc;

    // What's shown of another session stays until there's something of this.
    const any = for (view.items()) |*window| {
        const layout = window.layout() orelse continue;
        if (session.isReady(layout) or self.tabOf(window.id()) != null) break true;
    } else false;
    if (!any) return;

    const may_focus = session.focusing == 0 and view.revision >= session.focus_revision;
    const may_resize = session.resizing == 0 and
        view.revision >= session.ratio_revision and
        self.drag != .divider;
    const first = self.tabs.items.len == 0;
    const was_active = if (self.activeTab()) |v| v.id else 0;
    const was_focused = self.activeSurface();

    // What's replaced has to last until the layout has followed.
    var old: std.ArrayList(Tree) = .empty;
    defer {
        for (old.items) |*v| v.deinit();
        old.deinit(alloc);
    }
    var gone: std.ArrayList(Tab) = .empty;
    defer {
        for (gone.items) |*v| v.deinit(alloc);
        gone.deinit(alloc);
    }

    var order: usize = 0;
    for (view.items()) |*window| {
        const layout = window.layout() orelse continue;
        const index = self.tabOf(window.id());
        if (!session.isReady(layout)) {
            // It stays as it is for now.
            if (index) |v| {
                self.placeTab(v, order);
                order += 1;
            }
            continue;
        }
        var tree = try self.treeOf(session, layout) orelse continue;
        const focused = session.surfaceOf(window.focused_block_id orelse "") orelse firstOf(&tree);
        if (index) |v| {
            const tab = &self.tabs.items[v];
            if (sameTree(&tab.tree, &tree, !may_resize)) {
                tree.deinit();
            } else {
                errdefer tree.deinit();
                const zoomed: ?*Surface = if (tab.tree.zoomed) |z| tab.tree.nodes[z.idx()].leaf else null;
                try old.append(alloc, tab.tree);
                tab.tree = tree;
                if (zoomed) |z| if (tab.tree.locate(z)) |handle| tab.tree.zoom(handle);
                if (tab.tree.locate(tab.focused) == null) tab.focused = focused;
            }
            self.placeTab(v, order);
        } else {
            errdefer tree.deinit();
            try self.tabs.ensureUnusedCapacity(alloc, 1);
            const id = try alloc.dupe(u8, window.id());
            self.tabs.insertAssumeCapacity(@min(order, self.tabs.items.len), .{
                .id = self.app.nextTabId(),
                .tree = tree,
                .focused = focused,
                .rex_id = id,
                .row = .at(@floatFromInt(order)),
            });
        }
        const tab = &self.tabs.items[order];
        order += 1;
        try self.replaceTitle(&tab.title_override, window.chosenLabel() orelse "");
        if (may_focus) {
            if (tab.tree.locate(focused) != null) tab.focused = focused;
            const zoomed = session.surfaceOf(window.zoomed_block_id orelse "");
            tab.tree.zoom(if (zoomed) |v| tab.tree.locate(v) else null);
        }
    }

    // What's left isn't in the session, or can't be shown.
    while (self.tabs.items.len > order) {
        try gone.append(alloc, self.tabs.pop().?);
    }

    // Which one is shown.
    const wanted = if (may_focus) self.tabOf(view.active_window_id orelse "-") else null;
    self.active = wanted orelse for (self.tabs.items, 0..) |tab, i| {
        if (tab.id == was_active) break i;
    } else @min(self.active, self.tabs.items.len -| 1);
    if (self.tabs.items.len == 0) {
        self.forgetLayout();
        return;
    }
    for (self.tabs.items, 0..) |*tab, i| if (i != self.active) setTabVisible(tab, false);
    for (gone.items) |*tab| setTabVisible(tab, false);
    if (first) {
        self.selection = .at(@floatFromInt(self.active));
        self.drag = .none;
    }
    self.refresh();
    self.revealActive();
    if (first) {
        self.show();
        session.own("take");
    } else if (self.activeSurface() != was_focused or self.activeTab().?.id != was_active) {
        self.focusActive();
        session.own(if (self.is_active) "take" else "request");
    } else if (old.items.len > 0) session.own("request");
}

/// Move a tab that's further along, or where it belongs already.
fn placeTab(self: *Window, from: usize, to: usize) void {
    if (from == to or to >= self.tabs.items.len) return;
    const tab = self.tabs.orderedRemove(from);
    self.tabs.insertAssumeCapacity(to, tab);
}

/// The tree of a layout. Null if there's nothing in it that can be shown.
fn treeOf(self: *Window, session: *Session, node: *const rex.view.Node) !?Tree {
    const alloc = self.app.core_app.alloc;
    const split = node.split orelse {
        const surface = session.surfaceOf(node.block_id orelse return null) orelse return null;
        return try Tree.init(alloc, surface);
    };
    var before = try self.treeOf(session, split.before) orelse return try self.treeOf(session, split.after);
    var after = after: {
        errdefer before.deinit();
        break :after try self.treeOf(session, split.after) orelse return before;
    };
    defer before.deinit();
    defer after.deinit();
    return try before.split(
        alloc,
        .root,
        switch (split.axis()) {
            .horizontal => .right,
            .vertical => .down,
        },
        @floatCast(std.math.clamp(split.ratio, 0.01, 0.99)),
        &after,
    );
}

fn firstOf(tree: *const Tree) *Surface {
    var it = tree.iterator();
    return it.next().?.view;
}

fn sameTree(a: *const Tree, b: *const Tree, any_ratio: bool) bool {
    return sameNode(a, .root, b, .root, any_ratio);
}

fn sameNode(
    a: *const Tree,
    at_a: Tree.Node.Handle,
    b: *const Tree,
    at_b: Tree.Node.Handle,
    any_ratio: bool,
) bool {
    switch (a.nodes[at_a.idx()]) {
        .leaf => |v| return switch (b.nodes[at_b.idx()]) {
            .leaf => |w| v == w,
            .split => false,
        },
        .split => |v| switch (b.nodes[at_b.idx()]) {
            .leaf => return false,
            .split => |w| {
                if (v.layout != w.layout) return false;
                if (!any_ratio and @abs(v.ratio - w.ratio) > 0.0005) return false;
                return sameNode(a, v.left, b, w.left, any_ratio) and
                    sameNode(a, v.right, b, w.right, any_ratio);
            },
        },
    }
}

/// Called when the connection is lost, or is back.
pub fn titleOfSession(self: *Window) void {
    // There may be a title bar just for this.
    self.refresh();
}

/// Called when what programs are doing has changed.
pub fn statusChanged(self: *Window) void {
    self.invalidateBar();
    if (self.palette) |v| v.sessionsChanged();
    const session = self.session orelse return;
    const spins = self.app.motionStyle() != .off and for (self.tabs.items, 0..) |*tab, i| {
        if (i != self.active and tabStatus(session, tab).state == .working) break true;
    } else false;
    if (spins == self.spinning) return;
    self.spinning = spins and c.SetTimer(self.hwnd, spinner_timer, spinner_ms, null) != 0;
    if (!spins) _ = c.KillTimer(self.hwnd, spinner_timer);
}

/// What the program of a tab that needs the user the most is doing.
fn tabStatus(session: *Session, tab: *const Tab) rex.status.Summary {
    var result: rex.status.Summary = .{};
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const v = session.summary(entry.view);
        if (@backingInt(v.state) > @backingInt(result.state)) result = v;
    }
    return result;
}

fn markOf(self: *const Window, summary: rex.status.Summary) paint.Buffer.Mark {
    return switch (summary.state) {
        .idle => .none,
        .working => .{ .working = .{
            .progress = summary.progress,
            .spinner = if (self.spinning) self.spinner else null,
        } },
        .blocked => .blocked,
        .done => .done,
        .@"error" => .@"error",
    };
}

/// The mark of a tab that isn't the active one.
fn tabMark(self: *const Window, index: usize) paint.Buffer.Mark {
    const session = self.session orelse return .none;
    if (index == self.active) return .none;
    return self.markOf(tabStatus(session, &self.tabs.items[index]));
}

/// What other sessions need the user for, if they do.
fn elsewhereMark(self: *const Window) paint.Buffer.Mark {
    const session = self.session orelse return .none;
    return switch (session.elsewhere()) {
        .idle, .working => .none,
        .done => .done,
        .blocked => .blocked,
        .@"error" => .@"error",
    };
}

/// The user is leaving a pane, and has seen what's in it.
fn leavePane(self: *Window, surface: *const Surface) void {
    const session = self.session orelse return;
    if (self.is_active and !session.following) session.see(surface);
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

/// A new tab, as soon as it can be had.
pub fn openTab(self: *Window) !void {
    if (self.session) |v| return v.newTab();
    _ = try self.newTab(.tab);
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
    self.tabs.items[index].row = .at(@floatFromInt(index));
    self.active = index;
    if (self.tabs.items.len == 1) self.selection = .at(0);
    self.refresh();
    self.revealActive();
    self.focusActive();
}

pub fn selectTab(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len or index == self.active) return;
    self.leavePane(self.tabs.items[self.active].focused);
    setTabVisible(&self.tabs.items[self.active], false);
    self.active = index;
    self.refresh();
    self.revealActive();
    self.focusActive();
    if (self.session) |v| {
        v.tabSelected(self.tabs.items[index].rex_id);
        self.statusChanged();
    }
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
    self.selection.target = @floatFromInt(self.active);
    if (!self.animates()) self.selection.finish();
    self.syncRows();
    self.revealActive();
    self.invalidateBar();
    self.startMotion();
    if (self.session) |v| v.moveTab(
        self.tabs.items[to].rex_id,
        if (to + 1 < self.tabs.items.len) self.tabs.items[to + 1].rex_id else null,
    );
}

/// Move the tab with the given surface to a window of its own.
pub fn moveTabToNewWindow(self: *Window, surface: *const Surface) !bool {
    // A window is all of a session.
    if (self.session != null) return false;
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
        self.revealActive();
        if (was_active) self.focusActive();
    } else {
        // It's about to be destroyed, or not ours.
        self.forgetLayout();
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

    if (self.session) |session| {
        for (self.tabs.items, 0..) |tab, i| {
            if (Match.match(mode, i, base)) session.closeTab(tab.rex_id);
        }
        return;
    }

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
    if (self.session) |v| return v.closeBlock(surface);
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
    var old = loc.tab.tree;
    loc.tab.tree = tree;
    loc.tab.focused = next;
    self.refresh();
    if (!surface.dying) surface.setVisible(false);
    if (loc.index == self.active) self.focusActive();

    // This drops the last reference to the surface, unless it's still shown
    // making room.
    old.deinit();
}

pub fn needsConfirm(self: *const Window) bool {
    // It ends nothing.
    if (self.session != null) return false;
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
    if (self.session) |session| {
        // What's running there isn't ours to end, so have a tab for it.
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        return session.newTabWith(try Session.splitCommand(arena.allocator(), command));
    }
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
    if (self.session) |session| {
        session.newSplit(from, switch (direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        }, direction == .left or direction == .up);
        return true;
    }

    const surface = try Surface.create(self, .split, self.halfOf(from, direction), null);
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

/// About what a new split will have, so that it starts out with that.
fn halfOf(self: *const Window, from: *const Surface, direction: apprt.action.SplitDirection) c.RECT {
    var rect = self.contentRect();
    for (self.cards.items) |card| if (card.surface == from) {
        rect = card.hole;
    };
    switch (direction) {
        .left, .right => rect.right = rect.left + @divTrunc(rect.right - rect.left, 2),
        .up, .down => rect.bottom = rect.top + @divTrunc(rect.bottom - rect.top, 2),
    }
    return rect;
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
    self.leavePane(loc.tab.focused);
    loc.tab.focused = loc.tab.tree.nodes[handle.idx()].leaf;
    self.refresh();
    self.focusActive();
    if (self.session) |session| {
        if (loc.tab.tree.zoomed != null)
            session.paneZoomed(loc.tab.focused, true)
        else
            session.paneFocused(loc.tab.focused);
    }
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
    if (self.session) |v| v.ratiosChanged();
    return true;
}

pub fn equalizeSplits(self: *Window, from: *Surface) !bool {
    const loc = self.locate(from) orelse return false;
    if (!loc.tab.tree.isSplit()) return false;
    setTree(loc.tab, try loc.tab.tree.equalize(self.app.core_app.alloc));
    self.refresh();
    if (self.session) |v| v.ratiosChanged();
    return true;
}

pub fn toggleZoom(self: *Window, from: *Surface) bool {
    const loc = self.locate(from) orelse return false;
    if (!loc.tab.tree.isSplit()) return false;
    loc.tab.tree.zoom(if (loc.tab.tree.zoomed == null) loc.handle else null);
    loc.tab.focused = from;
    self.refresh();
    if (self.session) |v| v.paneZoomed(from, loc.tab.tree.zoomed != null);
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
    self.leavePane(loc.tab.focused);
    loc.tab.focused = surface;
    if (self.session) |v| v.paneFocused(surface);
    syncDimming(loc.tab);
    self.titleChanged(surface);
    if (loc.index == self.active) {
        self.syncOutline(self.animates());
        self.startMotion();
    }
    if (self.hasCards()) _ = c.InvalidateRect(self.hwnd, null, 0);
}

pub fn titleChanged(self: *Window, surface: *const Surface) void {
    const loc = self.locate(surface) orelse return;
    self.invalidateBar();
    self.updateTooltip();
    if (loc.index == self.active) self.updateTitle();
}

pub fn setTabTitle(self: *Window, surface: *const Surface, title: []const u8) !bool {
    const loc = self.locate(surface) orelse return false;
    if (self.session) |v| {
        v.setTabLabel(loc.tab.rex_id, title);
        return true;
    }
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

fn shownTitle(self: *const Window, tab: *const Tab) []const u8 {
    if (self.session) |v| if (v.lost) return "Reconnecting to Rex...";
    return self.title_override orelse tab.title();
}

fn updateTitle(self: *Window) void {
    const tab = self.activeTab() orelse return;
    const alloc = self.app.core_app.alloc;
    const title = std.unicode.wtf8ToWtf16LeAllocZ(alloc, self.shownTitle(tab)) catch return;
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

/// Whether tabs are shown, wherever that is.
fn tabsVisible(self: *const Window) bool {
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.tabs.items.len > 1,
        .never => false,
    };
}

fn tabsAtSide(self: *const Window) bool {
    return self.app.config.@"win32-tab-bar" == .side;
}

/// Whether tabs are in a bar at the top.
fn barVisible(self: *const Window) bool {
    return !self.tabsAtSide() and self.tabsVisible();
}

/// Whether tabs are in a panel at the side.
fn panelVisible(self: *const Window) bool {
    return self.tabsAtSide() and (self.panel_override orelse self.tabsVisible());
}

/// Show or hide the side panel, whatever is configured.
pub fn togglePanel(self: *Window) bool {
    if (!self.tabsAtSide()) return false;
    self.panel_override = !self.panelVisible();
    self.dropRow(false);
    self.refresh();
    self.revealActive();
    self.updateTooltip();
    return true;
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

/// Whether there's a title bar, of those that could have one. With tabs at the
/// side there's nothing for it but the buttons, if they're shown, and to say
/// that the server is gone.
fn needsTitle(self: *const Window) bool {
    if (!self.tabsAtSide()) return true;
    if (self.app.config.@"macos-window-buttons" == .visible) return true;
    const session = self.session orelse return false;
    return session.lost;
}

/// The title bar if we're the one drawing it.
fn titleRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.bottom = if (self.windowed != null or !self.needsTitle()) 0 else switch (self.titlebarStyle()) {
        .native, .hidden => 0,
        // Tabs take the place of the title.
        .transparent => self.scaled(if (self.barVisible()) strip_height else title_height),
        .tabs => self.scaled(if (self.tabsAtSide()) title_height else strip_height),
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
    if (self.tabsAtSide()) {
        const panel = self.panelRect();
        const pad = self.scaled(panel_pad);
        const offset = @min(0, panel.right - self.panelWidth());
        return .{
            .left = offset + pad,
            .top = panel.bottom - pad - self.scaled(row_height),
            .right = offset + self.panelWidth() - pad,
            .bottom = panel.bottom - pad,
        };
    }
    const pill = self.pillRect();
    const left = pill.right + self.scaled(strip_margin);
    return .{ .left = left, .top = pill.top, .right = left + pill.bottom - pill.top, .bottom = pill.bottom };
}

/// The width of the side panel when it's all in view.
fn panelWidth(self: *const Window) c_int {
    const client = self.clientRect();
    return std.math.clamp(
        client.right - self.scaled(terminal_min_width),
        @min(self.scaled(panel_min_width), @divTrunc(client.right, 3)),
        self.scaled(panel_width),
    );
}

/// The side panel, as much as is in view. It comes in from the left.
fn panelRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.top = self.barRect().bottom;
    const width: f32 = @floatFromInt(self.panelWidth());
    rect.right = @intFromFloat(@round(width * std.math.clamp(self.panel.value, 0, 1.2)));
    return rect;
}

/// What's above the list of tabs in the side panel.
fn listRect(self: *const Window) c.RECT {
    const panel = self.panelRect();
    const pad = self.scaled(panel_pad);

    // All of it moves, rather than being uncovered.
    const offset = @min(0, panel.right - self.panelWidth());
    const top = panel.top + if (self.titleRect().bottom > 0) 0 else pad;
    return .{
        .left = offset + pad,
        .top = top,
        .right = offset + self.panelWidth() - pad,
        .bottom = @max(top, self.newTabRect().top - self.scaled(row_gap)),
    };
}

/// A position in the list as it's scrolled, in rows.
fn rowRect(self: *const Window, position: f32) c.RECT {
    const list = self.listRect();
    const height = self.rowStride();
    const top = list.top - self.panel_scroll +
        @as(c_int, @intFromFloat(@round(position * @as(f32, @floatFromInt(height)))));
    return .{
        .left = list.left,
        .top = top,
        .right = list.right,
        .bottom = top + self.scaled(row_height),
    };
}

fn rowStride(self: *const Window) c_int {
    return self.scaled(row_height) + self.scaled(row_gap);
}

fn maxPanelScroll(self: *const Window) c_int {
    const list = self.listRect();
    const rows: c_int = @intCast(self.tabs.items.len);
    return @max(0, rows * self.rowStride() - self.scaled(row_gap) - (list.bottom - list.top));
}

fn setPanelScroll(self: *Window, value: c_int) void {
    const scroll = std.math.clamp(value, 0, self.maxPanelScroll());
    if (scroll == self.panel_scroll) return;
    self.panel_scroll = scroll;
    self.invalidateBar();
    self.updateTooltip();
}

/// Scroll the selected tab in to view.
fn revealActive(self: *Window) void {
    const list = self.listRect();
    const top = @as(c_int, @intCast(self.active)) * self.rowStride();
    const bottom = top + self.scaled(row_height);
    const view = list.bottom - list.top;
    self.setPanelScroll(@max(@min(self.panel_scroll, top), bottom - view));
}

/// The area of the client that holds surfaces.
pub fn contentRect(self: *const Window) c.RECT {
    var rect = self.clientRect();
    rect.top = self.barRect().bottom;
    rect.left = self.panelRect().right;
    return rect;
}

/// Bring the child windows, tab bar and title in line with our state.
pub fn refresh(self: *Window) void {
    self.relayout();
    self.updateTitle();
    self.invalidateBar();
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

//---------------------------------------------------------------
// Motion

/// Whether what changes now gets there over time. A window that isn't active
/// only finishes what it's doing.
pub fn animates(self: *const Window) bool {
    if (self.app.motionStyle() == .off or self.minimized) return false;
    if (c.IsWindowVisible(self.hwnd) == 0) return false;
    return self.is_active or self.moving();
}

/// Whether panes or the side panel are moving.
fn layoutMoving(self: *const Window) bool {
    return self.layout.moving() or self.card_amount.moving() or self.panel.moving();
}

fn moving(self: *const Window) bool {
    if (self.layoutMoving() or self.selection.moving() or self.outline_amount.moving()) return true;
    for (self.tabs.items) |*tab| if (tab.row.moving()) return true;
    return false;
}

fn startMotion(self: *Window) void {
    // It's no longer where it was.
    if (self.outline_amount.moving()) self.showOutline();
    if (self.animating or !self.moving()) return;
    self.last_frame = null;
    self.started = Ticker.now();
    self.animating = self.app.ticker.start();
    if (!self.animating) self.finishMotion();
}

/// Whether to wait with moving until what has been made larger has been drawn.
/// What's shown of it is the same until then.
fn unprepared(self: *const Window, now: i64) bool {
    if (self.last_frame != null or Ticker.milliseconds(self.started, now) > prepare_ms) return false;
    for (self.cards.items) |card| {
        if (card.surface.fit.moving and !card.surface.isPresented()) return true;
    }
    return false;
}

/// Have everything be where it's going to be.
fn finishMotion(self: *Window) void {
    self.layout.finish();
    self.card_amount.finish();
    self.panel.finish();
    self.selection.finish();
    self.outline_amount.finish();
    for (self.tabs.items) |*tab| tab.row.finish();
    self.arrange();
    self.hideOutline();
    self.bury();
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

/// A frame of animation. Returns whether another is wanted.
pub fn frame(self: *Window) bool {
    if (!self.animating) return false;
    const now = Ticker.now();
    if (self.unprepared(now)) return true;

    // It was at rest until now, however long ago the last frame was.
    const elapsed: f32 = if (self.last_frame) |v|
        std.math.clamp(Ticker.milliseconds(v, now), 1, 50) / 1000
    else
        0.008;
    self.last_frame = now;

    const style = self.app.motionStyle();
    const layout_moved = self.layoutMoving();
    const panel_moved = self.panel.moving();
    const cards_moved = self.card_amount.moving();
    _ = self.layout.step(style, elapsed);
    self.card_amount.step(style, elapsed);
    self.panel.step(style, elapsed);
    self.selection.step(style, elapsed);
    self.outline_amount.step(style, elapsed);
    for (self.tabs.items) |*tab| tab.row.step(style, elapsed);

    if (layout_moved and !self.minimized) {
        // The bars have text that takes a while to draw, so not for each frame.
        const bars = panel_moved or cards_moved or self.selection.moving();
        self.arrange();
        self.awaitPanes();
        const content = self.contentRect();
        _ = c.InvalidateRect(self.hwnd, if (bars) null else &content, 0);
    } else {
        self.invalidateBar();
    }
    const more = self.moving();
    if (!more) {
        self.animating = false;
        // For the outline that's no longer in a window of its own.
        _ = c.InvalidateRect(self.hwnd, null, 0);
    }
    _ = c.UpdateWindow(self.hwnd);
    self.showOutline();
    self.bury();
    return more;
}

/// Wait until panes have been drawn where they are now, so that the gaps
/// between them don't get ahead of them. It's fine if they don't make it.
fn awaitPanes(self: *Window) void {
    const start = Ticker.now();
    for (self.cards.items) |card| {
        while (card.surface.fit.moving and !card.surface.isPresented()) {
            const left = await_ms - Ticker.milliseconds(start, Ticker.now());
            if (left < 1) return;
            _ = c.WaitForSingleObject(self.app.presented, @intFromFloat(left));
        }
    }
}

/// Set where each tab goes in the side panel.
fn syncRows(self: *Window) void {
    const dragged: ?struct { from: usize, to: usize } = dragged: {
        if (self.drag != .row or !self.drag.row.moving) break :dragged null;
        const from = self.tabIndex(self.drag.row.id) orelse break :dragged null;
        break :dragged .{ .from = from, .to = self.drag.row.to };
    };
    const animated = self.panelVisible() and self.animates();
    for (self.tabs.items, 0..) |*tab, i| {
        const row = if (dragged) |v| row: {
            // It's where the pointer has it.
            if (i == v.from) continue;
            const others = if (i > v.from) i - 1 else i;
            break :row if (others >= v.to) others + 1 else others;
        } else i;
        tab.row.target = @floatFromInt(row);
        if (!animated) tab.row.finish();
    }
}

fn tabIndex(self: *const Window, id: u32) ?usize {
    for (self.tabs.items, 0..) |tab, i| if (tab.id == id) return i;
    return null;
}

/// Have the outline go to the pane with the focus.
fn syncOutline(self: *Window, animated: bool) void {
    const tab = self.activeTab() orelse return;
    if (self.outlined == tab.focused) return;
    const from = self.outlineRect();
    self.outlined = tab.focused;
    if (from == null or !animated or !self.is_active or
        self.layout_tab != tab.id or self.card_amount.target == 0)
    {
        self.outline_amount.finish();
        return;
    }
    self.outline_from = from.?;
    self.outline_amount = .{ .value = 0, .target = 1 };
}

/// What the outline is around at the moment.
fn outlineRect(self: *const Window) ?paint.Rect {
    for (self.cards.items) |card| {
        if (card.surface != self.outlined) continue;
        const to: paint.Rect = .from(card.card);
        if (!self.outline_amount.moving()) return if (card.shown) to else null;
        // It may go past the pane, but not over anything else.
        const r = self.outline_from.toward(to, self.outline_amount.value);
        const within: paint.Rect = .from(insetRect(self.contentRect(), self.scaled(outline_focused)));
        const left = @max(r.x, within.x);
        const top = @max(r.y, within.y);
        return .{
            .x = left,
            .y = top,
            .w = @max(0, @min(r.x + r.w, within.x + within.w) - left),
            .h = @max(0, @min(r.y + r.h, within.y + within.h) - top),
        };
    }
    return null;
}

fn showOutline(self: *Window) void {
    if (!self.outline_amount.moving() or self.minimized) return self.hideOutline();
    const rect = self.outlineRect() orelse return self.hideOutline();
    if (self.outline_window == null) {
        self.outline_window = Outline.create(self.hwnd, self.app.hinstance) catch return;
    }
    self.outline_window.?.show(
        self.hwnd,
        rect,
        @floatFromInt(self.scaled(card_radius)),
        @floatFromInt(self.scaled(outline_focused)),
        self.outlineColor(self.colors()),
    );
}

fn hideOutline(self: *Window) void {
    if (self.outline_window) |v| v.hide();
}

/// There's nothing left to show.
fn sessionEnded(self: *Window) !void {
    _ = c.KillTimer(self.hwnd, ended_timer);
    if (self.app.modal > 0) {
        _ = c.SetTimer(self.hwnd, ended_timer, ended_ms, null);
        return;
    }
    self.destroy();
}

/// Destroy what the layout is done with, once it's safe to.
fn bury(self: *Window) void {
    if (self.layout.dead.items.len == 0) return;
    for (self.layout.dead.items) |surface| surface.setVisible(false);
    _ = c.PostMessageW(self.hwnd, WM_BURY, 0, 0);
}

fn onBury(self: *Window) void {
    _ = c.KillTimer(self.hwnd, bury_timer);
    if (self.app.modal > 0) {
        _ = c.SetTimer(self.hwnd, bury_timer, bury_ms, null);
        return;
    }
    while (self.layout.dead.pop()) |surface| surface.unref();
}

/// Called when the tabs are about to be destroyed.
fn forgetLayout(self: *Window) void {
    self.layout.reset();
    self.layout_tab = 0;
    self.cards.clearRetainingCapacity();
    self.dividers.clearRetainingCapacity();
    self.placements.clearRetainingCapacity();
    self.outlined = null;
    while (self.layout.dead.pop()) |surface| surface.unref();
}

//---------------------------------------------------------------
// Panes

fn relayout(self: *Window) void {
    self.relayoutWith(self.animates());
}

/// Set where everything goes, and go there if not animated.
fn relayoutWith(self: *Window, animated: bool) void {
    const tab = self.activeTab() orelse return;
    self.syncOutline(animated);

    // Another tab is shown at once.
    const same = self.layout_tab == tab.id;
    if (!same) {
        self.layout.reset();
        self.layout_tab = tab.id;
        self.outline_amount.finish();
    }
    self.layout.sync(&tab.tree, animated and same) catch |err| {
        // It starts over the next time.
        log.warn("error in layout err={}", .{err});
        self.layout.reset();
    };

    self.card_amount.target = if (self.hasCards()) 1 else 0;
    if (!animated or !same) self.card_amount.finish();
    self.panel.target = if (self.panelVisible()) 1 else 0;
    if (!animated) self.panel.finish();
    self.selection.target = @floatFromInt(self.active);
    if (!animated) self.selection.finish();
    self.syncRows();
    self.setPanelScroll(self.panel_scroll);

    self.arrange();
    self.bury();
    self.startMotion();
}

/// Put everything where it is at the moment.
fn arrange(self: *Window) void {
    self.dividers.clearRetainingCapacity();
    self.cards.clearRetainingCapacity();
    if (self.minimized) return;
    const tab = self.activeTab() orelse return;
    syncDimming(tab);
    const max = self.maxPane();
    self.layout.arrange(
        self.cardsRect(self.contentRect()),
        &self.placements,
        &self.boundaries,
    ) catch |err| {
        log.warn("error in layout err={}", .{err});
        return;
    };

    const alloc = self.app.core_app.alloc;
    const half = @divTrunc(self.scaled(divider_width), 2);
    for (self.boundaries.items) |v| {
        var rect = v.area;
        switch (v.axis) {
            .horizontal => {
                rect.left = v.at - half;
                rect.right = v.at + half;
            },
            .vertical => {
                rect.top = v.at - half;
                rect.bottom = v.at + half;
            },
        }
        self.dividers.append(alloc, .{
            .rect = rect,
            .handle = v.handle,
            .layout = v.axis,
            .area = v.area,
        }) catch {};
    }

    const is_moving = self.layoutMoving();
    const gap = self.partly(half);
    const inset = gap + self.partly(self.scaled(card_inset));
    for (self.placements.items) |v| {
        const surface = v.view;
        if (v.dying) surface.setDying();
        const card = insetRect(v.area, gap);
        const hole = insetRect(v.area, inset);
        const shown = v.area.right - v.area.left > inset * 2 and
            v.area.bottom - v.area.top > inset * 2;
        self.cards.append(alloc, .{
            .surface = surface,
            .area = v.area,
            .card = card,
            .hole = hole,
            .shown = shown,
        }) catch {};

        const fit: Surface.Fit = fit: {
            if (v.vanishing) break :fit .{
                .moving = is_moving,
                .max_width = max.cx,
                .max_height = max.cy,
                .frozen = true,
            };
            if (!is_moving) break :fit .{ .max_width = max.cx, .max_height = max.cy };
            const target = insetRect(v.target, inset);
            const width = target.right - target.left;
            const height = target.bottom - target.top;
            break :fit .{
                .moving = true,
                .max_width = max.cx,
                .max_height = max.cy,
                // What appears is uncovered, as it already has its size.
                .min_width = if (v.appearing) width else @min(width, self.scaled(moving_min_width)),
                .min_height = if (v.appearing) height else @min(height, self.scaled(moving_min_height)),
            };
        };
        if (shown or !v.vanishing) surface.place(hole, fit);

        // Hiding waits for what's being drawn, so that's for when it's at rest.
        if (!shown and is_moving and surface.visible) surface.cutOff() else surface.setVisible(shown);
    }
    self.repositionOverlays();
}

/// The largest a pane could be, or nothing if they don't move.
pub fn maxPane(self: *const Window) c.SIZE {
    if (self.app.motionStyle() == .off) return .{};
    const client = self.clientRect();
    return .{ .cx = client.right, .cy = client.bottom - self.barRect().bottom };
}

/// As much of a length as panes are cards.
fn partly(self: *const Window, v: c_int) c_int {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * self.cardAmount()));
}

fn cardAmount(self: *const Window) f32 {
    return std.math.clamp(self.card_amount.value, 0, 1);
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
    const band = self.partly(self.scaled(card_margin) - @divTrunc(self.scaled(divider_width), 2));
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
    if (self.panelVisible()) rect.right += self.scaled(panel_width);
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
    // Opaque or not, it's only opacity that can be toggled off.
    if (!self.canToggleOpacity()) self.force_opaque = false;
    self.syncAppearance();
    self.updateFont();
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            entry.view.configChanged();
            entry.view.syncBackground();
            if (self.force_opaque) entry.view.updateOpacity();
            if (entry.view.search) |v| v.lookChanged();
        }
    }
    if (self.palette) |v| v.lookChanged();
    if (self.session) |v| v.configChanged();
    self.drag = .none;
    self.refresh();
    self.revealActive();
}

/// Called when we have, or have to, become glass or stop being that.
pub fn lookChanged(self: *Window) void {
    self.syncTransparency();
    for (self.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            entry.view.syncBackground();
            if (entry.view.search) |v| v.lookChanged();
        }
    }
    if (self.palette) |v| v.lookChanged();
    _ = c.RedrawWindow(self.hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ALLCHILDREN);
}

pub fn look(self: *const Window) glass.Look {
    const result = self.app.look();
    return if (result == .frost and self.force_opaque) .solid else result;
}

fn opacity(self: *const Window) glass.Opacity {
    return .init(&self.app.config, if (self.force_opaque) .solid else self.look());
}

/// What our surfaces use for the background, see `Surface.background`.
pub fn background(self: *const Window) u64 {
    return @bitCast(glass.Background.init(&self.app.config, self.look()));
}

fn colors(self: *const Window) paint.Palette {
    return .init(&self.app.config);
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
    return self.opacity().card;
}

fn canToggleOpacity(self: *const Window) bool {
    return self.app.config.@"win32-glass" or self.app.config.@"background-opacity" < 1;
}

pub fn toggleOpacity(self: *Window) bool {
    if (!self.canToggleOpacity()) return false;
    self.force_opaque = !self.force_opaque;
    if (self.app.config.@"win32-glass") {
        self.lookChanged();
        return true;
    }
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
    const is_frost = self.look() == .frost;

    // What's shown is translucent until it's drawn again.
    if (self.frosted and !is_frost and c.IsWindowVisible(self.hwnd) != 0 and
        c.SetTimer(self.hwnd, backing_timer, backing_ms, null) != 0) return;
    self.applyTransparency();
}

fn applyTransparency(self: *Window) void {
    _ = c.KillTimer(self.hwnd, backing_timer);
    const current = self.look();
    self.frosted = current == .frost;
    glass.setBacking(self.hwnd, switch (current) {
        .frost => .{ .frost = self.colors().bg },
        .solid => .solid,
        .off => if (self.backgroundOpacity() == 255)
            .solid
        else switch (self.app.config.@"background-blur") {
            .false => .clear,
            .radius => |v| if (v > 0) .blur else .clear,
            .true, .@"macos-glass-regular", .@"macos-glass-clear" => .blur,
        },
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
    const panel = self.panelRect();
    if (panel.right > 0) _ = c.InvalidateRect(self.hwnd, &panel, 0);
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
    if (self.tabsAtSide()) return self.rowRect(@floatFromInt(index));
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
    const space = @divTrunc(tab.bottom - tab.top - size, 2);
    const top = tab.top + space;
    const left = if (self.tabsAtSide()) tab.right - space - size else tab.left + space;
    return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
}

/// Where the title of a row goes.
fn rowLabelRect(self: *const Window, row: c.RECT, hovered: bool) c.RECT {
    const pad = self.scaled(row_pad);
    const side = row.bottom - row.top;
    return .{
        .left = row.left + pad,
        .top = row.top,
        .right = @max(row.left + pad, if (hovered) row.right - side else row.right - pad),
        .bottom = row.bottom,
    };
}

fn onPaint(self: *Window) void {
    var ps: c.PAINTSTRUCT = .{};
    const dc = c.BeginPaint(self.hwnd, &ps) orelse return;
    defer _ = c.EndPaint(self.hwnd, &ps);

    const client = self.clientRect();
    if (self.back) |v| if (v.width != client.right or v.height != client.bottom) {
        v.deinit();
        self.back = null;
    };
    if (self.back == null) self.back = .init(dc, client.right, client.bottom);
    const back = self.back orelse return;

    // What isn't to be shown doesn't need to be drawn.
    const palette: paint.Palette = .init(&self.app.config);
    const content = self.contentRect();
    if ((self.cardAmount() > 0 or self.layoutMoving()) and c.RectVisible(dc, &content) != 0) {
        self.paintCards(back.dc, palette);
    }
    const panel = self.panelRect();
    if (panel.right > 0 and c.RectVisible(dc, &panel) != 0) self.paintPanel(back.dc, palette);
    const bar = self.barRect();
    if (bar.bottom > 0 and c.RectVisible(dc, &bar) != 0) self.paintBar(back.dc, palette);
    back.show(dc, ps.rcPaint);
}

fn paintBar(self: *Window, dc: c.HDC, palette: paint.Palette) void {
    const bar = self.barRect();
    var buf = paint.Buffer.begin(dc, bar) orelse return;
    defer buf.end();
    self.paintBase(&buf, palette, .bar);
    if (self.buttonsVisible()) self.paintButtons(buf, palette);
    if (self.barVisible()) self.paintTabs(buf, palette) else self.paintTitle(buf, palette);
}

const Base = enum { bar, gap };

/// Cards are on something that's a little further back than they are.
fn paintBase(self: *const Window, buf: *paint.Buffer, palette: paint.Palette, base: Base) void {
    const color, const alpha = self.baseColor(palette, base);
    buf.base(color, alpha);
}

fn baseColor(self: *const Window, palette: paint.Palette, base: Base) struct { paint.Rgb, u8 } {
    const alpha = self.opacity();
    if (base == .bar and self.look() == .frost) return .{ palette.bg, alpha.bar };

    // More of what's behind the window is seen between cards.
    const amount = self.cardAmount();
    const card: f32 = @floatFromInt(alpha.card);
    const gap: f32 = @floatFromInt(alpha.gap);
    return .{
        palette.bg.mix(palette.backdrop, @intFromFloat(@round(amount * 255))),
        @intFromFloat(@round(card + (gap - card) * amount)),
    };
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
        self.paintBase(&buf, palette, .gap);
        buf.end();
    }

    const focused = self.activeSurface();
    for (self.cards.items) |card| {
        if (!card.shown) {
            var buf = paint.Buffer.begin(dc, card.area) orelse continue;
            defer buf.end();
            self.paintBase(&buf, palette, .gap);
            continue;
        }

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
            self.paintBase(&buf, palette, .gap);
            self.paintCard(
                buf,
                rect,
                card.card,
                palette,
                // While it's on its way it's in a window of its own.
                card.surface == focused and !self.outline_amount.moving(),
            );
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
    const amount = self.cardAmount();
    const radius: f32 = @as(f32, @floatFromInt(self.scaled(card_radius))) * amount;
    var r: paint.Rect = .from(card);
    r.x -= @floatFromInt(part.left);
    r.y -= @floatFromInt(part.top);
    buf.replaceRound(r, radius, palette.bg, self.backgroundOpacity());
    if (self.look() != .off) {
        const dark = palette.bg.isDark();
        const light: paint.Rgb = if (dark)
            .{ .r = 215, .g = 215, .b = 215 }
        else
            .{ .r = 255, .g = 255, .b = 255 };
        const thickness: f32 = @floatFromInt(@max(1, self.scaled(1)));
        buf.highlight(r, radius, thickness, light, amount * @as(f32, if (dark) 0.38 else 0.85));
    }

    // The outline is in the gap around the card, and takes nothing of it.
    const thickness: f32 = @floatFromInt(self.scaled(if (focused) outline_focused else outline));
    const color = if (focused) self.outlineColor(palette) else palette.divider;
    buf.outline(r.inset(-thickness), radius + thickness, thickness, color);
}

fn outlineColor(self: *const Window, palette: paint.Palette) paint.Rgb {
    return if (self.is_active) palette.accent else palette.accent.mix(palette.backdrop, 128);
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
        self.shownTitle(tab),
        rect,
        self.font_bold,
        palette.fg,
        0.85 * self.emphasis(),
        c.DT_CENTER,
    );
    const size = self.scaled(close_size);
    const title = self.titleRect();
    const top = @divTrunc(title.bottom - size, 2);
    const right = title.right - self.scaled(strip_margin);
    buf.statusMark(
        .{ .left = right - size, .top = top, .right = right, .bottom = top + size },
        self.elsewhereMark(),
        palette.fg,
        palette.bg,
        @max(0.6, self.emphasis()),
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
    const selection = self.tabArea(std.math.clamp(self.selection.value, 0, last)).inset(inset);
    if (palette.bg.isDark()) {
        buf.glass(selection, selection.h / 2, palette.fg, 0.07 + 0.08 * strength);
    } else {
        // On a light background, what's raised is brighter than its surroundings.
        buf.round(selection, selection.h / 2, .{ .r = 255, .g = 255, .b = 255 }, 0.45 + 0.5 * strength);
        buf.ring(selection, selection.h / 2, palette.fg, 0.05, 0.16);
    }

    for (0..self.tabs.items.len) |i| {
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
        if (i > 0 and !active and i - 1 != self.active and !self.selection.moving()) {
            buf.round(.{ .x = @floor(area.x), .y = area.y + area.h * 0.3, .w = 1, .h = area.h * 0.4 }, 0, palette.fg, 0.14);
        }

        // Centered, so leave the same space as the close button on the right.
        const close = self.closeRect(i);
        var label = self.tabRect(i);
        const side = close.right - label.left + self.scaled(2);
        label.left += side;
        label.right -= side;
        var number: [8]u8 = undefined;
        if (label.right > label.left) buf.blendText(
            self.tabLabel(i, &number),
            label,
            if (active) self.font_bold else self.font,
            palette.fg,
            (if (active) @as(f32, 0.95) else 0.6) * strength,
            c.DT_CENTER,
        );

        // Opposite of the close button.
        const tab = self.tabRect(i);
        const space = close.left - tab.left;
        buf.statusMark(.{
            .left = tab.right - space - (close.right - close.left),
            .top = close.top,
            .right = tab.right - space,
            .bottom = close.bottom,
        }, self.tabMark(i), palette.fg, palette.bg, strength);

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

    // There's no title to have it beside.
    const size = self.scaled(close_size);
    buf.statusMark(.{
        .left = plus.right - @divTrunc(size * 2, 3),
        .top = plus.top - @divTrunc(size, 4),
        .right = plus.right - @divTrunc(size * 2, 3) + size,
        .bottom = plus.top - @divTrunc(size, 4) + size,
    }, self.elsewhereMark(), palette.fg, palette.bg, @max(0.6, strength));
}

/// The side panel, with a row for each tab.
fn paintPanel(self: *Window, dc: c.HDC, palette: paint.Palette) void {
    const panel = self.panelRect();
    var buf = paint.Buffer.begin(dc, panel) orelse return;
    defer buf.end();
    self.paintBase(&buf, palette, .bar);

    const move = struct {
        fn move(rect: c.RECT, origin: c.RECT) c.RECT {
            return .{
                .left = rect.left - origin.left,
                .top = rect.top - origin.top,
                .right = rect.right - origin.left,
                .bottom = rect.bottom - origin.top,
            };
        }
    }.move;

    // A color that's the opposite of the text needs no help to be seen.
    const contrast = self.app.high_contrast;
    const strength: f32 = if (contrast) 1 else self.emphasis();
    const radius: f32 = @floatFromInt(self.scaled(row_radius));

    const plus = self.newTabRect();
    const plus_at = move(plus, panel);
    if (self.hover == .new_tab) {
        buf.glass(.from(plus_at), radius, palette.fg, if (contrast) 0.3 else 0.1);
    }
    buf.blendText(paint.icon.add, plus_at, self.font_icon, palette.fg, 0.8 * strength, c.DT_CENTER);

    // There's no title to have it beside.
    if (self.titleRect().bottom == 0) {
        const size = self.scaled(close_size);
        const inset = @divTrunc(plus_at.bottom - plus_at.top - size, 2);
        buf.statusMark(.{
            .left = plus_at.right - inset - size,
            .top = plus_at.top + inset,
            .right = plus_at.right - inset,
            .bottom = plus_at.bottom - inset,
        }, self.elsewhereMark(), palette.fg, palette.bg, 1);
    }

    // Between this and the terminal. Cards are their own.
    var line = move(panel, panel);
    line.left = line.right - 1;
    buf.round(.from(line), 0, palette.fg, if (contrast) 1 else 0.12);

    // The thumb of what's scrolled, beside the rows.
    const list = self.listRect();
    const max = self.maxPanelScroll();
    if (max > 0) {
        const list_at = move(list, panel);
        const view = list.bottom - list.top;
        const height = @max(self.scaled(24), @divTrunc(view * view, view + max));
        const top = list_at.top + @divTrunc((view - height) * self.panel_scroll, max);
        const left = list_at.right + @divTrunc(self.scaled(panel_pad - thumb_width), 2);
        buf.round(.from(.{
            .left = left,
            .top = top,
            .right = left + self.scaled(thumb_width),
            .bottom = top + height,
        }), @floatFromInt(self.scaled(thumb_width)), palette.fg, 0.35);
    }

    // Rows that are scrolled out of the list are cut off.
    var rows = paint.Buffer.begin(buf.dc, move(list, panel)) orelse return;
    defer rows.end();
    self.paintBase(&rows, palette, .bar);
    self.paintRows(rows, list, palette, strength, contrast);
}

fn paintRows(
    self: *Window,
    buf: paint.Buffer,
    list: c.RECT,
    palette: paint.Palette,
    strength: f32,
    contrast: bool,
) void {
    if (self.tabs.items.len == 0) return;
    const radius: f32 = @floatFromInt(self.scaled(row_radius));
    const dragged: ?usize = switch (self.drag) {
        .row => |v| if (v.moving) self.tabIndex(v.id) else null,
        else => null,
    };
    const place = struct {
        fn place(rect: c.RECT, origin: c.RECT) c.RECT {
            return .{
                .left = rect.left - origin.left,
                .top = rect.top - origin.top,
                .right = rect.right - origin.left,
                .bottom = rect.bottom - origin.top,
            };
        }
    }.place;

    const last: f32 = @floatFromInt(self.tabs.items.len - 1);
    const at = if (dragged != null and dragged.? == self.active)
        self.tabs.items[self.active].row.value
    else
        std.math.clamp(self.selection.value, 0, last);
    const selection = place(self.rowRect(at), list);
    if (contrast) {
        buf.round(.from(selection), radius, palette.fg, 1);
    } else {
        // As the selected row of the command palette.
        buf.glass(.from(selection), radius, palette.fg, if (self.is_active) 0.14 else 0.10);
    }

    for (self.tabs.items, 0..) |*tab, i| {
        const row = place(self.rowRect(tab.row.value), list);
        if (row.bottom <= 0 or row.top >= list.bottom - list.top) continue;
        const active = i == self.active;
        const hovered = dragged == null and switch (self.hover) {
            .tab, .tab_close => |v| v == i,
            else => false,
        };
        if (hovered and !active) buf.round(.from(row), radius, palette.fg, if (contrast) 0.25 else 0.05);

        const color = if (contrast and active) palette.bg else palette.fg;
        const alpha: f32 = if (contrast) 1 else if (active) 0.95 else 0.65;
        const mark = self.tabMark(i);
        const label = self.rowLabelRect(row, hovered or mark != .none);
        var number: [8]u8 = undefined;
        if (label.right > label.left) buf.blendText(
            self.tabLabel(i, &number),
            label,
            if (active) self.font_bold else self.font,
            color,
            alpha * @max(strength, 0.6),
            c.DT_LEFT,
        );

        // Where the close button is when it's hovered.
        if (!hovered) {
            const side = row.bottom - row.top;
            const inset = @divTrunc(side - self.scaled(close_size), 2);
            buf.statusMark(.{
                .left = row.right - side + inset,
                .top = row.top + inset,
                .right = row.right - inset,
                .bottom = row.bottom - inset,
            }, mark, palette.fg, palette.bg, 1);
        }

        if (hovered) {
            const on_close = self.hover.eql(.{ .tab_close = i });
            const close = place(self.closeRect(i), list);
            const r: paint.Rect = .from(close);
            if (on_close) buf.round(r, r.w / 2, color, 0.16);
            buf.blendText(
                paint.icon.cancel,
                close,
                self.font_icon,
                color,
                if (on_close or contrast) 0.95 else 0.6,
                c.DT_CENTER,
            );
        }
    }
}

//---------------------------------------------------------------
// Tooltip of the side panel

/// Show the title of the tab that's hovered, if there's no room for it.
fn updateTooltip(self: *Window) void {
    const index: ?usize = index: {
        if (!self.panelVisible() or self.drag != .none) break :index null;
        const i = switch (self.hover) {
            .tab => |v| v,
            else => break :index null,
        };
        if (i >= self.tabs.items.len) break :index null;
        var number: [8]u8 = undefined;
        const label = self.rowLabelRect(self.tabRect(i), true);
        const dc = c.GetDC(self.hwnd) orelse break :index null;
        defer _ = c.ReleaseDC(self.hwnd, dc);
        const width = paint.textWidth(
            dc,
            self.tabLabel(i, &number),
            if (i == self.active) self.font_bold else self.font,
        );
        if (self.session) |v| if (tabStatus(v, &self.tabs.items[i]).text.len > 0) break :index i;
        break :index if (width > label.right - label.left) i else null;
    };
    if (index == null and self.tooltip_tab == null) return;
    self.tooltip_tab = index;
    const tooltip = self.ensureTooltip() orelse return;

    var tool: c.TOOLINFOW = .{ .hwnd = self.hwnd, .uId = 1 };
    const alloc = self.app.core_app.alloc;
    const i = index orelse {
        tool.lpszText = c.L("");
        _ = c.SendMessageW(tooltip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&tool)));
        _ = c.SendMessageW(tooltip, c.TTM_NEWTOOLRECTW, 0, @bitCast(@intFromPtr(&tool)));
        _ = c.SendMessageW(tooltip, c.TTM_POP, 0, 0);
        return;
    };
    var number: [8]u8 = undefined;
    const says = if (self.session) |v| tabStatus(v, &self.tabs.items[i]).text else "";
    const utf8 = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{
        self.tabLabel(i, &number),
        if (says.len > 0) ": " else "",
        says,
    }) catch return;
    defer alloc.free(utf8);
    const text = std.unicode.wtf8ToWtf16LeAllocZ(alloc, utf8) catch return;
    defer alloc.free(text);
    tool.lpszText = text;
    tool.rect = self.tabRect(i);
    _ = c.SendMessageW(tooltip, c.TTM_UPDATETIPTEXTW, 0, @bitCast(@intFromPtr(&tool)));
    _ = c.SendMessageW(tooltip, c.TTM_NEWTOOLRECTW, 0, @bitCast(@intFromPtr(&tool)));
}

/// It's destroyed along with us.
fn ensureTooltip(self: *Window) ?c.HWND {
    if (self.tooltip) |v| return v;
    const hwnd = c.CreateWindowExW(
        0,
        c.L("tooltips_class32"),
        c.L(""),
        c.WS_POPUP | c.TTS_ALWAYSTIP | c.TTS_NOPREFIX,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        self.hwnd,
        null,
        self.app.hinstance,
        null,
    ) orelse return null;
    const tool: c.TOOLINFOW = .{
        .uFlags = c.TTF_SUBCLASS,
        .hwnd = self.hwnd,
        .uId = 1,
        .lpszText = c.L(""),
    };
    _ = c.SendMessageW(hwnd, c.TTM_ADDTOOLW, 0, @bitCast(@intFromPtr(&tool)));
    self.tooltip = hwnd;
    return hwnd;
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
    if (contains(self.panelRect(), x, y)) {
        if (contains(self.newTabRect(), x, y)) return .new_tab;
        const list = self.listRect();
        if (contains(list, x, y)) {
            const index: usize = @intCast(@divTrunc(y - list.top + self.panel_scroll, self.rowStride()));
            if (index < self.tabs.items.len) {
                if (contains(self.closeRect(index), x, y)) return .{ .tab_close = index };
                return .{ .tab = index };
            }
        }
        // There's nothing else to move the window by without a title bar.
        return if (self.titleRect().bottom == 0) .caption else .panel;
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
        .row => |*drag| {
            if (!drag.moving and @abs(y - drag.start_y) > self.scaled(4)) {
                drag.moving = true;
                self.updateTooltip();
            }
            if (drag.moving) self.dragRow(y);
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

            // It's where the pointer has it.
            self.relayoutWith(false);
            if (self.session) |v| v.ratiosChanged();
            _ = c.InvalidateRect(self.hwnd, null, 0);
        },
    }

    self.setHover(self.hitTest(x, y));
}

/// Have the row that's held be where the pointer is.
fn dragRow(self: *Window, y: c_int) void {
    const index = self.tabIndex(self.drag.row.id) orelse {
        self.drag = .none;
        return;
    };
    const list = self.listRect();

    // Keep going at the ends of a list that's scrolled.
    const step = @divTrunc(self.rowStride(), 4);
    if (y < list.top) self.setPanelScroll(self.panel_scroll - step);
    if (y >= list.bottom) self.setPanelScroll(self.panel_scroll + step);

    const last: f32 = @floatFromInt(self.tabs.items.len - 1);
    const offset: f32 = @floatFromInt(y - self.drag.row.grab - list.top + self.panel_scroll);
    const position = std.math.clamp(offset / @as(f32, @floatFromInt(self.rowStride())), 0, last);
    self.tabs.items[index].row = .at(position);
    self.drag.row.to = @intFromFloat(@round(position));
    self.syncRows();
    self.invalidateBar();
    self.startMotion();
}

/// Let go of the row that's held, if any.
fn dropRow(self: *Window, commit: bool) void {
    const drag = switch (self.drag) {
        .row => |v| v,
        else => return,
    };
    self.drag = .none;
    if (!drag.moving) return;
    const index = self.tabIndex(drag.id) orelse return;
    if (index == self.active) {
        // The selection was moved along with it.
        self.selection.value = self.tabs.items[index].row.value;
        self.selection.velocity = 0;
    }
    if (commit and drag.to < self.tabs.items.len) self.moveTabTo(index, drag.to);
    self.relayout();
    self.invalidateBar();
}

fn setHover(self: *Window, hover: Hit) void {
    if (hover.eql(self.hover)) return;
    self.hover = hover;
    self.invalidateBar();
    self.updateTooltip();
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
        .none, .caption, .button, .panel => {},
        .tab => |i| if (self.tabsAtSide()) {
            self.selectTab(i);
            self.drag = .{ .row = .{
                .id = self.tabs.items[i].id,
                .grab = y - self.tabRect(i).top,
                .start_y = y,
                .to = i,
            } };
            _ = c.SetCapture(self.hwnd);
        } else {
            self.selectTab(i);
            self.drag = .{ .tab = .{ .start_x = x, .start_y = y } };
            _ = c.SetCapture(self.hwnd);
        },
        .tab_close => |i| self.postCloseTab(self.tabs.items[i].id, .this),
        .new_tab => try self.openTab(),
        .divider => |i| {
            self.drag = .{ .divider = i };
            _ = c.SetCapture(self.hwnd);
        },
    }
    self.focusActive();
}

fn onDoubleClick(self: *Window, x: c_int, y: c_int) !void {
    switch (self.hitTest(x, y)) {
        .caption => try self.openTab(),
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
        c.WM_TIMER => switch (wparam) {
            bury_timer => self.onBury(),
            backing_timer => self.applyTransparency(),
            spinner_timer => {
                self.spinner +%= 1;
                self.invalidateBar();
            },
            ended_timer => try self.sessionEnded(),
            else => return null,
        },
        WM_BURY => self.onBury(),
        WM_SESSION_ENDED => try self.sessionEnded(),

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
            if (!self.is_active) {
                self.outline_amount.finish();
                self.hideOutline();
            } else if (self.session) |v| v.own("take");
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
                self.revealActive();
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
                if (self.panelVisible()) rect.right += self.panelWidth();
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
            self.app.systemChanged();
            self.syncAppearance();
            try self.app.colorSchemeChanged();
        },

        c.WM_POWERBROADCAST, c.WM_DISPLAYCHANGE, c.WM_THEMECHANGED, c.WM_SYSCOLORCHANGE => {
            self.app.systemChanged();
            return null;
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
            self.setHover(.none);
        },
        c.WM_MOUSEWHEEL => {
            var point: c.POINT = .{ .x = x, .y = y };
            _ = c.ScreenToClient(self.hwnd, &point);
            if (!contains(self.panelRect(), point.x, point.y)) return null;
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            self.setPanelScroll(self.panel_scroll - @divTrunc(@as(c_int, delta) * self.rowStride(), 60));
            self.setHover(self.hitTest(point.x, point.y));
        },
        c.WM_LBUTTONDOWN => try self.onLeftDown(x, y),
        c.WM_LBUTTONDBLCLK => try self.onDoubleClick(x, y),
        c.WM_LBUTTONUP => {
            self.dropRow(true);
            self.drag = .none;
            if (c.GetCapture() == self.hwnd) _ = c.ReleaseCapture();
        },
        c.WM_CAPTURECHANGED => {
            self.dropRow(false);
            self.drag = .none;
        },
        c.WM_MBUTTONDOWN => switch (self.hitTest(x, y)) {
            .tab, .tab_close => |i| self.postCloseTab(self.tabs.items[i].id, .this),
            else => {},
        },

        else => return null,
    }
    return 0;
}
