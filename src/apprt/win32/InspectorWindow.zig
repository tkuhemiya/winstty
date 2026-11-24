//! The inspector of a surface, in a window of its own.
//!
//! Everything here runs on the main thread. The window has its own WGL
//! context and its own Dear ImGui context, so any number of inspectors can be
//! open at once. The GL context is only current while a frame is drawn, so it
//! never interferes with anything else on this thread.
const InspectorWindow = @This();

const std = @import("std");
const cimgui = @import("dcimgui");
const global = @import("../../global.zig");
const input = @import("../../input.zig");
const Inspector = @import("../../inspector/Inspector.zig");
const wgl = @import("../../renderer/opengl/wgl.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");
const paint = @import("paint.zig");

const ig = cimgui.c;
const log = std.log.scoped(.win32);

const class_name = c.L("GhosttyInspector");

/// Posted by `queueRender`.
const WM_RENDER = c.WM_APP + 1;

const timer_id = 1;

/// ~30 FPS, which is plenty for a debugging tool, as on GTK.
const frame_ms = 33;

surface: *Surface,
hwnd: c.HWND,
gl: wgl.Context,
ig_context: *ig.ImGuiContext,

/// When the previous frame began, for the animation clock.
last_frame: ?std.Io.Timestamp = null,

/// A WM_RENDER is in the queue, so there's no need to post another.
render_queued: std.atomic.Value(bool) = .init(false),

/// Guards against drawing from inside a draw, should a message be pumped.
rendering: bool = false,
render_failed: bool = false,

tracking_leave: bool = false,

/// Bit per ImGui mouse button, so the mouse is captured while any is down.
buttons_down: u8 = 0,

pub fn register(hinstance: c.HINSTANCE) !void {
    const icon = c.LoadIconW(hinstance, 1);
    if (c.RegisterClassExW(&.{
        // The WGL context holds on to the window's DC, so it must be owned.
        .style = c.CS_OWNDC | c.CS_DBLCLKS,
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hIcon = icon,
        .hIconSm = icon,
        .lpszClassName = class_name,
    }) == 0) return error.Win32Failed;
}

/// Create the window, show it and start collecting inspection data.
pub fn create(surface: *Surface) !*InspectorWindow {
    const app = surface.app;
    const alloc = app.core_app.alloc;
    const device = app.core_app.device orelse return error.NoRenderDevice;

    const self = try alloc.create(InspectorWindow);
    errdefer alloc.destroy(self);

    const dpi = c.GetDpiForSystem();
    const hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.L("Ghostty: Terminal Inspector"),
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        paint.scale(1000, dpi),
        paint.scale(600, dpi),
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Failed;
    errdefer _ = c.DestroyWindow(hwnd);

    // The inspector is a dark UI, a light title bar would glare.
    const dark: c.BOOL = 1;
    _ = c.DwmSetWindowAttribute(hwnd, c.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(c.BOOL));

    const gl = try wgl.Context.init(device, @ptrCast(hwnd), 4, 3);
    errdefer gl.deinit();

    self.* = .{
        .surface = surface,
        .hwnd = hwnd,
        .gl = gl,
        .ig_context = undefined,
    };
    try self.initImGui(device);
    errdefer self.deinitImGui();

    try surface.core_surface.activateInspector();
    errdefer surface.core_surface.deactivateInspector();

    if (c.SetTimer(hwnd, timer_id, frame_ms, null) == 0) return error.Win32Failed;
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    self.render();
    return self;
}

/// Destroy now. Sets surface.inspector to null.
pub fn destroy(self: *InspectorWindow) void {
    const alloc = self.surface.app.core_app.alloc;
    _ = c.KillTimer(self.hwnd, timer_id);
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    self.deinitImGui();
    self.surface.core_surface.deactivateInspector();

    // The context must be gone before the window, and so its DC, is.
    self.gl.deinit();
    _ = c.DestroyWindow(self.hwnd);
    self.surface.inspector = null;
    alloc.destroy(self);
}

