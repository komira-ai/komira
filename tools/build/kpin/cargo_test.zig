//! `kpin cargo`: the golden output of a small fixture workspace (renames, two
//! versions of one crate, a proc-macro, a library named unlike its package,
//! build scripts of classes a, b and c), every refusal, and the commands end
//! to end on real files. Every test is named for the defect it catches.

const std = @import("std");
const cargo = @import("cargo.zig");
const cargo_lock = @import("cargo_lock.zig");
const cargo_trim = @import("cargo_trim.zig");
const fetch = @import("fetch.zig");
const main = @import("main.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const lock_text = @embedFile("cargo_fixture/Cargo.lock");
const raw_metadata_text = @embedFile("cargo_fixture/raw_metadata.json");
const metadata_text = @embedFile("cargo_fixture/metadata.json");
const target = "x86_64-unknown-linux-gnu";
const overrides_text = @embedFile("cargo_fixture/overrides.json");
const sizes_text = @embedFile("cargo_fixture/sizes.txt");
const expected_text = @embedFile("cargo_fixture/expected.bzl");

const Fix = struct {
    lock: []const u8 = lock_text,
    metadata: []const u8 = metadata_text,
    overrides: []const u8 = overrides_text,
    sizes: []const u8 = sizes_text,
    rustc: []const u8 = "1.85.0",
    target: []const u8 = target,
};

fn gen(a: std.mem.Allocator, f: Fix, d: *Diag) ![]u8 {
    return cargo.generate(a, .{ .lock = f.lock, .metadata = f.metadata, .overrides = f.overrides, .sizes = f.sizes, .rustc = f.rustc, .target = f.target }, d) catch error.Invalid;
}

/// `text` with the first `from` after `anchor` replaced; the edit must apply.
fn edit(a: std.mem.Allocator, text: []const u8, anchor: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, anchor) orelse return error.AnchorMissing;
    const rel = std.mem.indexOf(u8, text[at..], from) orelse return error.EditMissing;
    const start = at + rel;
    return std.mem.concat(a, u8, &.{ text[0..start], to, text[start + from.len ..] });
}

