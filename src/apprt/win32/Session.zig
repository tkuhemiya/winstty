//! A session of the Rex server that a window shows.
//!
//! The server has the session, and its view of it is the one that counts. Its
//! windows are our tabs, and its blocks are our panes. What the user does is
//! asked of the server, and the window follows once the server says it's so.
//! The exceptions are what must not wait, such as focus and dividers, where the
//! window goes ahead and what the server said before that is ignored.
//!
//! Each window has a connection of its own, since a client can only show a
//! block once.
const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const termio = @import("../../termio.zig");
const rex = @import("../../rex/main.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig");

const log = std.log.scoped(.rex);

const shell_flavor = "com.superlogical.terminal.shell";
const terminal_creator = "com.superlogical.terminal";

/// What a connection is for.
pub const Target = union(enum) {
    /// The session that was used last, or else any, or else a new one.
    last,
    new,
    /// An identifier.
    id: []const u8,

    pub fn dupe(self: Target, alloc: Allocator) !Target {
        return switch (self) {
            .last => .last,
            .new => .new,
            .id => |v| .{ .id = try alloc.dupe(u8, v) },
        };
    }

    pub fn deinit(self: Target, alloc: Allocator) void {
        switch (self) {
            .last, .new => {},
            .id => |v| alloc.free(v),
        }
    }
};

/// A block of the session.
pub const Block = struct {
    id: []const u8,

    /// What shows it, once there is one. Owned by the tabs of the window.
    surface: ?*Surface = null,

    /// There has been a request for a ticket, or a stream is being opened.
    opening: bool = false,
    failed: bool = false,
    tries: u8 = 0,

    /// In the view, as of the last time we looked.
    wanted: bool = false,
};

/// A pane that has said what it's doing, in this session or another.
pub const Report = struct {
    records: rex.status.Records = .{},
};

/// Another session, and what its panes are doing.
pub const Peer = struct {
    id: []const u8,
    label: []const u8,
    reports: std.StringHashMapUnmanaged(Report) = .empty,

    fn deinit(self: *Peer, alloc: Allocator) void {
        var it = self.reports.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.records.deinit(alloc);
        }
        self.reports.deinit(alloc);
        alloc.free(self.id);
        alloc.free(self.label);
    }

    pub fn summary(self: *const Peer) rex.status.Summary {
        var result: rex.status.Summary = .{};
        var it = self.reports.valueIterator();
        while (it.next()) |v| {
            const other = v.records.summary();
            if (@backingInt(other.state) > @backingInt(result.state)) result = other;
        }
        return result;
    }
};

/// What a response is for.
const Pending = union(enum) {
    ignore,
    /// Something new that the user asked for, who should know why it isn't there.
    user,
    bootstrap,
    create,
    attach: []const u8,
    view,
    ticket: []const u8,
    focus,
    ratio,
    blocks: []const u8,
    status: struct { session: []const u8, block: []const u8 },
    title: []const u8,
    destroy,

    fn deinit(self: Pending, alloc: Allocator) void {
        switch (self) {
            .attach, .ticket, .blocks, .title => |v| alloc.free(v),
            .status => |v| {
                alloc.free(v.session);
                alloc.free(v.block);
            },
            else => {},
        }
    }
};

alloc: Allocator,
app: *App,
window: *Window,
client: *rex.Client,

/// Has only the pipe of the server.
path_buf: [260:0]u16,
path_len: usize,

/// What was asked for, until there's a session.
target: Target,

/// The identifier of the session. Empty until there is one.
id: []const u8 = "",
label: []const u8 = "",

/// What the server last told us.
view_arena: ArenaAllocator,
view: rex.view.View = .{},
fetching: bool = false,
newest_revision: u64 = 0,

blocks: std.StringHashMapUnmanaged(*Block) = .empty,
peers: std.ArrayList(*Peer) = .empty,
pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,

/// Requests that move the focus and have not been answered, and the revision of
/// the last one that was. Older views would move it back.
focusing: usize = 0,
focus_revision: u64 = 0,

/// The same for the ratios of splits.
resizing: usize = 0,
ratio_revision: u64 = 0,
/// There's a newer layout to send once that has been answered.
ratios_waiting: bool = false,

/// The window is being made to follow the server.
following: bool = false,

/// Streams being opened, by threads that have to finish before we're gone.
openers: usize = 0,

/// The connection has ended, and another is on its way.
lost: bool = false,
reconnects: u32 = 0,

/// Takes over the client, and the target.
pub fn create(
    app: *App,
    window: *Window,
    client: *rex.Client,
    path: [:0]const u16,
    target: Target,
) !*Session {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(Session);
    self.* = .{
        .alloc = alloc,
        .app = app,
        .window = window,
        .client = client,
        .path_buf = undefined,
        .path_len = path.len,
        .target = target,
        .view_arena = .init(alloc),
    };
    @memcpy(self.path_buf[0..path.len], path);
    self.path_buf[path.len] = 0;
    return self;
}

