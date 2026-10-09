//! The commands' cases (cli.zig): arguments, the layout read back, gzip,
//! `tree`, `image`, `layers` and `check`.

const std = @import("std");
const C = @import("common.zig");
const M = @import("cli.zig");
const I = @import("image.zig");
const J = @import("json.zig");
const sha = @import("sha256.zig");
const F = @import("tar_fixture.zig");
const D = @import("fs_fixture.zig");

const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn strs(want: []const []const u8, got: []const []const u8) !void {
    if (want.len != got.len) {
        std.debug.print("want {d} items, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return error.TestUnexpectedResult;
    }
    for (want, got) |w, g| try eqs(w, g);
}

test "main: the_entrypoint_must_be_exactly_the_one_named" {
    try eqs("entrypoint /bin/sh", try F.ok(M.entrypointFinding(&.{"/bin/sh"}, "/bin/sh")));
    const bad = [_]?[]const []const u8{ &.{"/bin/other"}, &.{"/bin/./sh"}, &.{ "/bin/sh", "-c" }, &.{}, null };
    for (bad) |got| try F.expectFailPrefix(M.entrypointFinding(got, "/bin/sh"), "the config's Entrypoint is not [\"/bin/sh\"]: ");
}

test "main: every_exec_and_file_is_wanted" {
    const w = M.wants("/e", &.{ "a", "b", "c" }, &.{ "x", "y" });
    const want = [_]I.Wanted{ .{ .want = .exec, .path = "/e" }, .{ .want = .exec, .path = "a" }, .{ .want = .exec, .path = "b" }, .{ .want = .exec, .path = "c" }, .{ .want = .file, .path = "x" }, .{ .want = .file, .path = "y" } };
    try std.testing.expectEqual(want.len, w.len);
    for (want, w) |x, y| {
        try std.testing.expectEqual(x.want, y.want);
        try eqs(x.path, y.path);
    }
}

test "main: a_place_splits_at_the_first_equals" {
    const p = try F.ok(M.place("bin/sh=out/a=b", false));
    try eqs("bin/sh", p.path);
    try eqs("out/a=b", p.src);
    try expect(!p.bundle);
    try F.expectFailPrefix(M.place("bin/sh", false), "");
}

fn argv(v: []const []const u8) []const []const u8 {
    var out = C.list([]const u8);
    C.push([]const u8, &out, "komira_oci");
    C.add2([]const u8, &out, v);
    return out.items;
}

fn args(v: []const []const u8) M.Args {
    return M.Args.parse(argv(v)) catch unreachable;
}

fn scratch(name: []const u8) []const u8 {
    return D.scratch("main", name);
}

/// `data` written as a blob of the layout at `dir`; its digest.
fn blob(dir: []const u8, data: []const u8) []const u8 {
    D.mkdirAll(D.path(dir, "blobs/sha256"));
    D.write(D.path(dir, C.fmt("blobs/sha256/{s}", .{sha.hex(data)})), data);
    return sha.digest(data);
}

fn index(dir: []const u8, manifests: []const []const u8) void {
    var ds = C.list([]const u8);
    for (manifests) |m| C.push([]const u8, &ds, C.fmt("{{\"digest\":\"{s}\"}}", .{blob(dir, m)}));
    D.write(D.path(dir, "index.json"), C.fmt("{{\"manifests\":[{s}]}}", .{C.join(ds.items, ",")}));
}

fn manifest(config: []const u8, layers: []const []const u8) []const u8 {
    var ls = C.list([]const u8);
    for (layers) |d| C.push([]const u8, &ls, C.fmt("{{\"digest\":\"{s}\"}}", .{d}));
    return C.fmt("{{\"config\":{{\"digest\":\"{s}\"}},\"layers\":[{s}]}}", .{ config, C.join(ls.items, ",") });
}

const Laid = struct { dir: []const u8, layers: [][]const u8 };

/// A layout of `layers` (uncompressed tars, read without busybox) and a
/// config whose Entrypoint is the JSON `ep`; its directory and the layer
/// digests.
fn layout(name: []const u8, layers: []const []const u8, ep: []const u8) Laid {
    const dir = scratch(name);
    const c = blob(dir, C.fmt("{{\"config\":{{\"Entrypoint\":{s}}}}}", .{ep}));
    var ls = C.list([]const u8);
    for (layers) |l| C.push([]const u8, &ls, blob(dir, l));
    index(dir, &.{manifest(c, ls.items)});
    return .{ .dir = dir, .layers = ls.items };
}

fn baseLayer() []const u8 {
    return F.tar(&[_]F.E{ .{ "etc/", '5', 0o755, "", "" }, .{ "etc/f", '0', 0o644, "x", "" } });
}

fn shLayer(mode: u32) []const u8 {
    return F.tar(&[_]F.E{ .{ "bin/", '5', 0o755, "", "" }, .{ "bin/sh", '0', mode, "sh", "" } });
}

/// bin/sh, mode 0755, spelled `./bin/sh` as many tars do.
fn shLayerDot() []const u8 {
    return F.tar(&[_]F.E{ .{ "./bin/", '5', 0o755, "", "" }, .{ "./bin/sh", '0', 0o755, "sh", "" } });
}

test "main: arguments_are_flag_value_pairs_each_allowed_and_counted" {
    try F.expectFail(M.Args.parse(argv(&.{})), "no command (tree, image, layers, check)");
    try F.expectFail(M.Args.parse(argv(&.{ "check", "--out" })), "--out needs a value");
    var a = args(&.{ "check", "--out", "o", "--x", "1" });
    try F.expectFail(a.allow(&.{"--out"}), "unknown flag --x for check");
    try F.ok(a.allow(&.{ "--out", "--x" }));
    a = args(&.{ "check", "--out", "a", "--out", "b" });
    try F.expectFail(a.opt("--out"), "--out given twice");
    try expect((try F.ok(a.opt("--layout"))) == null);
    try F.expectFail(a.one("--layout"), "missing --layout");
    a = args(&.{ "check", "--exec", "a", "--file", "f", "--exec", "b", "--exec", "c" });
    try strs(&.{ "a", "b", "c" }, a.all("--exec"));
    try eqs("f", try F.ok(a.one("--file")));
    try F.expectFail(M.run(argv(&.{"bogus"})), "unknown command `bogus` (tree, image, layers, check)");
    for ([_][]const u8{ "tree", "image", "layers", "check" }) |cmd| {
        try F.expectFail(M.run(argv(&.{ cmd, "--nope", "x" })), C.fmt("unknown flag --nope for {s}", .{cmd}));
    }
}

fn str(x: []const u8) J.Value {
    return .{ .str = x };
}

test "main: a_digest_is_sha256_and_64_lower_case_hex" {
    const hex = F.rep("0123456789abcdef", 4);
    const good = C.fmt("sha256:{s}", .{hex});
    try eqs(good, try F.ok(M.digest(str(good), "w")));
    try F.expectFail(M.digest(null, "w"), "w: no digest");
    try F.expectFail(M.digest(.{ .num = "1" }, "w"), "w: no digest");
    const upper = std.mem.replaceOwned(u8, C.a(), hex, "a", "A") catch C.oom();
    const g = std.mem.replaceOwned(u8, C.a(), hex, "f", "g") catch C.oom();
    const slash = std.mem.replaceOwned(u8, C.a(), hex, "0", "/") catch C.oom();
    for ([_][]const u8{ hex[0..63], C.fmt("{s}0", .{hex}), upper, g, slash }) |bad| {
        const d = C.fmt("sha256:{s}", .{bad});
        try F.expectFail(M.digest(str(d), "w"), C.fmt("w: `{s}` is not a sha256:<64 hex> digest", .{d}));
    }
    const d = C.fmt("sha512:{s}", .{hex});
    try F.expectFail(M.digest(str(d), "w"), C.fmt("w: `{s}` is not a sha256:<64 hex> digest", .{d}));
}

test "main: image_refuses_an_entrypoint_that_is_not_absolute" {
    for ([_][]const u8{ "/", "bin/sh", "", "x" }) |ep| {
        try F.expectFail(M.imageCmd(args(&.{ "image", "--entrypoint", ep })), C.fmt("entrypoint `{s}` is not an absolute path", .{ep}));
    }
    // An absolute one gets as far as the next flag.
    try F.expectFail(M.imageCmd(args(&.{ "image", "--entrypoint", "/x" })), "missing --name");
}

test "main: tree_names_every_refusal_and_lays_files" {
    try F.expectFail(M.treeCmd(args(&.{ "tree", "--out", "o", "--file", "/abs=src" })), "the tree is refused:\n  file path `/abs` must be a plain relative path");
    try F.expectFail(
        M.treeCmd(args(&.{ "tree", "--out", "o", "--bundle", "b=src", "--file", "a/../b=s" })),
        "the tree is refused:\n  bundle path `b` must be a plain relative path ending in /\n  file path `a/../b` must be a plain relative path",
    );
    try F.expectFail(M.treeCmd(args(&.{ "tree", "--out", "o", "--file", "nosplit" })), "`nosplit` is not <path>=<source>");
    const d = scratch("tree");
    D.write(D.path(d, "src"), "s");
    const out = D.path(d, "out");
    const file = C.fmt("bin/sh={s}", .{D.path(d, "src")});
    try F.ok(M.treeCmd(args(&.{ "tree", "--out", out, "--file", file })));
    try eqs("s", D.read(D.path(out, "bin/sh")));
}

fn outcome(want_code: u8, want_stderr: []const u8, o: M.Outcome) !void {
    try eqs(want_stderr, o.stderr);
    try std.testing.expectEqual(want_code, o.code);
}

// A refusal must exit 1: Buck2 takes an action that exits 0 as done, with a
// `--out` that a late refusal may have left half written.
test "main: a_refusal_exits_one_with_one_line_and_success_exits_zero" {
    try outcome(1, "komira_oci: unknown command `bogus` (tree, image, layers, check)\n", M.outcome(argv(&.{"bogus"})));
    try outcome(1, "komira_oci: the tree is refused:\n  file path `/abs` must be a plain relative path\n", M.outcome(argv(&.{ "tree", "--out", "o", "--file", "/abs=src" })));
    const d = scratch("outcome");
    D.write(D.path(d, "src"), "s");
    const file = C.fmt("bin/sh={s}", .{D.path(d, "src")});
    try outcome(0, "", M.outcome(argv(&.{ "tree", "--out", D.path(d, "out"), "--file", file })));
    try eqs("s", D.read(D.path(d, "out/bin/sh")));
}

// Refused before any command runs, naming the first such argument by its
// index in argv: without the refusal these would be other refusals.
test "main: an_argument_that_is_not_utf8_is_refused_first" {
    try outcome(1, "komira_oci: argument 1 is not UTF-8: \"bogus\\xFF\"\n", M.outcome(argv(&.{"bogus\xff"})));
    try outcome(1, "komira_oci: argument 3 is not UTF-8: \"a\\xFEb\"\n", M.outcome(argv(&.{ "check", "--out", "a\xfeb", "--x", "\xff" })));
}

/// A program standing in for busybox: busybox's own `false` or `true`
/// applet, from this run's PATH (the test runner puts them there).
fn applet(name: []const u8) []const u8 {
    const path = C.posix.getenv("PATH") orelse @panic("no PATH");
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const p = C.pathJoin(dir, name);
        if (C.lstat(p)) |_| return p else |_| {}
    }
    std.debug.panic("no {s} in PATH {s}", .{ name, path });
}