fn refuses(f: Fix, needle: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    if (gen(a, f, &d)) |_| {
        std.debug.print("generated, but it must be refused for `{s}`\n", .{needle});
        return error.TestExpectedRefusal;
    } else |_| {}
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`; messages:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "golden: the fixture workspace generates exactly the committed file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const got = try gen(a, .{}, &d);
    if (!std.mem.eql(u8, got, expected_text)) {
        std.debug.print("---- generated ----\n{s}---- end ----\n", .{got});
        return error.TestGoldenMismatch;
    }
}

test "the committed trimmed fixture is what --trim makes of the raw one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const got = try cargo_trim.trim(a, "raw_metadata.json", raw_metadata_text, target, &d);
    if (!std.mem.eql(u8, got, metadata_text)) {
        std.debug.print("---- trimmed ----\n{s}---- end ----\n", .{got});
        return error.TestGoldenMismatch;
    }
}

test "the output is deterministic" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const x = try gen(a, .{}, &d);
    const y = try gen(a, .{}, &d);
    try t.expectEqualStrings(x, y);
}

test "only linked crates: build- and dev-dependencies are not emitted" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const got = try gen(a, .{}, &d);
    // cc is a build-dependency, tempfile a dev-dependency; libc is also a
    // build-dependency of serde but a normal dependency too.
    try t.expect(!has(got, "name = \"cc\""));
    try t.expect(!has(got, "name = \"tempfile\""));
    try t.expect(has(got, "name = \"libc\""));
    try t.expect(!has(got, "\"app\""));
}

test "two versions of one crate are told apart, and a rename is a renamed_deps entry" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const got = try gen(a, .{}, &d);
    try t.expect(has(got, "name = \"http-0.2.12\""));
    try t.expect(has(got, "name = \"http-1.1.0\""));
    try t.expect(has(got, "crate = \"http\""));
    // No target is plain `http`: it would be ambiguous.
    try t.expect(!has(got, "name = \"http\""));
    // foo-bar names the two as `http` and `http_1x`: the first is a plain
    // dependency, the second a rename.
    try t.expect(has(got, "deps = [\":http-0.2.12\", \":libc\"],"));
    try t.expect(has(got, "renamed_deps = {\n            \"http_1x\": \":http-1.1.0\",\n        },"));
}

test "the library's name and root are Cargo's, not the package's" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const got = try gen(a, .{}, &d);
    try t.expect(has(got, "crate_name = \"foo_baz\""));
    try t.expect(has(got, "crate_root = \"src/foo.rs\""));
    try t.expect(has(got, "edition = \"2018\""));
}

test "a proc-macro crate is marked, with proc_macro_extern" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const got = try gen(a, .{}, &d);
    try t.expect(has(got, "proc_macro = True,\n        proc_macro_extern = True,"));
}

test "a patch's text is escaped into a Starlark string" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    // The substituted text holds a quote, a backslash, a newline and a control character.
    const ov = try edit(a, overrides_text, "\"add\"", "pub mod __private100 {}\\n", "q\\\"b\\\\n\\nc\\u0001\\n");
    const got = try gen(a, .{ .overrides = ov }, &d);
    try t.expect(has(got, "\"content\": \"q\\\"b\\\\n\\nc\\x01\\n\""));
}

// ---- refusals ----------------------------------------------------------------

test "a planted bad sha256 in Cargo.lock is refused, naming the crate" {
    const h = "e" ** 64;
    const a = t.allocator;
    const bad = try edit(a, lock_text, "name = \"libc\"", h, "NOT-A-SHA256");
    defer a.free(bad);
    try refuses(.{ .lock = bad }, "libc 0.2.150: the checksum in Cargo.lock is not a lower-case sha256");
    const short = try edit(a, lock_text, "name = \"libc\"", h, "e" ** 63);
    defer a.free(short);
    try refuses(.{ .lock = short }, "libc 0.2.150: the checksum");
    const upper = try edit(a, lock_text, "name = \"libc\"", h, "E" ** 64);
    defer a.free(upper);
    try refuses(.{ .lock = upper }, "libc 0.2.150: the checksum");
}

test "a package with no checksum is refused" {
    const a = t.allocator;
    const bad = try edit(a, lock_text, "name = \"serde\"", "checksum = \"" ++ ("2" ** 64) ++ "\"\n", "");
    defer a.free(bad);
    try refuses(.{ .lock = bad }, "serde 1.0.100 has no checksum in Cargo.lock");
}

test "a build script with no override entry is an error that names the crate" {
    const a = t.allocator;
    // The entry is for another version: libc 0.2.150 has none, and the entry is stale.
    const bad = try edit(a, overrides_text, "\"libc 0.2.150\"", "libc 0.2.150", "libc 0.2.149");
    defer a.free(bad);
    try refuses(.{ .overrides = bad }, "libc 0.2.150 has a build script and no entry in overrides.json");
    try refuses(.{ .overrides = bad }, "\"libc 0.2.149\" matches no linked crate");
}

test "a build script that is unknown is refused for each class of crate" {
    const a = t.allocator;
    const bad = try edit(a, overrides_text, "\"lzma-sys 0.1.0\"", "lzma-sys 0.1.0", "lzma-sys 0.1.1");
    defer a.free(bad);
    try refuses(.{ .overrides = bad }, "lzma-sys 0.1.0 has a build script and no entry");
}

test "an override for a crate with no build script needs class m" {
    const a = t.allocator;
    const bad = try edit(a, overrides_text, "\"libc 0.2.150\"", "libc 0.2.150", "http 1.1.0");
    defer a.free(bad);
    try refuses(.{ .overrides = bad }, "http 1.1.0 has no build script, and its entry in overrides.json is class a");
    try refuses(.{ .overrides = bad }, "libc 0.2.150 has a build script and no entry");
}

test "a class that does not fit what the entry carries is refused" {
    const a = t.allocator;
    // libc as class b with no patch.
    const b = try edit(a, overrides_text, "\"libc 0.2.150\"", "\"class\": \"a\"", "\"class\": \"b\"");
    defer a.free(b);
    try refuses(.{ .overrides = b }, "class b generates files: it needs a `patch`");
    // serde (class b, patches) relabelled a.
    const c = try edit(a, overrides_text, "\"serde 1.0.100\"", "\"class\": \"b\"", "\"class\": \"a\"");
    defer a.free(c);
    try refuses(.{ .overrides = c }, "class a only emits cfgs and env");
    // lzma-sys (native) relabelled c with no native_deps.
    const d = try edit(a, overrides_text, "\"lzma-sys 0.1.0\"", "\"native_deps\": [\n    \"komira//third_party/xz:lzma[static-pic]\"\n   ],", "");
    defer a.free(d);
    try refuses(.{ .overrides = d }, "class c replaces native code with a komira target: it needs `native_deps`");
}

test "overrides: a typo in a key, a missing why, a bad path and an unknown class are refused" {
    const a = t.allocator;
    const typo = try edit(a, overrides_text, "\"libc 0.2.150\"", "\"cfgs\"", "\"cfg\"");
    defer a.free(typo);
    try refuses(.{ .overrides = typo }, "unknown key `cfg`");
    const nowhy = try edit(a, overrides_text, "\"libc 0.2.150\"", "\"why\"", "\"because\"");
    defer a.free(nowhy);
    try refuses(.{ .overrides = nowhy }, "no `why`");
    const path = try edit(a, overrides_text, "\"serde 1.0.100\"", "\"src/private.rs\"", "\"../private.rs\"");
    defer a.free(path);
    try refuses(.{ .overrides = path }, "patch.add file `../private.rs` is not a relative path");
    const cls = try edit(a, overrides_text, "\"libc 0.2.150\"", "\"class\": \"a\"", "\"class\": \"z\"");
    defer a.free(cls);
    try refuses(.{ .overrides = cls }, "`class` is a, b, c or m");
}

test "overrides derived for another compiler are refused" {
    try refuses(.{ .rustc = "1.86.0" }, "derived for rustc 1.85.0, but the pinned compiler is 1.86.0");
}

test "a crate from git or a path is refused, not pinned" {
    const a = t.allocator;
    const git = try edit(a, metadata_text, "\"name\": \"foo-bar\"", "\"source\": \"registry+https://github.com/rust-lang/crates.io-index\"", "\"source\": \"git+https://example.invalid/foo#abc\"");
    defer a.free(git);
    try refuses(.{ .metadata = git }, "foo-bar 1.0.0 comes from `git+https://example.invalid/foo#abc`");
    const path = try edit(a, metadata_text, "\"name\": \"foo-bar\"", "\"source\": \"registry+https://github.com/rust-lang/crates.io-index\"", "\"source\": null");
    defer a.free(path);
    try refuses(.{ .metadata = path }, "foo-bar 1.0.0 is a path dependency");
}

