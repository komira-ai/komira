//! native_so: the reader, export generator and checks of a komira library's
//! own shared library (`native_shared_library`, shared.bzl; README.md, "Each
//! library's shared library"). Every input may be ELF or Mach-O (a `.dylib`,
//! Mach-O objects and their archives): the readers tell them apart by magic
//! (native_elf.zig, native_macho.zig). Every mode is one build action:
//!
//!   native_so dynsym <lib.so> <out.txt>
//!       the shared object's dynamic section and dynamic symbols, with each
//!       symbol's version (native_elf.zig, `writeShared`), or a Mach-O
//!       library's load commands and symbols: the `[dynsym]` sub-target, for
//!       reading;
//!   native_so exports --soname <s> --list <out> --script <out> --report <out>
//!                     [--format elf|macho]
//!                     (--archive <label> <lib.a>)... (--caller <label> <src dir>)...
//!                     (--caller-archive <label> <lib.a>)...
//!       the export list, its version script (with --format macho, the
//!       exported symbols list ld64 takes instead; elf when absent) and a
//!       report (native_checks.zig, `exportList`); a caller archive is a
//!       dependent owner's archive, which calls every name it references and
//!       does not define (`archiveCalls`); exit 1 on a finding;
//!   native_so check <1-7> --result <out.json> --so <lib.so> [options]
//!       one of the checks of native_checks.zig; options as each needs:
//!       1 --list --script; 2 --archive... --caller... --caller-archive...;
//!       3 --weak... --owner <owner.so>...; 4 --soname --owner <owner.so>...;
//!       5 --floor <glibc version, or macOS version for a Mach-O library>;
//!       6 none; 7 --weak...
//!       An --owner is a declared NEEDED owner's shared library, read for its
//!       SONAME (a Mach-O owner's install name) and exports. Check 1 reads
//!       --script as the format of the library wrote it: a version script
//!       for ELF, an exported symbols list for Mach-O.
//!       Writes the validation result and exits 0 when green; prints every
//!       finding and exits 1 when red.
//!
//!   native_so loader --result <out.json> --so <lib> [--leave <prefix>]...
//!                    [--export <name>]...
//!       c_shared_lib's check (tools/build/node/defs.bzl; native_checks.zig,
//!       `checkLoader`): every strong undefined symbol is bound to a library
//!       the library loads, or starts with a --leave prefix (the names the
//!       loading program defines: a Node-API addon's `napi_` and `node_api_`),
//!       and the library exports each --export name; written and exit codes
//!       as `check`.
//!
//!   native_so readme --result <out.json> --soname <s> --list <exports.txt>
//!                    --objects <dir>
//!       the README check (docs/design/native_packaging.md, slice 10):
//!       green when some object in <dir>, the owning library's README
//!       programs compiled to objects (its `[tests][readme][objects]`),
//!       references or defines one name of the export list (native_checks.zig, `checkReadme`);
//!       written and exit codes as `check`.
//!
//! Exit 2: a usage error, or an input it cannot read (native_elf.zig).

const std = @import("std");
const elf = @import("native_elf.zig");
const calls = @import("native_callsites.zig");
const checks = @import("native_checks.zig");

const Alloc = std.mem.Allocator;

fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("native_so: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn readFile(alloc: Alloc, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 1 << 31) catch |err|
        usage("cannot read {s}: {s}", .{ path, @errorName(err) });
}

fn writeFile(path: []const u8, data: []const u8) void {
    var f = std.fs.cwd().createFile(path, .{}) catch |err| usage("cannot write {s}: {s}", .{ path, @errorName(err) });
    defer f.close();
    f.writeAll(data) catch |err| usage("cannot write {s}: {s}", .{ path, @errorName(err) });
}

fn readShared(alloc: Alloc, path: []const u8) elf.Shared {
    return elf.readShared(alloc, readFile(alloc, path)) catch |err| switch (err) {
        error.BadObject => usage("{s}: {s}", .{ path, elf.why }),
        else => usage("{s}: {s}", .{ path, @errorName(err) }),
    };
}

