//! # zrame.window (Win32 backend) — a native decorated window
//!
//! The Windows counterpart to `window_wayland.zig`. Where the Wayland backend paints its
//! own glass chrome (rounded panel, drop shadow) into a transparent-margin buffer, on
//! Windows we let the OS draw the frame (title bar, min/max/close, resizable borders) and
//! fill the client area ourselves: the content frame the app presents, with zrame's panels
//! (floating scrollbars, right-click menu) composited on top, blitted through GDI.
//!
//! The public surface matches the Wayland backend exactly (see the facade `window.zig`),
//! so `sink.zig` and callers such as zuer-gui are backend-agnostic. Key/mouse/scroll
//! events are translated to the **same evdev codes / axis units** the Wayland path emits,
//! so `on_key`/`on_mouse`/`on_scroll` handlers are identical across platforms.
//!
//! Threading contract, same as Wayland: everything windowing happens on the thread that
//! calls `run`; `presentRgba` is the one cross-thread door — it stages pixels under a lock
//! and pokes the UI thread with a thread-safe `PostMessageW`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zicro = @import("zicro");
const paint = zicro.paint;
const text = zicro.text;

const facade = @import("window.zig");
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const menu = @import("menu.zig");
const scroll = @import("scroll.zig");

pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const Options = facade.Options;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;

// --- Win32 FFI ----------------------------------------------------------------------

const HWND = ?*anyopaque;
const HDC = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: HICON = null,
};

