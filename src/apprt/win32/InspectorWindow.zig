//! The inspector of a surface, in a window of its own.
const InspectorWindow = @This();

const Surface = @import("Surface.zig");
const c = @import("c.zig");

surface: *Surface,

pub fn register(_: c.HINSTANCE) !void {}

pub fn create(surface: *Surface) !*InspectorWindow {
    const self = try surface.app.core_app.alloc.create(InspectorWindow);
    self.* = .{ .surface = surface };
    return self;
}

/// Destroy now. Sets surface.inspector to null.
pub fn destroy(self: *InspectorWindow) void {
    self.surface.inspector = null;
    self.surface.app.core_app.alloc.destroy(self);
}

/// Destroy soon, from the message loop.
pub fn close(_: *InspectorWindow) void {}

pub fn queueRender(_: *InspectorWindow) void {}