/// Destroy soon, from the message loop.
pub fn close(self: *InspectorWindow) void {
    _ = c.PostMessageW(self.hwnd, c.WM_CLOSE, 0, 0);
}

/// Draw soon. Safe from any thread.
pub fn queueRender(self: *InspectorWindow) void {
    if (self.render_queued.swap(true, .acq_rel)) return;
    if (c.PostMessageW(self.hwnd, WM_RENDER, 0, 0) == 0) self.render_queued.store(false, .release);
}

//---------------------------------------------------------------
// Dear ImGui

fn initImGui(self: *InspectorWindow, device: *const wgl.Device) !void {
    try self.gl.makeCurrent();
    defer wgl.Context.releaseCurrent();

    // This context presents from the UI thread, which mustn't wait for vsync.
    if (device.swap_interval) |f| _ = f(0);

    const context = ig.ImGui_CreateContext(null) orelse return error.ImGuiFailed;
    errdefer ig.ImGui_DestroyContext(context);
    ig.ImGui_SetCurrentContext(context);

    const io: *ig.ImGuiIO = ig.ImGui_GetIO();
    io.BackendPlatformName = "ghostty_win32";
    io.BackendFlags |= ig.ImGuiBackendFlags_HasMouseCursors;

    if (!cimgui.ImGui_ImplOpenGL3_Init(null)) return error.ImGuiFailed;
    errdefer cimgui.ImGui_ImplOpenGL3_Shutdown();

    Inspector.setup();
    self.ig_context = context;
    self.updateStyle();
}

fn deinitImGui(self: *InspectorWindow) void {
    // Shutting down the backend deletes GL objects, which needs the context.
    self.gl.makeCurrent() catch |err| {
        log.warn("error making inspector GL context current err={}", .{err});
        ig.ImGui_SetCurrentContext(self.ig_context);
        ig.ImGui_DestroyContext(self.ig_context);
        return;
    };
    defer wgl.Context.releaseCurrent();

    ig.ImGui_SetCurrentContext(self.ig_context);

    // Not the variant that also zeroes the backend's GL loader. That loader is
    // shared by every inspector, so another one would crash. It's needed only
    // on platforms where the shutdown unloads the GL library, and opengl32.dll
    // is linked to this program.
    cimgui.ImGui_ImplOpenGL3_Shutdown();
    ig.ImGui_DestroyContext(self.ig_context);
}

/// Scale the style for the window's DPI. Like on GTK, sizes are scaled by the
/// style and the display size stays in pixels, which makes for crisper text.
fn updateStyle(self: *InspectorWindow) void {
    self.setContext();
    const scale = @as(f32, @floatFromInt(c.GetDpiForWindow(self.hwnd))) / 96;

    // The default style has the right values (CurveTessellationTol...), zeroes
    // would not.
    var style: ig.ImGuiStyle = undefined;
    cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
    ig.ImGuiStyle_ScaleAllSizes(&style, scale);

    // Inspector.setup loads its font at 32 pixels, for a scale of 2.
    const active: *ig.ImGuiStyle = ig.ImGui_GetStyle();
    style.FontSizeBase = active.FontSizeBase;
    style.FontScaleMain = scale / 2;
    active.* = style;
}

fn setContext(self: *const InspectorWindow) void {
    ig.ImGui_SetCurrentContext(self.ig_context);
}

//---------------------------------------------------------------
// Drawing

