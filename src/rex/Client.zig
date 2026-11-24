//! A connection that calls the methods of a server, and is told of its events.
//!
//! Nothing here waits for the server. What it sends is kept until whoever owns
//! this takes it, and what's sent to it goes out from a thread of its own.
const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const build_config = @import("../build_config.zig");
const Conn = @import("websocket.zig").Conn;

const log = std.log.scoped(.rex);

/// The revision of the API that this is written for.
pub const api_revision = 19;

/// The oldest one that has what we need. Servers translate, so this is that of
/// the methods rather than their shapes.
pub const api_min_revision = 0;

const terminal = "com.superlogical.terminal.";

/// For methods that take no arguments. An anonymous one would be a list.
pub const NoArgs = struct {};

extern "kernel32" fn CreateEventW(?*anyopaque, c_int, c_int, ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(*anyopaque, u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) c_int;

pub const Notify = struct {
    context: *anyopaque,

    /// Called from another thread when there's something to take.
    func: *const fn (*anyopaque) void,
};

alloc: Allocator,
conn: *Conn,
notify: Notify,

/// The window and the panes that write each have one.
refs: std.atomic.Value(usize) = .init(1),

/// How the server knows us.
id: []const u8,

reader: ?std.Thread = null,
writer: ?std.Thread = null,
stopping: std.atomic.Value(bool) = .init(false),

/// The connection has ended, and won't come back.
closed: std.atomic.Value(bool) = .init(false),

mutex: std.Io.Mutex = .init,
inbox: std.ArrayList([]u8) = .empty,
outbox: std.ArrayList([]u8) = .empty,
outbox_event: *anyopaque,
last_request: u64 = 0,

/// Panes waiting for what they wrote to have arrived.
writing: std.AutoHashMapUnmanaged(u64, *Input) = .empty,

/// Blocks until the server has let us in.
pub fn connect(alloc: Allocator, path: [:0]const u16, notify: Notify) !*Client {
    const conn: *Conn = try .open(alloc, path, "/api/control", "rex.control.v1");
    errdefer conn.destroy();

    var hello: std.Io.Writer.Allocating = .init(alloc);
    defer hello.deinit();
    try std.json.Stringify.value(.{
        .type = "hello",
        .api_revision = api_revision,
        .api_min_revision = api_min_revision,
        .client = .{
            .kind = "app",
            .platform = "windows",
            .name = "winstty",
            .version = build_config.version_string,
        },
    }, .{}, &hello.writer);
    try conn.write(.text, hello.written());

    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(alloc);
    if (try conn.readMessage(&message) != .text) return error.ProtocolError;
    const Welcome = struct {
        type: []const u8,
        protocol: []const u8,
        client: ?struct { id: []const u8 = "" } = null,
    };
    const welcome = try std.json.parseFromSlice(Welcome, alloc, message.items, .{
        .ignore_unknown_fields = true,
    });
    defer welcome.deinit();
    if (!std.mem.eql(u8, welcome.value.type, "welcome") or
        !std.mem.eql(u8, welcome.value.protocol, "rex.control.v1")) return error.ProtocolError;

    const id = try alloc.dupe(u8, if (welcome.value.client) |v| v.id else "");
    errdefer alloc.free(id);
    const event = CreateEventW(null, 0, 0, null) orelse return error.SystemResources;
    errdefer _ = CloseHandle(event);

    const self = try alloc.create(Client);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .conn = conn,
        .notify = notify,
        .id = id,
        .outbox_event = event,
    };
    self.reader = try .spawn(.{}, readMain, .{self});
    errdefer {
        conn.cancel();
        self.reader.?.join();
    }
    self.writer = try .spawn(.{}, writeMain, .{self});
    return self;
}

pub fn ref(self: *Client) *Client {
    _ = self.refs.fetchAdd(1, .acq_rel);
    return self;
}

pub fn unref(self: *Client) void {
    if (self.refs.fetchSub(1, .acq_rel) > 1) return;
    self.stop();
    while (self.inbox.pop()) |v| self.alloc.free(v);
    while (self.outbox.pop()) |v| self.alloc.free(v);
    self.inbox.deinit(self.alloc);
    self.outbox.deinit(self.alloc);
    self.writing.deinit(self.alloc);
    self.conn.destroy();
    _ = CloseHandle(self.outbox_event);
    self.alloc.free(self.id);
    self.alloc.destroy(self);
}

