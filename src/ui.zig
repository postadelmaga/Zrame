//! # zrame.ui — shared widget helpers
//!
//! Small, dependency-free math the panels share: the frame-rate-independent boolean
//! animation egui uses for hover/fade, plus the easing curves. Kept separate so
//! `controls.zig`, `menu.zig` and `scroll.zig` animate identically.

const std = @import("std");

/// Time for an `approach` factor to travel the full 0↔1 range, in seconds. Matches
/// egui's `animate_bool_responsive` (~1/12 s) so fades feel the same as the reference.
pub const anim_time: f32 = 0.0833;

/// Ease-out cubic: fast start, gentle stop — egui's `cubic_out`, used for fades/reveals.
pub fn cubicOut(t: f32) f32 {
    const u = 1.0 - std.math.clamp(t, 0.0, 1.0);
    return 1.0 - u * u * u;
}

/// Smoothstep ease-in-out (`3t²−2t³`) — for symmetric transitions (menu open/close).
pub fn easeInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

/// Advance a linear 0..1 `factor` toward `target` by one `dt` step (reaching either end
/// in `anim_time`). Store the linear factor; apply `cubicOut`/`easeInOut` when you read
/// it. Returns the new factor; compare to the old to know if it still moved.
pub fn approach(factor: f32, target: bool, dt: f32) f32 {
    const step = dt / anim_time;
    return std.math.clamp(factor + (if (target) step else -step), 0.0, 1.0);
}

/// Linear interpolation.
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Map `v` from `[in0,in1]` to `[out0,out1]`, clamped to the output range.
pub fn remapClamp(v: f32, in0: f32, in1: f32, out0: f32, out1: f32) f32 {
    if (in1 == in0) return out0;
    const t = std.math.clamp((v - in0) / (in1 - in0), 0.0, 1.0);
    return out0 + (out1 - out0) * t;
}

test "approach reaches the target and clamps" {
    var f: f32 = 0;
    // ~anim_time worth of 16ms steps should saturate at 1.
    var i: usize = 0;
    while (i < 8) : (i += 1) f = approach(f, true, 0.016);
    try std.testing.expect(f == 1.0);
    i = 0;
    while (i < 8) : (i += 1) f = approach(f, false, 0.016);
    try std.testing.expect(f == 0.0);
}

test "cubicOut endpoints and remapClamp bounds" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), cubicOut(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cubicOut(1), 1e-6);
    try std.testing.expectEqual(@as(f32, 5), remapClamp(-3, 0, 10, 5, 25)); // below → out0
    try std.testing.expectEqual(@as(f32, 25), remapClamp(999, 0, 10, 5, 25)); // above → out1
    try std.testing.expectApproxEqAbs(@as(f32, 15), remapClamp(5, 0, 10, 5, 25), 1e-5);
}