fn render(self: *InspectorWindow) void {
    // A message box may be open above a core callback that holds a lock the
    // inspector needs.
    if (self.rendering or self.surface.app.modal > 0) return;
    if (c.IsIconic(self.hwnd) != 0 or c.IsWindowVisible(self.hwnd) == 0) return;

    var rect: c.RECT = .{};
    if (c.GetClientRect(self.hwnd, &rect) == 0) return;
    if (rect.right <= 0 or rect.bottom <= 0) return;

    self.rendering = true;
    defer self.rendering = false;

    self.gl.makeCurrent() catch |err| {
        if (!self.render_failed) log.warn("error making inspector GL context current err={}", .{err});
        self.render_failed = true;
        return;
    };
    defer wgl.Context.releaseCurrent();
    self.render_failed = false;

    self.setContext();
    const io: *ig.ImGuiIO = ig.ImGui_GetIO();

    // We render twice because some ImGui behaviors take multiple renders to
    // process, as in the other apprts.
    for (0..2) |_| {
        io.DisplaySize = .{ .x = @floatFromInt(rect.right), .y = @floatFromInt(rect.bottom) };
        io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };
        io.DeltaTime = self.deltaTime();

        cimgui.ImGui_ImplOpenGL3_NewFrame();
        ig.ImGui_NewFrame();
        if (self.surface.core_surface.inspector) |v| v.render(&self.surface.core_surface);
        ig.ImGui_Render();
    }

    c.glViewport(0, 0, rect.right, rect.bottom);
    c.glClearColor(0.1, 0.1, 0.1, 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    cimgui.ImGui_ImplOpenGL3_RenderDrawData(ig.ImGui_GetDrawData());
    self.gl.swap() catch |err| log.warn("error presenting inspector err={}", .{err});
}

fn deltaTime(self: *InspectorWindow) f32 {
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    defer self.last_frame = now;
    const prev = self.last_frame orelse return 1.0 / 60.0;
    const since_ns: f64 = @floatFromInt(prev.durationTo(now).nanoseconds);
    const since_s: f32 = @floatCast(since_ns / @as(f64, std.time.ns_per_s));
    return @max(0.00001, since_s);
}

//---------------------------------------------------------------
// Window procedure