test "main: the_gzip_header_must_be_plain_and_whole" {
    var ok: [18]u8 = undefined;
    @memcpy(ok[0..10], &[_]u8{ 0x1f, 0x8b, 8, 0, 1, 2, 3, 4, 0, 3 });
    @memset(ok[10..], 7);
    var want = ok;
    @memset(want[4..8], 0);
    var copy = ok;
    try std.testing.expectEqualSlices(u8, &want, try F.ok(M.zeroMtime(&copy)));
    var short = ok;
    try F.expectFail(M.zeroMtime(short[0..17]), "gzip -c wrote no plain gzip header: [1f, 8b, 08, 00]");
    var empty = [_]u8{};
    try F.expectFail(M.zeroMtime(&empty), "gzip -c wrote no plain gzip header: []");
    const edits = [_]struct { usize, u8 }{ .{ 0, 0x1e }, .{ 1, 0x8c }, .{ 2, 9 }, .{ 3, 8 } };
    for (edits) |e| {
        var gz = ok;
        gz[e[0]] = e[1];
        try F.expectFailPrefix(M.zeroMtime(&gz), "gzip -c wrote no plain gzip header: ");
    }
    try F.expectFailPrefix(M.gzip(applet("false"), ""), "gzip -c failed");
    try F.expectFail(M.gzip(applet("true"), ""), "gzip -c wrote no plain gzip header: []");
    try F.expectFailPrefix(M.gzip("/nonexistent/busybox", ""), "cannot run /nonexistent/busybox: ");
}

