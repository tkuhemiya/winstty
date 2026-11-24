//! GDI painting helpers and the colors of our own (non-terminal) UI.
const std = @import("std");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const c = @import("c.zig");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn from(color: Config.Color) Rgb {
        return .{ .r = color.r, .g = color.g, .b = color.b };
    }

    pub fn ref(self: Rgb) c.COLORREF {
        return @as(u32, self.r) | @as(u32, self.g) << 8 | @as(u32, self.b) << 16;
    }

    /// Mix in an amount (0 to 255) of another color.
    pub fn mix(self: Rgb, other: Rgb, amount: u8) Rgb {
        const f = struct {
            fn f(a: u8, b: u8, t: u32) u8 {
                return @intCast((@as(u32, a) * (255 - t) + @as(u32, b) * t) / 255);
            }
        }.f;
        return .{
            .r = f(self.r, other.r, amount),
            .g = f(self.g, other.g, amount),
            .b = f(self.b, other.b, amount),
        };
    }

    pub fn isDark(self: Rgb) bool {
        return @as(u32, self.r) * 299 + @as(u32, self.g) * 587 + @as(u32, self.b) * 114 < 128 * 1000;
    }
};

/// UI colors, derived from the terminal's so that any theme looks coherent.
pub const Palette = struct {
    bg: Rgb,
    fg: Rgb,
    /// Background of bars and popups.
    bar: Rgb,
    /// Background of a hovered item.
    hover: Rgb,
    /// Background of a selected item.
    selected: Rgb,
    /// Text of inactive items.
    dim: Rgb,
    divider: Rgb,
    /// What the cards of splits are on.
    backdrop: Rgb,
    /// Marks what has the focus.
    accent: Rgb,

    pub fn init(config: *const Config) Palette {
        const bg: Rgb = bg: {
            if (config.@"win32-glass") switch (config.@"win32-glass-tint") {
                .theme => {},
                .color => |v| break :bg .from(v),
            };
            break :bg .from(config.background);
        };
        const fg: Rgb = .from(config.foreground);
        return .{
            .bg = bg,
            .fg = fg,
            .bar = bg.mix(fg, if (bg.isDark()) 24 else 10),
            .hover = bg.mix(fg, 25),
            .selected = bg.mix(fg, 45),
            .dim = fg.mix(bg, 100),
            // Darker, unless there's hardly any darker to go.
            .backdrop = if (!bg.isDark())
                bg.mix(fg, 22)
            else if (@max(bg.r, @max(bg.g, bg.b)) < 16)
                bg.mix(fg, 16)
            else
                bg.mix(.{ .r = 0, .g = 0, .b = 0 }, 120),
            .accent = accent: {
                // The blue of the theme.
                const v = config.palette.value[if (bg.isDark()) 12 else 4];
                break :accent .{ .r = v.r, .g = v.g, .b = v.b };
            },
            .divider = if (config.@"split-divider-color") |v| .from(v) else bg.mix(fg, 50),
        };
    }
};

/// Scale a 96 DPI length.
pub fn scale(v: c_int, dpi: u32) c_int {
    return @divTrunc(v * @as(c_int, @intCast(dpi)), 96);
}

/// Glyphs of the icon font.
pub const icon = struct {
    pub const add = "\u{E710}";
    pub const cancel = "\u{E711}";
    pub const up = "\u{E70E}";
    pub const down = "\u{E70D}";
};

/// The caller owns the font.
pub fn iconFont(points: c_int, dpi: u32) ?c.HFONT {
    return font(c.L("Segoe Fluent Icons"), points, 400, dpi);
}

/// Grayscale antialiased, for `Buffer.blendText`. The caller owns the font.
pub fn font(family: [*:0]const u16, points: c_int, weight: c_int, dpi: u32) ?c.HFONT {
    return c.CreateFontW(
        -@divTrunc(points * @as(c_int, @intCast(dpi)), 72),
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        1, // DEFAULT_CHARSET
        0,
        0,
        4, // ANTIALIASED_QUALITY
        0,
        family,
    );
}