fn wndProc(hwnd: c.HWND, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *InspectorWindow = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.message(msg, wparam, lparam) catch |err| err: {
        log.warn("error handling inspector message msg=0x{x} err={}", .{ msg, err });
        break :err 0;
    } orelse c.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Returns null for default processing. Self is destroyed on WM_CLOSE.
fn message(self: *InspectorWindow, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) !?c.LRESULT {
    switch (msg) {
        c.WM_CLOSE => {
            // A message box may be open above a core callback.
            if (self.surface.app.modal > 0) return 0;
            self.destroy();
        },

        WM_RENDER => {
            self.render_queued.store(false, .release);
            self.render();
        },
        c.WM_TIMER => if (wparam == timer_id) self.render() else return null,
        c.WM_PAINT => {
            _ = c.ValidateRect(self.hwnd, null);
            self.render();
        },

        // We paint every pixel, erasing only causes flicker.
        c.WM_ERASEBKGND => return 1,

        c.WM_SIZE => if (wparam != c.SIZE_MINIMIZED) self.render(),

        c.WM_DPICHANGED => {
            const rect: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = c.SetWindowPos(
                self.hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOZORDER | c.SWP_NOACTIVATE,
            );
            self.updateStyle();
            self.render();
        },

        c.WM_SETFOCUS, c.WM_KILLFOCUS => {
            self.setContext();
            ig.ImGuiIO_AddFocusEvent(ig.ImGui_GetIO(), msg == c.WM_SETFOCUS);
            self.queueRender();
        },

        c.WM_SETCURSOR => {
            if (lparam & 0xFFFF != c.HTCLIENT) return null;
            self.setContext();
            _ = c.SetCursor(cursor(ig.ImGui_GetMouseCursor()));
            return 1;
        },

        c.WM_MOUSEMOVE => {
            if (!self.tracking_leave) {
                var track: c.TRACKMOUSEEVENT = .{ .dwFlags = c.TME_LEAVE, .hwndTrack = self.hwnd };
                self.tracking_leave = c.TrackMouseEvent(&track) != 0;
            }
            self.mouseMove(lparam);
        },
        c.WM_MOUSELEAVE => {
            self.tracking_leave = false;
            self.setContext();
            const none = -std.math.floatMax(f32);
            ig.ImGuiIO_AddMousePosEvent(ig.ImGui_GetIO(), none, none);
            self.queueRender();
        },

        c.WM_LBUTTONDOWN, c.WM_LBUTTONDBLCLK => self.button(ig.ImGuiMouseButton_Left, true, lparam),
        c.WM_LBUTTONUP => self.button(ig.ImGuiMouseButton_Left, false, lparam),
        c.WM_RBUTTONDOWN, c.WM_RBUTTONDBLCLK => self.button(ig.ImGuiMouseButton_Right, true, lparam),
        c.WM_RBUTTONUP => self.button(ig.ImGuiMouseButton_Right, false, lparam),
        c.WM_MBUTTONDOWN, c.WM_MBUTTONDBLCLK => self.button(ig.ImGuiMouseButton_Middle, true, lparam),
        c.WM_MBUTTONUP => self.button(ig.ImGuiMouseButton_Middle, false, lparam),

        // Capture was taken away without the buttons being released.
        c.WM_CAPTURECHANGED => {
            self.setContext();
            const io = ig.ImGui_GetIO();
            for (0..3) |i| if (self.buttons_down & (@as(u8, 1) << @intCast(i)) != 0) {
                ig.ImGuiIO_AddMouseButtonEvent(io, @intCast(i), false);
            };
            self.buttons_down = 0;
            self.queueRender();
        },

        c.WM_MOUSEWHEEL, c.WM_MOUSEHWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
            const ticks = @as(f32, @floatFromInt(delta)) / 120;
            self.setContext();
            ig.ImGuiIO_AddMouseWheelEvent(
                ig.ImGui_GetIO(),
                if (msg == c.WM_MOUSEHWHEEL) ticks else 0,
                if (msg == c.WM_MOUSEWHEEL) ticks else 0,
            );
            self.queueRender();
        },

        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => {
            const pressed = msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN;
            self.key(pressed, wparam, lparam);

            // App.run only translates keys for the IME. We need the text of
            // the rest, which arrives as WM_CHAR.
            if (msg == c.WM_KEYDOWN and wparam != c.VK_PROCESSKEY and wparam != c.VK_PACKET) {
                const translate: c.MSG = .{
                    .hwnd = self.hwnd,
                    .message = msg,
                    .wParam = wparam,
                    .lParam = lparam,
                    .time = 0,
                    .pt = .{},
                };
                _ = c.TranslateMessage(&translate);
            }

            // Leave Alt+F4 and Alt+Space to the system. Otherwise tapping Alt
            // would start a menu loop, in a window which has no menu.
            if (msg == c.WM_SYSKEYDOWN or msg == c.WM_SYSKEYUP) {
                if (wparam == c.VK_F4 or wparam == c.VK_SPACE) return null;
            }
        },

        c.WM_CHAR => {
            // Control characters are keys, which were sent as such.
            if (wparam >= 0x20 and wparam != 0x7F) {
                self.setContext();
                ig.ImGuiIO_AddInputCharacterUTF16(ig.ImGui_GetIO(), @truncate(wparam));
                self.queueRender();
            }
        },

        else => return null,
    }
    return 0;
}

fn cursor(shape: ig.ImGuiMouseCursor) ?c.HCURSOR {
    const id: usize = switch (shape) {
        ig.ImGuiMouseCursor_None => return null,
        ig.ImGuiMouseCursor_TextInput => c.IDC_IBEAM,
        ig.ImGuiMouseCursor_ResizeAll => c.IDC_SIZEALL,
        ig.ImGuiMouseCursor_ResizeNS => c.IDC_SIZENS,
        ig.ImGuiMouseCursor_ResizeEW => c.IDC_SIZEWE,
        ig.ImGuiMouseCursor_ResizeNESW => c.IDC_SIZENESW,
        ig.ImGuiMouseCursor_ResizeNWSE => c.IDC_SIZENWSE,
        ig.ImGuiMouseCursor_Hand => c.IDC_HAND,
        ig.ImGuiMouseCursor_Wait => c.IDC_WAIT,
        ig.ImGuiMouseCursor_Progress => c.IDC_APPSTARTING,
        ig.ImGuiMouseCursor_NotAllowed => c.IDC_NO,
        else => c.IDC_ARROW,
    };
    return c.LoadCursorW(null, id);
}

//---------------------------------------------------------------
// Input

