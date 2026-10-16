//! Unit tests of pkg_act's pure parts and of its checks over real files in a
//! temporary directory. Its process behaviour (the command line, exit status,
//! the guard re-run as its own process) is tests//functional/pkg_act.
const std = @import("std");
const U = @import("act_util");
const kcov = @import("kcov_guard.zig");
const release = @import("release.zig");
const bundle = @import("bundle.zig");
const misc = @import("misc.zig");
const t = std.testing;

const marker = "Usage: kcov [OPTIONS] out-dir in-file [args...]";

fn tmpPath(a: std.mem.Allocator, tmp: *std.testing.TmpDir, rel: []const u8) ![]u8 {
    const root = try tmp.dir.realpathAlloc(a, ".");
    return std.fs.path.join(a, &.{ root, rel });
}

fn put(tmp: *std.testing.TmpDir, rel: []const u8, data: []const u8) !void {
    try U.makeParent(tmp.dir, rel);
    try U.writeAll(tmp.dir, rel, data);
}

// ---- kcov guard ------------------------------------------------------------

test "kcov argsOk: a malformed sha256 and an empty or multi-line usage line are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = kcov.fixture_sha256;
    var out = U.Out.init(a);
    try kcov.argsOk(&out, "guard", .{ .ksum = good, .marker = marker });
    try t.expectEqual(@as(usize, 0), out.items.len);
    const bad = [_]kcov.Identity{
        .{ .ksum = good[0..63], .marker = marker },
        .{ .ksum = good ++ "0", .marker = marker },
        .{ .ksum = "177F9E3E45D0314EC5A7001DF49C20A2F2CA26C5AC681AA5A89E387C4B64854B", .marker = marker },
        .{ .ksum = "", .marker = marker },
        .{ .ksum = good, .marker = "" },
        .{ .ksum = good, .marker = "a\nb" },
    };
    for (bad) |b| {
        var o = U.Out.init(a);
        try t.expectError(error.Refused, kcov.argsOk(&o, "guard", b));
        try t.expect(std.mem.startsWith(u8, o.items, "kcov_guard guard: "));
    }
}

test "kcov judge: by sha256, by the line anywhere (NUL bytes included), and not by near misses" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = kcov.Identity{ .ksum = kcov.fixture_sha256, .marker = marker };
    const by_sha = (try kcov.judge(a, id, "lib/x.so", kcov.fixture_text)).?;
    try t.expectEqualStrings("  lib/x.so is kcov's bin/kcov (sha256 " ++ kcov.fixture_sha256 ++ ")\n", by_sha);
    const embedded = try std.fmt.allocPrint(a, "ELF\x00\x01{s}\x00tail", .{marker});
    const by_line = (try kcov.judge(a, id, "share/b", embedded)).?;
    try t.expect(std.mem.startsWith(u8, by_line, "  share/b holds kcov's usage line '" ++ marker ++ "'"));
    const near = [_][]const u8{
        "Usage: kcov [OPTIONS] out-dir in-file [args..]\n",
        "usage: kcov [OPTIONS] out-dir in-file [args...]\n",
        "Usage: kcov [OPTIONS] out-dir\x00in-file [args...]\n",
        "Usage: kcov [OPTIONS] out-dir\nin-file [args...]\n",
        kcov.fixture_text ++ "x",
        "",
    };
    for (near) |n| try t.expect((try kcov.judge(a, id, "n", n)) == null);
}

fn guardText(a: std.mem.Allocator, id: kcov.Identity, pairs: []const kcov.Pair) !struct { refused: bool, text: []const u8 } {
    var out = U.Out.init(a);
    kcov.guard(a, &out, "guard", id, "//x:y", pairs) catch |e| switch (e) {
        error.Refused => return .{ .refused = true, .text = out.items },
        else => return e,
    };
    return .{ .refused = false, .text = out.items };
}

