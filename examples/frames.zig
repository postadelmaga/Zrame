//! `zig build run-frames`
//!
//! The full Frame spine, on screen: a zicro **source** (`Painter`) renders an animated
//! plasma into `media.Frame`s at 60 Hz and pushes them down the zero-copy data plane
//! (`media.latest`); zicro's stock **`VideoSink` module** pumps the freshest frame into
//! zrame's `WindowSink`; the frame lands inside a frameless, blurred, rounded,
//! shadowed glass window. Three threads, no shared state outside the channel.

const std = @import("std");
const zicro = @import("zicro");
const zrame = @import("zrame");

const content_w: u32 = 600;
const content_h: u32 = 360;

/// A source module: paints plasma frames and sends them latest-wins.
const Painter = struct {
    sender: zicro.media.LatestSender(zicro.media.Frame),

    pub fn id(_: *Painter) []const u8 {
        return "painter";
    }

    pub fn run(self: *Painter, ctx: *zicro.ModuleCtx) anyerror!void {
        defer self.sender.deinit();
        const rgba = try ctx.gpa.alloc(u8, content_w * content_h * 4);
        defer ctx.gpa.free(rgba);

        var pacer = zicro.time.Pacer.hz(ctx.io, 60);
        var t: f32 = 0;
        while (!ctx.shouldStop()) {
            t += 0.016;
            plasma(rgba, t);
            const frame = zicro.media.Frame.init(ctx.gpa, content_w, content_h, .rgba8, rgba) catch break;
            self.sender.send(frame) catch {
                var owned = frame;
                owned.deinit();
                break; // window gone: nothing left to paint for
            };
            _ = pacer.tick();
        }
    }

    fn plasma(rgba: []u8, t: f32) void {
        var y: u32 = 0;
        while (y < content_h) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) / content_h;
            var x: u32 = 0;
            while (x < content_w) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) / content_w;
                const v = @sin(fx * 7.0 + t) + @sin((fy * 5.0 + t) * 1.3) +
                    @sin((fx + fy) * 6.0 - t * 0.7);
                const p = rgba[(@as(usize, y) * content_w + x) * 4 ..][0..4];
                p[0] = @intFromFloat(90.0 + 60.0 * @sin(v * std.math.pi * 0.5));
                p[1] = @intFromFloat(120.0 + 80.0 * @sin(v * std.math.pi * 0.5 + 2.1));
                p[2] = @intFromFloat(160.0 + 90.0 * @sin(v * std.math.pi * 0.5 + 4.2));
                p[3] = 110; // translucent: the plasma floats *in* the glass
            }
        }
    }
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — zicro frames",
        .app_id = "dev.zrame.frames",
        .width = content_w + 40,
        .height = content_h + 40,
        .style = .{
            .glass = zrame.Color.rgba(15, 15, 20, 0.35),
            .glass_fade_width = 30.0,
            .content_radius = 18.0,
            .content_fade_width = 25.0,
        },
    });
    defer win.deinit();

    // sources → world → sinks, minus the world: pixels don't need a reducer.
    var app = try zicro.App.init(gpa, io);
    const sender, const receiver = try zicro.media.latest(zicro.media.Frame, gpa, io);

    var window_sink = zrame.WindowSink.init(win);
    var video_sink = zicro.video.VideoSink.init("video", receiver, window_sink.frameSink());
    try app.sink(zicro.Module.of(zicro.video.VideoSink, &video_sink));
    var painter: Painter = .{ .sender = sender };
    try app.source(zicro.Module.of(Painter, &painter));

    // The window owns the main thread until the user closes it; then the app winds down.
    try win.run();
    var report = app.shutdownAndJoin();
    defer report.deinit();
    app.deinit();
    if (!report.isClean()) std.debug.print("modules failed: {d}\n", .{report.failed.len});
}
