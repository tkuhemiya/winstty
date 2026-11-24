//! What a terminal of the server shows: a snapshot of it, followed by what's
//! written to it.
const Stream = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const snapshot = @import("../terminal/main.zig").snapshot;
const Conn = @import("websocket.zig").Conn;

const log = std.log.scoped(.rex);

pub const subprotocol = "rex.data.terminal.v1";
pub const data_ref = "terminal";

/// More than any unfinished sequence of a program that isn't out to get us.
const max_continuation = 4 << 20;

alloc: Allocator,
conn: *Conn,

/// Reads the data of the connection.
reader: std.Io.Reader,
buffer: [64 * 1024]u8 = undefined,

/// The terminal as of the snapshot, until it's taken.
decoded: snapshot.Decoded,
splitter: Splitter,

const vtable: std.Io.Reader.VTable = .{ .stream = streamFn };

fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *Stream = @alignCast(@fieldParentPtr("reader", r));
    const dest = limit.slice(try w.writableSliceGreedy(1));
    const n = self.conn.readChunk(dest) catch |err| switch (err) {
        error.Closed => return error.EndOfStream,
        else => return error.ReadFailed,
    };
    w.advance(n);
    return n;
}

/// Blocks until there's a terminal to show, with all of its scrollback. It would
/// have to be locked to add that later, while waiting for the server. The ticket is from `data.connect`.
pub fn open(alloc: Allocator, path: [:0]const u16, ticket: []const u8) !*Stream {
    var hello: [17]u8 = undefined;
    hello[0] = 0x01;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    if (try decoder.calcSizeForSlice(ticket) != 16) return error.InvalidTicket;
    try decoder.decode(hello[1..], ticket);

    const conn: *Conn = try .open(alloc, path, "/api/data", subprotocol);
    errdefer conn.destroy();
    try conn.write(.binary, &hello);

    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(alloc);
    if (try conn.readMessage(&answer) != .binary or answer.items.len == 0) return error.ProtocolError;
    switch (answer.items[0]) {
        0x81 => if (answer.items.len != 32) return error.ProtocolError,
        0x82 => {
            log.warn("the server rejected a data connection reason={any}", .{answer.items[1..]});
            return error.Rejected;
        },
        else => return error.ProtocolError,
    }

    const self = try alloc.create(Stream);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .conn = conn,
        .reader = .{ .vtable = &vtable, .buffer = undefined, .seek = 0, .end = 0 },
        .decoded = undefined,
        .splitter = .init(std.mem.readInt(u64, answer.items[24..32], .little)),
    };
    self.reader.buffer = &self.buffer;
    self.decoded = try snapshot.decode(alloc, global.io(), &self.reader, .{
        .max_continuation_bytes = max_continuation,
    });
    return self;
}

/// No other thread may be using it.
pub fn destroy(self: *Stream) void {
    self.conn.destroy();
    self.decoded.deinit(self.alloc);
    self.splitter.deinit(self.alloc);
    self.alloc.destroy(self);
}

/// End the stream, and fail what another thread is waiting for.
pub fn cancel(self: *Stream) void {
    self.conn.sendClose();
    self.conn.cancel();
}

/// Some more of what's written to the terminal, after the snapshot. Valid until
/// the next call. Empty at the end.
pub fn next(self: *Stream) ![]const u8 {
    self.reader.tossBuffered();
    self.reader.fillMore() catch |err| switch (err) {
        error.EndOfStream => return &.{},
        error.ReadFailed => return error.ReadFailed,
    };
    return self.reader.buffered();
}

/// What's after the snapshot and has been read along with it.
pub fn leftover(self: *Stream) []const u8 {
    return self.reader.buffered();
}

/// What the server says about the terminal, in between what's written to it.
pub const Message = struct {
    type: []const u8 = "",
    cols: ?u16 = null,
    rows: ?u16 = null,
};