test "kcov guard: files, directories, links, destinations, and every offender named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(&tmp, "copy/lib/libcopy.so", kcov.fixture_text);
    try put(&tmp, "embed/share/blob.bin", "x\x00" ++ marker ++ "\x00y");
    try put(&tmp, "clean/a.txt", "fine");
    const copy = try tmpPath(a, &tmp, "copy");
    const embed = try tmpPath(a, &tmp, "embed");
    const clean = try tmpPath(a, &tmp, "clean");
    try tmp.dir.symLink(copy, "clean/dir", .{});
    const id = kcov.Identity{ .ksum = kcov.fixture_sha256, .marker = marker };

    // A clean directory with no link is accepted and prints nothing.
    try tmp.dir.makePath("plain");
    try put(&tmp, "plain/a.txt", "fine");
    const ok = try guardText(a, id, &.{.{ .dest = ".", .path = try tmpPath(a, &tmp, "plain") }});
    try t.expect(!ok.refused);
    try t.expectEqual(@as(usize, 0), ok.text.len);

    // Nothing to check is accepted.
    try t.expect(!(try guardText(a, id, &.{})).refused);

    // A file under a destination path, a directory under one, and the root.
    const r1 = try guardText(a, id, &.{.{ .dest = "lib/mojo/x.mojoc", .path = try tmpPath(a, &tmp, "copy/lib/libcopy.so") }});
    try t.expect(r1.refused);
    try t.expect(U.contains(r1.text, "  lib/mojo/x.mojoc is kcov's bin/kcov (sha256 " ++ kcov.fixture_sha256 ++ ")\n"));
    const r2 = try guardText(a, id, &.{.{ .dest = "opt/x", .path = copy }});
    try t.expect(U.contains(r2.text, "  opt/x/lib/libcopy.so is kcov's"));
    const r3 = try guardText(a, id, &.{.{ .dest = ".", .path = copy }});
    try t.expect(U.contains(r3.text, "  lib/libcopy.so is kcov's"));
    try t.expect(std.mem.startsWith(u8, r3.text, "//x:y packs kcov, a build-only tool: kcov is GPL-2.0"));

    // Both offenders, across arguments, in the order given.
    const r4 = try guardText(a, id, &.{ .{ .dest = ".", .path = copy }, .{ .dest = ".", .path = embed } });
    const first = std.mem.indexOf(u8, r4.text, "  lib/libcopy.so ").?;
    const second = std.mem.indexOf(u8, r4.text, "  share/blob.bin ").?;
    try t.expect(first < second);

    // A link to a directory is followed: the file is named under the link's name.
    const r5 = try guardText(a, id, &.{.{ .dest = ".", .path = clean }});
    try t.expect(r5.refused);
    try t.expect(U.contains(r5.text, "  dir/lib/libcopy.so is kcov's"));

    // A path that is neither is refused, naming it.
    const r6 = try guardText(a, id, &.{.{ .dest = "d", .path = try tmpPath(a, &tmp, "missing") }});
    try t.expect(r6.refused);
    try t.expect(U.contains(r6.text, "is neither a file nor a directory"));
}

// ---- release set ------------------------------------------------------------

test "release withoutMembers: the metapackage's rows go, the top level stays" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const j = "{\"build\":\"h1_9\",\"members\":[{\"build\":\"zz\",\"version\":\"1\"}],\"stamped\":true}\n";
    const top = try release.withoutMembers(a, j);
    try t.expectEqualStrings("{\"build\":\"h1_9\",\"stamped\":true}\n", top);
    // The member's own `build` is not the top level's.
    try t.expect(!try release.has(a, "\"build\":\"zz\"", top));
    try t.expect(try release.has(a, "\"build\":\"h1_9\"", top));
    // No members: unchanged. An unclosed row on a line: unchanged.
    try t.expectEqualStrings("{\"a\":1}", try release.withoutMembers(a, "{\"a\":1}"));
    try t.expectEqualStrings("{\"members\":[1", try release.withoutMembers(a, "{\"members\":[1"));
}

test "release has: a whole value, followed by a comma or a brace" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(try release.has(a, "\"k\":1", "{\"k\":1,\"z\":2}"));
    try t.expect(try release.has(a, "\"k\":1", "{\"z\":2,\"k\":1}"));
    try t.expect(!try release.has(a, "\"k\":1", "{\"k\":12}"));
}

