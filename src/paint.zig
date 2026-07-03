//! # zrame.paint — the software canvas
//!
//! Everything zrame puts on screen is drawn here, on the CPU, into a premultiplied
//! ARGB8888 buffer (the wl_shm wire format). The window chrome is analytic: a rounded
//! rectangle is a signed-distance function, the drop shadow is a smooth falloff of the
//! same SDF, anti-aliasing falls out of the distance for free. No textures, no GPU —
//! a decorated frame is just math over pixels.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A straight (non-premultiplied) color; premultiplication happens at draw time.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = a,
        };
    }
};

/// Signed distance from point `(px, py)` to a rounded rectangle: negative inside.
pub fn roundedRectSdf(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, radius: f32) f32 {
    const hw = w / 2.0;
    const hh = h / 2.0;
    const cx = x + hw;
    const cy = y + hh;
    const qx = @abs(px - cx) - (hw - radius);
    const qy = @abs(py - cy) - (hh - radius);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - radius;
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Pixel coverage of an SDF: full at d <= -0.5, zero at d >= 0.5.
fn coverage(d: f32) f32 {
    return std.math.clamp(0.5 - d, 0.0, 1.0);
}

fn packPremul(r: f32, g: f32, b: f32, a: f32) u32 {
    const ai: u32 = @intFromFloat(std.math.clamp(a, 0.0, 1.0) * 255.0 + 0.5);
    const ri: u32 = @intFromFloat(std.math.clamp(r * a, 0.0, 1.0) * 255.0 + 0.5);
    const gi: u32 = @intFromFloat(std.math.clamp(g * a, 0.0, 1.0) * 255.0 + 0.5);
    const bi: u32 = @intFromFloat(std.math.clamp(b * a, 0.0, 1.0) * 255.0 + 0.5);
    return (ai << 24) | (ri << 16) | (gi << 8) | bi;
}

/// How the window chrome looks. All lengths are in buffer pixels.
pub const Style = struct {
    /// Corner radius of the glass panel.
    corner_radius: f32 = 18,
    /// Transparent gutter around the panel that hosts the drop shadow.
    margin: u32 = 44,
    /// Penumbra half-width of the shadow falloff.
    shadow_blur: f32 = 26,
    /// Vertical offset of the shadow, a light-from-above cue.
    shadow_offset_y: f32 = 10,
    /// Peak shadow opacity.
    shadow_alpha: f32 = 0.55,
    /// The translucent panel fill; the compositor blur behind it makes it frosted.
    glass: Color = Color.rgba(22, 22, 32, 0.58),
    /// Opacity of the 1px highlight ring that catches the panel edge.
    border_alpha: f32 = 0.22,
    /// Progressive fade-out width of the glass color near the edges (0 to disable).
    glass_fade_width: f32 = 0,
    /// Corner radius of the content frames.
    content_radius: f32 = 14,
    /// Progressive fade-out width of the content near its edges (0 to disable).
    content_fade_width: f32 = 0,
    /// Inset of the compositor blur region relative to the panel (0 for full panel blur).
    blur_inset: f32 = 0,
};

/// A premultiplied ARGB8888 pixel canvas, the exact bytes a wl_shm buffer wants.
pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,

    pub fn init(pixels: []u32, width: u32, height: u32) Canvas {
        std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height));
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    /// Paint the full window chrome: transparent gutter, drop shadow, glass panel,
    /// highlight ring. The panel occupies the canvas minus `style.margin` on each side.
    pub fn drawChrome(self: *Canvas, style: Style) void {
        const m: f32 = @floatFromInt(style.margin);
        const pw = @as(f32, @floatFromInt(self.width)) - 2.0 * m;
        const ph = @as(f32, @floatFromInt(self.height)) - 2.0 * m;
        if (pw <= 0 or ph <= 0) return;

        const g = style.glass;
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const fx = @as(f32, @floatFromInt(x)) + 0.5;

                const d_panel = roundedRectSdf(fx, fy, m, m, pw, ph, style.corner_radius);
                const panel_cov = coverage(d_panel);

                // Shadow: same shape, nudged down, smooth penumbra — and clipped to the
                // outside of the panel so the glass stays clean over the blur.
                const d_shadow = roundedRectSdf(fx, fy - style.shadow_offset_y, m, m, pw, ph, style.corner_radius);
                const shadow = style.shadow_alpha *
                    (1.0 - smoothstep(-style.shadow_blur, style.shadow_blur, d_shadow)) *
                    (1.0 - panel_cov);

                // 1px highlight ring hugging the panel edge from the inside.
                const ring = coverage(@abs(d_panel + 1.0) - 1.0) * style.border_alpha * panel_cov;

                // Composite back-to-front in premultiplied space, starting from the
                // shadow (pure black at alpha `shadow`), then glass, then ring.
                var glass_cov = panel_cov;
                if (style.glass_fade_width > 0.0) {
                    glass_cov *= smoothstep(0.0, style.glass_fade_width, -d_panel);
                }
                const ga = g.a * glass_cov;
                var pr: f32 = 0.0;
                var pg: f32 = 0.0;
                var pb: f32 = 0.0;
                var pa: f32 = shadow;
                pr = g.r * ga + pr * (1.0 - ga);
                pg = g.g * ga + pg * (1.0 - ga);
                pb = g.b * ga + pb * (1.0 - ga);
                pa = ga + pa * (1.0 - ga);
                pr = ring + pr * (1.0 - ring);
                pg = ring + pg * (1.0 - ring);
                pb = ring + pb * (1.0 - ring);
                pa = ring + pa * (1.0 - ring);

                const ai: u32 = @intFromFloat(std.math.clamp(pa, 0.0, 1.0) * 255.0 + 0.5);
                const ri: u32 = @intFromFloat(std.math.clamp(pr, 0.0, 1.0) * 255.0 + 0.5);
                const gi: u32 = @intFromFloat(std.math.clamp(pg, 0.0, 1.0) * 255.0 + 0.5);
                const bi: u32 = @intFromFloat(std.math.clamp(pb, 0.0, 1.0) * 255.0 + 0.5);
                row[x] = (ai << 24) | (ri << 16) | (gi << 8) | bi;
            }
        }
    }

    /// Blit straight-alpha RGBA pixels (zicro's `media.Frame` layout) into the canvas
    /// at `(dst_x, dst_y)`, premultiplying and source-over compositing as it goes,
    /// clipped to both the canvas and a rounded-rect mask matching the panel.
    pub fn blitRgba(
        self: *Canvas,
        dst_x: u32,
        dst_y: u32,
        src: []const u8,
        src_w: u32,
        src_h: u32,
        style: Style,
    ) void {
        const m: f32 = @floatFromInt(style.margin);
        const pw = @as(f32, @floatFromInt(self.width)) - 2.0 * m;
        const ph = @as(f32, @floatFromInt(self.height)) - 2.0 * m;

        const dx_f: f32 = @floatFromInt(dst_x);
        const dy_f: f32 = @floatFromInt(dst_y);
        const sw_f: f32 = @floatFromInt(src_w);
        const sh_f: f32 = @floatFromInt(src_h);

        var sy: u32 = 0;
        while (sy < src_h) : (sy += 1) {
            const y = dst_y + sy;
            if (y >= self.height) break;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            const src_row = src[@as(usize, sy) * src_w * 4 ..][0 .. @as(usize, src_w) * 4];
            var sx: u32 = 0;
            while (sx < src_w) : (sx += 1) {
                const x = dst_x + sx;
                if (x >= self.width) break;
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const mask = coverage(roundedRectSdf(fx, fy, m, m, pw, ph, style.corner_radius));
                if (mask <= 0.0) continue;

                const d_content = roundedRectSdf(fx, fy, dx_f, dy_f, sw_f, sh_f, style.content_radius);
                var content_cov = coverage(d_content);
                if (content_cov <= 0.0) continue;

                if (style.content_fade_width > 0.0) {
                    content_cov *= smoothstep(0.0, style.content_fade_width, -d_content);
                }

                const sp = src_row[@as(usize, sx) * 4 ..][0..4];
                const sa = @as(f32, @floatFromInt(sp[3])) / 255.0 * mask * content_cov;
                if (sa <= 0.0) continue;
                const sr = @as(f32, @floatFromInt(sp[0])) / 255.0;
                const sg = @as(f32, @floatFromInt(sp[1])) / 255.0;
                const sb = @as(f32, @floatFromInt(sp[2])) / 255.0;

                const dst = row[x];
                const da = @as(f32, @floatFromInt((dst >> 24) & 0xff)) / 255.0;
                const dr = @as(f32, @floatFromInt((dst >> 16) & 0xff)) / 255.0;
                const dg = @as(f32, @floatFromInt((dst >> 8) & 0xff)) / 255.0;
                const db = @as(f32, @floatFromInt(dst & 0xff)) / 255.0;

                const inv = 1.0 - sa;
                const oa = sa + da * inv;
                const or_ = sr * sa + dr * inv;
                const og = sg * sa + dg * inv;
                const ob = sb * sa + db * inv;

                const ai: u32 = @intFromFloat(std.math.clamp(oa, 0.0, 1.0) * 255.0 + 0.5);
                const ri: u32 = @intFromFloat(std.math.clamp(or_, 0.0, 1.0) * 255.0 + 0.5);
                const gi: u32 = @intFromFloat(std.math.clamp(og, 0.0, 1.0) * 255.0 + 0.5);
                const bi: u32 = @intFromFloat(std.math.clamp(ob, 0.0, 1.0) * 255.0 + 0.5);
                row[x] = (ai << 24) | (ri << 16) | (gi << 8) | bi;
            }
        }
    }

    /// Fill a rounded rect with a straight-alpha color (source-over). For decorative
    /// content drawn by apps that don't push zicro frames.
    pub fn fillRoundedRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
        const x0: u32 = @intFromFloat(@max(0.0, @floor(x - 1)));
        const y0: u32 = @intFromFloat(@max(0.0, @floor(y - 1)));
        const x1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + w + 1)))));
        const y1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(y + h + 1)))));
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = coverage(roundedRectSdf(fx, fy, x, y, w, h, radius));
                if (cov <= 0.0) continue;
                const sa = color.a * cov;

                const dst = row[px];
                const da = @as(f32, @floatFromInt((dst >> 24) & 0xff)) / 255.0;
                const dr = @as(f32, @floatFromInt((dst >> 16) & 0xff)) / 255.0;
                const dg = @as(f32, @floatFromInt((dst >> 8) & 0xff)) / 255.0;
                const db = @as(f32, @floatFromInt(dst & 0xff)) / 255.0;
                const inv = 1.0 - sa;

                row[px] = packPremul(
                    (color.r * sa + dr * inv) / @max(sa + da * inv, 1e-6),
                    (color.g * sa + dg * inv) / @max(sa + da * inv, 1e-6),
                    (color.b * sa + db * inv) / @max(sa + da * inv, 1e-6),
                    sa + da * inv,
                );
            }
        }
    }
};

test "sdf signs" {
    // Center of a 100x100 rounded rect is deep inside, far corner is outside.
    try std.testing.expect(roundedRectSdf(50, 50, 0, 0, 100, 100, 10) < 0);
    try std.testing.expect(roundedRectSdf(150, 150, 0, 0, 100, 100, 10) > 0);
    // The very corner pixel of the bounding box is outside the rounded shape.
    try std.testing.expect(roundedRectSdf(1, 1, 0, 0, 100, 100, 12) > 0);
}

test "chrome paints premultiplied" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u32, 200 * 160);
    defer gpa.free(px);
    var canvas = Canvas.init(px, 200, 160);
    canvas.drawChrome(.{});
    // Center: glass alpha, premultiplied channels never exceed alpha.
    const c = px[80 * 200 + 100];
    const a = (c >> 24) & 0xff;
    try std.testing.expect(a > 100);
    try std.testing.expect((c >> 16 & 0xff) <= a and (c >> 8 & 0xff) <= a and (c & 0xff) <= a);
    // Corner of the gutter: fully transparent.
    try std.testing.expectEqual(@as(u32, 0), px[0]);
}
