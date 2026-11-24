//! What programs say they're doing, as the server tells it. Programs report it
//! with OSC 7501.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// In order of how much it needs the user.
pub const State = enum {
    idle,
    done,
    working,
    @"error",
    blocked,

    pub fn parse(text: []const u8) State {
        // What isn't known is to be idle.
        return std.meta.stringToEnum(State, text) orelse .idle;
    }

    pub fn max(a: State, b: State) State {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

pub const Summary = struct {
    state: State = .idle,
    /// A percentage, if there's one.
    progress: ?u8 = null,
    /// A line that the program wrote about it, if any.
    text: []const u8 = "",
};

/// Programs can write anything. This is a line of plain text, and not a long
/// one.
fn plainLine(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const max = 200;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const view = std.unicode.Utf8View.init(text) catch return "";
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        if (out.items.len + slice.len > max) break;
        const cp = std.unicode.utf8Decode(slice) catch continue;
        switch (cp) {
            0...0x1F, 0x7F...0x9F, 0x2028, 0x2029 => try out.append(alloc, ' '),
            // These change the direction of what's around them.
            0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069 => {},
            else => try out.appendSlice(alloc, slice),
        }
    }
    if (out.items.len == 0) return "";
    return try out.toOwnedSlice(alloc);
}

/// The records of a pane.
pub const Records = struct {
    map: std.StringHashMapUnmanaged(Record) = .empty,

    /// More than a server keeps.
    const max_records = 256;

    const Record = struct {
        state: State,
        progress: ?u8,
        text: []const u8 = "",
        /// The user has been at the pane since.
        seen: bool = false,
    };

    pub fn deinit(self: *Records, alloc: Allocator) void {
        self.clear(alloc);
        self.map.deinit(alloc);
    }

    pub fn clear(self: *Records, alloc: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.text);
        }
        self.map.clearRetainingCapacity();
    }

    pub fn set(
        self: *Records,
        alloc: Allocator,
        id: []const u8,
        state: State,
        progress: ?u8,
        text: []const u8,
    ) !void {
        const line = try plainLine(alloc, text);
        errdefer alloc.free(line);
        if (self.map.getPtr(id)) |v| {
            alloc.free(v.text);
            v.* = .{ .state = state, .progress = progress, .text = line };
            return;
        }
        if (self.map.count() >= max_records) return alloc.free(line);
        const key = try alloc.dupe(u8, id);
        errdefer alloc.free(key);
        try self.map.put(alloc, key, .{ .state = state, .progress = progress, .text = line });
    }

    pub fn remove(self: *Records, alloc: Allocator, id: []const u8) void {
        const kv = self.map.fetchRemove(id) orelse return;
        alloc.free(kv.key);
        alloc.free(kv.value.text);
    }

    /// The user is at the pane. Returns whether that changed anything.
    pub fn see(self: *Records) bool {
        var changed = false;
        var it = self.map.valueIterator();
        while (it.next()) |v| switch (v.state) {
            .done, .@"error" => if (!v.seen) {
                v.seen = true;
                changed = true;
            },
            .idle, .working, .blocked => {},
        };
        return changed;
    }

    /// The one that needs the user the most.
    pub fn summary(self: *const Records) Summary {
        var result: Summary = .{};
        var it = self.map.valueIterator();
        while (it.next()) |v| {
            if (v.seen) continue;
            if (@backingInt(v.state) < @backingInt(result.state)) continue;
            if (v.state == result.state and v.progress == null) continue;
            result = .{ .state = v.state, .progress = v.progress, .text = v.text };
        }
        return result;
    }
};

const testing = std.testing;

test "rex: the status that needs the user the most" {
    var r: Records = .{};
    defer r.deinit(testing.allocator);
    try testing.expectEqual(State.idle, r.summary().state);
    try r.set(testing.allocator, "", .done, null, "");
    try testing.expectEqual(State.done, r.summary().state);
    try r.set(testing.allocator, "build", .working, 40, "");
    try testing.expectEqual(Summary{ .state = .working, .progress = 40 }, r.summary());
    try r.set(testing.allocator, "build/test", .@"error", null, "");
    try testing.expectEqual(State.@"error", r.summary().state);
    try r.set(testing.allocator, "ask", .blocked, null, "");
    try testing.expectEqual(State.blocked, r.summary().state);
    r.remove(testing.allocator, "ask");
    r.remove(testing.allocator, "never there");
    r.remove(testing.allocator, "build/test");
    try testing.expectEqual(State.working, r.summary().state);
}

test "rex: done stays until it's seen" {
    var r: Records = .{};
    defer r.deinit(testing.allocator);
    try r.set(testing.allocator, "", .done, null, "");
    try r.set(testing.allocator, "x", .working, null, "");
    try testing.expect(r.see());
    try testing.expect(!r.see());
    try testing.expectEqual(State.working, r.summary().state);
    r.remove(testing.allocator, "x");
    try testing.expectEqual(State.idle, r.summary().state);

    // It's news again.
    try r.set(testing.allocator, "", .@"error", null, "");
    try testing.expectEqual(State.@"error", r.summary().state);
}

test "rex: what programs write is a line of plain text" {
    var r: Records = .{};
    defer r.deinit(testing.allocator);
    try r.set(testing.allocator, "", .blocked, null, "<b>hi</b>\r\nhttps://x.y\x1b[31m\u{202E}z");
    try testing.expectEqualStrings("<b>hi</b>  https://x.y [31mz", r.summary().text);
    const long: [500]u8 = @splat('x');
    try r.set(testing.allocator, "", .blocked, null, &long);
    try testing.expectEqual(@as(usize, 200), r.summary().text.len);
    try r.set(testing.allocator, "", .blocked, null, "\xFF\xFE");
    try testing.expectEqualStrings("", r.summary().text);
}

test "rex: states that aren't known are idle" {
    try testing.expectEqual(State.idle, State.parse("pondering"));
    try testing.expectEqual(State.@"error", State.parse("error"));
    try testing.expectEqual(State.blocked, State.max(.blocked, .working));
}
