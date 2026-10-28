//! The process behaviour of `node_act` (tools/build/node_tools/node_act.zig):
//! dist, npm-package, node-test, binding-test and esbuild-bundle, by exit status, message,
//! the environment the child sees and the files written. The programs it runs
//! are one stand-in (fake.zig) under the names node, tool and esbuild.
const std = @import("std");
const kit = @import("driver_kit");
const tt = @import("node_tartest");
const t = std.testing;
const has = kit.has;

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "NODE_ACT");
}

/// The stand-in's bytes.
fn fakeBytes(c: *kit.Ctx) ![]u8 {
    return std.fs.cwd().readFileAlloc(c.alloc(), try c.env("FAKE"), 1 << 26);
}

fn tgzOf(c: *kit.Ctx, entries: []const tt.Entry) ![]u8 {
    const al = c.alloc();
    return tt.gzip(al, try tt.tar(al, entries));
}

fn sriOf(c: *kit.Ctx, bytes: []const u8) ![]u8 {
    var d: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &d, .{});
    const al = c.alloc();
    const b64 = try al.alloc(u8, std.base64.standard.Encoder.calcSize(64));
    _ = std.base64.standard.Encoder.encode(b64, &d);
    return std.fmt.allocPrint(al, "sha512-{s}", .{b64});
}

// ---- dist ---------------------------------------------------------------------

fn distEntries(fake: []const u8, license: []const u8, node_mode: u32) [8]tt.Entry {
    return .{
        .{ .name = "node-x/", .kind = '5', .mode = 0o755 },
        .{ .name = "node-x/bin/node", .mode = node_mode, .data = fake },
        .{ .name = "node-x/bin/npm", .kind = '2', .link = "../lib/node_modules/npm/bin/npm-cli.js" },
        .{ .name = "node-x/LICENSE", .mode = 0o644, .data = license },
        .{ .name = "node-x/include/node/node_api.h", .mode = 0o644, .data = "H" },
        .{ .name = "node-x/include/node/sub/inner.h", .mode = 0o644, .data = "I" },
        .{ .name = "node-x/lib/node_modules/npm/bin/npm-cli.js", .mode = 0o755, .data = "NPM" },
        .{ .name = "node-x/share/doc.md", .mode = 0o644, .data = "D" },
    };
}

test "dist: bin/node, include/node and LICENSE only; node runs with the library path alone and must print v<version>" {
    var c = try newCtx("dist_ok");
    defer c.deinit();
    const fake = try fakeBytes(&c);
    try c.write("a.tgz", try tgzOf(&c, &distEntries(fake, "v7.8.9\nlicence text\n", 0o755)), 0o644);
    try c.mkdir("libs");
    const r = try c.run(&.{ "dist", "--archive", "a.tgz", "--out", "out", "--top", "node-x", "--version", "7.8.9", "--libs", "libs" }, &.{});
    if (r.code != 0) std.debug.print("[node_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/bin/node"));
    try t.expectEqualStrings("H", try c.read("out/include/node/node_api.h"));
    try t.expectEqualStrings("I", try c.read("out/include/node/sub/inner.h"));
    try t.expectEqualStrings("v7.8.9\nlicence text\n", try c.read("out/LICENSE"));
    // Nothing else of the archive: no npm, no library, no share, no link.
    try t.expect(!c.exists("out/lib"));
    try t.expect(!c.exists("out/share"));
    var buf: [64]u8 = undefined;
    try t.expectError(error.FileNotFound, std.fs.cwd().readLink(try c.path("out/bin/npm"), &buf));
}

