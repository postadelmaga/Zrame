const std = @import("std");
const zrame = @import("zrame");

const WindowMode = enum {
    a,
    b,
    c,
    d,
};

const mode_a: WindowMode = .a;
const mode_b: WindowMode = .b;
const mode_c: WindowMode = .c;
const mode_d: WindowMode = .d;

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

            // Info tile: Window A - Fluent Design / Acrylic
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 220, 22, 11, zrame.Color.rgba(255, 255, 255, 0.15));
        },
        .b => {
            // Stylized letter "B"
            canvas.fillRoundedRect(lx, ly, 10, 60, 4, color); // left bar
            canvas.fillRoundedRect(lx, ly, 30, 10, 4, color); // top bar
            canvas.fillRoundedRect(lx, ly + 25, 30, 10, 4, color); // middle bar
            canvas.fillRoundedRect(lx, ly + 50, 30, 10, 4, color); // bottom bar
            canvas.fillRoundedRect(lx + 20, ly, 10, 35, 4, color); // top loop right
            canvas.fillRoundedRect(lx + 20, ly + 25, 10, 35, 4, color); // bottom loop right

            // Info tiles: Window B - Vision Pro Glassmorphism
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 300, 22, 11, zrame.Color.rgba(137, 180, 250, 0.45));
        },
        .c => {
            // Stylized letter "C"
            canvas.fillRoundedRect(lx, ly, 10, 60, 4, color); // left bar
            canvas.fillRoundedRect(lx, ly, 35, 10, 4, color); // top bar
            canvas.fillRoundedRect(lx, ly + 50, 35, 10, 4, color); // bottom bar

            // Info tiles: Window C - Aurora Glass (Inset + Fading Blur)
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 360, 22, 11, zrame.Color.rgba(243, 139, 168, 0.45));
        },
        .d => {
            // Stylized letter "D"
            canvas.fillRoundedRect(lx, ly, 10, 60, 4, color); // left bar
            canvas.fillRoundedRect(lx, ly, 25, 10, 4, color); // top bar
            canvas.fillRoundedRect(lx, ly + 50, 25, 10, 4, color); // bottom bar
            canvas.fillRoundedRect(lx + 18, ly + 5, 10, 50, 4, color); // right curve bar

            // Info tiles: Window D - Material Design 3 (Solid surface tint + 28px corners)
            canvas.fillRoundedRect(cx + 88, cy + 32, 280, 26, 13, zrame.Color.rgba(255, 255, 255, 0.20));
            canvas.fillRoundedRect(cx + 88, cy + 70, 260, 22, 11, zrame.Color.rgba(166, 227, 161, 0.45));
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
        .title = "zrame — Window A (Fluent Design)",
        .app_id = "dev.zrame.hello.a",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .user = @ptrCast(@constCast(&mode_a)),
        .style = zrame.Style.fluent(),
    });
    defer win1.deinit();

    const win2 = try zrame.Window.init(gpa, .{
        .title = "zrame — Window B (Vision Pro Glass)",
        .app_id = "dev.zrame.hello.b",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .user = @ptrCast(@constCast(&mode_b)),
        .style = zrame.Style.macos(),
    });
    defer win2.deinit();

    const win3 = try zrame.Window.init(gpa, .{
        .title = "zrame — Window C (Aurora Glass)",
        .app_id = "dev.zrame.hello.c",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .user = @ptrCast(@constCast(&mode_c)),
        .style = zrame.Style.aurora(),
    });
    defer win3.deinit();

    const win4 = try zrame.Window.init(gpa, .{
        .title = "zrame — Window D (Material Design)",
        .app_id = "dev.zrame.hello.d",
        .width = 640,
        .height = 400,
        .on_draw = drawContent,
        .user = @ptrCast(@constCast(&mode_d)),
        .style = zrame.Style.material(),
    });
    defer win4.deinit();

    const t1 = try std.Thread.spawn(.{}, runWindow, .{win1});
    defer t1.join();

    const t2 = try std.Thread.spawn(.{}, runWindow, .{win2});
    defer t2.join();

    const t3 = try std.Thread.spawn(.{}, runWindow, .{win3});
    defer t3.join();

    try win4.run();
}
