//! # zrame.appmenu — the `org_kde_kwin_appmenu` Wayland binding
//!
//! On Wayland there is no window id, so the DBus `com.canonical.AppMenu.Registrar` (X11)
//! can't be used to publish a global menu. KDE's answer is this tiny Wayland protocol: the
//! client tells KWin the DBus *service name* + *object path* where its `com.canonical.dbusmenu`
//! lives, and KWin hands that to the Global Menu applet / decoration menu button.
//!
//! We hand-wrap the two requests with the same `wl_proxy_marshal_flags` idiom as zicro's
//! Wayland glue; the interface tables come from `appmenu.xml` via wayland-scanner (build.zig).

const zicro = @import("zicro");
const wl = zicro.wl;

// Interface tables generated from appmenu.xml and linked into the binary.
pub extern const org_kde_kwin_appmenu_manager_interface: wl.Interface;
pub extern const org_kde_kwin_appmenu_interface: wl.Interface;

/// The registry global to look for, and its interface table for `Registry.bind`.
pub const manager_global = "org_kde_kwin_appmenu_manager";
pub const manager_interface = &org_kde_kwin_appmenu_manager_interface;

pub const Manager = opaque {
    /// `create(new_id org_kde_kwin_appmenu, object wl_surface)` — request opcode 0.
    pub fn create(self: *Manager, surface: *wl.Surface) *Appmenu {
        const p = wl.wl_proxy_marshal_flags(
            @ptrCast(self),
            0,
            &org_kde_kwin_appmenu_interface,
            wl.wl_proxy_get_version(@ptrCast(self)),
            0,
            @as(?*wl.Proxy, null),
            @as(*wl.Proxy, @ptrCast(surface)),
        );
        return @ptrCast(p.?);
    }
};

pub const Appmenu = opaque {
    /// `set_address(string service_name, string object_path)` — request opcode 0. The DBus
    /// object must already be exported before this is sent.
    pub fn setAddress(self: *Appmenu, service_name: [*:0]const u8, object_path: [*:0]const u8) void {
        _ = wl.wl_proxy_marshal_flags(
            @ptrCast(self),
            0,
            null,
            wl.wl_proxy_get_version(@ptrCast(self)),
            0,
            service_name,
            object_path,
        );
    }

    /// `release()` — destructor, request opcode 1.
    pub fn release(self: *Appmenu) void {
        _ = wl.wl_proxy_marshal_flags(
            @ptrCast(self),
            1,
            null,
            wl.wl_proxy_get_version(@ptrCast(self)),
            wl.MARSHAL_FLAG_DESTROY,
        );
    }
};