test "dist: each way an archive can be no Node.js release is refused in words, exit 2" {
    var c = try newCtx("dist_bad");
    defer c.deinit();
    const fake = try fakeBytes(&c);
    try c.mkdir("libs");
    const Case = struct { name: []const u8, entries: []const tt.Entry, version: []const u8, want: []const u8 };
    var good = distEntries(fake, "v7.8.9\n", 0o755);
    var not_exec = distEntries(fake, "v7.8.9\n", 0o644);
    var no_bin = good;
    no_bin[1] = .{ .name = "node-x/bin/other", .data = fake };
    var no_header = good;
    no_header[4] = .{ .name = "node-x/include/node/other.h", .data = "H" };
    var header_dir = good;
    header_dir[4] = .{ .name = "node-x/include/node/node_api.h/", .kind = '5', .mode = 0o755 };
    var no_license = good;
    no_license[3] = .{ .name = "node-x/NOTICE", .data = "N" };
    var broken = good;
    broken[1] = .{ .name = "node-x/bin/node", .mode = 0o755, .data = "this is not a program\n" };
    var other_top = good;
    for (&other_top) |*e| {
        e.name = try std.fmt.allocPrint(c.alloc(), "other{s}", .{e.name[6..]});
    }
    const cases = [_]Case{
        .{ .name = "wrong_version", .entries = &good, .version = "7.8.0", .want = "node_dist: the node in a.tgz is v7.8.9, the pin says v7.8.0\n" },
        .{ .name = "version_prefix", .entries = &good, .version = "7.8", .want = "is v7.8.9, the pin says v7.8\n" },
        .{ .name = "not_executable", .entries = &not_exec, .version = "7.8.9", .want = "node_dist: a.tgz holds no node-x/bin/node or node-x/include/node/node_api.h\n" },
        .{ .name = "no_bin_node", .entries = &no_bin, .version = "7.8.9", .want = "holds no node-x/bin/node or node-x/include/node/node_api.h" },
        .{ .name = "no_header", .entries = &no_header, .version = "7.8.9", .want = "holds no node-x/bin/node or node-x/include/node/node_api.h" },
        .{ .name = "header_is_dir", .entries = &header_dir, .version = "7.8.9", .want = "holds no node-x/bin/node or node-x/include/node/node_api.h" },
        .{ .name = "no_license", .entries = &no_license, .version = "7.8.9", .want = "node_dist: a.tgz holds no node-x/LICENSE\n" },
        .{ .name = "does_not_run", .entries = &broken, .version = "7.8.9", .want = "/bin/node does not run\n" },
        .{ .name = "other_top", .entries = &other_top, .version = "7.8.9", .want = "holds no node-x/bin/node" },
    };
    for (cases) |cs| {
        try c.write("a.tgz", try tgzOf(&c, cs.entries), 0o644);
        const out = try std.fmt.allocPrint(c.alloc(), "out_{s}", .{cs.name});
        const r = try c.run(&.{ "dist", "--archive", "a.tgz", "--out", out, "--top", "node-x", "--version", cs.version, "--libs", "libs" }, &.{});
        if (r.code != 2 or !has(r.stderr, cs.want)) std.debug.print("[{s}] code {d}: {s}\n", .{ cs.name, r.code, r.stderr });
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expect(has(r.stderr, cs.want));
    }
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "dist", "--archive", "a.tgz" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "dist", "--bogus", "x" }, &.{})).code);
}

// ---- npm-package ------------------------------------------------------------------

const js = "// the program is the pinned node's; the stand-in ignores it\n";

fn pkgEntries(fake: []const u8, name: []const u8, tool_name: []const u8) [4]tt.Entry {
    _ = name;
    return .{
        .{ .name = "package/", .kind = '5', .mode = 0o755 },
        .{ .name = "package/package.json", .data = "{\"name\":\"p\",\"version\":\"2.0.0\"}" },
        .{ .name = tool_name, .mode = 0o755, .data = fake },
        .{ .name = "package/lib/a.js", .mode = 0o600, .data = "A" },
    };
}

fn layNode(c: *kit.Ctx) !void {
    const al = c.alloc();
    try c.mkdir("node/bin");
    try std.fs.cwd().copyFile(try c.env("FAKE"), std.fs.cwd(), try c.path("node/bin/node"), .{});
    try c.mkdir("libs");
    _ = al;
}