/// The tabs of the window must be gone. Everything keeps running.
pub fn destroy(self: *Session) void {
    const alloc = self.alloc;
    self.client.leave();
    self.forgetRequests();
    self.pending.deinit(alloc);
    self.forgetBlocks();
    self.blocks.deinit(alloc);
    for (self.peers.items) |v| {
        v.deinit(alloc);
        alloc.destroy(v);
    }
    self.peers.deinit(alloc);
    self.target.deinit(alloc);
    if (self.id.len > 0) alloc.free(self.id);
    if (self.label.len > 0) alloc.free(self.label);
    self.view_arena.deinit();
    alloc.destroy(self);
}

fn forgetRequests(self: *Session) void {
    var it = self.pending.valueIterator();
    while (it.next()) |v| v.deinit(self.alloc);
    self.pending.clearRetainingCapacity();
    self.focusing = 0;
    self.resizing = 0;
    self.fetching = false;
    self.ratios_waiting = false;
}

fn forgetBlocks(self: *Session) void {
    var it = self.blocks.valueIterator();
    while (it.next()) |block| self.freeBlock(block.*);
    self.blocks.clearRetainingCapacity();
}

pub fn pipePath(self: *const Session) [:0]const u16 {
    return self.path_buf[0..self.path_len :0];
}

//---------------------------------------------------------------
// Calling the server

fn call(self: *Session, method: []const u8, args: anytype, what: Pending) void {
    self.tryCall(method, args, what) catch |err| {
        what.deinit(self.alloc);
        log.debug("error calling the server method={s} err={}", .{ method, err });
    };
}

fn tryCall(self: *Session, method: []const u8, args: anytype, what: Pending) !void {
    if (self.lost) return error.Closed;
    try self.pending.ensureUnusedCapacity(self.alloc, 1);
    const id = try self.client.call(method, args);
    self.pending.putAssumeCapacity(id, what);
}

fn callTerminal(
    self: *Session,
    session: []const u8,
    block: []const u8,
    comptime method: []const u8,
    args: anytype,
    what: Pending,
) void {
    self.call(terminal_creator ++ "." ++ method, .{
        .session_id = session,
        .block_id = block,
        .args = args,
    }, what);
}

/// Called once the window is there.
pub fn start(self: *Session) void {
    self.call("session.bootstrap", .{
        .event_scope = "all",
        // We attach to the one we want ourselves.
        .attach_session_ids = @as([]const []const u8, &.{}),
    }, .bootstrap);
}

fn attach(self: *Session, id: []const u8) void {
    const copy = self.alloc.dupe(u8, id) catch return;
    self.call("session.attach", .{ .session_id = id }, .{ .attach = copy });
}

/// The options of a new shell.
const ShellOptions = struct {
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const []const u8 = null,
};
const BlockSpec = struct { flavor: []const u8 = shell_flavor, options: ShellOptions = .{} };
const LayoutSpec = struct { block: BlockSpec = .{} };

/// The directory of the focused pane, if new ones start there.
fn cwd(self: *const Session, arena: Allocator) ?[]const u8 {
    if (!self.app.config.@"window-inherit-working-directory") return null;
    const surface = self.window.activeSurface() orelse return null;
    if (!surface.ready) return null;
    const pwd = (surface.core_surface.pwd(arena) catch return null) orelse return null;
    return if (pwd.len > 0) pwd else null;
}

pub fn newSession(self: *Session, what: Pending) void {
    self.call("session.create", .{
        .initial_windows = [_]struct { layout: LayoutSpec }{.{ .layout = .{} }},
    }, what);
}

pub fn newTab(self: *Session) void {
    self.newTabWith(null);
}

/// A command of an absolute or relative program and its arguments, if any.
pub fn newTabWith(self: *Session, command: ?[]const []const u8) void {
    var arena: ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    self.call("session.new_window", .{
        .session_id = self.id,
        .layout = LayoutSpec{ .block = .{ .options = .{
            .cwd = self.cwd(arena.allocator()),
            .command = command,
            .shell = if (command != null) "none" else null,
        } } },
    }, .user);
}

pub fn newSplit(self: *Session, from: *const Surface, axis: rex.view.Axis, before: bool) void {
    const block = from.block orelse return;
    var arena: ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    self.call("session.new_split", .{
        .session_id = self.id,
        .anchor_id = block.id,
        .direction = @tagName(axis),
        .side = if (before) "before" else "after",
        .layout = LayoutSpec{ .block = .{ .options = .{ .cwd = self.cwd(arena.allocator()) } } },
        .focus = true,
    }, .user);
}

/// This ends the program in it.
pub fn closeBlock(self: *Session, surface: *const Surface) void {
    const block = surface.block orelse return;
    self.call("block.close", .{ .session_id = self.id, .block_id = block.id }, .ignore);
}

/// This ends the programs in it.
pub fn closeTab(self: *Session, window_id: []const u8) void {
    self.call("session.close_window", .{ .session_id = self.id, .window_id = window_id }, .ignore);
}

pub fn setTabLabel(self: *Session, window_id: []const u8, label: []const u8) void {
    self.call("session.set_window_label", .{
        .session_id = self.id,
        .window_id = window_id,
        .label = cutLabel(label),
    }, .ignore);
}

pub fn setLabel(self: *Session, label: []const u8) void {
    self.call("session.set_label", .{ .session_id = self.id, .label = cutLabel(label) }, .ignore);
}

