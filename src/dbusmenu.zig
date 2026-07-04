//! # zrame.dbusmenu — a `com.canonical.dbusmenu` menu, over DBus
//!
//! This is the model behind KDE's **Global Menu** (and any `dbusmenu` consumer): the app
//! exports its menu bar as a DBus object; the host (the Plasma Global Menu applet, the
//! window-decoration menu button, …) walks it with `GetLayout` and calls back through
//! `Event` when the user picks something. `window.zig` publishes the object's address to
//! KWin over the `org_kde_kwin_appmenu` Wayland protocol (see `appmenu.zig`).
//!
//! The app describes a static tree of [`Item`]s; we flatten it into integer-id nodes (id 0
//! is the synthetic root container) and serve the `dbusmenu` interface off sd-bus. The one
//! fiddly part is `GetLayout`, whose reply is the recursive `(ia{sv}av)` — an id, a
//! property dict, and an array of variant children, each a nested `(ia{sv}av)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus = @import("sdbus.zig");

/// One entry in the menu tree. A plain container (submenu) has `children`; a leaf has an
/// `on_click`; a rule is `separator = true`. The tree is borrowed for the server's
/// lifetime — keep it alive (a `const` array literal is fine).
pub const Item = struct {
    label: [:0]const u8 = "",
    enabled: bool = true,
    visible: bool = true,
    separator: bool = false,
    children: []const Item = &.{},
    /// Invoked when the host reports this item "clicked" (on the window thread).
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
};

pub const Config = struct {
    /// Top-level menus (File, Edit, …). Their children are the drop-down entries.
    items: []const Item,
    /// Object path to export the menu at; must match what we hand KWin.
    object_path: [:0]const u8 = "/MenuBar",
    /// Opaque context handed to every `on_click`.
    ctx: ?*anyopaque = null,
};

const Node = struct {
    item: ?*const Item, // null for the synthetic root (id 0)
    children: []i32,
};

