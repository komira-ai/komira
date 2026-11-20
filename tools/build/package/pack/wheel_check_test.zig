//! The read-back check: the directory the builder writes passes, and every
//! defect of the module doc of wheel_check.zig is refused by name: an extra
//! or missing file, a manifest of other bytes, a RECORD hash, size, row or
//! member that disagrees, another tag, other METADATA, a missing or changed
//! licence, a missing py.typed or library, a library not executable, a Mojo
//! runtime library carried, an unstamped or commit-less release, and a twin
//! of other bytes.

const std = @import("std");
const project = @import("wheel_project.zig");
const wheel = @import("wheel.zig");
const zip = @import("wheel_zip.zig");
const check = @import("wheel_check.zig");
const common = @import("common.zig");
const fixture = @import("wheel_testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const commit = "7e57c0de1f2e3d4c5b6a79880a1b2c3d4e5f6071";

fn expect(a: Alloc) !check.Expect {
    const in = try fixture.input(a);
    return .{
        .project = in.project,
        .readme = in.readme,
        .version_base = "1.0.0",
        .stamp = "57",
        .commit = commit,
        .tag = in.tag,
        .platform = "linux-x86_64",
        .runtime_requires = in.runtime_requires,
        .import_name = in.import_name,
        .native_lib = in.native_lib,
        .forbid = in.native_drop,
        .licenses = in.licenses,
        .require_stamped = true,
    };
}

/// The output directory of a wheel made of `members` (RECORD rewritten for
/// them unless `keep_record`), as the builder would write it.
fn dirOf(a: Alloc, members: []const zip.Member, keep_record: bool) !check.Dir {
    var ms = try a.dupe(zip.Member, members);
    if (!keep_record) {
        const last = ms.len - 1;
        ms[last].data = try wheel.renderRecord(a, ms[0..last], ms[last].name);
    }
    var d = project.Diag{};
    const z = try zip.write(a, &d, ms);
    const name = "komira-1.0.0.post57-py3-none-manylinux_2_34_x86_64.whl";
    var meta: []const u8 = "";
    for (ms) |m| if (std.mem.endsWith(u8, m.name, "/METADATA")) {
        meta = m.data;
    };
    return .{
        .names = try a.dupe([]const u8, &.{ "manifest.json", name, "METADATA" }),
        .manifest = try wheel.manifest(a, "komira", "1.0.0.post57", "linux-x86_64", name, &common.sha256Hex(z)),
        .metadata = meta,
        .wheel_name = name,
        .wheel = z,
    };
}

fn goodMembers(a: Alloc) ![]zip.Member {
    var d = project.Diag{};
    const built = try wheel.build(a, &d, try fixture.input(a));
    return zip.read(a, &d, built.wheel);
}

fn index(ms: []const zip.Member, suffix: []const u8) usize {
    for (ms, 0..) |m, i| if (std.mem.endsWith(u8, m.name, suffix)) return i;
    unreachable;
}

fn refusal(a: Alloc, e: check.Expect, dir: check.Dir, twin: ?[]const u8) ![]const u8 {
    var d = project.Diag{};
    try t.expectError(error.Refused, check.check(a, &d, e, dir, twin));
    return d.msg;
}

test "the directory the builder writes passes, with its twin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dirOf(a, try goodMembers(a), true);
    var d = project.Diag{};
    try check.check(a, &d, try expect(a), dir, dir.wheel);
}

test "a twin of other bytes is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dirOf(a, try goodMembers(a), true);
    const other = try a.dupe(u8, dir.wheel);
    other[other.len - 1] ^= 1;
    try t.expect(std.mem.startsWith(u8, try refusal(a, try expect(a), dir, other), "the wheel built twice from the same inputs, staged at two paths, is not the same bytes"));
}

test "an unstamped build, or a stamp without its commit, is refused for a release" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try dirOf(a, try goodMembers(a), true);
    var e = try expect(a);
    e.stamp = "0";
    try t.expectEqualStrings("the wheel is not stamped (version 1.0.0.post0): an unstamped build is a development output, never a release", try refusal(a, e, dir, null));
    e = try expect(a);
    e.commit = "";
    try t.expectEqualStrings("the stamp 57 comes with no source commit of 40 lowercase hex digits (``)", try refusal(a, e, dir, null));
    e.commit = "7E57C0DE1F2E3D4C5B6A79880A1B2C3D4E5F6071";
    try t.expectEqualStrings("the stamp 57 comes with no source commit of 40 lowercase hex digits (`7E57C0DE1F2E3D4C5B6A79880A1B2C3D4E5F6071`)", try refusal(a, e, dir, null));
    // Without require_stamped the development output passes, and a wheel
    // whose name says another stamp is refused.
    e = try expect(a);
    e.require_stamped = false;
    var d = project.Diag{};
    try check.check(a, &d, e, dir, null);
    e.stamp = "58";
    try t.expectEqualStrings("the wheel is named komira-1.0.0.post57-py3-none-manylinux_2_34_x86_64.whl, not komira-1.0.0.post58-py3-none-manylinux_2_34_x86_64.whl", try refusal(a, e, dir, null));
}

