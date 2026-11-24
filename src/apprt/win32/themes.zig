//! Finding themes, and choosing one.
const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const themepkg = @import("../../config/theme.zig");
const global = @import("../../global.zig");
const paint = @import("paint.zig");

const log = std.log.scoped(.win32);

/// Config files are small. This is to not read something that isn't one.
const max_file_size = 1024 * 1024;

pub const Theme = struct {
    name: []const u8,
    path: []const u8,

    fn lessThan(_: void, a: Theme, b: Theme) bool {
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }
};

/// All themes, sorted. Use an arena.
pub fn list(arena: Allocator) ![]const Theme {
    const io = global.io();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var result: std.ArrayList(Theme) = .empty;
    var it: themepkg.LocationIterator = .{ .arena_alloc = arena };
    while (try it.next()) |loc| {
        var dir = std.Io.Dir.cwd().openDir(io, loc.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var entries = dir.iterate();
        while (entries.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;

            // Locations are in order of priority, and names aren't case
            // sensitive on Windows.
            const key = try std.ascii.allocLowerString(arena, entry.name);
            if ((try seen.getOrPut(arena, key)).found_existing) continue;
            try result.append(arena, .{
                .name = try arena.dupe(u8, entry.name),
                .path = try std.fs.path.join(arena, &.{ loc.dir, entry.name }),
            });
        }
    }
    std.mem.sort(Theme, result.items, {}, Theme.lessThan);
    return result.items;
}

/// What a theme looks like, at a glance.
pub const Swatch = struct {
    background: paint.Rgb,
    foreground: paint.Rgb,
    /// Red, green, yellow, blue, magenta and cyan.
    colors: [6]paint.Rgb,

    pub fn read(alloc: Allocator, path: []const u8) ?Swatch {
        const content = readFile(alloc, path) catch return null;
        defer alloc.free(content);
        return parse(content);
    }

    /// Loading this as a config would do, but that takes a while, and lists
    /// have many themes.
    fn parse(content: []const u8) ?Swatch {
        var background: ?paint.Rgb = null;
        var foreground: ?paint.Rgb = null;
        var colors: [6]paint.Rgb = undefined;
        var found: usize = 0;
        var lines = std.mem.tokenizeAny(u8, content, "\r\n");
        while (lines.next()) |line| {
            const entry = splitLine(line) orelse continue;
            if (std.mem.eql(u8, entry.key, "background")) {
                background = parseColor(entry.value);
            } else if (std.mem.eql(u8, entry.key, "foreground")) {
                foreground = parseColor(entry.value);
            } else if (std.mem.eql(u8, entry.key, "palette")) {
                const eql = std.mem.indexOfScalar(u8, entry.value, '=') orelse continue;
                const index = std.fmt.parseInt(u8, entry.value[0..eql], 10) catch continue;
                if (index < 1 or index > 6) continue;
                colors[index - 1] = parseColor(entry.value[eql + 1 ..]) orelse continue;
                found += 1;
            }
        }
        if (found != colors.len) return null;
        return .{
            .background = background orelse return null,
            .foreground = foreground orelse return null,
            .colors = colors,
        };
    }
};

fn parseColor(value: []const u8) ?paint.Rgb {
    const hex = std.mem.trimStart(u8, std.mem.trim(u8, value, " \t\""), "#");
    if (hex.len != 6) return null;
    const v = std.fmt.parseInt(u24, hex, 16) catch return null;
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

const Entry = struct { key: []const u8, value: []const u8 };

/// Null for comments and anything else that isn't a setting.
fn splitLine(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eql = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    return .{
        .key = std.mem.trim(u8, trimmed[0..eql], " \t"),
        .value = std.mem.trim(u8, trimmed[eql + 1 ..], " \t"),
    };
}

/// Load the user's configuration, but with another theme. An empty name is no
/// theme at all.
pub fn loadConfig(alloc: Allocator, name: []const u8) !Config {
    const arg = try std.fmt.allocPrint(alloc, "--theme={s}", .{name});
    defer alloc.free(arg);

    // As Config.load does.
    var config = try Config.default(alloc);
    errdefer config.deinit();
    try config.loadDefaultFiles(alloc);
    try config.loadCliArgs(alloc);
    try config.loadRecursiveFiles(alloc);

    const args = [_][]const u8{arg};
    var iter = @import("../../cli.zig").args.sliceIterator(&args);
    try config.loadIter(alloc, &iter);
    try config.finalize();
    return config;
}

/// Make a theme the one in the user's configuration file. An empty name
/// removes it.
pub fn save(alloc: Allocator, name: []const u8) !void {
    const path = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(path);
    const old = readFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => try alloc.alloc(u8, 0),
        // Don't replace what couldn't be read.
        else => return err,
    };
    defer alloc.free(old);
    const new = try withTheme(alloc, old, name);
    defer alloc.free(new);
    if (std.mem.eql(u8, old, new)) return;

    const io = global.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(new);
    try writer.interface.flush();
    log.info("saved theme to config path={s}", .{path});
}

fn readFile(alloc: Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(global.io(), path, alloc, .limited(max_file_size));
}

/// Change the theme in the text of a configuration file, and nothing else.
fn withTheme(alloc: Allocator, content: []const u8, name: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    const newline = if (std.mem.indexOf(u8, content, "\r\n") != null) "\r\n" else "\n";
    var written = name.len == 0;
    var rest = content;
    while (rest.len > 0) {
        const end = if (std.mem.indexOfScalar(u8, rest, '\n')) |i| i + 1 else rest.len;
        const line = rest[0..end];
        rest = rest[end..];

        const entry = splitLine(std.mem.trimEnd(u8, line, "\n"));
        if (entry == null or !std.mem.eql(u8, entry.?.key, "theme")) {
            try result.appendSlice(alloc, line);
            continue;
        }

        // Replace the first and drop the others, the last one would win.
        if (written) continue;
        written = true;
        try result.print(alloc, "theme = {s}{s}", .{ name, newline });
    }

    if (!written) {
        if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
            try result.appendSlice(alloc, newline);
        }
        try result.print(alloc, "theme = {s}{s}", .{ name, newline });
    }
    return try result.toOwnedSlice(alloc);
}