const stamp_meta = "{\"build\":\"h7e57c0de_999999999\",\"build_number\":999999999,\"source_commit\":\"c0ffee\",\"stamped\":true,\"timestamp_ms\":1000}";

fn stampFixture(tmp: *std.testing.TmpDir, name: []const u8, dir: []const u8, requires: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const conda = try std.fmt.allocPrint(a, "{s}/{s}-1.2.3-h7e57c0de_999999999.conda", .{ dir, name });
    try put(tmp, conda, "pkg");
    const manifest = try std.fmt.allocPrint(a, "{s}/manifest.json", .{dir});
    const mtext = try std.fmt.allocPrint(a, "{{\"file\":\"{s}-1.2.3-h7e57c0de_999999999.conda\",\"version\":\"1.2.3\"}}", .{name});
    try put(tmp, manifest, mtext);
    var depends = std.ArrayList(u8).init(a);
    for (requires) |r| try depends.writer().print("\"{s} ==1.2.3 h7e57c0de_999999999\",", .{r});
    const meta = try std.fmt.allocPrint(a, "{{\"depends\":[{s}],{s}}}", .{ depends.items, stamp_meta[1 .. stamp_meta.len - 1] });
    try put(tmp, try std.fmt.allocPrint(a, "{s}/metadata.json", .{dir}), meta);
}

test "release stampCheck: green over a release set, then each refusal" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try stampFixture(&tmp, "komira_a", "ma", &.{});
    try stampFixture(&tmp, "komira_b", "mb", &.{});
    try stampFixture(&tmp, "komira", "meta", &.{ "komira_a", "komira_b" });
    // the metapackage's own metadata names its members' rows too; the
    // fixture's top level carries the stamp.
    try put(&tmp, "set.txt", "# comment\n\nmetapackage komira\nmember komira_a\nmember komira_b\nlicense Apache-2.0\nsummary Every library.\nhome https://example.test/komira");
    const base = release.Stamp{
        .version = "1.2.3",
        .build_number = "999999999",
        .commit = "c0ffee",
        .timestamp_ms = "1000",
        .build = "h7e57c0de_999999999",
        .meta = "komira",
        .meta_dir = try tmpPath(a, &tmp, "meta"),
        .set = try tmpPath(a, &tmp, "set.txt"),
        .license = "Apache-2.0",
        .summary = "Every library.",
        .home = "https://example.test/komira",
        .members = &.{
            .{ .name = "komira_a", .path = try tmpPath(a, &tmp, "ma") },
            .{ .name = "komira_b", .path = try tmpPath(a, &tmp, "mb") },
        },
    };
    var out = U.Out.init(a);
    const text = try release.stampCheck(a, &out, base);
    try t.expectEqualStrings("stamped 1.2.3 h7e57c0de_999999999: komira_a komira_b\n", text);

    const Case = struct { mutate: *const fn (*release.Stamp) void, want: []const u8 };
    const cases = [_]Case{
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.meta = "other"; } }.f, .want = "names the metapackage 'komira', this target makes 'other'" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.license = "MIT"; } }.f, .want = "license is 'Apache-2.0', conda-meta is given 'MIT'" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.summary = "x"; } }.f, .want = "summary is 'Every library.', conda-meta is given 'x'" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.home = "x"; } }.f, .want = "home is 'https://example.test/komira', conda-meta is given 'x'" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.version = "9.9.9"; } }.f, .want = "holds no komira_a-9.9.9-h7e57c0de_999999999.conda" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.commit = "dead"; } }.f, .want = "metadata.json does not carry \"source_commit\":\"dead\" of the test stamp" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.timestamp_ms = "1001"; } }.f, .want = "metadata.json does not carry \"timestamp_ms\":1001" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.build_number = "5"; } }.f, .want = "metadata.json does not carry \"build_number\":5" },
        .{ .mutate = struct { fn f(s: *release.Stamp) void { s.members = s.members[0..1]; } }.f, .want = "libs are [ komira_a ], " },
    };
    for (cases) |c| {
        var s = base;
        c.mutate(&s);
        var o = U.Out.init(a);
        try t.expectError(error.Refused, release.stampCheck(a, &o, s));
        try t.expect(std.mem.startsWith(u8, o.items, "conda_release_set_check: "));
        if (!U.contains(o.items, c.want)) {
            std.debug.print("want [{s}] in [{s}]\n", .{ c.want, o.items });
            return error.TestUnexpectedResult;
        }
    }
}