/// No longer than the server takes.
fn cutLabel(label: []const u8) []const u8 {
    const max = 128;
    var it: std.unicode.Utf8Iterator = .{ .bytes = label, .i = 0 };
    for (0..max) |_| _ = it.nextCodepointSlice() orelse break;
    return label[0..it.i];
}

pub fn destroySession(self: *Session) void {
    self.call("session.destroy", .{ .session_id = self.id }, .destroy);
}

pub fn moveTab(self: *Session, window_id: []const u8, before: ?[]const u8) void {
    self.call("session.move_window", .{
        .session_id = self.id,
        .window_id = window_id,
        .before_window_id = before,
    }, .ignore);
}

/// Called when the window has gone ahead and selected a tab.
pub fn tabSelected(self: *Session, window_id: []const u8) void {
    if (self.following or window_id.len == 0) return;
    self.focusing += 1;
    self.tryCall("session.focus_window", .{
        .session_id = self.id,
        .window_id = window_id,
    }, .focus) catch {
        self.focusing -= 1;
    };
    self.own("take");
}

/// Called when the window has gone ahead and focused a pane.
pub fn paneFocused(self: *Session, surface: *const Surface) void {
    if (self.following) return;
    const block = surface.block orelse return;
    self.focusing += 1;
    self.tryCall("session.focus_block", .{
        .session_id = self.id,
        .block_id = block.id,
    }, .focus) catch {
        self.focusing -= 1;
    };
}

/// Called when the window has gone ahead and zoomed, or stopped that.
pub fn paneZoomed(self: *Session, surface: *const Surface, zoomed: bool) void {
    if (self.following) return;
    const block = surface.block orelse return;
    self.focusing += 1;
    self.tryCall("session.zoom_block", .{
        .session_id = self.id,
        .block_id = block.id,
        .zoom = zoomed,
    }, .focus) catch {
        self.focusing -= 1;
    };
}

/// Called when the window has gone ahead and moved the dividers of the active
/// tab.
pub fn ratiosChanged(self: *Session) void {
    if (self.following) return;
    if (self.resizing > 0) {
        self.ratios_waiting = true;
        return;
    }
    const tab = self.window.activeTab() orelse return;
    if (tab.tree.isEmpty()) return;
    self.sendRatios(&tab.tree, .root);
}

fn sendRatios(self: *Session, tree: *const Window.Tree, handle: Window.Tree.Node.Handle) void {
    const split = switch (tree.nodes[handle.idx()]) {
        .leaf => return,
        .split => |v| v,
    };
    defer self.sendRatios(tree, split.left);
    defer self.sendRatios(tree, split.right);

    // The two next to the divider, of which it's the innermost one.
    const before = endOf(tree, split.left, true).block orelse return;
    const after = endOf(tree, split.right, false).block orelse return;
    const ratio: f64 = @floatCast(split.ratio);
    if (self.ratioOf(before.id, after.id)) |v| if (@abs(v - ratio) < 0.0005) return;
    self.resizing += 1;
    self.tryCall("session.resize_pane", .{
        .session_id = self.id,
        .direction = @tagName(split.layout),
        .before_block_id = before.id,
        .after_block_id = after.id,
        .ratio = std.math.clamp(ratio, 0.01, 0.99),
    }, .ratio) catch {
        self.resizing -= 1;
    };
}

fn endOf(tree: *const Window.Tree, handle: Window.Tree.Node.Handle, last: bool) *Surface {
    return switch (tree.nodes[handle.idx()]) {
        .leaf => |v| v,
        .split => |v| endOf(tree, if (last) v.right else v.left, last),
    };
}

/// The ratio of the split that two blocks are the ends of, as the server has it.
fn ratioOf(self: *const Session, before: []const u8, after: []const u8) ?f64 {
    for (self.view.items()) |*window| {
        const layout = window.layout() orelse continue;
        if (ratioIn(layout, before, after)) |v| return v;
    }
    return null;
}

fn ratioIn(node: *const rex.view.Node, before: []const u8, after: []const u8) ?f64 {
    const split = node.split orelse return null;
    if (std.mem.eql(u8, split.before.end(true) orelse "", before) and
        std.mem.eql(u8, split.after.end(false) orelse "", after)) return split.ratio;
    return ratioIn(split.before, before, after) orelse ratioIn(split.after, before, after);
}

/// Have the panes of the active tab be as large as they are here, rather than in
/// another window.
pub fn own(self: *Session, mode: []const u8) void {
    if (self.id.len == 0) return;
    const tab = self.window.activeTab() orelse return;
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(self.alloc);
    var it = tab.tree.iterator();
    while (it.next()) |entry| {
        const block = entry.view.block orelse continue;
        ids.append(self.alloc, block.id) catch return;
    }
    if (ids.items.len == 0) return;
    self.call("session.own_block", .{
        .session_id = self.id,
        .block_ids = ids.items,
        .mode = mode,
    }, .ignore);
}

/// Tell programs of the colors, since the server answers when they ask.
pub fn sendTheme(self: *Session, surface: *const Surface) void {
    const block = surface.block orelse return;
    var arena: ArenaAllocator = .init(self.alloc);
    defer arena.deinit();
    self.sendThemeTo(arena.allocator(), block) catch |err|
        log.debug("error sending the theme err={}", .{err});
}