/// Labels are one line and ellipsized, so a long one can be cut short.
fn toWide(wide: *[512]u16, utf8: []const u8) usize {
    var end = @min(utf8.len, wide.len);
    while (end > 0 and end < utf8.len and utf8[end] & 0xC0 == 0x80) end -= 1;
    return std.unicode.wtf8ToWtf16Le(wide, utf8[0..end]) catch 0;
}

/// The width of a label that isn't ellipsized.
pub fn textWidth(dc: c.HDC, utf8: []const u8, with: ?c.HFONT) c_int {
    var wide: [512]u16 = undefined;
    const len = toWide(&wide, utf8);
    if (len == 0) return 0;
    const old = if (with) |v| c.SelectObject(dc, v) else null;
    defer if (old) |v| {
        _ = c.SelectObject(dc, v);
    };
    var r: c.RECT = .{};
    _ = c.DrawTextW(dc, &wide, @intCast(len), &r, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
    return r.right;
}

/// A rectangle for antialiased shapes.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn from(r: c.RECT) Rect {
        return .{
            .x = @floatFromInt(r.left),
            .y = @floatFromInt(r.top),
            .w = @floatFromInt(r.right - r.left),
            .h = @floatFromInt(r.bottom - r.top),
        };
    }

    /// Part of the way to another one.
    pub fn toward(self: Rect, other: Rect, t: f32) Rect {
        return .{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
            .w = @max(0, self.w + (other.w - self.w) * t),
            .h = @max(0, self.h + (other.h - self.h) * t),
        };
    }

    pub fn inset(self: Rect, v: f32) Rect {
        return .{ .x = self.x + v, .y = self.y + v, .w = self.w - v * 2, .h = self.h - v * 2 };
    }
};

/// The caller owns the font.
pub fn uiFont(points: c_int, dpi: u32) ?c.HFONT {
    return c.CreateFontW(
        -@divTrunc(points * @as(c_int, @intCast(dpi)), 72),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        1, // DEFAULT_CHARSET
        0,
        0,
        5, // CLEARTYPE_QUALITY
        0,
        c.L("Segoe UI Variable Text"),
    );
}

