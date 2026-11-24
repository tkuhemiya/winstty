//! The layout of a split tree while it changes.
//!
//! A split tree only knows where its views are going to be. This follows one,
//! and has the splits between views move to where the tree wants them. Views
//! start out with no space when they're new, and stay until they have none left
//! after they've been removed. Space is only ever divided, so whatever happens
//! there's never a hole or an overlap.
const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const c = @import("c.zig");
const motion = @import("motion.zig");

pub fn Layout(comptime View: type) type {
    return struct {
        const Self = @This();
        pub const Tree = SplitTree(View);
        const Handle = Tree.Node.Handle;

        const Node = union(enum) {
            leaf: Leaf,
            split: Split,
        };

        const Leaf = struct {
            view: *View,
            /// Removed from the tree. We have a reference to it.
            dying: bool = false,
            /// Getting back, or getting for the first time, all of its space.
            appearing: bool = false,
        };

        const Split = struct {
            handle: Handle,
            axis: Tree.Split.Layout,
            /// The part of the space that the left one has.
            ratio: motion.Spring,
            left: *Node,
            right: *Node,
            /// One of the two is dying, so it's not in the tree.
            closing: bool = false,
        };

        /// Where a view is.
        pub const Placement = struct {
            view: *View,
            area: c.RECT,
            /// Where it will be.
            target: c.RECT,
            dying: bool,
            /// It will have no space, though it may be in the tree.
            vanishing: bool,
            appearing: bool,
        };

        /// What's between two parts of the space.
        pub const Boundary = struct {
            handle: Handle,
            axis: Tree.Split.Layout,
            at: c_int,
            area: c.RECT,
        };

        alloc: Allocator,
        root: ?*Node = null,

        /// Views that are done dying. The owner has to drop the reference.
        dead: std.ArrayList(*View) = .empty,

        pub fn init(alloc: Allocator) Self {
            return .{ .alloc = alloc };
        }

        /// The dead should have been dealt with. Not the dying.
        pub fn deinit(self: *Self) void {
            self.dead.deinit(self.alloc);
        }

        /// Forget the tree. What was dying is dead.
        pub fn reset(self: *Self) void {
            if (self.root) |v| self.discard(v);
            self.root = null;
        }

        /// Follow a tree that may have changed. If not animated, the result is
        /// the layout of the tree.
        ///
        /// Views that were removed must still be valid.
        pub fn sync(self: *Self, tree: *const Tree, animated: bool) Allocator.Error!void {
            if (tree.isEmpty()) return self.reset();
            errdefer self.reset();

            // There's no way back from half a change.
            self.root = if (self.root) |root|
                try self.follow(root, tree, .root, animated)
            else
                try self.build(tree, .root);
            if (!animated) self.finish();
        }

        /// Advance, and returns whether there's more to come.
        pub fn step(self: *Self, style: motion.Style, elapsed: f32) bool {
            const root = self.root orelse return false;
            stepNode(root, style, elapsed);
            if (self.moving()) return true;
            self.finish();
            return false;
        }

        pub fn moving(self: *const Self) bool {
            return if (self.root) |v| nodeMoving(v) else false;
        }

        /// Have everything be where it's going to be.
        pub fn finish(self: *Self) void {
            self.root = self.finishNode(self.root orelse return);
        }

        /// The placements and boundaries in an area, in the order of the tree.
        pub fn arrange(
            self: *const Self,
            area: c.RECT,
            placements: *std.ArrayList(Placement),
            boundaries: *std.ArrayList(Boundary),
        ) Allocator.Error!void {
            placements.clearRetainingCapacity();
            boundaries.clearRetainingCapacity();
            try self.arrangeNode(
                self.root orelse return,
                area,
                area,
                false,
                placements,
                boundaries,
            );
        }

        fn arrangeNode(
            self: *const Self,
            node: *const Node,
            area: c.RECT,
            target: c.RECT,
            vanishing: bool,
            placements: *std.ArrayList(Placement),
            boundaries: *std.ArrayList(Boundary),
        ) Allocator.Error!void {
            switch (node.*) {
                .leaf => |leaf| try placements.append(self.alloc, .{
                    .view = leaf.view,
                    .area = area,
                    .target = target,
                    .dying = leaf.dying,
                    .vanishing = vanishing or leaf.dying,
                    .appearing = leaf.appearing,
                }),
                .split => |split| {
                    const now = divide(area, split.axis, split.ratio.value);
                    const then = divide(target, split.axis, split.ratio.target);
                    if (!split.closing and split.ratio.target > 0 and split.ratio.target < 1) {
                        try boundaries.append(self.alloc, .{
                            .handle = split.handle,
                            .axis = split.axis,
                            .at = now.at,
                            .area = area,
                        });
                    }
                    try self.arrangeNode(
                        split.left,
                        now.left,
                        then.left,
                        vanishing or split.ratio.target <= 0,
                        placements,
                        boundaries,
                    );
                    try self.arrangeNode(
                        split.right,
                        now.right,
                        then.right,
                        vanishing or split.ratio.target >= 1,
                        placements,
                        boundaries,
                    );
                },
            }
        }

        fn divide(area: c.RECT, axis: Tree.Split.Layout, ratio: f32) struct {
            at: c_int,
            left: c.RECT,
            right: c.RECT,
        } {
            const start, const end = switch (axis) {
                .horizontal => .{ area.left, area.right },
                .vertical => .{ area.top, area.bottom },
            };
            const space: f32 = @floatFromInt(@max(0, end - start));

            // A spring overshoots, but the space doesn't end where it ends.
            const at = start + @as(c_int, @intFromFloat(std.math.clamp(ratio, 0, 1) * space));
            var left = area;
            var right = area;
            switch (axis) {
                .horizontal => {
                    left.right = at;
                    right.left = at;
                },
                .vertical => {
                    left.bottom = at;
                    right.top = at;
                },
            }
            return .{ .at = at, .left = left, .right = right };
        }

        //-----------------------------------------------------------
        // Following

        fn create(self: *Self, value: Node) Allocator.Error!*Node {
            const node = try self.alloc.create(Node);
            node.* = value;
            return node;
        }

        fn build(self: *Self, tree: *const Tree, handle: Handle) Allocator.Error!*Node {
            switch (tree.nodes[handle.idx()]) {
                .leaf => |view| return try self.create(.{ .leaf = .{ .view = view } }),
                .split => |split| {
                    const left = try self.build(tree, split.left);
                    errdefer self.discard(left);
                    const right = try self.build(tree, split.right);
                    errdefer self.discard(right);
                    return try self.create(.{ .split = .{
                        .handle = handle,
                        .axis = split.layout,
                        .ratio = .at(wantedRatio(tree, split)),
                        .left = left,
                        .right = right,
                    } });
                },
            }
        }

        /// What a node becomes, to follow a part of the tree. On error it's as
        /// it was, or in part what it was becoming, but always whole.
        fn follow(
            self: *Self,
            node: *Node,
            tree: *const Tree,
            handle: Handle,
            animated: bool,
        ) Allocator.Error!*Node {
            if (node.* == .split) {
                const split = &node.split;
                const left = lives(split.left, tree, handle);
                const right = lives(split.right, tree, handle);
                if (left != right and animated) {
                    // The one that's left gets all of the space.
                    split.closing = true;
                    split.handle = .root;
                    split.ratio.target = if (left) 1 else 0;
                    self.kill(if (left) split.right else split.left);
                    const child = if (left) &split.left else &split.right;
                    child.* = try self.follow(child.*, tree, handle, animated);
                    return node;
                } else if (left != right) {
                    const keep, const drop = if (left)
                        .{ split.left, split.right }
                    else
                        .{ split.right, split.left };
                    const result = try self.follow(keep, tree, handle, animated);
                    self.discard(drop);
                    self.alloc.destroy(node);
                    return result;
                }
            }

            switch (tree.nodes[handle.idx()]) {
                .leaf => |view| if (node.* == .leaf and node.leaf.view == view) return node,
                .split => |want| {
                    if (node.* == .split and
                        node.split.axis == want.layout and
                        within(node.split.left, tree, want.left) and
                        within(node.split.right, tree, want.right))
                    {
                        const split = &node.split;
                        split.closing = false;
                        split.handle = handle;
                        const ratio = wantedRatio(tree, want);
                        // What's got no space is about to get some.
                        if (split.ratio.target <= 0 and ratio > 0) appear(split.left);
                        if (split.ratio.target >= 1 and ratio < 1) appear(split.right);
                        split.ratio.target = ratio;
                        split.left = try self.follow(split.left, tree, want.left, animated);
                        split.right = try self.follow(split.right, tree, want.right, animated);
                        return node;
                    }

                    // One side of it is all new.
                    const left = lives(node, tree, want.left);
                    const right = lives(node, tree, want.right);
                    if (left != right) {
                        const new = try self.build(tree, if (left) want.right else want.left);
                        errdefer self.discard(new);
                        appear(new);
                        const wrapper = try self.create(undefined);
                        errdefer self.alloc.destroy(wrapper);
                        const old = try self.follow(
                            node,
                            tree,
                            if (left) want.left else want.right,
                            animated,
                        );
                        wrapper.* = .{ .split = .{
                            .handle = handle,
                            .axis = want.layout,
                            .ratio = .{
                                .value = if (left) 1 else 0,
                                .target = wantedRatio(tree, want),
                            },
                            .left = if (left) old else new,
                            .right = if (left) new else old,
                        } };
                        return wrapper;
                    }
                },
            }

            // It's nothing like it was.
            const result = try self.build(tree, handle);
            self.discard(node);
            return result;
        }

        /// Where the tree wants a split to be, which is at the edge if a view
        /// is zoomed.
        fn wantedRatio(tree: *const Tree, split: Tree.Split) f32 {
            if (tree.zoomed) |zoomed| {
                if (isUnder(tree, split.left, zoomed)) return 1;
                if (isUnder(tree, split.right, zoomed)) return 0;
            }
            return @floatCast(split.ratio);
        }

        fn isUnder(tree: *const Tree, handle: Handle, other: Handle) bool {
            if (handle == other) return true;
            return switch (tree.nodes[handle.idx()]) {
                .leaf => false,
                .split => |v| isUnder(tree, v.left, other) or isUnder(tree, v.right, other),
            };
        }

        fn hasView(tree: *const Tree, handle: Handle, view: *const View) bool {
            return switch (tree.nodes[handle.idx()]) {
                .leaf => |v| v == view,
                .split => |v| hasView(tree, v.left, view) or hasView(tree, v.right, view),
            };
        }

        /// Whether any view of the node is in the part of the tree.
        fn lives(node: *const Node, tree: *const Tree, handle: Handle) bool {
            return switch (node.*) {
                .leaf => |v| !v.dying and hasView(tree, handle, v.view),
                .split => |v| lives(v.left, tree, handle) or lives(v.right, tree, handle),
            };
        }

        /// Whether every view of the node that's in the tree is in that part of
        /// it, and there's at least one.
        fn within(node: *const Node, tree: *const Tree, handle: Handle) bool {
            return lives(node, tree, handle) and !strays(node, tree, handle);
        }

        fn strays(node: *const Node, tree: *const Tree, handle: Handle) bool {
            return switch (node.*) {
                .leaf => |v| !v.dying and
                    hasView(tree, .root, v.view) and
                    !hasView(tree, handle, v.view),
                .split => |v| strays(v.left, tree, handle) or strays(v.right, tree, handle),
            };
        }

        fn appear(node: *Node) void {
            switch (node.*) {
                .leaf => |*v| v.appearing = true,
                .split => |v| {
                    appear(v.left);
                    appear(v.right);
                },
            }
        }

        /// Keep the views of a node for as long as they're shown.
        fn kill(self: *Self, node: *Node) void {
            switch (node.*) {
                .leaf => |*v| if (!v.dying) {
                    v.dying = true;
                    _ = v.view.ref();
                },
                .split => |v| {
                    self.kill(v.left);
                    self.kill(v.right);
                },
            }
        }

        /// Free a node. Views of it that were dying are dead.
        fn discard(self: *Self, node: *Node) void {
            switch (node.*) {
                .leaf => |v| if (v.dying) self.dead.append(self.alloc, v.view) catch {
                    // It leaks, which beats destroying it here and now.
                },
                .split => |v| {
                    self.discard(v.left);
                    self.discard(v.right);
                },
            }
            self.alloc.destroy(node);
        }

        //-----------------------------------------------------------
        // Moving

        fn stepNode(node: *Node, style: motion.Style, elapsed: f32) void {
            switch (node.*) {
                .leaf => {},
                .split => |*v| {
                    v.ratio.step(style, elapsed);
                    stepNode(v.left, style, elapsed);
                    stepNode(v.right, style, elapsed);
                },
            }
        }

        fn nodeMoving(node: *const Node) bool {
            return switch (node.*) {
                .leaf => false,
                .split => |v| v.ratio.moving() or nodeMoving(v.left) or nodeMoving(v.right),
            };
        }

        fn finishNode(self: *Self, node: *Node) *Node {
            switch (node.*) {
                .leaf => |*v| {
                    v.appearing = false;
                    return node;
                },
                .split => |*v| {
                    v.ratio.finish();
                    if (!v.closing) {
                        v.left = self.finishNode(v.left);
                        v.right = self.finishNode(v.right);
                        return node;
                    }
                    const keep, const drop = if (v.ratio.target > 0.5)
                        .{ v.left, v.right }
                    else
                        .{ v.right, v.left };
                    self.discard(drop);
                    self.alloc.destroy(node);
                    return self.finishNode(keep);
                },
            }
        }
    };
}

