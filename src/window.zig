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

const wl = @import("wl.zig");
const paint = @import("paint.zig");
const text = @import("text.zig");

pub const Style = paint.Style;

pub const Options = struct {
    title: [:0]const u8 = "zrame",
    app_id: [:0]const u8 = "dev.zrame.window",
    /// Initial size of the glass panel (the xdg window geometry), in pixels.
    width: u32 = 720,
    height: u32 = 460,
    style: Style = .{},
    /// Optional painter invoked after the chrome, before any staged frame:
    /// draws app content directly on the canvas (window thread).
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    /// Optional key handler (evdev keycode, keyboard key state).
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    /// Optional scroll handler (axis, discrete/value).
    on_scroll: ?*const fn (window: *Window, axis: u32, value: i32, user: ?*anyopaque) void = null,
    /// Optional mouse event handler (motion or button clicks).
    on_mouse: ?*const fn (window: *Window, event: MouseEvent, user: ?*anyopaque) void = null,
    user: ?*anyopaque = null,
};

pub const MouseEvent = union(enum) {
    motion: struct { x: f32, y: f32 },
    button: struct { button: u32, state: u32 },
};

/// The panel-content rectangle in canvas coordinates.
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

const Staged = struct {
    pixels: std.ArrayList(u8) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    /// Set by `presentRgba`, cleared when `redraw` swaps the frame to the front slot.
    fresh: bool = false,
};

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
const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.state.unlock();
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

    surface: ?*wl.Surface = null,
    xdg_surface: ?*wl.XdgSurface = null,
    toplevel: ?*wl.XdgToplevel = null,
    blur: ?*wl.BackgroundEffectSurface = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    cursor_device: ?*wl.CursorShapeDevice = null,

    /// Panel (window-geometry) size; buffer size adds the shadow margin on each side.
    panel_w: u32,
    panel_h: u32,
    configured: bool = false,
    needs_redraw: bool = false,
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
    // Motore di testo (stb_truetype), creato pigramente al primo uso: font di
    // default Hack regular+bold, sostituibile con `setFont`/`loadFont`.
    font: ?text.Font = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,

    // wl_shm double buffer, one pool + mapping shared by both slots.
    shm_fd: posix.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    pool: ?*wl.ShmPool = null,
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

    pub fn init(gpa: Allocator, opts: Options) !*Window {
        const display = wl.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        errdefer wl.wl_display_disconnect(display);

        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        const wake_fd: posix.fd_t = @intCast(efd);
        errdefer _ = linux.close(wake_fd);

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
        };
        self.panel_w = @max(self.panel_w, self.minPanel());
        self.panel_h = @max(self.panel_h, self.minPanel());

        self.registry.setListener(&registry_listener, self);
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        if (self.compositor == null or self.shm == null or self.wm_base == null)
            return error.MissingWaylandGlobals;

        self.wm_base.?.setListener(&wm_base_listener, self);

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

        // First commit carries no buffer; the compositor answers with configure and
        // only then may we attach pixels.
        surface.commit();
        if (wl.wl_display_roundtrip(display) < 0) return error.WaylandIo;
        return self;
    }

    pub fn deinit(self: *Window) void {
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
        if (self.blur) |b| wl.wl_proxy_destroy(@ptrCast(b));
        if (self.cursor_device) |c| wl.wl_proxy_destroy(@ptrCast(c));
        if (self.keyboard) |k| wl.wl_proxy_destroy(@ptrCast(k));
        if (self.pointer) |p| wl.wl_proxy_destroy(@ptrCast(p));
        if (self.toplevel) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |x| wl.wl_proxy_destroy(@ptrCast(x));
        if (self.surface) |s| s.destroy();
        wl.wl_display_disconnect(self.display);
        _ = linux.close(self.wake_fd);
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
        const need = @as(usize, width) * @as(usize, height) * 4;
        if (rgba.len < need) return;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.staged.pixels.clearRetainingCapacity();
            self.staged.pixels.appendSlice(self.gpa, rgba[0..need]) catch {
                // Keep the invariant `pixels.len == width * height * 4`: a stale
                // width over emptied pixels would send redraw out of bounds.
                self.staged.width = 0;
                self.staged.height = 0;
                self.staged.fresh = false;
                return;
            };
            self.staged.width = width;
            self.staged.height = height;
            self.staged.fresh = true;
        }
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

    /// The event loop: blocks until the window is closed or the connection drops.
    pub fn run(self: *Window) !void {
        while (!self.closed) {
            while (wl.wl_display_prepare_read(self.display) != 0) {
                if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            }
            _ = wl.wl_display_flush(self.display);

            var fds = [_]posix.pollfd{
                .{ .fd = wl.wl_display_get_fd(self.display), .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
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

            if (self.configured and self.needs_redraw) try self.redraw();
        }
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

    // --- drawing --------------------------------------------------------------------

    /// Smallest panel the chrome stays legible at; also what we advertise as min size.
    fn minPanel(self: *const Window) u32 {
        return 4 * self.opts.style.margin;
    }

    fn contentRect(self: *Window) Rect {
        const m = self.opts.style.margin;
        return .{ .x = m, .y = m, .w = self.panel_w, .h = self.panel_h };
    }

    fn redraw(self: *Window) !void {
        const m = self.opts.style.margin;
        const bw = self.panel_w + 2 * m;
        const bh = self.panel_h + 2 * m;
        if (bw != self.buf_w or bh != self.buf_h) try self.resizeBuffers(bw, bh);

        const slot = self.freeSlot() orelse return; // both busy: retry on next wake
        @memcpy(slot.pixels, self.decor);
        var canvas = paint.Canvas.init(slot.pixels, bw, bh);

        if (self.opts.on_draw) |draw| draw(&canvas, self.contentRect(), self.opts.user);

        // Take the newest frame with a buffer swap: the lock is held for a few word
        // writes, never for the per-pixel blit, so producers don't spin behind it.
        // The swapped-out front buffer becomes the producer's next staging capacity.
        self.mutex.lock();
        if (self.staged.fresh) {
            std.mem.swap(Staged, &self.staged, &self.front);
            self.staged.fresh = false;
        }
        self.mutex.unlock();

        if (self.front.width > 0) {
            const content = self.contentRect();
            const fw = @min(self.front.width, content.w);
            const fh = @min(self.front.height, content.h);
            const dx = content.x + (content.w - fw) / 2;
            const dy = content.y + (content.h - fh) / 2;
            canvas.blitRgba(dx, dy, self.front.pixels.items, self.front.width, self.front.height, self.opts.style);
        }

        const surface = self.surface.?;
        surface.attach(slot.buffer, 0, 0);
        surface.damageBuffer(0, 0, @intCast(bw), @intCast(bh));
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
        self.buf_w = 0;
        self.buf_h = 0;
    }

    fn resizeBuffers(self: *Window, bw: u32, bh: u32) !void {
        self.dropBuffers();

        const stride = @as(usize, bw) * 4;
        const slot_size = stride * @as(usize, bh);
        const total = slot_size * self.slots.len;

        const fd = try posix.memfd_create("zrame-shm", linux.MFD.CLOEXEC);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(total))) != .SUCCESS) return error.ShmSetupFailed;
        const map = try posix.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);

        self.shm_fd = fd;
        self.shm_map = map;
        self.pool = self.shm.?.createPool(fd, @intCast(total));
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
        canvas.drawChrome(self.opts.style);
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
        } else if (std.mem.eql(u8, iface, "ext_background_effect_manager_v1")) {
            self.blur_manager = @ptrCast(registry.bind(name, &wl.ext_background_effect_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shapes = @ptrCast(registry.bind(name, &wl.wp_cursor_shape_manager_v1_interface, 1).?);
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
        // During init (before run()) the loop isn't pumping yet: draw right here so the
        // window appears mapped after the first roundtrip.
        self.redraw() catch {};
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
    // xdg_toplevel.state
    const STATE_FULLSCREEN: u32 = 2;

    fn onToplevelConfigure(data: ?*anyopaque, _: *wl.XdgToplevel, width: i32, height: i32, states: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));

        // Rileva lo stato fullscreen dall'array di stati del compositore.
        var is_fs = false;
        if (states) |sp| {
            const arr: *const WlArray = @ptrCast(@alignCast(sp));
            if (arr.data) |d| {
                const n = arr.size / @sizeOf(u32);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    if (d[i] == STATE_FULLSCREEN) is_fs = true;
                }
            }
        }

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
                self.opts.style.margin = 0;
                self.opts.style.corner_radius = 0;
            } else {
                self.opts.style.margin = self.saved_margin;
                self.opts.style.corner_radius = self.saved_radius;
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

    fn onConfigureBounds(_: ?*anyopaque, _: *wl.XdgToplevel, _: i32, _: i32) callconv(.c) void {}
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

    fn onKeymap(_: ?*anyopaque, _: *wl.Keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
        // Keys arrive as raw evdev codes, which is all we need; the xkb keymap fd
        // would leak if we didn't close it.
        _ = linux.close(fd);
    }

    fn onKeyEnter(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface, _: ?*anyopaque) callconv(.c) void {}
    fn onKeyLeave(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface) callconv(.c) void {}

    fn onKey(data: ?*anyopaque, _: *wl.Keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (key == wl.KEY_ESC and state == wl.KEYBOARD_KEY_STATE_PRESSED) self.closed = true;
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
    }

    fn onKeyModifiers(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onKeyRepeatInfo(_: ?*anyopaque, _: *wl.Keyboard, _: i32, _: i32) callconv(.c) void {}

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
        if (self.cursor_device) |device| device.setShape(serial, wl.CursorShapeDevice.SHAPE_DEFAULT);
    }

    fn onPointerLeave(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: ?*wl.Surface) callconv(.c) void {}
    fn onPointerMotion(data: ?*anyopaque, _: *wl.Pointer, _: u32, x: wl.Fixed, y: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const fx = wl.fixedToF32(x);
        const fy = wl.fixedToF32(y);
        self.pointer_x = fx;
        self.pointer_y = fy;
        if (self.opts.on_mouse) |cb| {
            cb(self, .{ .motion = .{ .x = fx, .y = fy } }, self.opts.user);
        }
    }

    fn onPointerButton(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.opts.on_mouse) |cb| {
            cb(self, .{ .button = .{ .button = button, .state = state } }, self.opts.user);
        }
        if (button == wl.BTN_LEFT and state == wl.POINTER_BUTTON_STATE_PRESSED) {
            const m = @as(f32, @floatFromInt(self.opts.style.margin));
            const px = self.pointer_x - m;
            const py = self.pointer_y - m;
            const w = @as(f32, @floatFromInt(self.panel_w));
            const h = @as(f32, @floatFromInt(self.panel_h));
            const near_edge = (px < 30.0 or py < 30.0 or px > w - 30.0 or py > h - 30.0);
            if (near_edge) {
                if (self.seat) |seat| self.toplevel.?.move(seat, serial);
            }
        }
    }

    fn onPointerAxis(data: ?*anyopaque, _: *wl.Pointer, _: u32, axis: u32, value: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.opts.on_scroll) |cb| cb(self, axis, value, self.opts.user);
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