/// Leave the server, and give up the reference of the owner. Panes may still
/// have theirs, but what they write goes nowhere.
pub fn leave(self: *Client) void {
    self.stop();

    // Nobody is going to say that these have arrived.
    var it = self.writing.valueIterator();
    var inputs: std.ArrayList(*Input) = .empty;
    const alloc = self.alloc;
    defer inputs.deinit(alloc);
    while (it.next()) |v| inputs.append(alloc, v.*) catch {};
    self.writing.clearRetainingCapacity();
    for (inputs.items) |v| v.unref();
    self.unref();
}

/// There are no notifications after this.
fn stop(self: *Client) void {
    if (self.stopping.swap(true, .acq_rel)) return;
    _ = SetEvent(self.outbox_event);
    if (self.writer) |v| v.join();
    if (!self.closed.load(.acquire)) self.conn.sendClose();
    self.conn.cancel();
    if (self.reader) |v| v.join();
}

fn readMain(self: *Client) void {
    self.read() catch |err| {
        if (!self.stopping.load(.acquire)) log.info("the connection to the server ended err={}", .{err});
    };
    self.closed.store(true, .release);
    if (!self.stopping.load(.acquire)) self.notify.func(self.notify.context);
}

fn read(self: *Client) !void {
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(self.alloc);
    while (true) {
        if (try self.conn.readMessage(&message) != .text) continue;
        if (self.written(message.items)) continue;

        const copy = try self.alloc.dupe(u8, message.items);
        {
            errdefer self.alloc.free(copy);
            self.mutex.lockUncancelable(global.io());
            defer self.mutex.unlock(global.io());
            try self.inbox.append(self.alloc, copy);
            if (self.inbox.items.len > 1) continue;
        }
        self.notify.func(self.notify.context);
    }
}

/// Everything that has arrived. The caller owns the messages and the list.
pub fn take(self: *Client) std.ArrayList([]u8) {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const result = self.inbox;
    self.inbox = .empty;
    return result;
}

fn writeMain(self: *Client) void {
    const infinite = 0xFFFFFFFF;
    while (true) {
        self.mutex.lockUncancelable(global.io());
        var list = self.outbox;
        self.outbox = .empty;
        self.mutex.unlock(global.io());
        defer list.deinit(self.alloc);

        for (list.items) |message| {
            defer self.alloc.free(message);
            if (self.closed.load(.acquire)) continue;
            self.conn.write(.text, message) catch {
                // Have the reader notice.
                self.conn.cancel();
            };
        }
        if (list.items.len > 0) continue;
        if (self.stopping.load(.acquire)) return;
        _ = WaitForSingleObject(self.outbox_event, infinite);
    }
}

/// Call a method. Returns what the response is recognized by. The arguments are
/// anything that can be JSON.
pub fn call(self: *Client, method: []const u8, args: anytype) !u64 {
    return try self.callFor(method, args, null);
}

/// Call a method of a terminal.
pub fn callTerminal(
    self: *Client,
    session_id: []const u8,
    block_id: []const u8,
    comptime method: []const u8,
    args: anytype,
) !u64 {
    return try self.call(terminal ++ method, .{
        .session_id = session_id,
        .block_id = block_id,
        .args = args,
    });
}

fn callFor(self: *Client, method: []const u8, args: anytype, input: ?*Input) !u64 {
    if (self.closed.load(.acquire)) return error.Closed;

    var message: std.Io.Writer.Allocating = .init(self.alloc);
    defer message.deinit();

    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const id = self.last_request + 1;
    var id_buf: [20]u8 = undefined;
    try std.json.Stringify.value(.{
        .type = "request",
        .id = std.fmt.bufPrint(&id_buf, "{}", .{id}) catch unreachable,
        .method = method,
        .payload = args,
    }, .{ .emit_null_optional_fields = false }, &message.writer);

    try self.outbox.ensureUnusedCapacity(self.alloc, 1);
    if (input) |v| try self.writing.put(self.alloc, id, v);
    errdefer if (input != null) {
        _ = self.writing.remove(id);
    };
    self.outbox.appendAssumeCapacity(try message.toOwnedSlice());
    self.last_request = id;
    _ = SetEvent(self.outbox_event);
    return id;
}

/// Whether a message says that what a pane wrote has arrived. If so the pane is
/// told at once, since the next key may be waiting for it.
fn written(self: *Client, message: []const u8) bool {
    return self.writtenId(responseId(message) orelse return false);
}

/// Called with the identifier of a response that isn't recognized.
pub fn writtenId(self: *Client, id: u64) bool {
    self.mutex.lockUncancelable(global.io());
    const kv = self.writing.fetchRemove(id);
    self.mutex.unlock(global.io());
    const input = (kv orelse return false).value;
    input.arrived();
    return true;
}

