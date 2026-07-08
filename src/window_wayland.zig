//! # zrame.window — the frameless glass window
//!
//! One Wayland toplevel, no server decorations: the chrome (rounded glass panel, drop
//! shadow) is painted client-side by [`paint`], the frosted look comes from the
//! compositor via `ext-background-effect-v1` (real background blur, KWin 6.4+), and the
//! shadow gutter is punched out of the input region so clicks fall through it.
//!
//! Threading contract: everything Wayland happens on the thread that calls [`run`].
//! [`presentRgba`] is the one cross-thread door — it stages pixels under a mutex and
//! pokes an eventfd, and the run loop picks them up. That is exactly the shape zicro's
//! `video.FrameSink` needs (see `sink.zig`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;

const zicro = @import("zicro");
const wl = zicro.wl;
const xkb = @import("xkb.zig");
const paint = zicro.paint;
const text = zicro.text;
const anim = zicro.anim;
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const menu = @import("menu.zig");
const scroll = @import("scroll.zig");
const tray_mod = @import("tray.zig");
const dbusmenu = @import("dbusmenu.zig");
const appmenu_mod = @import("appmenu.zig");

// Public window types (Options, MouseEvent, TrayConfig, Rect, Style, …) live in the
// facade `window.zig` so both backends share them and `*Window` in a callback resolves
// to the selected backend. This file (the Linux/Wayland backend) imports them so its
// existing code keeps referring to them by their short names.
const facade = @import("window.zig");
pub const Style = facade.Style;
pub const Panel = facade.Panel;
pub const Host = facade.Host;
pub const TitlebarStyle = facade.TitlebarStyle;
pub const Options = facade.Options;
pub const TrayConfig = facade.TrayConfig;
pub const MouseEvent = facade.MouseEvent;
pub const Rect = facade.Rect;

// The cross-thread frame mailbox and its composition are shared with the Win32 backend.
const chrome = @import("chrome.zig");
const Staged = chrome.Staged;

/// One pending dmabuf present (see `Window.presentDmabuf`).
const StagedDma = struct {
    slot: u8,
    fd: posix.fd_t,
    width: u32,
    height: u32,
    stride: u32,
    fourcc: u32,
    modifier: u64,
};

/// Zig 0.16 keeps blocking mutexes behind `std.Io`; the staging handoff is a short,
/// bounded copy at frame cadence, so a spin on the lock-free `std.atomic.Mutex` is
/// simpler than threading an `Io` through the window.
const SpinLock = chrome.SpinLock;

/// Best text flavor a clipboard offer advertises, in ascending preference (utf8 wins).
const TextMime = enum(u8) {
    none = 0,
    plain = 1,
    utf8_string = 2,
    utf8 = 3,

    fn mime(self: TextMime) [*:0]const u8 {
        return switch (self) {
            .utf8 => "text/plain;charset=utf-8",
            .utf8_string => "UTF8_STRING",
            .plain => "text/plain",
            .none => unreachable,
        };
    }
};

const BufferSlot = struct {
    buffer: ?*wl.Buffer = null,
    pixels: []u32 = &.{},
    busy: bool = false,
};

