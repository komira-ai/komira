//! The process behaviour of `pkg_act` (tools/build/package/act): every
//! subcommand over real files and a stand-in child, by exit status, stderr and
//! the bytes written. Each case says the defect it would catch.
const std = @import("std");
const kit = @import("driver_kit");
const t = std.testing;
const has = kit.has;

const marker = "Usage: kcov [OPTIONS] out-dir in-file [args...]";
const hex64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn sha(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "PKG_ACT");
}

// ---- kcov-guard -------------------------------------------------------------

test "kcov-guard guard: accepts a clean tree, and writes <out> only then" {
    var c = try newCtx("guard_ok");
    defer c.deinit();
    const ksum = sha("the stand-in for bin/kcov\n");
    try c.write("tree/lib/a.so", "fine", 0o644);
    try c.write("tree/share/b.txt", "Usage: kcov [OPTIONS] out-dir\nin-file [args...]\n", 0o644);
    const r = try c.run(&.{ "kcov-guard", "guard", &ksum, marker, "out.ok", "//p:t", ".", "tree" }, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("ok\n", try c.read("out.ok"));
    try t.expectEqualStrings("", r.stderr);
}

test "kcov-guard guard: refuses by sha256 and by the usage line, naming each file; <out> is not written" {
    var c = try newCtx("guard_refuse");
    defer c.deinit();
    const body = "the stand-in for bin/kcov\n";
    const ksum = sha(body);
    try c.write("tree/lib/k.so", body, 0o644);
    try c.write("tree/share/blob.bin", "ELF\x00" ++ marker ++ "\x00tail", 0o644);
    try c.write("tree/fine.txt", "fine", 0o644);
    const r = try c.run(&.{ "kcov-guard", "guard", &ksum, marker, "out.ok", "//p:t", "opt/x", "tree" }, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(!c.exists("out.ok"));
    try t.expect(has(r.stderr, "//p:t packs kcov, a build-only tool"));
    const named = try std.fmt.allocPrint(c.alloc(), "  opt/x/lib/k.so is kcov's bin/kcov (sha256 {s})", .{&ksum});
    try t.expect(has(r.stderr, named));
    try t.expect(has(r.stderr, "  opt/x/share/blob.bin holds kcov's usage line '" ++ marker ++ "'"));
    try t.expect(!has(r.stderr, "fine.txt"));
}

test "kcov-guard guard: the sha256 and the line come from their positions; a malformed pin, a missing <what>, an odd pair, a missing path" {
    var c = try newCtx("guard_args");
    defer c.deinit();
    const ksum = sha("x");
    try c.write("tree/a", "a", 0o644);
    // Swapped positions are refused by the form check, not read as constants.
    const r1 = try c.run(&.{ "kcov-guard", "guard", marker, &ksum, "o", "w", ".", "tree" }, &.{});
    try t.expectEqual(@as(u8, 1), r1.code);
    try t.expect(has(r1.stderr, "is not 64 lowercase hex digits"));
    const r2 = try c.run(&.{ "kcov-guard", "guard", ksum[0..63], marker, "o", "w" }, &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    const r3 = try c.run(&.{ "kcov-guard", "guard", &ksum, "", "o", "w" }, &.{});
    try t.expectEqual(@as(u8, 1), r3.code);
    try t.expect(has(r3.stderr, "usage line is empty"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "kcov-guard", "guard", &ksum, marker, "o" }, &.{})).code);
    const r4 = try c.run(&.{ "kcov-guard", "guard", &ksum, marker, "o", "w", "dest-only" }, &.{});
    try t.expectEqual(@as(u8, 1), r4.code);
    try t.expect(has(r4.stderr, "<dest> dest-only has no <path>"));
    const r5 = try c.run(&.{ "kcov-guard", "guard", &ksum, marker, "o", "w", "d", "missing" }, &.{});
    try t.expectEqual(@as(u8, 1), r5.code);
    try t.expect(has(r5.stderr, "is neither a file nor a directory"));
    try t.expect(!c.exists("o"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"kcov-guard"}, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "kcov-guard", "bogus" }, &.{})).code);
}

