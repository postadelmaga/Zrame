//! # zrame.tray — a system-tray icon over DBus (StatusNotifierItem)
//!
//! The freedesktop/KDE tray protocol: an app exposes an `org.kde.StatusNotifierItem`
//! object on the session bus and registers it with the `org.kde.StatusNotifierWatcher`.
//! The panel (KDE, waybar, etc.) then draws the icon and calls back on interaction.
//!
//! This is the window layer's answer to Phase 6. It talks to the bus through **sd-bus**
//! (libsystemd) — the same hand-written C-FFI style as `wl.zig` — and hangs its socket fd
//! off the window's `poll` loop (see `Window.run`), so it costs nothing when idle.
//!
//! First slice: the icon (themed `IconName`), title, tooltip and `Active` status, plus
//! left-click `Activate` wired to a caller callback. The `com.canonical.dbusmenu` context
//! menu is a follow-up (see the Phase 6 issue) — `ItemIsMenu` is reported false and no
//! `Menu` object is advertised, so a host uses `Activate`/`ContextMenu` instead.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

// ── sd-bus FFI ──────────────────────────────────────────────────────────────
// Opaque handles; we only ever hold pointers to them.
const Bus = opaque {};
const Slot = opaque {};
const Message = opaque {};

/// Mirrors `struct sd_bus_error` (name, message, _need_free).
const BusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    need_free: c_int = 0,
};

extern fn sd_bus_open_user(ret: *?*Bus) c_int;
extern fn sd_bus_unref(bus: ?*Bus) ?*Bus;
extern fn sd_bus_slot_unref(slot: ?*Slot) ?*Slot;
extern fn sd_bus_request_name(bus: ?*Bus, name: [*:0]const u8, flags: u64) c_int;
extern fn sd_bus_add_object_vtable(bus: ?*Bus, slot: *?*Slot, path: [*:0]const u8, interface: [*:0]const u8, vtable: [*]const Vtable, userdata: ?*anyopaque) c_int;
extern fn sd_bus_call_method(bus: ?*Bus, destination: [*:0]const u8, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8, ret_error: *BusError, reply: ?*?*Message, types: ?[*:0]const u8, ...) c_int;
extern fn sd_bus_get_fd(bus: ?*Bus) c_int;
extern fn sd_bus_process(bus: ?*Bus, ret: ?*?*Message) c_int;
extern fn sd_bus_flush(bus: ?*Bus) c_int;
extern fn sd_bus_message_append(m: ?*Message, types: [*:0]const u8, ...) c_int;
extern fn sd_bus_reply_method_return(call: ?*Message, types: [*:0]const u8, ...) c_int;
extern fn sd_bus_error_free(e: *BusError) void;
/// ABI version tag the START vtable entry must point at.
extern const sd_bus_object_vtable_format: c_uint;

/// Byte-for-byte layout of `struct sd_bus_vtable` (systemd): a `type:8|flags:56` header
/// packed into one u64, then an 8-pointer-wide union. The largest arm (`method`) is six
/// machine words, so the whole record is 8 + 48 = 56 bytes. Unused arms stay zero.
const Vtable = extern struct {
    type_and_flags: u64 = 0,
    f0: usize = 0,
    f1: usize = 0,
    f2: usize = 0,
    f3: usize = 0,
    f4: usize = 0,
    f5: usize = 0,
};

const VTABLE_START = '<';
const VTABLE_END = '>';
const VTABLE_METHOD = 'M';
const VTABLE_PROPERTY = 'P';

fn header(kind: u8, flags: u64) u64 {
    return @as(u64, kind) | (flags << 8);
}

const PropGet = *const fn (bus: ?*Bus, path: [*:0]const u8, interface: [*:0]const u8, property: [*:0]const u8, reply: ?*Message, userdata: ?*anyopaque, ret_error: ?*BusError) callconv(.c) c_int;
const MethodHandler = *const fn (m: ?*Message, userdata: ?*anyopaque, ret_error: ?*BusError) callconv(.c) c_int;

