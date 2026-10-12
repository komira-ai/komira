//! komira_pack readme-link: the link commands written into a packaged README
//! (docs/design/native_packaging.md, "Where a user gets these flags", option
//! (a); slice 10).
//!
//! A `.mojoc` holds no machine code, so a program using a library is linked
//! against every native library of the library's closure. The packaged
//! README says how, as a fenced block whose info string is `sh komira-link`:
//!
//!     mojo run -Xlinker -L$CONDA_PREFIX/lib -Xlinker -l<owner>... prog.mojo
//!     mojo build -Xlinker -L$CONDA_PREFIX/lib -Xlinker -l<owner>... [-Xlinker -l<static>...]
//!         -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o $CONDA_PREFIX/bin/prog
//!
//! (each command on one line). `--owner NAME` is the link name of one shared
//! library of the closure (`lib<NAME>.so`, the `link` row of its package's
//! `lib_files`), given in the order the commands name them: dependents first
//! (conda.bzl orders them). `--static NAME` is a static archive of the
//! closure (`lib<NAME>.a`, komira_log's holder), named on the `mojo build`
//! line only: no shared copy of it exists, and the JIT of `mojo run` has no
//! holder object yet (the design's question 2, option A).
//!
//! THE SOURCE AND THE PACKAGED README. The packaged README is the source
//! README's bytes, then the generated section, appended: every line of the
//! source keeps its number, so a README run's report names the line of the
//! repository's README (src/kci_validate, readme_installed.mojo), and the
//! welded README gate, which runs the source's examples, runs exactly the
//! examples the package ships (the section holds no ```mojo block). The
//! section is derived from the build graph, so the source never carries it:
//! a source README holding a fence that names `komira-link` is refused
//! (a mention in prose is not), and so
//! is a closure with neither an owner nor a static archive (the caller then
//! ships the source unchanged).
//!
//! THE ORDER, CHECKED FROM THE OBJECTS. The order comes from the build graph
//! (native_facts.bzl `readme_link_names`), and kci computes it the same
//! way, so neither would notice the other ordering the owners backwards.
//! Each `--needed-of SONAME=FILE` is the shared library of one owner
//! (conda.bzl passes the package's own and, through `needed_owners`, every
//! owner it NEEDs): its DT_NEEDED is read, and every owner of `--owner` it
//! names must come AFTER it, or the README is refused naming both. A NEEDED
//! name no `--owner` names (libc.so.6) is not ordered here.
//!
//! `--args FILE` receives the commands' arguments in the form the README
//! examples tool's `link` prints (tools/build/readme_examples/link.zig): one
//! `run\t<word>` or `build\t<word>` line per argument, quotes removed. The
//! build hands it to that tool's `link-check` over the packaged README, so a
//! block the tool cannot parse, or parses to other words, is red at build
//! time.

const std = @import("std");
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const Args = pack_common.Args;
const all = pack_common.all;
const fail = pack_common.fail;
const one = pack_common.one;
const conda_lib = @import("conda_lib.zig");

pub const Error = error{Refused} || Alloc.Error;

/// Why the last `error.Refused` was returned.
pub var why: []const u8 = "";

fn refuse(alloc: Alloc, comptime fmt: []const u8, args: anytype) Error {
    why = try std.fmt.allocPrint(alloc, fmt, args);
    return error.Refused;
}

/// The fence info string of the block (the README examples tool reads it).
pub const block_info = "sh komira-link";
/// The marker word a source README may not use.
const marker = "komira-link";

pub const Commands = struct {
    /// The arguments of `mojo run` between `run` and the program.
    run: []const []const u8,
    /// The arguments of `mojo build` between `build` and the program.
    build: []const []const u8,
};

/// A link name: what follows `-l`. Letters, digits and `_` only, so it is
/// one shell word as it stands.
fn checkName(alloc: Alloc, kind: []const u8, n: []const u8) Error!void {
    if (n.len == 0) return refuse(alloc, "an empty --{s} name", .{kind});
    for (n) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return refuse(alloc, "--{s} {s}: a link name is letters, digits and _", .{ kind, n });
    }
}

