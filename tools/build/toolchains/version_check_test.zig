//! Unit tests of version_check.zig's verdict. The program itself runs on the real
//! pinned pixi (//tools/build/toolchains:pixi_version) and, in a planted
//! wrong-version target, must fail (tests//negative).
const std = @import("std");
const V = @import("version_check.zig");
const t = std.testing;

test "refusal: the expected version passes; another version and a failed run are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try V.refusal(a, "pixi", true, "pixi 0.40.0", "pixi 0.40.0")) == null);
    try t.expectEqualStrings(
        "pixi --version printed 'pixi 0.39.0', expected 'pixi 0.40.0' (tools/build/platforms/table.bzl)",
        (try V.refusal(a, "pixi", true, "pixi 0.39.0", "pixi 0.40.0")).?,
    );
    try t.expectEqualStrings("pixi --version failed: boom", (try V.refusal(a, "pixi", false, "boom", "pixi 0.40.0")).?);
    // A failed run is refused even when it printed the expected line.
    try t.expect((try V.refusal(a, "pixi", false, "pixi 0.40.0", "pixi 0.40.0")) != null);
}
