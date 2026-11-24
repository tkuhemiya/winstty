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

    pub fn init(config: *const Config) Palette {
        const bg: Rgb = .from(config.background);
        const fg: Rgb = .from(config.foreground);
        return .{
            .bg = bg,
            .fg = fg,
            .bar = bg.mix(fg, if (bg.isDark()) 24 else 10),
            .hover = bg.mix(fg, 25),
            .selected = bg.mix(fg, 45),
            .dim = fg.mix(bg, 100),
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
    /// `base`. Only the blending functions may be used, not `fill` or `text`.
    has_alpha: bool = false,

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
    fn discard(self: Buffer) void {
        if (self.previous) |v| _ = c.SelectObject(self.dc, v);
        _ = c.DeleteObject(self.bitmap);
        _ = c.DeleteDC(self.dc);
    }

    /// Premultiplies in linear space, as the terminal's renderer does, so that
    /// the same color next to it looks the same.
    fn premultiplied(opacity: u8) [256]u8 {
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
        const table = premultiplied(opacity);
        const pixel = @as(u32, opacity) << 24 |
            @as(u32, table[color.r]) << 16 |
            @as(u32, table[color.g]) << 8 |
            table[color.b];
        @memset(self.pixels, pixel);
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

    pub fn fill(self: Buffer, rect: c.RECT, color: Rgb) void {
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
        // Labels are one line and ellipsized, so a long one can be cut short.
        var wide: [512]u16 = undefined;
        var end_idx = @min(utf8.len, wide.len);
        while (end_idx > 0 and end_idx < utf8.len and utf8[end_idx] & 0xC0 == 0x80) end_idx -= 1;
        const len = std.unicode.wtf8ToWtf16Le(&wide, utf8[0..end_idx]) catch return;
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
