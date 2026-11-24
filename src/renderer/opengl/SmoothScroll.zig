//! Smooth scrolling, as an effect on presented frames.
//!
//! The terminal scrolls by rows and knows nothing of this. We remember recently
//! drawn rows in a texture, and when the viewport moves, show them sliding from
//! where they were to where they are. Since the old and new viewport are of the
//! same document, and everything between was drawn on the way, all of what has
//! to be shown is there.
const SmoothScroll = @This();

const std = @import("std");
const assert = std.debug.assert;
const gl = @import("opengl");
const global = @import("../../global.zig");
const Target = @import("Target.zig");

const log = std.log.scoped(.opengl);

/// How long it takes for the remaining distance to shrink by two thirds.
const time_constant_ms = 45;

/// What's needed of a frame to know how it has scrolled.
pub const Geometry = struct {
    /// Rows in the document, of the first in the viewport, and in the viewport.
    total: usize = 0,
    offset: usize = 0,
    rows: usize = 0,

    /// In pixels. The grid starts below the padding.
    row_height: usize = 0,
    padding_top: usize = 0,
    width: usize = 0,
    height: usize = 0,

    fn sameLayout(a: Geometry, b: Geometry) bool {
        return a.rows == b.rows and
            a.row_height == b.row_height and
            a.padding_top == b.padding_top and
            a.width == b.width and
            a.height == b.height;
    }
};

/// The position in the document that's shown, which follows the real one.
const Position = struct {
    shown: f64 = 0,
    animating: bool = false,

    /// Take note of the viewport having moved.
    fn move(self: *Position, from: Geometry, to: Geometry) void {
        const target: f64 = @floatFromInt(to.offset);

        // With new output the viewport moves along with the document, which
        // isn't scrolling. After a jump the rows between weren't drawn.
        const moved = @max(from.offset, to.offset) - @min(from.offset, to.offset);
        if (moved > 0 and (from.total != to.total or moved > to.rows)) {
            self.* = .{ .shown = target };
            return;
        }
        if (moved > 0) self.animating = true;

        // Only so many rows are remembered.
        const max: f64 = @floatFromInt(to.rows);
        self.shown = std.math.clamp(self.shown, target - max, target + max);
    }

    /// Get closer to the target.
    fn step(self: *Position, target_row: usize, row_height: usize, elapsed_ms: f64) void {
        if (!self.animating) return;
        const target: f64 = @floatFromInt(target_row);
        self.shown += (target - self.shown) * (1 - @exp(-elapsed_ms / time_constant_ms));
        if (@abs(target - self.shown) * @as(f64, @floatFromInt(row_height)) < 0.5) {
            self.* = .{ .shown = target };
        }
    }
};

/// Pixels of the ring, which may wrap around.
const Segment = struct { start: usize, offset: usize, len: usize };

fn segments(ring: usize, start: usize, len: usize) [2]Segment {
    assert(len <= ring);
    const first_start = start % ring;
    const first_len = @min(len, ring - first_start);
    return .{
        .{ .start = first_start, .offset = 0, .len = first_len },
        .{ .start = 0, .offset = first_len, .len = len - first_len },
    };
}

texture: gl.Texture,
framebuffer: gl.Framebuffer,
geometry: Geometry,
position: Position,
last_frame: ?std.Io.Timestamp = null,

/// Null if there's nothing to scroll, or not enough memory for it.
fn init(geometry: Geometry) !?SmoothScroll {
    const ring = ringHeight(geometry);
    if (ring == 0 or geometry.width == 0 or ring > 16384) return null;

    const texture = try gl.Texture.create();
    errdefer texture.destroy();
    {
        const bound = try texture.bind(.@"2d");
        defer bound.unbind();
        try bound.parameter(.min_filter, .nearest);
        try bound.parameter(.mag_filter, .nearest);
        // Not sRGB. The values are copied as they are.
        try bound.image2D(
            0,
            .rgba,
            @intCast(geometry.width),
            @intCast(ring),
            .rgba,
            .unsigned_byte,
            null,
        );
        try bound.parameter(.base_level, 0);
        try bound.parameter(.max_level, 0);
    }

    const framebuffer = try gl.Framebuffer.create();
    errdefer framebuffer.destroy();
    {
        const bound = try framebuffer.bind(.framebuffer);
        defer bound.unbind();
        try bound.texture2D(.color0, .@"2d", texture, 0);
        if (bound.checkStatus() != .complete) return error.FramebufferIncomplete;
    }

    return .{
        .texture = texture,
        .framebuffer = framebuffer,
        .geometry = geometry,
        .position = .{ .shown = @floatFromInt(geometry.offset) },
    };
}

pub fn deinit(self: *SmoothScroll) void {
    self.framebuffer.destroy();
    self.texture.destroy();
    self.* = undefined;
}

/// Enough for two viewports, since the one shown may be a whole one behind.
fn ringHeight(geometry: Geometry) usize {
    return geometry.rows * 2 * geometry.row_height;
}

