//! How things move.
const std = @import("std");
const Config = @import("../../config.zig").Config;

pub const Style = @FieldType(Config, "win32-animation");

/// A value on its way to another one. It can be given a new target at any time,
/// and carries on from where it is and how fast it's going.
pub const Spring = struct {
    value: f32,
    target: f32,
    velocity: f32 = 0,

    /// Closer than this, and slower than this per frame or so, is there.
    const precision = 0.0004;

    pub fn at(value: f32) Spring {
        return .{ .value = value, .target = value };
    }

    pub fn moving(self: *const Spring) bool {
        return self.value != self.target or self.velocity != 0;
    }

    /// Be there.
    pub fn finish(self: *Spring) void {
        self.* = .at(self.target);
    }

    pub fn step(self: *Spring, style: Style, elapsed: f32) void {
        if (!self.moving()) return;

        // The frequency, and the damping as a part of what's critical.
        const frequency: f32, const damping: f32 = switch (style) {
            .natural => .{ 21, 0.68 },
            .snappy => .{ 30, 1 },
            .off => return self.finish(),
        };

        const side = self.value < self.target;
        var left = elapsed;
        while (left > 0) {
            const dt = @min(left, 0.001);
            left -= dt;
            const force = (self.target - self.value) * frequency * frequency -
                self.velocity * 2 * damping * frequency;
            self.velocity += force * dt;
            self.value += self.velocity * dt;

            // It may have been given a push, but still shouldn't go past.
            if (style == .snappy and side != (self.value < self.target)) return self.finish();
        }
        if (@abs(self.target - self.value) < precision and
            @abs(self.velocity) < precision * 60) self.finish();
    }
};

fn run(spring: *Spring, style: Style) struct { frames: usize, min: f32, max: f32 } {
    var frames: usize = 0;
    var min = spring.value;
    var max = spring.value;
    while (spring.moving() and frames < 1000) : (frames += 1) {
        spring.step(style, 1.0 / 60.0);
        min = @min(min, spring.value);
        max = @max(max, spring.value);
    }
    return .{ .frames = frames, .min = min, .max = max };
}

test "motion: natural overshoots a little, once, and settles" {
    var spring: Spring = .{ .value = 0, .target = 1 };
    var peak: f32 = 0;
    var after: f32 = 1;
    var frames: usize = 0;
    while (spring.moving()) : (frames += 1) {
        spring.step(.natural, 1.0 / 60.0);
        peak = @max(peak, spring.value);
        if (peak > 1.01 and spring.value < peak) after = @min(after, spring.value);
        try std.testing.expect(frames < 60);
    }
    try std.testing.expect(peak > 1.02 and peak < 1.1);
    try std.testing.expect(after > 0.99);
    try std.testing.expectEqual(@as(f32, 1), spring.value);
}

test "motion: snappy doesn't overshoot" {
    var spring: Spring = .{ .value = 1, .target = 0.5 };
    const result = run(&spring, .snappy);
    try std.testing.expect(result.min >= 0.5);
    try std.testing.expect(result.frames > 3 and result.frames < 40);

    // Not even when it's already moving fast.
    spring = .{ .value = 0, .target = 1, .velocity = 100 };
    try std.testing.expect(run(&spring, .snappy).max <= 1);
}

test "motion: off is there at once" {
    var spring: Spring = .{ .value = 0, .target = 1, .velocity = 3 };
    spring.step(.off, 0.001);
    try std.testing.expect(!spring.moving());
    try std.testing.expectEqual(@as(f32, 1), spring.value);
}

test "motion: a new target doesn't disturb the value or velocity" {
    var spring: Spring = .{ .value = 0, .target = 1 };
    for (0..5) |_| spring.step(.natural, 1.0 / 60.0);
    const before = spring;
    spring.target = 0.2;
    try std.testing.expectEqual(before.value, spring.value);
    try std.testing.expectEqual(before.velocity, spring.velocity);
    _ = run(&spring, .natural);
    try std.testing.expectEqual(@as(f32, 0.2), spring.value);
}

test "motion: doesn't depend on the frame rate" {
    var a: Spring = .{ .value = 0, .target = 1 };
    var b: Spring = .{ .value = 0, .target = 1 };
    for (0..6) |_| a.step(.natural, 1.0 / 60.0);
    for (0..12) |_| b.step(.natural, 1.0 / 120.0);
    try std.testing.expectApproxEqAbs(a.value, b.value, 0.01);
}
