//! Shows a terminal of a Rex server, which runs the program and has the
//! terminal that counts. Ours follows it: it starts out as a copy, and is given
//! everything that's written to it. The server also answers what programs ask
//! of their terminal, and decides on its size.
const Rex = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");
const renderer = @import("../renderer.zig");
const rex = @import("../rex/main.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_rex);

/// Told when the stream has ended, such as because the server has.
pub const Ended = struct {
    context: *anyopaque,

    /// Called from another thread.
    func: *const fn (*anyopaque) void,
};

/// What it takes to show a terminal. All of it is ours.
stream: *rex.Stream,
input: *rex.Client.Input,
ended: Ended,

cell: renderer.CellSize,
requested: ?struct { cols: u16, rows: u16, cell: renderer.CellSize } = null,
thread: ?std.Thread = null,
stopping: std.atomic.Value(bool) = .init(false),

/// The stream has ended.
finished: std.atomic.Value(bool) = .init(false),

pub const ThreadData = struct {};

pub fn init(stream: *rex.Stream, input: *rex.Client.Input, ended: Ended) Rex {
    return .{
        .stream = stream,
        .input = input,
        .ended = ended,
        .cell = .{ .width = 0, .height = 0 },
    };
}

pub fn deinit(self: *Rex) void {
    self.stream.destroy();
    self.input.unref();
}

/// Start from the terminal of the server. There's no one to have seen the one
/// there was.
pub fn initTerminal(self: *Rex, t: *terminal.Terminal) void {
    var value = self.stream.decoded.toOwned();
    const alloc = self.stream.alloc;

    // Colors are as configured here, except those that programs changed. The
    // server is told of them too.
    value.colors.background.default = t.colors.background.default;
    value.colors.foreground.default = t.colors.foreground.default;
    value.colors.cursor.default = t.colors.cursor.default;
    value.colors.palette.changeDefault(alloc, t.colors.palette.original.*) catch |err|
        log.warn("error changing the palette err={}", .{err});
    value.flags.dirty.palette = true;

    t.deinit(alloc);
    t.* = value;
}

pub fn threadEnter(
    self: *Rex,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // This isn't where we were made.
    const in_place = &io.backend.rex;
    std.debug.assert(in_place == self);
    self.thread = try .spawn(.{}, readMain, .{ self, io });
    td.backend = .{ .rex = .{} };
}

pub fn threadExit(self: *Rex, td: *termio.Termio.ThreadData) void {
    _ = td;
    self.stopping.store(true, .release);
    self.stream.cancel();
    if (self.thread) |v| v.join();
    self.thread = null;
}

fn readMain(self: *Rex, io: *termio.Termio) void {
    self.read(io) catch |err| {
        if (!self.stopping.load(.acquire)) log.info("a stream ended err={}", .{err});
    };
    self.finished.store(true, .release);
    if (!self.stopping.load(.acquire)) self.ended.func(self.ended.context);
}

fn read(self: *Rex, io: *termio.Termio) !void {
    const stream = self.stream;

    // A sequence that was only written in part when the snapshot was taken.
    switch (stream.decoded.continuation) {
        .ground => {},
        .bytes => |bytes| io.processOutput(bytes),
    }

    var sink: Sink = .{ .io = io };
    try stream.splitter.feed(stream.alloc, stream.leftover(), &sink);
    while (true) {
        const bytes = try stream.next();
        if (bytes.len == 0) return;
        try stream.splitter.feed(stream.alloc, bytes, &sink);
    }
}

const Sink = struct {
    io: *termio.Termio,

    pub fn output(self: *Sink, bytes: []const u8) void {
        self.io.processOutput(bytes);
    }

    pub fn message(self: *Sink, json: []const u8) void {
        const alloc = self.io.alloc;
        const parsed = std.json.parseFromSlice(rex.Stream.Message, alloc, json, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const v = parsed.value;

        // Colors are as configured here, and the rest are told by events.
        if (!std.mem.eql(u8, v.type, "resize")) return;
        const cols = v.cols orelse return;
        const rows = v.rows orelse return;
        if (cols == 0 or rows == 0) return;

        const io = self.io;
        io.renderer_state.mutex.lockUncancelable(global.io());
        defer io.renderer_state.mutex.unlock(global.io());
        io.terminal.resize(alloc, .{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{ .width = io.size.cell.width, .height = io.size.cell.height },
        }) catch |err| log.warn("error resizing err={}", .{err});
        io.renderer_wakeup.notify() catch {};
    }
};

/// Ask for a size. It's up to the server whether that's what we get.
pub fn resize(self: *Rex, grid: renderer.GridSize) !void {
    const request: @TypeOf(self.requested.?) = .{
        .cols = grid.columns,
        .rows = grid.rows,
        .cell = self.cell,
    };
    if (self.requested) |v| if (std.meta.eql(v, request)) return;
    self.requested = request;
    _ = self.input.client.callTerminal(self.input.session_id, self.input.block_id, "resize", .{
        .columns = grid.columns,
        .rows = grid.rows,
        .cell_width_px = if (self.cell.width > 0 and self.cell.height > 0) self.cell.width else null,
        .cell_height_px = if (self.cell.width > 0 and self.cell.height > 0) self.cell.height else null,
    }) catch |err| log.debug("error asking for a size err={}", .{err});
}

pub fn queueWrite(self: *Rex, alloc: Allocator, data: []const u8, linefeed: bool) !void {
    if (!linefeed) return self.input.write(data);
    const converted = try std.mem.replaceOwned(u8, alloc, data, "\r", "\r\n");
    defer alloc.free(converted);
    try self.input.write(converted);
}

pub fn clear(self: *Rex) bool {
    return self.call("clear");
}

pub fn reset(self: *Rex) bool {
    return self.call("reset");
}

fn call(self: *Rex, comptime method: []const u8) bool {
    _ = self.input.client.callTerminal(
        self.input.session_id,
        self.input.block_id,
        method,
        rex.Client.NoArgs{},
    ) catch |err| log.debug("error calling a terminal err={}", .{err});
    return true;
}