fn startEntry() Vtable {
    return .{
        .type_and_flags = header(VTABLE_START, 0),
        .f0 = @sizeOf(Vtable), // element_size
        .f1 = 0, // features: no param-names, so method `names` fields are ignored
        .f2 = @intFromPtr(&sd_bus_object_vtable_format),
    };
}

fn endEntry() Vtable {
    return .{ .type_and_flags = header(VTABLE_END, 0) };
}

fn propEntry(member: [*:0]const u8, signature: [*:0]const u8, get: PropGet) Vtable {
    return .{
        .type_and_flags = header(VTABLE_PROPERTY, 0),
        .f0 = @intFromPtr(member),
        .f1 = @intFromPtr(signature),
        .f2 = @intFromPtr(get),
    };
}

fn methodEntry(member: [*:0]const u8, signature: [*:0]const u8, result: [*:0]const u8, handler: MethodHandler) Vtable {
    return .{
        .type_and_flags = header(VTABLE_METHOD, 0),
        .f0 = @intFromPtr(member),
        .f1 = @intFromPtr(signature),
        .f2 = @intFromPtr(result),
        .f3 = @intFromPtr(handler),
    };
}

// ── the tray item ────────────────────────────────────────────────────────────

pub const Config = struct {
    /// Stable application id (SNI `Id`).
    id: [:0]const u8 = "dev.zrame.window",
    /// Human title (SNI `Title`), shown in tooltips/menus.
    title: [:0]const u8 = "zrame",
    /// Themed icon name (SNI `IconName`), e.g. "application-x-executable".
    icon_name: [:0]const u8 = "application-x-executable",
    /// Optional tooltip text (empty = none).
    tooltip: [:0]const u8 = "",
    /// Invoked on left-click (SNI `Activate`), on the window thread.
    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const Tray = struct {
    gpa: Allocator,
    bus: ?*Bus = null,
    slot: ?*Slot = null,
    vtable: [12]Vtable = undefined,

    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    id_buf: [128:0]u8 = undefined,
    title_buf: [256:0]u8 = undefined,
    icon_buf: [128:0]u8 = undefined,
    tip_buf: [256:0]u8 = undefined,
    name_buf: [64:0]u8 = undefined,

    const category = "ApplicationStatus";
    const status = "Active";
    const item_path = "/StatusNotifierItem";
    const item_iface = "org.kde.StatusNotifierItem";

    pub fn init(gpa: Allocator, cfg: Config) !*Tray {
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .on_activate = cfg.on_activate, .ctx = cfg.ctx };

        copyz(&self.id_buf, cfg.id);
        copyz(&self.title_buf, cfg.title);
        copyz(&self.icon_buf, cfg.icon_name);
        copyz(&self.tip_buf, cfg.tooltip);
        // Well-known name per the SNI convention: org.kde.StatusNotifierItem-PID-ID.
        _ = std.fmt.bufPrintZ(&self.name_buf, "org.kde.StatusNotifierItem-{d}-1", .{linux.getpid()}) catch return error.TrayName;

        if (sd_bus_open_user(&self.bus) < 0) return error.TrayBusOpen;
        errdefer _ = sd_bus_unref(self.bus);

        self.buildVtable();
        if (sd_bus_add_object_vtable(self.bus, &self.slot, item_path, item_iface, &self.vtable, self) < 0)
            return error.TrayVtable;
        errdefer _ = sd_bus_slot_unref(self.slot);

        // DBUS_NAME_FLAG_DO_NOT_QUEUE would be nicer but 0 (queue) is fine — our name is
        // pid-unique so it never collides.
        if (sd_bus_request_name(self.bus, &self.name_buf, 0) < 0) return error.TrayName;

        var err: BusError = .{};
        defer sd_bus_error_free(&err);
        const r = sd_bus_call_method(
            self.bus,
            "org.kde.StatusNotifierWatcher",
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem",
            &err,
            null,
            "s",
            @as([*:0]const u8, &self.name_buf),
        );
        if (r < 0) return error.TrayRegister;

        return self;
    }

    pub fn deinit(self: *Tray) void {
        _ = sd_bus_slot_unref(self.slot);
        _ = sd_bus_unref(self.bus);
        self.gpa.destroy(self);
    }

    /// The bus socket; hang it off the window's `poll` set.
    pub fn fd(self: *Tray) i32 {
        return sd_bus_get_fd(self.bus);
    }

    /// Push any queued outgoing traffic; call before blocking in `poll`.
    pub fn flush(self: *Tray) void {
        _ = sd_bus_flush(self.bus);
    }

    /// Dispatch everything the socket has for us (property reads, `Activate`, …).
    pub fn process(self: *Tray) void {
        while (sd_bus_process(self.bus, null) > 0) {}
    }

    /// The full vtable: START, the six SNI properties, the four SNI methods, END.
    fn buildVtable(self: *Tray) void {
        self.vtable = std.mem.zeroes([12]Vtable);
        self.vtable[0] = startEntry();
        self.vtable[1] = propEntry("Category", "s", getProp);
        self.vtable[2] = propEntry("Id", "s", getProp);
        self.vtable[3] = propEntry("Title", "s", getProp);
        self.vtable[4] = propEntry("Status", "s", getProp);
        self.vtable[5] = propEntry("IconName", "s", getProp);
        self.vtable[6] = propEntry("ItemIsMenu", "b", getProp);
        self.vtable[7] = methodEntry("Activate", "ii", "", onActivate);
        self.vtable[8] = methodEntry("SecondaryActivate", "ii", "", onNoop);
        self.vtable[9] = methodEntry("ContextMenu", "ii", "", onNoop);
        self.vtable[10] = methodEntry("Scroll", "is", "", onNoop);
        self.vtable[11] = endEntry();
    }

    fn getProp(_: ?*Bus, _: [*:0]const u8, _: [*:0]const u8, property: [*:0]const u8, reply: ?*Message, userdata: ?*anyopaque, _: ?*BusError) callconv(.c) c_int {
        const self: *Tray = @ptrCast(@alignCast(userdata.?));
        const p = std.mem.span(property);
        if (std.mem.eql(u8, p, "Category")) return sd_bus_message_append(reply, "s", @as([*:0]const u8, category));
        if (std.mem.eql(u8, p, "Id")) return sd_bus_message_append(reply, "s", @as([*:0]const u8, &self.id_buf));
        if (std.mem.eql(u8, p, "Title")) return sd_bus_message_append(reply, "s", @as([*:0]const u8, &self.title_buf));
        if (std.mem.eql(u8, p, "Status")) return sd_bus_message_append(reply, "s", @as([*:0]const u8, status));
        if (std.mem.eql(u8, p, "IconName")) return sd_bus_message_append(reply, "s", @as([*:0]const u8, &self.icon_buf));
        if (std.mem.eql(u8, p, "ItemIsMenu")) return sd_bus_message_append(reply, "b", @as(c_int, 0));
        return sd_bus_message_append(reply, "s", @as([*:0]const u8, ""));
    }

    fn onActivate(m: ?*Message, userdata: ?*anyopaque, _: ?*BusError) callconv(.c) c_int {
        const self: *Tray = @ptrCast(@alignCast(userdata.?));
        if (self.on_activate) |cb| cb(self.ctx);
        return sd_bus_reply_method_return(m, "");
    }

    fn onNoop(m: ?*Message, _: ?*anyopaque, _: ?*BusError) callconv(.c) c_int {
        return sd_bus_reply_method_return(m, "");
    }
};

/// Copy `src` into a fixed sentinel-terminated buffer, truncating if it would overflow.
fn copyz(dst: anytype, src: []const u8) void {
    const cap = dst.len; // sentinel array: .len excludes the terminator slot
    const n = @min(src.len, cap);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

test "vtable record is 56 bytes (matches C sd_bus_vtable)" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Vtable));
}

test "header packs type in low byte, flags above" {
    try std.testing.expectEqual(@as(u64, '<'), header('<', 0));
    try std.testing.expectEqual(@as(u64, @as(u64, 'M') | (@as(u64, 3) << 8)), header('M', 3));
}