const Opts = struct {
    soname: ?[]const u8 = null,
    list: ?[]const u8 = null,
    script: ?[]const u8 = null,
    report: ?[]const u8 = null,
    result: ?[]const u8 = null,
    so: ?[]const u8 = null,
    floor: ?[]const u8 = null,
    objects: ?[]const u8 = null,
    format: ?[]const u8 = null,
    weak: std.ArrayList([]const u8),
    leave: std.ArrayList([]const u8),
    exports: std.ArrayList([]const u8),
    owners: std.ArrayList(checks.Owner),
    archives: std.ArrayList(checks.Archive),
    callers: std.ArrayList(checks.Caller),
};

fn need(v: ?[]const u8, what: []const u8) []const u8 {
    return v orelse usage("{s} is required", .{what});
}

fn parse(alloc: Alloc, argv: []const []const u8) !Opts {
    var o = Opts{
        .weak = std.ArrayList([]const u8).empty,
        .leave = std.ArrayList([]const u8).empty,
        .exports = std.ArrayList([]const u8).empty,
        .owners = std.ArrayList(checks.Owner).empty,
        .archives = std.ArrayList(checks.Archive).empty,
        .callers = std.ArrayList(checks.Caller).empty,
    };
    var i: usize = 0;
    while (i < argv.len) {
        const a = argv[i];
        const one = [_][]const u8{ "--soname", "--list", "--script", "--report", "--result", "--so", "--floor", "--weak", "--objects", "--format", "--leave", "--export" };
        var matched = false;
        for (one) |flag| {
            if (!std.mem.eql(u8, a, flag)) continue;
            if (i + 1 >= argv.len) usage("{s} needs a value", .{a});
            const v = argv[i + 1];
            if (std.mem.eql(u8, flag, "--soname")) o.soname = v;
            if (std.mem.eql(u8, flag, "--list")) o.list = v;
            if (std.mem.eql(u8, flag, "--script")) o.script = v;
            if (std.mem.eql(u8, flag, "--report")) o.report = v;
            if (std.mem.eql(u8, flag, "--result")) o.result = v;
            if (std.mem.eql(u8, flag, "--so")) o.so = v;
            if (std.mem.eql(u8, flag, "--floor")) o.floor = v;
            if (std.mem.eql(u8, flag, "--objects")) o.objects = v;
            if (std.mem.eql(u8, flag, "--format")) o.format = v;
            if (std.mem.eql(u8, flag, "--weak")) try o.weak.append(alloc, v);
            if (std.mem.eql(u8, flag, "--leave")) try o.leave.append(alloc, v);
            if (std.mem.eql(u8, flag, "--export")) try o.exports.append(alloc, v);
            i += 2;
            matched = true;
        }
        if (matched) continue;
        if (std.mem.eql(u8, a, "--owner")) {
            if (i + 1 >= argv.len) usage("--owner needs a shared library", .{});
            const path = argv[i + 1];
            const so = readShared(alloc, path);
            const soname = so.soname orelse usage("--owner {s}: no SONAME", .{path});
            try o.owners.append(alloc, try checks.ownerOf(alloc, soname, so));
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, a, "--archive") or std.mem.eql(u8, a, "--caller") or std.mem.eql(u8, a, "--caller-archive")) {
            if (i + 2 >= argv.len) usage("{s} needs a label and a path", .{a});
            const label = argv[i + 1];
            const path = argv[i + 2];
            if (std.mem.eql(u8, a, "--caller")) {
                try o.callers.append(alloc, .{ .label = label, .calls = try calls.scanDir(alloc, path) });
            } else {
                const syms = elf.readArchive(alloc, readFile(alloc, path)) catch |err| switch (err) {
                    error.BadObject => usage("{s} ({s}): {s}", .{ path, label, elf.why }),
                    else => usage("{s}: {s}", .{ path, @errorName(err) }),
                };
                if (std.mem.eql(u8, a, "--archive")) {
                    try o.archives.append(alloc, .{ .label = label, .syms = syms });
                } else try o.callers.append(alloc, try checks.archiveCalls(alloc, label, syms));
            }
            i += 3;
            continue;
        }
        usage("unknown argument {s}", .{a});
    }
    return o;
}