fn openLayout(dir: []const u8, busybox: []const u8) !M.Layout {
    return F.ok(M.Layout.open(dir, busybox));
}

test "main: only_a_gzip_layer_goes_through_busybox" {
    var gz = C.list(u8);
    C.add(&gz, &.{ 0x1f, 0x8b });
    C.add(&gz, baseLayer());
    const l = layout("gunzip", &.{ baseLayer(), gz.items }, "[\"/bin/sh\"]");
    // A plain tar is read as it is: `false` never runs.
    try std.testing.expectEqual(@as(usize, 2), (try F.ok((try openLayout(l.dir, applet("false"))).entries(0))).len);
    try F.expectFailPrefix((try openLayout(l.dir, applet("false"))).entries(1), C.fmt("layer {s}: gzip -dc failed", .{l.layers[1]}));
    try F.expectFail((try openLayout(l.dir, applet("true"))).entries(1), C.fmt("layer {s}: tar: the archive ends without a zero block", .{l.layers[1]}));
    try F.expectFailPrefix((try openLayout(l.dir, "/nonexistent/busybox")).entries(1), "cannot run /nonexistent/busybox: ");
}

fn openErr(dir: []const u8) ![]const u8 {
    return F.failText(M.Layout.open(dir, "unused"));
}

test "main: a_layout_is_one_manifest_of_digests_and_layers" {
    const d = scratch("open_none");
    try expect(C.startsWith(try openErr(d), C.fmt("cannot read {s}: ", .{D.path(d, "index.json")})));
    D.write(D.path(d, "index.json"), "{}");
    try eqs("index.json: no `manifests` array", try openErr(d));
    D.write(D.path(d, "index.json"), "{");
    try expect(C.startsWith(try openErr(d), "index.json: JSON: "));
    index(d, &.{});
    try eqs("index.json names 0 manifests, want 1", try openErr(d));
    const c = blob(d, "{}");
    const l = blob(d, baseLayer());
    index(d, &.{ manifest(c, &.{l}), manifest(c, &.{}) });
    try eqs("index.json names 2 manifests, want 1", try openErr(d));
    D.write(D.path(d, "index.json"), "{\"manifests\":[{\"digest\":\"sha256:../../x\"}]}");
    try eqs("index.json manifest: `sha256:../../x` is not a sha256:<64 hex> digest", try openErr(d));
    index(d, &.{"{"});
    try expect(C.startsWith(try openErr(d), "manifest: JSON: "));
    index(d, &.{manifest("sha256:zz", &.{l})});
    try eqs("manifest config: `sha256:zz` is not a sha256:<64 hex> digest", try openErr(d));
    index(d, &.{C.fmt("{{\"config\":{{\"digest\":\"{s}\"}}}}", .{c})});
    try eqs("manifest: no `layers` array", try openErr(d));
    index(d, &.{manifest(c, &.{})});
    try eqs("the manifest names no layer", try openErr(d));
    index(d, &.{manifest(c, &.{ l, "sha256:x" })});
    try eqs("manifest layer 1: `sha256:x` is not a sha256:<64 hex> digest", try openErr(d));
    const bad = blob(d, "not json");
    index(d, &.{manifest(bad, &.{l})});
    try expect(C.startsWith(try openErr(d), "config: JSON: "));
    index(d, &.{manifest(c, &.{ l, l })});
    _ = try openLayout(d, "unused");
}