/// What a window looks like. Parts of it are drawn to this, and it's shown all
/// at once, as each time something is shown waits for the compositor.
pub const Back = struct {
    dc: c.HDC,
    bitmap: c.HBITMAP,
    previous: ?c.HGDIOBJ,
    width: c_int,
    height: c_int,

    pub fn init(target: c.HDC, width: c_int, height: c_int) ?Back {
        if (width <= 0 or height <= 0) return null;
        const dc = c.CreateCompatibleDC(target) orelse return null;
        var bits: ?*anyopaque = null;
        const bitmap = c.CreateDIBSection(dc, &.{
            // Negative is top-down.
            .bmiHeader = .{ .biWidth = width, .biHeight = -height },
        }, 0, &bits, null, 0) orelse {
            _ = c.DeleteDC(dc);
            return null;
        };
        return .{
            .dc = dc,
            .bitmap = bitmap,
            .previous = c.SelectObject(dc, bitmap),
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: Back) void {
        if (self.previous) |v| _ = c.SelectObject(self.dc, v);
        _ = c.DeleteObject(self.bitmap);
        _ = c.DeleteDC(self.dc);
    }

    pub fn show(self: Back, target: c.HDC, rect: c.RECT) void {
        _ = c.BitBlt(
            target,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            self.dc,
            rect.left,
            rect.top,
            c.SRCCOPY,
        );
    }
};

/// An offscreen buffer for flicker-free painting.
///
/// GDI writes zeroes to the alpha channel, and the window may be composited
/// with per-pixel alpha, so the buffer is made opaque before it's shown.
pub const Buffer = struct {
    target: c.HDC,
    rect: c.RECT,
    dc: c.HDC,
    bitmap: c.HBITMAP,
    previous: ?c.HGDIOBJ,
    pixels: []u32,

    width: usize,

    /// Less than 255 shows what's behind a window with per-pixel alpha.
    opacity: u8 = 255,

    /// The pixels have an alpha channel, so they're shown as they are. Set by
    /// `base`.
    has_alpha: bool = false,
    base_opacity: u8 = 255,

    /// Coordinates drawn to `dc` are relative to the rect's origin.
    pub fn begin(target: c.HDC, rect: c.RECT) ?Buffer {
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width <= 0 or height <= 0) return null;

        const dc = c.CreateCompatibleDC(target) orelse return null;
        var bits: ?*anyopaque = null;
        const bitmap = c.CreateDIBSection(dc, &.{
            // Negative is top-down.
            .bmiHeader = .{ .biWidth = width, .biHeight = -height },
        }, 0, &bits, null, 0) orelse {
            _ = c.DeleteDC(dc);
            return null;
        };
        const ptr: [*]u32 = @ptrCast(@alignCast(bits.?));
        return .{
            .target = target,
            .rect = rect,
            .dc = dc,
            .bitmap = bitmap,
            .previous = c.SelectObject(dc, bitmap),
            .pixels = ptr[0..@intCast(width * height)],
            .width = @intCast(width),
        };
    }

    pub fn end(self: Buffer) void {
        _ = c.GdiFlush();
        if (self.has_alpha) {
            // Nothing to do.
        } else if (self.opacity == 255) {
            for (self.pixels) |*pixel| pixel.* |= 0xFF000000;
        } else {
            const table = premultiplied(self.opacity);
            for (self.pixels) |*pixel| {
                const p = pixel.*;
                pixel.* = @as(u32, self.opacity) << 24 |
                    @as(u32, table[(p >> 16) & 0xFF]) << 16 |
                    @as(u32, table[(p >> 8) & 0xFF]) << 8 |
                    table[p & 0xFF];
            }
        }
        _ = c.BitBlt(
            self.target,
            self.rect.left,
            self.rect.top,
            self.rect.right - self.rect.left,
            self.rect.bottom - self.rect.top,
            self.dc,
            0,
            0,
            c.SRCCOPY,
        );
        self.discard();
    }

    /// Free without showing.
    pub fn discard(self: Buffer) void {
        if (self.previous) |v| _ = c.SelectObject(self.dc, v);
        _ = c.DeleteObject(self.bitmap);
        _ = c.DeleteDC(self.dc);
    }

    /// Premultiplies in linear space, as the terminal's renderer does, so that
    /// the same color next to it looks the same.
    fn premultiplied(opacity: u8) [256]u8 {
        // Painting is all done by one thread, and there are only a few.
        const cache = struct {
            var tables: [4][256]u8 = undefined;
            var opacities: [4]?u8 = @splat(null);
            var next: usize = 0;
        };
        for (cache.opacities, 0..) |v, i| if (v != null and v.? == opacity) return cache.tables[i];
        const table = computePremultiplied(opacity);
        cache.tables[cache.next] = table;
        cache.opacities[cache.next] = opacity;
        cache.next = (cache.next + 1) % cache.tables.len;
        return table;
    }

    fn computePremultiplied(opacity: u8) [256]u8 {
        const alpha = @as(f32, @floatFromInt(opacity)) / 255;
        var table: [256]u8 = undefined;
        for (&table, 0..) |*v, i| {
            const srgb = @as(f32, @floatFromInt(i)) / 255;
            const linear = alpha * if (srgb <= 0.04045)
                srgb / 12.92
            else
                std.math.pow(f32, (srgb + 0.055) / 1.055, 2.4);
            const encoded = if (linear <= 0.0031308)
                linear * 12.92
            else
                1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
            v.* = @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
        }
        return table;
    }

    /// Fill everything with a color that may be translucent, and start
    /// keeping track of alpha.
    pub fn base(self: *Buffer, color: Rgb, opacity: u8) void {
        self.has_alpha = true;
        self.base_opacity = opacity;
        const table = premultiplied(opacity);
        const pixel = @as(u32, opacity) << 24 |
            @as(u32, table[color.r]) << 16 |
            @as(u32, table[color.g]) << 8 |
            table[color.b];
        @memset(self.pixels, pixel);
    }

    /// Replace what's in a rectangle with a color that may be translucent.
    /// Only for buffers with a base.
    pub fn replace(self: Buffer, rect: c.RECT, color: Rgb, opacity: u8) void {
        const table = premultiplied(opacity);
        const pixel = @as(u32, opacity) << 24 |
            @as(u32, table[color.r]) << 16 |
            @as(u32, table[color.g]) << 8 |
            table[color.b];
        const width: c_int = @intCast(self.width);
        const height: c_int = @intCast(self.pixels.len / self.width);
        const x0: usize = @intCast(std.math.clamp(rect.left, 0, width));
        const x1: usize = @intCast(std.math.clamp(rect.right, 0, width));
        if (x0 >= x1) return;
        var y = std.math.clamp(rect.top, 0, height);
        while (y < @min(rect.bottom, height)) : (y += 1) {
            const row = @as(usize, @intCast(y)) * self.width;
            @memset(self.pixels[row + x0 .. row + x1], pixel);
        }
    }

    fn blend(self: Buffer, index: usize, color: Rgb, alpha: f32) void {
        if (alpha <= 0) return;
        const a: u32 = @intFromFloat(@min(alpha, 1) * 255 + 0.5);
        const inv = 255 - a;
        const d = self.pixels[index];
        const r = (color.r * a + ((d >> 16) & 0xFF) * inv) / 255;
        const g = (color.g * a + ((d >> 8) & 0xFF) * inv) / 255;
        const b = (color.b * a + (d & 0xFF) * inv) / 255;
        // GDI leaves zero alpha, which `end` fixes if it isn't kept track of.
        const da = if (self.has_alpha) d >> 24 else 255;
        const out: u32 = @min(255, a + da * inv / 255);
        self.pixels[index] = out << 24 | r << 16 | g << 8 | b;
    }

    /// Distance outside (positive) of a rounded rectangle.
    fn distance(r: Rect, radius: f32, px: f32, py: f32) f32 {
        const qx = @abs(px - (r.x + r.w / 2)) - r.w / 2 + radius;
        const qy = @abs(py - (r.y + r.h / 2)) - r.h / 2 + radius;
        const ox = @max(qx, 0);
        const oy = @max(qy, 0);
        return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - radius;
    }

    const Bounds = struct { x0: usize, y0: usize, x1: usize, y1: usize };

    fn bounds(self: Buffer, r: Rect) Bounds {
        const height = self.pixels.len / self.width;
        const f = struct {
            fn f(v: f32, max: usize) usize {
                return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(max))));
            }
        }.f;
        return .{
            .x0 = f(@floor(r.x - 1), self.width),
            .y0 = f(@floor(r.y - 1), height),
            .x1 = f(@ceil(r.x + r.w + 1), self.width),
            .y1 = f(@ceil(r.y + r.h + 1), height),
        };
    }

    /// An antialiased rounded rectangle.
    pub fn round(self: Buffer, r: Rect, radius: f32, color: Rgb, alpha: f32) void {
        if (r.w <= 0 or r.h <= 0) return;
        if (!self.has_alpha) _ = c.GdiFlush();
        const limited = @min(radius, @min(r.w, r.h) / 2);
        const b = self.bounds(r);
        for (b.y0..b.y1) |y| for (b.x0..b.x1) |x| {
            const d = distance(r, limited, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            self.blend(y * self.width + x, color, alpha * std.math.clamp(0.5 - d, 0, 1));
        };
    }

    /// An antialiased rounded rectangle that replaces what's there, rather than
    /// covering it. What's there may be more or less translucent.
    pub fn replaceRound(self: Buffer, r: Rect, radius: f32, color: Rgb, opacity: u8) void {
        if (r.w <= 0 or r.h <= 0) return;
        const table = premultiplied(opacity);
        const target = [4]u32{ table[color.b], table[color.g], table[color.r], opacity };
        const limited = @min(radius, @min(r.w, r.h) / 2);
        const b = self.bounds(r);
        const solid = target[3] << 24 | target[2] << 16 | target[1] << 8 | target[0];
        for (b.y0..b.y1) |y| {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const x0, const x1 = insideOf(r, limited, py, b);
            for (b.x0..x0) |x| self.replacePixel(r, limited, target, x, y, py);
            if (x1 > x0) @memset(self.pixels[y * self.width + x0 .. y * self.width + x1], solid);
            for (x1..b.x1) |x| self.replacePixel(r, limited, target, x, y, py);
        }
    }

    fn replacePixel(self: Buffer, r: Rect, radius: f32, target: [4]u32, x: usize, y: usize, py: f32) void {
        const d = distance(r, radius, @as(f32, @floatFromInt(x)) + 0.5, py);
        const t: u32 = @intFromFloat(std.math.clamp(0.5 - d, 0, 1) * 255);
        if (t == 0) return;
        const pixel = &self.pixels[y * self.width + x];
        var out: u32 = 0;
        for (target, 0..) |v, i| {
            const shift: u5 = @intCast(i * 8);
            const old = (pixel.* >> shift) & 0xFF;
            out |= ((old * (255 - t) + v * t) / 255) << shift;
        }
        pixel.* = out;
    }

    /// The part of a row of pixels that's surely all inside of a rounded
    /// rectangle: all of it between the corners, and what's between them
    /// otherwise.
    fn insideOf(r: Rect, radius: f32, py: f32, b: Bounds) struct { usize, usize } {
        if (py < r.y + 1 or py > r.y + r.h - 1) return .{ b.x1, b.x1 };
        const edge = if (py > r.y + radius and py < r.y + r.h - radius) 1 else radius + 1;
        const lo: f32 = @floatFromInt(b.x0);
        const hi: f32 = @floatFromInt(b.x1);
        const x0 = std.math.clamp(@ceil(r.x + edge), lo, hi);
        const x1 = std.math.clamp(@floor(r.x + r.w - edge), lo, hi);
        if (x1 <= x0) return .{ b.x1, b.x1 };
        return .{ @intFromFloat(x0), @intFromFloat(x1) };
    }

    /// A solid line along the inside of a rounded rectangle.
    pub fn outline(self: Buffer, r: Rect, radius: f32, thickness: f32, color: Rgb) void {
        if (r.w <= 0 or r.h <= 0) return;
        const limited = @min(radius, @min(r.w, r.h) / 2);
        const margin = limited + thickness + 2;
        const b = self.bounds(r);
        const lo: f32 = @floatFromInt(b.x0);
        const hi: f32 = @floatFromInt(b.x1);
        const left = std.math.clamp(@ceil(r.x + margin), lo, hi);
        const right = std.math.clamp(@floor(r.x + r.w - margin), left, hi);
        for (b.y0..b.y1) |y| {
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            // Between the corners it's the same all along a row, and none at
            // all unless that's near the top or the bottom.
            const along = if (py > r.y + margin and py < r.y + r.h - margin)
                0
            else
                ringOf(distance(r, limited, r.x + r.w / 2, py), thickness);
            const x0: usize = @intFromFloat(left);
            const x1: usize = @intFromFloat(right);
            for (b.x0..x0) |x| self.outlinePixel(r, limited, thickness, color, x, y, py);
            if (along > 0) for (x0..x1) |x| self.blend(y * self.width + x, color, along);
            for (x1..b.x1) |x| self.outlinePixel(r, limited, thickness, color, x, y, py);
        }
    }

    fn outlinePixel(self: Buffer, r: Rect, radius: f32, thickness: f32, color: Rgb, x: usize, y: usize, py: f32) void {
        const d = distance(r, radius, @as(f32, @floatFromInt(x)) + 0.5, py);
        self.blend(y * self.width + x, color, ringOf(d, thickness));
    }

    /// How much of a pixel is in a line along the inside of an edge.
    fn ringOf(d: f32, thickness: f32) f32 {
        return std.math.clamp(0.5 - d, 0, 1) - std.math.clamp(0.5 - (d + thickness), 0, 1);
    }

    /// Light that's caught by the upper edge of a rounded rectangle. It's the
    /// strongest in the middle.
    pub fn highlight(self: Buffer, r: Rect, radius: f32, thickness: f32, color: Rgb, alpha: f32) void {
        if (r.w <= 0 or r.h <= 0) return;
        const limited = @min(radius, @min(r.w, r.h) / 2);
        var top = r;
        top.h = @min(r.h, @max(limited, thickness));
        const b = self.bounds(top);
        for (b.y0..b.y1) |y| for (b.x0..b.x1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = distance(r, limited, px, py);
            const edge = std.math.clamp(0.5 - d, 0, 1) -
                std.math.clamp(0.5 - (d + thickness), 0, 1);
            if (edge <= 0) continue;
            const across = std.math.clamp(@abs(px - (r.x + r.w / 2)) / (r.w / 2), 0, 1);
            const down = std.math.clamp((py - r.y) / top.h, 0, 1);
            self.blend(
                y * self.width + x,
                color,
                alpha * edge * (1 - across * across) * (1 - down),
            );
        };
    }

    /// An antialiased outline inside a rounded rectangle, with a different
    /// alpha at the top and the bottom.
    pub fn ring(self: Buffer, r: Rect, radius: f32, color: Rgb, top: f32, bottom: f32) void {
        if (r.w <= 0 or r.h <= 0) return;
        if (!self.has_alpha) _ = c.GdiFlush();
        const limited = @min(radius, @min(r.w, r.h) / 2);
        const b = self.bounds(r);
        for (b.y0..b.y1) |y| {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const t = std.math.clamp((py - r.y) / r.h, 0, 1);
            const alpha = top + (bottom - top) * t;
            for (b.x0..b.x1) |x| {
                const d = distance(r, limited, @as(f32, @floatFromInt(x)) + 0.5, py);
                const outer = std.math.clamp(0.5 - d, 0, 1);
                const inner = std.math.clamp(0.5 - (d + 1), 0, 1);
                self.blend(y * self.width + x, color, alpha * (outer - inner));
            }
        }
    }

    /// An antialiased line with round ends.
    pub fn stroke(self: Buffer, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: Rgb, alpha: f32) void {
        const half = thickness / 2;
        const b = self.bounds(.{
            .x = @min(x0, x1) - half,
            .y = @min(y0, y1) - half,
            .w = @abs(x1 - x0) + thickness,
            .h = @abs(y1 - y0) + thickness,
        });
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = @max(0.0001, dx * dx + dy * dy);
        for (b.y0..b.y1) |y| for (b.x0..b.x1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - x0;
            const py = @as(f32, @floatFromInt(y)) + 0.5 - y0;
            const t = std.math.clamp((px * dx + py * dy) / len2, 0, 1);
            const ex = px - t * dx;
            const ey = py - t * dy;
            const d = @sqrt(ex * ex + ey * ey) - half;
            self.blend(y * self.width + x, color, alpha * std.math.clamp(0.5 - d, 0, 1));
        };
    }

    /// A pane of glass: lighter than what it's on, with light catching its
    /// upper edge.
    pub fn glass(self: Buffer, r: Rect, radius: f32, tint: Rgb, strength: f32) void {
        self.round(r, radius, tint, strength);
        self.ring(r, radius, tint, strength * 1.6, strength * 0.5);
    }

    /// What a program is doing, in a square.
    pub fn statusMark(
        self: Buffer,
        rect: c.RECT,
        mark: Mark,
        fg: Rgb,
        bg: Rgb,
        alpha: f32,
    ) void {
        const square: Rect = .from(rect);
        const size = @min(square.w, square.h) * 0.72;
        const r: Rect = .{
            .x = square.x + (square.w - size) / 2,
            .y = square.y + (square.h - size) / 2,
            .w = size,
            .h = size,
        };
        const cx = r.x + size / 2;
        const cy = r.y + size / 2;
        const line = @max(1.3, size * 0.12);
        const arm = size * 0.2;
        switch (mark) {
            .none => {},

            // Dots in a circle, some of which are brighter.
            .working => |v| for (0..mark_dots) |i| {
                const turn = @as(f32, @floatFromInt(i)) / mark_dots * std.math.tau - std.math.tau / 4.0;
                const dot = size * 0.17;
                const strength: f32 = if (v.progress) |p|
                    if (i * 100 < @as(usize, p) * mark_dots) 1 else 0.25
                else if (v.spinner) |s|
                    0.2 + 0.8 * @as(f32, @floatFromInt((i + mark_dots - s % mark_dots) % mark_dots)) / mark_dots
                else
                    0.6;
                self.round(.{
                    .x = cx + @cos(turn) * size * 0.38 - dot / 2,
                    .y = cy + @sin(turn) * size * 0.38 - dot / 2,
                    .w = dot,
                    .h = dot,
                }, dot / 2, fg, alpha * strength);
            },

            .blocked => {
                self.round(r, size / 2, .{ .r = 0xF2, .g = 0xA3, .b = 0x1B }, alpha);
                self.stroke(cx, cy - arm * 1.2, cx, cy + arm * 0.25, line, bg, alpha);
                self.stroke(cx, cy + arm * 1.2, cx, cy + arm * 1.2, line, bg, alpha);
            },

            .done => {
                const green: Rgb = .{ .r = 0x35, .g = 0xB5, .b = 0x58 };
                self.round(r, size / 2, green, alpha * 0.22);
                self.ring(r, size / 2, green, alpha, alpha);
                self.stroke(cx - arm, cy, cx - arm * 0.2, cy + arm * 0.8, line, green, alpha);
                self.stroke(cx - arm * 0.2, cy + arm * 0.8, cx + arm * 1.1, cy - arm * 0.8, line, green, alpha);
            },

            .@"error" => {
                self.round(r, size / 2, .{ .r = 0xE5, .g = 0x48, .b = 0x4D }, alpha);
                self.stroke(cx - arm, cy - arm, cx + arm, cy + arm, line, bg, alpha);
                self.stroke(cx - arm, cy + arm, cx + arm, cy - arm, line, bg, alpha);
            },
        }
    }

    pub const mark_dots = 8;

    pub const Mark = union(enum) {
        none,
        /// The spinner is how far it has turned, if it does.
        working: struct { progress: ?u8, spinner: ?u8 },
        blocked,
        done,
        @"error",
    };

    /// Text that may be on something translucent.
    pub fn blendText(
        self: Buffer,
        utf8: []const u8,
        rect: c.RECT,
        with: ?c.HFONT,
        color: Rgb,
        alpha: f32,
        flags: u32,
    ) void {
        // Draw white on black, which makes the pixels the coverage.
        const mask = Buffer.begin(self.dc, rect) orelse return;
        defer mask.discard();
        mask.text(utf8, .{
            .right = rect.right - rect.left,
            .bottom = rect.bottom - rect.top,
        }, with, .{ .r = 255, .g = 255, .b = 255 }, flags);
        _ = c.GdiFlush();

        const height = self.pixels.len / self.width;
        for (0..mask.pixels.len / mask.width) |my| {
            const y = std.math.cast(usize, rect.top + @as(c_int, @intCast(my))) orelse continue;
            if (y >= height) break;
            for (0..mask.width) |mx| {
                const x = std.math.cast(usize, rect.left + @as(c_int, @intCast(mx))) orelse continue;
                if (x >= self.width) break;
                const coverage = (mask.pixels[my * mask.width + mx] >> 8) & 0xFF;
                if (coverage == 0) continue;
                self.blend(y * self.width + x, color, alpha * @as(f32, @floatFromInt(coverage)) / 255);
            }
        }
    }

    /// Fill with a color that's as opaque as the base.
    pub fn surface(self: Buffer, rect: c.RECT, color: Rgb) void {
        if (self.has_alpha) return self.replace(rect, color, self.base_opacity);
        self.fill(rect, color);
    }

    pub fn fill(self: Buffer, rect: c.RECT, color: Rgb) void {
        if (self.has_alpha) return self.replace(rect, color, 255);
        const brush = c.CreateSolidBrush(color.ref()) orelse return;
        defer _ = c.DeleteObject(brush);
        _ = c.FillRect(self.dc, &rect, brush);
    }

    pub fn text(
        self: Buffer,
        utf8: []const u8,
        rect: c.RECT,
        with: ?c.HFONT,
        color: Rgb,
        flags: u32,
    ) void {
        // This has no alpha of its own.
        if (self.has_alpha) return self.blendText(utf8, rect, with, color, 1, flags);

        var wide: [512]u16 = undefined;
        const len = toWide(&wide, utf8);
        if (len == 0) return;

        const old = if (with) |v| c.SelectObject(self.dc, v) else null;
        defer if (old) |v| {
            _ = c.SelectObject(self.dc, v);
        };
        _ = c.SetBkMode(self.dc, c.TRANSPARENT);
        _ = c.SetTextColor(self.dc, color.ref());
        var r = rect;
        _ = c.DrawTextW(
            self.dc,
            &wide,
            @intCast(len),
            &r,
            flags | c.DT_SINGLELINE | c.DT_VCENTER | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
        );
    }
};
