//! # zrame.window — the public window facade
//!
//! The window comes in one of two shapes depending on the target OS:
//!
//! | os       | backend             | transport                              |
//! |----------|---------------------|----------------------------------------|
//! | linux    | `window_wayland.zig`| frameless Wayland toplevel, client-side glass chrome, compositor blur |
//! | windows  | `window_win32.zig`  | native decorated window, GDI blit      |
//!
//! Both backends expose the SAME public surface (`init`/`run`/`presentRgba`/
//! `waitFrame`/`toggleFullscreen`/`setStyle`/`animateResize`/`close` + the
//! `panel_w`/`panel_h`/`closed` fields), so callers — and zrame's own `sink.zig` —
//! are backend-agnostic. `waitFrame(timeout_ms)` blocks any thread until the
//! compositor's next frame callback (Wayland); on Win32 it returns false at once
//! and callers fall back to their own software pacer.
//! This file owns the platform-independent public *types* both backends share, so the
//! callback signatures (`fn (window: *Window, …)`) resolve to the selected backend.

const std = @import("std");
const builtin = @import("builtin");

const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const dbusmenu = @import("dbusmenu.zig");

pub const Style = paint.Style;
pub const Panel = plugin.Panel;
pub const Host = plugin.Host;
pub const TitlebarStyle = controls.Layout;

/// The panel-content rectangle in canvas coordinates (shared with the plugin seam).
pub const Rect = plugin.Rect;

/// Device form factor, classified from the logical (dp) content width. Apps reflow
/// their layout on this — collapse side panels, shrink the toolbar to essentials —
/// instead of hardcoding pixel thresholds.
pub const FormFactor = enum { phone, tablet, desktop };

/// Responsive metrics computed by the substrate from each backend's raw signals
/// (physical content size + display scale + touch), so every zrame app is responsive
/// the same way on web AND native/mobile without reinventing it.
///
/// - `w_dp`/`h_dp`: logical content size in **dp** (physical px ÷ `dpr`) — device
///   independent, the space breakpoints live in.
/// - `dpr`: display density (`devicePixelRatio` / native scale) — crispness only.
/// - `class`: [`FormFactor`], for reflow decisions.
/// - `touch`: touch-primary device — keep hit targets large.
/// - `ui_scale`: a density multiplier for DRAWING (on top of `dpr`). 1.0 through
///   normal sizes, growing toward **φ** (the golden ratio) on very large displays so
///   the UI doesn't look lost; never below 1.0, so touch targets never shrink (small
///   screens adapt by reflow, not by zoom).
pub const Metrics = struct {
    w_dp: f32,
    h_dp: f32,
    dpr: f32,
    class: FormFactor,
    touch: bool,
    ui_scale: f32,
};

// Breakpoints scanned by the golden ratio: phone→tablet at `phone_max`, tablet→desktop
// at `phone_max·φ`. Density (`ui_scale`) stays 1.0 up to `dense_ref = phone_max·φ²` and
// climbs to φ beyond it. One φ (`zicro.phi`) drives the whole responsive scale.
const phone_max: f32 = 640; // dp: below this the layout is a single column (phone)
const tablet_max: f32 = phone_max * zicro.phi; // ≈ 1035 dp
const dense_ref: f32 = phone_max * zicro.phi * zicro.phi; // ≈ 1675 dp: below → ui_scale 1.0

/// Builds [`Metrics`] from a backend's raw signals: `w_px`/`h_px` are PHYSICAL content
/// pixels, `dpr_in` the display scale, `touch` whether the device is touch-primary.
pub fn computeMetrics(dpr_in: f32, w_px: u32, h_px: u32, touch: bool) Metrics {
    const dpr = if (dpr_in > 0) dpr_in else 1.0;
    const w_dp = @as(f32, @floatFromInt(w_px)) / dpr;
    const h_dp = @as(f32, @floatFromInt(h_px)) / dpr;
    const class: FormFactor = if (w_dp < phone_max) .phone else if (w_dp < tablet_max) .tablet else .desktop;
    // Density: 1.0 until `dense_ref`, then grow to φ. Clamped both ends — never shrinks
    // below 1.0 (touch targets stay put), never past φ (stops looking cartoonish on 8K).
    const ui_scale = std.math.clamp(w_dp / dense_ref, 1.0, zicro.phi);
    return .{ .w_dp = w_dp, .h_dp = h_dp, .dpr = dpr, .class = class, .touch = touch, .ui_scale = ui_scale };
}

/// The concrete window struct for this target. Selected at comptime; the backends
/// mutually import this file for the shared types below, so `*Window` in a callback
/// signature is exactly the backend struct the caller receives.
pub const Window = switch (builtin.os.tag) {
    .windows => @import("window_win32.zig").Window,
    .macos => @import("window_cocoa.zig").Window,
    // WebAssembly: a thin adapter over zicro's web window that paints the glass chrome
    // into a browser <canvas>. (freestanding wasm falls here, not the Wayland else.)
    else => if (builtin.cpu.arch.isWasm())
        @import("window_web.zig").Window
    else if (builtin.abi == .android or builtin.abi == .androideabi)
        @import("window_android.zig").Window
    else
        @import("window_wayland.zig").Window,
};

