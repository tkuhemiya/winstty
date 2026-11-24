//! A connection to a named pipe. One thread may read while another writes.
const Pipe = @This();

const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;
const invalid: usize = std.math.maxInt(usize);

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?HANDLE,
};

const GENERIC_READ_WRITE = 0xC0000000;
const OPEN_EXISTING = 3;
const FILE_FLAG_OVERLAPPED = 0x40000000;
/// Let the server know who we are, which is how it decides to let us in, but
/// not act as us.
const SECURITY_SQOS_PRESENT_IDENTIFICATION = 0x00110000;
const ERROR_PIPE_BUSY = 231;
const ERROR_IO_PENDING = 997;

extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WaitNamedPipeW([*:0]const u16, u32) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(HANDLE, [*]u8, u32, ?*u32, *OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(HANDLE, [*]const u8, u32, ?*u32, *OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(HANDLE, *OVERLAPPED, *u32, BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn CancelIoEx(HANDLE, ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

handle: HANDLE,
read_event: HANDLE,
write_event: HANDLE,
canceled: std.atomic.Value(bool) = .init(false),

/// The pipes of this machine. A server on another machine isn't ours to use.
const local_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\");

pub fn open(path: [:0]const u16) !Pipe {
    if (!std.mem.startsWith(u16, path, local_prefix)) return error.NotLocal;

    const handle: HANDLE = handle: for (0..20) |_| {
        const result = CreateFileW(
            path,
            GENERIC_READ_WRITE,
            0,
            null,
            OPEN_EXISTING,
            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT_IDENTIFICATION,
            null,
        );
        if (result) |v| if (@intFromPtr(v) != invalid) break :handle v;
        if (GetLastError() != ERROR_PIPE_BUSY) return error.ConnectFailed;
        _ = WaitNamedPipeW(path, 100);
    } else return error.ConnectFailed;
    errdefer _ = CloseHandle(handle);

    const read_event = CreateEventW(null, 1, 0, null) orelse return error.ConnectFailed;
    errdefer _ = CloseHandle(read_event);
    const write_event = CreateEventW(null, 1, 0, null) orelse return error.ConnectFailed;
    return .{ .handle = handle, .read_event = read_event, .write_event = write_event };
}

/// Nothing may be using it.
pub fn close(self: *Pipe) void {
    _ = CloseHandle(self.handle);
    _ = CloseHandle(self.read_event);
    _ = CloseHandle(self.write_event);
    self.* = undefined;
}

/// Fail what's going on in other threads, and anything that's still to come.
pub fn cancel(self: *Pipe) void {
    self.canceled.store(true, .seq_cst);
    _ = CancelIoEx(self.handle, null);
}

/// Returns zero at the end.
pub fn read(self: *Pipe, buf: []u8) error{ReadFailed}!usize {
    var overlapped: OVERLAPPED = .{ .hEvent = self.read_event };
    const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
    if (ReadFile(self.handle, buf.ptr, len, null, &overlapped) == 0 and
        GetLastError() != ERROR_IO_PENDING) return error.ReadFailed;
    return self.finish(&overlapped) orelse error.ReadFailed;
}

/// Fails if the server doesn't take it in time.
pub fn writeAll(self: *Pipe, data: []const u8, timeout_ms: u32) error{WriteFailed}!void {
    var rest = data;
    while (rest.len > 0) {
        var overlapped: OVERLAPPED = .{ .hEvent = self.write_event };
        const len: u32 = @intCast(@min(rest.len, 1 << 20));
        if (WriteFile(self.handle, rest.ptr, len, null, &overlapped) == 0 and
            GetLastError() != ERROR_IO_PENDING) return error.WriteFailed;
        if (WaitForSingleObject(self.write_event, timeout_ms) != 0) _ = CancelIoEx(self.handle, &overlapped);
        const n = self.finish(&overlapped) orelse return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        rest = rest[n..];
    }
}

fn finish(self: *Pipe, overlapped: *OVERLAPPED) ?usize {
    // It may have been canceled before there was anything to cancel.
    if (self.canceled.load(.seq_cst)) _ = CancelIoEx(self.handle, overlapped);
    var n: u32 = 0;
    if (GetOverlappedResult(self.handle, overlapped, &n, 1) == 0) return null;
    return n;
}

/// The path of an endpoint as Rex writes it, such as `npipe:////./pipe/rex`.
/// Only for servers of this machine.
pub fn pathOf(buf: *[260:0]u16, endpoint: []const u8) ![:0]const u16 {
    const scheme = "npipe://";
    if (!std.mem.startsWith(u8, endpoint, scheme)) return error.NotLocal;
    const rest = endpoint[scheme.len..];
    if (rest.len >= buf.len) return error.NotLocal;
    var len = try std.unicode.utf8ToUtf16Le(buf, rest);
    for (buf[0..len]) |*v| if (v.* == '/') {
        v.* = '\\';
    };
    while (len > 0 and buf[len - 1] == 0) len -= 1;
    buf[len] = 0;
    const path = buf[0..len :0];
    if (!std.mem.startsWith(u16, path, local_prefix) or path.len == local_prefix.len) return error.NotLocal;
    return path;
}

test "rex: the path of an endpoint" {
    var buf: [260:0]u16 = undefined;
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\rex-server"),
        try pathOf(&buf, "npipe:////./pipe/rex-server"),
    );
}

test "rex: endpoints that aren't local" {
    var buf: [260:0]u16 = undefined;
    for ([_][]const u8{
        "",
        "http://localhost:7000",
        "tailnet://rex",
        "npipe:////other/pipe/rex",
        "npipe:////./pipe/",
        "npipe://",
        "unix:///tmp/rex.sock",
    }) |v| try std.testing.expectError(error.NotLocal, pathOf(&buf, v));
}