fn finish(what: []const u8, soname: []const u8, red: checks.Red) void {
    if (red.green()) return;
    std.debug.print("native_so: {s} of {s} RED:\n", .{ what, soname });
    for (red.lines.items) |l| std.debug.print("  {s}\n", .{l});
    std.process.exit(1);
}

const titles = [_][]const u8{
    "check 1 (exports: komira_ prefix, exactly the list)",
    "check 2 (every called name exported)",
    "check 3 (undefined komira_ symbols: a declared NEEDED owner exports each)",
    "check 4 (SONAME, NEEDED glibc and the declared owners, run path)",
    "check 5 (glibc version floor)",
    "check 6 (DT_FLAGS DF_SYMBOLIC)",
    "check 7 (undefined symbols: GLIBC_, komira_ or the weak list)",
};

/// The titles of checks 4 to 7 for a Mach-O library (1 to 3 are the same).
const macho_titles = [_][]const u8{
    "check 4 (install name, loaded system dylibs and the declared owners, LC_RPATH)",
    "check 5 (minimum macOS version floor)",
    "check 6 (two-level namespace, no exported weak definition)",
    "check 7 (undefined symbols: bound to a system dylib, komira_ or the weak list)",
};

fn checkTitle(so: elf.Shared, n: u8) []const u8 {
    return if (so.format == .macho and n >= 4) macho_titles[n - 4] else titles[n - 1];
}

/// What `exports --format` names: the file --script holds.
fn scriptFormat(v: ?[]const u8) elf.Format {
    const f = v orelse return .elf;
    if (std.mem.eql(u8, f, "elf")) return .elf;
    if (std.mem.eql(u8, f, "macho")) return .macho;
    usage("--format {s} is not elf or macho", .{f});
}

const readme_title = "README check (a README program calls the library's C)";