fn layersOf(dir: []const u8) C.Fail![]const u8 {
    const out = D.path(dir, "layers.out");
    try M.layers(args(&.{ "layers", "--layout", dir, "--busybox", "unused", "--out", out }));
    return D.read(out);
}

test "main: layers_writes_every_digest_and_wants_the_entrypoint_in_the_last_layer" {
    const l = layout("layers_ok", &.{ baseLayer(), shLayerDot() }, "[\"/bin/sh\"]");
    try eqs(C.fmt("{s}\n{s}\n", .{ l.layers[0], l.layers[1] }), try F.ok(layersOf(l.dir)));
    for ([_][]const u8{ "[\"/\"]", "[\"bin/sh\"]", "[\"/bin/sh\",\"-c\"]", "[]", "\"/bin/sh\"", "[1]" }) |ep| {
        const x = layout("layers_ep", &.{ baseLayer(), shLayer(0o755) }, ep);
        try F.expectFailPrefix(layersOf(x.dir), "the config's Entrypoint is not one absolute path: ");
    }
    const not_there = "entrypoint /bin/sh is not a regular file with mode 0755 in the image's last layer";
    // In the first layer only.
    const first = layout("layers_first", &.{ shLayer(0o755), baseLayer() }, "[\"/bin/sh\"]");
    try F.expectFail(layersOf(first.dir), not_there);
    const lasts = [_]struct { []const u8, []const u8 }{
        .{ "layers_644", shLayer(0o644) },
        .{ "layers_4755", shLayer(0o4755) },
        .{ "layers_dir", F.tar(&[_]F.E{ .{ "bin/", '5', 0o755, "", "" }, .{ "bin/sh/", '5', 0o755, "", "" } }) },
        .{ "layers_link", F.tar(&[_]F.E{ .{ "bin/", '5', 0o755, "", "" }, .{ "bin/sh", '2', 0o755, "", "busybox" } }) },
    };
    for (lasts) |c| {
        const x = layout(c[0], &.{ baseLayer(), c[1] }, "[\"/bin/sh\"]");
        try F.expectFail(layersOf(x.dir), not_there);
    }
}