test "release stampCheck: an unknown key in the release set, and a metapackage that misses a member" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try stampFixture(&tmp, "komira_a", "ma", &.{});
    try stampFixture(&tmp, "komira", "meta", &.{});
    try put(&tmp, "bad.txt", "metapackage komira\nbogus 1\n");
    try put(&tmp, "set.txt", "metapackage komira\nmember komira_a\nlicense L\nsummary S\nhome H\n");
    var s = release.Stamp{
        .version = "1.2.3",
        .build_number = "999999999",
        .commit = "c0ffee",
        .timestamp_ms = "1000",
        .build = "h7e57c0de_999999999",
        .meta = "komira",
        .meta_dir = try tmpPath(a, &tmp, "meta"),
        .set = try tmpPath(a, &tmp, "bad.txt"),
        .license = "L",
        .summary = "S",
        .home = "H",
        .members = &.{.{ .name = "komira_a", .path = try tmpPath(a, &tmp, "ma") }},
    };
    var o = U.Out.init(a);
    try t.expectError(error.Refused, release.stampCheck(a, &o, s));
    try t.expect(U.contains(o.items, "bad.txt: unknown key 'bogus'"));
    s.set = try tmpPath(a, &tmp, "set.txt");
    var o2 = U.Out.init(a);
    try t.expectError(error.Refused, release.stampCheck(a, &o2, s));
    try t.expect(U.contains(o2.items, "metapackage komira does not require member komira_a at 1.2.3 h7e57c0de_999999999"));
}

test "release orderCheck: a member that requires one listed after it is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(&tmp, "a.json", "{\"depends\":[\"b ==1 B\"]}");
    try put(&tmp, "b.json", "{\"depends\":[\"a ==1 B\"]}");
    try put(&tmp, "c.json", "{\"depends\":[\"a ==2 B\"]}");
    const pa = try tmpPath(a, &tmp, "a.json");
    const pb = try tmpPath(a, &tmp, "b.json");
    const pc = try tmpPath(a, &tmp, "c.json");
    var out = U.Out.init(a);
    // b requires a, listed before it: in order.
    const ok = try release.orderCheck(a, &out, "set", "1", "B", &.{ .{ .name = "a", .path = pc }, .{ .name = "b", .path = pb } });
    try t.expectEqualStrings("in order: a b\n", ok);
    // a requires b, listed after it: refused with one line.
    try t.expectError(error.Refused, release.orderCheck(a, &out, "the.txt", "1", "B", &.{ .{ .name = "a", .path = pa }, .{ .name = "b", .path = pb } }));
    try t.expectEqualStrings("conda_release_set_check: member a requires b, which the.txt lists after it: list each member after the members it requires (here, in release/artifacts.textproto and in libs)\n", out.items);
}

test "release judgeOrderRun: passing with no stderr, or one refusal line containing the text" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try release.judgeOrderRun(a, 0, "", "")) == null);
    try t.expect((try release.judgeOrderRun(a, 0, "noise\n", "")) != null);
    try t.expect((try release.judgeOrderRun(a, 0, "", "x")) != null);
    try t.expect((try release.judgeOrderRun(a, 1, "bad thing\n", "")) != null);
    try t.expect((try release.judgeOrderRun(a, 1, "a bad thing\n", "bad")) == null);
    try t.expect((try release.judgeOrderRun(a, 1, "a thing\n", "bad")) != null);
    try t.expect((try release.judgeOrderRun(a, 1, "bad\nbad\n", "bad")) != null);
    try t.expect((try release.judgeOrderRun(a, 1, "bad", "bad")) != null);
}