fn sendThemeTo(self: *Session, arena: Allocator, block: *const Block) !void {
    const config = &self.app.config;
    const hex = struct {
        fn hex(a: Allocator, v: anytype) ![]const u8 {
            return try std.fmt.allocPrint(a, "{x:0>2}{x:0>2}{x:0>2}", .{ v.r, v.g, v.b });
        }
    }.hex;
    const palette = try arena.alloc([]const u8, 256);
    for (palette, config.palette.value, 0..) |*out, color, i| {
        out.* = try std.fmt.allocPrint(arena, "{}={s}", .{ i, try hex(arena, color) });
    }
    self.callTerminal(self.id, block.id, "set_theme", .{
        .foreground = try hex(arena, config.foreground),
        .background = try hex(arena, config.background),
        .palette = palette,
    }, .ignore);
}

pub fn configChanged(self: *Session) void {
    var it = self.blocks.valueIterator();
    while (it.next()) |block| if (block.*.surface) |v| self.sendTheme(v);
}

//---------------------------------------------------------------
// Hearing from the server

/// Called when there's something to take from the client.
pub fn receive(self: *Session) void {
    var messages = self.client.take();
    defer messages.deinit(self.alloc);
    for (messages.items) |message| {
        defer self.alloc.free(message);
        var arena: ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        self.handleMessage(arena.allocator(), message) catch |err|
            log.warn("error handling a message of the server err={}", .{err});
    }
    self.fetchView();
    if (self.client.closed.load(.acquire) and !self.lost) self.loseConnection();
}

fn get(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |v| v.get(key),
        else => null,
    };
}

fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (get(value, key) orelse return null) {
        .string => |v| v,
        else => null,
    };
}

fn getInt(value: std.json.Value, key: []const u8) ?u64 {
    return switch (get(value, key) orelse return null) {
        .integer => |v| std.math.cast(u64, v),
        else => null,
    };
}

fn handleMessage(self: *Session, arena: Allocator, text: []const u8) !void {
    const message = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const kind = getString(message, "type") orelse return;
    if (std.mem.eql(u8, kind, "response")) {
        const id = std.fmt.parseInt(u64, getString(message, "id") orelse return, 10) catch return;
        const kv = self.pending.fetchRemove(id) orelse {
            _ = self.client.writtenId(id);
            return;
        };
        defer kv.value.deinit(self.alloc);
        const failure = if (get(message, "error")) |v| switch (v) {
            .null => null,
            else => v,
        } else null;
        if (failure) |v| return self.failed(kv.value, v);
        try self.answered(arena, kv.value, get(message, "payload") orelse .null);
    } else if (std.mem.eql(u8, kind, "event")) {
        const event = get(message, "payload") orelse return;
        try self.handleEvent(
            getString(event, "type") orelse return,
            get(event, "payload") orelse .null,
        );
    }
}

fn failed(self: *Session, what: Pending, failure: std.json.Value) void {
    const code = getString(failure, "code") orelse "";
    const text = getString(failure, "message") orelse "";
    log.info("the server refused what={t} code={s}", .{ what, code });
    switch (what) {
        .ignore, .blocks, .status, .title, .destroy => {},
        .user => self.app.tell(self.window.hwnd, "Rex couldn't do that", text),
        .view => self.fetching = false,
        .focus => self.focusing -|= 1,
        .ratio => self.ratioDone(null),
        .bootstrap, .create => self.app.post(.{ .failed = .{
            .window = self.window.hwnd,
            .err = error.Refused,
        } }),
        // It's gone, so have another.
        .attach => if (self.peers.items.len > 0 and
            !std.mem.eql(u8, self.peers.items[0].id, what.attach))
            self.attach(self.peers.items[0].id)
        else
            self.newSession(.create),
        .ticket => |id| if (self.blocks.get(id)) |block| {
            // It may be gone, which the view is about to say.
            if (std.mem.eql(u8, code, "session_not_found") or std.mem.eql(u8, code, "not_found")) {
                block.opening = false;
                block.failed = true;
            } else self.openFailed(block);
        },
    }
}

