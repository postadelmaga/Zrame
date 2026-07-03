//! # zrame — the window layer of the Frame architecture
//!
//! zicro deliberately stops at the `FrameSink` contract; zrame picks up from there:
//! a frameless Wayland toplevel with client-side chrome (rounded glass, drop shadow),
//! real compositor background blur via `ext-background-effect-v1`, and a thread-safe
//! present path that plugs straight into zicro's video data plane.
//!
//! | file         | role                                                        |
//! |--------------|-------------------------------------------------------------|
//! | `wl.zig`     | hand-written libwayland-client FFI + protocol wrappers      |
//! | `paint.zig`  | premultiplied ARGB software canvas, SDF chrome              |
//! | `window.zig` | the frameless glass window + event loop                     |
//! | `sink.zig`   | zicro `video.FrameSink` adapter                             |

pub const wl = @import("wl.zig");
pub const paint = @import("paint.zig");
pub const window = @import("window.zig");
pub const sink = @import("sink.zig");

pub const Window = window.Window;
pub const Options = window.Options;
pub const Style = window.Style;
pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const Color = paint.Color;
pub const Canvas = paint.Canvas;
pub const WindowSink = sink.WindowSink;

test {
    @import("std").testing.refAllDecls(@This());
}