fn expectWithTheme(expected: []const u8, content: []const u8, name: []const u8) !void {
    const actual = try withTheme(std.testing.allocator, content, name);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "themes: add to a config" {
    try expectWithTheme("theme = Nord\n", "", "Nord");
    try expectWithTheme("font-size = 12\ntheme = Nord\n", "font-size = 12\n", "Nord");
    try expectWithTheme("font-size = 12\ntheme = Nord\n", "font-size = 12", "Nord");
    try expectWithTheme("a = 1\r\ntheme = Nord\r\n", "a = 1\r\n", "Nord");
}

test "themes: replace in a config" {
    try expectWithTheme("a = 1\ntheme = Nord\nb = 2\n", "a = 1\ntheme = Dracula\nb = 2\n", "Nord");
    try expectWithTheme("theme = Nord\n", "theme=light:A,dark:B", "Nord");
    try expectWithTheme("theme = Nord\na = 1\n", "theme = A\na = 1\ntheme = B\n", "Nord");
}

test "themes: leaves everything else alone" {
    try expectWithTheme(
        "# theme = A\nwindow-theme = dark\ntheme = Nord\n",
        "# theme = A\nwindow-theme = dark\n",
        "Nord",
    );
}

test "themes: remove from a config" {
    try expectWithTheme("a = 1\nb = 2\n", "a = 1\ntheme = Nord\nb = 2\n", "");
    try expectWithTheme("a = 1\n", "a = 1\n", "");
}

test "themes: swatch" {
    const swatch = Swatch.parse(
        \\# comment
        \\palette = 0=#000000
        \\palette = 1=#010101
        \\palette = 2=#020202
        \\palette = 3=#030303
        \\palette = 4=#040404
        \\palette = 5=#050505
        \\palette = 6=#060606
        \\background = #282a36
        \\foreground = f8f8f2
    ).?;
    try std.testing.expectEqual(paint.Rgb{ .r = 0x28, .g = 0x2A, .b = 0x36 }, swatch.background);
    try std.testing.expectEqual(paint.Rgb{ .r = 0xF8, .g = 0xF8, .b = 0xF2 }, swatch.foreground);
    try std.testing.expectEqual(@as(u8, 6), swatch.colors[5].g);
    try std.testing.expect(Swatch.parse("background = #282a36") == null);
}