//---------------------------------------------------------------
// Tests

const testing = std.testing;

const TestView = struct {
    refs: usize = 0,

    pub fn ref(self: *TestView) *TestView {
        self.refs += 1;
        return self;
    }

    pub fn unref(self: *TestView) void {
        self.refs -= 1;
    }

    pub fn eql(a: *const TestView, b: *const TestView) bool {
        return a == b;
    }
};

const TestLayout = Layout(TestView);
const TestTree = TestLayout.Tree;

const Harness = struct {
    layout: TestLayout = .init(testing.allocator),
    tree: TestTree,
    views: [8]TestView = @splat(.{}),
    placements: std.ArrayList(TestLayout.Placement) = .empty,
    boundaries: std.ArrayList(TestLayout.Boundary) = .empty,

    const area: c.RECT = .{ .left = 100, .top = 50, .right = 1100, .bottom = 650 };

    fn init(self: *Harness) !void {
        self.* = .{ .tree = undefined };
        self.tree = try .init(testing.allocator, &self.views[0]);
        try self.layout.sync(&self.tree, true);
    }

    fn deinit(self: *Harness) void {
        self.layout.reset();
        self.bury();
        self.layout.deinit();
        self.tree.deinit();
        self.placements.deinit(testing.allocator);
        self.boundaries.deinit(testing.allocator);
        for (self.views) |view| testing.expectEqual(0, view.refs) catch @panic("leaked a view");
    }

    fn bury(self: *Harness) void {
        for (self.layout.dead.items) |view| view.unref();
        self.layout.dead.clearRetainingCapacity();
    }

    fn set(self: *Harness, tree: TestTree, animated: bool) !void {
        var old = self.tree;
        self.tree = tree;
        try self.layout.sync(&self.tree, animated);
        old.deinit();
    }

    fn split(self: *Harness, from: usize, to: usize, direction: TestTree.Split.Direction) !void {
        var insert: TestTree = try .init(testing.allocator, &self.views[to]);
        defer insert.deinit();
        try self.set(try self.tree.split(
            testing.allocator,
            self.tree.locate(&self.views[from]).?,
            direction,
            0.5,
            &insert,
        ), true);
    }

    fn remove(self: *Harness, view: usize) !void {
        try self.set(try self.tree.remove(
            testing.allocator,
            self.tree.locate(&self.views[view]).?,
        ), true);
    }

    fn zoom(self: *Harness, view: ?usize) !void {
        self.tree.zoom(if (view) |v| self.tree.locate(&self.views[v]).? else null);
        try self.layout.sync(&self.tree, true);
    }

    /// Checks that the views divide the area, with nothing left over.
    fn arrange(self: *Harness) !void {
        try self.layout.arrange(area, &self.placements, &self.boundaries);
        var total: i64 = 0;
        for (self.placements.items, 0..) |a, i| {
            try testing.expect(a.area.left <= a.area.right and a.area.top <= a.area.bottom);
            try testing.expect(a.area.left >= area.left and a.area.right <= area.right);
            try testing.expect(a.area.top >= area.top and a.area.bottom <= area.bottom);
            total += @as(i64, a.area.right - a.area.left) * (a.area.bottom - a.area.top);
            for (self.placements.items[i + 1 ..]) |b| {
                const apart = a.area.right <= b.area.left or b.area.right <= a.area.left or
                    a.area.bottom <= b.area.top or b.area.bottom <= a.area.top;
                try testing.expect(apart);
            }
        }
        try testing.expectEqual(@as(i64, 1000 * 600), total);
    }

    fn step(self: *Harness) !bool {
        const more = self.layout.step(.natural, 1.0 / 60.0);
        try self.arrange();
        return more;
    }

    fn settle(self: *Harness) !void {
        var frames: usize = 0;
        while (try self.step()) : (frames += 1) try testing.expect(frames < 100);
    }

    fn get(self: *Harness, view: usize) !TestLayout.Placement {
        try self.arrange();
        for (self.placements.items) |p| if (p.view == &self.views[view]) return p;
        return error.NotPlaced;
    }

    fn width(self: *Harness, view: usize) !c_int {
        const p = try self.get(view);
        return p.area.right - p.area.left;
    }
};