/// The two commands' arguments for the closure's shared libraries `owners`
/// (in the order given) and static archives `statics`.
pub fn commands(alloc: Alloc, owners: []const []const u8, statics: []const []const u8) Error!Commands {
    if (owners.len == 0 and statics.len == 0) return refuse(alloc, "readme-link: no --owner and no --static: a closure without native files needs no link commands", .{});
    var seen = std.StringHashMap(void).init(alloc);
    for (owners) |o| {
        try checkName(alloc, "owner", o);
        if (seen.contains(o)) return refuse(alloc, "readme-link: {s} given twice", .{o});
        try seen.put(o, {});
    }
    for (statics) |s| {
        try checkName(alloc, "static", s);
        if (seen.contains(s)) return refuse(alloc, "readme-link: {s} given twice", .{s});
        try seen.put(s, {});
    }
    var run = std.ArrayList([]const u8).init(alloc);
    try run.appendSlice(&.{ "-Xlinker", "-L$CONDA_PREFIX/lib" });
    for (owners) |o| try run.appendSlice(&.{ "-Xlinker", try std.mem.concat(alloc, u8, &.{ "-l", o }) });
    var build = std.ArrayList([]const u8).init(alloc);
    try build.appendSlice(run.items);
    for (statics) |s| try build.appendSlice(&.{ "-Xlinker", try std.mem.concat(alloc, u8, &.{ "-l", s }) });
    try build.appendSlice(&.{ "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/../lib" });
    return .{ .run = try run.toOwnedSlice(), .build = try build.toOwnedSlice() };
}

/// One owner's shared library: its SONAME and its bytes (`--needed-of`).
pub const SharedObject = struct { soname: []const u8, data: []const u8 };

/// The link name of SONAME `lib<X>.so.<n>`: X, or null for another shape.
fn ownerName(soname: []const u8) ?[]const u8 {
    const link = conda_lib.linkName(soname) orelse return null;
    return link["lib".len .. link.len - ".so".len];
}

fn position(owners: []const []const u8, name: []const u8) ?usize {
    for (owners, 0..) |o, i| if (std.mem.eql(u8, o, name)) return i;
    return null;
}

/// Refused unless every owner each of `objects` NEEDs comes after it in
/// `owners` (file header, "the order, checked from the objects").
pub fn checkOrder(alloc: Alloc, owners: []const []const u8, objects: []const SharedObject) Error!void {
    for (objects) |o| {
        const name = ownerName(o.soname) orelse return refuse(alloc, "readme-link: --needed-of {s} is not lib<name>.so.<n>", .{o.soname});
        const at = position(owners, name) orelse return refuse(alloc, "readme-link: --needed-of {s}: {s} is not an --owner", .{ o.soname, name });
        const needs = conda_lib.needed(alloc, o.data) catch |e| switch (e) {
            error.Refused => return refuse(alloc, "readme-link: {s}: {s}", .{ o.soname, conda_lib.why }),
            else => |x| return x,
        };
        for (needs) |n| {
            const dep = ownerName(n) orelse continue;
            const dep_at = position(owners, dep) orelse continue;
            if (dep_at <= at) return refuse(alloc, "readme-link: {s} has NEEDED {s}, so -l{s} must come after -l{s}, but the owners are given {s} first (dependents first is the order the README states)", .{ o.soname, n, dep, name, dep });
        }
    }
}

/// A word as the README writes it: single-quoted when it holds `$ORIGIN`
/// (the loader's token, which a shell must not expand).
fn shellWord(alloc: Alloc, w: []const u8) Alloc.Error![]const u8 {
    if (std.mem.indexOf(u8, w, "$ORIGIN") != null) return std.mem.concat(alloc, u8, &.{ "'", w, "'" });
    return w;
}

fn line(alloc: Alloc, out: *std.ArrayList(u8), verb: []const u8, args: []const []const u8, tail: []const u8) !void {
    try out.appendSlice("mojo ");
    try out.appendSlice(verb);
    for (args) |a| {
        try out.append(' ');
        try out.appendSlice(try shellWord(alloc, a));
    }
    try out.appendSlice(tail);
    try out.append('\n');
}