fn answered(self: *Session, arena: Allocator, what: Pending, payload: std.json.Value) !void {
    switch (what) {
        .ignore, .user, .destroy => {},

        .bootstrap => {
            const all = get(payload, "attach_all") orelse .null;
            const sessions = try rex.view.parse([]const rex.view.Session, arena, get(all, "sessions") orelse .{ .array = .init(arena) });
            for (sessions) |v| try self.addPeer(v.session_id, v.label);
            switch (self.target) {
                .new => self.newSession(.create),
                .id => |id| self.attach(id),
                .last => {
                    const last = try self.app.lastSession();
                    defer if (last) |v| self.alloc.free(v);
                    if (last != null and self.peer(last.?) != null) {
                        self.attach(last.?);
                    } else if (self.peers.items.len > 0) {
                        self.attach(self.peers.items[0].id);
                    } else {
                        self.newSession(.create);
                    }
                },
            }
            for (self.peers.items) |v| self.askReports(v.id);
        },

        .create => self.attach(getString(payload, "session_id") orelse return error.ProtocolError),

        .attach => |id| {
            try replace(self.alloc, &self.id, id);
            self.app.setLastSession(id);
            const value = get(payload, "view") orelse return error.ProtocolError;
            try self.setView(value);

            // What's there without anything in it would show nothing.
            if (self.view.items().len == 0) self.newTab();
        },

        .view => {
            self.fetching = false;
            try self.setView(payload);
        },

        .ticket => |id| {
            const block = self.blocks.get(id) orelse return;
            const ticket = getString(payload, "ticket") orelse return self.openFailed(block);
            self.openStream(block, ticket) catch |err| {
                log.warn("error opening a stream err={}", .{err});
                self.openFailed(block);
            };
        },

        .focus => {
            self.focusing -|= 1;
            if (getInt(payload, "revision")) |v| self.focus_revision = @max(self.focus_revision, v);
        },

        .ratio => self.ratioDone(getInt(payload, "revision")),

        .blocks => |session| {
            const list = get(payload, "blocks") orelse return;
            const items = switch (list) {
                .array => |v| v.items,
                else => return,
            };
            for (items) |v| {
                const block = getString(v, "block_id") orelse continue;
                if (!std.mem.eql(u8, getString(v, "creator_name") orelse "", terminal_creator)) continue;
                self.callTerminal(session, block, "program_status", rex.Client.NoArgs{}, .{ .status = .{
                    .session = try self.alloc.dupe(u8, session),
                    .block = try self.alloc.dupe(u8, block),
                } });
            }
        },

        .status => |v| {
            const items = switch (get(payload, "records") orelse return) {
                .array => |a| a.items,
                else => return,
            };
            for (items) |record| try self.setRecord(v.session, v.block, getString(record, "id") orelse "", record);
        },

        .title => |id| {
            const block = self.blocks.get(id) orelse return;
            const surface = block.surface orelse return;
            const title = getString(payload, "title") orelse return;
            if (title.len == 0 or surface.title != null) return;
            const copy = try self.alloc.dupeSentinel(u8, title, 0);
            defer self.alloc.free(copy);
            try surface.setTitle(copy);
        },
    }
}

fn ratioDone(self: *Session, revision: ?u64) void {
    self.resizing -|= 1;
    if (revision) |v| self.ratio_revision = @max(self.ratio_revision, v);
    if (self.resizing > 0 or !self.ratios_waiting) return;
    self.ratios_waiting = false;
    self.ratiosChanged();
}

fn handleEvent(self: *Session, kind: []const u8, payload: std.json.Value) !void {
    if (std.mem.eql(u8, kind, "session_event")) {
        const session = getString(payload, "session_id") orelse return;
        const inner = get(payload, "event") orelse return;
        return self.sessionEvent(
            session,
            getString(inner, "type") orelse return,
            get(inner, "payload") orelse .null,
        );
    }
    if (std.mem.eql(u8, kind, "session_created")) {
        const session = get(payload, "session") orelse return;
        try self.addPeer(
            getString(session, "session_id") orelse return,
            getString(session, "label") orelse "",
        );
    } else if (std.mem.eql(u8, kind, "session_destroyed")) {
        const id = getString(payload, "session_id") orelse return;
        self.removePeer(id);
        if (std.mem.eql(u8, id, self.id)) self.ended();
    } else if (std.mem.eql(u8, kind, "event_dropped")) {
        // Whatever it was, this is how to have it.
        self.newest_revision = @max(self.newest_revision, self.view.revision + 1);
    } else if (std.mem.eql(u8, kind, "client_perform_requested") or
        std.mem.eql(u8, kind, "client_prompt_requested") or
        std.mem.eql(u8, kind, "client_call_requested"))
    {
        // We have no actions, and aren't to be driven.
        const call_id = getString(payload, "call_id") orelse return;
        self.call("client.reply", .{
            .call_id = call_id,
            .@"error" = .{ .code = "not_supported", .message = "winstty doesn't do that" },
        }, .ignore);
    }
}

fn sessionEvent(self: *Session, session: []const u8, kind: []const u8, payload: std.json.Value) !void {
    if (std.mem.eql(u8, kind, "block_event")) {
        const block = getString(payload, "block_id") orelse return;
        const name = getString(payload, "name") orelse return;
        return self.blockEvent(session, block, name, get(payload, "payload") orelse .null);
    }
    if (std.mem.eql(u8, kind, "block_closed")) {
        const id = getString(payload, "block_id") orelse return;
        if (self.peer(session)) |v| if (v.reports.fetchRemove(id)) |kv| {
            self.alloc.free(kv.key);
            var records = kv.value.records;
            records.deinit(self.alloc);
            self.window.statusChanged();
        };
    } else if (std.mem.eql(u8, kind, "session_label_changed")) {
        const label = getString(payload, "label") orelse return;
        if (self.peer(session)) |v| try replace(self.alloc, &v.label, label);
    }
    if (!std.mem.eql(u8, session, self.id)) return;
    if (std.mem.eql(u8, kind, "session_view_changed")) {
        self.newest_revision = @max(self.newest_revision, getInt(payload, "revision") orelse return);
    }
}

