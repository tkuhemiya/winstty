//! The command palette of a window.
const CommandPalette = @This();

const Window = @import("Window.zig");
const c = @import("c.zig");

window: *Window,

pub fn register(_: c.HINSTANCE) !void {}

pub fn create(window: *Window) !*CommandPalette {
    const self = try window.app.core_app.alloc.create(CommandPalette);
    self.* = .{ .window = window };
    return self;
}

/// Called when the window is destroyed.
pub fn destroy(self: *CommandPalette) void {
    self.window.app.core_app.alloc.destroy(self);
}

pub fn toggle(_: *CommandPalette) void {}

/// Called when the window moved or changed size.
pub fn reposition(_: *CommandPalette) void {}