test "a crate with no size is refused" {
    const a = t.allocator;
    const bad = try edit(a, sizes_text, "http-1.1.0.crate", "http-1.1.0.crate", "http-9.9.9.crate");
    defer a.free(bad);
    try refuses(.{ .sizes = bad }, "no size for http-1.1.0.crate in sizes.txt");
}

test "a lock version other than 3 and 4, and metadata without a resolve, are refused" {
    const a = t.allocator;
    const v2 = try edit(a, lock_text, "version = 3", "version = 3", "version = 2");
    defer a.free(v2);
    try refuses(.{ .lock = v2 }, "lock version 2 is not 3 or 4");
    const nr = try edit(a, metadata_text, "\"resolve\"", "\"resolve\"", "\"resolved\"");
    defer a.free(nr);
    try refuses(.{ .metadata = nr }, "no `resolve`");
}

test "a feature name outside the character set is refused" {
    const a = t.allocator;
    const bad = try edit(a, metadata_text, "\"extra_traits\"", "extra_traits", "x\\\"y");
    defer a.free(bad);
    try refuses(.{ .metadata = bad }, "feature `x\"y` has unsupported characters");
}

test "Cargo.lock: dependencies are skipped, the [metadata] table ends the packages" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const text =
        \\version = 3
        \\
        \\[[package]]
        \\name = "a"
        \\version = "1.0.0"
        \\source = "registry+https://github.com/rust-lang/crates.io-index"
        \\checksum = "0000000000000000000000000000000000000000000000000000000000000000"
        \\dependencies = [
        \\ "name = \"not a field\"",
        \\]
        \\
        \\[metadata]
        \\name = "ignored"
        \\
    ;
    const es = try cargo_lock.parse(a, "Cargo.lock", text, &d);
    try t.expectEqual(@as(usize, 1), es.len);
    try t.expectEqualStrings("a", es[0].name);
    try t.expectEqualStrings("0" ** 64, es[0].checksum);
}

