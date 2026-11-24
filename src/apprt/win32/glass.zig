//! Windows that show a blurred view of what's behind them.
const std = @import("std");
const Config = @import("../../config.zig").Config;
const c = @import("c.zig");
const paint = @import("paint.zig");

/// How a window is made.
pub const Look = enum {
    /// Without `win32-glass`.
    off,
    /// Glass.
    frost,
    /// Glass that can't be shown, or shouldn't be.
    solid,
};

/// How opaque popups are.
pub const popup_opacity: u8 = 217;

/// How much of the tint is in the frost itself. The material also keeps the
/// brightness of what's behind it close to that of the tint, which is what
/// makes text readable on any desktop.
const frost_tint: u32 = 0x80;

/// How opaque each part of a window is, 255 being fully.
pub const Opacity = struct {
    card: u8,
    /// Between cards.
    gap: u8,
    /// The title bar and the side panel.
    bar: u8,

    pub fn init(config: *const Config, look: Look) Opacity {
        const value: f64 = switch (look) {
            .off => std.math.clamp(config.@"background-opacity", 0, 1),
            .frost => std.math.clamp(config.@"win32-glass-opacity", 0.2, 1),
            .solid => 1,
        };
        const card: u8 = @intFromFloat(@round(value * 255));
        return .{
            .card = card,
            .gap = if (card == 255) 255 else @intCast(@as(u32, card) * 7 / 10),
            // A quarter of the way to being opaque.
            .bar = if (look == .frost) card + (255 - card) / 4 else card,
        };
    }
};

/// What the terminal renderer uses for the background in place of its own.
pub const Background = packed struct(u64) {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
    a: u8 = 0,
    active: bool = false,
    /// Otherwise only the opacity is replaced.
    has_color: bool = false,
    _: u30 = 0,

    pub fn init(config: *const Config, look: Look) Background {
        if (look == .off) return .{};
        var result: Background = .{
            .a = Opacity.init(config, look).card,
            .active = true,
        };
        switch (config.@"win32-glass-tint") {
            .theme => {},
            .color => |v| {
                result.has_color = true;
                result.r = v.r;
                result.g = v.g;
                result.b = v.b;
            },
        }
        return result;
    }
};

/// Why blur can't be shown at the moment, if it can't.
pub fn unavailable() ?[]const u8 {
    if (highContrast()) return "a high contrast theme is in use";
    if (c.GetSystemMetrics(c.SM_REMOTESESSION) != 0) return "this is a remote session";
    var power: c.SYSTEM_POWER_STATUS = .{};
    if (c.GetSystemPowerStatus(&power) != 0 and power.SystemStatusFlag & 1 != 0)
        return "battery saver is on";
    var enabled: u32 = 1;
    var size: u32 = @sizeOf(u32);
    _ = c.RegGetValueW(
        c.HKEY_CURRENT_USER,
        c.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        c.L("EnableTransparency"),
        c.RRF_RT_REG_DWORD,
        null,
        &enabled,
        &size,
    );
    if (enabled == 0) return "transparency effects are turned off";
    return null;
}

pub fn highContrast() bool {
    var info: c.HIGHCONTRASTW = .{};
    if (c.SystemParametersInfoW(c.SPI_GETHIGHCONTRAST, info.cbSize, &info, 0) == 0) return false;
    return info.dwFlags & c.HCF_HIGHCONTRASTON != 0;
}

pub const Backing = union(enum) {
    /// The alpha channel of what's drawn is ignored.
    solid,
    /// Shows what's behind as it is.
    clear,
    blur,
    /// A stronger blur, in a color.
    frost: paint.Rgb,
};

