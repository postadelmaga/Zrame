//! `zig build run-hello`
//!
//! The smallest zrame program: one frameless glass window — transparent, background
//! blur from the compositor, rounded corners, drop shadow. Drag anywhere to move it,
//! press Esc to close it.

const std = @import("std");
const zrame = @import("zrame");

fn drawContent(canvas: *zrame.Canvas, content: zrame.Rect, _: ?*anyopaque) void {
    // A few floating tiles, just to show translucent content over the frosted panel.
    const cx: f32 = @floatFromInt(content.x);
    const cy: f32 = @floatFromInt(content.y);
    canvas.fillRoundedRect(cx + 32, cy + 32, 180, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
    canvas.fillRoundedRect(cx + 32, cy + 78, 120, 26, 13, zrame.Color.rgba(137, 180, 250, 0.45));
    canvas.fillRoundedRect(cx + 168, cy + 78, 44, 26, 13, zrame.Color.rgba(243, 139, 168, 0.45));
}

fn runWindow(win: *zrame.Window) void {
    win.run() catch {};
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const win1 = try zrame.Window.init(gpa, .{
        .title = "zrame — Window A (Baseline)",
        .app_id = "dev.zrame.hello.a",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .style = .{
            .glass = zrame.Color.rgba(15, 15, 20, 0.35),
            .glass_fade_width = 0.0,
            .blur_inset = 0.0,
        },
    });
    defer win1.deinit();

    const win2 = try zrame.Window.init(gpa, .{
        .title = "zrame — Window B (Glass Fade)",
        .app_id = "dev.zrame.hello.b",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .style = .{
            .glass = zrame.Color.rgba(15, 15, 20, 0.35),
            .glass_fade_width = 30.0,
            .blur_inset = 0.0,
        },
    });
    defer win2.deinit();

    const win3 = try zrame.Window.init(gpa, .{
        .title = "zrame — Window C (Fade + Inset Blur)",
        .app_id = "dev.zrame.hello.c",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .style = .{
            .glass = zrame.Color.rgba(15, 15, 20, 0.35),
            .glass_fade_width = 30.0,
            .blur_inset = 25.0,
        },
    });
    defer win3.deinit();

    const t1 = try std.Thread.spawn(.{}, runWindow, .{win1});
    defer t1.join();

    const t2 = try std.Thread.spawn(.{}, runWindow, .{win2});
    defer t2.join();

    try win3.run();
}
