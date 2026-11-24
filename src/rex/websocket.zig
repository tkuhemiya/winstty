//! The client side of WebSocket, over a named pipe.
const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const Pipe = @import("Pipe.zig");

pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
    _,

    fn isControl(self: Opcode) bool {
        return @backingInt(self) & 8 != 0;
    }
};

pub const Header = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    len: u64,
};

/// The largest header that's written: with a 64 bit length and a mask.
const max_header = 14;

/// The length in bytes of what a header starts with, before it's whole.
fn headerLen(second: u8) usize {
    return 2 + @as(usize, switch (second & 0x7F) {
        126 => 2,
        127 => 8,
        else => 0,
    }) + @as(usize, if (second & 0x80 != 0) 4 else 0);
}

fn parseHeader(bytes: []const u8) Header {
    return .{
        .fin = bytes[0] & 0x80 != 0,
        .opcode = @fromBackingInt(@as(u4, @truncate(bytes[0]))),
        .masked = bytes[1] & 0x80 != 0,
        .len = switch (bytes[1] & 0x7F) {
            126 => std.mem.readInt(u16, bytes[2..4], .big),
            127 => std.mem.readInt(u64, bytes[2..10], .big),
            else => |v| v,
        },
    };
}

/// Returns the part of the buffer that was written.
fn writeHeader(buf: *[max_header]u8, opcode: Opcode, len: usize, mask: [4]u8) []const u8 {
    buf[0] = 0x80 | @as(u8, @backingInt(opcode));
    var end: usize = 2;
    if (len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(len));
    } else if (len <= std.math.maxInt(u16)) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(len), .big);
        end = 4;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[2..10], len, .big);
        end = 10;
    }
    buf[end..][0..4].* = mask;
    return buf[0 .. end + 4];
}

fn applyMask(data: []u8, mask: [4]u8) void {
    for (data, 0..) |*v, i| v.* ^= mask[i & 3];
}