fn blockEvent(self: *Session, session: []const u8, id: []const u8, name: []const u8, payload: std.json.Value) !void {
    if (std.mem.eql(u8, name, "program_status_changed")) {
        const record = get(payload, "record") orelse return;
        try self.setRecord(session, id, getString(payload, "id") orelse "", record);
    } else if (std.mem.eql(u8, name, "program_status_removed")) {
        const ids = switch (get(payload, "ids") orelse return) {
            .array => |v| v.items,
            else => return,
        };
        const report = self.findReport(session, id) orelse return;
        for (ids) |v| switch (v) {
            .string => |s| report.records.remove(self.alloc, s),
            else => {},
        };
        self.window.statusChanged();
    }
    // Titles, directories and bells are in what's written to the terminal.
}

//---------------------------------------------------------------
// Status

fn setRecord(self: *Session, session: []const u8, block: []const u8, id: []const u8, record: std.json.Value) !void {
    const owner = self.peer(session) orelse return;
    const entry = try owner.reports.getOrPut(self.alloc, block);
    if (!entry.found_existing) {
        errdefer _ = owner.reports.remove(block);
        entry.key_ptr.* = try self.alloc.dupe(u8, block);
        entry.value_ptr.* = .{};
    }
    const progress: ?u8 = if (getInt(record, "progress")) |v| @intCast(@min(v, 100)) else null;
    try entry.value_ptr.records.set(
        self.alloc,
        id,
        .parse(getString(record, "state") orelse ""),
        progress,
        getString(record, "msg") orelse getString(record, "title") orelse "",
    );
    self.window.statusChanged();
}

fn findReport(self: *Session, session: []const u8, block: []const u8) ?*Report {
    const owner = self.peer(session) orelse return null;
    return owner.reports.getPtr(block);
}

/// What the program in a pane is doing.
pub fn summary(self: *Session, surface: *const Surface) rex.status.Summary {
    const block = surface.block orelse return .{};
    const report = self.findReport(self.id, block.id) orelse return .{};
    return report.records.summary();
}

/// The user is at a pane, so has seen what was done.
pub fn see(self: *Session, surface: *const Surface) void {
    const block = surface.block orelse return;
    const report = self.findReport(self.id, block.id) orelse return;
    if (report.records.see()) self.window.statusChanged();
}

/// What the sessions that aren't shown here are doing.
pub fn elsewhere(self: *const Session) rex.status.State {
    var result: rex.status.State = .idle;
    for (self.peers.items) |v| {
        if (!std.mem.eql(u8, v.id, self.id)) result = result.max(v.summary().state);
    }
    return result;
}

fn askReports(self: *Session, session: []const u8) void {
    const copy = self.alloc.dupe(u8, session) catch return;
    self.call("session.list_blocks", .{ .session_id = session }, .{ .blocks = copy });
}

pub fn peer(self: *const Session, id: []const u8) ?*Peer {
    for (self.peers.items) |v| if (std.mem.eql(u8, v.id, id)) return v;
    return null;
}

fn addPeer(self: *Session, id: []const u8, label: []const u8) !void {
    if (self.peer(id)) |v| return replace(self.alloc, &v.label, label);
    try self.peers.ensureUnusedCapacity(self.alloc, 1);
    const v = try self.alloc.create(Peer);
    errdefer self.alloc.destroy(v);
    const id_copy = try self.alloc.dupe(u8, id);
    errdefer self.alloc.free(id_copy);
    v.* = .{ .id = id_copy, .label = try self.alloc.dupe(u8, label) };
    self.peers.appendAssumeCapacity(v);
}

fn removePeer(self: *Session, id: []const u8) void {
    for (self.peers.items, 0..) |v, i| if (std.mem.eql(u8, v.id, id)) {
        _ = self.peers.orderedRemove(i);
        v.deinit(self.alloc);
        self.alloc.destroy(v);
        self.window.statusChanged();
        return;
    };
}

fn replace(alloc: Allocator, slot: *[]const u8, value: []const u8) !void {
    const copy = try alloc.dupe(u8, value);
    if (slot.len > 0) alloc.free(slot.*);
    slot.* = copy;
}

//---------------------------------------------------------------
// Following the view

/// Ask for the view if it has changed.
fn fetchView(self: *Session) void {
    if (self.id.len == 0 or self.fetching or self.newest_revision <= self.view.revision) return;
    self.fetching = true;
    self.tryCall("session.view", .{ .session_id = self.id }, .view) catch {
        self.fetching = false;
    };
}

fn setView(self: *Session, value: std.json.Value) !void {
    var arena: ArenaAllocator = .init(self.alloc);
    errdefer arena.deinit();
    const view = try rex.view.parse(rex.view.View, arena.allocator(), value);
    if (view.revision < self.view.revision) {
        arena.deinit();
        return;
    }
    self.view_arena.deinit();
    self.view_arena = arena;
    self.view = view;
    self.newest_revision = @max(self.newest_revision, view.revision);
    try replace(self.alloc, &self.label, view.label);
    try self.follow();
}

/// Have the window be like the view, as far as it can be at the moment.
pub fn follow(self: *Session) !void {
    const windows = self.view.items();

    // The last one was closed, which is how a window closes.
    if (windows.len == 0) {
        if (self.window.tabs.items.len > 0) self.ended();
        return;
    }

    var it = self.blocks.valueIterator();
    while (it.next()) |block| block.*.wanted = false;
    for (windows) |*window| {
        if (window.layout()) |layout| try self.want(layout);
    }

    self.following = true;
    defer self.following = false;
    try self.window.followView(self, &self.view);
    self.dropBlocks();
}