test "kcov-guard cases: the 15 cases pass and the report is byte-exact; the scratch directory is gone" {
    var c = try newCtx("cases_ok");
    defer c.deinit();
    const scratch = try c.path("scratch");
    const r = try c.run(&.{ "kcov-guard", "cases", hex64, marker, "report" }, &.{.{ "BUCK_SCRATCH_PATH", scratch }});
    if (r.code != 0) std.debug.print("[pkg_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"kcov_guard cases: 15 cases passed\"}}\n", try c.read("report/validation.json"));
    try t.expect(!c.exists("scratch/komira/kcov_guard_cases"));
}

test "kcov-guard cases: red when the usage line is in the fixture (the sha256 cases would show nothing), and on a malformed pin" {
    var c = try newCtx("cases_red");
    defer c.deinit();
    const r = try c.run(&.{ "kcov-guard", "cases", hex64, "this file stands for bin/kcov", "report" }, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.stderr, "kcov_guard cases: RED: the fixture holds the usage line"));
    try t.expect(!c.exists("report/validation.json"));
    const r2 = try c.run(&.{ "kcov-guard", "cases", hex64[0..10], marker, "report2" }, &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(has(r2.stderr, "RED: the pinned constants"));
    try t.expect(!c.exists("report2/validation.json"));
}

// ---- bundle -----------------------------------------------------------------

fn bundleArgs(c: *kit.Ctx, out: []const u8, runtime: []const u8) ![]const []const u8 {
    const al = c.alloc();
    return al.dupe([]const u8, &.{
        "bundle",
        "--out",
        out,
        "--name",
        "prog",
        "--cpu",
        "x86-64-v3",
        "--launcher",
        "in/launcher",
        "--so",
        "in/prog.so",
        "--runtime",
        runtime,
        "--version",
        "in/VERSION",
        "--file",
        "share/doc/d.txt",
        "in/data.txt",
        "--file",
        "bin/helper",
        "in/helper",
    });
}