pub const Window = struct {
    gpa: Allocator,
    opts: Options,

    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    subcompositor: ?*wl.Subcompositor = null,
    dmabuf: ?*wl.LinuxDmabuf = null,
    wm_base: ?*wl.XdgWmBase = null,
    seat: ?*wl.Seat = null,
    blur_manager: ?*wl.BackgroundEffectManager = null,
    cursor_shapes: ?*wl.CursorShapeManager = null,
    viewporter: ?*wl.Viewporter = null,
    fractional_manager: ?*wl.FractionalScaleManager = null,
    data_device_manager: ?*wl.DataDeviceManager = null,

    surface: ?*wl.Surface = null,
    xdg_surface: ?*wl.XdgSurface = null,
    toplevel: ?*wl.XdgToplevel = null,
    blur: ?*wl.BackgroundEffectSurface = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    touch: ?*wl.Touch = null,
    /// Slot del dito primario attivo (`-1` = nessuno): il touch a un dito è sintetizzato
    /// come pointer, così le app funzionano al tocco senza modifiche.
    touch_id: i32 = -1,
    cursor_device: ?*wl.CursorShapeDevice = null,
    // HiDPI: with both globals present the buffer is rendered at `logical × scale`
    // physical pixels and presented at logical size through the viewport — crisp on
    // fractionally scaled outputs. Without them scale stays 1.0 (previous behavior).
    viewport: ?*wl.Viewport = null,
    fractional: ?*wl.FractionalScale = null,
    /// Compositor-preferred surface scale in 120ths (`wp_fractional_scale_v1`): 120 = 1.0.
    scale120: u32 = 120,

    /// Panel (window-geometry) size; buffer size adds the shadow margin on each side.
    panel_w: u32,
    panel_h: u32,
    configured: bool = false,
    needs_redraw: bool = false,
    // Resize richiesto da un altro thread (protetto da `mutex`): le operazioni
    // sulla surface Wayland NON sono thread-safe, quindi `requestResize` deposita
    // solo il target e il run loop chiama `animateResize` sul thread finestra.
    pending_resize: ?[2]u32 = null,
    // True once `run` is pumping. Before that (init roundtrips) `onXdgConfigure` must
    // redraw synchronously to map the window; during the loop it only flags a redraw so
    // a burst of resize configures coalesces into one paint per iteration.
    running: bool = false,
    /// Wall-clock ms of the last overlay-triggered parent repaint, to cap it (see
    /// the run loop): a HUD over a dmabuf video must not repaint at video rate.
    last_overlay_ms: i64 = 0,
    closed: bool = false,
    // Stato fullscreen: in fullscreen il gutter/ombra/angoli vengono azzerati
    // così il contenuto riempie lo schermo; i valori originali si ripristinano
    // all'uscita insieme alla dimensione del pannello a finestra.
    fullscreen: bool = false,
    saved_panel_w: u32 = 0,
    saved_panel_h: u32 = 0,
    saved_margin: u32 = 0,
    saved_radius: f32 = 0,
    saved_content_radius: f32 = 0,
    // Motore di testo (stb_truetype), creato pigramente al primo uso: font di
    // default Hack regular+bold, sostituibile con `setFont`/`loadFont`.
    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    /// Latest pointer input serial (enter/button), needed by interactive move/resize and
    /// cursor-shape requests, which the compositor authenticates against a recent serial.
    pointer_serial: u32 = 0,
    /// Cursor shape currently requested, so repeated motion doesn't re-issue set_shape.
    cursor_shape: u32 = wl.CursorShapeDevice.SHAPE_DEFAULT,
    // Stato massimizzato, come per il fullscreen: rilevato dagli stati del configure,
    // pilota l'icona massimizza/ripristina dei controlli.
    maximized: bool = false,

    // --- keyboard layout translation (xkbcommon) --------------------------------------
    // Built from the compositor's `wl_keyboard.keymap` fd; a new keymap (layout switch)
    // replaces all three. Null when setup failed → `on_text` simply never fires.
    xkb_context: ?*xkb.Context = null,
    xkb_keymap: ?*xkb.Keymap = null,
    xkb_state: ?*xkb.State = null,

    // --- clipboard (wl_data_device selection) -----------------------------------------
    /// Latest keyboard/pointer-button input serial: `set_selection` must be
    /// authenticated against a recent input event, exactly like move/resize.
    input_serial: u32 = 0,
    data_device: ?*wl.DataDevice = null,
    /// Our outstanding selection source; non-null == WE own the clipboard. Cleared by
    /// the `cancelled` event when another client takes the selection over.
    data_source: ?*wl.DataSource = null,
    /// Window-owned copy of the text behind `data_source` (served in `send`).
    clip_text: []u8 = &.{},
    /// Offer introduced by the last `data_offer` event, still collecting mime types;
    /// `selection` (or a DnD `enter` we ignore) will designate it.
    pending_offer: ?*wl.DataOffer = null,
    pending_mime: TextMime = .none,
    /// The current clipboard content offer (null = empty clipboard), and the best text
    /// mime it advertised.
    selection_offer: ?*wl.DataOffer = null,
    selection_mime: TextMime = .none,

    // Panels (title-bar controls, context menu, scrollbars, dlopen plugins) draw over the
    // content, receive input before the app callbacks, and animate off a shared clock.
    panels: plugin.Registry,
    // Floating egui-style scrollbars, auto-mounted on every window as the bottom-most
    // panel. Dormant (invisible) until the app reports its content size via
    // `win.scrollbars.setContent(w, h)`; the viewport tracks the content rect for free.
    scrollbars: scroll.Scroll = .{ .follow_content = true },
    // timerfd che batte l'orologio d'animazione: armato (~60 Hz) mentre un pannello si
    // anima, disarmato quando tutto si è assestato così `poll` torna a bloccarsi a riposo.
    timer_fd: posix.fd_t = -1,
    timer_armed: bool = false,
    last_tick_ns: i64 = 0,
    // Dimensione massima utile della geometria finestra suggerita dal compositore
    // (xdg_toplevel.configure_bounds): l'area dello schermo meno pannelli/riserve.
    // 0 = non nota. Vincola i ridimensionamenti così la finestra non sborda oltre
    // lo schermo (in particolare sotto). Il client non può posizionarsi da sé su
    // Wayland — il compositore piazza (e di norma centra) la finestra.
    bounds_w: u32 = 0,
    bounds_h: u32 = 0,
    // Optional StatusNotifierItem tray connection; created in `run` when `opts.tray` is set,
    // its bus fd is polled alongside Wayland. Null when no tray or registration failed.
    tray: ?*tray_mod.Tray = null,
    // Optional KDE global menu: the com.canonical.dbusmenu server plus the Wayland
    // appmenu object that tells KWin where to find it. Bus fd polled alongside Wayland.
    menu: ?*dbusmenu.Server = null,
    appmenu_manager: ?*appmenu_mod.Manager = null,
    appmenu_obj: ?*appmenu_mod.Appmenu = null,
    // Open handles of `dlopen`'d plugin `.so`s. Closed after `panels.deinit` in `deinit`,
    // because the panels' `deinit` code lives inside these libraries.
    plugin_libs: std.ArrayList(std.DynLib) = .empty,

    // wl_shm double buffer, one pool + mapping shared by both slots.
    shm_fd: posix.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    pool: ?*wl.ShmPool = null,
    // Bytes backing `pool`/`shm_map`. Kept over-allocated so a resize only re-slices the
    // two buffers instead of tearing down the memfd/mmap/pool every frame; grown (with
    // headroom) only when the needed size exceeds it.
    pool_cap: usize = 0,
    slots: [2]BufferSlot = .{ .{}, .{} },
    buf_w: u32 = 0,
    buf_h: u32 = 0,

    /// Chrome painted once per resize, memcpy'd under every frame.
    decor: []u32 = &.{},

    // Cross-thread frame mailbox: producers write `staged` under the lock, `redraw`
    // swaps it into `front` (window-thread-only) so the blit runs unlocked.
    mutex: SpinLock = .{},
    staged: Staged = .{},
    front: Staged = .{},
    wake_fd: posix.fd_t,

    // The zero-copy video path: GPU frames arrive as dmabufs and go to a
    // desynced subsurface over the content area — no CPU pixels involved.
    // `staged_dma` is the cross-thread mailbox (same wake fd as `staged`);
    // wl_buffers are created once per slot and reused every frame.
    video_surface: ?*wl.Surface = null,
    video_subsurface: ?*wl.Subsurface = null,
    // 8 slots: enough for a few resolution tiers × double buffering.
    video_buffers: [8]?*wl.Buffer = @splat(null),
    staged_dma: ?StagedDma = null,
    /// True while a frame callback is outstanding on the video surface: the
    /// compositor has not yet consumed the last commit. Producers poll
    /// `videoBusy` to pace themselves to the refresh rate instead of
    /// free-running (mailbox semantics: staging while busy replaces).
    video_pending: std.atomic.Value(bool) = .init(false),

    // --- attesa vsync (`waitFrame`) -----------------------------------------------
    // Contatore dei frame callback del compositor sulla surface principale: il
    // dispatch (thread finestra) lo incrementa e sveglia i waiter via futex; i
    // chiamanti di `waitFrame` dormono in FUTEX_WAIT proprio su questo indirizzo.
    // (Zig 0.16 tiene mutex/condvar bloccanti dietro `std.Io`, vedi `SpinLock`:
    // per un'attesa bloccante con timeout il futex raw è la primitiva giusta qui,
    // e questo backend è comunque solo-Linux.)
    frame_seq: std.atomic.Value(u32) = .init(0),
    /// Solo thread finestra: true mentre un `wl_surface.frame` è in volo sulla
    /// surface principale (al massimo un callback pendente per volta, richiesto
    /// insieme al commit in `redraw`).
    frame_cb_pending: bool = false,
    /// Alzato al teardown (uscita dal run loop o `deinit`): i waiter vengono
    /// svegliati e `waitFrame` ritorna false invece di aspettare un callback che
    /// non arriverà più.
    frame_teardown: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const display = wl.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        errdefer wl.wl_display_disconnect(display);

        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        const wake_fd: posix.fd_t = @intCast(efd);
        errdefer _ = linux.close(wake_fd);

        const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
        if (linux.errno(tfd) != .SUCCESS) return error.TimerFdFailed;
        const timer_fd: posix.fd_t = @intCast(tfd);
        errdefer _ = linux.close(timer_fd);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .opts = opts,
            .display = display,
            .registry = wl.displayGetRegistry(display),
            .panel_w = opts.width,
            .panel_h = opts.height,
            .wake_fd = wake_fd,
            .timer_fd = timer_fd,
            .panels = plugin.Registry.init(gpa),
        };
        self.panel_w = @max(self.panel_w, self.minPanel());
        self.panel_h = @max(self.panel_h, self.minPanel());

        self.registry.setListener(&registry_listener, self);
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        if (self.compositor == null or self.shm == null or self.wm_base == null)
            return error.MissingWaylandGlobals;

        self.wm_base.?.setListener(&wm_base_listener, self);

        // Clipboard endpoint: needs both the manager and the seat from the same
        // registry burst. Absent either (bare compositor), clipboardSet/Get degrade
        // to no-ops/null.
        if (self.data_device_manager) |ddm| {
            if (self.seat) |seat| {
                const dev = ddm.getDataDevice(seat);
                dev.setListener(&data_device_listener, self);
                self.data_device = dev;
            }
        }

        const surface = self.compositor.?.createSurface();
        self.surface = surface;
        const xdg_surface = self.wm_base.?.getXdgSurface(surface);
        xdg_surface.setListener(&xdg_surface_listener, self);
        self.xdg_surface = xdg_surface;
        const toplevel = xdg_surface.getToplevel();
        toplevel.setListener(&toplevel_listener, self);
        toplevel.setTitle(opts.title.ptr);
        toplevel.setAppId(opts.app_id.ptr);
        const min: i32 = @intCast(self.minPanel());
        toplevel.setMinSize(min, min);
        self.toplevel = toplevel;

        if (self.blur_manager) |mgr| self.blur = mgr.getBackgroundEffect(surface);

        // Fractional HiDPI needs BOTH: the scale preference and the viewport that maps
        // the physically-sized buffer back to the logical window size.
        if (self.viewporter != null and self.fractional_manager != null) {
            self.viewport = self.viewporter.?.getViewport(surface);
            self.fractional = self.fractional_manager.?.getFractionalScale(surface);
            self.fractional.?.setListener(&fractional_listener, self);
        }

        // Floating scrollbars are the bottom-most panel: the title bar and context menu
        // draw over them and grab input first. Borrowed — the Window owns the instance
        // (as a field), so the registry must not deinit/free it.
        try self.panels.add(Panel.of(scroll.Scroll, &self.scrollbars), false);

        // Register the built-in title-bar controls next, then the context menu on top of
        // it so the menu draws over the bar and grabs input first.
        if (opts.titlebar) {
            const c = try controls.Controls.create(gpa, opts.titlebar_style, opts.titlebar_height, opts.title);
            try self.panels.add(Panel.of(controls.Controls, c), true);
        }
        if (opts.context_menu) {
            const mnu = try menu.Menu.create(gpa);
            try self.panels.add(Panel.of(menu.Menu, mnu), true);
        }

        // First commit carries no buffer; the compositor answers with configure and
        // only then may we attach pixels.
        surface.commit();
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        return self;
    }

    pub fn deinit(self: *Window) void {
        // Cintura di sicurezza per chi non è mai entrato in `run`: segna il
        // teardown e sveglia eventuali waiter di `waitFrame` PRIMA di smontare.
        // (Il contratto resta: i thread che chiamano waitFrame vanno joinati
        // prima di deinit — qui si riduce solo la finestra di corsa.)
        self.frame_teardown.store(true, .release);
        self.wakeFrameWaiters();
        if (self.appmenu_obj) |o| o.release();
        if (self.menu) |mnu| mnu.deinit();
        if (self.tray) |t| t.deinit();
        // Panels first (runs plugin `deinit`s), then unload the libraries that hold them.
        self.panels.deinit();
        for (self.plugin_libs.items) |*lib| lib.close();
        self.plugin_libs.deinit(self.gpa);
        self.dropBuffers();
        if (self.font) |*f| f.deinit();
        if (self.decor.len > 0) self.gpa.free(self.decor);
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        for (self.video_buffers) |vb| {
            if (vb) |b| b.destroy();
        }
        if (self.video_subsurface) |ss| ss.destroy();
        if (self.video_surface) |vs| vs.destroy();
        if (self.data_source) |s| s.destroy();
        if (self.pending_offer) |o| {
            if (o != self.selection_offer) o.destroy();
        }
        if (self.selection_offer) |o| o.destroy();
        if (self.data_device) |d| d.release();
        if (self.clip_text.len > 0) self.gpa.free(self.clip_text);
        if (self.xkb_state) |st| xkb.xkb_state_unref(st);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        if (self.xkb_context) |ctx| xkb.xkb_context_unref(ctx);
        if (self.fractional) |f| wl.wl_proxy_destroy(@ptrCast(f));
        if (self.viewport) |v| wl.wl_proxy_destroy(@ptrCast(v));
        if (self.blur) |b| wl.wl_proxy_destroy(@ptrCast(b));
        if (self.cursor_device) |c| wl.wl_proxy_destroy(@ptrCast(c));
        if (self.keyboard) |k| wl.wl_proxy_destroy(@ptrCast(k));
        if (self.pointer) |p| wl.wl_proxy_destroy(@ptrCast(p));
        if (self.toplevel) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |x| wl.wl_proxy_destroy(@ptrCast(x));
        if (self.surface) |s| s.destroy();
        wl.wl_display_disconnect(self.display);
        _ = linux.close(self.wake_fd);
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// True once the compositor granted background blur.
    pub fn hasBlur(self: *Window) bool {
        return self.blur != null;
    }

    /// Stage a straight-alpha RGBA frame for presentation. Safe from any thread; the
    /// newest frame wins (latest-value semantics, same spirit as zicro's media plane).
    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        if (chrome.stageFrame(self.gpa, &self.mutex, &self.staged, width, height, rgba)) {
            const one: u64 = 1;
            _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
        }
    }

    /// Richiede un resize della finestra da un thread qualsiasi. Deposita il
    /// target e sveglia il run loop, che eseguirà `animateResize` sul thread
    /// finestra: le operazioni sulla surface Wayland (attach/commit) non sono
    /// thread-safe e chiamarle da un worker durante `run` corrompe il protocollo
    /// (es. `xdg_surface: attached a buffer before configure`).
    pub fn requestResize(self: *Window, width: u32, height: u32) void {
        self.mutex.lock();
        self.pending_resize = .{ width, height };
        self.mutex.unlock();
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
    }

    /// Present a GPU frame with zero CPU pixel work: `fd` is a dmabuf export
    /// of the frame image (`fourcc`/`stride`/`modifier` as the exporter
    /// reports them). `slot` (0..2) identifies a persistent image the caller
    /// re-renders into; its wl_buffer is created once and reused. Returns
    /// false when the compositor lacks linux-dmabuf/subcompositor support —
    /// fall back to `presentRgba`. Thread-safe, same mailbox as `presentRgba`.
    pub fn presentDmabuf(self: *Window, slot: u8, fd: posix.fd_t, width: u32, height: u32, stride: u32, fourcc: u32, modifier: u64) bool {
        if (self.dmabuf == null or self.subcompositor == null) return false;
        std.debug.assert(slot < self.video_buffers.len);
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.staged_dma = .{
                .slot = slot,
                .fd = fd,
                .width = width,
                .height = height,
                .stride = stride,
                .fourcc = fourcc,
                .modifier = modifier,
            };
        }
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
        return true;
    }

    /// Window-thread half of `presentDmabuf`: build the subsurface/buffers
    /// lazily, then attach + commit the requested slot. Returns true when a
    /// staged frame was committed (so the caller can refresh a client overlay).
    fn processVideo(self: *Window) bool {
        self.mutex.lock();
        const req_opt = self.staged_dma;
        self.staged_dma = null;
        self.mutex.unlock();
        const req = req_opt orelse return false;
        if (!self.configured) return false;

        if (self.video_surface == null) {
            const vs = self.compositor.?.createSurface();
            // Input passes through to the glass parent (drag/keys still work).
            const empty = self.compositor.?.createRegion();
            vs.setInputRegion(empty);
            empty.destroy();
            const ss = self.subcompositor.?.getSubsurface(vs, self.surface.?);
            ss.setDesync();
            self.video_surface = vs;
            self.video_subsurface = ss;
            // Mapping and position are parent state: one chrome commit seals them.
            self.needs_redraw = true;
        }
        const content = self.contentRect();
        const dx = content.x + (content.w -| @min(req.width, content.w)) / 2;
        const dy = content.y + (content.h -| @min(req.height, content.h)) / 2;
        self.video_subsurface.?.setPosition(@intCast(dx), @intCast(dy));

        if (self.video_buffers[req.slot] == null) {
            const params = self.dmabuf.?.createParams();
            params.add(req.fd, 0, 0, req.stride, req.modifier);
            self.video_buffers[req.slot] = params.createImmed(
                @intCast(req.width),
                @intCast(req.height),
                req.fourcc,
                0,
            );
            params.destroy();
        }
        const vs = self.video_surface.?;
        vs.attach(self.video_buffers[req.slot], 0, 0);
        vs.damageBuffer(0, 0, @intCast(req.width), @intCast(req.height));
        // Refresh pacing: one frame callback per commit; producers that honor
        // `videoBusy` settle at the compositor's cadence.
        self.video_pending.store(true, .release);
        const cb = vs.frame();
        cb.setListener(&video_frame_listener, self);
        vs.commit();
        return true;
    }

    const video_frame_listener = wl.Callback.Listener{ .done = onVideoFrameDone };

    fn onVideoFrameDone(data: ?*anyopaque, callback: *wl.Callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        callback.destroy();
        self.video_pending.store(false, .release);
    }

    /// True while the compositor still owes a frame-done for the last video
    /// commit — render the next frame when this turns false to run at the
    /// refresh rate instead of burning frames nobody sees.
    pub fn videoBusy(self: *const Window) bool {
        return self.video_pending.load(.acquire);
    }

    /// Blocca il thread chiamante (uno QUALSIASI, tipicamente il render worker
    /// dell'app) fino al prossimo frame callback del compositor — il momento
    /// giusto per comporre il frame successivo — o fino a `timeout_ms`.
    /// Ritorna `true` se svegliato dal callback, `false` su timeout o a
    /// finestra chiusa/in teardown (il chiamante degrada al proprio pacer).
    ///
    /// Contratto:
    /// - Il callback viene richiesto solo quando `redraw` committa davvero un
    ///   frame: senza commit dall'ultimo callback (es. video in pausa) o con la
    ///   finestra nascosta/occlusa (i compositor fermano i frame callback)
    ///   l'attesa scade col timeout — è la rete di sicurezza, non un errore.
    /// - Più waiter contemporanei sono ammessi (il risveglio è broadcast).
    /// - Alla chiusura della finestra i waiter vengono svegliati e ricevono
    ///   `false`; il chiamante deve essere uscito da `waitFrame` (cioè il suo
    ///   thread raggiunto/joinato) prima di chiamare `deinit`.
    /// - Su Win32 il metodo omologo ritorna sempre subito `false` (nessun
    ///   aggancio vsync): lì il chiamante usa il suo pacer software.
    pub fn waitFrame(self: *Window, timeout_ms: u32) bool {
        if (self.frame_teardown.load(.acquire)) return false;
        const start = self.frame_seq.load(.acquire);
        const deadline = monotonicNs() + @as(i64, timeout_ms) * 1_000_000;
        while (true) {
            const now = monotonicNs();
            if (now >= deadline) return false;
            const left: u64 = @intCast(deadline - now);
            const ts: linux.timespec = .{
                .sec = @intCast(left / 1_000_000_000),
                .nsec = @intCast(left % 1_000_000_000),
            };
            // FUTEX_WAIT dorme solo se `frame_seq` vale ancora `start`: un
            // callback arrivato tra la load e la wait fa fallire la wait con
            // EAGAIN — niente lost wake-up. Timeout relativo, clock monotonico.
            const rc = linux.futex_4arg(
                &self.frame_seq.raw,
                .{ .cmd = .WAIT, .private = true },
                start,
                &ts,
            );
            switch (linux.errno(rc)) {
                .SUCCESS, .AGAIN, .INTR => {},
                else => return false, // TIMEDOUT o errore inatteso
            }
            if (self.frame_teardown.load(.acquire)) return false;
            if (self.frame_seq.load(.acquire) != start) return true;
            // Risveglio spurio/EINTR: il tempo rimasto si ricalcola e si riprova.
        }
    }

    /// Sveglia in broadcast tutti i thread fermi in `waitFrame` (store già fatto
    /// dal chiamante: qui solo la syscall di wake).
    fn wakeFrameWaiters(self: *Window) void {
        _ = linux.futex_3arg(
            &self.frame_seq.raw,
            .{ .cmd = .WAKE, .private = true },
            std.math.maxInt(i32),
        );
    }

    const frame_done_listener = wl.Callback.Listener{ .done = onFrameDone };

    /// Frame callback della surface principale (dispatch sul thread finestra):
    /// SOLO store + wake, nessun lavoro pesante nel dispatch Wayland.
    fn onFrameDone(data: ?*anyopaque, callback: *wl.Callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        callback.destroy();
        self.frame_cb_pending = false;
        _ = self.frame_seq.fetchAdd(1, .release);
        self.wakeFrameWaiters();
    }

    /// The event loop: blocks until the window is closed or the connection drops.
    pub fn run(self: *Window) !void {
        self.running = true;
        // All'uscita dal loop (chiusura o errore di connessione) nessun frame
        // callback arriverà più: sveglia chi è fermo in `waitFrame`, che così
        // ritorna false e lascia terminare il proprio thread.
        defer {
            self.frame_teardown.store(true, .release);
            self.wakeFrameWaiters();
        }
        // Bring up the tray icon once, if requested. Registration failure (no tray host on
        // the bus) is non-fatal: log and run without it.
        if (self.tray == null) {
            if (self.opts.tray) |tc| {
                self.tray = tray_mod.Tray.init(self.gpa, .{
                    .id = tc.id,
                    .title = tc.title,
                    .icon_name = tc.icon_name,
                    .tooltip = tc.tooltip,
                    .on_activate = onTrayActivate,
                    .ctx = self,
                }) catch |err| blk: {
                    std.log.warn("zrame: tray icon unavailable ({s})", .{@errorName(err)});
                    break :blk null;
                };
            }
        }

        // Bring up the KDE global menu once: export the dbusmenu on the session bus, then
        // tell KWin its address over the appmenu Wayland protocol. Any failure is non-fatal.
        if (self.menu == null) {
            if (self.opts.menu) |items| self.setupMenu(items);
        }

        while (!self.closed) {
            while (wl.wl_display_prepare_read(self.display) != 0) {
                if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            }
            _ = wl.wl_display_flush(self.display);
            if (self.tray) |t| t.flush();
            if (self.menu) |mnu| mnu.flush();

            var fds = [_]posix.pollfd{
                .{ .fd = wl.wl_display_get_fd(self.display), .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.timer_fd, .events = posix.POLL.IN, .revents = 0 },
                // Negative fd = ignored by poll, so these slots are inert when absent.
                .{ .fd = if (self.tray) |t| t.fd() else -1, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (self.menu) |mnu| mnu.fd() else -1, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch |err| {
                wl.wl_display_cancel_read(self.display);
                return err;
            };

            if (fds[0].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) {
                if (wl.wl_display_read_events(self.display) < 0) return error.WaylandIo;
            } else {
                wl.wl_display_cancel_read(self.display);
            }
            if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return error.WaylandIo;

            if (fds[1].revents & posix.POLL.IN != 0) {
                var drained: u64 = 0;
                _ = posix.read(self.wake_fd, std.mem.asBytes(&drained)) catch {};
                // A staged shm frame needs the full chrome redraw. A dmabuf frame
                // commits its own subsurface; when the client draws an overlay
                // (`on_draw` — e.g. a live HUD) the parent must repaint too, or the
                // overlay freezes on its first paint while the video keeps moving.
                const had_video = self.processVideo();
                self.mutex.lock();
                const has_frame = self.staged.fresh;
                self.mutex.unlock();
                if (has_frame) {
                    self.needs_redraw = true;
                } else if (had_video and self.opts.on_draw != null) {
                    // Cap the overlay repaint at ~15 Hz. Repainting the whole parent
                    // at video rate saturates this thread — which also dispatches
                    // input — making input lag badly under interaction. A HUD reads
                    // fine at 15 Hz; the video keeps its own (full-rate) subsurface.
                    var ts: linux.timespec = undefined;
                    _ = linux.clock_gettime(.MONOTONIC, &ts);
                    const now_ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
                    if (now_ms - self.last_overlay_ms >= 66) {
                        self.last_overlay_ms = now_ms;
                        self.needs_redraw = true;
                    }
                }
            }

            if (fds[2].revents & posix.POLL.IN != 0) self.onTimerTick();

            if (self.tray) |t| {
                if (fds[3].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) t.process();
            }
            if (self.menu) |mnu| {
                if (fds[4].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) mnu.process();
            }

            // Resize richiesto da un altro thread: eseguilo QUI, sul thread
            // finestra, prima del redraw (le surface Wayland non sono thread-safe).
            self.mutex.lock();
            const rr = self.pending_resize;
            self.pending_resize = null;
            self.mutex.unlock();
            if (rr) |wh| self.animateResize(wh[0], wh[1]);

            if (self.configured and self.needs_redraw) try self.redraw();
        }
    }

    /// sd-bus `Activate` trampoline: recover the window from the tray's ctx and forward to
    /// the caller's `on_activate` (see `TrayConfig`).
    fn onTrayActivate(ctx: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        if (self.opts.tray) |tc| {
            if (tc.on_activate) |cb| cb(self, self.opts.user);
        }
    }

    const menu_object_path = "/MenuBar";

    /// Export the global menu on the bus and publish its address to KWin.
    fn setupMenu(self: *Window, items: []const dbusmenu.Item) void {
        const server = dbusmenu.Server.init(self.gpa, .{
            .items = items,
            .object_path = menu_object_path,
            .ctx = self.opts.user,
        }) catch |err| {
            std.log.warn("zrame: global menu unavailable ({s})", .{@errorName(err)});
            return;
        };
        self.menu = server;

        const mgr = self.appmenu_manager orelse {
            std.log.warn("zrame: compositor has no org_kde_kwin_appmenu — menu is on the bus but not shown", .{});
            return;
        };
        const surface = self.surface orelse return;
        const name = server.uniqueName() orelse return;
        const obj = mgr.create(surface);
        self.appmenu_obj = obj;
        obj.setAddress(name, menu_object_path);
        _ = wl.wl_display_flush(self.display);
    }

    /// Animation heartbeat: drain the timerfd, measure real elapsed `dt`, tick every
    /// panel, and repaint. When nothing wants more frames, disarm so `poll` blocks idle.
    fn onTimerTick(self: *Window) void {
        var expirations: u64 = 0;
        _ = posix.read(self.timer_fd, std.mem.asBytes(&expirations)) catch {};
        const now = monotonicNs();
        const dt: f32 = if (self.last_tick_ns != 0)
            @min(@as(f32, @floatFromInt(now - self.last_tick_ns)) / 1_000_000_000.0, 0.1)
        else
            0.016;
        self.last_tick_ns = now;
        const panels_active = self.panels.tick(dt, self.host());
        self.needs_redraw = true;
        if (!panels_active) self.disarmTimer();
    }

    fn monotonicNs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
    }

    /// Register a panel to draw over the content and receive input before the app
    /// callbacks. `owned` = the registry runs its `deinit` at teardown. Window thread only.
    pub fn addPanel(self: *Window, panel: Panel, owned: bool) !void {
        try self.panels.add(panel, owned);
        self.needs_redraw = true;
    }

    /// Remove a previously added panel by its instance pointer (runs `deinit` if owned).
    pub fn removePanel(self: *Window, ptr: *anyopaque) void {
        self.panels.remove(ptr);
        self.needs_redraw = true;
    }

    /// Load a single plugin `.so` and let it register its panels (see `plugin.loadPlugin`).
    /// Window thread only. The library stays loaded until `deinit`.
    pub fn loadPlugin(self: *Window, path: []const u8) !void {
        const lib = try plugin.loadPlugin(&self.panels, path);
        try self.plugin_libs.append(self.gpa, lib);
        self.needs_redraw = true;
    }

    /// Load every `*.so` in `dir_path`. Missing directory is a no-op; a plugin that fails
    /// to load is logged and skipped, not fatal. Window thread only.
    pub fn loadPluginDir(self: *Window, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |ent| {
            if (ent.kind != .file or !std.mem.endsWith(u8, ent.name, ".so")) continue;
            const full = try std.fs.path.join(self.gpa, &.{ dir_path, ent.name });
            defer self.gpa.free(full);
            self.loadPlugin(full) catch |e| std.log.warn("zrame: plugin {s} failed to load: {}", .{ ent.name, e });
        }
    }

    /// The narrow interface panels use to reach back into the window (see `plugin.zig`).
    pub fn host(self: *Window) Host {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    const host_vtable = Host.VTable{ .do = hostDo, .info = hostInfo, .font = hostFont };

    fn hostDo(ptr: *anyopaque, action: plugin.Action) void {
        const self: *Window = @ptrCast(@alignCast(ptr));
        switch (action) {
            .minimize => if (self.toplevel) |t| t.setMinimized(),
            .toggle_maximize => if (self.toplevel) |t| {
                if (self.maximized) t.unsetMaximized() else t.setMaximized();
            },
            .toggle_fullscreen => self.toggleFullscreen(),
            .close => self.closed = true,
            .begin_move => if (self.toplevel) |t| {
                if (self.seat) |s| t.move(s, self.pointer_serial);
            },
            .begin_resize => |edge| if (self.toplevel) |t| {
                if (self.seat) |s| t.resize(s, self.pointer_serial, edge);
            },
            .set_cursor => |shape| self.setCursorShape(shape),
            .request_redraw => self.needs_redraw = true,
        }
    }

    /// Request a `wp_cursor_shape_device` shape, skipping the round-trip when unchanged.
    fn setCursorShape(self: *Window, shape: u32) void {
        if (shape == self.cursor_shape) return;
        self.cursor_shape = shape;
        if (self.cursor_device) |d| d.setShape(self.pointer_serial, shape);
    }

    /// The `xdg_toplevel` resize-edge bitmask for a pointer at canvas `(sx,sy)`: an 8px
    /// band around the panel border, corners combining two edges. NONE in the interior.
    fn resizeEdgeAt(self: *const Window, sx: f32, sy: f32) u32 {
        const p = self.physPanel();
        const px = sx - p.m;
        const py = sy - p.m;
        const w = p.w;
        const h = p.h;
        if (px < 0 or py < 0 or px >= w or py >= h) return wl.RESIZE_EDGE_NONE;
        const band: f32 = self.physPxF(8.0);
        var edge: u32 = 0;
        if (py < band) edge |= wl.RESIZE_EDGE_TOP;
        if (py >= h - band) edge |= wl.RESIZE_EDGE_BOTTOM;
        if (px < band) edge |= wl.RESIZE_EDGE_LEFT;
        if (px >= w - band) edge |= wl.RESIZE_EDGE_RIGHT;
        return edge;
    }

    fn edgeCursor(edge: u32) u32 {
        return switch (edge) {
            wl.RESIZE_EDGE_TOP, wl.RESIZE_EDGE_BOTTOM => wl.CursorShapeDevice.SHAPE_NS_RESIZE,
            wl.RESIZE_EDGE_LEFT, wl.RESIZE_EDGE_RIGHT => wl.CursorShapeDevice.SHAPE_EW_RESIZE,
            wl.RESIZE_EDGE_TOP_LEFT, wl.RESIZE_EDGE_BOTTOM_RIGHT => wl.CursorShapeDevice.SHAPE_NWSE_RESIZE,
            wl.RESIZE_EDGE_TOP_RIGHT, wl.RESIZE_EDGE_BOTTOM_LEFT => wl.CursorShapeDevice.SHAPE_NESW_RESIZE,
            else => wl.CursorShapeDevice.SHAPE_DEFAULT,
        };
    }

    fn hostInfo(ptr: *anyopaque) plugin.Info {
        const self: *Window = @ptrCast(@alignCast(ptr));
        // Physical pixels throughout — consistent with the canvas panels draw on and
        // with the pointer coordinates they hit-test against.
        const p = self.physPanel();
        return .{
            .content = self.contentRect(),
            .panel_w = @intFromFloat(p.w),
            .panel_h = @intFromFloat(p.h),
            .margin = @intFromFloat(p.m),
            .maximized = self.maximized,
            .fullscreen = self.fullscreen,
        };
    }

    fn hostFont(ptr: *anyopaque) ?*text.Font {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return self.textFont() catch null;
    }

    /// Route an input event through the panels; returns true if a panel consumed it.
    /// Any input may have started an animation, so we (cheaply) re-arm the timer, which
    /// self-disarms on the first tick that reports nothing left to animate.
    fn routeInput(self: *Window, event: plugin.Event) bool {
        const consumed = self.panels.route(event, self.host());
        if (consumed) self.needs_redraw = true;
        self.armTimer();
        return consumed;
    }

    fn armTimer(self: *Window) void {
        if (self.timer_armed) return;
        // ~60 Hz repeating tick.
        const spec = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 16_666_667 },
            .it_value = .{ .sec = 0, .nsec = 16_666_667 },
        };
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
        self.timer_armed = true;
        self.last_tick_ns = monotonicNs();
    }

    fn disarmTimer(self: *Window) void {
        if (!self.timer_armed) return;
        const spec = std.mem.zeroes(linux.itimerspec);
        _ = linux.timerfd_settime(self.timer_fd, .{}, &spec, null);
        self.timer_armed = false;
        self.last_tick_ns = 0;
    }

    /// Ask the loop to exit (safe from listeners on the window thread).
    pub fn close(self: *Window) void {
        self.closed = true;
    }

    /// Dynamically update the window's decoration style. Window thread only (it talks
    /// to Wayland objects): call it from an input callback or before [`run`].
    pub fn setStyle(self: *Window, style: Style) !void {
        self.opts.style = style;
        const m = style.margin;
        try self.repaintDecor(self.panel_w + 2 * m, self.panel_h + 2 * m);
        self.applySurfaceMetrics();
        self.needs_redraw = true;
    }

    /// Alterna la modalità a schermo intero. Si limita a chiedere/rilasciare il
    /// fullscreen al compositore: la dimensione reale e lo stato arrivano dal
    /// `configure` successivo (onToplevelConfigure), che azzera/ripristina
    /// gutter/ombra/angoli. Solo dal thread finestra (parla con oggetti Wayland):
    /// chiamalo da una callback di input.
    pub fn toggleFullscreen(self: *Window) void {
        const tl = self.toplevel orelse return;
        if (self.fullscreen) tl.unsetFullscreen() else tl.setFullscreen();
    }

    /// Riduce (in scala, preservando le proporzioni) `w`×`h` perché la geometria
    /// finestra stia nell'area utile suggerita dal compositore (`bounds_*`), con
    /// un piccolo margine di sicurezza. Non ingrandisce mai. No-op se i bounds
    /// non sono noti. Serve a non far sbordare la finestra oltre lo schermo.
    fn fitBounds(self: *const Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        if (self.bounds_w == 0 or self.bounds_h == 0) return .{ .w = w, .h = h };
        const inset: u32 = 8;
        const bw: f32 = @floatFromInt(self.bounds_w -| inset);
        const bh: f32 = @floatFromInt(self.bounds_h -| inset);
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const scale = @min(@as(f32, 1.0), @min(bw / fw, bh / fh));
        if (scale >= 1.0) return .{ .w = w, .h = h };
        return .{
            .w = @max(self.minPanel(), @as(u32, @intFromFloat(@round(fw * scale)))),
            .h = @max(self.minPanel(), @as(u32, @intFromFloat(@round(fh * scale)))),
        };
    }

    /// Porta la finestra al pannello `target_w`×`target_h`, capato all'area utile
    /// (`fitBounds` → mai fuori schermo), e la ri-centra. Su Wayland il client non può
    /// spostare il proprio toplevel: l'unico modo per ri-centrare dopo un resize è
    /// smappare e rimappare la surface (un breve "flash"), così il compositore riesegue
    /// il placement e la rimette al centro. No-op in fullscreen/massimizzato o se la
    /// dimensione non cambia. Solo dal thread finestra (callback di input o prima di run).
    pub fn animateResize(self: *Window, target_w: u32, target_h: u32) void {
        if (self.fullscreen or self.maximized) return;
        const fitted = self.fitBounds(target_w, target_h);
        const tw = @max(fitted.w, self.minPanel());
        const th = @max(fitted.h, self.minPanel());
        if (tw == self.panel_w and th == self.panel_h) return; // già a misura
        self.panel_w = tw;
        self.panel_h = th;
        // Non ancora mappata (init, prima del primo map): imposta soltanto — il primo
        // map la centrerà da sé.
        if (!self.configured or self.surface == null) {
            self.needs_redraw = true;
            return;
        }
        // Smappa e rimappa così il compositore rifà il placement e ri-centra la finestra
        // (unico aggancio su Wayland). Il protocollo xdg impone la sequenza di re-map:
        // attach(null)+commit per smappare, poi un commit "iniziale" senza buffer e si
        // ATTENDE un nuovo configure prima di ri-attaccare pixel (altrimenti
        // `unconfigured_buffer`). Marcando `configured=false` il loop non ridisegna finché
        // il configure non arriva; onXdgConfigure lo rialza e il redraw riattacca → re-map.
        const surface = self.surface.?;
        surface.attach(null, 0, 0);
        surface.commit();
        self.configured = false;
        surface.commit();
        // Un frame callback in volo era legato alla surface mappata: dopo l'unmap
        // potrebbe non arrivare mai. Sbloccando il flag, il primo redraw dopo il
        // re-map ne richiede uno nuovo; se il vecchio arriva comunque, gestirne
        // due è innocuo (ogni `done` distrugge solo il proprio wl_callback).
        self.frame_cb_pending = false;
        self.needs_redraw = true;
    }

    /// Motore di testo della finestra, creato pigramente col font di default
    /// (Hack regular+bold). Usalo per disegnare testo in `on_draw`:
    /// `canvas.drawText(try win.textFont(), x, baseline, "…", .{})`.
    pub fn textFont(self: *Window) !*text.Font {
        if (self.font == null) self.font = try text.Font.initDefault(self.gpa);
        return &self.font.?;
    }

    /// Sostituisce la faccia regular del font con byte TTF (es. un `@embedFile`).
    pub fn setFont(self: *Window, ttf: []const u8) !void {
        const f = try self.textFont();
        try f.setFace(.regular, ttf, false);
    }

    /// Carica la faccia regular da un file .ttf/.otf su disco.
    pub fn loadFont(self: *Window, path: []const u8) !void {
        const f = try self.textFont();
        try f.loadFace(.regular, path);
    }

    // --- clipboard --------------------------------------------------------------------

    /// Take ownership of the system selection (the ctrl+C side): copies `bytes` into a
    /// window-owned buffer (replacing any previous copy) and offers it as plain UTF-8
    /// text. Ownership needs a recent input serial, so call it in response to input.
    /// Window thread only (talks to Wayland objects) — call from an input callback.
    pub fn clipboardSet(self: *Window, bytes: []const u8) void {
        const mgr = self.data_device_manager orelse return;
        const dev = self.data_device orelse return;
        const copy = self.gpa.dupe(u8, bytes) catch return;
        if (self.clip_text.len > 0) self.gpa.free(self.clip_text);
        self.clip_text = copy;
        // Replace any previous source of ours; the compositor would cancel it anyway
        // the moment the new one takes the selection.
        if (self.data_source) |old| {
            old.destroy();
            self.data_source = null;
        }
        const src = mgr.createDataSource();
        src.setListener(&data_source_listener, self);
        src.offer("text/plain;charset=utf-8");
        src.offer("text/plain");
        dev.setSelection(src, self.input_serial);
        self.data_source = src;
        _ = wl.wl_display_flush(self.display);
    }

    /// Read the system selection as UTF-8 text (the ctrl+V side). Returns null when the
    /// clipboard is empty or offers no text, when WE own the selection (use the copy you
    /// passed to `clipboardSet` — it is byte-identical), or on any I/O failure. The
    /// caller frees the returned bytes with `gpa`.
    ///
    /// Window thread only: it performs a nested roundtrip on the display (fine — the
    /// same thread owns it, and our own `send` handler can service another client's
    /// concurrent request during it) and reads the pipe under a ~250 ms poll budget,
    /// capped at 1 MiB.
    pub fn clipboardGet(self: *Window, gpa: Allocator) ?[]u8 {
        if (self.data_source != null) return null; // self-paste: caller's copy is fresher
        const offer = self.selection_offer orelse return null;
        if (self.selection_mime == .none) return null;
        const pipe_fds = posix.pipe2(.{ .CLOEXEC = true }) catch return null;
        offer.receive(self.selection_mime.mime(), pipe_fds[1]);
        // Close our write end NOW: the source client holds the only other copy, so its
        // close after writing is what turns into our EOF.
        _ = linux.close(pipe_fds[1]);
        // Push the receive out and give the source a chance to answer immediately.
        _ = wl.wl_display_flush(self.display);
        _ = wl.wl_display_roundtrip(self.display);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const deadline = monotonicNs() + 250 * 1_000_000;
        var buf: [4096]u8 = undefined;
        while (out.items.len < 1024 * 1024) {
            const left_ns = deadline - monotonicNs();
            if (left_ns <= 0) break; // budget exhausted: slow/stuck source
            var pfd = [_]posix.pollfd{.{ .fd = pipe_fds[0], .events = posix.POLL.IN, .revents = 0 }};
            const ready = posix.poll(&pfd, @intCast(@divTrunc(left_ns, 1_000_000) + 1)) catch break;
            if (ready == 0) break; // timeout
            const n = posix.read(pipe_fds[0], &buf) catch break;
            if (n == 0) break; // EOF: transfer complete
            out.appendSlice(gpa, buf[0..n]) catch {
                _ = linux.close(pipe_fds[0]);
                return null;
            };
        }
        _ = linux.close(pipe_fds[0]);
        if (out.items.len == 0) return null;
        return out.toOwnedSlice(gpa) catch null;
    }

    const data_device_listener = wl.DataDevice.Listener{
        .data_offer = onDataOffer,
        .enter = onDndEnter,
        .leave = onDndLeave,
        .motion = onDndMotion,
        .drop = onDndDrop,
        .selection = onSelection,
    };

    fn onDataOffer(data: ?*anyopaque, _: *wl.DataDevice, offer: *wl.DataOffer) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // A previously introduced offer that never became the selection (e.g. a DnD
        // offer we ignored) is dead weight by now — each event introduces a fresh one.
        if (self.pending_offer) |old| {
            if (old != self.selection_offer) old.destroy();
        }
        self.pending_offer = offer;
        self.pending_mime = .none;
        offer.setListener(&data_offer_listener, self);
    }

    // DnD is out of scope: we never accept drags, so enter/leave/motion/drop stay no-ops
    // (an unused DnD offer is reaped by the next data_offer/deinit, see onDataOffer).
    fn onDndEnter(_: ?*anyopaque, _: *wl.DataDevice, _: u32, _: ?*wl.Surface, _: wl.Fixed, _: wl.Fixed, _: ?*wl.DataOffer) callconv(.c) void {}
    fn onDndLeave(_: ?*anyopaque, _: *wl.DataDevice) callconv(.c) void {}
    fn onDndMotion(_: ?*anyopaque, _: *wl.DataDevice, _: u32, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {}
    fn onDndDrop(_: ?*anyopaque, _: *wl.DataDevice) callconv(.c) void {}

    fn onSelection(data: ?*anyopaque, _: *wl.DataDevice, offer: ?*wl.DataOffer) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // The previous selection offer is superseded — the protocol obliges us to
        // destroy it. Null = the clipboard was cleared (its owner quit).
        if (self.selection_offer) |old| {
            if (old != offer) old.destroy();
        }
        self.selection_offer = offer;
        self.selection_mime = .none;
        if (offer != null and offer == self.pending_offer) {
            self.selection_mime = self.pending_mime;
            self.pending_offer = null;
            self.pending_mime = .none;
        }
    }

    const data_offer_listener = wl.DataOffer.Listener{
        .offer = onOfferMime,
        .source_actions = onOfferSourceActions,
        .action = onOfferAction,
    };

    fn onOfferMime(data: ?*anyopaque, offer: *wl.DataOffer, mime: [*:0]const u8) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (offer != self.pending_offer) return;
        const m = std.mem.span(mime);
        const rank: TextMime = if (std.mem.eql(u8, m, "text/plain;charset=utf-8"))
            .utf8
        else if (std.mem.eql(u8, m, "UTF8_STRING"))
            .utf8_string
        else if (std.mem.eql(u8, m, "text/plain"))
            .plain
        else
            .none;
        if (@intFromEnum(rank) > @intFromEnum(self.pending_mime)) self.pending_mime = rank;
    }

    fn onOfferSourceActions(_: ?*anyopaque, _: *wl.DataOffer, _: u32) callconv(.c) void {}
    fn onOfferAction(_: ?*anyopaque, _: *wl.DataOffer, _: u32) callconv(.c) void {}

    const data_source_listener = wl.DataSource.Listener{
        .target = onSourceTarget,
        .send = onSourceSend,
        .cancelled = onSourceCancelled,
        .dnd_drop_performed = onSourceDndDrop,
        .dnd_finished = onSourceDndFinished,
        .action = onSourceAction,
    };

    /// A client wants our selection (possibly DURING a `clipboardGet` roundtrip of ours
    /// — fine, this needs no reentrancy into Wayland): write the owned text into the
    /// pipe, looping short writes, then close the fd. A stalled reader is abandoned
    /// after ~1s so a hostile client can't wedge the window thread.
    fn onSourceSend(data: ?*anyopaque, _: *wl.DataSource, _: [*:0]const u8, fd: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        defer _ = linux.close(fd);
        const deadline = monotonicNs() + 1_000_000_000;
        var off: usize = 0;
        while (off < self.clip_text.len) {
            const n = posix.write(fd, self.clip_text[off..]) catch |err| switch (err) {
                error.WouldBlock => {
                    // The receiver made its pipe end non-blocking and it's full: wait
                    // for drain, bounded.
                    if (monotonicNs() >= deadline) return;
                    var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                    const ready = posix.poll(&pfd, 100) catch return;
                    if (ready == 0 and monotonicNs() >= deadline) return;
                    continue;
                },
                else => return, // reader vanished (EPIPE et al.): nothing left to do
            };
            if (n == 0) return;
            off += n;
        }
    }

    fn onSourceCancelled(data: ?*anyopaque, source: *wl.DataSource) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Another client took the selection over: drop ownership. `clip_text` stays —
        // it backs nothing anymore but may be mid-`send` on a concurrent transfer.
        source.destroy();
        if (self.data_source == source) self.data_source = null;
    }

    fn onSourceTarget(_: ?*anyopaque, _: *wl.DataSource, _: ?[*:0]const u8) callconv(.c) void {}
    fn onSourceDndDrop(_: ?*anyopaque, _: *wl.DataSource) callconv(.c) void {}
    fn onSourceDndFinished(_: ?*anyopaque, _: *wl.DataSource) callconv(.c) void {}
    fn onSourceAction(_: ?*anyopaque, _: *wl.DataSource, _: u32) callconv(.c) void {}

    // --- drawing --------------------------------------------------------------------

    /// Smallest panel the chrome stays legible at; also what we advertise as min size.
    fn minPanel(self: *const Window) u32 {
        return 4 * self.opts.style.margin;
    }

    // --- HiDPI helpers -------------------------------------------------------------------
    // The cut: everything that PAINTS (buffer, canvas, panels, pointer coords, app
    // content rect) is in physical pixels; everything the COMPOSITOR sees (window
    // geometry, input/blur regions, configure sizes, viewport destination) stays logical.

    /// The surface's preferred scale (1.0 on non-scaled outputs or without protocol support).
    pub fn scaleFactor(self: *const Window) f32 {
        return @as(f32, @floatFromInt(self.scale120)) / 120.0;
    }

    /// Logical → physical pixels, rounded.
    fn physPx(self: *const Window, v: u32) u32 {
        return @intCast((@as(u64, v) * self.scale120 + 60) / 120);
    }

    fn physPxF(self: *const Window, v: f32) f32 {
        return v * @as(f32, @floatFromInt(self.scale120)) / 120.0;
    }

    /// Panel geometry in buffer (physical) pixels — the space pointer coords live in.
    /// Width/height are derived as `total − 2·margin` so they always complement the
    /// buffer dimensions exactly (no independent-rounding drift).
    fn physPanel(self: *const Window) struct { m: f32, w: f32, h: f32 } {
        const m = self.opts.style.margin;
        const bw = self.physPx(self.panel_w + 2 * m);
        const bh = self.physPx(self.panel_h + 2 * m);
        const mp = self.physPx(m);
        return .{
            .m = @floatFromInt(mp),
            .w = @floatFromInt(bw - 2 * mp),
            .h = @floatFromInt(bh - 2 * mp),
        };
    }

    /// The chrome style in buffer (physical) pixels — geometry fields only, colors and
    /// alphas untouched. Compositor-facing users (regions, geometry) keep `opts.style`.
    fn paintStyle(self: *const Window) Style {
        var s = self.opts.style;
        s.margin = self.physPx(s.margin);
        s.corner_radius = self.physPxF(s.corner_radius);
        s.shadow_blur = self.physPxF(s.shadow_blur);
        s.shadow_offset_y = self.physPxF(s.shadow_offset_y);
        s.glass_fade_width = self.physPxF(s.glass_fade_width);
        s.content_radius = self.physPxF(s.content_radius);
        s.content_fade_width = self.physPxF(s.content_fade_width);
        s.border_anim_width = self.physPxF(s.border_anim_width);
        return s;
    }

    /// Height the title bar steals from the top of the content (0 when disabled or in
    /// fullscreen, where the chrome is hidden).
    fn titlebarHeight(self: *const Window) u32 {
        if (!self.opts.titlebar or self.fullscreen) return 0;
        return @min(self.opts.titlebar_height, self.panel_h);
    }

    fn contentRect(self: *Window) Rect {
        // Physical (buffer) pixels — the canvas/panel/pointer space. The title-bar
        // height stays unscaled on purpose: the controls panel draws its bar with its
        // own (unscaled) metrics, and the content must start exactly beneath it.
        const p = self.physPanel();
        const m: u32 = @intFromFloat(p.m);
        const tb = self.titlebarHeight();
        return .{ .x = m, .y = m + tb, .w = @intFromFloat(p.w), .h = @as(u32, @intFromFloat(p.h)) - tb };
    }

    /// Composite one full window frame into `pixels` (an ARGB8888 buffer sized
    /// `bw`×`bh`). Pure CPU: no windowing-system call happens here. It paints the
    /// chrome decoration, the app `on_draw` overlay, the newest staged content
    /// frame (taken via a lock-light buffer swap), and finally the panels stack.
    ///
    /// This is the platform seam for presentation: every backend — the Wayland
    /// shm path below, or a future Cocoa/Metal path — acquires a writable pixel
    /// buffer its own way, calls this to fill it, then presents it however it can.
    fn composeFrame(self: *Window, pixels: []u32, bw: u32, bh: u32) void {
        @memcpy(pixels, self.decor);
        var canvas = paint.Canvas.init(pixels, bw, bh);
        chrome.swapFront(&self.mutex, &self.staged, &self.front);
        chrome.composeContent(&canvas, self.contentRect(), &self.front, self.paintStyle(), &self.panels, self.host(), self.opts.on_draw, self.opts.user);
    }

    /// Wayland present path: size the shm buffers, acquire a free slot, compose
    /// into it, then attach + damage + commit. The composition itself is backend
    /// -agnostic (see `composeFrame`); only the slot acquisition and surface
    /// commit are Wayland-specific.
    fn redraw(self: *Window) !void {
        const m = self.opts.style.margin;
        const bw = self.physPx(self.panel_w + 2 * m);
        const bh = self.physPx(self.panel_h + 2 * m);
        if (bw != self.buf_w or bh != self.buf_h) try self.resizeBuffers(bw, bh);

        const slot = self.freeSlot() orelse return; // both busy: retry on next wake
        self.composeFrame(slot.pixels, bw, bh);

        const surface = self.surface.?;
        surface.attach(slot.buffer, 0, 0);
        surface.damageBuffer(0, 0, @intCast(bw), @intCast(bh));
        // Vsync: chiedi un frame callback per QUESTO commit (la richiesta `frame`
        // è stato double-buffered, va emessa prima del commit), se non ce n'è già
        // uno in volo. Niente commit → niente callback → i waiter di `waitFrame`
        // scadono col loro timeout (coalescenza: video in pausa non blocca).
        if (!self.frame_cb_pending) {
            const fcb = surface.frame();
            fcb.setListener(&frame_done_listener, self);
            self.frame_cb_pending = true;
        }
        surface.commit();
        slot.busy = true;
        self.needs_redraw = false;
    }

    fn freeSlot(self: *Window) ?*BufferSlot {
        for (&self.slots) |*slot| {
            if (!slot.busy and slot.buffer != null) return slot;
        }
        return null;
    }

    fn dropBuffers(self: *Window) void {
        for (&self.slots) |*slot| {
            if (slot.buffer) |b| b.destroy();
            slot.* = .{};
        }
        if (self.pool) |p| p.destroy();
        self.pool = null;
        if (self.shm_map.len > 0) posix.munmap(self.shm_map);
        self.shm_map = &.{};
        if (self.shm_fd >= 0) _ = linux.close(self.shm_fd);
        self.shm_fd = -1;
        self.pool_cap = 0;
        self.buf_w = 0;
        self.buf_h = 0;
    }

    fn resizeBuffers(self: *Window, bw: u32, bh: u32) !void {
        const stride = @as(usize, bw) * 4;
        const slot_size = stride * @as(usize, bh);
        const total = slot_size * self.slots.len;

        if (self.pool == null or total > self.pool_cap) {
            // Grow: tear down the memfd/mmap/pool and reallocate with 50% headroom, so a
            // continuing drag stops re-allocating once it has room.
            self.dropBuffers();
            const cap = total + total / 2;
            const fd = try posix.memfd_create("zrame-shm", linux.MFD.CLOEXEC);
            errdefer _ = linux.close(fd);
            if (linux.errno(linux.ftruncate(fd, @intCast(cap))) != .SUCCESS) return error.ShmSetupFailed;
            const map = try posix.mmap(null, cap, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
            self.shm_fd = fd;
            self.shm_map = map;
            self.pool = self.shm.?.createPool(fd, @intCast(cap));
            self.pool_cap = cap;
        } else {
            // Reuse the existing pool/mapping; only the two buffer objects change geometry.
            for (&self.slots) |*slot| {
                if (slot.buffer) |b| b.destroy();
                slot.buffer = null;
            }
        }

        const map = self.shm_map;
        for (&self.slots, 0..) |*slot, i| {
            const off = i * slot_size;
            slot.buffer = self.pool.?.createBuffer(@intCast(off), @intCast(bw), @intCast(bh), @intCast(stride), wl.SHM_FORMAT_ARGB8888);
            slot.buffer.?.setListener(&buffer_listener, slot);
            slot.pixels = @as([*]u32, @ptrCast(@alignCast(map.ptr + off)))[0 .. @as(usize, bw) * bh];
            slot.busy = false;
        }
        self.buf_w = bw;
        self.buf_h = bh;

        try self.repaintDecor(bw, bh);
        self.applySurfaceMetrics();
    }

    /// (Re)raster the chrome cache at `bw`×`bh`, reusing the allocation when the size
    /// is unchanged (e.g. a pure style swap).
    fn repaintDecor(self: *Window, bw: u32, bh: u32) !void {
        const len = @as(usize, bw) * bh;
        if (self.decor.len != len) {
            if (self.decor.len > 0) self.gpa.free(self.decor);
            self.decor = &.{};
            self.decor = try self.gpa.alloc(u32, len);
        }
        var canvas = paint.Canvas.init(self.decor, bw, bh);
        canvas.drawChrome(self.paintStyle());
    }

    /// Window geometry, input region and blur region all describe the *panel*, not the
    /// buffer: the shadow gutter is invisible to the compositor's window management.
    fn applySurfaceMetrics(self: *Window) void {
        const m: i32 = @intCast(self.opts.style.margin);
        const pw: i32 = @intCast(self.panel_w);
        const ph: i32 = @intCast(self.panel_h);
        self.xdg_surface.?.setWindowGeometry(m, m, pw, ph);

        const input = self.compositor.?.createRegion();
        defer input.destroy();
        input.add(m, m, pw, ph);
        self.surface.?.setInputRegion(input);

        if (self.blur) |blur| {
            const region = self.compositor.?.createRegion();
            defer region.destroy();
            const bi = self.opts.style.blur_inset;
            if (bi > 0.0 and bi < @as(f32, @floatFromInt(self.panel_w)) / 2.0 and bi < @as(f32, @floatFromInt(self.panel_h)) / 2.0) {
                const bi_u: u32 = @intFromFloat(bi);
                const pw_shrunk = self.panel_w - 2 * bi_u;
                const ph_shrunk = self.panel_h - 2 * bi_u;
                const radius = @max(0.0, self.opts.style.corner_radius - bi);
                addRoundedRegion(region, bi_u, pw_shrunk, ph_shrunk, radius);
            } else {
                addRoundedRegion(region, 0, self.panel_w, self.panel_h, self.opts.style.corner_radius);
            }
            blur.setBlurRegion(region);
        }

        // HiDPI: present the physically-sized buffer at the logical window size.
        if (self.viewport) |vp| {
            vp.setDestination(pw + 2 * m, ph + 2 * m);
        }
    }

    // --- listeners --------------------------------------------------------------------

    const registry_listener = wl.Registry.Listener{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };

    fn onGlobal(data: ?*anyopaque, registry: *wl.Registry, name: u32, interface: [*:0]const u8, ver: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(registry.bind(name, &wl.wl_compositor_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(registry.bind(name, &wl.wl_shm_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
            self.subcompositor = @ptrCast(registry.bind(name, &wl.wl_subcompositor_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) {
            // v2 is enough (create_immed); cap at 4 (v5 changes nothing we use).
            if (ver >= 2)
                self.dmabuf = @ptrCast(registry.bind(name, &wl.zwp_linux_dmabuf_v1_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = @ptrCast(registry.bind(name, &wl.xdg_wm_base_interface, @min(ver, 6)).?);
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            const seat: *wl.Seat = @ptrCast(registry.bind(name, &wl.wl_seat_interface, @min(ver, 5)).?);
            seat.setListener(&seat_listener, self);
            self.seat = seat;
        } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
            // v3 is current; v1 still covers the selection path we use.
            self.data_device_manager = @ptrCast(registry.bind(name, &wl.wl_data_device_manager_interface, @min(ver, 3)).?);
        } else if (std.mem.eql(u8, iface, "ext_background_effect_manager_v1")) {
            self.blur_manager = @ptrCast(registry.bind(name, &wl.ext_background_effect_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shapes = @ptrCast(registry.bind(name, &wl.wp_cursor_shape_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
            self.viewporter = @ptrCast(registry.bind(name, &wl.wp_viewporter_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
            self.fractional_manager = @ptrCast(registry.bind(name, &wl.wp_fractional_scale_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, appmenu_mod.manager_global)) {
            self.appmenu_manager = @ptrCast(registry.bind(name, appmenu_mod.manager_interface, 1).?);
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: *wl.Registry, _: u32) callconv(.c) void {}

    const wm_base_listener = wl.XdgWmBase.Listener{ .ping = onPing };

    fn onPing(data: ?*anyopaque, wm_base: *wl.XdgWmBase, serial: u32) callconv(.c) void {
        _ = data;
        wm_base.pong(serial);
    }

    const xdg_surface_listener = wl.XdgSurface.Listener{ .configure = onXdgConfigure };

    fn onXdgConfigure(data: ?*anyopaque, xdg_surface: *wl.XdgSurface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        xdg_surface.ackConfigure(serial);
        self.configured = true;
        self.needs_redraw = true;
        // Before the loop is pumping (init roundtrips) draw right here so the window maps.
        // Once running, only flag it: the loop paints once per iteration, so a burst of
        // resize configures collapses into a single redraw instead of one apiece.
        if (!self.running) self.redraw() catch {};
    }

    const toplevel_listener = wl.XdgToplevel.Listener{
        .configure = onToplevelConfigure,
        .close = onToplevelClose,
        .configure_bounds = onConfigureBounds,
        .wm_capabilities = onWmCapabilities,
    };

    // wl_array: buffer dinamico Wayland. `states` di xdg_toplevel.configure è un
    // array di u32 (enum di stato); `size` è in byte.
    const WlArray = extern struct { size: usize, alloc: usize, data: ?[*]u32 };

    fn onToplevelConfigure(data: ?*anyopaque, _: *wl.XdgToplevel, width: i32, height: i32, states: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));

        // Rileva fullscreen e massimizzato dall'array di stati del compositore.
        var is_fs = false;
        var is_max = false;
        if (states) |sp| {
            const arr: *const WlArray = @ptrCast(@alignCast(sp));
            if (arr.data) |d| {
                const n = arr.size / @sizeOf(u32);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (d[i] == wl.STATE_FULLSCREEN) is_fs = true;
                    if (d[i] == wl.STATE_MAXIMIZED) is_max = true;
                }
            }
        }
        self.maximized = is_max;

        // Ingresso/uscita da fullscreen: azzera o ripristina gutter/ombra/angoli.
        // La dimensione la porta il `width`/`height` di questa stessa configure;
        // il repaint della decor e la geometria li aggiorna il redraw sul resize.
        if (is_fs != self.fullscreen) {
            self.fullscreen = is_fs;
            if (is_fs) {
                self.saved_panel_w = self.panel_w;
                self.saved_panel_h = self.panel_h;
                self.saved_margin = self.opts.style.margin;
                self.saved_radius = self.opts.style.corner_radius;
                self.saved_content_radius = self.opts.style.content_radius;
                self.opts.style.margin = 0;
                self.opts.style.corner_radius = 0;
                // Anche il contenuto senza angoli tondi: a schermo intero niente
                // cornice/bordo, il contenuto riempe da bordo a bordo.
                self.opts.style.content_radius = 0;
            } else {
                self.opts.style.margin = self.saved_margin;
                self.opts.style.corner_radius = self.saved_radius;
                self.opts.style.content_radius = self.saved_content_radius;
                // Se il compositore non suggerisce una dimensione (0), torna a
                // quella pre-fullscreen.
                if (width <= 0) self.panel_w = self.saved_panel_w;
                if (height <= 0) self.panel_h = self.saved_panel_h;
            }
        }

        // The suggested size is window geometry — the panel. 0 means "you pick".
        if (width > 0) self.panel_w = @max(@as(u32, @intCast(width)), self.minPanel());
        if (height > 0) self.panel_h = @max(@as(u32, @intCast(height)), self.minPanel());
    }

    fn onToplevelClose(data: ?*anyopaque, _: *wl.XdgToplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.closed = true;
    }

    fn onConfigureBounds(data: ?*anyopaque, _: *wl.XdgToplevel, width: i32, height: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Area utile massima per la geometria finestra (0 = "nessun vincolo").
        if (width > 0) self.bounds_w = @intCast(width);
        if (height > 0) self.bounds_h = @intCast(height);
        // Se il contenuto attuale eccede l'area utile, riportalo dentro: prima della
        // mappatura (init roundtrip) in modo istantaneo, a finestra viva con
        // un'animazione. Così un documento più alto dello schermo non sborda sotto.
        const fitted = self.fitBounds(self.panel_w, self.panel_h);
        if (fitted.w != self.panel_w or fitted.h != self.panel_h) {
            if (self.running) {
                self.animateResize(fitted.w, fitted.h);
            } else {
                self.panel_w = fitted.w;
                self.panel_h = fitted.h;
            }
        }
    }
    fn onWmCapabilities(_: ?*anyopaque, _: *wl.XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    const buffer_listener = wl.Buffer.Listener{ .release = onBufferRelease };

    fn onBufferRelease(data: ?*anyopaque, _: *wl.Buffer) callconv(.c) void {
        const slot: *BufferSlot = @ptrCast(@alignCast(data.?));
        slot.busy = false;
    }

    const seat_listener = wl.Seat.Listener{ .capabilities = onSeatCaps, .name = onSeatName };

    fn onSeatCaps(data: ?*anyopaque, seat: *wl.Seat, caps: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (caps & wl.SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
            const pointer = seat.getPointer();
            pointer.setListener(&pointer_listener, self);
            self.pointer = pointer;
            if (self.cursor_shapes) |shapes| self.cursor_device = shapes.getPointer(pointer);
        }
        if (caps & wl.SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
            const keyboard = seat.getKeyboard();
            keyboard.setListener(&keyboard_listener, self);
            self.keyboard = keyboard;
        }
        if (caps & wl.SEAT_CAPABILITY_TOUCH != 0 and self.touch == null) {
            const touch = seat.getTouch();
            touch.setListener(&touch_listener, self);
            self.touch = touch;
        }
    }

    fn onSeatName(_: ?*anyopaque, _: *wl.Seat, _: [*:0]const u8) callconv(.c) void {}

    const keyboard_listener = wl.Keyboard.Listener{
        .keymap = onKeymap,
        .enter = onKeyEnter,
        .leave = onKeyLeave,
        .key = onKey,
        .modifiers = onKeyModifiers,
        .repeat_info = onKeyRepeatInfo,
    };

    fn onKeymap(data: ?*anyopaque, _: *wl.Keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        defer _ = linux.close(fd);
        // Keys keep flowing to `on_key` as raw evdev codes regardless; the keymap only
        // feeds the layout-correct `on_text` translation. Any failure below just leaves
        // `xkb_state` null → on_text never fires (apps fall back to their own mapping).
        if (format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0) return;
        const map = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer posix.munmap(map);
        if (self.xkb_context == null) self.xkb_context = xkb.xkb_context_new(xkb.CONTEXT_NO_FLAGS);
        const ctx = self.xkb_context orelse return;
        // The blob is NUL-terminated per protocol (`size` includes the terminator).
        const keymap = xkb.xkb_keymap_new_from_string(ctx, @ptrCast(map.ptr), xkb.KEYMAP_FORMAT_TEXT_V1, xkb.KEYMAP_COMPILE_NO_FLAGS) orelse return;
        const state = xkb.xkb_state_new(keymap) orelse {
            xkb.xkb_keymap_unref(keymap);
            return;
        };
        // A new keymap (layout switch, keyboard hotplug) replaces the old one wholesale.
        if (self.xkb_state) |st| xkb.xkb_state_unref(st);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    fn onKeyEnter(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface, _: ?*anyopaque) callconv(.c) void {}
    fn onKeyLeave(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface) callconv(.c) void {}

    fn onKey(data: ?*anyopaque, _: *wl.Keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.input_serial = serial;
        const pressed = state == wl.KEYBOARD_KEY_STATE_PRESSED;
        if (self.routeInput(.{ .key = .{ .key = key, .pressed = pressed } })) return;
        if (key == wl.KEY_ESC and pressed) self.closed = true;
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
        if (pressed) self.emitText(key);
    }

    /// Layout-correct text for a pressed evdev key, additive to `on_key`: 1..4 UTF-8
    /// bytes via xkbcommon (keycode = evdev + 8), control chars and DEL skipped.
    fn emitText(self: *Window, key: u32) void {
        const cb = self.opts.on_text orelse return;
        const st = self.xkb_state orelse return;
        var buf: [8]u8 = undefined;
        const n = xkb.xkb_state_key_get_utf8(st, key + 8, &buf, buf.len);
        if (n < 1 or n > 4) return; // no text, or beyond one codepoint
        const len: u8 = @intCast(n);
        if (len == 1 and (buf[0] < 0x20 or buf[0] == 0x7f)) return;
        var bytes: [4]u8 = .{ 0, 0, 0, 0 };
        @memcpy(bytes[0..len], buf[0..len]);
        cb(self, bytes, len, self.opts.user);
    }

    fn onKeyModifiers(data: ?*anyopaque, _: *wl.Keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Feed the compositor-authoritative masks straight into xkb, so shifted/altgr
        // text comes out right. `group` is the effective layout index.
        if (self.xkb_state) |st| _ = xkb.xkb_state_update_mask(st, depressed, latched, locked, 0, 0, group);
    }
    fn onKeyRepeatInfo(_: ?*anyopaque, _: *wl.Keyboard, _: i32, _: i32) callconv(.c) void {}

    // --- touch: il dito primario è sintetizzato come pointer (down→press, motion, up→release),
    //     così ogni app zrame è usabile al tocco senza modifiche. Il multi-touch (pinch) potrà
    //     esporre un callback dedicato più avanti.
    const touch_listener = wl.Touch.Listener{
        .down = onTouchDown,
        .up = onTouchUp,
        .motion = onTouchMotion,
        .frame = onTouchFrame,
        .cancel = onTouchCancel,
        .shape = onTouchShape,
        .orientation = onTouchOrientation,
    };

    fn touchEmitMotion(self: *Window, fx: f32, fy: f32) void {
        self.pointer_x = fx;
        self.pointer_y = fy;
        if (self.routeInput(.{ .motion = .{ .x = fx, .y = fy } })) return;
        // Mouse in coordinate CANVAS (come il pointer e on_draw), non content-local.
        if (self.opts.on_mouse) |cb| _ = cb(self, .{ .motion = .{ .x = fx, .y = fy } }, self.opts.user);
    }

    fn touchEmitButton(self: *Window, pressed: bool) void {
        const state: u32 = if (pressed) wl.POINTER_BUTTON_STATE_PRESSED else 0;
        if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = wl.BTN_LEFT, .pressed = pressed } })) return;
        if (self.opts.on_mouse) |cb| _ = cb(self, .{ .button = .{ .button = wl.BTN_LEFT, .state = state } }, self.opts.user);
    }

    fn onTouchDown(data: ?*anyopaque, _: *wl.Touch, _: u32, _: u32, _: ?*wl.Surface, id: i32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.touch_id != -1) return; // un solo dito primario alla volta
        self.touch_id = id;
        const s = self.scaleFactor();
        self.touchEmitMotion(wl.fixedToF32(x) * s, wl.fixedToF32(y) * s);
        self.touchEmitButton(true);
    }

    fn onTouchMotion(data: ?*anyopaque, _: *wl.Touch, _: u32, id: i32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (id != self.touch_id) return;
        const s = self.scaleFactor();
        self.touchEmitMotion(wl.fixedToF32(x) * s, wl.fixedToF32(y) * s);
    }

    fn onTouchUp(data: ?*anyopaque, _: *wl.Touch, _: u32, _: u32, id: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (id != self.touch_id) return;
        self.touchEmitButton(false);
        self.touch_id = -1;
    }

    fn onTouchCancel(data: ?*anyopaque, _: *wl.Touch) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.touch_id == -1) return;
        self.touchEmitButton(false);
        self.touch_id = -1;
    }

    fn onTouchFrame(_: ?*anyopaque, _: *wl.Touch) callconv(.c) void {}
    fn onTouchShape(_: ?*anyopaque, _: *wl.Touch, _: i32, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {}
    fn onTouchOrientation(_: ?*anyopaque, _: *wl.Touch, _: i32, _: wl.Fixed) callconv(.c) void {}

    const pointer_listener = wl.Pointer.Listener{
        .enter = onPointerEnter,
        .leave = onPointerLeave,
        .motion = onPointerMotion,
        .button = onPointerButton,
        .axis = onPointerAxis,
        .frame = onPointerFrame,
        .axis_source = onPointerAxisSource,
        .axis_stop = onPointerAxisStop,
        .axis_discrete = onPointerAxisDiscrete,
        .axis_value120 = onPointerAxisValue120,
        .axis_relative_direction = onPointerAxisRelDir,
    };

    fn onPointerEnter(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: ?*wl.Surface, _: wl.Fixed, _: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.cursor_shape = wl.CursorShapeDevice.SHAPE_DEFAULT;
        if (self.cursor_device) |device| device.setShape(serial, wl.CursorShapeDevice.SHAPE_DEFAULT);
    }

    fn onPointerLeave(data: ?*anyopaque, _: *wl.Pointer, _: u32, _: ?*wl.Surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Broadcast to every panel (none consumes `leave`) so hover states fade out,
        // then hand it to the app. `routeInput` arms the animation timer, so the fade
        // actually plays out.
        _ = self.routeInput(.leave);
        if (self.opts.on_mouse) |cb| _ = cb(self, .leave, self.opts.user);
    }
    fn onPointerMotion(data: ?*anyopaque, _: *wl.Pointer, _: u32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        // Pointer events arrive in logical surface coords; everything client-side
        // (canvas, panels, app) lives in physical buffer pixels.
        const s = self.scaleFactor();
        const fx = wl.fixedToF32(x) * s;
        const fy = wl.fixedToF32(y) * s;
        self.pointer_x = fx;
        self.pointer_y = fy;
        if (self.routeInput(.{ .motion = .{ .x = fx, .y = fy } })) return;
        if (self.opts.on_mouse) |cb| {
            // Mouse in coordinate CANVAS: lo stesso spazio del `content` rect passato a
            // `on_draw` e dei pannelli (routeInput usa fx,fy). Così l'app usa content.x/y
            // come origine per disegno E hit-test in modo coerente (niente offset titlebar).
            const consumed = cb(self, .{ .motion = .{ .x = fx, .y = fy } }, self.opts.user);
            if (consumed) {
                // The app owns this motion (e.g. hovering/dragging its own scrollbar):
                // keep the normal cursor, don't flash the resize arrows over its widget.
                self.setCursorShape(wl.CursorShapeDevice.SHAPE_DEFAULT);
                return;
            }
        }
        // Not over a panel/app widget: reflect the resize band in the cursor, else default.
        if (!self.fullscreen and !self.maximized) {
            self.setCursorShape(edgeCursor(self.resizeEdgeAt(fx, fy)));
        } else {
            self.setCursorShape(wl.CursorShapeDevice.SHAPE_DEFAULT);
        }
    }

    fn onPointerButton(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.input_serial = serial;
        const pressed = state == wl.POINTER_BUTTON_STATE_PRESSED;
        if (self.routeInput(.{ .button = .{ .x = self.pointer_x, .y = self.pointer_y, .button = button, .pressed = pressed } })) return;
        if (self.opts.on_mouse) |cb| {
            // App consumed it (e.g. grabbed its own scrollbar) → skip the default
            // window move/resize so the two don't fight over the same click.
            if (cb(self, .{ .button = .{ .button = button, .state = state } }, self.opts.user)) return;
        }
        if (button == wl.BTN_LEFT and state == wl.POINTER_BUTTON_STATE_PRESSED) {
            const edge = self.resizeEdgeAt(self.pointer_x, self.pointer_y);
            if (edge != wl.RESIZE_EDGE_NONE and !self.fullscreen and !self.maximized) {
                if (self.seat) |seat| self.toplevel.?.resize(seat, serial, edge);
            } else if (!self.opts.titlebar) {
                // No title bar to grab: keep the panel draggable from near its edge, as
                // before. With a title bar, dragging is the bar's job (see controls.zig).
                const p = self.physPanel();
                const px = self.pointer_x - p.m;
                const py = self.pointer_y - p.m;
                const w = p.w;
                const h = p.h;
                const grab = self.physPxF(30.0);
                if (px < grab or py < grab or px > w - grab or py > h - grab) {
                    if (self.seat) |seat| self.toplevel.?.move(seat, serial);
                }
            }
        }
    }

    fn onPointerAxis(data: ?*anyopaque, _: *wl.Pointer, _: u32, axis: u32, value: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.routeInput(.{ .axis = .{ .x = self.pointer_x, .y = self.pointer_y, .axis = axis, .value = wl.fixedToF32(value), .line = true } })) return;
        if (self.opts.on_scroll) |cb| cb(self, axis, value, self.opts.user);
    }
    const fractional_listener = wl.FractionalScale.Listener{ .preferred_scale = onPreferredScale };

    fn onPreferredScale(data: ?*anyopaque, _: *wl.FractionalScale, scale: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (scale == 0 or scale == self.scale120) return;
        self.scale120 = scale;
        // Buffer dimensions derive from the scale: the next redraw resizes, repaints
        // the decor and re-applies the viewport destination.
        self.needs_redraw = true;
    }

    fn onPointerFrame(_: ?*anyopaque, _: *wl.Pointer) callconv(.c) void {}
    fn onPointerAxisSource(_: ?*anyopaque, _: *wl.Pointer, _: u32) callconv(.c) void {}
    fn onPointerAxisStop(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPointerAxisDiscrete(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisValue120(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisRelDir(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
};

/// Build the blur region as the rounded panel itself: one span per row through the
/// corner arcs, one big rect for the body. wl_region only speaks rectangles, so the
/// arc becomes ~radius scanline spans — pixel-accurate, so no blur leaks past a corner.
fn addRoundedRegion(region: *wl.Region, margin: u32, pw: u32, ph: u32, radius: f32) void {
    const m: i32 = @intCast(margin);
    const w: i32 = @intCast(pw);
    const h: i32 = @intCast(ph);
    const r: i32 = @intFromFloat(@ceil(radius));
    const rows: i32 = @min(r, @divTrunc(h, 2));

    var y: i32 = 0;
    while (y < rows) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const dy = radius - fy;
        const dx = radius - @sqrt(@max(0.0, radius * radius - dy * dy));
        const inset: i32 = @intFromFloat(@ceil(dx));
        const span = w - 2 * inset;
        if (span <= 0) continue;
        region.add(m + inset, m + y, span, 1); // top arc row
        region.add(m + inset, m + h - 1 - y, span, 1); // bottom arc row
    }
    if (h > 2 * rows) region.add(m, m + rows, w, h - 2 * rows);
}