/// Called with a frame that has been copied to the screen. Shows it sliding
/// over that if it has to. Creates and destroys what it needs in the slot.
///
/// The frame is `bottom` above the bottom of the screen, see `blitToScreen`.
pub fn present(
    slot: *?SmoothScroll,
    target: *const Target,
    geometry: Geometry,
    bottom: i32,
) !void {
    // The grid may not fit for a moment while resizing.
    if (geometry.width != target.width or
        geometry.height != target.height or
        geometry.padding_top + geometry.rows * geometry.row_height > geometry.height)
    {
        reset(slot);
        return;
    }

    if (slot.*) |*self| {
        if (!self.geometry.sameLayout(geometry)) reset(slot);
    }
    if (slot.* == null) slot.* = try init(geometry);
    const self: *SmoothScroll = if (slot.*) |*v| v else return;

    const was_animating = self.position.animating;
    self.position.move(self.geometry, geometry);
    self.geometry = geometry;

    const now: std.Io.Timestamp = .now(global.io(), .awake);
    if (self.position.animating) {
        const elapsed_ms: f64 = elapsed: {
            // It was at rest until now, however long ago the last frame was.
            if (!was_animating) break :elapsed 8;
            const last = self.last_frame orelse break :elapsed 8;
            const ns: f64 = @floatFromInt(last.durationTo(now).nanoseconds);
            break :elapsed @min(ns / std.time.ns_per_ms, 50);
        };
        self.position.step(geometry.offset, geometry.row_height, elapsed_ms);
    }
    self.last_frame = now;

    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err|
        log.err("error re-enabling GL_FRAMEBUFFER_SRGB err={}", .{err});
    try self.remember(target);
    if (self.position.animating) try self.show(bottom);
}

pub fn reset(slot: *?SmoothScroll) void {
    if (slot.*) |*v| v.deinit();
    slot.* = null;
}

/// Copy the rows of a frame to their place in the ring.
fn remember(self: *const SmoothScroll, target: *const Target) !void {
    const read = try target.framebuffer.bind(.read);
    defer read.unbind();
    const draw = try self.framebuffer.bind(.draw);
    defer draw.unbind();

    const g = self.geometry;
    const ring = ringHeight(g);
    for (segments(ring, g.offset * g.row_height, g.rows * g.row_height)) |s| {
        try blit(
            g.width,
            g.height - g.padding_top - s.offset,
            @intCast(ring - s.start),
            s.len,
        );
    }
}

/// Copy rows from the ring to the screen.
fn show(self: *const SmoothScroll, bottom: i32) !void {
    const read = try self.framebuffer.bind(.read);
    defer read.unbind();
    const screen: gl.Framebuffer = .{ .id = 0 };
    const draw = try screen.bind(.draw);
    defer draw.unbind();

    const g = self.geometry;
    const ring = ringHeight(g);
    const top = self.position.shown * @as(f64, @floatFromInt(g.row_height));
    const start: usize = @intFromFloat(@max(0, @round(top)));
    for (segments(ring, start, g.rows * g.row_height)) |s| {
        try blit(
            g.width,
            ring - s.start,
            @as(i32, @intCast(g.height - g.padding_top - s.offset)) + bottom,
            s.len,
        );
    }
}

/// Copy a full width part, given its upper edges. Y is up in OpenGL.
fn blit(width: usize, src_top: usize, dst_top: i32, height: usize) !void {
    if (height == 0) return;
    try gl.blitFramebuffer(
        0,
        @intCast(src_top - height),
        @intCast(width),
        @intCast(src_top),
        0,
        dst_top - @as(i32, @intCast(height)),
        @intCast(width),
        dst_top,
        .{ .color_buffer_bit = true },
        .nearest,
    );
}

test "smooth scroll: scrolling animates and settles" {
    var p: Position = .{ .shown = 100 };
    const from: Geometry = .{ .total = 200, .offset = 100, .rows = 25 };
    const to: Geometry = .{ .total = 200, .offset = 97, .rows = 25 };
    p.move(from, to);
    try std.testing.expect(p.animating);
    try std.testing.expectEqual(@as(f64, 100), p.shown);

    var previous = p.shown;
    var frames: usize = 0;
    while (p.animating) : (frames += 1) {
        p.step(97, 20, 16);
        try std.testing.expect(p.shown < previous and p.shown >= 97);
        previous = p.shown;
        try std.testing.expect(frames < 60);
    }
    try std.testing.expectEqual(@as(f64, 97), p.shown);
    try std.testing.expect(frames > 5);
}

test "smooth scroll: output and jumps don't animate" {
    var p: Position = .{ .shown = 100 };
    p.move(
        .{ .total = 125, .offset = 100, .rows = 25 },
        .{ .total = 128, .offset = 103, .rows = 25 },
    );
    try std.testing.expect(!p.animating);
    try std.testing.expectEqual(@as(f64, 103), p.shown);

    p.move(
        .{ .total = 128, .offset = 103, .rows = 25 },
        .{ .total = 128, .offset = 0, .rows = 25 },
    );
    try std.testing.expect(!p.animating);
    try std.testing.expectEqual(@as(f64, 0), p.shown);
}

test "smooth scroll: output while looking at history doesn't disturb it" {
    var p: Position = .{ .shown = 50 };
    p.move(
        .{ .total = 125, .offset = 50, .rows = 25 },
        .{ .total = 130, .offset = 50, .rows = 25 },
    );
    try std.testing.expect(!p.animating);
    try std.testing.expectEqual(@as(f64, 50), p.shown);
}

test "smooth scroll: never further behind than what's remembered" {
    var p: Position = .{ .shown = 100 };
    var g: Geometry = .{ .total = 500, .offset = 100, .rows = 25 };
    for (0..5) |_| {
        var next = g;
        next.offset += 20;
        p.move(g, next);
        g = next;
        const target: f64 = @floatFromInt(g.offset);
        try std.testing.expect(@abs(target - p.shown) <= 25);
    }
}

test "smooth scroll: segments" {
    const a = segments(100, 250, 40);
    try std.testing.expectEqual(Segment{ .start = 50, .offset = 0, .len = 40 }, a[0]);
    try std.testing.expectEqual(@as(usize, 0), a[1].len);

    const b = segments(100, 190, 40);
    try std.testing.expectEqual(Segment{ .start = 90, .offset = 0, .len = 10 }, b[0]);
    try std.testing.expectEqual(Segment{ .start = 0, .offset = 10, .len = 30 }, b[1]);
}