// ---- the platform the metadata was filtered for ------------------------------------

test "metadata filtered for another platform is refused" {
    const a = t.allocator;
    const other = try edit(a, metadata_text, "\"filter_platform\"", "x86_64-unknown-linux-gnu", "aarch64-apple-darwin");
    defer a.free(other);
    try refuses(.{ .metadata = other }, "filtered for aarch64-apple-darwin, but the pinned target is x86_64-unknown-linux-gnu");
    try refuses(.{ .target = "aarch64-apple-darwin" }, "filtered for x86_64-unknown-linux-gnu, but the pinned target is aarch64-apple-darwin");
}

test "raw cargo metadata, which records no platform, is refused with the way to trim it" {
    try refuses(.{ .metadata = raw_metadata_text }, "records no platform");
}

test "an edge for another platform's triple shows the metadata was not filtered" {
    const a = t.allocator;
    // serde's edge to libc, as made for windows.
    const bad = try edit(a, metadata_text, "\"name\": \"libc\"", "\"target\": null", "\"target\": \"x86_64-pc-windows-msvc\"");
    defer a.free(bad);
    try refuses(.{ .metadata = bad }, "has an edge for x86_64-pc-windows-msvc, not x86_64-unknown-linux-gnu");
}

// ---- trimmed metadata ------------------------------------------------------------

test "trim: the machine's paths are gone, and the generated file is the same" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const trimmed = try cargo_trim.trim(a, "metadata.json", raw_metadata_text, target, &d);
    try t.expect(!has(trimmed, "/reg/"));
    try t.expect(!has(trimmed, "/w/app"));
    try t.expect(has(trimmed, "/m/serde-1.0.100/src/lib.rs"));
    // Only what kpin reads: no test targets, no dependency lists.
    try t.expect(!has(trimmed, "tests/t.rs"));
    try t.expect(!has(trimmed, "crate_types"));
    try t.expect(trimmed.len < raw_metadata_text.len);
    const got = try gen(a, .{ .metadata = trimmed }, &d);
    try t.expectEqualStrings(expected_text, got);
}

test "trim is idempotent" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var d = Diag.init(a);
    const once = try cargo_trim.trim(a, "metadata.json", raw_metadata_text, target, &d);
    const twice = try cargo_trim.trim(a, "metadata.json", once, target, &d);
    try t.expectEqualStrings(once, twice);
}