// ---- bundle ----------------------------------------------------------------

test "bundle assemble: layout, modes, and SHA256SUMS of every other file in byte order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(&tmp, "in/launcher", "L");
    try put(&tmp, "in/prog.so", "S");
    try put(&tmp, "in/rt/libone.so", "1");
    try put(&tmp, "in/rt/libtwo.so", "2");
    try put(&tmp, "in/VERSION", "name=x\n");
    try put(&tmp, "in/data.txt", "D");
    try put(&tmp, "in/helper", "H");
    const r = struct {
        fn p(aa: std.mem.Allocator, tt: *std.testing.TmpDir, rel: []const u8) []const u8 {
            return tmpPath(aa, tt, rel) catch unreachable;
        }
    };
    const out_path = r.p(a, &tmp, "o");
    try bundle.assemble(a, .{
        .out = out_path,
        .name = "prog",
        .cpu = "x86-64-v3",
        .launcher = r.p(a, &tmp, "in/launcher"),
        .so = r.p(a, &tmp, "in/prog.so"),
        .runtime = r.p(a, &tmp, "in/rt"),
        .version = r.p(a, &tmp, "in/VERSION"),
        .files = &.{ .{ "share/doc/d.txt", r.p(a, &tmp, "in/data.txt") }, .{ "bin/helper", r.p(a, &tmp, "in/helper") } },
    });
    const sums = try tmp.dir.readFileAlloc(a, "o/SHA256SUMS", 1 << 20);
    var expect = std.ArrayList(u8).init(a);
    const names = [_][]const u8{ "VERSION", "bin/helper", "bin/prog", "lib/glibc-hwcaps/x86-64-v3/libprog.so", "lib/libone.so", "lib/libtwo.so", "share/doc/d.txt" };
    for (names) |n| {
        const data = try tmp.dir.readFileAlloc(a, try std.fmt.allocPrint(a, "o/{s}", .{n}), 1 << 20);
        try expect.writer().print("{s}  {s}\n", .{ &U.sha256Hex(data), n });
    }
    try t.expectEqualStrings(expect.items, sums);
    const modes = [_]struct { p: []const u8, m: std.fs.File.Mode }{
        .{ .p = "o", .m = 0o755 },
        .{ .p = "o/bin", .m = 0o755 },
        .{ .p = "o/bin/prog", .m = 0o755 },
        .{ .p = "o/bin/helper", .m = 0o755 },
        .{ .p = "o/lib/libone.so", .m = 0o644 },
        .{ .p = "o/share/doc/d.txt", .m = 0o644 },
        .{ .p = "o/VERSION", .m = 0o644 },
        .{ .p = "o/SHA256SUMS", .m = 0o644 },
        .{ .p = "o/share/doc", .m = 0o755 },
    };
    for (modes) |m| try t.expectEqual(m.m, (try tmp.dir.statFile(m.p)).mode & 0o777);
}

test "bundle assemble: a directory in the runtime is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(&tmp, "in/launcher", "L");
    try put(&tmp, "in/prog.so", "S");
    try put(&tmp, "in/rt/sub/x", "1");
    try put(&tmp, "in/VERSION", "v");
    try t.expectError(error.RuntimeHoldsDirectory, bundle.assemble(a, .{
        .out = try tmpPath(a, &tmp, "o"),
        .name = "p",
        .cpu = "c",
        .launcher = try tmpPath(a, &tmp, "in/launcher"),
        .so = try tmpPath(a, &tmp, "in/prog.so"),
        .runtime = try tmpPath(a, &tmp, "in/rt"),
        .version = try tmpPath(a, &tmp, "in/VERSION"),
        .files = &.{},
    }));
}

// ---- misc ------------------------------------------------------------------

const hex64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn oci(digest: []const u8, name: []const u8) misc.OciManifest {
    return .{ .digest_path = "d.txt", .digest = digest, .name = name, .version = "1.0", .platform = "linux-x86_64", .file = "img", .label = "//p:i", .repo = "komira/x", .from = "the bundle's program" };
}

