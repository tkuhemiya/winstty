//! Native Win32 application runtime.

const internal_os = @import("../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    _ = App;
    _ = @import("../rex/main.zig");
    _ = Surface;
    _ = @import("win32/CommandPalette.zig");
    _ = @import("win32/Session.zig");
    _ = @import("win32/glass.zig");
    _ = @import("win32/layout.zig");
    _ = @import("win32/motion.zig");
    _ = @import("win32/themes.zig");
}