/// The identifier of a response, without parsing all of it. Null if it isn't
/// written the way that servers do.
fn responseId(message: []const u8) ?u64 {
    const start = "{\"type\":\"response\",\"id\":\"";
    if (!std.mem.startsWith(u8, message, start)) return null;
    const rest = message[start.len..];
    const end = std.mem.findScalar(u8, rest, '"') orelse return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

/// What's typed in to a pane. Text written by two calls could arrive in any
/// order, so there's only ever one under way.
pub const Input = struct {
    client: *Client,
    session_id: []const u8,
    block_id: []const u8,

    mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(u8) = .empty,
    under_way: bool = false,
    refs: std.atomic.Value(usize) = .init(1),

    /// Much less than what fits in a message, even if it has to be escaped.
    const max_write = 64 * 1024;

    pub fn create(client: *Client, session_id: []const u8, block_id: []const u8) !*Input {
        const alloc = client.alloc;
        const self = try alloc.create(Input);
        errdefer alloc.destroy(self);
        const session = try alloc.dupe(u8, session_id);
        errdefer alloc.free(session);
        self.* = .{
            .client = client.ref(),
            .session_id = session,
            .block_id = try alloc.dupe(u8, block_id),
        };
        return self;
    }

    pub fn unref(self: *Input) void {
        if (self.refs.fetchSub(1, .acq_rel) > 1) return;
        const client = self.client;
        const alloc = client.alloc;
        self.pending.deinit(alloc);
        alloc.free(self.session_id);
        alloc.free(self.block_id);
        alloc.destroy(self);
        client.unref();
    }

    pub fn write(self: *Input, data: []const u8) !void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        try self.pending.appendSlice(self.client.alloc, data);
        if (!self.under_way) try self.send();
    }

    fn arrived(self: *Input) void {
        {
            self.mutex.lockUncancelable(global.io());
            defer self.mutex.unlock(global.io());
            self.under_way = false;
            if (self.pending.items.len > 0) self.send() catch |err|
                log.warn("error writing to a pane err={}", .{err});
        }
        self.unref();
    }

    /// Must be locked.
    fn send(self: *Input) !void {
        const alloc = self.client.alloc;
        const len = textLen(self.pending.items, max_write);
        const text = try toUtf8(alloc, self.pending.items[0..len]);
        defer alloc.free(text);
        self.under_way = true;
        _ = self.refs.fetchAdd(1, .acq_rel);
        errdefer {
            self.under_way = false;
            _ = self.refs.fetchSub(1, .acq_rel);
        }
        _ = try self.client.callFor(terminal ++ "write", .{
            .session_id = self.session_id,
            .block_id = self.block_id,
            .args = .{ .data = text },
        }, self);
        self.pending.replaceRangeAssumeCapacity(0, len, &.{});
    }
};

/// As much as fits without splitting a character.
fn textLen(data: []const u8, max: usize) usize {
    if (data.len <= max) return data.len;
    var len = max;
    while (len > max - 4 and data[len] & 0xC0 == 0x80) len -= 1;
    return len;
}

/// Writes are text. What isn't can't be written, and is left out.
fn toUtf8(alloc: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(alloc, data.len);
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < data.len) {
        const len = std.unicode.utf8ByteSequenceLength(data[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > data.len or !std.unicode.utf8ValidateSlice(data[i..][0..len])) {
            i += 1;
            continue;
        }
        out.appendSliceAssumeCapacity(data[i..][0..len]);
        i += len;
    }
    return try out.toOwnedSlice(alloc);
}

test "rex: no arguments is an object" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{ .args = NoArgs{} }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"args\":{}}", out.written());
}

test "rex: the identifier of a response" {
    try std.testing.expectEqual(@as(?u64, 12), responseId(
        \\{"type":"response","id":"12","seq":0,"payload":{}}
    ));
    try std.testing.expectEqual(@as(?u64, null), responseId(
        \\{"type":"event","seq":1,"payload":{}}
    ));
    try std.testing.expectEqual(@as(?u64, null), responseId(
        \\{"type":"response","id":"x1"}
    ));
}

test "rex: writes are text" {
    const alloc = std.testing.allocator;
    const a = try toUtf8(alloc, "h\u{e9}llo\x1b[A\r");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("h\u{e9}llo\x1b[A\r", a);
    const b = try toUtf8(alloc, "a\xFFb\xC3");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("ab", b);

    try std.testing.expectEqual(@as(usize, 3), textLen("abc", 8));
    try std.testing.expectEqual(@as(usize, 8), textLen("abcdefghij", 8));
    try std.testing.expectEqual(@as(usize, 7), textLen("abcdefg\u{e9}xx", 8));
}
