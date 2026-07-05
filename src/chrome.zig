//! # zrame.chrome — the backend-agnostic frame composition
//!
//! Everything a window backend does that is *not* talking to the OS: the cross-thread
//! frame mailbox (`Staged` + `SpinLock`, staged under `presentRgba`, swapped on the window
//! thread) and the composition itself (`composeContent`: the app `on_draw` overlay, the
//! newest staged content frame blitted into the content rect, then the panel stack on
//! top). Both `window_wayland.zig` and `window_win32.zig` share this, so the one thing most
//! likely to drift between platforms — *how a frame is composited* — lives in one place.
//!
//! Backends keep only the transport: acquiring a writable pixel buffer, filling its
//! background (glass chrome on Wayland, an opaque fill on Win32), calling `composeContent`,
//! and presenting the result however the OS allows.

const std = @import("std");
const zicro = @import("zicro");
const paint = zicro.paint;
const plugin = @import("plugin.zig");

const Rect = plugin.Rect;

/// The staged/front RGBA frame. `presentRgba` fills `staged`; the window thread swaps it
/// into `front` before compositing, so the per-pixel blit never runs under the lock.
pub const Staged = struct {
    pixels: std.ArrayList(u8) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    /// Set by `stageFrame`, cleared when `swapFront` moves the frame to the front slot.
    fresh: bool = false,
};

/// Zig 0.16 keeps blocking mutexes behind `std.Io`; the staging handoff is a short,
/// bounded copy at frame cadence, so a spin on a lock-free flag is simpler than threading
/// an `Io` through the window.
pub const SpinLock = struct {
    flag: std.atomic.Value(bool) = .init(false),
    pub fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Stage a straight-alpha RGBA frame (thread-safe, newest wins). Returns true when a fresh
/// frame is staged — the caller then wakes its window thread (eventfd write / PostMessage).
/// On OOM the staged frame is invalidated (so a stale width can't send a later blit out of
/// bounds) and false is returned.
pub fn stageFrame(gpa: std.mem.Allocator, lock: *SpinLock, staged: *Staged, width: u32, height: u32, rgba: []const u8) bool {
    const need = @as(usize, width) * @as(usize, height) * 4;
    if (rgba.len < need) return false;
    lock.lock();
    defer lock.unlock();
    staged.pixels.clearRetainingCapacity();
    staged.pixels.appendSlice(gpa, rgba[0..need]) catch {
        staged.width = 0;
        staged.height = 0;
        staged.fresh = false;
        return false;
    };
    staged.width = width;
    staged.height = height;
    staged.fresh = true;
    return true;
}

/// Take the newest staged frame with a buffer swap: the lock is held for a few word writes,
/// never for the per-pixel blit, so producers don't spin behind it. The swapped-out front
/// buffer becomes the producer's next staging capacity.
pub fn swapFront(lock: *SpinLock, staged: *Staged, front: *Staged) void {
    lock.lock();
    defer lock.unlock();
    if (staged.fresh) {
        std.mem.swap(Staged, staged, front);
        staged.fresh = false;
    }
}

/// Composite the app content into a canvas whose background the backend has already filled:
/// the `on_draw` overlay, then the newest `front` frame centered in `content`, then the
/// panel stack on top. No windowing-system call and no lock happens here.
pub fn composeContent(
    canvas: *paint.Canvas,
    content: Rect,
    front: *const Staged,
    style: paint.Style,
    panels: *plugin.Registry,
    host: plugin.Host,
    on_draw: ?*const fn (*paint.Canvas, Rect, ?*anyopaque) void,
    user: ?*anyopaque,
) void {
    if (on_draw) |draw| draw(canvas, content, user);

    if (front.width > 0) {
        const fw = @min(front.width, content.w);
        const fh = @min(front.height, content.h);
        const dx = content.x + (content.w - fw) / 2;
        const dy = content.y + (content.h - fh) / 2;
        canvas.blitRgba(dx, dy, front.pixels.items, front.width, front.height, style);
    }

    // Panels (title bar, scrollbars, context menu, plugins) composite last, on top of both
    // the app content and any video frame.
    panels.draw(canvas, host);
}
