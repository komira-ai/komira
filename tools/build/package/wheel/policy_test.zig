//! The wheel the rule refuses to write, on synthetic libraries: the good
//! library and its owner pass; a library needing GLIBC_2.38 under a 2.34
//! tag, GLIBC_PRIVATE, a GLIBCXX_ or CXXABI_ version over its bound or with
//! no bound set, an absolute or relative-to-the-working-directory run path,
//! a DT_NEEDED nobody provides, a bundled Mojo runtime library, an ELF file
//! in a macOS wheel and a member over 90 MB are each refused by the message
//! that names its check.

const std = @import("std");
const diag = @import("diag.zig");
const policy = @import("policy.zig");
const fixture = @import("testing.zig");
const t = std.testing;

const lib_policy = policy.Policy{
    .glibc = "2.34",
    .max_glibcxx = "3.4.30",
    .max_cxxabi = "1.3.13",
    .external_needed = &fixture.external,
};

fn members(a: std.mem.Allocator, lib: []const u8) ![]policy.Member {
    return a.dupe(policy.Member, &.{
        .{ .name = "komira/_lib/libkomira.so", .data = lib },
        .{ .name = "komira/_lib/lib/libkomira_fs_native.so.1", .data = try fixture.elf(a, .{ .needed = &.{"libc.so.6"}, .runpath = "$ORIGIN" }) },
        .{ .name = "komira/__init__.py", .data = "" },
    });
}

fn refusal(a: std.mem.Allocator, p: policy.Policy, ms: []const policy.Member) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, policy.check(a, &d, p, ms));
    return d.msg;
}

test "the good library, its owner and a Python file pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    try policy.check(a, &d, lib_policy, try members(a, try fixture.goodLibrary(a)));
    // `${ORIGIN}` and a run path of `$ORIGIN` alone pass too; GLIBC_2.34 is
    // at the bound, not over it.
    try policy.check(a, &d, lib_policy, try members(a, try fixture.elf(a, .{ .runpath = "${ORIGIN}/lib:$ORIGIN", .verneed = &.{.{ .file = "libc.so.6", .versions = &.{"GLIBC_2.34"} }} })));
}

test "glibc: a library needing GLIBC_2.38 under a 2.34 tag is refused, and GLIBC_PRIVATE" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const new = try fixture.elf(a, .{ .needed = &.{"libc.so.6"}, .verneed = &.{.{ .file = "libc.so.6", .versions = &.{ "GLIBC_2.17", "GLIBC_2.38" } }} });
    try t.expectEqualStrings("glibc: komira/_lib/libkomira.so needs GLIBC_2.38, newer than the tag's glibc 2.34", try refusal(a, lib_policy, try members(a, new)));
    const private = try fixture.elf(a, .{ .verneed = &.{.{ .file = "libc.so.6", .versions = &.{"GLIBC_PRIVATE"} }} });
    try t.expectEqualStrings("glibc: komira/_lib/libkomira.so needs GLIBC_PRIVATE, which no glibc release promises", try refusal(a, lib_policy, try members(a, private)));
}

test "glibcxx and cxxabi: a version over the bound, or any with no bound set, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cxx = try fixture.elf(a, .{ .verneed = &.{.{ .file = "libstdc++.so.6", .versions = &.{"GLIBCXX_3.4.32"} }} });
    try t.expectEqualStrings("glibcxx: komira/_lib/libkomira.so needs GLIBCXX_3.4.32, newer than the max_glibcxx 3.4.30", try refusal(a, lib_policy, try members(a, cxx)));
    var unset = lib_policy;
    unset.max_glibcxx = null;
    try t.expectEqualStrings("glibcxx: komira/_lib/libkomira.so needs GLIBCXX_3.4.29, and the rule sets no max_glibcxx", try refusal(a, unset, try members(a, try fixture.goodLibrary(a))));
    const abi = try fixture.elf(a, .{ .verneed = &.{.{ .file = "libstdc++.so.6", .versions = &.{"CXXABI_1.3.15"} }} });
    try t.expectEqualStrings("cxxabi: komira/_lib/libkomira.so needs CXXABI_1.3.15, newer than the max_cxxabi 1.3.13", try refusal(a, lib_policy, try members(a, abi)));
    unset = lib_policy;
    unset.max_cxxabi = null;
    try t.expectEqualStrings("cxxabi: komira/_lib/libkomira.so needs CXXABI_1.3.13, and the rule sets no max_cxxabi", try refusal(a, unset, try members(a, try fixture.goodLibrary(a))));
    const odd = try fixture.elf(a, .{ .verneed = &.{.{ .file = "libstdc++.so.6", .versions = &.{"GLIBCXX_3.4.x"} }} });
    try t.expectEqualStrings("glibcxx: komira/_lib/libkomira.so needs GLIBCXX_3.4.x, which is not a dotted version", try refusal(a, lib_policy, try members(a, odd)));
}

