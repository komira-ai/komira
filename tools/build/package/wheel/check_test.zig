//! The read-back check: the wheel the builder writes passes, stamped and
//! with its twin; and each defect is refused by the message that names its
//! check: an unstamped wheel where a release is required, another name or
//! version, a member dated otherwise, a member missing, extra, out of order,
//! of other bytes or another mode, RECORD that disagrees each way, another
//! tag or WHEEL, other Requires-Dist or METADATA, a changed licence, a member
//! the policy refuses, and a twin of other bytes. A macOS wheel of a dylib and
//! the runtime dylibs passes, and the same wheel with a dylib needing a newer
//! macOS than its tag is refused by the minos check.

const std = @import("std");
const diag = @import("native_policy").diag;
const check = @import("check.zig");
const stamp_mod = @import("stamp.zig");
const wheel = @import("wheel.zig");
const zip = @import("zip.zig");
const fixture = @import("testing.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

const commit = "7e57c0de1f2e3d4c5b6a79880a1b2c3d4e5f6071";
const name = "komira-0.1.57-py3-none-manylinux_2_34_x86_64.whl";

fn stamped(a: Alloc) !stamp_mod.Stamp {
    var d = diag.Diag{};
    return stamp_mod.of(a, &d, "57", commit, "1795186129000");
}

fn dateOf(a: Alloc) !zip.Stamp {
    var d = diag.Diag{};
    return zip.stampOf(a, &d, 1795186129000);
}

fn good(a: Alloc) ![]zip.Member {
    var d = diag.Diag{};
    const bytes = try wheel.build(a, &d, try fixture.input(a), try dateOf(a));
    var out = std.ArrayList(zip.Member).empty;
    for (try zip.read(a, &d, bytes)) |m| try out.append(a, .{ .name = m.name, .data = m.data, .mode = m.mode });
    return out.toOwnedSlice(a);
}

/// The zip of `ms` (RECORD rewritten for them unless `keep_record`).
fn zipOf(a: Alloc, ms: []const zip.Member, keep_record: bool) ![]u8 {
    const copy = try a.dupe(zip.Member, ms);
    if (!keep_record) {
        const last = copy.len - 1;
        copy[last].data = try wheel.renderRecord(a, copy[0..last], copy[last].name);
    }
    var d = diag.Diag{};
    return zip.write(a, &d, copy, try dateOf(a));
}

fn index(ms: []const zip.Member, suffix: []const u8) usize {
    for (ms, 0..) |m, i| if (std.mem.endsWith(u8, m.name, suffix)) return i;
    unreachable;
}

fn refusal(a: Alloc, in: wheel.Input, bytes: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, check.check(a, &d, in, try stamped(a), name, bytes, true, null));
    return d.msg;
}

test "the builder's wheel passes, stamped and with its twin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try zipOf(a, try good(a), true);
    var d = diag.Diag{};
    try check.check(a, &d, try fixture.input(a), try stamped(a), name, bytes, true, bytes);
}

test "stamp: an unstamped wheel is not a release, and the version is the stamp's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const none = try stamp_mod.of(a, &d, "0", "", "0");
    var in = try fixture.input(a);
    in.version = none.version;
    const bytes = try wheel.build(a, &d, in, .{});
    const dev = "komira-0.0.0-py3-none-manylinux_2_34_x86_64.whl";
    try t.expectError(error.Refused, check.check(a, &d, in, none, dev, bytes, true, null));
    try t.expectEqualStrings("stamp: the wheel is unstamped (version 0.0.0): a development wheel, never a release", d.msg);
    // A development check of it passes.
    try check.check(a, &d, in, none, dev, bytes, false, null);
    try t.expectError(error.Refused, check.check(a, &d, try fixture.input(a), none, dev, bytes, false, null));
    try t.expectEqualStrings("stamp: the version 0.1.57 is not the stamp's 0.0.0", d.msg);
}

test "name and date: another file name, or a member dated otherwise, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try fixture.input(a);
    const bytes = try zipOf(a, try good(a), true);
    var d = diag.Diag{};
    try t.expectError(error.Refused, check.check(a, &d, in, try stamped(a), "komira-0.1.58-py3-none-manylinux_2_34_x86_64.whl", bytes, true, null));
    try t.expectEqualStrings("name: the wheel is named komira-0.1.58-py3-none-manylinux_2_34_x86_64.whl, not komira-0.1.57-py3-none-manylinux_2_34_x86_64.whl", d.msg);
    var dd = diag.Diag{};
    const undated = try zip.write(a, &dd, try good(a), .{});
    try t.expect(std.mem.startsWith(u8, try refusal(a, in, undated), "date: komira/__init__.py is dated 21/0, not the stamp's"));
}