test "a directory of other files, or a manifest of other bytes, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try dirOf(a, try goodMembers(a), true);
    const e = try expect(a);
    const names = dir.names;
    dir.names = try std.mem.concat(a, []const u8, &.{ names, &.{"extra.txt"} });
    try t.expectEqualStrings("the directory holds 4 files, not manifest.json, METADATA and komira-1.0.0.post57-py3-none-manylinux_2_34_x86_64.whl", try refusal(a, e, dir, null));
    dir.names = &.{ "manifest.json", "manifest.json", names[1] };
    try t.expectEqualStrings("the directory does not hold `METADATA` once", try refusal(a, e, dir, null));
    dir.names = names;
    dir.manifest = try wheel.manifest(a, "komira", "1.0.0.post57", "linux-x86_64", dir.wheel_name, "00");
    try t.expect(std.mem.startsWith(u8, try refusal(a, e, dir, null), "manifest.json is not the manifest of this wheel:"));
}

test "RECORD that disagrees with the members is refused, each way" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try expect(a);
    const good = try goodMembers(a);
    const rec = good.len - 1;
    const record_name = good[rec].name;
    const Case = struct { from: []const u8, to: []const u8, want: []const u8 };
    const init_row = try std.fmt.allocPrint(a, "komira/__init__.py,{s},24\n", .{try wheel.recordHash(a, "__all__: list[str] = []\n")});
    const self_row = try std.fmt.allocPrint(a, "{s},,\n", .{record_name});
    const cases = [_]Case{
        .{ .from = ",24\n", .to = ",25\n", .want = "RECORD gives `komira/__init__.py` the size 25, but it holds 24 bytes" },
        .{ .from = init_row, .to = "", .want = "`komira/__init__.py` is in the wheel but not in RECORD" },
        .{ .from = init_row, .to = try std.mem.concat(a, u8, &.{ init_row, init_row }), .want = "RECORD lists `komira/__init__.py` twice" },
        .{ .from = init_row, .to = try std.mem.concat(a, u8, &.{ init_row, "komira/gone.py,sha256=x,1\n" }), .want = "RECORD lists `komira/gone.py`, which the wheel does not hold" },
        .{ .from = init_row, .to = "komira/__init__.py,sha256=x\n", .want = "RECORD line 1 has no size column" },
        .{ .from = init_row, .to = "komira/__init__.py\n", .want = "RECORD line 1 has no hash column" },
        .{ .from = init_row, .to = "komira/__init__.py,a,b,c\n", .want = "RECORD line 1 has more than three columns" },
        .{ .from = init_row, .to = "\n", .want = "RECORD line 1 is empty" },
        .{ .from = self_row, .to = "", .want = "RECORD does not list itself" },
        .{ .from = self_row, .to = try std.fmt.allocPrint(a, "{s},sha256=x,1\n", .{record_name}), .want = "RECORD lists itself twice, or with a hash or size" },
    };
    for (cases) |c| {
        const ms = try a.dupe(zip.Member, good);
        ms[rec].data = try std.mem.replaceOwned(u8, a, good[rec].data, c.from, c.to);
        try t.expect(!std.mem.eql(u8, ms[rec].data, good[rec].data));
        try t.expectEqualStrings(c.want, try refusal(a, e, try dirOf(a, ms, true), null));
    }
    // A member's bytes changed after RECORD was written.
    const ms = try a.dupe(zip.Member, good);
    ms[0].data = "changed\n";
    try t.expect(std.mem.startsWith(u8, try refusal(a, e, try dirOf(a, ms, true), null), "RECORD gives `komira/__init__.py` the hash sha256="));
    // RECORD not last.
    const moved = try a.dupe(zip.Member, good);
    std.mem.swap(zip.Member, &moved[rec], &moved[rec - 1]);
    try t.expectEqualStrings("the last member is not komira-1.0.0.post57.dist-info/RECORD", try refusal(a, e, try dirOf(a, moved, true), null));
}