/// The section appended to the README (file header).
pub fn section(alloc: Alloc, c: Commands) Alloc.Error![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    try out.appendSlice("\n## Linking\n\n" ++
        "<!-- Written by the packer from the package's closure (komira_pack readme-link); not in the source README. -->\n" ++
        "A program using this package links every native library of its closure,\n" ++
        "dependents first. In the environment holding the package (`$CONDA_PREFIX`,\n" ++
        "which `pixi run` and `conda activate` set), run or build `prog.mojo` with:\n\n" ++
        "```" ++ block_info ++ "\n");
    try line(alloc, &out, "run", c.run, " prog.mojo");
    try line(alloc, &out, "build", c.build, " prog.mojo -o $CONDA_PREFIX/bin/prog");
    try out.appendSlice("```\n");
    return out.toOwnedSlice();
}

/// The `run\t<word>` / `build\t<word>` lines of `c` (file header).
pub fn argsText(alloc: Alloc, c: Commands) Alloc.Error![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    for (c.run) |a| try out.writer().print("run\t{s}\n", .{a});
    for (c.build) |a| try out.writer().print("build\t{s}\n", .{a});
    return out.toOwnedSlice();
}

/// Whether `text` (one line) opens or closes a fence (``` or ~~~ after any
/// indent) naming the marker.
fn markerFence(text: []const u8) bool {
    const s = std.mem.trimLeft(u8, text, " \t");
    if (!std.mem.startsWith(u8, s, "```") and !std.mem.startsWith(u8, s, "~~~")) return false;
    return std.mem.indexOf(u8, s, marker) != null;
}

/// The packaged README: `source`, ending in a newline, then the section.
/// A source holding a fence that names the marker is refused (file header).
pub fn packagedReadme(alloc: Alloc, source: []const u8, c: Commands) Error![]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        n += 1;
        if (markerFence(l)) {
            return refuse(alloc, "line {d} opens a `{s}` block: the link block is written by the packer from the build graph, never by hand; remove it", .{ n, marker });
        }
    }
    const sep: []const u8 = if (source.len > 0 and source[source.len - 1] != '\n') "\n" else "";
    return std.mem.concat(alloc, u8, &.{ source, sep, try section(alloc, c) });
}

/// `komira_pack readme-link --readme SRC --out README --args FILE (--owner NAME)... (--static NAME)... (--needed-of SONAME=FILE)...`
pub fn cmdReadmeLink(alloc: Alloc, a: Args) !void {
    pack_common.allow(a, &.{ "--readme", "--args", "--owner", "--static", "--needed-of" });
    const src = one(a, "--readme") orelse fail("readme-link: --readme is required", .{});
    const out = a.out orelse fail("readme-link: --out is required", .{});
    const args_out = one(a, "--args") orelse fail("readme-link: --args is required", .{});
    const owners = try all(alloc, a, "--owner");
    const c = commands(alloc, owners, try all(alloc, a, "--static")) catch |e| switch (e) {
        error.Refused => fail("{s}", .{why}),
        else => return e,
    };
    var objects = std.ArrayList(SharedObject).init(alloc);
    for (try all(alloc, a, "--needed-of")) |v| {
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse fail("readme-link: --needed-of `{s}` is not <SONAME>=<file>", .{v});
        try objects.append(.{ .soname = v[0..eq], .data = pack_common.readAll(alloc, v[eq + 1 ..]) });
    }
    checkOrder(alloc, owners, objects.items) catch |e| switch (e) {
        error.Refused => fail("{s}", .{why}),
        else => return e,
    };
    const text = packagedReadme(alloc, pack_common.readAll(alloc, src), c) catch |e| switch (e) {
        error.Refused => fail("{s}: {s}", .{ src, why }),
        else => return e,
    };
    try pack_common.writeFile(std.fs.cwd(), out, text);
    try pack_common.writeFile(std.fs.cwd(), args_out, try argsText(alloc, c));
}

// ---- tests -------------------------------------------------------------------

const t = std.testing;