test "trim refuses metadata made with --no-deps, and a target outside its package" {
    const a = t.allocator;
    var ar = std.heap.ArenaAllocator.init(a);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const nr = try edit(a, raw_metadata_text, "\"resolve\"", "\"resolve\"", "\"resolved\"");
    defer a.free(nr);
    try t.expectError(error.Invalid, cargo_trim.trim(ar.allocator(), "metadata.json", nr, target, &d));
    try t.expect(has(d.msgs.items[0], "no `resolve`"));
    const out = try edit(a, raw_metadata_text, "\"name\": \"foo-bar\"", "/reg/foo-bar-1.0.0/src/foo.rs", "/elsewhere/foo.rs");
    defer a.free(out);
    var d2 = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, cargo_trim.trim(ar.allocator(), "metadata.json", out, target, &d2));
    try t.expect(has(d2.msgs.items[0], "foo-bar 1.0.0: a target's src_path is not under its manifest directory"));
}

// ---- the command, end to end ---------------------------------------------------

const Env = struct {
    ar: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    dir: []const u8,

    fn init() !*Env {
        const self = try t.allocator.create(Env);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try self.tmp.dir.realpathAlloc(self.ar.allocator(), ".");
        try self.tmp.dir.writeFile(.{ .sub_path = "Cargo.lock", .data = lock_text });
        try self.tmp.dir.writeFile(.{ .sub_path = "metadata.json", .data = metadata_text });
        try self.tmp.dir.writeFile(.{ .sub_path = "raw_metadata.json", .data = raw_metadata_text });
        try self.tmp.dir.writeFile(.{ .sub_path = "overrides.json", .data = overrides_text });
        try self.tmp.dir.writeFile(.{ .sub_path = "sizes.txt", .data = sizes_text });
        return self;
    }

    fn deinit(self: *Env) void {
        self.tmp.cleanup();
        self.ar.deinit();
        t.allocator.destroy(self);
    }

    fn a(self: *Env) std.mem.Allocator {
        return self.ar.allocator();
    }

    fn path(self: *Env, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.dir, name }) catch @panic("oom");
    }

    const Run = struct { code: u8, out: []const u8, err: []const u8 };

    fn kpin(self: *Env, extra: []const []const u8) Run {
        var argv = std.ArrayList([]const u8).empty;
        argv.appendSlice(self.a(), &.{ "cargo", "--cargo-lock", self.path("Cargo.lock"), "--metadata", self.path("metadata.json"), "--overrides", self.path("overrides.json"), "--sizes", self.path("sizes.txt"), "--rustc", "1.85.0", "--target", target, "--cargo-out", self.path("crates.bzl") }) catch @panic("oom");
        argv.appendSlice(self.a(), extra) catch @panic("oom");
        var out = std.Io.Writer.Allocating.init(self.a());
        var err = std.Io.Writer.Allocating.init(self.a());
        var http = fetch.HttpFetcher{ .allocator = self.a() };
        const code = main.run(self.a(), argv.items, &out.writer, &err.writer, &http);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }

    fn read(self: *Env, name: []const u8) []const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), name, 1 << 20) catch @panic("read");
    }
};

test "kpin cargo writes the file, and --check passes on it" {
    const e = try Env.init();
    defer e.deinit();
    const w = e.kpin(&.{});
    try t.expectEqual(@as(u8, 0), w.code);
    try t.expectEqualStrings(expected_text, e.read("crates.bzl"));
    const again = e.kpin(&.{});
    try t.expectEqual(@as(u8, 0), again.code);
    try t.expect(has(again.out, "is up to date"));
    const c = e.kpin(&.{"--check"});
    try t.expectEqual(@as(u8, 0), c.code);
}

test "a hand-edited output is caught by --check, naming the line, and is not rewritten" {
    const e = try Env.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 0), e.kpin(&.{}).code);
    const good = e.read("crates.bzl");
    const at = std.mem.indexOf(u8, good, "size = 1148").?;
    const edited = try std.mem.concat(e.a(), u8, &.{ good[0..at], "size = 1149", good[at + "size = 1148".len ..] });
    try e.tmp.dir.writeFile(.{ .sub_path = "crates.bzl", .data = edited });
    const c = e.kpin(&.{"--check"});
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(has(c.err, "is not what the inputs generate (first difference at line "));
    try t.expectEqualStrings(edited, e.read("crates.bzl"));
    // Without --check the file is regenerated.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{}).code);
    try t.expectEqualStrings(good, e.read("crates.bzl"));
}

