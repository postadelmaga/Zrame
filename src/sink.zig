//! # zrame.sink — the zicro seam
//!
//! zicro's `video.zig` ends at a contract: *"The actual GPU/window backend is the
//! app's job — the framework only needs `FrameSink.present`."* This file is that
//! backend. [`WindowSink`] adapts a zrame [`Window`] to zicro's `FrameSink`, so a
//! standard zicro pipeline — producer → `media.latest` → `VideoSink` module — lands
//! its frames inside the glass panel.
//!
//! `present` is called on the VideoSink module's thread; `Window.presentRgba` is the
//! window's thread-safe door (stage + eventfd), so no Wayland object is ever touched
//! off the window thread.

const std = @import("std");
const zicro = @import("zicro");

const window = @import("window.zig");

pub const WindowSink = struct {
    win: *window.Window,

    pub fn init(win: *window.Window) WindowSink {
        return .{ .win = win };
    }

    /// zicro `FrameSink` entry point. `bgra8` frames are swizzled to RGBA on the way in.
    pub fn present(self: *WindowSink, frame: *const zicro.media.Frame) void {
        const pixels = frame.pixels.slice();
        switch (frame.format) {
            .rgba8 => self.win.presentRgba(frame.width, frame.height, pixels),
            .bgra8 => {
                // Rare path, so the swizzle buffer is per-call.
                const swizzled = self.win.gpa.alloc(u8, pixels.len) catch return;
                defer self.win.gpa.free(swizzled);
                var i: usize = 0;
                while (i < pixels.len) : (i += 4) {
                    swizzled[i] = pixels[i + 2];
                    swizzled[i + 1] = pixels[i + 1];
                    swizzled[i + 2] = pixels[i];
                    swizzled[i + 3] = pixels[i + 3];
                }
                self.win.presentRgba(frame.width, frame.height, swizzled);
            },
        }
    }

    /// The vtable zicro's `VideoSink` module wants.
    pub fn frameSink(self: *WindowSink) zicro.video.FrameSink {
        return zicro.video.FrameSink.of(WindowSink, self);
    }

    /// zicro `GpuFrameSink` entry point — present a dmabuf frame with **no CPU
    /// copy**: the plane fd goes straight to the desynced video subsurface. This
    /// keeps the fast path inside the zicro contract instead of forcing the app to
    /// call `presentDmabuf` directly. Returns `false` when the window has no
    /// dmabuf/subcompositor support (the caller falls back to a CPU `Frame`).
    /// Single-plane RGBA today; the first plane's fd/stride drive the present.
    pub fn presentGpu(self: *WindowSink, frame: *const zicro.video.GpuFrame) bool {
        if (frame.planes.len == 0) return false;
        const plane = frame.planes[0];
        return self.win.presentDmabuf(
            frame.slot,
            plane.fd,
            frame.width,
            frame.height,
            plane.stride,
            frame.fourcc,
            frame.modifier,
        );
    }

    /// The vtable zicro wants for the zero-copy GPU path.
    pub fn gpuFrameSink(self: *WindowSink) zicro.video.GpuFrameSink {
        return zicro.video.GpuFrameSink.of(WindowSink, self);
    }
};