pub const Conn = struct {
    alloc: Allocator,
    pipe: Pipe,
    write_mutex: std.Io.Mutex = .init,

    /// What was read but not used yet.
    buf: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    /// What's left of the frame of `readChunk`, and whether it's the last one.
    left: u64 = 0,

    /// The limit of `readMessage`.
    const max_message = 4 << 20;

    const write_timeout_ms = 10_000;
    const close_timeout_ms = 300;

    pub const ReadError = error{ ReadFailed, Closed, ProtocolError, OutOfMemory };

    pub fn open(alloc: Allocator, path: [:0]const u16, url: []const u8, subprotocol: []const u8) !*Conn {
        const self = try alloc.create(Conn);
        errdefer alloc.destroy(self);
        self.* = .{ .alloc = alloc, .pipe = try .open(path) };
        errdefer self.pipe.close();

        var nonce: [16]u8 = undefined;
        random(&nonce);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &nonce);

        const request = try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Protocol: {s}\r\n\r\n", .{ url, key, subprotocol });
        defer alloc.free(request);
        try self.pipe.writeAll(request, write_timeout_ms);

        while (true) {
            const head = self.buf[0..self.end];
            if (std.mem.find(u8, head, "\r\n\r\n")) |i| {
                if (!std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.Refused;
                self.start = i + 4;
                return self;
            }
            if (self.end == self.buf.len) return error.ProtocolError;
            const n = try self.pipe.read(self.buf[self.end..]);
            if (n == 0) return error.Refused;
            self.end += n;
        }
    }

    /// No other thread may be using it.
    pub fn destroy(self: *Conn) void {
        self.pipe.close();
        self.alloc.destroy(self);
    }

    /// Fail what other threads are doing.
    pub fn cancel(self: *Conn) void {
        self.pipe.cancel();
    }

    /// Tell the server we're done, rather than have it wait for us to return.
    pub fn sendClose(self: *Conn) void {
        self.writeIn(.close, &.{ 0x03, 0xE8 }, close_timeout_ms) catch {};
    }

    pub fn write(self: *Conn, opcode: Opcode, payload: []const u8) !void {
        try self.writeIn(opcode, payload, write_timeout_ms);
    }

    fn writeIn(self: *Conn, opcode: Opcode, payload: []const u8, timeout_ms: u32) !void {
        var mask: [4]u8 = undefined;
        random(&mask);
        var header: [max_header]u8 = undefined;
        const head = writeHeader(&header, opcode, payload.len, mask);
        const frame = try self.alloc.alloc(u8, head.len + payload.len);
        defer self.alloc.free(frame);
        @memcpy(frame[0..head.len], head);
        @memcpy(frame[head.len..], payload);
        applyMask(frame[head.len..], mask);

        self.write_mutex.lockUncancelable(global.io());
        defer self.write_mutex.unlock(global.io());
        try self.pipe.writeAll(frame, timeout_ms);
    }

    /// Read a whole message, in place of what's in the list.
    pub fn readMessage(self: *Conn, out: *std.ArrayList(u8)) ReadError!Opcode {
        out.clearRetainingCapacity();
        var opcode: ?Opcode = null;
        while (true) {
            const header = try self.readHeader();
            if (header.opcode.isControl()) {
                try self.control(header);
                continue;
            }
            if (opcode == null) {
                opcode = header.opcode;
            } else if (header.opcode != .continuation) return error.ProtocolError;
            if (out.items.len + header.len > max_message) return error.ProtocolError;
            try self.readExact(try out.addManyAsSlice(self.alloc, @intCast(header.len)));
            if (header.fin) return opcode.?;
        }
    }

    /// Read some of the data of binary messages, of which the boundaries have
    /// no meaning.
    pub fn readChunk(self: *Conn, out: []u8) ReadError!usize {
        while (self.left == 0) {
            const header = try self.readHeader();
            if (header.opcode.isControl()) {
                try self.control(header);
                continue;
            }
            self.left = header.len;
        }
        if (self.start == self.end) try self.fill();
        const n: usize = @intCast(@min(self.left, @min(out.len, self.end - self.start)));
        @memcpy(out[0..n], self.buf[self.start..][0..n]);
        self.start += n;
        self.left -= n;
        return n;
    }

    fn control(self: *Conn, header: Header) ReadError!void {
        var payload: [125]u8 = undefined;
        if (header.len > payload.len) return error.ProtocolError;
        const data = payload[0..@intCast(header.len)];
        try self.readExact(data);
        switch (header.opcode) {
            .ping => self.write(.pong, data) catch return error.ReadFailed,
            .close => {
                // Closing has to be answered.
                self.write(.close, data[0..@min(2, data.len)]) catch {};
                return error.Closed;
            },
            else => {},
        }
    }

    fn readHeader(self: *Conn) ReadError!Header {
        try self.need(2);
        const len = headerLen(self.buf[self.start + 1]);
        try self.need(len);
        const header = parseHeader(self.buf[self.start..][0..len]);
        self.start += len;

        // Only clients mask.
        if (header.masked) return error.ProtocolError;
        return header;
    }

    fn readExact(self: *Conn, out: []u8) ReadError!void {
        var rest = out;
        while (rest.len > 0) {
            if (self.start == self.end) try self.fill();
            const n = @min(rest.len, self.end - self.start);
            @memcpy(rest[0..n], self.buf[self.start..][0..n]);
            self.start += n;
            rest = rest[n..];
        }
    }

    /// Have at least this much in the buffer.
    fn need(self: *Conn, len: usize) ReadError!void {
        while (self.end - self.start < len) {
            if (self.start > 0) {
                std.mem.copyForwards(u8, &self.buf, self.buf[self.start..self.end]);
                self.end -= self.start;
                self.start = 0;
            }
            const n = try self.pipe.read(self.buf[self.end..]);
            if (n == 0) return error.Closed;
            self.end += n;
        }
    }

    fn fill(self: *Conn) ReadError!void {
        self.start = 0;
        self.end = 0;
        const n = try self.pipe.read(&self.buf);
        if (n == 0) return error.Closed;
        self.end = n;
    }
};

fn random(buf: []u8) void {
    const source: std.Random.IoSource = .{ .io = global.io() };
    source.interface().bytes(buf);
}

test "rex: websocket headers" {
    const mask = [4]u8{ 1, 2, 3, 4 };
    for ([_]usize{ 0, 1, 125, 126, 127, 65535, 65536, 1 << 20 }) |len| {
        var buf: [max_header]u8 = undefined;
        const bytes = writeHeader(&buf, .binary, len, mask);
        try std.testing.expectEqual(bytes.len, headerLen(bytes[1]));
        try std.testing.expectEqual(Header{
            .fin = true,
            .opcode = .binary,
            .masked = true,
            .len = len,
        }, parseHeader(bytes));
        try std.testing.expectEqualSlices(u8, &mask, bytes[bytes.len - 4 ..]);
    }
}

test "rex: websocket mask" {
    var data = "Hello, pipe".*;
    applyMask(&data, .{ 0x37, 0xFA, 0x21, 0x3D });
    try std.testing.expect(!std.mem.eql(u8, "Hello, pipe", &data));
    applyMask(&data, .{ 0x37, 0xFA, 0x21, 0x3D });
    try std.testing.expectEqualStrings("Hello, pipe", &data);
}

test "rex: websocket unmasked header" {
    const header = parseHeader(&.{ 0x02, 0x05 });
    try std.testing.expect(!header.fin and !header.masked);
    try std.testing.expectEqual(Opcode.binary, header.opcode);
    try std.testing.expectEqual(@as(u64, 5), header.len);
    try std.testing.expect(Opcode.ping.isControl() and !Opcode.text.isControl());
}