/// Have every block of a layout be shown at some point.
fn want(self: *Session, node: *const rex.view.Node) !void {
    if (node.split) |v| {
        try self.want(v.before);
        try self.want(v.after);
        return;
    }
    const id = node.block_id orelse return;
    const entry = try self.blocks.getOrPut(self.alloc, id);
    if (!entry.found_existing) {
        errdefer _ = self.blocks.remove(id);
        const block = try self.alloc.create(Block);
        errdefer self.alloc.destroy(block);
        block.* = .{ .id = try self.alloc.dupe(u8, id) };
        entry.key_ptr.* = block.id;
        entry.value_ptr.* = block;
    }
    const block = entry.value_ptr.*;
    block.wanted = true;
    if (block.surface == null and !block.opening and !block.failed) self.openBlock(block);
}

/// Called when some stream has ended. That's usually because the block has too,
/// but if not it can be shown again.
pub fn streamsEnded(self: *Session) void {
    if (self.lost) return;
    var it = self.blocks.valueIterator();
    while (it.next()) |entry| {
        const block = entry.*;
        const surface = block.surface orelse continue;
        if (block.wanted and !block.opening and !block.failed and surface.isFinished()) self.openBlock(block);
    }
}

/// A surface that's in no tab goes with its block.
fn freeBlock(self: *Session, block: *Block) void {
    if (block.surface) |v| {
        v.block = null;
        if (v.refs == 0) v.destroy();
    }
    self.alloc.free(block.id);
    self.alloc.destroy(block);
}

fn dropBlocks(self: *Session) void {
    var again = true;
    while (again) {
        again = false;
        var it = self.blocks.iterator();
        while (it.next()) |entry| {
            const block = entry.value_ptr.*;
            if (block.wanted) continue;
            self.blocks.removeByPtr(entry.key_ptr);
            self.freeBlock(block);
            again = true;
            break;
        }
    }
}

/// Whether every block of a layout can be shown. Those that never will be don't
/// keep the others from that.
pub fn isReady(self: *const Session, node: *const rex.view.Node) bool {
    if (node.split) |v| return self.isReady(v.before) and self.isReady(v.after);
    const block = self.blocks.get(node.block_id orelse return true) orelse return false;
    return block.surface != null or block.failed;
}

/// The surface of a block, if it can be shown.
pub fn surfaceOf(self: *const Session, id: []const u8) ?*Surface {
    const block = self.blocks.get(id) orelse return null;
    return block.surface;
}

//---------------------------------------------------------------
// Streams

fn openBlock(self: *Session, block: *Block) void {
    const copy = self.alloc.dupe(u8, block.id) catch return;
    block.opening = true;
    self.call("data.connect", .{
        .session_id = self.id,
        .block_id = block.id,
        .data_ref_id = rex.Stream.data_ref,
        .subprotocol = rex.Stream.subprotocol,
    }, .{ .ticket = copy });
}

fn openFailed(self: *Session, block: *Block) void {
    const max_tries = 5;
    block.opening = false;
    block.tries += 1;
    if (block.tries < max_tries) return self.openBlock(block);
    block.failed = true;
    log.warn("a block can't be shown", .{});
    self.follow() catch |err| log.warn("error following the server err={}", .{err});
}

/// The result of opening a stream, which is posted to the app.
pub const Opened = struct {
    alloc: Allocator,
    window: c.HWND,
    /// Of the session, in case there's been another since.
    client: *rex.Client,
    block_id: []const u8,
    ticket: []const u8,
    path_buf: [260:0]u16,
    path_len: usize,
    stream: ?*rex.Stream = null,

    pub fn destroy(self: *Opened) void {
        if (self.stream) |v| {
            v.cancel();
            v.destroy();
        }
        self.client.unref();
        self.alloc.free(self.block_id);
        self.alloc.free(self.ticket);
        self.alloc.destroy(self);
    }

    fn run(self: *Opened, app: *App) void {
        self.stream = rex.Stream.open(self.alloc, self.path_buf[0..self.path_len :0], self.ticket) catch |err| stream: {
            log.info("error opening a stream err={}", .{err});
            break :stream null;
        };
        app.post(.{ .opened = self });
    }
};

fn openStream(self: *Session, block: *Block, ticket: []const u8) !void {
    const job = try self.alloc.create(Opened);
    errdefer self.alloc.destroy(job);
    const id = try self.alloc.dupe(u8, block.id);
    errdefer self.alloc.free(id);
    const ticket_copy = try self.alloc.dupe(u8, ticket);
    errdefer self.alloc.free(ticket_copy);
    job.* = .{
        .alloc = self.alloc,
        .window = self.window.hwnd,
        .client = self.client.ref(),
        .block_id = id,
        .ticket = ticket_copy,
        .path_buf = self.path_buf,
        .path_len = self.path_len,
    };
    errdefer self.client.unref();
    const thread = try std.Thread.spawn(.{}, Opened.run, .{ job, self.app });
    thread.detach();
}

