//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");
const build_config = @import("../build_config.zig");
const wgl = @import("opengl/wgl.zig");
pub const SmoothScroll = @import("opengl/SmoothScroll.zig");

/// The Win32 apprt presents straight to its window using WGL. Everything
/// else renders offscreen using EGL and exports frames to the apprt.
pub const use_wgl = build_config.app_runtime == .win32;

pub const Device = if (use_wgl) wgl.Device else @import("opengl/Device.zig");

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
pub const swap_chain_count = 3;

const log = std.log.scoped(.opengl);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The shared render device.
device: *const Device,

context: if (use_wgl) wgl.Context else *gl.egl.Context,

/// The surface we present to, and what dims it.
rt_surface: if (use_wgl) *apprt.Surface else void,
dimmer: if (use_wgl) ?wgl.Dimmer else void = if (use_wgl) null else {},

/// Smooth scrolling, and what it needs to know of the frame being drawn.
smooth_scroll: if (use_wgl) ?SmoothScroll else void = if (use_wgl) null else {},
scroll_geometry: SmoothScroll.Geometry = .{},

/// Whether presenting doesn't wait for the compositor.
unpaced: bool = false,

/// The background of the frame being drawn.
clear_color: [4]u8 = @splat(0),

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !OpenGL {
    if (comptime use_wgl) return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .context = try .init(
            device,
            @ptrCast(opts.rt_surface.hwnd),
            MIN_VERSION_MAJOR,
            MIN_VERSION_MINOR,
        ),
        .rt_surface = opts.rt_surface,
    };

    const display = device.display;

    // Bind to OpenGL API explicitly before we create the context,
    // as otherwise it might fallback to OpenGL ES
    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Create our context. Contexts are surface-scoped because a
    // context can only be current on one thread at a time.
    const context = egl.Context.create(display, device.config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .context = context,
        .rt_surface = {},
    };
}

pub fn deinit(self: *OpenGL) void {
    if (comptime use_wgl) {
        self.context.deinit();
    } else {
        self.device.display.releaseCurrent();
        self.context.destroy(self.device.display) catch {};
    }
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".attrs.@"callconv";

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    _ = surface;
    if (comptime use_wgl) {
        try self.context.makeCurrent();
        errdefer wgl.Context.releaseCurrent();

        // Pace presentation with the compositor. This only blocks the
        // render thread. Frames are still driven by wakeups.
        if (self.device.swap_interval) |f| _ = f(1);
        try prepareContext(&wgl.getProcAddress);
        return;
    }

    try self.device.display.makeCurrent(null, null, self.context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    if (comptime use_wgl) {
        if (self.dimmer) |v| v.deinit();
        self.dimmer = null;
        SmoothScroll.reset(&self.smooth_scroll);
        wgl.Context.releaseCurrent();
    } else self.device.display.releaseCurrent();
    gl.glad.unload();
}

/// Tell us about the frame that's about to be drawn.
pub fn setScrollGeometry(self: *OpenGL, geometry: SmoothScroll.Geometry) void {
    self.scroll_geometry = geometry;
}

/// The opacity, and perhaps the color, to use for the background rather than
/// what's configured.
pub fn background(self: *const OpenGL) ?Background {
    if (comptime !use_wgl) return null;
    const v: BackgroundOverride = @bitCast(self.rt_surface.background.load(.acquire));
    if (!v.active) return null;
    return .{
        .opacity = v.a,
        .color = if (v.has_color) .{ v.r, v.g, v.b } else null,
    };
}

pub const Background = struct { opacity: u8, color: ?[3]u8 };

const BackgroundOverride = if (use_wgl)
    @import("../apprt/win32/glass.zig").Background
else
    void;

/// Remember the background of the frame that's about to be drawn.
pub fn setClearColor(self: *OpenGL, color: [4]u8) void {
    self.clear_color = color;
}

/// Fill the screen with the background, as the frame is. The values on screen
/// are sRGB, and were premultiplied before they became that.
fn clearScreen(self: *const OpenGL) !void {
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err|
        log.err("error re-enabling GL_FRAMEBUFFER_SRGB err={}", .{err});
    const alpha = @as(f32, @floatFromInt(self.clear_color[3])) / 255;
    var out: [3]f32 = undefined;
    for (&out, self.clear_color[0..3]) |*v, value| {
        const srgb = @as(f32, @floatFromInt(value)) / 255;
        v.* = wgl.toSrgb(alpha * wgl.toLinear(srgb));
    }
    const screen: gl.Framebuffer = .{ .id = 0 };
    const draw = try screen.bind(.draw);
    defer draw.unbind();
    gl.clearColor(out[0], out[1], out[2], alpha);
    gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
}

/// Whether more frames are needed, for a scroll that's in progress.
pub fn isScrolling(self: *const OpenGL) bool {
    if (comptime !use_wgl) return false;
    const scroll = self.smooth_scroll orelse return false;
    return scroll.position.animating;
}

/// Called on the render thread when the surface is hidden.
pub fn releaseResources(self: *OpenGL) void {
    if (comptime use_wgl) SmoothScroll.reset(&self.smooth_scroll);
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(
    self: *OpenGL,
    target: Target,
    presentation_health: rendererpkg.Health,
) !ExportedFrame {
    if (comptime use_wgl) {
        const move = self.rt_surface.moves.load(.acquire);

        // The window may not be the size of the frame, if it's moving or has
        // changed since. What's at the top stays there.
        const window = self.context.size();
        const bottom = window.height - @as(i32, @intCast(target.height));
        if (bottom > 0 or window.width > target.width) try self.clearScreen();
        try target.blitToScreen(bottom);
        if (self.rt_surface.smooth_scroll.load(.acquire))
            try SmoothScroll.present(&self.smooth_scroll, &target, self.scroll_geometry, bottom)
        else
            SmoothScroll.reset(&self.smooth_scroll);
        const dim = self.rt_surface.dim.load(.acquire);
        if (dim >> 24 > 0) {
            if (self.dimmer == null) self.dimmer = try .init();
            try self.dimmer.?.draw(
                dim,
                if (self.background()) |v| @as(f32, @floatFromInt(v.opacity)) / 255 else null,
            );
        }
        // Moving a window waits for a swap that's in progress, so don't have
        // those wait for the compositor. Whatever moves us does already.
        const moving = self.rt_surface.moving.load(.acquire);
        if (moving != self.unpaced) {
            self.unpaced = moving;
            if (self.device.swap_interval) |f| _ = f(if (moving) 0 else 1);
        }
        try self.context.swap();
        if (moving) self.rt_surface.setPresented(move);
        return;
    }

    // We only export DMABUFs when the apprt can present them.
    // Otherwise, use CPU buffers.
    if (presentation_health == .healthy) {
        if (target.exportDmabuf(self.device.display, self.context)) |dmabuf| {
            return .{ .dmabuf = dmabuf };
        } else |_| {
            log.warn("failed to export DMABUF, falling back to CPU presentation", .{});
        }
    }

    return .{ .memory = .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .pixels = try target.readPixelsAlloc(self.alloc),
        .alloc = self.alloc,
    } };
}

/// A finished frame exported for presentation by the apprt.
///
/// Void for WGL, where `present` has already put the frame on screen.
pub const ExportedFrame = if (use_wgl) void else union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2d",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