const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct {
    hwnd: HWND,
    message: u32,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32 = 0,
};
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};
const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: i32,
    rcPaint: RECT,
    fRestore: i32,
    fIncUpdate: i32,
    rgbReserved: [32]u8 = @splat(0),
};
const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32 = 0,
};
const WINDOWPLACEMENT = extern struct {
    length: u32 = @sizeOf(WINDOWPLACEMENT),
    flags: u32 = 0,
    showCmd: u32 = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HINSTANCE;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, ?[*:0]const u16, u32, i32, i32, i32, i32, HWND, ?*anyopaque, HINSTANCE, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(*MSG, HWND, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(HWND, u32, WPARAM, LPARAM) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn InvalidateRect(HWND, ?*const RECT, i32) callconv(.winapi) i32;
extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) i32;
extern "user32" fn GetDC(HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) i32;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "user32" fn GetWindowLongW(HWND, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowLongW(HWND, i32, i32) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(HWND, HWND, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn AdjustWindowRectEx(*RECT, u32, i32, u32) callconv(.winapi) i32;
extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
extern "user32" fn LoadCursorW(HINSTANCE, usize) callconv(.winapi) HCURSOR;
extern "user32" fn SetCursor(HCURSOR) callconv(.winapi) HCURSOR;
extern "user32" fn SetTimer(HWND, usize, u32, ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(HWND, usize) callconv(.winapi) i32;
extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) i32;
extern "user32" fn GetWindowPlacement(HWND, *WINDOWPLACEMENT) callconv(.winapi) i32;
extern "gdi32" fn SetDIBitsToDevice(HDC, i32, i32, u32, u32, i32, i32, u32, u32, ?*const anyopaque, *const BITMAPINFO, u32) callconv(.winapi) i32;

// Window/message constants.
const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_POPUP: u32 = 0x80000000;
const WS_VISIBLE: u32 = 0x10000000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const GWL_STYLE: i32 = -16;
const GWLP_USERDATA: i32 = -21;

const SW_MINIMIZE: i32 = 6;
const SW_MAXIMIZE: i32 = 3;
const SW_RESTORE: i32 = 9;
const SW_SHOWNORMAL: i32 = 1;
const SW_MAX_STATE: u32 = 3; // SW_SHOWMAXIMIZED value seen in WINDOWPLACEMENT.showCmd

const SWP_NOMOVE: u32 = 0x0002;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_FRAMECHANGED: u32 = 0x0020;
const SWP_SHOWWINDOW: u32 = 0x0040;

const WM_DESTROY: u32 = 0x0002;
const WM_SIZE: u32 = 0x0005;
const WM_PAINT: u32 = 0x000F;
const WM_CLOSE: u32 = 0x0010;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_KEYDOWN: u32 = 0x0100;
const WM_KEYUP: u32 = 0x0101;
const WM_MOUSEMOVE: u32 = 0x0200;
const WM_LBUTTONDOWN: u32 = 0x0201;
const WM_LBUTTONUP: u32 = 0x0202;
const WM_RBUTTONDOWN: u32 = 0x0204;
const WM_RBUTTONUP: u32 = 0x0205;
const WM_MOUSEWHEEL: u32 = 0x020A;
const WM_MOUSEHWHEEL: u32 = 0x020E;
const WM_MOUSELEAVE: u32 = 0x02A3;
const WM_TIMER: u32 = 0x0113;
const WM_APP_PRESENT: u32 = 0x8001; // WM_APP + 1: a freshly staged frame is ready

const IDC_ARROW: usize = 32512;
const TME_LEAVE: u32 = 0x00000002;
const ANIM_TIMER_ID: usize = 1;

// evdev button codes, matching the Wayland path (`BTN_LEFT`/`BTN_RIGHT`).
const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;

const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),
    fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const Staged = struct {
    pixels: std.ArrayList(u8) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    fresh: bool = false,
};

pub const Window = struct {
    gpa: Allocator,
    opts: Options,
    hwnd: HWND = null,

    /// Client-area size in pixels — the public geometry the app reads and presents into.
    panel_w: u32,
    panel_h: u32,
    closed: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    saved_style: u32 = 0,
    saved_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    tracking_leave: bool = false,

    panels: plugin.Registry,
    scrollbars: scroll.Scroll = .{ .follow_content = true },
    timer_armed: bool = false,
    last_tick_ms: u64 = 0,

    // Cross-thread frame mailbox (same shape as the Wayland backend): producers write
    // `staged` under the lock; the UI thread swaps it into `front` and composites.
    lock: SpinLock = .{},
    staged: Staged = .{},
    front: Staged = .{},
    // The composited, client-sized buffer we blit; kept so WM_PAINT can re-blit on expose.
    frame: []u32 = &.{},
    frame_w: u32 = 0,
    frame_h: u32 = 0,

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .panel_w = @max(opts.width, 160),
            .panel_h = @max(opts.height, 120),
            .panels = plugin.Registry.init(gpa),
        };

        const hinst = GetModuleHandleW(null);
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZrameWindowClass");
        const wc = WNDCLASSEXW{
            .style = 0x0003, // CS_HREDRAW | CS_VREDRAW
            .lpfnWndProc = wndProc,
            .hInstance = hinst,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = class_name,
        };
        _ = RegisterClassExW(&wc);

        // Native decorated, resizable window. Grow the outer rect so the *client* area is
        // panel_w×panel_h (AdjustWindowRectEx accounts for the frame + title bar).
        var rect = RECT{ .left = 0, .top = 0, .right = @intCast(self.panel_w), .bottom = @intCast(self.panel_h) };
        _ = AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, 0);
        const title = try toUtf16Z(gpa, opts.title);
        defer gpa.free(title);

        const hwnd = CreateWindowExW(
            0,
            class_name,
            title.ptr,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            hinst,
            self,
        ) orelse return error.WindowCreationFailed;
        self.hwnd = hwnd;

        // Floating scrollbars are the bottom-most panel (borrowed: the Window owns the
        // field instance, so the registry must not free it). Mirrors the Wayland backend.
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);
        if (opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        _ = ShowWindow(hwnd, SW_SHOWNORMAL);
        self.syncClientSize();
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.panels.deinit();
        if (self.font) |*f| f.deinit();
        if (self.frame.len > 0) self.gpa.free(self.frame);
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        if (self.hwnd) |h| _ = DestroyWindow(h);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// No compositor blur on GDI.
    pub fn hasBlur(_: *Window) bool {
        return false;
    }

    /// Stage a straight-alpha RGBA frame for presentation. Safe from any thread; newest
    /// frame wins. Wakes the UI thread with a thread-safe PostMessageW.
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        const need = @as(usize, width) * @as(usize, height) * 4;
        if (rgba.len < need) return;
        {
            self.lock.lock();
            defer self.lock.unlock();
            self.staged.pixels.clearRetainingCapacity();
            self.staged.pixels.appendSlice(self.gpa, rgba[0..need]) catch {
                self.staged.width = 0;
                self.staged.height = 0;
                self.staged.fresh = false;
                return;
            };
            self.staged.width = width;
            self.staged.height = height;
            self.staged.fresh = true;
        }
        _ = PostMessageW(self.hwnd, WM_APP_PRESENT, 0, 0);
    }

    /// dmabuf zero-copy present is a Linux/Wayland path; on Windows there is no equivalent,
    /// so callers fall back to `presentRgba`.
    pub fn presentDmabuf(_: *Window, _: u8, _: i32, _: u32, _: u32, _: u32, _: u32, _: u64) bool {
        return false;
    }

    pub fn videoBusy(_: *const Window) bool {
        return false;
    }

    /// The event loop: pumps Win32 messages until the window is closed.
    pub fn run(self: *Window) !void {
        var msg: MSG = undefined;
        while (!self.closed) {
            const r = GetMessageW(&msg, null, 0, 0);
            if (r == 0 or r == -1) break; // WM_QUIT or error
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }

    pub fn close(self: *Window) void {
        self.closed = true;
        _ = PostMessageW(self.hwnd, WM_CLOSE, 0, 0);
    }

    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
        self.requestRedraw();
    }

    pub fn toggleFullscreen(self: *Window) void {
        const h = self.hwnd orelse return;
        self.fullscreen = !self.fullscreen;
        if (self.fullscreen) {
            self.saved_style = @bitCast(GetWindowLongW(h, GWL_STYLE));
            _ = GetWindowRect(h, &self.saved_rect);
            _ = SetWindowLongW(h, GWL_STYLE, @bitCast(WS_POPUP | WS_VISIBLE));
            const sw = GetSystemMetrics(0); // SM_CXSCREEN
            const sh = GetSystemMetrics(1); // SM_CYSCREEN
            _ = SetWindowPos(h, null, 0, 0, sw, sh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        } else {
            _ = SetWindowLongW(h, GWL_STYLE, @bitCast(self.saved_style));
            const rw = self.saved_rect.right - self.saved_rect.left;
            const rh = self.saved_rect.bottom - self.saved_rect.top;
            _ = SetWindowPos(h, null, self.saved_rect.left, self.saved_rect.top, rw, rh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
        }
        self.syncClientSize();
    }

    /// Resize the window so its client area becomes `target_w`×`target_h`, keeping the
    /// top-left corner put. No-op in fullscreen/maximized. (The Wayland backend re-centers
    /// via the compositor; on Windows the app keeps its position.)
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        if (self.fullscreen or self.maximized) return;
        const h = self.hwnd orelse return;
        const tw = @max(target_w, 160);
        const th = @max(target_h, 120);
        if (tw == self.panel_w and th == self.panel_h) return;
        var rect = RECT{ .left = 0, .top = 0, .right = @intCast(tw), .bottom = @intCast(th) };
        const style: u32 = @bitCast(GetWindowLongW(h, GWL_STYLE));
        _ = AdjustWindowRectEx(&rect, style, 0, 0);
        _ = SetWindowPos(h, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, SWP_NOMOVE | SWP_NOZORDER);
        self.syncClientSize();
    }

    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }

    pub fn setFont(self: *Window, ttf: []const u8) !void {
        const f = try self.textFont();
        try f.setFace(.regular, ttf, false);
    }

    pub fn loadFont(self: *Window, path: []const u8) !void {
        const f = try self.textFont();
        try f.loadFace(.regular, path);
    }

    pub fn addPanel(self: *Window, panel: Panel, owned: bool) !void {
        try self.panels.add(panel, owned);
        self.requestRedraw();
    }

    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
        self.requestRedraw();
    }

    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        _ = try plugin.loadPlugin(&self.panels, path);
        self.requestRedraw();
    }

    pub fn loadPluginDir(self: *Window, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".dll")) continue;
            const full = std.fs.path.join(self.gpa, &.{ dir_path, ent.name }) catch continue;
            defer self.gpa.free(full);
            self.loadPlugin(full) catch |e| std.log.warn("zrame: plugin {s} failed to load: {}", .{ ent.name, e });
        }
    }

    // --- host seam (panels reach back into the window) --------------------------------

    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        const h = self.hwnd;
        switch (action) {
            .minimize => _ = ShowWindow(h, SW_MINIMIZE),
            .toggle_maximize => _ = ShowWindow(h, if (self.maximized) SW_RESTORE else SW_MAXIMIZE),
            .toggle_fullscreen => self.toggleFullscreen(),
            .close => self.close(),
            // Native borders/title bar already handle interactive move+resize; the panels
            // that request these are the CSD controls, unused with native decorations.
            .begin_move => {},
            .begin_resize => {},
            .set_cursor => {},
            .request_redraw => self.requestRedraw(),
        }
    }

    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return .{
            .content = self.contentRect(),
            .panel_w = self.panel_w,
            .panel_h = self.panel_h,
            .margin = 0, // no shadow gutter with native decorations
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }

    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    // --- geometry / drawing -----------------------------------------------------------

    /// With native decorations there is no client-side margin or title bar: the content
    /// rect is the whole client area.
    fn contentRect(self: *Window) Rect {
        return .{ .x = 0, .y = 0, .w = self.panel_w, .h = self.panel_h };
    }

    /// Pull the current client-area size from the OS into `panel_w`/`panel_h`.
    fn syncClientSize(self: *Window) void {
        const h = self.hwnd orelse return;
        var rc: RECT = undefined;
        if (GetClientRect(h, &rc) == 0) return;
        const w: u32 = @intCast(@max(rc.right - rc.left, 1));
        const ph: u32 = @intCast(@max(rc.bottom - rc.top, 1));
        self.panel_w = w;
        self.panel_h = ph;
        self.requestRedraw();
    }

    fn requestRedraw(self: *Window) void {
        if (self.hwnd) |h| _ = InvalidateRect(h, null, 0);
    }

    /// Composite one client-sized frame: opaque background, the app `on_draw` overlay, the
    /// newest staged content frame (buffer-swapped, lock held only for a few words), then
    /// the panels stack. Same composition order as the Wayland `composeFrame`.
    fn compose(self: *Window) void {
        const w = self.panel_w;
        const h = self.panel_h;
        const len = @as(usize, w) * h;
        if (self.frame_w != w or self.frame_h != h or self.frame.len != len) {
            const nf = self.gpa.alloc(u32, len) catch return;
            if (self.frame.len > 0) self.gpa.free(self.frame);
            self.frame = nf;
            self.frame_w = w;
            self.frame_h = h;
        }
        // Opaque background (the app content usually covers it; the border shows only
        // during a resize). ARGB8888, matching paint.Canvas / GDI 32bpp byte order.
        @memset(self.frame, 0xFF141414);
        var canvas = paint.Canvas.init(self.frame, w, h);

        if (self.opts.on_draw) |draw| draw(&canvas, self.contentRect(), self.opts.user);

        self.lock.lock();
        if (self.staged.fresh) {
            std.mem.swap(Staged, &self.staged, &self.front);
            self.staged.fresh = false;
        }
        self.lock.unlock();

        if (self.front.width > 0) {
            const content = self.contentRect();
            const fw = @min(self.front.width, content.w);
            const fh = @min(self.front.height, content.h);
            const dx = content.x + (content.w - fw) / 2;
            const dy = content.y + (content.h - fh) / 2;
            canvas.blitRgba(dx, dy, self.front.pixels.items, self.front.width, self.front.height, self.opts.style);
        }

        self.panels.draw(&canvas, self.host());
    }

    /// Blit the composed frame to the window via GDI (top-down DIB → SetDIBitsToDevice).
    fn blit(self: *Window, hdc: HDC) void {
        if (self.frame.len == 0) return;
        var bmi = BITMAPINFO{ .bmiHeader = .{
            .biWidth = @intCast(self.frame_w),
            .biHeight = -@as(i32, @intCast(self.frame_h)), // negative = top-down
            .biBitCount = 32,
        } };
        _ = SetDIBitsToDevice(hdc, 0, 0, self.frame_w, self.frame_h, 0, 0, 0, self.frame_h, self.frame.ptr, &bmi, 0);
    }

    fn composeAndBlit(self: *Window) void {
        self.compose();
        const hdc = GetDC(self.hwnd);
        defer _ = ReleaseDC(self.hwnd, hdc);
        self.blit(hdc);
    }

    // --- input / animation ------------------------------------------------------------

    fn routeInput(self: *Window, event: plugin.Event) bool {
        const consumed = self.panels.route(event, self.host());
        if (consumed) self.requestRedraw();
        self.armTimer();
        return consumed;
    }

    fn armTimer(self: *Window) void {
        if (self.timer_armed) return;
        _ = SetTimer(self.hwnd, ANIM_TIMER_ID, 16, null); // ~60 Hz
        self.timer_armed = true;
        self.last_tick_ms = GetTickCount64();
    }

    fn disarmTimer(self: *Window) void {
        if (!self.timer_armed) return;
        _ = KillTimer(self.hwnd, ANIM_TIMER_ID);
        self.timer_armed = false;
        self.last_tick_ms = 0;
    }

    fn onTimerTick(self: *Window) void {
        const now = GetTickCount64();
        const dt: f32 = if (self.last_tick_ms != 0)
            @min(@as(f32, @floatFromInt(now - self.last_tick_ms)) / 1000.0, 0.1)
        else
            0.016;
        self.last_tick_ms = now;
        const active = self.panels.tick(dt, self.host());
        self.composeAndBlit();
        if (!active) self.disarmTimer();
    }

    fn refreshMaximized(self: *Window) void {
        const h = self.hwnd orelse return;
        var wp = WINDOWPLACEMENT{};
        if (GetWindowPlacement(h, &wp) != 0) self.maximized = (wp.showCmd == SW_MAX_STATE);
    }

    // --- window procedure -------------------------------------------------------------

    fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
        // Stash the Window* delivered via CreateWindow's lpParam on WM_CREATE (0x0001).
        // lpCreateParams is the first field of CREATESTRUCTW on every ABI we target.
        if (msg == 0x0001) {
            const create: *const extern struct { lpCreateParams: ?*anyopaque } = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(create.lpCreateParams)));
        }

        const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        if (ptr == 0) return DefWindowProcW(hwnd, msg, wparam, lparam);
        const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));

        switch (msg) {
            WM_DESTROY => {
                self.closed = true;
                PostQuitMessage(0);
                return 0;
            },
            WM_CLOSE => {
                self.closed = true;
                PostQuitMessage(0);
                return 0;
            },
            WM_ERASEBKGND => return 1, // we paint every pixel; skip the flash-clear
            WM_SIZE => {
                self.refreshMaximized();
                self.syncClientSize();
                self.composeAndBlit();
                return 0;
            },
            WM_PAINT => {
                var ps: PAINTSTRUCT = undefined;
                const hdc = BeginPaint(hwnd, &ps);
                if (self.frame.len == 0) self.compose();
                self.blit(hdc);
                _ = EndPaint(hwnd, &ps);
                return 0;
            },
            WM_APP_PRESENT => {
                self.composeAndBlit();
                return 0;
            },
            WM_TIMER => {
                if (wparam == ANIM_TIMER_ID) self.onTimerTick();
                return 0;
            },
            WM_KEYDOWN, WM_KEYUP => {
                const pressed: u32 = if (msg == WM_KEYDOWN) 1 else 0;
                const key = mapVk(wparam);
                if (key != 0) {
                    if (self.routeInput(.{ .key = .{ .key = key, .pressed = pressed == 1 } })) return 0;
                    if (self.opts.on_key) |cb| cb(self, key, pressed, self.opts.user);
                }
                return 0;
            },
            WM_MOUSEMOVE => {
                const p = lparamPoint(lparam);
                self.pointer_x = p.x;
                self.pointer_y = p.y;
                if (!self.tracking_leave) {
                    var tme = TRACKMOUSEEVENT{ .dwFlags = TME_LEAVE, .hwndTrack = hwnd };
                    _ = TrackMouseEvent(&tme);
                    self.tracking_leave = true;
                }
                if (self.routeInput(.{ .motion = .{ .x = p.x, .y = p.y } })) return 0;
                if (self.opts.on_mouse) |cb| {
                    // Content-local coords: content rect starts at (0,0) here.
                    _ = cb(self, .{ .motion = .{ .x = p.x, .y = p.y } }, self.opts.user);
                }
                return 0;
            },
            WM_MOUSELEAVE => {
                self.tracking_leave = false;
                _ = self.routeInput(.leave);
                if (self.opts.on_mouse) |cb| _ = cb(self, .leave, self.opts.user);
                return 0;
            },
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP => {
                const is_left = (msg == WM_LBUTTONDOWN or msg == WM_LBUTTONUP);
                const pressed = (msg == WM_LBUTTONDOWN or msg == WM_RBUTTONDOWN);
                const button: u32 = if (is_left) BTN_LEFT else BTN_RIGHT;
                if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = button, .pressed = pressed } })) return 0;
                if (self.opts.on_mouse) |cb| _ = cb(self, .{ .button = .{ .button = button, .state = @intFromBool(pressed) } }, self.opts.user);
                return 0;
            },
            WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
                // Wheel delta is a signed i16 in the high word of wParam, in units of 120.
                const raw: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
                const notches = @as(f32, @floatFromInt(raw)) / 120.0;
                const axis: u32 = if (msg == WM_MOUSEHWHEEL) 1 else 0;
                // Match the Wayland axis-value scale (1/256 px units). Wheel-up (positive)
                // scrolls content up, i.e. a negative axis value, as on Wayland.
                const value: i32 = @intFromFloat(-notches * 40.0 * 256.0);
                if (self.routeInput(.{ .axis = .{ .x = self.pointer_x, .y = self.pointer_y, .axis = axis, .value = @as(f32, @floatFromInt(value)) / 256.0, .line = true } })) return 0;
                if (self.opts.on_scroll) |cb| cb(self, axis, value, self.opts.user);
                return 0;
            },
            else => return DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }
};