test "another tag, other METADATA, or METADATA beside the manifest of other bytes, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var e = try expect(a);
    const good = try goodMembers(a);
    e.tag = "py3-none-manylinux_2_28_x86_64";
    var dir = try dirOf(a, good, true);
    dir.wheel_name = "komira-1.0.0.post57-py3-none-manylinux_2_28_x86_64.whl";
    dir.names = &.{ "manifest.json", dir.wheel_name, "METADATA" };
    dir.manifest = try wheel.manifest(a, "komira", "1.0.0.post57", "linux-x86_64", dir.wheel_name, &common.sha256Hex(dir.wheel));
    try t.expect(std.mem.startsWith(u8, try refusal(a, e, dir, null), "WHEEL is not the one for the tag py3-none-manylinux_2_28_x86_64:"));

    e = try expect(a);
    e.runtime_requires = &.{"mojo-compiler==1.2.0"};
    try t.expectEqualStrings("METADATA is not the one the pyproject, the version 1.0.0.post57 and the runtime requirements give", try refusal(a, e, try dirOf(a, good, true), null));

    e = try expect(a);
    dir = try dirOf(a, good, true);
    dir.metadata = "Metadata-Version: 2.4\n";
    try t.expectEqualStrings("the METADATA beside the manifest differs from the wheel's", try refusal(a, e, dir, null));
}

test "a licence missing, changed or extra is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try expect(a);
    const good = try goodMembers(a);
    const lic = index(good, "/licenses/LICENSE");

    const dropped = try std.mem.concat(a, zip.Member, &.{ good[0..lic], good[lic + 1 ..] });
    try t.expectEqualStrings("the wheel has no licence file komira-1.0.0.post57.dist-info/licenses/LICENSE", try refusal(a, e, try dirOf(a, dropped, false), null));

    const changed = try a.dupe(zip.Member, good);
    changed[lic].data = "another licence\n";
    try t.expectEqualStrings("the licence file komira-1.0.0.post57.dist-info/licenses/LICENSE differs from the one given", try refusal(a, e, try dirOf(a, changed, false), null));

    const extra = try std.mem.concat(a, zip.Member, &.{ good[0..lic], &.{.{ .name = "komira-1.0.0.post57.dist-info/licenses/COPYING", .data = "x" }}, good[lic..] });
    try t.expectEqualStrings("the wheel carries the licence member komira-1.0.0.post57.dist-info/licenses/COPYING, which no licence file given is", try refusal(a, e, try dirOf(a, extra, false), null));
}

test "the package's files and library must be there, the library executable, and no runtime library" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try expect(a);
    const good = try goodMembers(a);
    const Case = struct { suffix: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .suffix = "komira/__init__.py", .want = "the wheel has no komira/__init__.py" },
        .{ .suffix = "komira/py.typed", .want = "the wheel has no komira/py.typed: the package ships typed" },
        .{ .suffix = "komira/_lib/libkomira.so", .want = "the wheel has no komira/_lib/libkomira.so" },
        .{ .suffix = "/WHEEL", .want = "the wheel has no komira-1.0.0.post57.dist-info/WHEEL" },
        .{ .suffix = "/METADATA", .want = "the wheel has no komira-1.0.0.post57.dist-info/METADATA" },
    }) |c| {
        const i = index(good, c.suffix);
        try t.expectEqualStrings(c.want, try refusal(a, e, try dirOf(a, try std.mem.concat(a, zip.Member, &.{ good[0..i], good[i + 1 ..] }), false), null));
    }

    const plain = try a.dupe(zip.Member, good);
    plain[index(good, "/libkomira.so")].mode = 0o644;
    try t.expectEqualStrings("komira/_lib/libkomira.so is not executable (mode 644)", try refusal(a, e, try dirOf(a, plain, false), null));

    const i = index(good, "/libkomira.so");
    const runtime = try std.mem.concat(a, zip.Member, &.{ good[0..i], &.{.{ .name = "komira/_lib/lib/libKGENCompilerRTShared.so", .data = "runtime", .mode = 0o755 }}, good[i..] });
    try t.expectEqualStrings("the wheel carries `komira/_lib/lib/libKGENCompilerRTShared.so`, a library of the Mojo runtime, which comes from its own package and never from this wheel", try refusal(a, e, try dirOf(a, runtime, false), null));

    const twice = try std.mem.concat(a, zip.Member, &.{ good[0..1], good });
    try t.expectEqualStrings("`komira/__init__.py` is in the wheel twice", try refusal(a, e, try dirOf(a, twice, false), null));
}