test "a stale output is caught by --check when an input changes" {
    const e = try Env.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 0), e.kpin(&.{}).code);
    // A new feature in the metadata, with the committed output untouched.
    const meta = try edit(e.a(), metadata_text, "\"extra_traits\"", "extra_traits", "extra_traits\",\n    \"align");
    try e.tmp.dir.writeFile(.{ .sub_path = "metadata.json", .data = meta });
    const c = e.kpin(&.{"--check"});
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(has(c.err, "is not what the inputs generate"));
}

test "--check of a missing output is exit 1" {
    const e = try Env.init();
    defer e.deinit();
    const c = e.kpin(&.{"--check"});
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(has(c.err, "cannot read"));
}

test "a refused input writes nothing and no stamp" {
    const e = try Env.init();
    defer e.deinit();
    const bad = try edit(e.a(), lock_text, "name = \"libc\"", "e" ** 64, "nope");
    try e.tmp.dir.writeFile(.{ .sub_path = "Cargo.lock", .data = bad });
    const r = e.kpin(&.{ "--stamp", e.path("stamp.json") });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.err, "libc 0.2.150"));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("crates.bzl", .{}));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("stamp.json", .{}));
}

test "the stamp is a passing validation result, written on success only" {
    const e = try Env.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 0), e.kpin(&.{ "--stamp", e.path("stamp.json") }).code);
    try t.expect(has(e.read("stamp.json"), "\"status\": \"success\""));
}

test "a missing flag is named, and the cargo flags belong to the cargo command" {
    const e = try Env.init();
    defer e.deinit();
    var out = std.Io.Writer.Allocating.init(e.a());
    var err = std.Io.Writer.Allocating.init(e.a());
    var http = fetch.HttpFetcher{ .allocator = e.a() };
    const code = main.run(e.a(), &.{ "cargo", "--rustc", "1.85.0" }, &out.writer, &err.writer, &http);
    try t.expectEqual(@as(u8, 1), code);
    try t.expect(has(err.written(), "kpin cargo needs --cargo-lock"));
    err.clearRetainingCapacity();
    const code2 = main.run(e.a(), &.{ "lock", "--rustc", "1.85.0" }, &out.writer, &err.writer, &http);
    try t.expectEqual(@as(u8, 2), code2);
}

test "kpin cargo --trim writes the trimmed metadata, which generates the same file" {
    const e = try Env.init();
    defer e.deinit();
    const r = e.kpin(&.{ "--trim", e.path("trimmed.json"), "--metadata", e.path("raw_metadata.json") });
    try t.expectEqual(@as(u8, 0), r.code);
    try e.tmp.dir.writeFile(.{ .sub_path = "metadata.json", .data = e.read("trimmed.json") });
    try t.expectEqual(@as(u8, 0), e.kpin(&.{}).code);
    try t.expectEqualStrings(expected_text, e.read("crates.bzl"));
}

test "a Cargo.lock checksum that differs from the base's for one crate version is an alarm, not an error" {
    const e = try Env.init();
    defer e.deinit();
    const moved = try edit(e.a(), lock_text, "name = \"libc\"", "e" ** 64, "f" ** 64);
    try e.tmp.dir.writeFile(.{ .sub_path = "Cargo.lock", .data = moved });
    try e.tmp.dir.writeFile(.{ .sub_path = "base.lock", .data = lock_text });
    const r = e.kpin(&.{ "--previous-lock", e.path("base.lock") });
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expect(has(r.err, "libc 0.2.150: Cargo.lock has checksum"));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("crates.bzl", .{}));
    // The same lock is no alarm.
    try e.tmp.dir.writeFile(.{ .sub_path = "Cargo.lock", .data = lock_text });
    try t.expectEqual(@as(u8, 0), e.kpin(&.{ "--previous-lock", e.path("base.lock") }).code);
}