pub const Server = struct {
    gpa: Allocator,
    bus: ?*bus.Bus = null,
    slot: ?*bus.Slot = null,
    vtable: [10]bus.Vtable = undefined,
    nodes: []Node = &.{},
    ctx: ?*anyopaque = null,
    revision: u32 = 1,
    path_buf: [128:0]u8 = undefined,

    const iface = "com.canonical.dbusmenu";

    pub fn init(gpa: Allocator, cfg: Config) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ctx = cfg.ctx };
        copyz(&self.path_buf, cfg.object_path);

        try self.buildTree(cfg.items);
        errdefer self.freeTree();

        if (bus.sd_bus_open_user(&self.bus) < 0) return error.MenuBusOpen;
        errdefer _ = bus.sd_bus_unref(self.bus);

        self.buildVtable();
        if (bus.sd_bus_add_object_vtable(self.bus, &self.slot, &self.path_buf, iface, &self.vtable, self) < 0)
            return error.MenuVtable;

        return self;
    }

    pub fn deinit(self: *Server) void {
        _ = bus.sd_bus_slot_unref(self.slot);
        _ = bus.sd_bus_unref(self.bus);
        self.freeTree();
        self.gpa.destroy(self);
    }

    pub fn fd(self: *Server) i32 {
        return bus.sd_bus_get_fd(self.bus);
    }
    pub fn flush(self: *Server) void {
        _ = bus.sd_bus_flush(self.bus);
    }
    pub fn process(self: *Server) void {
        while (bus.sd_bus_process(self.bus, null) > 0) {}
    }

    /// The connection's unique name (":1.NN") — the "service name" KWin needs to find us.
    pub fn uniqueName(self: *Server) ?[*:0]const u8 {
        var name: ?[*:0]const u8 = null;
        if (bus.sd_bus_get_unique_name(self.bus, &name) < 0) return null;
        return name;
    }

    // ── tree flattening ───────────────────────────────────────────────────────

    fn buildTree(self: *Server, items: []const Item) !void {
        var list: std.ArrayList(Node) = .empty;
        errdefer list.deinit(self.gpa);
        _ = try self.addNode(&list, null, items);
        self.nodes = try list.toOwnedSlice(self.gpa);
    }

    /// Append a node for `item` (its drop-down being `kids`), recurse, return its id.
    fn addNode(self: *Server, list: *std.ArrayList(Node), item: ?*const Item, kids: []const Item) !i32 {
        const id: i32 = @intCast(list.items.len);
        try list.append(self.gpa, .{ .item = item, .children = &.{} });
        const ids = try self.gpa.alloc(i32, kids.len);
        for (kids, 0..) |*k, i| ids[i] = try self.addNode(list, k, k.children);
        // `list` may have reallocated while recursing, but `id` still indexes this node.
        list.items[@intCast(id)].children = ids;
        return id;
    }

    fn freeTree(self: *Server) void {
        for (self.nodes) |n| if (n.children.len > 0) self.gpa.free(n.children);
        if (self.nodes.len > 0) self.gpa.free(self.nodes);
        self.nodes = &.{};
    }

    // ── vtable ────────────────────────────────────────────────────────────────

    fn buildVtable(self: *Server) void {
        self.vtable = std.mem.zeroes([10]bus.Vtable);
        self.vtable[0] = bus.startEntry();
        self.vtable[1] = bus.propEntry("Version", "u", getProp);
        self.vtable[2] = bus.propEntry("Status", "s", getProp);
        self.vtable[3] = bus.propEntry("TextDirection", "s", getProp);
        self.vtable[4] = bus.methodEntry("GetLayout", "iias", "u(ia{sv}av)", onGetLayout);
        self.vtable[5] = bus.methodEntry("GetGroupProperties", "aias", "a(ia{sv})", onGetGroupProperties);
        self.vtable[6] = bus.methodEntry("GetProperty", "is", "v", onGetProperty);
        self.vtable[7] = bus.methodEntry("Event", "isvu", "", onEvent);
        self.vtable[8] = bus.methodEntry("AboutToShow", "i", "b", onAboutToShow);
        self.vtable[9] = bus.endEntry();
    }

    fn getProp(_: ?*bus.Bus, _: [*:0]const u8, _: [*:0]const u8, property: [*:0]const u8, reply: ?*bus.Message, _: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const p = std.mem.span(property);
        if (std.mem.eql(u8, p, "Version")) return bus.sd_bus_message_append(reply, "u", @as(c_uint, 4));
        if (std.mem.eql(u8, p, "TextDirection")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, "ltr"));
        return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, "normal")); // Status
    }

    // ── layout serialization ──────────────────────────────────────────────────

    fn valid(self: *Server, id: i32) bool {
        return id >= 0 and id < self.nodes.len;
    }

    /// Emit one item's `a{sv}` property dict.
    fn appendProps(self: *Server, reply: ?*bus.Message, id: i32) void {
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_ARRAY, "{sv}");
        const node = self.nodes[@intCast(id)];
        if (node.item) |it| {
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "label"), @as([*:0]const u8, "s"), @as([*:0]const u8, it.label));
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "enabled"), @as([*:0]const u8, "b"), @as(c_int, @intFromBool(it.enabled)));
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "visible"), @as([*:0]const u8, "b"), @as(c_int, @intFromBool(it.visible)));
            if (it.separator)
                _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "type"), @as([*:0]const u8, "s"), @as([*:0]const u8, "separator"));
        }
        if (node.children.len > 0)
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "children-display"), @as([*:0]const u8, "s"), @as([*:0]const u8, "submenu"));
        _ = bus.sd_bus_message_close_container(reply);
    }

    /// Emit the recursive `(ia{sv}av)` layout for `id`, descending `depth` levels
    /// (-1 = unlimited).
    fn appendLayout(self: *Server, reply: ?*bus.Message, id: i32, depth: i32) void {
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_STRUCT, "ia{sv}av");
        _ = bus.sd_bus_message_append(reply, "i", @as(c_int, id));
        self.appendProps(reply, id);
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_ARRAY, "v");
        if (depth != 0) {
            for (self.nodes[@intCast(id)].children) |child| {
                _ = bus.sd_bus_message_open_container(reply, bus.TYPE_VARIANT, "(ia{sv}av)");
                self.appendLayout(reply, child, depth - 1);
                _ = bus.sd_bus_message_close_container(reply);
            }
        }
        _ = bus.sd_bus_message_close_container(reply);
        _ = bus.sd_bus_message_close_container(reply);
    }

    // ── method handlers ───────────────────────────────────────────────────────

    fn onGetLayout(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(userdata.?));
        var parent: i32 = 0;
        var depth: i32 = -1;
        _ = bus.sd_bus_message_read(m, "ii", &parent, &depth);
        if (!self.valid(parent)) parent = 0;

        var reply: ?*bus.Message = null;
        if (bus.sd_bus_message_new_method_return(m, &reply) < 0) return -1;
        defer _ = bus.sd_bus_message_unref(reply);
        _ = bus.sd_bus_message_append(reply, "u", @as(c_uint, self.revision));
        self.appendLayout(reply, parent, depth);
        return bus.sd_bus_send(self.bus, reply, null);
    }

    fn onGetGroupProperties(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(userdata.?));
        var ids: [512]i32 = undefined;
        var n: usize = 0;
        _ = bus.sd_bus_message_enter_container(m, bus.TYPE_ARRAY, "i");
        while (n < ids.len) {
            var id: i32 = 0;
            if (bus.sd_bus_message_read_basic(m, 'i', &id) <= 0) break;
            ids[n] = id;
            n += 1;
        }
        _ = bus.sd_bus_message_exit_container(m);

        var reply: ?*bus.Message = null;
        if (bus.sd_bus_message_new_method_return(m, &reply) < 0) return -1;
        defer _ = bus.sd_bus_message_unref(reply);
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_ARRAY, "(ia{sv})");
        // An empty request means "every item" per the spec.
        if (n == 0) {
            var id: i32 = 0;
            while (id < self.nodes.len) : (id += 1) self.appendGroupEntry(reply, id);
        } else {
            for (ids[0..n]) |id| if (self.valid(id)) self.appendGroupEntry(reply, id);
        }
        _ = bus.sd_bus_message_close_container(reply);
        return bus.sd_bus_send(self.bus, reply, null);
    }

    fn appendGroupEntry(self: *Server, reply: ?*bus.Message, id: i32) void {
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_STRUCT, "ia{sv}");
        _ = bus.sd_bus_message_append(reply, "i", @as(c_int, id));
        self.appendProps(reply, id);
        _ = bus.sd_bus_message_close_container(reply);
    }

    fn onGetProperty(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(userdata.?));
        var id: i32 = 0;
        var name: ?[*:0]const u8 = null;
        _ = bus.sd_bus_message_read(m, "is", &id, &name);
        const key = if (name) |nm| std.mem.span(nm) else "";

        var reply: ?*bus.Message = null;
        if (bus.sd_bus_message_new_method_return(m, &reply) < 0) return -1;
        defer _ = bus.sd_bus_message_unref(reply);
        const it: ?*const Item = if (self.valid(id)) self.nodes[@intCast(id)].item else null;
        if (it != null and std.mem.eql(u8, key, "label")) {
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "s"), @as([*:0]const u8, it.?.label));
        } else if (it != null and std.mem.eql(u8, key, "enabled")) {
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "b"), @as(c_int, @intFromBool(it.?.enabled)));
        } else {
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "s"), @as([*:0]const u8, ""));
        }
        return bus.sd_bus_send(self.bus, reply, null);
    }

    fn onEvent(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Server = @ptrCast(@alignCast(userdata.?));
        var id: i32 = 0;
        var event: ?[*:0]const u8 = null;
        _ = bus.sd_bus_message_read(m, "is", &id, &event);
        const name = if (event) |e| std.mem.span(e) else "";
        if (std.mem.eql(u8, name, "clicked") and self.valid(id)) {
            if (self.nodes[@intCast(id)].item) |it| {
                if (it.on_click) |cb| cb(self.ctx);
            }
        }
        return bus.sd_bus_reply_method_return(m, "");
    }

    fn onAboutToShow(m: ?*bus.Message, _: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        // Static menu: nothing to rebuild, so no update is needed.
        return bus.sd_bus_reply_method_return(m, "b", @as(c_int, 0));
    }
};

/// Copy `src` into a fixed sentinel-terminated buffer, truncating if it would overflow.
fn copyz(dst: anytype, src: []const u8) void {
    const cap = dst.len;
    const n = @min(src.len, cap);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

test "tree flattens with contiguous DFS ids" {
    const items = [_]Item{
        .{ .label = "File", .children = &.{ .{ .label = "Open" }, .{ .label = "Quit" } } },
        .{ .label = "Help", .children = &.{.{ .label = "About" }} },
    };
    const s = try Server.init(std.testing.allocator, .{ .items = &items });
    defer s.deinit();
    // root + File + Open + Quit + Help + About = 6 nodes
    try std.testing.expectEqual(@as(usize, 6), s.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), s.nodes[0].children.len); // root: File, Help
    try std.testing.expect(s.nodes[1].item != null);
    try std.testing.expectEqualStrings("File", std.mem.span(s.nodes[1].item.?.label.ptr));
}
