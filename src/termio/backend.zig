const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const build_config = @import("../build_config.zig");

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec, rex };

/// Whether terminals of a Rex server can be shown.
pub const rex_enabled = build_config.app_runtime == .win32;
const Rex = if (rex_enabled) @import("Rex.zig") else NoRex;

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,

    /// Rex shows a terminal that's run by a server.
    rex: void,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    rex: Rex,

    /// Whether the terminal isn't ours, in which case it's someone else who
    /// decides on its size, and answers what programs ask of it.
    pub fn isRemote(self: *const Backend) bool {
        return self.* == .rex;
    }

    /// Called before a resize, with the size of a cell.
    pub fn setCell(self: *Backend, cell: renderer.CellSize) void {
        switch (self.*) {
            .exec => {},
            .rex => |*rex| rex.cell = cell,
        }
    }

    /// Whether the terminal was cleared by whoever has it.
    pub fn clear(self: *Backend) bool {
        return switch (self.*) {
            .exec => false,
            .rex => |*rex| rex.clear(),
        };
    }

    /// Whether the terminal was reset by whoever has it.
    pub fn reset(self: *Backend) bool {
        return switch (self.*) {
            .exec => false,
            .rex => |*rex| rex.reset(),
        };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .rex => |*rex| rex.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .rex => |*rex| rex.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .rex => |*rex| try rex.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .rex => |*rex| rex.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .rex => {},
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
            .rex => |*rex| try rex.resize(grid_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .rex => |*rex| try rex.queueWrite(alloc, data, linefeed),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .rex => {},
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .rex => null,
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    rex: Rex.ThreadData,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .rex => {},
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};

/// Where there's no Rex.
const NoRex = struct {
    cell: renderer.CellSize = undefined,
    pub const ThreadData = struct {};
    pub fn deinit(_: *NoRex) void {}
    pub fn initTerminal(_: *NoRex, _: *terminal.Terminal) void {}
    pub fn threadEnter(_: *NoRex, _: Allocator, _: *termio.Termio, _: *termio.Termio.ThreadData) !void {}
    pub fn threadExit(_: *NoRex, _: *termio.Termio.ThreadData) void {}
    pub fn resize(_: *NoRex, _: renderer.GridSize) !void {}
    pub fn queueWrite(_: *NoRex, _: Allocator, _: []const u8, _: bool) !void {}
    pub fn clear(_: *NoRex) bool {
        return false;
    }
    pub fn reset(_: *NoRex) bool {
        return false;
    }
};
