//! Finding the server of this machine, and starting it if it isn't running.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Pipe = @import("Pipe.zig");

const log = std.log.scoped(.rex);

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const HANDLE = *anyopaque;
const BOOL = c_int;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32 = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 1,
};
const STARTUPINFOW = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

const STARTF_USESTDHANDLES = 0x100;
const CREATE_NO_WINDOW = 0x08000000;
const HANDLE_FLAG_INHERIT = 1;
const INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY = 0x10;

extern "kernel32" fn CreatePipe(*?HANDLE, *?HANDLE, ?*const SECURITY_ATTRIBUTES, u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(HANDLE, u32, u32) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(HANDLE, ?[*]u8, u32, ?*u32, ?*u32, ?*u32) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(?[*:0]const u16, ?[*:0]u16, ?*anyopaque, ?*anyopaque, BOOL, u32, ?*anyopaque, ?[*:0]const u16, *STARTUPINFOW, *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(HANDLE, *u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, ?[*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;

pub const Error = error{
    /// There's no `rex` to start a server with.
    NotInstalled,
    /// It couldn't be started.
    StartFailed,
    /// It isn't on this machine.
    NotLocal,
    OutOfMemory,
};

const start_timeout_ms = 20_000;

/// The path of the pipe of the server. Blocks until it has started.
pub fn path(alloc: Allocator, buf: *[260:0]u16) Error![:0]const u16 {
    // Rex tells its own terminals which server they're of, and has commands
    // follow that. So do we, as long as it's on this machine.
    if (try environ(alloc, L("REX_SERVER"))) |wide| {
        defer alloc.free(wide);
        const endpoint = std.unicode.utf16LeToUtf8Alloc(alloc, wide) catch return error.NotLocal;
        defer alloc.free(endpoint);
        return Pipe.pathOf(buf, endpoint) catch error.NotLocal;
    }

    const exe = try find(alloc) orelse return error.NotInstalled;
    defer alloc.free(exe);
    var out: [4096]u8 = undefined;
    const text = try run(exe, &out);
    const endpoint = endpointOf(alloc, text) catch return error.StartFailed;
    defer alloc.free(endpoint);
    return Pipe.pathOf(buf, endpoint) catch error.NotLocal;
}

fn environ(alloc: Allocator, name: [*:0]const u16) Allocator.Error!?[:0]u16 {
    const len = GetEnvironmentVariableW(name, null, 0);
    if (len < 2) return null;
    const result = try alloc.allocSentinel(u16, len - 1, 0);
    errdefer alloc.free(result);
    if (GetEnvironmentVariableW(name, result.ptr, len) != len - 1) {
        alloc.free(result);
        return null;
    }
    return result;
}

/// Looks through the path, rather than having Windows do so, since that would
/// include the current directory.
fn find(alloc: Allocator) Allocator.Error!?[:0]u16 {
    if (try environ(alloc, L("PATH"))) |dirs| {
        defer alloc.free(dirs);
        var it = std.mem.splitScalar(u16, dirs, ';');
        while (it.next()) |entry| {
            const dir = std.mem.trim(u16, entry, &.{ '"', ' ' });
            if (!isAbsolute(dir)) continue;
            if (try candidate(alloc, dir, L("\\rex.exe"))) |v| return v;
        }
    }

    // It may have been installed after we were started.
    const local = try environ(alloc, L("LOCALAPPDATA")) orelse return null;
    defer alloc.free(local);
    if (!isAbsolute(local)) return null;
    return try candidate(alloc, local, L("\\Microsoft\\WinGet\\Links\\rex.exe"));
}

fn isAbsolute(dir: []const u16) bool {
    return dir.len >= 3 and dir[1] == ':' and (dir[2] == '\\' or dir[2] == '/');
}

fn candidate(alloc: Allocator, dir: []const u16, name: []const u16) Allocator.Error!?[:0]u16 {
    const full = try std.mem.concatWithSentinel(alloc, u16, &.{ dir, name }, 0);
    const attributes = GetFileAttributesW(full);
    if (attributes != INVALID_FILE_ATTRIBUTES and
        attributes & FILE_ATTRIBUTE_DIRECTORY == 0) return full;
    alloc.free(full);
    return null;
}

/// Run `rex server start`, which does nothing if it's running already. Returns
/// what it printed.
fn run(exe: [:0]const u16, out: []u8) Error![]const u8 {
    var read: ?HANDLE = null;
    var write: ?HANDLE = null;
    if (CreatePipe(&read, &write, &.{}, 64 * 1024) == 0) return error.StartFailed;
    defer _ = CloseHandle(read.?);
    _ = SetHandleInformation(read.?, HANDLE_FLAG_INHERIT, 0);

    var command = L("rex server start --json").*;
    var startup: STARTUPINFOW = .{ .dwFlags = STARTF_USESTDHANDLES, .hStdOutput = write };
    var process: PROCESS_INFORMATION = .{};
    const created = CreateProcessW(
        exe,
        &command,
        null,
        null,
        1,
        CREATE_NO_WINDOW,
        null,
        null,
        &startup,
        &process,
    );
    _ = CloseHandle(write.?);
    if (created == 0) return error.StartFailed;
    defer _ = CloseHandle(process.hProcess.?);
    defer _ = CloseHandle(process.hThread.?);

    if (WaitForSingleObject(process.hProcess.?, start_timeout_ms) != 0) {
        log.warn("the server took too long to start", .{});
        return error.StartFailed;
    }
    var code: u32 = 1;
    _ = GetExitCodeProcess(process.hProcess.?, &code);
    if (code != 0) {
        log.warn("the server couldn't be started code={}", .{code});
        return error.StartFailed;
    }

    // The server may have the other end, so there may be no end to wait for.
    var len: u32 = 0;
    if (PeekNamedPipe(read.?, out.ptr, @intCast(out.len), &len, null, null) == 0) return error.StartFailed;
    return out[0..len];
}

fn endpointOf(alloc: Allocator, text: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(struct { endpoint: []const u8 }, alloc, text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return try alloc.dupe(u8, parsed.value.endpoint);
}

test "rex: the endpoint of a server" {
    const alloc = std.testing.allocator;
    const v = try endpointOf(alloc,
        \\{"endpoint":"npipe:////./pipe/rex","pid":1,"tailscale":{"state":"disabled"}}
    );
    defer alloc.free(v);
    try std.testing.expectEqualStrings("npipe:////./pipe/rex", v);
    try std.testing.expectError(error.MissingField, endpointOf(alloc, "{\"pid\":1}"));
}

test "rex: only absolute directories are searched" {
    try std.testing.expect(isAbsolute(L("C:\\bin")));
    try std.testing.expect(!isAbsolute(L("bin")));
    try std.testing.expect(!isAbsolute(L(".")));
    try std.testing.expect(!isAbsolute(L("\\\\server\\share")));
}
