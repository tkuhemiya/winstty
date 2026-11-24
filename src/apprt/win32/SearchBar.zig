//! The search popup of a surface.
const SearchBar = @This();

const Surface = @import("Surface.zig");
const c = @import("c.zig");

surface: *Surface,

pub fn register(_: c.HINSTANCE) !void {}

pub fn create(surface: *Surface) !*SearchBar {
    const self = try surface.app.core_app.alloc.create(SearchBar);
    self.* = .{ .surface = surface };
    return self;
}

/// Called when the surface is destroyed.
pub fn destroy(self: *SearchBar) void {
    self.surface.app.core_app.alloc.destroy(self);
}

pub fn show(_: *SearchBar, _: [:0]const u8) void {}
pub fn hide(_: *SearchBar) void {}
pub fn setTotal(_: *SearchBar, _: ?usize) void {}
pub fn setSelected(_: *SearchBar, _: ?usize) void {}

/// Called when the surface or window moved, or changed size or visibility.
pub fn reposition(_: *SearchBar) void {}
