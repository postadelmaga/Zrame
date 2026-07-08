//! `zig build run-widgets`
//!
//! The widget-toolkit showcase: one glass window whose content is rebuilt every frame
//! with `zrame.widget` — tabs, buttons, toggles, slider, stepper, text field, dropdown,
//! a scrollable list, and a modal dialog. This is also the reference wiring for apps:
//! window callbacks push into an [`widget.InputQueue`]; `on_draw` runs `Ui.begin` →
//! widgets → `Ui.end`, and requests a repaint while anything animates.

const std = @import("std");
const zrame = @import("zrame");
const widget = zrame.widget;

const Demo = struct {
    gpa: std.mem.Allocator,
    window: ?*zrame.Window = null,
    queue: widget.InputQueue = .{},
    store: widget.Store,
    // The macos() glass is light — pair the light theme (dark() suits darker styles).
    theme: widget.Theme = widget.Theme.light(),

    // app state driven by the widgets
    tab: usize = 0,
    power: bool = true,
    phantom: bool = false,
    gain: f32 = 42,
    channels: i64 = 32,
    name: std.ArrayList(u8) = .empty,
    mic: usize = 0,
    selected_row: usize = 0,
    clicks: u32 = 0,
};

const mics = [_][]const u8{ "SM58", "SM57", "MD421", "e906", "Beta 52A", "C414" };
const tabs = [_][]const u8{ "Controls", "List", "About" };

fn onDraw(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(user.?));
    const win = demo.window orelse return;
    const font = win.textFont() catch return;

    var ui = widget.Ui.begin(
        &demo.store,
        canvas,
        font,
        demo.theme.scaled(win.scaleFactor()),
        .{
            .x = @floatFromInt(content.x),
            .y = @floatFromInt(content.y),
            .w = @floatFromInt(content.w),
            .h = @floatFromInt(content.h),
        },
        widget.nowMs(),
        demo.queue.take(),
    );

    ui.heading("zrame widgets");
    _ = ui.tabBar("tabs", &tabs, &demo.tab);
    ui.gap(6);

    switch (demo.tab) {
        0 => {
            ui.beginRow();
            if (ui.buttonPrimary("Primary")) demo.clicks += 1;
            if (ui.button("Default")) demo.clicks += 1;
            if (ui.button("Open dialog")) ui.openDialog("demo-dialog");
            ui.endRow();

            _ = ui.toggle("Power", &demo.power);
            _ = ui.checkbox("Phantom +48V", &demo.phantom);
            _ = ui.slider("Gain", &demo.gain, 0, 100);
            _ = ui.stepper("Input channels", &demo.channels, 8, 128);
            _ = ui.textField("name", &demo.name);
            _ = ui.dropdown("mic", &mics, &demo.mic);
        },
        1 => {
            ui.labelDim("A scrollable list (mouse wheel):");
            ui.beginScroll("rows", 220);
            var i: usize = 0;
            var buf: [32]u8 = undefined;
            while (i < 40) : (i += 1) {
                ui.pushIdScopeIndex(i);
                const s = std.fmt.bufPrint(&buf, "Channel {d:0>2}", .{i + 1}) catch "?";
                if (ui.selectable(s, demo.selected_row == i)) demo.selected_row = i;
                ui.popIdScope();
            }
            ui.endScroll();
        },
        else => {
            ui.beginCard(120);
            ui.label("Immediate-mode toolkit over zicro.paint.");
            ui.labelDim("Every frame the UI is rebuilt from state;");
            ui.labelDim("the Store keeps hot/active/focus and offsets.");
            ui.endCard();
        },
    }

    // status footer
    var sbuf: [160]u8 = undefined;
    const status = std.fmt.bufPrint(&sbuf, "clicks {d}   gain {d:.0}   ch {d}   mic {s}   row {d}   name \"{s}\"", .{
        demo.clicks,          demo.gain, demo.channels,
        mics[demo.mic],       demo.selected_row + 1,
        demo.name.items,
    }) catch "";
    ui.gap(8);
    ui.labelDim(status);

    // modal on top of everything
    if (ui.beginDialog("demo-dialog", "A modal dialog", 340, 190)) {
        ui.label("Everything underneath is inert.");
        ui.labelDim("Esc, the x, or a click outside closes it.");
        ui.gap(8);
        if (ui.buttonPrimary("Done")) ui.closeDialog();
        ui.endDialog();
    }

    const report = ui.end();
    if (report.needs_repaint) win.host().do(.request_redraw);
}

fn onMouse(win: *zrame.Window, event: zrame.MouseEvent, user: ?*anyopaque) bool {
    const demo: *Demo = @ptrCast(@alignCast(user.?));
    switch (event) {
        .motion => |m| demo.queue.push(.{ .motion = .{ .x = m.x, .y = m.y } }),
        .button => |b| demo.queue.push(.{ .button = .{ .button = b.button, .pressed = b.state == 1 } }),
        .leave => demo.queue.push(.{ .motion = .{ .x = -1e9, .y = -1e9 } }),
    }
    win.host().do(.request_redraw);
    return false;
}

fn onKey(win: *zrame.Window, key: u32, state: u32, user: ?*anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(user.?));
    demo.queue.push(.{ .key = .{ .code = key, .pressed = state == 1 } });
    win.host().do(.request_redraw);
}

fn onScroll(win: *zrame.Window, axis: u32, value: i32, user: ?*anyopaque) void {
    const demo: *Demo = @ptrCast(@alignCast(user.?));
    demo.queue.push(.{ .scroll = .{ .axis = axis, .px = @as(f32, @floatFromInt(value)) / 256.0 } });
    win.host().do(.request_redraw);
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var demo = Demo{ .gpa = gpa, .store = widget.Store.init(gpa) };
    defer demo.store.deinit();
    defer demo.name.deinit(gpa);

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — widgets",
        .app_id = "dev.zrame.widgets",
        .width = 560,
        .height = 480,
        .style = zrame.Style.macos(),
        .titlebar = true,
        .on_draw = onDraw,
        .on_mouse = onMouse,
        .on_key = onKey,
        .on_scroll = onScroll,
        .user = &demo,
    });
    defer win.deinit();
    demo.window = win;

    try win.run();
}