test "layout: a new split grows from nothing, and overshoots" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    try testing.expectEqual(1000, try h.width(0));
    try testing.expectEqual(0, try h.width(1));
    try testing.expect((try h.get(1)).appearing);
    try testing.expect(!(try h.get(0)).appearing);
    try testing.expectEqual(500, (try h.get(1)).target.right - (try h.get(1)).target.left);

    var max: c_int = 0;
    var previous: c_int = 0;
    var grew = false;
    while (try h.step()) {
        const width = try h.width(1);
        if (width > previous and previous > 0 and width < 500) grew = true;
        previous = width;
        max = @max(max, width);
    }
    try testing.expect(grew);
    try testing.expect(max > 505 and max < 560);
    try testing.expectEqual(500, try h.width(1));
    try testing.expect(!(try h.get(1)).appearing);
    try testing.expectEqual(1, h.boundaries.items.len);
}

test "layout: new splits to the left and above" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .left);
    try testing.expectEqual(0, try h.width(1));
    try testing.expectEqual(Harness.area.left, (try h.get(1)).area.left);
    try h.settle();
    try testing.expectEqual(Harness.area.left, (try h.get(1)).area.left);

    try h.split(0, 2, .up);
    const p = try h.get(2);
    try testing.expectEqual(p.area.top, p.area.bottom);
    try testing.expectEqual(Harness.area.top, p.area.top);
    try h.settle();
}