/// Takes the messages of the server out of what's written to the terminal.
pub const Splitter = struct {
    marker_buf: [32]u8,
    marker_len: usize,

    /// The start of what may be a message.
    held: std.ArrayList(u8) = .empty,

    const max_message = 64 * 1024;
    const terminator = "\x1b\\";

    pub fn init(nonce: u64) Splitter {
        var self: Splitter = .{ .marker_buf = undefined, .marker_len = 0 };
        self.marker_len = (std.fmt.bufPrint(&self.marker_buf, "\x1b_rex1;{};", .{nonce}) catch unreachable).len;
        return self;
    }

    pub fn deinit(self: *Splitter, alloc: Allocator) void {
        self.held.deinit(alloc);
    }

    fn marker(self: *const Splitter) []const u8 {
        return self.marker_buf[0..self.marker_len];
    }

    /// Calls `output` with what's for the terminal, and `message` with the JSON
    /// of messages.
    pub fn feed(self: *Splitter, alloc: Allocator, bytes: []const u8, sink: anytype) Allocator.Error!void {
        if (self.held.items.len == 0) {
            const used = self.scan(bytes, sink);
            try self.held.appendSlice(alloc, bytes[used..]);
            return;
        }
        try self.held.appendSlice(alloc, bytes);
        const used = self.scan(self.held.items, sink);
        self.held.replaceRangeAssumeCapacity(0, used, &.{});
    }

    /// Returns how much was used. The rest may be the start of a message.
    fn scan(self: *const Splitter, bytes: []const u8, sink: anytype) usize {
        var rest = bytes;
        while (std.mem.find(u8, rest, self.marker())) |i| {
            if (i > 0) sink.output(rest[0..i]);
            const body = rest[i + self.marker_len ..];
            const len = std.mem.find(u8, body, terminator) orelse {
                if (body.len < max_message) return bytes.len - (rest.len - i);
                // It isn't one, then.
                sink.output(rest[i..]);
                return bytes.len;
            };
            sink.message(body[0..len]);
            rest = body[len + terminator.len ..];
        }

        // The end may be the start of one.
        var keep = @min(rest.len, self.marker_len - 1);
        while (keep > 0) : (keep -= 1) {
            if (std.mem.endsWith(u8, rest, self.marker()[0..keep])) break;
        }
        const ready = rest[0 .. rest.len - keep];
        if (ready.len > 0) sink.output(ready);
        return bytes.len - keep;
    }
};

const TestSink = struct {
    out: std.ArrayList(u8) = .empty,
    messages: std.ArrayList(u8) = .empty,

    fn output(self: *TestSink, bytes: []const u8) void {
        self.out.appendSlice(std.testing.allocator, bytes) catch unreachable;
    }

    fn message(self: *TestSink, json: []const u8) void {
        self.messages.appendSlice(std.testing.allocator, json) catch unreachable;
        self.messages.append(std.testing.allocator, '|') catch unreachable;
    }

    fn deinit(self: *TestSink) void {
        self.out.deinit(std.testing.allocator);
        self.messages.deinit(std.testing.allocator);
    }
};

test "rex: messages are taken out, however they arrive" {
    const text = "one\x1b[31m\x1b_rex1;42;{\"type\":\"resize\"}\x1b\\two" ++
        "\x1b_rex1;42;{\"type\":\"theme\"}\x1b\\\x1b_rex1;42;{}\x1b\\three";
    for (1..text.len + 1) |size| {
        var splitter: Splitter = .init(42);
        defer splitter.deinit(std.testing.allocator);
        var sink: TestSink = .{};
        defer sink.deinit();
        var i: usize = 0;
        while (i < text.len) : (i += size) {
            try splitter.feed(std.testing.allocator, text[i..@min(text.len, i + size)], &sink);
        }
        try std.testing.expectEqualStrings("one\x1b[31mtwothree", sink.out.items);
        try std.testing.expectEqualStrings("{\"type\":\"resize\"}|{\"type\":\"theme\"}|{}|", sink.messages.items);
    }
}

test "rex: messages that a program made up are left alone" {
    var splitter: Splitter = .init(42);
    defer splitter.deinit(std.testing.allocator);
    var sink: TestSink = .{};
    defer sink.deinit();
    const text = "a\x1b_rex1;41;{\"type\":\"resize\"}\x1b\\b\x1b_rex1;420;{}\x1b\\c";
    try splitter.feed(std.testing.allocator, text, &sink);
    try std.testing.expectEqualStrings(text, sink.out.items);
    try std.testing.expectEqual(@as(usize, 0), sink.messages.items.len);
}

test "rex: a message without an end isn't one" {
    var splitter: Splitter = .init(1);
    defer splitter.deinit(std.testing.allocator);
    var sink: TestSink = .{};
    defer sink.deinit();
    const junk: [70 * 1024]u8 = @splat('x');
    try splitter.feed(std.testing.allocator, "\x1b_rex1;1;", &sink);
    try std.testing.expectEqual(@as(usize, 0), sink.out.items.len);
    try splitter.feed(std.testing.allocator, &junk, &sink);
    try std.testing.expectEqual(junk.len + "\x1b_rex1;1;".len, sink.out.items.len);
}