fn writeResult(alloc: Alloc, path: []const u8, soname: []const u8, title: []const u8, msg: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(alloc);
    const w = &out.writer;
    try w.writeAll("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": ");
    try std.json.Stringify.encodeJsonString(try std.fmt.allocPrint(alloc, "{s} {s}: {s}", .{ soname, title, msg }), .{}, w);
    try w.writeAll("}}\n");
    writeFile(path, out.written());
    std.debug.print("native_so: {s} {s} GREEN: {s}\n", .{ soname, title, msg });
}

/// The README programs' objects in `dir`, by file name.
fn readPrograms(alloc: Alloc, dir_path: []const u8) ![]checks.Program {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| usage("cannot read {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| try names.append(alloc, try alloc.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var out = std.ArrayList(checks.Program).empty;
    for (names.items) |n| {
        const path = try std.fs.path.join(alloc, &.{ dir_path, n });
        const syms = elf.readProgram(alloc, readFile(alloc, path)) catch |err| switch (err) {
            error.BadObject => usage("{s}: {s}", .{ path, elf.why }),
            else => usage("{s}: {s}", .{ path, @errorName(err) }),
        };
        try out.append(alloc, .{ .name = n, .syms = syms });
    }
    return out.toOwnedSlice(alloc);
}

/// The `exports` mode, over its arguments (argv after `exports`): reads the
/// --archive, --caller and --caller-archive inputs, and writes --list,
/// --script (as --format says) and --report. Exits 1 on a finding and 2 on
/// a usage error, as every mode does.
fn runExports(alloc: Alloc, args: []const []const u8) !void {
    const o = try parse(alloc, args);
    if (o.archives.items.len == 0) usage("exports: no --archive", .{});
    if (o.callers.items.len == 0) usage("exports: no --caller", .{});
    const soname = need(o.soname, "--soname");
    var red = checks.Red.init(alloc);
    const e = try checks.exportList(alloc, o.archives.items, o.callers.items, &red);
    finish("the export list", soname, red);
    var list = std.ArrayList(u8).empty;
    for (e.names) |n| try list.writer(alloc).print("{s}\n", .{n});
    writeFile(need(o.list, "--list"), list.items);
    writeFile(need(o.script, "--script"), switch (scriptFormat(o.format)) {
        .elf => try checks.versionScript(alloc, soname, e.names),
        .macho => try checks.exportedSymbolsList(alloc, e.names),
    });
    writeFile(need(o.report, "--report"), e.report);
}

const loader_title = "loader check (undefined symbols left to the loading program, and the required exports)";

/// What the `loader` mode found: the library's name for messages, the
/// green message and the --result path.
const Loader = struct { soname: []const u8, msg: []const u8, result: []const u8 };

/// The `loader` mode over its arguments (argv after `loader`): reads --so
/// and adds to `red` what `checks.checkLoader` finds against the --leave
/// prefixes and the --export names. `main` exits 1 when `red` has a line
/// and otherwise writes --result.
fn runLoader(alloc: Alloc, args: []const []const u8, red: *checks.Red) !Loader {
    const o = try parse(alloc, args);
    const result = need(o.result, "--result");
    const so_path = need(o.so, "--so");
    const so = readShared(alloc, so_path);
    const msg = try checks.checkLoader(alloc, so, o.leave.items, o.exports.items, red);
    return .{ .soname = std.fs.path.basename(so_path), .msg = msg, .result = result };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) usage("usage: native_so dynsym|exports|check|loader|readme ... (see native_so.zig)", .{});
    const mode = argv[1];

    if (std.mem.eql(u8, mode, "dynsym")) {
        if (argv.len != 4) usage("usage: native_so dynsym <lib.so> <out.txt>", .{});
        var b = std.ArrayList(u8).empty;
        try elf.writeShared(b.writer(alloc), readShared(alloc, argv[2]));
        writeFile(argv[3], b.items);
        return;
    }

    if (std.mem.eql(u8, mode, "exports")) return runExports(alloc, argv[2..]);

    if (std.mem.eql(u8, mode, "loader")) {
        var red = checks.Red.init(alloc);
        const l = try runLoader(alloc, argv[2..], &red);
        finish(loader_title, l.soname, red);
        try writeResult(alloc, l.result, l.soname, loader_title, l.msg);
        return;
    }

    if (std.mem.eql(u8, mode, "readme")) {
        const o = try parse(alloc, argv[2..]);
        const soname = need(o.soname, "--soname");
        const exports = try checks.lines(alloc, readFile(alloc, need(o.list, "--list")));
        const programs = try readPrograms(alloc, need(o.objects, "--objects"));
        var red = checks.Red.init(alloc);
        const msg = try checks.checkReadme(alloc, exports, programs, &red);
        finish(readme_title, soname, red);
        try writeResult(alloc, need(o.result, "--result"), soname, readme_title, msg);
        return;
    }

    if (!std.mem.eql(u8, mode, "check") or argv.len < 3) usage("usage: native_so check <1-7> --result <out.json> --so <lib.so> ...", .{});
    const n = std.fmt.parseInt(u8, argv[2], 10) catch usage("check: {s} is not 1 to 7", .{argv[2]});
    if (n < 1 or n > 7) usage("check: {d} is not 1 to 7", .{n});
    const o = try parse(alloc, argv[3..]);
    const so_path = need(o.so, "--so");
    const so = readShared(alloc, so_path);
    const soname = so.soname orelse so_path;
    var red = checks.Red.init(alloc);
    const msg = switch (n) {
        1 => try checks.check1(
            alloc,
            so,
            try checks.lines(alloc, readFile(alloc, need(o.list, "--list"))),
            switch (so.format) {
                .elf => try checks.scriptGlobals(alloc, readFile(alloc, need(o.script, "--script"))),
                .macho => try checks.symbolsListNames(alloc, readFile(alloc, need(o.script, "--script"))),
            },
            &red,
        ),
        2 => blk: {
            if (o.archives.items.len == 0 or o.callers.items.len == 0) usage("check 2 needs --archive and --caller", .{});
            break :blk try checks.check2(alloc, so, o.archives.items, o.callers.items, &red);
        },
        3 => try checks.check3(alloc, so, o.weak.items, o.owners.items, &red),
        4 => blk: {
            var sonames = std.ArrayList([]const u8).empty;
            for (o.owners.items) |ow| try sonames.append(alloc, ow.soname);
            break :blk try checks.check4(alloc, so, need(o.soname, "--soname"), sonames.items, &red);
        },
        5 => try checks.check5(alloc, so, need(o.floor, "--floor"), &red),
        6 => try checks.check6(alloc, so, &red),
        else => try checks.check7(alloc, so, o.weak.items, &red),
    };
    finish(checkTitle(so, n), soname, red);
    try writeResult(alloc, need(o.result, "--result"), soname, checkTitle(so, n), msg);
}

test "a Mach-O library's checks 4 to 7 carry their Mach-O titles; 1 to 3 and an ELF library's keep theirs" {
    const mac = elf.Shared{ .format = .macho };
    try std.testing.expectEqualStrings(titles[0], checkTitle(mac, 1));
    try std.testing.expectEqualStrings(titles[2], checkTitle(mac, 3));
    try std.testing.expectEqualStrings("check 4 (install name, loaded system dylibs and the declared owners, LC_RPATH)", checkTitle(mac, 4));
    try std.testing.expectEqualStrings("check 7 (undefined symbols: bound to a system dylib, komira_ or the weak list)", checkTitle(mac, 7));
    try std.testing.expectEqualStrings(titles[3], checkTitle(.{}, 4));
}

test "exports --format: absent and elf write a version script, macho an exported symbols list" {
    try std.testing.expectEqual(elf.Format.elf, scriptFormat(null));
    try std.testing.expectEqual(elf.Format.elf, scriptFormat("elf"));
    try std.testing.expectEqual(elf.Format.macho, scriptFormat("macho"));
}

/// `path` inside the scratch directory `root`.
fn inDir(alloc: Alloc, root: []const u8, path: []const u8) ![]const u8 {
    return std.fs.path.join(alloc, &.{ root, path });
}

test "exports, run from its arguments: --format macho writes the `_`-prefixed exported symbols list; absent or elf, the version script" {
    const mt = @import("native_macho_test.zig");
    const A = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A Mach-O archive defining two names the caller calls, and one private
    // external name it does not; the caller's source calls the two.
    try tmp.dir.writeFile(.{ .sub_path = "libt.a", .data = mt.bsdArchive(&.{.{ .name = "t.o", .body = mt.object(&.{
        .{ .name = "_komira_t_f", .ty = mt.N_SECT_EXT },
        .{ .name = "_komira_t_g", .ty = mt.N_SECT_EXT },
        .{ .name = "_komira_t_private", .ty = 0x1f },
    }) }}) });
    try tmp.dir.makeDir("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/t.mojo", .data = "fn f():\n    _ = external_call[\"komira_t_f\", Int]()\n    _ = external_call[\"komira_t_g\", Int]()\n" });
    const root = try tmp.dir.realpathAlloc(A, ".");

    const version_script =
        "/* libkomira_t_native.so.1: generated by tools/build/native/native_so.zig (exports).\n" ++
        "   The callers' external_call names its archives define; every other symbol is local. */\n" ++
        "{\n  global:\n    komira_t_f;\n    komira_t_g;\n  local:\n    *;\n};\n";
    const runs = [_]struct { format: ?[]const u8, script: []const u8 }{
        .{ .format = null, .script = version_script },
        .{ .format = "elf", .script = version_script },
        .{ .format = "macho", .script = "_komira_t_f\n_komira_t_g\n" },
    };
    for (runs, 0..) |r, i| {
        const list = try inDir(A, root, try std.fmt.allocPrint(A, "exports_{d}.txt", .{i}));
        const script = try inDir(A, root, try std.fmt.allocPrint(A, "script_{d}", .{i}));
        const report = try inDir(A, root, try std.fmt.allocPrint(A, "report_{d}.txt", .{i}));
        var args = std.ArrayList([]const u8).empty;
        try args.appendSlice(A, &.{ "--soname", "libkomira_t_native.so.1", "--list", list, "--script", script, "--report", report });
        if (r.format) |f| try args.appendSlice(A, &.{ "--format", f });
        try args.appendSlice(A, &.{ "--archive", "//t:t", try inDir(A, root, "libt.a"), "--caller", "//t:lib", try inDir(A, root, "src") });
        // Returning is the green exit: a finding exits 1 and a usage error 2.
        try runExports(A, args.items);
        try std.testing.expectEqualStrings("komira_t_f\nkomira_t_g\n", try std.fs.cwd().readFileAlloc(A, list, 1 << 20));
        const written = try std.fs.cwd().readFileAlloc(A, script, 1 << 20);
        try std.testing.expectEqualStrings(r.script, written);
        if (r.format != null and std.mem.eql(u8, r.format.?, "macho")) {
            // What check 1 reads back from the list it wrote is the export list.
            const back = try checks.symbolsListNames(A, written);
            try std.testing.expectEqual(@as(usize, 2), back.len);
            try std.testing.expectEqualStrings("komira_t_f", back[0]);
            try std.testing.expectEqualStrings("komira_t_g", back[1]);
        }
        try std.testing.expectEqualStrings(
            "2 exports, from 1 callers and 1 archives\narchives (exports each defines):\n  //t:t: 2\n" ++
                "callers (exports each calls, of its call-site names):\n  //t:lib: 2 of 2\n",
            try std.fs.cwd().readFileAlloc(A, report, 1 << 20),
        );
    }
}