test "runpath: an absolute or working-directory run path entry is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = try fixture.elf(a, .{ .runpath = "$ORIGIN/lib:/opt/build/out/lib" });
    try t.expectEqualStrings("runpath: komira/_lib/libkomira.so has the run path entry `/opt/build/out/lib`, which is not $ORIGIN-relative", try refusal(a, lib_policy, try members(a, abs)));
    for ([_][]const u8{ "lib", "$ORIGINAL", "" }) |r| {
        const bad = try fixture.elf(a, .{ .rpath = if (r.len == 0) "$ORIGIN::" else r });
        _ = try refusal(a, lib_policy, try members(a, bad));
    }
    const rpath = try fixture.elf(a, .{ .rpath = "/opt/lib" });
    try t.expectEqualStrings("runpath: komira/_lib/libkomira.so has the run path entry `/opt/lib`, which is not $ORIGIN-relative", try refusal(a, lib_policy, try members(a, rpath)));
}

test "needed: a DT_NEEDED nobody provides is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lib = try fixture.elf(a, .{ .needed = &.{ "libc.so.6", "libssl.so.3" } });
    try t.expectEqualStrings("needed: komira/_lib/libkomira.so needs libssl.so.3, which is not in the wheel, not a manylinux system library, and not in external_needed", try refusal(a, lib_policy, try members(a, lib)));
    // The owner is found by its file name in the wheel: without it, refused.
    const ms = try members(a, try fixture.goodLibrary(a));
    try t.expectEqualStrings("needed: komira/_lib/libkomira.so needs libkomira_fs_native.so.1, which is not in the wheel, not a manylinux system library, and not in external_needed", try refusal(a, lib_policy, &.{ ms[0], ms[2] }));
}

test "external: a bundled Mojo runtime library is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ms = try members(a, try fixture.goodLibrary(a));
    const bundled = try std.mem.concat(a, policy.Member, &.{ ms, &.{.{ .name = "komira/_lib/lib/libKGENCompilerRTShared.so", .data = try fixture.elf(a, .{}) }} });
    try t.expectEqualStrings("external: the wheel carries komira/_lib/lib/libKGENCompilerRTShared.so, which external_needed says comes from another package and never from this wheel", try refusal(a, lib_policy, bundled));
}

test "arch: an ELF file for another machine than the tag's is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arm = try fixture.elf(a, .{ .machine = 183 });
    try t.expectEqualStrings("arch: komira/_lib/libkomira.so is an ELF file for machine 183, not the tag's x86_64 (62)", try refusal(a, lib_policy, try members(a, arm)));
    var aarch64 = lib_policy;
    aarch64.arch = "aarch64";
    var d = diag.Diag{};
    try policy.check(a, &d, aarch64, &.{.{ .name = "komira/_lib/libkomira.so", .data = arm }});
    try t.expectEqualStrings("arch: komira/_lib/libkomira.so is an ELF file for machine 62, not the tag's aarch64 (183)", try refusal(a, aarch64, &.{.{ .name = "komira/_lib/libkomira.so", .data = try fixture.elf(a, .{}) }}));
}

test "platform: an ELF file in a macOS wheel is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mac = lib_policy;
    mac.glibc = null;
    try t.expectEqualStrings("platform: komira/_lib/libkomira.so is an ELF file, and a macOS wheel holds none", try refusal(a, mac, try members(a, try fixture.goodLibrary(a))));
    var d = diag.Diag{};
    try policy.check(a, &d, mac, &.{.{ .name = "komira/__init__.py", .data = "" }});
}

test "size: a member over 90 MB is refused, one of exactly 90 MB passes" {
    const big = try t.allocator.alloc(u8, policy.max_member + 1);
    defer t.allocator.free(big);
    @memset(big, 0);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    try policy.check(a, &d, lib_policy, &.{.{ .name = "komira/data.bin", .data = big[0..policy.max_member] }});
    try t.expectEqualStrings("size: komira/data.bin is 90000001 bytes, over the 90000000 a wheel member may be (PyPI takes 100 MB a file)", try refusal(a, lib_policy, &.{.{ .name = "komira/data.bin", .data = big }}));
}