fn mousePos(lparam: c.LPARAM) ig.ImVec2 {
    const bits: usize = @bitCast(lparam);
    const x: i16 = @bitCast(@as(u16, @truncate(bits)));
    const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

fn mouseMove(self: *InspectorWindow, lparam: c.LPARAM) void {
    self.setContext();
    const pos = mousePos(lparam);
    ig.ImGuiIO_AddMousePosEvent(ig.ImGui_GetIO(), pos.x, pos.y);
    self.queueRender();
}

fn button(self: *InspectorWindow, btn: c_int, pressed: bool, lparam: c.LPARAM) void {
    const bit = @as(u8, 1) << @intCast(btn);
    if (pressed) {
        // Capture so that drags and releases outside the window reach us.
        if (self.buttons_down == 0) _ = c.SetCapture(self.hwnd);
        self.buttons_down |= bit;
        if (c.GetFocus() != self.hwnd) _ = c.SetFocus(self.hwnd);
    } else {
        self.buttons_down &= ~bit;
        if (self.buttons_down == 0) _ = c.ReleaseCapture();
    }

    // The position goes first, so that the click lands where the mouse is.
    self.mouseMove(lparam);
    ig.ImGuiIO_AddMouseButtonEvent(ig.ImGui_GetIO(), btn, pressed);
}

fn key(self: *InspectorWindow, pressed: bool, wparam: c.WPARAM, lparam: c.LPARAM) void {
    // Keys of the IME, and synthesized Unicode input, only produce text.
    if (wparam == c.VK_PROCESSKEY or wparam == c.VK_PACKET) return;

    self.setContext();
    const io: *ig.ImGuiIO = ig.ImGui_GetIO();

    const mods = currentMods();
    ig.ImGuiIO_AddKeyEvent(io, ig.ImGuiKey_LeftShift, mods.shift);
    ig.ImGuiIO_AddKeyEvent(io, ig.ImGuiKey_LeftCtrl, mods.ctrl);
    ig.ImGuiIO_AddKeyEvent(io, ig.ImGuiKey_LeftAlt, mods.alt);
    ig.ImGuiIO_AddKeyEvent(io, ig.ImGuiKey_LeftSuper, mods.super);

    if (physicalKey(@intCast(wparam), lparam).imguiKey()) |v| ig.ImGuiIO_AddKeyEvent(io, v, pressed);
    self.queueRender();
}

fn isDown(vk: c_int) bool {
    return c.GetKeyState(vk) < 0;
}

fn currentMods() input.Mods {
    return .{
        .shift = isDown(c.VK_SHIFT),
        .ctrl = isDown(c.VK_CONTROL),
        .alt = isDown(c.VK_MENU),
        .super = isDown(c.VK_LWIN) or isDown(c.VK_RWIN),
    };
}

/// The same lookup as Surface's: by scancode, not by the layout.
fn physicalKey(vk: u32, lparam: c.LPARAM) input.Key {
    const bits: usize = @bitCast(lparam);

    // With Num Lock off, the numpad sends navigation keys. Only the lack of
    // the extended flag tells these apart from the dedicated ones.
    if (bits & (1 << 24) == 0) switch (vk) {
        c.VK_CLEAR => return .numpad_begin,
        c.VK_PRIOR => return .numpad_page_up,
        c.VK_NEXT => return .numpad_page_down,
        c.VK_END => return .numpad_end,
        c.VK_HOME => return .numpad_home,
        c.VK_LEFT => return .numpad_left,
        c.VK_UP => return .numpad_up,
        c.VK_RIGHT => return .numpad_right,
        c.VK_DOWN => return .numpad_down,
        c.VK_INSERT => return .numpad_insert,
        c.VK_DELETE => return .numpad_delete,
        else => {},
    };

    const scancode: u32 = @intCast((bits >> 16) & 0xFF);
    const native = if (bits & (1 << 24) != 0) 0xE000 | scancode else scancode;
    for (input.keycodes.entries) |entry| {
        if (entry.native == native) return entry.key;
    }
    return .unidentified;
}