fn npmArgs(c: *kit.Ctx, tgz: []const u8, sri: []const u8, version: []const u8, exe: []const u8, out: []const u8) ![]const []const u8 {
    _ = tgz;
    return c.alloc().dupe([]const u8, &.{
        "npm-package", "--tarball", "p.tgz",   "--out",  out,    "--name", "p",
        "--version",   version,     "--integrity", sri, "--exe", exe,     "--node",
        "node",        "--libs",    "libs",    "--js",   js,
    });
}

test "npm-package: the sha512 is checked, package/ is unpacked, the pinned node reads package.json, the executable prints the version" {
    var c = try newCtx("npm_ok");
    defer c.deinit();
    const fake = try fakeBytes(&c);
    try layNode(&c);
    const tgz = try tgzOf(&c, &pkgEntries(fake, "p", "package/bin/tool"));
    try c.write("p.tgz", tgz, 0o644);
    const sri = try sriOf(&c, tgz);
    const r = try c.run(try npmArgs(&c, "p.tgz", sri, "1.0.0", "bin/tool", "out"), &.{});
    if (r.code != 0) std.debug.print("[node_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try c.mode("out/bin/tool"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try c.mode("out/lib/a.js"));
    try t.expectEqualStrings("A", try c.read("out/lib/a.js"));
    // node was run with the library path alone, and its words are passed on.
    try t.expect(has(r.stdout, "node -e env=1 ld="));
    try t.expect(has(r.stdout, "/libs/lib\n"));
    // no executable named: none is run
    const r2 = try c.run(try npmArgs(&c, "p.tgz", sri, "1.0.0", "-", "out2"), &.{});
    try t.expectEqual(@as(u8, 0), r2.code);
}

test "npm-package: each refusal in its words, with the exit status of the script" {
    var c = try newCtx("npm_bad");
    defer c.deinit();
    const fake = try fakeBytes(&c);
    try layNode(&c);
    const tgz = try tgzOf(&c, &pkgEntries(fake, "p", "package/bin/tool"));
    try c.write("p.tgz", tgz, 0o644);

    const r1 = try c.run(try npmArgs(&c, "p.tgz", "sha256-AAAA", "1.0.0", "-", "o1"), &.{});
    try t.expectEqual(@as(u8, 2), r1.code);
    try t.expectEqualStrings("npm_package: p: integrity sha256-AAAA is not sha512-<base64>\n", r1.stderr);
    const r1b = try c.run(try npmArgs(&c, "p.tgz", "sha512-", "1.0.0", "-", "o1b"), &.{});
    try t.expectEqualStrings("npm_package: p: integrity sha512- is not sha512-<base64>\n", r1b.stderr);

    const zeros = "sha512-" ++ "A" ** 86 ++ "==";
    const r2 = try c.run(try npmArgs(&c, "p.tgz", zeros, "1.0.0", "-", "o2"), &.{});
    try t.expectEqual(@as(u8, 2), r2.code);
    try t.expect(has(r2.stderr, "npm_package: p: the sha512 of p.tgz is "));
    try t.expect(has(r2.stderr, "; the pinned integrity " ++ zeros ++ " is " ++ "0" ** 128 ++ "\n"));
    try t.expect(!c.exists("o2/package.json"));

    // no package/package.json
    const bare = try tgzOf(&c, &.{.{ .name = "package/x", .data = "x" }});
    try c.write("p.tgz", bare, 0o644);
    const r3 = try c.run(try npmArgs(&c, "p.tgz", try sriOf(&c, bare), "1.0.0", "-", "o3"), &.{});
    try t.expectEqual(@as(u8, 2), r3.code);
    try t.expectEqualStrings("npm_package: p: p.tgz holds no package/package.json\n", r3.stderr);

    // the node refuses package.json: its words and its status reach the action
    const badpkg = try tgzOf(&c, &.{ .{ .name = "package/package.json", .data = "BADPKG" } });
    try c.write("p.tgz", badpkg, 0o644);
    const r4 = try c.run(try npmArgs(&c, "p.tgz", try sriOf(&c, badpkg), "1.0.0", "-", "o4"), &.{});
    try t.expectEqual(@as(u8, 1), r4.code);
    try t.expect(has(r4.stderr, "npm_package: p: package.json of p.tgz does not state \"name\":\"p\" at its top level"));

    // the executable: another version, one that fails, one that is no program
    const other = try tgzOf(&c, &pkgEntries(fake, "p", "package/bin/tool_other"));
    try c.write("p.tgz", other, 0o644);
    const r5 = try c.run(try npmArgs(&c, "p.tgz", try sriOf(&c, other), "1.0.0", "bin/tool_other", "o5"), &.{});
    try t.expectEqual(@as(u8, 2), r5.code);
    try t.expectEqualStrings("npm_package: p: bin/tool_other --version prints 9.9.9, the pin says 1.0.0\n", r5.stderr);
    const broken = try tgzOf(&c, &pkgEntries(fake, "p", "package/bin/tool_broken"));
    try c.write("p.tgz", broken, 0o644);
    const r6 = try c.run(try npmArgs(&c, "p.tgz", try sriOf(&c, broken), "1.0.0", "bin/tool_broken", "o6"), &.{});
    try t.expectEqual(@as(u8, 2), r6.code);
    try t.expectEqualStrings("npm_package: p: bin/tool_broken does not run\n", r6.stderr);
    const r7 = try c.run(try npmArgs(&c, "p.tgz", try sriOf(&c, broken), "1.0.0", "package.json", "o7"), &.{});
    try t.expectEqual(@as(u8, 2), r7.code);
    try t.expectEqualStrings("npm_package: p: package.json does not run\n", r7.stderr);
}

// ---- node-test ----------------------------------------------------------------------

fn testArgs(c: *kit.Ctx, expect: []const u8, err: []const u8, out: []const u8, extra: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    try list.appendSlice(c.alloc(), &.{ "node-test", "--node", "node", "--libs", "libs", "--out", out, "--dir", "src", "--script", "t.mjs", "--expect", expect, "--error", err, "--" });
    try list.appendSlice(c.alloc(), extra);
    return list.items;
}

test "node-test: pass means exit 0; the script sees the fixed environment, its arguments, a HOME and a TMPDIR that exist; the scratch goes" {
    var c = try newCtx("test_pass");
    defer c.deinit();
    try layNode(&c);
    try c.write("src/t.mjs", "env\nargs\nstdout hello\n", 0o644);
    const scratch = try c.path("scratch");
    const r = try c.run(try testArgs(&c, "pass", "-", "t.pass", &.{ "one", "two" }), &.{.{ "BUCK_SCRATCH_PATH", scratch }});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", try c.read("t.pass"));
    try t.expect(has(r.stdout, "env: n=5 LC_ALL=C TZ=UTC0 home=dir tmp=dir ld_ends_lib=yes\n"));
    try t.expect(has(r.stdout, "arg: one\narg: two\n"));
    try t.expect(has(r.stdout, "hello\n"));
    try t.expect(!c.exists("scratch/komira"));
    // A failing script fails the action with its status, and leaves no marker.
    try c.write("src/t.mjs", "stderr boom\nexit 5\n", 0o644);
    const r2 = try c.run(try testArgs(&c, "pass", "-", "t2.pass", &.{}), &.{});
    try t.expectEqual(@as(u8, 5), r2.code);
    try t.expect(has(r2.stderr, "boom"));
    try t.expect(!c.exists("t2.pass"));
}

test "node-test: fail means a non-zero exit whose stderr holds the text; each other outcome is a red" {
    var c = try newCtx("test_fail");
    defer c.deinit();
    try layNode(&c);
    try c.write("src/t.mjs", "stderr assertion: negative fixture fails\nexit 1\n", 0o644);
    const ok = try c.run(try testArgs(&c, "fail", "negative fixture fails", "ok.pass", &.{}), &.{});
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expect(c.exists("ok.pass"));
    // The text is a fixed string, not a pattern.
    try c.write("src/t.mjs", "stderr negative fixture.fails\nexit 1\n", 0o644);
    const pat = try c.run(try testArgs(&c, "fail", "negative fixture.fails", "pat.pass", &.{}), &.{});
    try t.expectEqual(@as(u8, 0), pat.code);
    const pat2 = try c.run(try testArgs(&c, "fail", "negative fixture..fails", "pat2.pass", &.{}), &.{});
    try t.expectEqual(@as(u8, 1), pat2.code);
    // The wrong text: the script's stderr is shown, then the verdict.
    try c.write("src/t.mjs", "stderr something else\nexit 1\n", 0o644);
    const wrong = try c.run(try testArgs(&c, "fail", "negative fixture fails", "w.pass", &.{}), &.{});
    try t.expectEqual(@as(u8, 1), wrong.code);
    try t.expect(has(wrong.stderr, "something else\n"));
    try t.expect(has(wrong.stderr, "t.mjs failed, but its stderr does not hold: negative fixture fails\n"));
    try t.expect(!c.exists("w.pass"));
    // Exiting 0 when it is expected to fail.
    try c.write("src/t.mjs", "stdout fine\n", 0o644);
    const zero = try c.run(try testArgs(&c, "fail", "any error", "z.pass", &.{}), &.{});
    try t.expectEqual(@as(u8, 1), zero.code);
    try t.expect(has(zero.stderr, "t.mjs exited 0; it was expected to fail with: any error\n"));
    try t.expect(!c.exists("z.pass"));
    // Usage: --expect is pass or fail.
    try t.expectEqual(@as(u8, 2), (try c.run(try testArgs(&c, "maybe", "-", "u.pass", &.{}), &.{})).code);
}

// ---- binding-test --------------------------------------------------------------------

fn bindingArgs(c: *kit.Ctx, out: []const u8, files: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    try list.appendSlice(c.alloc(), &.{ "binding-test", "--node", "node", "--libs", "libs", "--out", out, "--dir", "src", "--" });
    try list.appendSlice(c.alloc(), files);
    return list.items;
}

const tap_pass = "stdout # tests 2\nstdout # pass 2\nstdout # fail 0\nstdout # cancelled 0\nstdout # skipped 0\nstdout # todo 0\n";

test "binding-test: node --test over absolute paths of the files; the marker only for a run that reports tests, all passed" {
    var c = try newCtx("binding_pass");
    defer c.deinit();
    try layNode(&c);
    try c.write("src/a.test.mjs", tap_pass, 0o644);
    const scratch = try c.path("scratch");
    const r = try c.run(try bindingArgs(&c, "b.pass", &.{"a.test.mjs"}), &.{.{ "BUCK_SCRATCH_PATH", scratch }});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", try c.read("b.pass"));
    try t.expect(has(r.stdout, "test-mode files=1\n"));
    try t.expect(has(r.stdout, "# pass 2\n"));
    try t.expect(!c.exists("scratch/komira"));
    // Two files are two paths.
    try c.write("src/b.test.mjs", tap_pass, 0o644);
    const r2 = try c.run(try bindingArgs(&c, "b2.pass", &.{ "a.test.mjs", "b.test.mjs" }), &.{});
    try t.expectEqual(@as(u8, 0), r2.code);
    try t.expect(has(r2.stdout, "test-mode files=2\n"));
}

test "binding-test: a failing run keeps its status and shows its output; a run of no test, or of skipped ones, is a red though node exited 0" {
    var c = try newCtx("binding_red");
    defer c.deinit();
    try layNode(&c);
    try c.write("src/t.mjs", "stdout # tests 1\nstdout # fail 1\nstderr not ok 1 - the addon answers 42\nexit 1\n", 0o644);
    const f = try c.run(try bindingArgs(&c, "f.pass", &.{"t.mjs"}), &.{});
    try t.expectEqual(@as(u8, 1), f.code);
    try t.expect(has(f.stderr, "not ok 1 - the addon answers 42\n"));
    try t.expect(has(f.stderr, "binding_test: node --test exited 1\n"));
    try t.expect(!c.exists("f.pass"));
    // Exit 0 with a summary of zero tests (a file that registers none).
    try c.write("src/t.mjs", "stdout # tests 0\nstdout # pass 0\nstdout # fail 0\nstdout # cancelled 0\nstdout # skipped 0\nstdout # todo 0\n", 0o644);
    const z = try c.run(try bindingArgs(&c, "z.pass", &.{"t.mjs"}), &.{});
    try t.expectEqual(@as(u8, 1), z.code);
    try t.expect(has(z.stderr, "binding_test: node --test exited 0, but it ran no test\n"));
    try t.expect(!c.exists("z.pass"));
    // Exit 0, but the file itself is the one test: it registered none.
    const only = try std.fmt.allocPrint(c.alloc(), "stdout # Subtest: {s}\n", .{try c.path("src/t.mjs")});
    try c.write("src/t.mjs", try std.mem.concat(c.alloc(), u8, &.{ only, "stdout # tests 1\nstdout # pass 1\nstdout # fail 0\nstdout # cancelled 0\nstdout # skipped 0\nstdout # todo 0\n" }), 0o644);
    const own = try c.run(try bindingArgs(&c, "own.pass", &.{"t.mjs"}), &.{});
    try t.expectEqual(@as(u8, 1), own.code);
    try t.expect(has(own.stderr, "registers no test of its own\n"));
    try t.expect(!c.exists("own.pass"));
    // Exit 0 with no summary at all.
    try c.write("src/t.mjs", "stdout nothing\n", 0o644);
    const n = try c.run(try bindingArgs(&c, "n.pass", &.{"t.mjs"}), &.{});
    try t.expectEqual(@as(u8, 1), n.code);
    try t.expect(has(n.stderr, "its TAP summary has no \"# tests\" line"));
    // A skipped test.
    try c.write("src/t.mjs", "stdout # tests 2\nstdout # pass 2\nstdout # fail 0\nstdout # cancelled 0\nstdout # skipped 1\nstdout # todo 0\n", 0o644);
    const s = try c.run(try bindingArgs(&c, "s.pass", &.{"t.mjs"}), &.{});
    try t.expectEqual(@as(u8, 1), s.code);
    try t.expect(has(s.stderr, "a test was skipped or left todo"));
    // No file: usage.
    try t.expectEqual(@as(u8, 2), (try c.run(try bindingArgs(&c, "u.pass", &.{}), &.{})).code);
}

// ---- esbuild-bundle -----------------------------------------------------------------

test "esbuild-bundle: run from the staged directory with an empty environment, the output given as an absolute path; its status is the action's" {
    var c = try newCtx("bundle");
    defer c.deinit();
    try c.mkdir("staged");
    try std.fs.cwd().copyFile(try c.env("FAKE"), std.fs.cwd(), try c.path("esbuild"), .{});
    {
        const f = try std.fs.cwd().openFile(try c.path("esbuild"), .{});
        defer f.close();
        try f.chmod(0o755);
    }
    try c.mkdir("out");
    const r2 = try c.run(&.{ "esbuild-bundle", "--esbuild", "esbuild", "--dir", "staged", "--entry", "main.mjs", "--out", "out/bundle.js", "--format", "esm" }, &.{});
    if (r2.code != 0) std.debug.print("[node_act stderr] {s}\n", .{r2.stderr});
    try t.expectEqual(@as(u8, 0), r2.code);
    const want =
        \\cwd=staged
        \\env=0
        \\arg=main.mjs
        \\arg=--bundle
        \\arg=--platform=node
        \\arg=--format=esm
        \\arg=--log-level=warning
        \\outfile_absolute=yes
        \\
    ;
    try t.expectEqualStrings(want, try c.read("out/bundle.js"));
    const r3 = try c.run(&.{ "esbuild-bundle", "--esbuild", "esbuild", "--dir", "staged", "--entry", "FAIL", "--out", "out/b2.js", "--format", "cjs" }, &.{});
    try t.expectEqual(@as(u8, 4), r3.code);
    try t.expect(has(r3.stderr, "esbuild: the entry fails"));
    try t.expect(!c.exists("out/b2.js"));
}

test "usage" {
    var c = try newCtx("usage");
    defer c.deinit();
    try t.expectEqual(@as(u8, 2), (try c.run(&.{}, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"frobnicate"}, &.{})).code);
}
