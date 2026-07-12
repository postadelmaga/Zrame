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

const paint = @import("zicro").paint;
const plugin = @import("plugin.zig");
const controls = @import("controls.zig");
const dbusmenu = @import("dbusmenu.zig");

pub const Style = paint.Style;
pub const Panel = plugin.Panel;
pub const Host = plugin.Host;
pub const TitlebarStyle = controls.Layout;

/// The panel-content rectangle in canvas coordinates (shared with the plugin seam).
pub const Rect = plugin.Rect;

/// The concrete window struct for this target. Selected at comptime; the backends
/// mutually import this file for the shared types below, so `*Window` in a callback
/// signature is exactly the backend struct the caller receives.
pub const Window = switch (builtin.os.tag) {
    .windows => @import("window_win32.zig").Window,
    .macos => @import("window_cocoa.zig").Window,
    else => @import("window_wayland.zig").Window,
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

/// Declarative tray-icon config (see `tray.zig`). `on_activate` fires on left-click.
/// Linux-only in effect (StatusNotifierItem over DBus); ignored on other platforms.
pub const TrayConfig = struct {
    id: [:0]const u8 = "dev.zrame.window",
    title: [:0]const u8 = "zrame",
    icon_name: [:0]const u8 = "application-x-executable",
    tooltip: [:0]const u8 = "",
    on_activate: ?*const fn (window: *Window, user: ?*anyopaque) void = null,
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
    /// Optional system-tray icon (StatusNotifierItem over DBus). Linux-only; a no-op
    /// elsewhere.
    tray: ?TrayConfig = null,
    /// Optional KDE global menu (`com.canonical.dbusmenu`). Linux-only; a no-op elsewhere.
    menu: ?[]const dbusmenu.Item = null,
    user: ?*anyopaque = null,
};