fn lparamPoint(lparam: LPARAM) struct { x: f32, y: f32 } {
    const lo: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) & 0xFFFF)));
    const hi: i16 = @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFFFF)));
    return .{ .x = @floatFromInt(lo), .y = @floatFromInt(hi) };
}

fn toUtf16Z(gpa: Allocator, s: [:0]const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s);
}

/// Translate a Win32 virtual-key code to the evdev keycode the Wayland path emits, so
/// `on_key` handlers are identical across platforms.
fn mapVk(vk: WPARAM) u32 {
    return switch (vk) {
        'A' => 30, 'B' => 48, 'C' => 46, 'D' => 32, 'E' => 18,
        'F' => 33, 'G' => 34, 'H' => 35, 'I' => 23, 'J' => 36,
        'K' => 37, 'L' => 38, 'M' => 50, 'N' => 49, 'O' => 24,
        'P' => 25, 'Q' => 16, 'R' => 19, 'S' => 31, 'T' => 20,
        'U' => 22, 'V' => 47, 'W' => 17, 'X' => 45, 'Y' => 21, 'Z' => 44,
        '1' => 2, '2' => 3, '3' => 4, '4' => 5, '5' => 6,
        '6' => 7, '7' => 8, '8' => 9, '9' => 10, '0' => 11,
        0x1B => 1, // VK_ESCAPE -> KEY_ESC
        0x20 => 57, // VK_SPACE
        0x0D => 28, // VK_RETURN -> KEY_ENTER
        0x08 => 14, // VK_BACK -> KEY_BACKSPACE
        0x09 => 15, // VK_TAB
        0x25 => 105, // VK_LEFT
        0x26 => 103, // VK_UP
        0x27 => 106, // VK_RIGHT
        0x28 => 108, // VK_DOWN
        0x21 => 104, // VK_PRIOR -> PAGEUP
        0x22 => 109, // VK_NEXT  -> PAGEDOWN
        0xBD => 12, // VK_OEM_MINUS
        0xBB => 13, // VK_OEM_PLUS (=)
        0x10, 0xA0 => 42, // VK_SHIFT / VK_LSHIFT -> KEY_LEFTSHIFT
        0xA1 => 54, // VK_RSHIFT
        0x11, 0xA2 => 29, // VK_CONTROL / VK_LCONTROL -> KEY_LEFTCTRL
        0xA3 => 97, // VK_RCONTROL
        else => 0,
    };
}
