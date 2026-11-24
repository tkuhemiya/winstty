//! The slice of the Win32 API used by this apprt. Declared by hand, like
//! os/windows.zig, rather than translating windows.h.
const std = @import("std");

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const BOOL = c_int;
pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HIMC = *opaque {};
pub const HANDLE = *anyopaque;
pub const HCURSOR = *opaque {};
pub const HICON = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMONITOR = *opaque {};
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;

pub const POINT = extern struct { x: c_int = 0, y: c_int = 0 };
pub const RECT = extern struct {
    left: c_int = 0,
    top: c_int = 0,
    right: c_int = 0,
    bottom: c_int = 0,
};
pub const MSG = extern struct {
    hwnd: ?HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
};
pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};
pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
};
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32 = 0,
};
pub const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    showCmd: u32 = 0,
    ptMinPosition: POINT = .{},
    ptMaxPosition: POINT = .{},
    rcNormalPosition: RECT = .{},
};
pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT = .{},
};

pub const CS_OWNDC = 0x20;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const GWL_STYLE = -16;
pub const GWLP_USERDATA = -21;
pub const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));
pub const HTCLIENT = 1;

pub const SW_HIDE = 0;
pub const SW_SHOWNORMAL = 1;
pub const SW_MAXIMIZE = 3;
pub const SW_SHOW = 5;
pub const SW_RESTORE = 9;
pub const SWP_NOSIZE = 0x1;
pub const SWP_NOMOVE = 0x2;
pub const SWP_NOZORDER = 0x4;
pub const SWP_NOACTIVATE = 0x10;
pub const SWP_FRAMECHANGED = 0x20;

pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_ACTIVATEAPP = 0x001C;
pub const WM_SETCURSOR = 0x0020;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_APP = 0x8000;

pub const SIZE_MINIMIZED = 1;
pub const TME_LEAVE = 2;

pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_CLEAR = 0x0C;
pub const VK_SPACE = 0x20;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_END = 0x23;
pub const VK_HOME = 0x24;
pub const VK_LEFT = 0x25;
pub const VK_UP = 0x26;
pub const VK_RIGHT = 0x27;
pub const VK_DOWN = 0x28;
pub const VK_INSERT = 0x2D;
pub const VK_DELETE = 0x2E;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_NUMLOCK = 0x90;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_PROCESSKEY = 0xE5;
pub const VK_PACKET = 0xE7;
pub const MAPVK_VK_TO_CHAR = 2;

pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 2;

pub const GCS_COMPSTR = 0x0008;
pub const GCS_RESULTSTR = 0x0800;
pub const CFS_POINT = 2;

pub const MB_OKCANCEL = 0x1;
pub const MB_ICONWARNING = 0x30;
pub const IDOK = 1;

pub const IDC_ARROW = 32512;
pub const IDC_IBEAM = 32513;
pub const IDC_WAIT = 32514;
pub const IDC_CROSS = 32515;
pub const IDC_SIZENWSE = 32642;
pub const IDC_SIZENESW = 32643;
pub const IDC_SIZEWE = 32644;
pub const IDC_SIZENS = 32645;
pub const IDC_SIZEALL = 32646;
pub const IDC_NO = 32648;
pub const IDC_HAND = 32649;
pub const IDC_APPSTARTING = 32650;
pub const IDC_HELP = 32651;

pub const MONITOR_DEFAULTTONEAREST = 2;
pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const HKEY_CURRENT_USER: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2147483647))));
pub const RRF_RT_REG_DWORD = 0x10;
pub const RRF_RT_REG_SZ = 0x2;
pub const KEY_READ = 0x20019;

pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalFree(HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalSize(HANDLE) callconv(.winapi) usize;
pub extern "kernel32" fn SetConsoleCtrlHandler(?*const anyopaque, BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
pub extern "advapi32" fn RegGetValueW(*anyopaque, [*:0]const u16, [*:0]const u16, u32, ?*u32, ?*anyopaque, ?*u32) callconv(.winapi) c_long;
pub extern "advapi32" fn RegOpenKeyExW(*anyopaque, [*:0]const u16, u32, u32, *?*anyopaque) callconv(.winapi) c_long;
pub extern "advapi32" fn RegEnumKeyExW(*anyopaque, u32, [*]u16, *u32, ?*u32, ?[*]u16, ?*u32, ?*anyopaque) callconv(.winapi) c_long;
pub extern "advapi32" fn RegCloseKey(*anyopaque) callconv(.winapi) c_long;
pub extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, c_int, c_int, c_int, c_int, ?HWND, ?*anyopaque, ?HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(?HWND, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(*RECT, u32, BOOL, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
pub extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) isize;
pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(HWND, *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(HWND, u32) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, usize) callconv(.winapi) ?HICON;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(c_int) callconv(.winapi) i16;
pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(u32, u32) callconv(.winapi) u32;
pub extern "user32" fn ToUnicode(u32, u32, *const [256]u8, [*]u16, c_int, u32) callconv(.winapi) c_int;
pub extern "user32" fn MessageBeep(u32) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(.winapi) c_int;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(u32, HANDLE) callconv(.winapi) ?HANDLE;

pub extern "imm32" fn ImmGetContext(HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(HWND, HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(HIMC, u32, ?*anyopaque, u32) callconv(.winapi) c_long;
pub extern "imm32" fn ImmSetCompositionWindow(HIMC, *const COMPOSITIONFORM) callconv(.winapi) BOOL;

pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, u32, *const anyopaque, u32) callconv(.winapi) c_long;
pub extern "shell32" fn ShellExecuteW(?HWND, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, c_int) callconv(.winapi) ?*anyopaque;

//---------------------------------------------------------------
// Windows, tabs and splits

pub const HGDIOBJ = *anyopaque;
pub const HFONT = *anyopaque;
pub const HBITMAP = *anyopaque;
pub const HMENU = *opaque {};
pub const COLORREF = u32;

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = @splat(0),
};
pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: c_int,
    biHeight: c_int,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: c_int = 0,
    biYPelsPerMeter: c_int = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};
pub const DWM_BLURBEHIND = extern struct {
    dwFlags: u32,
    fEnable: BOOL,
    hRgnBlur: ?*anyopaque = null,
    fTransitionOnMaximized: BOOL = 0,
};

pub const ACCENT_POLICY = extern struct {
    state: u32,
    flags: u32 = 0,
    color: u32 = 0,
    animation: u32 = 0,
};
pub const WINDOWCOMPOSITIONATTRIBDATA = extern struct {
    attribute: u32,
    data: *const anyopaque,
    size: usize,
};
pub const WCA_ACCENT_POLICY = 19;
pub const ACCENT_DISABLED = 0;
pub const ACCENT_ENABLE_BLURBEHIND = 3;

pub const CS_DBLCLKS = 0x8;
pub const WS_CHILD: u32 = 0x40000000;
pub const WS_POPUP: u32 = 0x80000000;
pub const WS_VISIBLE: u32 = 0x10000000;
pub const WS_CLIPSIBLINGS: u32 = 0x04000000;
pub const WS_CLIPCHILDREN: u32 = 0x02000000;
pub const WS_BORDER: u32 = 0x00800000;
pub const WS_EX_TOOLWINDOW: u32 = 0x80;

pub const SW_SHOWNA = 8;
pub const SWP_SHOWWINDOW = 0x40;
pub const SWP_HIDEWINDOW = 0x80;
pub const SWP_NOCOPYBITS = 0x100;

pub const WM_ACTIVATE = 0x0006;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_NCACTIVATE = 0x0086;
pub const WM_COMMAND = 0x0111;
pub const WM_SYSCOMMAND = 0x0112;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_RBUTTONDBLCLK = 0x0206;
pub const WM_MBUTTONDBLCLK = 0x0209;
pub const WM_XBUTTONDBLCLK = 0x020D;
pub const WM_CAPTURECHANGED = 0x0215;
pub const SC_KEYMENU = 0xF100;

pub const DT_CENTER = 0x1;
pub const DT_VCENTER = 0x4;
pub const DT_SINGLELINE = 0x20;
pub const DT_NOPREFIX = 0x800;
pub const DT_END_ELLIPSIS = 0x8000;
pub const TRANSPARENT = 1;
pub const SRCCOPY = 0x00CC0020;

pub const DWM_BB_ENABLE = 1;
pub const DWM_BB_BLURREGION = 2;
pub const DWMWA_CAPTION_COLOR = 35;
pub const DWMWA_TEXT_COLOR = 36;
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;
pub const DWMWA_COLOR_DEFAULT: u32 = 0xFFFFFFFF;

pub extern "kernel32" fn GetProcAddress(HINSTANCE, [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub const RDW_INVALIDATE = 0x1;
pub const RDW_ALLCHILDREN = 0x80;
pub extern "user32" fn RedrawWindow(HWND, ?*const RECT, ?*anyopaque, u32) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetParent(HWND, ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;
pub extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
pub extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetricsForDpi(c_int, u32) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(HDC, [*]const u16, c_int, *RECT, u32) callconv(.winapi) c_int;
pub extern "user32" fn FillRect(HDC, *const RECT, HGDIOBJ) callconv(.winapi) c_int;
pub extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFO, u32, *?*anyopaque, ?HANDLE, u32) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
pub extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(HDC, c_int, c_int, c_int, c_int, HDC, c_int, c_int, u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) COLORREF;
pub extern "gdi32" fn CreateFontW(c_int, c_int, c_int, c_int, c_int, u32, u32, u32, u32, u32, u32, u32, u32, [*:0]const u16) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn CreateRectRgn(c_int, c_int, c_int, c_int) callconv(.winapi) ?HGDIOBJ;
pub extern "dwmapi" fn DwmEnableBlurBehindWindow(HWND, *const DWM_BLURBEHIND) callconv(.winapi) c_long;

//---------------------------------------------------------------
// Search bar

pub const GWLP_WNDPROC = -4;
pub const GWLP_HWNDPARENT = -8;
pub const WM_SETFONT = 0x0030;
pub const WM_MOUSEACTIVATE = 0x0021;
pub const WM_NCDESTROY = 0x0082;
pub const WM_TIMER = 0x0113;
pub const WM_CTLCOLOREDIT = 0x0133;
pub const MA_ACTIVATE = 1;
pub const MA_NOACTIVATE = 3;
pub const EM_GETSEL = 0x00B0;
pub const EM_SETSEL = 0x00B1;
pub const EM_REPLACESEL = 0x00C2;
pub const EN_CHANGE = 0x0300;
pub const ES_AUTOHSCROLL = 0x80;
pub const VK_BACK = 0x08;
pub const VK_RETURN = 0x0D;
pub const VK_ESCAPE = 0x1B;
pub const DT_RIGHT = 0x2;
pub const DWMWA_WINDOW_CORNER_PREFERENCE = 33;
pub const DWMWCP_ROUNDSMALL: u32 = 3;

pub extern "user32" fn SetTimer(?HWND, usize, u32, ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
pub extern "user32" fn CallWindowProcW(WNDPROC, HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn SetActiveWindow(HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindowTextW(HWND, [*]u16, c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextLengthW(HWND) callconv(.winapi) c_int;
pub extern "gdi32" fn SetBkColor(HDC, COLORREF) callconv(.winapi) COLORREF;

//---------------------------------------------------------------
// Command palette

pub const EM_SETLIMITTEXT = 0x00C5;
pub const EM_SETCUEBANNER = 0x1501;
pub const WA_INACTIVE = 0;

pub const DT_LEFT = 0x0;
pub const DT_CALCRECT = 0x400;

pub const DWMWCP_ROUND: u32 = 2;

//---------------------------------------------------------------
// Inspector

pub const VK_F4 = 0x73;
pub const GL_COLOR_BUFFER_BIT = 0x4000;

pub extern "opengl32" fn glViewport(c_int, c_int, c_int, c_int) callconv(.winapi) void;
pub extern "opengl32" fn glClearColor(f32, f32, f32, f32) callconv(.winapi) void;
pub extern "opengl32" fn glClear(u32) callconv(.winapi) void;

//---------------------------------------------------------------
// Custom frame

pub const HTTRANSPARENT = -1;
pub const HTCAPTION = 2;
pub const HTMINBUTTON = 8;
pub const HTMAXBUTTON = 9;
pub const HTTOP = 12;
pub const HTCLOSE = 20;
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCLBUTTONDBLCLK = 0x00A3;
pub const WM_NCMOUSELEAVE = 0x02A2;
pub const TME_NONCLIENT = 0x10;
pub const SW_MINIMIZE = 6;
pub const GW_OWNER = 4;
pub const DWMWA_BORDER_COLOR = 34;
pub extern "user32" fn GetWindow(HWND, u32) callconv(.winapi) ?HWND;

//---------------------------------------------------------------
// Glass

pub const ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;
pub const WM_SYSCOLORCHANGE = 0x0015;
pub const WM_DISPLAYCHANGE = 0x007E;
pub const WM_POWERBROADCAST = 0x0218;
pub const WM_THEMECHANGED = 0x031A;
pub const SM_REMOTESESSION = 0x1000;
pub const SPI_GETHIGHCONTRAST = 0x0042;
pub const HCF_HIGHCONTRASTON = 1;
pub const GWL_EXSTYLE = -20;
pub const WS_EX_LAYERED: u32 = 0x80000;
pub const WS_EX_TRANSPARENT: u32 = 0x20;
pub const WS_EX_NOACTIVATE: u32 = 0x08000000;
pub const LWA_COLORKEY = 1;
pub const LWA_ALPHA = 2;

pub const HIGHCONTRASTW = extern struct {
    cbSize: u32 = @sizeOf(HIGHCONTRASTW),
    dwFlags: u32 = 0,
    lpszDefaultScheme: ?[*:0]u16 = null,
};
pub const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: u8 = 0,
    BatteryFlag: u8 = 0,
    BatteryLifePercent: u8 = 0,
    /// Whether battery saver is on.
    SystemStatusFlag: u8 = 0,
    BatteryLifeTime: u32 = 0,
    BatteryFullLifeTime: u32 = 0,
};
pub const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const GUID_POWER_SAVING_STATUS: GUID = .{
    .a = 0xE00958C0,
    .b = 0xC213,
    .c = 0x4ACE,
    .d = .{ 0xAC, 0x77, 0xFE, 0xCC, 0xED, 0x2E, 0xEE, 0xA5 },
};

pub extern "kernel32" fn GetSystemPowerStatus(*SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(c_int) callconv(.winapi) c_int;
pub extern "user32" fn SystemParametersInfoW(u32, u32, ?*anyopaque, u32) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterPowerSettingNotification(HWND, *const GUID, u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn UnregisterPowerSettingNotification(HANDLE) callconv(.winapi) BOOL;
pub extern "user32" fn SetLayeredWindowAttributes(HWND, COLORREF, u8, u32) callconv(.winapi) BOOL;

//---------------------------------------------------------------
// Motion

pub const SPI_GETCLIENTAREAANIMATION = 0x1042;
pub const SIZE = extern struct { cx: c_int = 0, cy: c_int = 0 };
pub const BLENDFUNCTION = extern struct {
    BlendOp: u8 = 0,
    BlendFlags: u8 = 0,
    SourceConstantAlpha: u8 = 255,
    AlphaFormat: u8 = 1,
};
pub const ULW_ALPHA = 2;

pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(HANDLE, u32) callconv(.winapi) u32;
pub extern "dwmapi" fn DwmFlush() callconv(.winapi) c_long;
pub extern "user32" fn SetWindowRgn(HWND, ?HGDIOBJ, BOOL) callconv(.winapi) c_int;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn EnableWindow(HWND, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateLayeredWindow(HWND, ?HDC, ?*const POINT, ?*const SIZE, ?HDC, ?*const POINT, COLORREF, ?*const BLENDFUNCTION, u32) callconv(.winapi) BOOL;

//---------------------------------------------------------------
// Side panel

pub const ICC_BAR_CLASSES = 0x4;
pub const TTS_ALWAYSTIP: u32 = 0x1;
pub const TTS_NOPREFIX: u32 = 0x2;
pub const TTF_SUBCLASS = 0x10;
pub const TTM_POP = 0x041C;
pub const TTM_ADDTOOLW = 0x0432;
pub const TTM_NEWTOOLRECTW = 0x0434;
pub const TTM_UPDATETIPTEXTW = 0x0439;

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: u32 = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: u32,
};
pub const TOOLINFOW = extern struct {
    cbSize: u32 = @sizeOf(TOOLINFOW),
    uFlags: u32 = 0,
    hwnd: ?HWND = null,
    uId: usize = 0,
    rect: RECT = .{},
    hinst: ?HINSTANCE = null,
    lpszText: ?[*:0]const u16 = null,
    lParam: LPARAM = 0,
    lpReserved: ?*anyopaque = null,
};
pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
