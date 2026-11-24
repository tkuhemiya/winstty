//! What a session looks like, as the server says it.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Identifiers are strings such as `block:<uuid>`.
pub const Id = []const u8;

pub const Axis = enum { horizontal, vertical };

pub const View = struct {
    revision: u64 = 0,
    session_id: ?Id = null,
    label: []const u8 = "",
    active_window_id: ?Id = null,
    windows: ?[]const Window = null,

    pub fn items(self: *const View) []const Window {
        return self.windows orelse &.{};
    }
};

pub const Window = struct {
    window_id: ?Id = null,
    label: []const u8 = "",
    focused_block_id: ?Id = null,
    zoomed_block_id: ?Id = null,
    layers: ?[]const Layer = null,

    pub fn id(self: *const Window) Id {
        return self.window_id orelse "";
    }

    /// The label if someone chose it, rather than the server.
    pub fn chosenLabel(self: *const Window) ?[]const u8 {
        const prefix = "Window ";
        if (self.label.len == 0) return null;
        if (std.mem.startsWith(u8, self.label, prefix) and
            self.label.len > prefix.len and
            std.mem.endsWith(u8, self.id(), self.label[prefix.len..])) return null;
        return self.label;
    }

    /// The layout that fills the window.
    pub fn layout(self: *const Window) ?*const Node {
        for (self.layers orelse return null) |*layer| {
            if (!std.mem.eql(u8, layer.kind, "tiled")) continue;
            return layer.layout;
        }
        return null;
    }
};

pub const Layer = struct {
    kind: []const u8 = "",
    layout: ?*const Node = null,
    blocks: ?[]const Block = null,
};

pub const Block = struct {
    block_id: ?Id = null,
    label: []const u8 = "",
    creator_name: []const u8 = "",
    owner: ?Id = null,
};

pub const Node = struct {
    block_id: ?Id = null,
    split: ?*const Split = null,

    pub fn count(self: *const Node) usize {
        const v = self.split orelse return @intFromBool(self.block_id != null);
        return v.before.count() + v.after.count();
    }

    /// The first block, or the last.
    pub fn end(self: *const Node, last: bool) ?Id {
        const v = self.split orelse return self.block_id;
        return (if (last) v.after else v.before).end(last);
    }

    pub fn contains(self: *const Node, id: Id) bool {
        if (self.block_id) |v| if (std.mem.eql(u8, v, id)) return true;
        const v = self.split orelse return false;
        return v.before.contains(id) or v.after.contains(id);
    }
};

pub const Split = struct {
    split_id: ?Id = null,
    direction: []const u8 = "",
    ratio: f64 = 0.5,
    before: *const Node,
    after: *const Node,

    pub fn axis(self: *const Split) Axis {
        // What isn't known is to be horizontal.
        return if (std.mem.eql(u8, self.direction, "vertical")) .vertical else .horizontal;
    }
};

pub const Session = struct {
    session_id: Id = "",
    label: []const u8 = "",
};

/// Newer servers add fields.
pub const options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

pub fn parse(comptime T: type, arena: Allocator, value: std.json.Value) !T {
    return try std.json.parseFromValueLeaky(T, arena, value, options);
}

const testing = std.testing;

fn testParse(arena: Allocator, text: []const u8) !View {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    return try parse(View, arena, value);
}

test "rex: a view" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const view = try testParse(arena.allocator(),
        \\{"revision":7,"session_id":"session:1","label":"work","active_window_id":"window:b","new":{"x":1},
        \\"windows":[
        \\ {"window_id":"window:aa12345678","label":"Window 12345678","focused_block_id":"block:1",
        \\  "layers":[{"layer_id":"layer:1","kind":"tiled","bounds":[0,0,1,1],"layout":{"rect":[0,0,1,1],"block_id":"block:1"},
        \\  "blocks":[{"block_id":"block:1","label":"shell","creator_name":"com.superlogical.terminal"}]}]},
        \\ {"window_id":"window:b","label":"editor","focused_block_id":"block:3","zoomed_block_id":"block:3",
        \\  "layers":[{"kind":"tiled","layout":{"rect":[0,0,1,1],"split":{"split_id":"split:1","direction":"vertical","ratio":0.25,
        \\   "before":{"block_id":"block:2"},"after":{"split":{"direction":"sideways","ratio":0.5,
        \\     "before":{"block_id":"block:3"},"after":{"block_id":"block:4"}}}}}},
        \\   {"kind":"floating","layout":{"block_id":"block:5"}}]}]}
    );
    try testing.expectEqual(@as(u64, 7), view.revision);
    try testing.expectEqualStrings("window:b", view.active_window_id.?);
    const windows = view.items();
    try testing.expectEqual(@as(usize, 2), windows.len);
    try testing.expect(windows[0].chosenLabel() == null);
    try testing.expectEqualStrings("editor", windows[1].chosenLabel().?);
    try testing.expectEqual(@as(usize, 1), windows[0].layout().?.count());

    const layout = windows[1].layout().?;
    try testing.expectEqual(@as(usize, 3), layout.count());
    try testing.expectEqual(Axis.vertical, layout.split.?.axis());
    try testing.expectEqual(Axis.horizontal, layout.split.?.after.split.?.axis());
    try testing.expectEqualStrings("block:2", layout.end(false).?);
    try testing.expectEqualStrings("block:4", layout.end(true).?);
    try testing.expect(layout.contains("block:3") and !layout.contains("block:5"));
}

test "rex: a view with nothing in it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const view = try testParse(arena.allocator(),
        \\{"revision":0,"session_id":"session:1","windows":null}
    );
    try testing.expectEqual(@as(usize, 0), view.items().len);
    const empty = try testParse(arena.allocator(),
        \\{"revision":1,"windows":[{"window_id":"window:a","layers":[{"kind":"tiled","layout":null}]}]}
    );
    try testing.expect(empty.items()[0].layout() == null);
}

test "rex: a label that only looks like one of the server's" {
    const w: Window = .{ .window_id = "window:abc", .label = "Window of opportunity" };
    try testing.expectEqualStrings("Window of opportunity", w.chosenLabel().?);
}
