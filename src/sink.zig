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
};