test "members: one missing, extra, out of order, of other bytes or another mode is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try fixture.input(a);
    const ms = try good(a);

    const lib = index(ms, "/libkomira.so");
    const dropped = try std.mem.concat(a, zip.Member, &.{ ms[0..lib], ms[lib + 1 ..] });
    try t.expectEqualStrings("members: member 2 is komira-0.1.57.dist-info/METADATA, not komira/_lib/libkomira.so", try refusal(a, in, try zipOf(a, dropped, false)));

    const extra = try std.mem.concat(a, zip.Member, &.{ ms, &.{.{ .name = "komira/extra.txt", .data = "" }} });
    try t.expectEqualStrings("members: the wheel carries komira/extra.txt, which the rule did not give", try refusal(a, in, try zipOf(a, extra, true)));

    const swapped = try a.dupe(zip.Member, ms);
    std.mem.swap(zip.Member, &swapped[0], &swapped[1]);
    try t.expectEqualStrings("members: member 0 is komira/_lib/lib/libkomira_fs_native.so.1, not komira/__init__.py", try refusal(a, in, try zipOf(a, swapped, false)));

    const changed = try a.dupe(zip.Member, ms);
    changed[0].data = "import os\n";
    try t.expectEqualStrings("members: komira/__init__.py is not the file given", try refusal(a, in, try zipOf(a, changed, false)));

    const plain = try a.dupe(zip.Member, ms);
    plain[lib].mode = 0o644;
    try t.expectEqualStrings("mode: komira/_lib/libkomira.so has mode 644, not 755", try refusal(a, in, try zipOf(a, plain, false)));
    const exec_meta = try a.dupe(zip.Member, ms);
    exec_meta[index(ms, "/METADATA")].mode = 0o755;
    try t.expectEqualStrings("mode: komira-0.1.57.dist-info/METADATA has mode 755, not 644", try refusal(a, in, try zipOf(a, exec_meta, false)));

    const short = ms[0 .. ms.len - 1];
    try t.expectEqualStrings("members: the wheel has no komira-0.1.57.dist-info/RECORD", try refusal(a, in, try zipOf(a, short, true)));
}

test "record: RECORD that disagrees with the members is refused, each way" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try fixture.input(a);
    const ms = try good(a);
    const rec = ms.len - 1;
    const record_name = ms[rec].name;
    const init_row = try std.fmt.allocPrint(a, "komira/__init__.py,{s},24\n", .{try wheel.recordHash(a, "__all__: list[str] = []\n")});
    const self_row = try std.fmt.allocPrint(a, "{s},,\n", .{record_name});
    const Case = struct { from: []const u8, to: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .from = init_row, .to = "komira/__init__.py,sha256=x,24\n", .want = "record: RECORD gives `komira/__init__.py` the hash sha256=x, but its bytes hash to sha256=juqd9PbXs4yg45zMJ7BHAOPQjb7sgEbWE9InBtGZhfo" },
        .{ .from = ",24\n", .to = ",25\n", .want = "record: RECORD gives `komira/__init__.py` the size 25, but it holds 24 bytes" },
        .{ .from = init_row, .to = "", .want = "record: `komira/__init__.py` is in the wheel but not in RECORD" },
        .{ .from = init_row, .to = try std.mem.concat(a, u8, &.{ init_row, init_row }), .want = "record: RECORD lists `komira/__init__.py` twice" },
        .{ .from = init_row, .to = try std.mem.concat(a, u8, &.{ init_row, "komira/gone.py,sha256=x,1\n" }), .want = "record: RECORD lists `komira/gone.py`, which the wheel does not hold" },
        .{ .from = init_row, .to = "komira/__init__.py,sha256=x\n", .want = "record: line 1 has no size column" },
        .{ .from = init_row, .to = "komira/__init__.py\n", .want = "record: line 1 has no hash column" },
        .{ .from = init_row, .to = "komira/__init__.py,a,b,c\n", .want = "record: line 1 has more than three columns" },
        .{ .from = init_row, .to = "\n", .want = "record: line 1 is empty" },
        .{ .from = self_row, .to = "", .want = "record: RECORD does not list itself" },
        .{ .from = self_row, .to = try std.fmt.allocPrint(a, "{s},sha256=x,1\n", .{record_name}), .want = "record: RECORD lists itself twice, or with a hash or size" },
    }) |c| {
        const copy = try a.dupe(zip.Member, ms);
        copy[rec].data = try std.mem.replaceOwned(u8, a, ms[rec].data, c.from, c.to);
        try t.expect(!std.mem.eql(u8, copy[rec].data, ms[rec].data));
        try t.expectEqualStrings(c.want, try refusal(a, in, try zipOf(a, copy, true)));
    }
    var d = diag.Diag{};
    try t.expectError(error.Refused, check.checkRecord(a, &d, &.{}, record_name));
    try t.expectEqualStrings("record: the last member is not komira-0.1.57.dist-info/RECORD", d.msg);
}