const Checked = struct { r: C.Fail!void, out: ?[]const u8 };

/// `check` of the layout at `d` with the layer list `list` and the
/// arguments `more`: its result and what it wrote.
fn checkOf(d: []const u8, list: []const []const u8, more: []const []const u8) Checked {
    const lf = D.path(d, "list");
    var text = C.list(u8);
    for (list) |l| C.add(&text, C.fmt("{s}\n", .{l}));
    D.write(lf, text.items);
    const out = D.path(d, "check.out");
    std.fs.cwd().deleteFile(out) catch {};
    var v = C.list([]const u8);
    C.add2([]const u8, &v, &.{ "check", "--layout", d, "--busybox", "unused", "--layers", lf, "--out", out });
    C.add2([]const u8, &v, more);
    const r = M.check(args(v.items));
    const msg = C.msg;
    const wrote: ?[]const u8 = C.readFile(out) catch null;
    C.msg = msg;
    return .{ .r = r, .out = wrote };
}

test "main: check_is_green_only_with_no_failure" {
    const l = layout("check_ok", &.{ baseLayer(), shLayer(0o755) }, "[\"/bin/sh\"]");
    const ep = [_][]const u8{ "--entrypoint", "/bin/sh", "--file", "etc/f" };
    const green = checkOf(l.dir, l.layers, &ep);
    try F.ok(green.r);
    try eqs("entrypoint /bin/sh\nlayers 2\nok exec /bin/sh -> bin/sh\nok file etc/f -> etc/f\n", green.out.?);
    // The layer list short of its last digest, and reversed.
    const order = "the layer list is not the manifest's layers in order";
    for ([_][]const []const u8{ &.{l.layers[0]}, &.{ l.layers[1], l.layers[0] } }) |list| {
        const c = checkOf(l.dir, list, &ep);
        try F.expectFailContains(c.r, order);
        try expect(c.out == null);
    }
    // Red without --expect-red: the layout, then each failure.
    const red = checkOf(l.dir, l.layers, &.{ "--entrypoint", "/bin/other", "--file", "etc/nope" });
    try F.expectFail(red.r, C.fmt("{s}:\n  the config's Entrypoint is not [\"/bin/other\"]: Some([\"/bin/sh\"])\n  exec /bin/other: not in the image\n  file etc/nope: not in the image", .{l.dir}));
}