/// Have the compositor use the alpha channel of what's drawn, or not.
pub fn setBacking(hwnd: c.HWND, backing: Backing) void {
    const transparent = backing != .solid;

    // An empty region enables alpha without any blur. Since Windows 8 the
    // blur this is named for doesn't exist anyway.
    const region = if (transparent) c.CreateRectRgn(0, 0, -1, -1) else null;
    defer if (region) |v| {
        _ = c.DeleteObject(v);
    };
    _ = c.DwmEnableBlurBehindWindow(hwnd, &.{
        .dwFlags = c.DWM_BB_ENABLE | @as(u32, if (transparent) c.DWM_BB_BLURREGION else 0),
        .fEnable = @intFromBool(transparent),
        .hRgnBlur = region,
    });

    // The documented backdrops (DWMWA_SYSTEMBACKDROP_TYPE) aren't in the first
    // release of Windows 11, and turn solid in windows that aren't active. This
    // is undocumented, so look it up and do without if it's ever removed.
    const user32 = c.GetModuleHandleW(c.L("user32.dll")) orelse return;
    const proc = c.GetProcAddress(user32, "SetWindowCompositionAttribute") orelse return;
    const func: *const fn (
        c.HWND,
        *const c.WINDOWCOMPOSITIONATTRIBDATA,
    ) callconv(.winapi) c.BOOL = @ptrCast(@alignCast(proc));
    const policy: c.ACCENT_POLICY = switch (backing) {
        .solid, .clear => .{ .state = c.ACCENT_DISABLED },
        .blur => .{ .state = c.ACCENT_ENABLE_BLURBEHIND },
        .frost => |tint| .{
            .state = c.ACCENT_ENABLE_ACRYLICBLURBEHIND,
            .color = frost_tint << 24 | tint.ref(),
        },
    };
    _ = func(hwnd, &.{
        .attribute = c.WCA_ACCENT_POLICY,
        .data = &policy,
        .size = @sizeOf(c.ACCENT_POLICY),
    });
}

/// Let a popup that's painted with an alpha channel be glass, or not.
pub fn setPopupBacking(hwnd: c.HWND, look: Look, palette: paint.Palette) void {
    setBacking(hwnd, if (look == .frost) .{ .frost = palette.bar } else .solid);
}

/// GDI leaves the alpha channel of what it draws at zero, so native controls
/// can't be on glass. If they're layered they have no alpha channel to leave,
/// and their background can be left out.
pub fn setControlBacking(hwnd: c.HWND, look: Look, background: paint.Rgb) void {
    const style: u32 = @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE))));
    const want = if (look == .frost) style | c.WS_EX_LAYERED else style & ~c.WS_EX_LAYERED;
    if (want != style) _ = c.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, want);
    if (look == .frost) {
        _ = c.SetLayeredWindowAttributes(hwnd, background.ref(), 0, c.LWA_COLORKEY);
    }
    if (want != style) _ = c.InvalidateRect(hwnd, null, 1);
}

test "glass: opacity" {
    var config: Config = try .default(std.testing.allocator);
    defer config.deinit();

    // Off is as configured, and the bar is like the terminal.
    config.@"background-opacity" = 0.8;
    const off: Opacity = .init(&config, .off);
    try std.testing.expectEqual(Opacity{ .card = 204, .gap = 142, .bar = 204 }, off);

    const frost: Opacity = .init(&config, .frost);
    try std.testing.expectEqual(@as(u8, 153), frost.card);
    try std.testing.expectEqual(@as(u8, 107), frost.gap);
    try std.testing.expect(frost.bar > frost.card and frost.bar < 255);

    const solid: Opacity = .init(&config, .solid);
    try std.testing.expectEqual(Opacity{ .card = 255, .gap = 255, .bar = 255 }, solid);
}

test "glass: background" {
    var config: Config = try .default(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(Background.init(&config, .off))));

    const theme: Background = .init(&config, .frost);
    try std.testing.expect(theme.active and !theme.has_color and theme.a == 153);

    config.@"win32-glass-tint" = .{ .color = .{ .r = 1, .g = 2, .b = 3 } };
    const tinted: Background = .init(&config, .solid);
    try std.testing.expect(tinted.active and tinted.has_color and tinted.a == 255);
    try std.testing.expectEqual(@as(u8, 2), tinted.g);
}
