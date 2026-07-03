const std = @import("std");
const zrame = @import("zrame");

const WindowMode = enum {
    a,
    b,
    c,
};

const mode_a: WindowMode = .a;
const mode_b: WindowMode = .b;
const mode_c: WindowMode = .c;

fn drawContent(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    const mode: WindowMode = @as(*const WindowMode, @ptrCast(@alignCast(user.?))).*;
    const cx: f32 = @floatFromInt(content.x);
    const cy: f32 = @floatFromInt(content.y);

    const lx = cx + 32;
    const ly = cy + 32;
    const color = zrame.Color.rgba(255, 255, 255, 0.65);

    switch (mode) {
        .a => {
            // Stylized letter "A"
            canvas.fillRoundedRect(lx, ly, 10, 60, 4, color); // left leg
            canvas.fillRoundedRect(lx + 25, ly, 10, 60, 4, color); // right leg
            canvas.fillRoundedRect(lx, ly, 35, 10, 4, color); // top bar
            canvas.fillRoundedRect(lx, ly + 25, 35, 10, 4, color); // middle bar

            // Info tile: Mode A - Baseline (Uniform Glass + Full Blur)
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 160, 22, 11, zrame.Color.rgba(255, 255, 255, 0.15));
        },
        .b => {
            // Stylized letter "B"
            canvas.fillRoundedRect(lx, ly, 10, 60, 4, color); // left bar
            canvas.fillRoundedRect(lx, ly, 30, 10, 4, color); // top bar
            canvas.fillRoundedRect(lx, ly + 25, 30, 10, 4, color); // middle bar
            canvas.fillRoundedRect(lx, ly + 50, 30, 10, 4, color); // bottom bar
            canvas.fillRoundedRect(lx + 20, ly, 10, 35, 4, color); // top loop right
            canvas.fillRoundedRect(lx + 20, ly + 25, 10, 35, 4, color); // bottom loop right

            // Info tiles: Mode B - Glass Fade (Fading Glass + Full Blur)
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 240, 22, 11, zrame.Color.rgba(137, 180, 250, 0.45));
        },
        .c => {
            // Stylized letter "C"
            canvas.fillRoundedRect(lx, ly, 10, 60, 4, color); // left bar
            canvas.fillRoundedRect(lx, ly, 35, 10, 4, color); // top bar
            canvas.fillRoundedRect(lx, ly + 50, 35, 10, 4, color); // bottom bar

            // Info tiles: Mode C - Glass Fade + Inset Blur (Fading Glass + 25px Inset Blur)
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 320, 22, 11, zrame.Color.rgba(243, 139, 168, 0.45));
        },
    }
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
        .user = @ptrCast(@constCast(&mode_a)),
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
        .user = @ptrCast(@constCast(&mode_b)),
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
        .user = @ptrCast(@constCast(&mode_c)),
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
