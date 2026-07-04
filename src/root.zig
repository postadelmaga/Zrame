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

const zicro = @import("zicro");
pub const wl = zicro.wl;
pub const paint = zicro.paint;
pub const window = @import("window.zig");
pub const sink = @import("sink.zig");
pub const text = zicro.text;
pub const plugin = @import("plugin.zig");
pub const ui = @import("ui.zig");
pub const controls = @import("controls.zig");
pub const menu = @import("menu.zig");
pub const scroll = @import("scroll.zig");
pub const sdbus = @import("sdbus.zig");
pub const tray = @import("tray.zig");
pub const dbusmenu = @import("dbusmenu.zig");
pub const appmenu = @import("appmenu.zig");

pub const Window = window.Window;
pub const Options = window.Options;
pub const Style = window.Style;
pub const Rect = window.Rect;
pub const MouseEvent = window.MouseEvent;
pub const Color = paint.Color;
pub const Canvas = paint.Canvas;
pub const WindowSink = sink.WindowSink;
pub const Font = text.Font;
pub const TextStyle = text.Style;
pub const TextOpts = paint.TextOpts;
pub const Panel = plugin.Panel;
pub const Host = plugin.Host;
pub const TitlebarStyle = window.TitlebarStyle;
pub const Registry = plugin.Registry;
pub const Event = plugin.Event;
pub const Action = plugin.Action;
pub const Info = plugin.Info;

test {
    @import("std").testing.refAllDecls(@This());
}
