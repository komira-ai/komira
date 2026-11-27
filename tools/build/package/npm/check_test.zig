//! The read-back check: the tarball the builder writes passes, stamped and
//! with its twin, and unstamped when no release is required; and each defect
//! is refused by the message that names its check: an unstamped package
//! where a release is required, another file name, a tarball that does not
//! read back, a stray member the rule did not give, a member missing, out of
//! order, of other bytes or another mode, a member the native policy refuses
//! on its own (a Mojo runtime library missing from the platform package),
//! and a twin of other bytes.

const std = @import("std");
const diag = @import("native_policy").diag;
const check = @import("check.zig");
const npm = @import("npm.zig");
const tarball = @import("tarball.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const main_name = "komira-ai-komira-0.1.57.tgz";

fn good(a: Alloc, in: npm.Input) ![]tarball.Member {
    var d = diag.Diag{};
    return a.dupe(tarball.Member, try tarball.read(a, &d, try npm.build(a, &d, in)));
}

fn tgz(a: Alloc, ms: []const tarball.Member) ![]u8 {
    var d = diag.Diag{};
    return tarball.write(a, &d, ms);
}

fn refusal(a: Alloc, in: npm.Input, name: []const u8, bytes: []const u8, require_stamped: bool, twin: ?[]const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, check.check(a, &d, in, name, bytes, require_stamped, twin));
    return d.msg;
}

test "the builder's tarball passes, stamped and with its twin, and unstamped when no release is required" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const in = try fixture.mainInput(a);
    const bytes = try npm.build(a, &d, in);
    try check.check(a, &d, in, main_name, bytes, true, bytes);
    const plat = try fixture.platformInput(a);
    const pbytes = try npm.build(a, &d, plat);
    try check.check(a, &d, plat, "komira-ai-komira-linux-x64-gnu-0.1.57.tgz", pbytes, true, pbytes);

    var dev = in;
    dev.version = "0.0.0";
    dev.stamped = false;
    try check.check(a, &d, dev, "komira-ai-komira-0.0.0.tgz", try npm.build(a, &d, dev), false, null);
}

test "stamp and name: an unstamped package where a release is required, and another file name, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    var dev = try fixture.mainInput(a);
    dev.version = "0.0.0";
    dev.stamped = false;
    const bytes = try npm.build(a, &d, dev);
    try t.expectEqualStrings("stamp: the package is unstamped (version 0.0.0): a development package, never a release", try refusal(a, dev, "komira-ai-komira-0.0.0.tgz", bytes, true, null));
    try t.expectEqualStrings("name: the tarball is named komira-0.0.0.tgz, not komira-ai-komira-0.0.0.tgz", try refusal(a, dev, "komira-0.0.0.tgz", bytes, false, null));
}

test "members: a stray member, a missing one, one out of order, of other bytes or another mode are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try fixture.mainInput(a);
    const ms = try good(a, in);

    const stray = try std.mem.concat(a, tarball.Member, &.{ ms, &.{.{ .name = "package/zz.log", .data = "left over\n" }} });
    try t.expectEqualStrings("members: the tarball carries package/zz.log, which the rule did not give", try refusal(a, in, main_name, try tgz(a, stray), true, null));

    const early = try std.mem.concat(a, tarball.Member, &.{ ms[0..1], &.{.{ .name = "package/.npmrc", .data = "" }}, ms[1..] });
    try t.expectEqualStrings("members: member 1 is package/.npmrc, not package/NOTICE", try refusal(a, in, main_name, try tgz(a, early), true, null));

    try t.expectEqualStrings("members: the tarball has no package/package.json", try refusal(a, in, main_name, try tgz(a, ms[0 .. ms.len - 1]), true, null));

    const swapped = try a.dupe(tarball.Member, ms);
    std.mem.swap(tarball.Member, &swapped[0], &swapped[1]);
    try t.expectEqualStrings("members: member 0 is package/NOTICE, not package/LICENSE", try refusal(a, in, main_name, try tgz(a, swapped), true, null));

    const changed = try a.dupe(tarball.Member, ms);
    changed[1].data = "another notice\n";
    try t.expectEqualStrings("members: package/NOTICE is not the file given", try refusal(a, in, main_name, try tgz(a, changed), true, null));

    const moded = try a.dupe(tarball.Member, ms);
    moded[1].mode = 0o755;
    try t.expectEqualStrings("mode: package/NOTICE has mode 755, not 644", try refusal(a, in, main_name, try tgz(a, moded), true, null));
}

test "a tarball that does not read back, a platform package missing a runtime library, and a twin of other bytes are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const in = try fixture.mainInput(a);
    const bytes = try npm.build(a, &d, in);
    try t.expectEqualStrings("gzip: the tarball does not start with the gzip header this tool writes (deflate, no flags, no time, OS 255)", try refusal(a, in, main_name, bytes[1..], true, null));

    // The rule's input without libMSupportGlobals.so: the check refuses it as
    // the build does, before it compares the tarball.
    const plat = try fixture.platformInput(a);
    const lacking = try fixture.platformInputOf(a, try fixture.without(a, try fixture.nativeFiles(a), "native/lib/libMSupportGlobals.so"));
    try t.expectEqualStrings(
        "needed: native/lib/libKGENCompilerRTShared.so needs libMSupportGlobals.so, which is not in the package, not a manylinux system library, and not in external_needed",
        try refusal(a, lacking, "komira-ai-komira-linux-x64-gnu-0.1.57.tgz", try npm.build(a, &d, plat), true, null),
    );

    var other = try fixture.mainInput(a);
    const files = try a.dupe(npm.File, other.files);
    files[0].data = "export const version = \"0.1.58\";\n";
    other.files = files;
    const twin = try npm.build(a, &d, other);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "twin: the package written twice from the same inputs, staged at two paths, is not the same bytes ({d} and {d} bytes): the build is not reproducible", .{ bytes.len, twin.len }), try refusal(a, in, main_name, bytes, true, twin));
}