/// Mouse events delivered to the app's `on_mouse` callback.
///
/// Motion coordinates are in the app's PRESENTATION space, not canvas space: the origin
/// is the top-left of the frame the app last staged with `presentRgba` (zrame centers it
/// in the content rect), or the content rect itself before any frame is staged. So an
/// app hit-tests with the same coordinates it drew with, and never sees the shadow
/// gutter, title bar, or frame-centering offsets — the client-coordinates contract of
/// mainstream toolkits (Win32 client area, Cocoa view coords, SDL logical presentation).
/// Chrome-space input (panels, resize bands) stays inside zrame in canvas coordinates.
pub const MouseEvent = union(enum) {
    motion: struct { x: f32, y: f32 },
    button: struct { button: u32, state: u32 },
    /// The pointer left the window surface: apps drop hover state (highlighted rows,
    /// custom cursors). Carries no position.
    leave,
};

/// Gesto multi-touch riconosciuto dal substrato (pinch, …). Un dito arriva come evento
/// mouse su `on_mouse`; due dita qui. `scale` = rapporto di zoom incrementale, `(cx,cy)` il
/// centro, `(dx,dy)` la traslazione — l'app zooma/pana a modo suo. Vedi `zicro.gesture`.
pub const GestureEvent = zicro.gesture.Gesture;

/// Declarative tray-icon config (see `tray.zig`). `on_activate` fires on left-click.
/// Linux-only in effect (StatusNotifierItem over DBus); ignored on other platforms.
pub const TrayConfig = struct {
    id: [:0]const u8 = "dev.zrame.window",
    title: [:0]const u8 = "zrame",
    icon_name: [:0]const u8 = "application-x-executable",
    tooltip: [:0]const u8 = "",
    on_activate: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
};

/// How a presented GPU frame (`presentDmabuf`) is placed in the content rect.
pub const VideoFit = enum {
    /// The frame FILLS the content rect (wp_viewport scales it on the scanout
    /// path, for free). Its pixel size is then a quality knob — the resolution
    /// tier, dynamic-res, FSR — and not a statement about how big the window is.
    /// This is what a window whose whole content IS the render wants; anything
    /// else leaves a border of empty glass around it.
    fill,
    /// The frame is presented at its native size, centered. For a window whose
    /// render is a PANEL inside a larger card — the rest of the content rect
    /// belongs to `on_draw` (text, chrome) and must not be painted over.
    native,
};

pub const Options = struct {
    title: [:0]const u8 = "zrame",
    app_id: [:0]const u8 = "dev.zrame.window",
    /// Initial size of the glass panel (the window geometry), in pixels.
    width: u32 = 720,
    height: u32 = 460,
    style: Style = .{},
    /// Draw a client-side title bar with window controls (see [`TitlebarStyle`]). Off by
    /// default so bare content windows keep the whole panel; the content rect shrinks by
    /// `titlebar_height` when on. Ignored on platforms that use native decorations.
    titlebar: bool = false,
    /// Title-bar height in panel pixels.
    titlebar_height: u32 = 38,
    /// Traffic-lights (macOS) or right-aligned buttons (Material). Default macOS.
    titlebar_style: TitlebarStyle = .macos,
    /// Where a staged GPU frame lands in the content rect (see [`VideoFit`]).
    video_fit: VideoFit = .fill,
    /// Client-drawn right-click window menu (Minimize/Maximize/Full Screen/Close).
    context_menu: bool = true,
    /// Close the window on ESC (handy for demo/tool windows). Apps that use ESC
    /// themselves (dialogs, editors) turn this off and decide in `on_key`.
    close_on_esc: bool = true,
    /// Optional painter invoked after the chrome, before any staged frame:
    /// draws app content directly on the canvas (window thread).
    on_draw: ?*const fn (canvas: *paint.Canvas, content: Rect, user: ?*anyopaque) void = null,
    /// Optional key handler (evdev keycode, key state: 1 pressed / 0 released). Win32
    /// translates VK codes to the same evdev codes so handlers are cross-platform.
    on_key: ?*const fn (window: *Window, key: u32, state: u32, user: ?*anyopaque) void = null,
    /// Optional text-input handler, additive to `on_key` (which keeps firing unchanged):
    /// on every key press that produces printable text under the ACTIVE keyboard layout
    /// (xkbcommon on Wayland, `WM_CHAR` on Win32), `bytes[0..len]` carries one UTF-8
    /// encoded codepoint (1..4 bytes). Control characters and DEL never fire. When layout
    /// translation is unavailable (no keymap) it simply never fires — apps fall back to
    /// their own `on_key` mapping.
    on_text: ?*const fn (window: *Window, bytes: [4]u8, len: u8, user: ?*anyopaque) void = null,
    /// Optional scroll handler (axis: 0 vertical / 1 horizontal, value in 1/256 units).
    on_scroll: ?*const fn (window: *Window, axis: u32, value: i32, user: ?*anyopaque) void = null,
    /// Optional mouse event handler (motion, button clicks, leave). Motion coordinates
    /// are in **canvas coordinates** — the same space as the `content` rect passed to
    /// `on_draw` (so use `content.x/content.y` as the origin for both drawing and
    /// hit-testing). Returns **true to consume** the event so the window skips its
    /// default handling.
    on_mouse: ?*const fn (window: *Window, event: MouseEvent, user: ?*anyopaque) bool = null,
    /// Optional multi-touch gesture handler (pinch, …) recognised by the substrate. Single
    /// touch still arrives through `on_mouse`; two fingers here. See [`GestureEvent`].
    on_gesture: ?*const fn (window: *Window, gesture: GestureEvent, user: ?*anyopaque) void = null,
    /// Optional system-tray icon (StatusNotifierItem over DBus). Linux-only; a no-op
    /// elsewhere.
    tray: ?TrayConfig = null,
    /// Optional KDE global menu (`com.canonical.dbusmenu`). Linux-only; a no-op elsewhere.
    menu: ?[]const dbusmenu.Item = null,
    user: ?*anyopaque = null,
};