test "layout: a removed view shrinks, and is kept until it's gone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    try h.settle();
    try h.remove(0);
    try testing.expectEqual(500, try h.width(0));
    try testing.expect((try h.get(0)).dying);
    try testing.expect((try h.get(0)).vanishing);
    try testing.expectEqual(1, h.views[0].refs);
    try testing.expectEqual(0, h.boundaries.items.len);

    _ = try h.step();
    _ = try h.step();
    _ = try h.step();
    const width = try h.width(0);
    try testing.expect(width > 0 and width < 500);
    try testing.expectEqual(0, h.layout.dead.items.len);

    try h.settle();
    try testing.expectEqual(1000, try h.width(1));
    try testing.expectEqual(1, h.layout.dead.items.len);
    try testing.expectError(error.NotPlaced, h.get(0));
    h.bury();
    try testing.expectEqual(0, h.views[0].refs);
}

test "layout: a second change carries on from the first" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    for (0..4) |_| _ = try h.step();
    const before = .{ (try h.get(0)).area, (try h.get(1)).area };
    try h.split(1, 2, .down);
    try testing.expectEqual(before[0], (try h.get(0)).area);
    try testing.expectEqual(before[1], (try h.get(1)).area);
    try h.settle();
    try testing.expectEqual(500, try h.width(2));

    // Close one while another is still opening.
    try h.split(0, 3, .right);
    for (0..3) |_| _ = try h.step();
    const opening = (try h.get(3)).area;
    try h.remove(2);
    try testing.expectEqual(opening, (try h.get(3)).area);
    try h.settle();
    h.bury();
    try testing.expectEqual(0, h.views[2].refs);
}

