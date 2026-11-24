//! WGL (Windows OpenGL) device and context, used by the Win32 apprt.
//!
//! Unlike the EGL path, which renders offscreen and exports frames for the
//! apprt to composite, WGL contexts are bound to a window's device context
//! and the render thread presents directly with SwapBuffers.
const std = @import("std");
const gl = @import("opengl");

const log = std.log.scoped(.opengl);

pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
const HMODULE = *opaque {};
const BOOL = c_int;
const Proc = *const fn () callconv(.c) void;

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = 40,
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,

    comptime {
        std.debug.assert(@sizeOf(PIXELFORMATDESCRIPTOR) == 40);
    }
};

const PFD_DOUBLEBUFFER = 0x1;
const PFD_DRAW_TO_WINDOW = 0x4;
const PFD_SUPPORT_OPENGL = 0x20;

const pixel_format: PIXELFORMATDESCRIPTOR = .{
    .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
    .cColorBits = 32,
    .cAlphaBits = 8,
};

extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
const RECT = extern struct { left: c_int = 0, top: c_int = 0, right: c_int = 0, bottom: c_int = 0 };
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(
    u32,
    [*:0]const u16,
    [*:0]const u16,
    u32,
    c_int,
    c_int,
    c_int,
    c_int,
    ?HWND,
    ?*anyopaque,
    ?*anyopaque,
    ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress([*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW([*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(HMODULE, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const CreateContextAttribs = *const fn (HDC, ?HGLRC, [*]const c_int) callconv(.winapi) ?HGLRC;
const SwapInterval = *const fn (c_int) callconv(.winapi) BOOL;

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x1;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// GL function loader for glad. wglGetProcAddress only serves GL 1.2+, the
/// rest are plain exports of opengl32.dll. Some drivers return small sentinel
/// integers instead of null on failure.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?Proc {
    if (wglGetProcAddress(name)) |proc| switch (@as(isize, @bitCast(@intFromPtr(proc)))) {
        -1, 1, 2, 3 => {},
        else => return @ptrCast(@alignCast(proc)),
    };
    const module = GetModuleHandleW(L("opengl32.dll")) orelse return null;
    return @ptrCast(@alignCast(GetProcAddress(module, name) orelse return null));
}

fn setPixelFormat(dc: HDC) !void {
    const format = ChoosePixelFormat(dc, &pixel_format);
    if (format == 0) return error.WglNoPixelFormat;
    if (SetPixelFormat(dc, format, &pixel_format) == 0) return error.WglSetPixelFormatFailed;
}

/// App-wide WGL state: extension functions that can only be loaded while
/// some context is current.
pub const Device = struct {
    pub const Options = struct {};

    create_context: CreateContextAttribs,
    swap_interval: ?SwapInterval,

    pub fn init(alloc: std.mem.Allocator, _: Options) !*Device {
        // A window's pixel format can only be set once, so bootstrap with a
        // throwaway window of a predefined class.
        const hwnd = CreateWindowExW(
            0,
            L("STATIC"),
            L(""),
            0,
            0,
            0,
            1,
            1,
            null,
            null,
            null,
            null,
        ) orelse return error.WglBootstrapFailed;
        defer _ = DestroyWindow(hwnd);
        const dc = GetDC(hwnd) orelse return error.WglBootstrapFailed;
        defer _ = ReleaseDC(hwnd, dc);
        try setPixelFormat(dc);

        const ctx = wglCreateContext(dc) orelse return error.WglBootstrapFailed;
        defer _ = wglDeleteContext(ctx);
        if (wglMakeCurrent(dc, ctx) == 0) return error.WglBootstrapFailed;
        defer _ = wglMakeCurrent(null, null);

        const create = getProcAddress("wglCreateContextAttribsARB") orelse
            return error.OpenGLOutdated;
        const self = try alloc.create(Device);
        self.* = .{
            .create_context = @ptrCast(create),
            .swap_interval = if (getProcAddress("wglSwapIntervalEXT")) |p| @ptrCast(p) else null,
        };
        return self;
    }

    pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

/// A context bound to one window. The window class must be CS_OWNDC so the
/// device context stays valid for the life of the window.
pub const Context = struct {
    hwnd: HWND,
    dc: HDC,
    rc: HGLRC,

    pub fn init(device: *const Device, hwnd: HWND, major: c_int, minor: c_int) !Context {
        const dc = GetDC(hwnd) orelse return error.WglNoDeviceContext;
        errdefer _ = ReleaseDC(hwnd, dc);
        try setPixelFormat(dc);
        const attribs = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, major,
            WGL_CONTEXT_MINOR_VERSION_ARB, minor,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        const rc = device.create_context(dc, null, &attribs) orelse {
            log.warn("failed to create OpenGL {}.{} context", .{ major, minor });
            return error.OpenGLOutdated;
        };
        return .{ .hwnd = hwnd, .dc = dc, .rc = rc };
    }

    pub fn deinit(self: Context) void {
        _ = wglDeleteContext(self.rc);
        _ = ReleaseDC(self.hwnd, self.dc);
    }

    /// The size of the window, which the size of what's drawn follows.
    pub fn size(self: Context) struct { width: i32, height: i32 } {
        var rect: RECT = .{};
        _ = GetClientRect(self.hwnd, &rect);
        return .{ .width = rect.right, .height = rect.bottom };
    }

    pub fn makeCurrent(self: Context) !void {
        if (wglMakeCurrent(self.dc, self.rc) == 0) return error.WglMakeCurrentFailed;
    }

    pub fn releaseCurrent() void {
        _ = wglMakeCurrent(null, null);
    }

    pub fn swap(self: Context) !void {
        if (SwapBuffers(self.dc) == 0) return error.WglSwapFailed;
    }
};

pub fn toLinear(v: f32) f32 {
    if (v <= 0.04045) return v / 12.92;
    return std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

pub fn toSrgb(v: f32) f32 {
    if (v <= 0.0031308) return v * 12.92;
    return 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

/// Draws a translucent color over the whole window.
pub const Dimmer = struct {
    program: gl.Program,
    vao: gl.VertexArray,
    color: gl.c.GLint,

    pub fn init() !Dimmer {
        // A triangle that covers the screen.
        const program = try gl.Program.createVF(
            \\#version 430 core
            \\void main() {
            \\    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
            \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
            \\}
        ,
            \\#version 430 core
            \\uniform vec4 color;
            \\out vec4 result;
            \\void main() { result = color; }
        );
        errdefer program.destroy();
        return .{
            .program = program,
            .vao = try gl.VertexArray.create(),
            .color = gl.glad.context.GetUniformLocation.?(program.id, "color"),
        };
    }

    pub fn deinit(self: Dimmer) void {
        self.program.destroy();
        self.vao.destroy();
    }

    /// The color is 0xAARRGGBB. The values on screen are sRGB, so this blends
    /// in sRGB as desktops do.
    ///
    /// With the opacity of the background, the color is made as translucent as
    /// the renderer makes that, so that dimming a background with its own color
    /// doesn't change it. Otherwise the two differ, more so the more translucent
    /// the background is.
    pub fn draw(self: Dimmer, argb: u32, opacity: ?f32) !void {
        try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
        defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err|
            log.err("error re-enabling GL_FRAMEBUFFER_SRGB err={}", .{err});
        try gl.enable(gl.c.GL_BLEND);

        // This tints what's there, and leaves it as translucent as it was.
        gl.glad.context.BlendFuncSeparate.?(
            gl.c.GL_DST_ALPHA,
            gl.c.GL_ONE_MINUS_SRC_ALPHA,
            gl.c.GL_ZERO,
            gl.c.GL_ONE,
        );

        const program = try self.program.use();
        defer program.unbind();
        const vao = try self.vao.bind();
        defer vao.unbind();

        // Premultiplied.
        const a = @as(f32, @floatFromInt(argb >> 24)) / 255;
        const f = struct {
            fn f(v: u32, alpha: f32, background: ?f32) f32 {
                const color = @as(f32, @floatFromInt(v & 0xFF)) / 255;
                const o = background orelse return color * alpha;
                if (o <= 0) return color * alpha;
                // It's multiplied by the opacity when it's blended.
                return alpha * toSrgb(toLinear(color) * o) / o;
            }
        }.f;
        gl.glad.context.Uniform4f.?(
            self.color,
            f(argb >> 16, a, opacity),
            f(argb >> 8, a, opacity),
            f(argb, a, opacity),
            a,
        );
        try gl.drawArrays(gl.c.GL_TRIANGLES, 0, 3);
    }
};
