//! `zig build run-menu`
//!
//! A glass window that publishes a **KDE global menu** (`com.canonical.dbusmenu`) over the
//! `org_kde_kwin_appmenu` Wayland protocol. On Plasma with the *Global Menu* applet (or the
//! window-decoration "app menu" button) enabled, the File / Edit / Help bar shows up there;
//! picking an entry prints a line, and File → Quit closes the window.

const std = @import("std");
const zrame = @import("zrame");

const Ctx = struct { win: ?*zrame.Window = null };
var ctx: Ctx = .{};

fn onNew(_: ?*anyopaque) void {
    std.debug.print("menu: File -> New\n", .{});
}
fn onOpen(_: ?*anyopaque) void {
    std.debug.print("menu: File -> Open\n", .{});
}
fn onQuit(c: ?*anyopaque) void {
    std.debug.print("menu: File -> Quit\n", .{});
    const cx: *Ctx = @ptrCast(@alignCast(c.?));
    if (cx.win) |w| w.close();
}
fn onCut(_: ?*anyopaque) void {
    std.debug.print("menu: Edit -> Cut\n", .{});
}
fn onCopy(_: ?*anyopaque) void {
    std.debug.print("menu: Edit -> Copy\n", .{});
}
fn onAbout(_: ?*anyopaque) void {
    std.debug.print("menu: Help -> About\n", .{});
}

const menu = [_]zrame.dbusmenu.Item{
    .{ .label = "File", .children = &.{
        .{ .label = "New", .on_click = onNew },
        .{ .label = "Open", .on_click = onOpen },
        .{ .separator = true },
        .{ .label = "Quit", .on_click = onQuit },
    } },
    .{ .label = "Edit", .children = &.{
        .{ .label = "Cut", .on_click = onCut },
        .{ .label = "Copy", .on_click = onCopy },
        .{ .label = "Paste", .enabled = false }, // greyed out, no handler
    } },
    .{ .label = "Help", .children = &.{
        .{ .label = "About zrame", .on_click = onAbout },
    } },
};

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const win = try zrame.Window.init(gpa, .{
        .title = "zrame — Global Menu",
        .app_id = "dev.zrame.menu",
        .width = 560,
        .height = 360,
        .titlebar = true,
        .titlebar_style = .macos,
        .style = zrame.Style.macos(),
        .menu = &menu,
        .user = @ptrCast(&ctx),
    });
    defer win.deinit();
    ctx.win = win;

    std.debug.print("global menu published; look in your panel's Global Menu (or the titlebar menu button).\n", .{});
    try win.run();
}