test "layout: closing what's still opening, and what's already closing" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    for (0..3) |_| _ = try h.step();
    try h.split(1, 2, .right);
    for (0..3) |_| _ = try h.step();
    try h.remove(1);
    for (0..2) |_| _ = try h.step();
    try h.remove(2);
    for (0..2) |_| _ = try h.step();
    try h.split(0, 3, .down);
    try h.settle();
    h.bury();
    try testing.expectEqual(1000, try h.width(0));
    try testing.expectEqual(1000, try h.width(3));
    for ([_]usize{ 1, 2 }) |i| try testing.expectEqual(0, h.views[i].refs);
}

test "layout: zoom takes all of the space, and gives it back" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    try h.split(1, 2, .down);
    try h.settle();
    const before = .{ (try h.get(0)).area, (try h.get(1)).area, (try h.get(2)).area };

    try h.zoom(2);
    try testing.expect((try h.get(0)).vanishing and (try h.get(1)).vanishing);
    try testing.expect(!(try h.get(0)).dying);
    try testing.expect(!(try h.get(2)).vanishing);
    try h.settle();
    try testing.expectEqual(Harness.area, (try h.get(2)).area);
    try testing.expectEqual(0, try h.width(0));
    try testing.expectEqual(0, h.boundaries.items.len);

    try h.zoom(null);
    try testing.expect((try h.get(0)).appearing and (try h.get(1)).appearing);
    try testing.expect(!(try h.get(2)).appearing);
    try h.settle();
    try testing.expectEqual(before[0], (try h.get(0)).area);
    try testing.expectEqual(before[1], (try h.get(1)).area);
    try testing.expectEqual(before[2], (try h.get(2)).area);
}