test "loader, run from its arguments: --leave and --export reach the check, and an addon leaving another name to node is red" {
    const mt = @import("native_macho_test.zig");
    const A = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ids = [_][]const u8{"@rpath/komira_addon.node"};
    const loads = [_]mt.Load{.{ .name = "/usr/lib/libSystem.B.dylib" }};
    const good = [_]mt.NSym{
        .{ .name = "_napi_register_module_v1", .ty = mt.N_SECT_EXT },
        .{ .name = "_strlen", .ty = 0x01, .desc = 0x0100 },
        .{ .name = "_napi_get_undefined", .ty = 0x01, .desc = 0xfe00 },
    };
    try tmp.dir.writeFile(.{ .sub_path = "good.node", .data = mt.dylib(.{ .ids = &ids, .loads = &loads, .rpaths = &.{}, .syms = &good }) });
    const missing = good ++ [_]mt.NSym{.{ .name = "_arrow_result_value", .ty = 0x01, .desc = 0xfe00 }};
    try tmp.dir.writeFile(.{ .sub_path = "missing.node", .data = mt.dylib(.{ .ids = &ids, .loads = &loads, .rpaths = &.{}, .syms = &missing }) });
    const root = try tmp.dir.realpathAlloc(A, ".");
    const result = try inDir(A, root, "result.json");

    var red = checks.Red.init(A);
    const l = try runLoader(A, &.{ "--result", result, "--so", try inDir(A, root, "good.node"), "--leave", "napi_", "--leave", "node_api_", "--export", "napi_register_module_v1" }, &red);
    try std.testing.expect(red.green());
    try std.testing.expectEqualStrings("good.node", l.soname);
    try std.testing.expectEqualStrings(result, l.result);
    try std.testing.expectEqualStrings("1 strong undefined symbols bound to the libraries it loads and 1 left to the loading program, all napi_* or node_api_*; exports the 1 required", l.msg);

    red = checks.Red.init(A);
    _ = try runLoader(A, &.{ "--result", result, "--so", try inDir(A, root, "missing.node"), "--leave", "napi_", "--leave", "node_api_", "--export", "napi_register_module_v1" }, &red);
    try std.testing.expectEqual(@as(usize, 1), red.lines.items.len);
    try std.testing.expectEqualStrings("strong undefined symbols left to the loading program that are not napi_* or node_api_* (1): arrow_result_value", red.lines.items[0]);

    // No --leave: the same good addon leaves a Node-API name, and is red.
    red = checks.Red.init(A);
    _ = try runLoader(A, &.{ "--result", result, "--so", try inDir(A, root, "good.node") }, &red);
    try std.testing.expectEqual(@as(usize, 1), red.lines.items.len);
    try std.testing.expectEqualStrings("strong undefined symbols left to the loading program, which may define none of them (1): napi_get_undefined", red.lines.items[0]);
}

test {
    _ = @import("native_so_test.zig");
    _ = @import("native_elf_test.zig");
    _ = @import("native_macho_test.zig");
    _ = @import("native_loader_test.zig");
}