test "main: only_the_last_layer_may_not_change_a_type" {
    const to_dir = F.tar(&[_]F.E{.{ "etc/f/", '5', 0o755, "", "" }});
    const l = layout("type_last", &.{ baseLayer(), shLayer(0o755), to_dir }, "[\"/bin/sh\"]");
    try F.expectFail(checkOf(l.dir, l.layers, &.{ "--entrypoint", "/bin/sh" }).r, C.fmt("{s}:\n  the last layer turns etc/f from type - into type d", .{l.dir}));
    // The same change in a layer below the last is how layers work.
    const mid = layout("type_mid", &.{ baseLayer(), to_dir, shLayer(0o755) }, "[\"/bin/sh\"]");
    try F.ok(checkOf(mid.dir, mid.layers, &.{ "--entrypoint", "/bin/sh" }).r);
    // A layer that cannot be applied is red, naming it.
    const wh = F.tar(&[_]F.E{.{ "etc/.wh.", '0', 0o644, "", "" }});
    const w = layout("type_wh", &.{ baseLayer(), wh }, "[\"/bin/sh\"]");
    try F.expectFail(checkOf(w.dir, w.layers, &.{ "--entrypoint", "/bin/sh" }).r, C.fmt("{s}:\n  layer {s}: a whiteout `etc/.wh.` names no entry", .{ w.dir, w.layers[1] }));
}

fn with(l: anytype, base: []const []const u8, t: []const u8) Checked {
    var v = C.list([]const u8);
    C.add2([]const u8, &v, base);
    C.add2([]const u8, &v, &.{ "--expect-red", t });
    return checkOf(l.dir, l.layers, v.items);
}

test "main: expect_red_writes_only_when_a_failure_names_the_text" {
    const l = layout("expect", &.{ baseLayer(), shLayer(0o755) }, "[\"/bin/sh\"]");
    const green = [_][]const u8{ "--entrypoint", "/bin/sh" };
    const red = [_][]const u8{ "--entrypoint", "/bin/other", "--file", "etc/nope" };
    var c = with(l, &green, "x");
    try F.expectFail(c.r, "green, want red naming `x`");
    try expect(c.out == null);
    c = with(l, &red, "");
    try F.expectFail(c.r, "--expect-red is empty");
    try expect(c.out == null);
    c = with(l, &green, "");
    try F.expectFail(c.r, "--expect-red is empty");
    try expect(c.out == null);
    // The text names the second failure, not the first.
    c = with(l, &red, "file etc/nope");
    try F.ok(c.r);
    try expect(C.startsWith(c.out.?, "red as expected, naming `file etc/nope`:\n  the config's Entrypoint"));
    c = with(l, &red, "nothing like this");
    try F.expectFailPrefix(c.r, "red, but no failure names `nothing like this`:\n  the config's Entrypoint");
    try expect(c.out == null);
    var twice = C.list([]const u8);
    C.add2([]const u8, &twice, &red);
    C.add2([]const u8, &twice, &.{ "--expect-red", "a", "--expect-red", "b" });
    try F.expectFail(checkOf(l.dir, l.layers, twice.items).r, "--expect-red given twice");
    // A layout that cannot be read is red too.
    const gone = D.path(l.dir, "gone");
    const out = D.path(l.dir, "gone.out");
    const v = [_][]const u8{ "check", "--layout", gone, "--busybox", "unused", "--layers", "nolist", "--out", out, "--entrypoint", "/bin/sh" };
    var e = C.list([]const u8);
    C.add2([]const u8, &e, &v);
    C.add2([]const u8, &e, &.{ "--expect-red", "cannot read" });
    try F.ok(M.check(args(e.items)));
    try F.expectFailPrefix(M.check(args(&v)), C.fmt("{s}:\n  cannot read ", .{gone}));
}