test "the commands name every owner in the order given, then the static archives on the build line only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try commands(a, &.{ "komira_http_core_native", "komira_crypto_native" }, &.{"komira_log_holder"});
    const s = try section(a, c);
    try t.expect(std.mem.indexOf(u8, s, "```sh komira-link\n" ++
        "mojo run -Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_http_core_native -Xlinker -lkomira_crypto_native prog.mojo\n" ++
        "mojo build -Xlinker -L$CONDA_PREFIX/lib -Xlinker -lkomira_http_core_native -Xlinker -lkomira_crypto_native" ++
        " -Xlinker -lkomira_log_holder -Xlinker -rpath -Xlinker '$ORIGIN/../lib' prog.mojo -o $CONDA_PREFIX/bin/prog\n```\n") != null);
    try t.expectEqualStrings("run\t-Xlinker\nrun\t-L$CONDA_PREFIX/lib\nrun\t-Xlinker\nrun\t-lkomira_http_core_native\nrun\t-Xlinker\nrun\t-lkomira_crypto_native\n" ++
        "build\t-Xlinker\nbuild\t-L$CONDA_PREFIX/lib\nbuild\t-Xlinker\nbuild\t-lkomira_http_core_native\nbuild\t-Xlinker\nbuild\t-lkomira_crypto_native\n" ++
        "build\t-Xlinker\nbuild\t-lkomira_log_holder\nbuild\t-Xlinker\nbuild\t-rpath\nbuild\t-Xlinker\nbuild\t$ORIGIN/../lib\n", try argsText(a, c));
}

test "the packaged README is the source's bytes, then the section: every source line keeps its number" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try commands(a, &.{"komira_metrics_native"}, &.{});
    const src = "# x\n\n```mojo\nprint(1)\n```\n";
    const got = try packagedReadme(a, src, c);
    try t.expect(std.mem.startsWith(u8, got, src));
    try t.expectEqualStrings(try section(a, c), got[src.len..]);
    // a source without a final newline gets one before the section
    const no_nl = try packagedReadme(a, "# x", c);
    try t.expect(std.mem.startsWith(u8, no_nl, "# x\n\n## Linking\n"));
}

test "a source README holding a fence naming the marker is refused; a mention in prose is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try commands(a, &.{"komira_libc_native"}, &.{});
    try t.expectError(error.Refused, packagedReadme(a, "# x\n\n```sh komira-link\nmojo run prog.mojo\n```\n", c));
    try t.expect(std.mem.indexOf(u8, why, "line 3 opens a `komira-link` block") != null);
    try t.expectError(error.Refused, packagedReadme(a, "# x\n\n  ~~~ sh komira-link\n~~~\n", c));
    const prose = "# x\n\nThe packer writes a `sh komira-link` block.\n";
    try t.expect(std.mem.startsWith(u8, try packagedReadme(a, prose, c), prose));
}

test "no owner and no static, a name twice, or a name that is not one shell word is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.Refused, commands(a, &.{}, &.{}));
    try t.expectError(error.Refused, commands(a, &.{ "komira_fs_native", "komira_fs_native" }, &.{}));
    try t.expectError(error.Refused, commands(a, &.{"komira fs"}, &.{}));
    try t.expectError(error.Refused, commands(a, &.{}, &.{"x;y"}));
}

test "every owner a shared library NEEDs must come after it; a NEEDED name no owner has is not ordered" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const http = try conda_lib.testElf(a, &.{ "libkomira_crypto_native.so.1", "libc.so.6" });
    const crypto = try conda_lib.testElf(a, &.{"libc.so.6"});
    const objs = [_]SharedObject{
        .{ .soname = "libkomira_http_core_native.so.1", .data = http },
        .{ .soname = "libkomira_crypto_native.so.1", .data = crypto },
    };
    // dependents first: passes
    try checkOrder(a, &.{ "komira_http_core_native", "komira_async_native", "komira_crypto_native" }, &objs);
    // the order backwards (rank ascending): refused naming both
    try t.expectError(error.Refused, checkOrder(a, &.{ "komira_crypto_native", "komira_async_native", "komira_http_core_native" }, &objs));
    try t.expectEqualStrings("readme-link: libkomira_http_core_native.so.1 has NEEDED libkomira_crypto_native.so.1, so -lkomira_crypto_native must come after -lkomira_http_core_native, but the owners are given komira_crypto_native first (dependents first is the order the README states)", why);
    // an object that is no owner, or no ELF file, is refused
    try t.expectError(error.Refused, checkOrder(a, &.{"komira_crypto_native"}, objs[0..1]));
    const not_elf = [_]SharedObject{.{ .soname = "libkomira_crypto_native.so.1", .data = "!<arch>\n" }};
    try t.expectError(error.Refused, checkOrder(a, &.{"komira_crypto_native"}, &not_elf));
    const bad_name = [_]SharedObject{.{ .soname = "komira_crypto_native.so", .data = crypto }};
    try t.expectError(error.Refused, checkOrder(a, &.{"komira_crypto_native"}, &bad_name));
}