test "bundle: the layout, the modes, and SHA256SUMS of every other file in byte order" {
    var c = try newCtx("bundle");
    defer c.deinit();
    try c.write("in/launcher", "L", 0o755);
    try c.write("in/prog.so", "S", 0o444);
    try c.write("in/rt/libtwo.so", "2", 0o444);
    try c.write("in/rt/libone.so", "1", 0o755);
    try c.write("in/VERSION", "name=prog\n", 0o444);
    try c.write("in/data.txt", "D", 0o400);
    try c.write("in/helper", "H", 0o644);
    const r = try c.run(try bundleArgs(&c, "out/b", "in/rt"), &.{});
    if (r.code != 0) std.debug.print("[pkg_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("L", try c.read("out/b/bin/prog"));
    try t.expectEqualStrings("S", try c.read("out/b/lib/glibc-hwcaps/x86-64-v3/libprog.so"));
    try t.expectEqualStrings("1", try c.read("out/b/lib/libone.so"));
    try t.expectEqualStrings("D", try c.read("out/b/share/doc/d.txt"));
    try t.expectEqualStrings("name=prog\n", try c.read("out/b/VERSION"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/b/bin/prog"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/b/bin/helper"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try c.mode("out/b/lib/libone.so"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try c.mode("out/b/share/doc/d.txt"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try c.mode("out/b/SHA256SUMS"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/b"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/b/share/doc"));
    const names = [_][]const u8{ "VERSION", "bin/helper", "bin/prog", "lib/glibc-hwcaps/x86-64-v3/libprog.so", "lib/libone.so", "lib/libtwo.so", "share/doc/d.txt" };
    var want = std.ArrayList(u8).init(c.alloc());
    for (names) |n| {
        const data = try c.read(try std.fmt.allocPrint(c.alloc(), "out/b/{s}", .{n}));
        try want.writer().print("{s}  {s}\n", .{ &sha(data), n });
    }
    try t.expectEqualStrings(want.items, try c.read("out/b/SHA256SUMS"));
}

test "bundle: a directory in the runtime, an empty runtime and a missing input are refused" {
    var c = try newCtx("bundle_bad");
    defer c.deinit();
    try c.write("in/launcher", "L", 0o755);
    try c.write("in/prog.so", "S", 0o644);
    try c.write("in/VERSION", "v", 0o644);
    try c.write("in/data.txt", "D", 0o644);
    try c.write("in/helper", "H", 0o644);
    try c.write("in/rtdir/sub/x", "1", 0o644);
    try c.mkdir("in/rtempty");
    try t.expectEqual(@as(u8, 1), (try c.run(try bundleArgs(&c, "o1", "in/rtdir"), &.{})).code);
    try t.expectEqual(@as(u8, 1), (try c.run(try bundleArgs(&c, "o2", "in/rtempty"), &.{})).code);
    try t.expectEqual(@as(u8, 1), (try c.run(try bundleArgs(&c, "o3", "in/missing"), &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "bundle", "--out", "o4" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "bundle", "--bogus", "x" }, &.{})).code);
}

// ---- copy-dir ---------------------------------------------------------------

test "copy-dir: the whole tree, modes and links kept, merged into an existing directory" {
    var c = try newCtx("copy_dir");
    defer c.deinit();
    try c.write("src/a", "a", 0o755);
    try c.write("src/sub/b", "b", 0o644);
    try std.fs.cwd().symLink("a", try c.path("src/ln"), .{});
    try c.write("dst/keep", "k", 0o644);
    const r = try c.run(&.{ "copy-dir", "src", "dst" }, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("a", try c.read("dst/a"));
    try t.expectEqualStrings("b", try c.read("dst/sub/b"));
    try t.expectEqualStrings("k", try c.read("dst/keep"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("dst/a"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("a", try std.fs.cwd().readLink(try c.path("dst/ln"), &buf));
    // The destination is created; a missing source is refused.
    try t.expectEqual(@as(u8, 0), (try c.run(&.{ "copy-dir", "src", "new/deep/dst" }, &.{})).code);
    try t.expectEqualStrings("b", try c.read("new/deep/dst/sub/b"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "copy-dir", "nope", "d2" }, &.{})).code);
}

// ---- oci-release-manifest ---------------------------------------------------

fn ociArgs(c: *kit.Ctx, name: []const u8) ![]const []const u8 {
    return c.alloc().dupe([]const u8, &.{
        "oci-release-manifest", "--out",      "m.json",  "--digest", "digest.txt",     "--name", name,
        "--version",            "1.0",        "--platform", "linux-x86_64", "--file", "img", "--label",
        "//p:image",            "--repo",     "komira/x", "--from",   "the bundle's program",
    });
}

test "oci-release-manifest: kci's compact bytes; a bad digest or member name is refused in words and writes nothing" {
    var c = try newCtx("oci");
    defer c.deinit();
    try c.write("digest.txt", "sha256:" ++ hex64 ++ "\n", 0o644);
    const r = try c.run(try ociArgs(&c, "hello_app"), &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"OCI\",\"name\":\"hello_app\",\"version\":\"1.0\",\"platform\":\"linux-x86_64\",\"file\":\"img\",\"sha256\":\"" ++ hex64 ++ "\"}\n", try c.read("m.json"));

    const r2 = try c.run(try ociArgs(&c, "oci-check"), &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expectEqualStrings("oci_image[release] of //p:image (repository komira/x): member name 'oci-check' (the bundle's program) is not a kci artifact name ([a-z][a-z0-9_]*)\n", r2.stderr);

    std.fs.cwd().deleteFile(try c.path("m.json")) catch {};
    try c.write("digest.txt", "sha256:short\n", 0o644);
    const r3 = try c.run(try ociArgs(&c, "x"), &.{});
    try t.expectEqual(@as(u8, 1), r3.code);
    try t.expect(has(r3.stderr, "digest.txt holds 'sha256:short', not sha256:<64 hex>"));
    try t.expect(!c.exists("m.json"));
}

// ---- level-run ---------------------------------------------------------------

test "level-run: the program's stdout is the target's output and is shown; its exit status is the action's" {
    var c = try newCtx("level");
    defer c.deinit();
    const probe = try c.env("PROBE");
    const r = try c.run(&.{ "level-run", "out.txt", probe }, &.{.{ "PROBE_MODE", "level" }});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("level report\n", try c.read("out.txt"));
    try t.expect(has(r.stderr, "level report\n"));
    try t.expect(has(r.stderr, "a note on stderr"));
    const r2 = try c.run(&.{ "level-run", "out2.txt", probe }, &.{.{ "PROBE_MODE", "level_fail" }});
    try t.expectEqual(@as(u8, 3), r2.code);
    try t.expectEqualStrings("level report: wrong\n", try c.read("out2.txt"));
    try t.expect(has(r2.stderr, "level report: wrong"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "level-run", "o" }, &.{})).code);
}

// ---- conda-manifest-kci --------------------------------------------------------

fn laydir(c: *kit.Ctx, dir: []const u8) !void {
    const al = c.alloc();
    try c.write(try std.fmt.allocPrint(al, "{s}/p-1.0-0.conda", .{dir}), "pkg", 0o644);
    try c.write(try std.fmt.allocPrint(al, "{s}/manifest.json", .{dir}), "{}", 0o644);
    try c.write(try std.fmt.allocPrint(al, "{s}/metadata.json", .{dir}), "{}", 0o644);
}

test "conda-manifest-kci: the probe's line, with the directory taken out; refused for each way it can be wrong" {
    var c = try newCtx("kci");
    defer c.deinit();
    const probe = try c.env("PROBE");
    try laydir(&c, "pkg");
    const r = try c.run(&.{ "conda-manifest-kci", "out.parsed", "pkg", probe }, &.{.{ "PROBE_MODE", "ok" }});
    if (r.code != 0) std.debug.print("[pkg_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("OK CONDA pkg 1.0 metadata=metadata.json metadata_path=metadata.json render-identical=yes\n", try c.read("out.parsed"));

    // A parser that refuses: its exit status and words are in the message.
    const r2 = try c.run(&.{ "conda-manifest-kci", "o2", "pkg", probe }, &.{.{ "PROBE_MODE", "refuse" }});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(has(r2.stderr, "conda_manifest_kci: kci's artifact-manifest parser refuses "));
    try t.expect(has(r2.stderr, "(exit 1): cannot parse the manifest"));
    try t.expect(!c.exists("o2"));
    // A metadata path that is not the file next to the manifest.
    const r3 = try c.run(&.{ "conda-manifest-kci", "o3", "pkg", probe }, &.{.{ "PROBE_MODE", "elsewhere" }});
    try t.expectEqual(@as(u8, 1), r3.code);
    try t.expect(has(r3.stderr, "it must be one OK CONDA line ending"));
    try t.expect(!c.exists("o3"));
    // Another file in the directory; a directory with two packages.
    try c.write("pkg/notes.txt", "x", 0o644);
    const r4 = try c.run(&.{ "conda-manifest-kci", "o4", "pkg", probe }, &.{.{ "PROBE_MODE", "ok" }});
    try t.expectEqual(@as(u8, 1), r4.code);
    try t.expect(has(r4.stderr, "holds [manifest.json metadata.json notes.txt p-1.0-0.conda ], not exactly one .conda, manifest.json and metadata.json"));
    try laydir(&c, "two");
    try c.write("two/q-1.0-0.conda", "x", 0o644);
    try std.fs.cwd().deleteFile(try c.path("two/manifest.json"));
    try t.expectEqual(@as(u8, 1), (try c.run(&.{ "conda-manifest-kci", "o5", "two", probe }, &.{.{ "PROBE_MODE", "ok" }})).code);
}

test "conda-manifest-kci: the probe sees no library path, a TMPDIR and a HOME that exist" {
    var c = try newCtx("kci_env");
    defer c.deinit();
    const probe = try c.env("PROBE");
    try laydir(&c, "pkg");
    const r = try c.run(&.{ "conda-manifest-kci", "out.parsed", "pkg", probe }, &.{ .{ "PROBE_MODE", "env" }, .{ "LD_LIBRARY_PATH", "/a" }, .{ "LD_PRELOAD", "/b" } });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("OK CONDA ld=unset_preload=unset_tmp=dir_home=dir 1.0 metadata=metadata.json metadata_path=metadata.json render-identical=yes\n", try c.read("out.parsed"));
}

// ---- the release-set checks --------------------------------------------------------

const build = "h7e57c0de_999999999";

fn member(c: *kit.Ctx, name: []const u8, requires: []const []const u8) !void {
    const al = c.alloc();
    const conda = try std.fmt.allocPrint(al, "{s}/{s}-1.2.3-{s}.conda", .{ name, name, build });
    try c.write(conda, "pkg", 0o644);
    try c.write(try std.fmt.allocPrint(al, "{s}/manifest.json", .{name}), try std.fmt.allocPrint(al, "{{\"file\":\"{s}-1.2.3-{s}.conda\",\"version\":\"1.2.3\"}}", .{ name, build }), 0o644);
    var deps = std.ArrayList(u8).init(al);
    for (requires) |r| try deps.writer().print("\"{s} ==1.2.3 {s}\",", .{ r, build });
    try c.write(try std.fmt.allocPrint(al, "{s}/metadata.json", .{name}), try std.fmt.allocPrint(al, "{{\"depends\":[{s}],\"build\":\"{s}\",\"build_number\":999999999,\"source_commit\":\"c0ffee\",\"stamped\":true,\"timestamp_ms\":1000}}", .{ deps.items, build }), 0o644);
}

fn stampArgs(c: *kit.Ctx, set: []const u8) ![]const []const u8 {
    return c.alloc().dupe([]const u8, &.{
        "release-stamp-check", "--out", "stamped.txt", "--version", "1.2.3", "--build-number", "999999999",
        "--commit", "c0ffee", "--timestamp-ms", "1000", "--build", build, "--meta", "meta", "--meta-dir", "meta",
        "--set", set, "--license", "L", "--summary", "S", "--home", "H",
        "--member", "komira_a", "komira_a", "--member", "komira_b", "komira_b",
    });
}

test "release-stamp-check: the marker names the version, build and members; each mismatch is one refusal line" {
    var c = try newCtx("stamp");
    defer c.deinit();
    try member(&c, "komira_a", &.{});
    try member(&c, "komira_b", &.{});
    try member(&c, "meta", &.{ "komira_a", "komira_b" });
    // the metapackage's own conda file is named for the metapackage
    try c.write("set.txt", "metapackage meta\nmember komira_a\nmember komira_b\nlicense L\nsummary S\nhome H\n", 0o644);
    const r = try c.run(try stampArgs(&c, "set.txt"), &.{});
    if (r.code != 0) std.debug.print("[pkg_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("stamped 1.2.3 " ++ build ++ ": komira_a komira_b\n", try c.read("stamped.txt"));

    // The release set lists a member the target does not have.
    try c.write("set2.txt", "metapackage meta\nmember komira_a\nmember komira_b\nmember komira_c\nlicense L\nsummary S\nhome H\n", 0o644);
    std.fs.cwd().deleteFile(try c.path("stamped.txt")) catch {};
    const r2 = try c.run(try stampArgs(&c, "set2.txt"), &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(has(r2.stderr, "libs are [ komira_a komira_b ], set2.txt's members are [ komira_a komira_b komira_c ]: the two lists of the release set differ"));
    try t.expect(!c.exists("stamped.txt"));
    // A line of the release set that is not a key.
    try c.write("set3.txt", "metapackage meta\nbogus x\n", 0o644);
    const r3 = try c.run(try stampArgs(&c, "set3.txt"), &.{});
    try t.expectEqual(@as(u8, 1), r3.code);
    try t.expectEqualStrings("conda_release_set_check: set3.txt: unknown key 'bogus'\n", r3.stderr);
    // A metapackage whose requirement is missing.
    try member(&c, "meta", &.{"komira_a"});
    const r4 = try c.run(try stampArgs(&c, "set.txt"), &.{});
    try t.expectEqual(@as(u8, 1), r4.code);
    try t.expect(has(r4.stderr, "metapackage meta does not require member komira_b at 1.2.3 " ++ build));
}

test "release-order-check and release-order-test: in order passes; a requirement of a later member is one refusal line the test accepts only when it contains the wanted text" {
    var c = try newCtx("order");
    defer c.deinit();
    try c.write("a.json", "{\"depends\":[\"b ==1 B\"]}", 0o644);
    try c.write("b.json", "{\"depends\":[]}", 0o644);
    const ok = try c.run(&.{ "release-order-check", "--out", "ok.txt", "--set", "rs", "--version", "1", "--build", "B", "--member", "b", "b.json", "--member", "a", "a.json" }, &.{});
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqualStrings("in order: b a\n", try c.read("ok.txt"));
    const bad = try c.run(&.{ "release-order-check", "--out", "bad.txt", "--set", "rs", "--version", "1", "--build", "B", "--member", "a", "a.json", "--member", "b", "b.json" }, &.{});
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expectEqualStrings("conda_release_set_check: member a requires b, which rs lists after it: list each member after the members it requires (here, in release/artifacts.textproto and in libs)\n", bad.stderr);
    try t.expect(!c.exists("bad.txt"));

    // The test: green when the refusal is the wanted one, or nothing is wanted and nothing is refused.
    const g1 = try c.run(&.{ "release-order-test", "--out", "t1.ok", "--refuses", "member a requires b", "--set", "rs", "--version", "1", "--build", "B", "--member", "a", "a.json", "--member", "b", "b.json" }, &.{});
    try t.expectEqual(@as(u8, 0), g1.code);
    try t.expectEqualStrings("ok\n", try c.read("t1.ok"));
    const g2 = try c.run(&.{ "release-order-test", "--out", "t2.ok", "--refuses", "", "--set", "rs", "--version", "1", "--build", "B", "--member", "b", "b.json", "--member", "a", "a.json" }, &.{});
    try t.expectEqual(@as(u8, 0), g2.code);
    // Red: a refusal without the wanted text; a pass where a refusal is wanted; a refusal where a pass is wanted.
    const r1 = try c.run(&.{ "release-order-test", "--out", "t3.ok", "--refuses", "something else", "--set", "rs", "--version", "1", "--build", "B", "--member", "a", "a.json", "--member", "b", "b.json" }, &.{});
    try t.expectEqual(@as(u8, 1), r1.code);
    try t.expect(has(r1.stderr, "release_order_test: the order check refused without 'something else'"));
    const r2 = try c.run(&.{ "release-order-test", "--out", "t4.ok", "--refuses", "member a", "--set", "rs", "--version", "1", "--build", "B", "--member", "b", "b.json", "--member", "a", "a.json" }, &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(has(r2.stderr, "release_order_test: the order check passed, expected a refusal containing 'member a'"));
    const r3 = try c.run(&.{ "release-order-test", "--out", "t5.ok", "--refuses", "", "--set", "rs", "--version", "1", "--build", "B", "--member", "a", "a.json", "--member", "b", "b.json" }, &.{});
    try t.expectEqual(@as(u8, 1), r3.code);
    try t.expect(has(r3.stderr, "release_order_test: the order check refused, expected it to pass: "));
    try t.expect(!c.exists("t3.ok") and !c.exists("t4.ok") and !c.exists("t5.ok"));
}

test "usage: no subcommand, an unknown one" {
    var c = try newCtx("usage");
    defer c.deinit();
    try t.expectEqual(@as(u8, 2), (try c.run(&.{}, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"frobnicate"}, &.{})).code);
}