test "tag, requires and metadata: other WHEEL, Requires-Dist or METADATA is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in = try fixture.input(a);
    const ms = try good(a);
    const w = index(ms, "/WHEEL");
    const m = index(ms, "/METADATA");

    const other_tag = try a.dupe(zip.Member, ms);
    other_tag[w].data = try wheel.renderWheel(a, "py3-none-manylinux_2_28_x86_64");
    try t.expectEqualStrings("tag: WHEEL gives the tags py3-none-manylinux_2_28_x86_64, not py3-none-manylinux_2_34_x86_64", try refusal(a, in, try zipOf(a, other_tag, false)));

    const purelib = try a.dupe(zip.Member, ms);
    purelib[w].data = try std.mem.replaceOwned(u8, a, ms[w].data, "Root-Is-Purelib: false", "Root-Is-Purelib: true");
    try t.expect(std.mem.startsWith(u8, try refusal(a, in, try zipOf(a, purelib, false)), "tag: WHEEL is not Wheel-Version 1.0, Root-Is-Purelib false:"));

    const reqs = try a.dupe(zip.Member, ms);
    reqs[m].data = try std.mem.replaceOwned(u8, a, ms[m].data, "mojo-compiler==1.0.0", "mojo-compiler==1.2.0");
    try t.expectEqualStrings("requires: METADATA's Requires-Dist is [pyarrow; mojo-compiler==1.2.0], not [pyarrow; mojo-compiler==1.0.0]", try refusal(a, in, try zipOf(a, reqs, false)));

    const summary = try a.dupe(zip.Member, ms);
    summary[m].data = try std.mem.replaceOwned(u8, a, ms[m].data, "Summary: SQL over local files", "Summary: other");
    try t.expectEqualStrings("metadata: METADATA is not the one the rule's attributes give", try refusal(a, in, try zipOf(a, summary, false)));
}

test "licence, policy and twin: a changed licence, a member the policy refuses, a twin of other bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ms = try good(a);

    const lic = try a.dupe(zip.Member, ms);
    lic[index(ms, "/licenses/NOTICE")].data = "another notice\n";
    try t.expectEqualStrings("licence: komira-0.1.57.dist-info/licenses/NOTICE differs from the licence file given", try refusal(a, try fixture.input(a), try zipOf(a, lic, false)));

    // The input and the wheel agree on a library the policy refuses (as if
    // the writer had not held it): the check refuses it again.
    var in = try fixture.input(a);
    const bad_lib = try fixture.elf(a, .{ .runpath = "/usr/lib" });
    const files = try a.dupe(wheel.File, in.files);
    files[0].data = bad_lib;
    in.files = files;
    const pol = try a.dupe(zip.Member, ms);
    pol[index(ms, "/libkomira.so")].data = bad_lib;
    try t.expectEqualStrings("runpath: komira/_lib/libkomira.so has the run path entry `/usr/lib`, which is not $ORIGIN-relative", try refusal(a, in, try zipOf(a, pol, false)));

    const bytes = try zipOf(a, ms, true);
    const other = try a.dupe(u8, bytes);
    other[other.len - 1] ^= 1;
    var d = diag.Diag{};
    try t.expectError(error.Refused, check.check(a, &d, try fixture.input(a), try stamped(a), name, bytes, true, other));
    try t.expect(std.mem.startsWith(u8, d.msg, "twin: the wheel built twice from the same inputs, staged at two paths, is not the same bytes"));
}

test "a macOS wheel passes, and with a dylib needing a newer macOS than its tag it is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const mac_name = "komira-0.1.57-py3-none-macosx_11_0_arm64.whl";
    const in = try fixture.macosInput(a);
    const bytes = try wheel.build(a, &d, in, try dateOf(a));
    try check.check(a, &d, in, try stamped(a), mac_name, bytes, true, bytes);
    const read = try zip.read(a, &d, bytes);
    const ms = try a.alloc(zip.Member, read.len);
    for (read, ms) |m, *o| o.* = .{ .name = m.name, .data = m.data, .mode = m.mode };
    const w = index(ms, "/WHEEL");
    try t.expectEqualStrings("Wheel-Version: 1.0\nGenerator: komira_wheel\nRoot-Is-Purelib: false\nTag: py3-none-macosx_11_0_arm64\n", ms[w].data);

    // The input still says what the good dylib is; the wheel holds one that
    // needs macOS 13.0, as if the writer had not held it.
    const swapped = try a.dupe(zip.Member, ms);
    swapped[index(ms, "/libkomira.dylib")].data = try fixture.machO(a, .{ .install_name = "@rpath/libkomira.dylib", .minos = fixture.macosVersion(13, 0, 0) });
    var in_new = in;
    const files = try a.dupe(wheel.File, in.files);
    for (files) |*f| {
        if (std.mem.endsWith(u8, f.path, "/libkomira.dylib")) f.data = swapped[index(ms, "/libkomira.dylib")].data;
    }
    in_new.files = files;
    try t.expectError(error.Refused, check.check(a, &d, in_new, try stamped(a), mac_name, try zipOf(a, swapped, false), true, null));
    try t.expectEqualStrings("minos: komira/_lib/libkomira.dylib needs macOS 13.0, newer than the tag's macOS 11.0", d.msg);
}