/// Called when a stream has been opened, or couldn't be.
pub fn opened(self: *Session, job: *Opened) void {
    const block = self.blocks.get(job.block_id) orelse return;
    block.opening = false;
    if (!block.wanted) return;
    const stream = job.stream orelse return self.openFailed(block);
    self.makeSurface(block, job, stream) catch |err| {
        log.warn("error showing a block err={}", .{err});
        self.openFailed(block);
        return;
    };
    self.follow() catch |err| log.warn("error following the server err={}", .{err});
}

fn makeSurface(self: *Session, block: *Block, job: *Opened, stream: *rex.Stream) !void {
    const input: *rex.Client.Input = try .create(self.client, self.id, block.id);

    // It has the stream from here, whatever becomes of it.
    job.stream = null;
    const surface: *Surface = try .createFor(self.window, .{ .rex = .init(stream, input, .{
        .context = self.app,
        .func = App.streamEnded,
    }) });
    if (block.surface) |v| v.block = null;
    surface.block = block;
    block.surface = surface;
    block.tries = 0;
    self.sendTheme(surface);

    const copy = try self.alloc.dupe(u8, block.id);
    self.callTerminal(self.id, block.id, "title", rex.Client.NoArgs{}, .{ .title = copy });
}

//---------------------------------------------------------------
// Ending

/// The session is gone, or there's nothing left of it.
fn ended(self: *Session) void {
    // We may be in the middle of something, and this is the end of us.
    _ = c.PostMessageW(self.window.hwnd, Window.WM_SESSION_ENDED, 0, 0);
}

fn loseConnection(self: *Session) void {
    self.lost = true;
    log.info("lost the server", .{});
    self.window.titleOfSession();
    self.reconnect();
}

/// Have another connection take the place of the one that was lost.
pub fn reconnect(self: *Session) void {
    const target: Target = if (self.id.len > 0)
        .{ .id = self.alloc.dupe(u8, self.id) catch return }
    else
        .last;
    self.app.connectRex(target, self.window.hwnd) catch |err| {
        target.deinit(self.alloc);
        log.warn("error reconnecting err={}", .{err});
    };
}

/// Show another session in place of this one, which keeps running.
pub fn switchTo(self: *Session, id: []const u8) void {
    if (std.mem.eql(u8, id, self.id)) return;
    const copy = self.alloc.dupe(u8, id) catch return;
    defer self.alloc.free(copy);
    self.call("session.detach", .{ .session_id = self.id }, .ignore);
    self.forgetRequests();
    self.forgetBlocks();
    self.forgetView();
    self.attach(copy);
}

/// Show a new session in place of this one, which keeps running.
pub fn switchToNew(self: *Session) void {
    if (self.id.len > 0) self.call("session.detach", .{ .session_id = self.id }, .ignore);
    self.forgetRequests();
    self.forgetBlocks();
    self.forgetView();
    self.newSession(.create);
}

fn forgetView(self: *Session) void {
    self.newest_revision = 0;
    self.focus_revision = 0;
    self.ratio_revision = 0;
    self.view = .{};
}

/// Called with another connection, after the one there was got lost. What's
/// shown stays until there's something to replace it.
pub fn @"resume"(self: *Session, client: *rex.Client, path: [:0]const u16, target: Target) void {
    self.client.leave();
    self.client = client;
    @memcpy(self.path_buf[0..path.len], path);
    self.path_buf[path.len] = 0;
    self.path_len = path.len;
    self.target.deinit(self.alloc);
    self.target = target;
    self.lost = false;
    self.reconnects = 0;
    self.forgetRequests();
    self.forgetBlocks();
    for (self.peers.items) |v| {
        v.deinit(self.alloc);
        self.alloc.destroy(v);
    }
    self.peers.clearRetainingCapacity();
    self.forgetView();
    self.start();
    self.window.titleOfSession();
}

//---------------------------------------------------------------
// Commands

/// Split a command line in to a program and its arguments, the way that the
/// ones we make are written: separated by spaces, unless they're in quotes.
pub fn splitCommand(arena: Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = std.mem.trim(u8, line, " ");
    while (rest.len > 0) {
        const quoted = rest[0] == '"';
        const from = rest[@intFromBool(quoted)..];
        const end = std.mem.findScalar(u8, from, if (quoted) '"' else ' ') orelse from.len;
        try out.append(arena, from[0..end]);
        rest = std.mem.trimStart(u8, from[@min(from.len, end + 1)..], " ");
    }
    return out.items;
}

test "session: split a command" {
    var arena: ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = try splitCommand(arena.allocator(), "pwsh.exe -NoLogo");
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("-NoLogo", a[1]);
    const b = try splitCommand(arena.allocator(), "\"C:\\Program Files\\Git\\bin\\bash.exe\" --login  -i");
    try std.testing.expectEqual(@as(usize, 3), b.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", b[0]);
    try std.testing.expectEqualStrings("-i", b[2]);
    try std.testing.expectEqual(@as(usize, 0), (try splitCommand(arena.allocator(), "  ")).len);
}

test "session: labels are cut to what the server takes" {
    try std.testing.expectEqualStrings("short", cutLabel("short"));
    const long: [200]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, 128), cutLabel(&long).len);
    const wide: [200][2]u8 = @splat("\u{e9}".*);
    try std.testing.expectEqual(@as(usize, 256), cutLabel(std.mem.sliceAsBytes(&wide)).len);
}
