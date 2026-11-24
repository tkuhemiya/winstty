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
        const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
        return .{
            .bg = bg,
            .fg = fg,
            .bar = bg.mix(black, if (bg.isDark()) 70 else 25),
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
        c.L("Segoe UI"),
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
        };
    }

    pub fn end(self: Buffer) void {
        _ = c.GdiFlush();
        for (self.pixels) |*pixel| pixel.* |= 0xFF000000;
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
        if (self.previous) |v| _ = c.SelectObject(self.dc, v);
        _ = c.DeleteObject(self.bitmap);
        _ = c.DeleteDC(self.dc);
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
        font: ?c.HFONT,
        color: Rgb,
        flags: u32,
    ) void {
        // Labels are one line and ellipsized, so a long one can be cut short.
        var wide: [512]u16 = undefined;
        var end_idx = @min(utf8.len, wide.len);
        while (end_idx > 0 and end_idx < utf8.len and utf8[end_idx] & 0xC0 == 0x80) end_idx -= 1;
        const len = std.unicode.wtf8ToWtf16Le(&wide, utf8[0..end_idx]) catch return;
        if (len == 0) return;

        const old = if (font) |v| c.SelectObject(self.dc, v) else null;
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