test "layout: equalize moves the splits" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    try h.split(1, 2, .right);
    try h.settle();
    try testing.expectEqual(250, try h.width(2));
    try h.set(try h.tree.equalize(testing.allocator), true);
    try testing.expectEqual(250, try h.width(2));
    try h.settle();
    for (0..3) |i| try testing.expect(@abs(try h.width(i) - 333) <= 2);
}

test "layout: not animated is there at once" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    _ = try h.step();
    try h.layout.sync(&h.tree, false);
    try testing.expect(!h.layout.moving());
    try testing.expectEqual(500, try h.width(0));

    try h.set(try h.tree.remove(testing.allocator, h.tree.locate(&h.views[0]).?), false);
    try testing.expectEqual(0, h.layout.dead.items.len);
    try testing.expectEqual(0, h.views[0].refs);
    try testing.expectEqual(1000, try h.width(1));
}

test "layout: finishing is the layout of the tree" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();

    try h.split(0, 1, .right);
    _ = try h.step();
    try h.remove(0);
    _ = try h.step();
    h.layout.finish();
    try h.arrange();
    try testing.expectEqual(1, h.placements.items.len);
    try testing.expectEqual(1000, try h.width(1));
    try testing.expectEqual(1, h.layout.dead.items.len);
}

test "layout: any series of changes divides the space" {
    var prng: std.Random.DefaultPrng = .init(4);
    const random = prng.random();
    for (0..60) |_| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        for (0..24) |_| {
            var used: [8]bool = undefined;
            var count: usize = 0;
            for (&h.views, &used) |*view, *v| {
                v.* = h.tree.locate(view) != null;
                count += @intFromBool(v.*);
            }
            const i = random.uintLessThan(usize, 8);
            switch (random.uintLessThan(u8, 4)) {
                // Not one that's still dying, which a new surface never is.
                0, 1 => if (!used[i] and h.views[i].refs == 0) {
                    var from = random.uintLessThan(usize, 8);
                    while (!used[from]) from = (from + 1) % 8;
                    try h.split(from, i, random.enumValue(TestTree.Split.Direction));
                },
                2 => if (used[i] and count > 1) try h.remove(i),
                else => if (count > 1) {
                    if (h.tree.zoomed != null) {
                        try h.zoom(null);
                    } else if (used[i]) {
                        try h.zoom(i);
                    } else {
                        try h.set(try h.tree.equalize(testing.allocator), true);
                    }
                },
            }
            for (0..random.uintLessThan(usize, 12)) |_| _ = try h.step();
            h.bury();
        }
        try h.settle();
        h.bury();

        // It ended up the same as if nothing had moved.
        var fresh: TestLayout = .init(testing.allocator);
        defer fresh.deinit();
        defer fresh.reset();
        try fresh.sync(&h.tree, false);
        var placements: std.ArrayList(TestLayout.Placement) = .empty;
        defer placements.deinit(testing.allocator);
        try fresh.arrange(Harness.area, &placements, &h.boundaries);
        try h.arrange();
        try testing.expectEqual(placements.items.len, h.placements.items.len);
        for (placements.items, h.placements.items) |a, b| {
            try testing.expectEqual(a.view, b.view);
            try testing.expectEqual(a.area, b.area);
        }
    }
}