test "oci manifest: the bytes kci's writer renders, and each refusal in words" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = U.Out.init(a);
    const text = try misc.ociManifest(a, &out, oci("sha256:" ++ hex64 ++ "\n", "hello_app"));
    try t.expectEqualStrings("{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"OCI\",\"name\":\"hello_app\",\"version\":\"1.0\",\"platform\":\"linux-x86_64\",\"file\":\"img\",\"sha256\":\"" ++ hex64 ++ "\"}\n", text);
    const Bad = struct { digest: []const u8, name: []const u8, want: []const u8 };
    const bad = [_]Bad{
        .{ .digest = hex64, .name = "a", .want = "d.txt holds '" ++ hex64 ++ "', not sha256:<64 hex>" },
        .{ .digest = "sha256:abc", .name = "a", .want = "not sha256:<64 hex>" },
        .{ .digest = "sha256:" ++ "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef", .name = "a", .want = "not sha256:<64 lowercase hex>" },
        .{ .digest = "sha256:" ++ hex64, .name = "Hello", .want = "member name 'Hello' (the bundle's program) is not a kci artifact name ([a-z][a-z0-9_]*)" },
        .{ .digest = "sha256:" ++ hex64, .name = "oci-check", .want = "is not a kci artifact name" },
        .{ .digest = "sha256:" ++ hex64, .name = "1a", .want = "is not a kci artifact name" },
        .{ .digest = "sha256:" ++ hex64, .name = "", .want = "is not a kci artifact name" },
    };
    for (bad) |b| {
        var o = U.Out.init(a);
        try t.expectError(error.Refused, misc.ociManifest(a, &o, oci(b.digest, b.name)));
        try t.expect(std.mem.startsWith(u8, o.items, "oci_image[release] of //p:i (repository komira/x): "));
        try t.expect(U.contains(o.items, b.want));
    }
}

test "kciLineOk and stripDir" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "OK CONDA komira_hash 1.0 metadata=metadata.json metadata_path=/w/d/metadata.json render-identical=yes";
    try t.expect(try misc.kciLineOk(a, line, "/w/d"));
    try t.expect(!try misc.kciLineOk(a, line, "/w/e"));
    try t.expect(!try misc.kciLineOk(a, "NOT " ++ line[3..], "/w/d"));
    try t.expect(!try misc.kciLineOk(a, line[0 .. line.len - 1], "/w/d"));
    try t.expectEqualStrings("OK CONDA komira_hash 1.0 metadata=metadata.json metadata_path=metadata.json render-identical=yes", try misc.stripDir(a, line, "/w/d"));
    try t.expectEqualStrings("x\ny", try misc.stripDir(a, "x\ny", "/w/d"));
}

test "condaDirListing: exactly one .conda, manifest.json and a non-empty metadata.json" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(&tmp, "ok/p.conda", "x");
    try put(&tmp, "ok/manifest.json", "{}");
    try put(&tmp, "ok/metadata.json", "{}");
    try put(&tmp, "extra/p.conda", "x");
    try put(&tmp, "extra/manifest.json", "{}");
    try put(&tmp, "extra/metadata.json", "{}");
    try put(&tmp, "extra/notes", "x");
    try put(&tmp, "empty/p.conda", "x");
    try put(&tmp, "empty/manifest.json", "{}");
    try put(&tmp, "empty/metadata.json", "");
    try put(&tmp, "two/a.conda", "x");
    try put(&tmp, "two/b.conda", "x");
    try put(&tmp, "two/manifest.json", "{}");
    try t.expect((try misc.condaDirListing(a, try tmpPath(a, &tmp, "ok"))) == null);
    try t.expectEqualStrings("manifest.json metadata.json notes p.conda ", (try misc.condaDirListing(a, try tmpPath(a, &tmp, "extra"))).?);
    try t.expect((try misc.condaDirListing(a, try tmpPath(a, &tmp, "empty"))) != null);
    try t.expect((try misc.condaDirListing(a, try tmpPath(a, &tmp, "two"))) != null);
}
