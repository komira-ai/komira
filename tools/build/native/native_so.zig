//! native_so: the reader, export generator and checks of a komira library's
//! own shared library (`native_shared_library`, shared.bzl; README.md, "Each
//! library's shared library"). Every mode is one build action:
//!
//!   native_so dynsym <lib.so> <out.txt>
//!       the shared object's dynamic section and dynamic symbols, with each
//!       symbol's version (native_elf.zig, `writeShared`): the `[dynsym]`
//!       sub-target, for reading;
//!   native_so exports --soname <s> --list <out> --script <out> --report <out>
//!                     (--archive <label> <lib.a>)... (--caller <label> <src dir>)...
//!       the export list, its version script and a report (native_checks.zig,
//!       `exportList`); exit 1 on a finding;
//!   native_so check <1-7> --result <out.json> --so <lib.so> [options]
//!       one of the checks of native_checks.zig; options as each needs:
//!       1 --list --script; 2 --archive... --caller...; 3 --weak...;
//!       4 --soname; 5 --floor <glibc version>; 6 none; 7 --weak...
//!       Writes the validation result and exits 0 when green; prints every
//!       finding and exits 1 when red.
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
        error.BadElf => usage("{s}: {s}", .{ path, elf.why }),
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
    weak: std.ArrayList([]const u8),
    archives: std.ArrayList(checks.Archive),
    callers: std.ArrayList(checks.Caller),
};

fn need(v: ?[]const u8, what: []const u8) []const u8 {
    return v orelse usage("{s} is required", .{what});
}

fn parse(alloc: Alloc, argv: []const []const u8) !Opts {
    var o = Opts{
        .weak = std.ArrayList([]const u8).init(alloc),
        .archives = std.ArrayList(checks.Archive).init(alloc),
        .callers = std.ArrayList(checks.Caller).init(alloc),
    };
    var i: usize = 0;
    while (i < argv.len) {
        const a = argv[i];
        const one = [_][]const u8{ "--soname", "--list", "--script", "--report", "--result", "--so", "--floor", "--weak" };
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
            if (std.mem.eql(u8, flag, "--weak")) try o.weak.append(v);
            i += 2;
            matched = true;
        }
        if (matched) continue;
        if (std.mem.eql(u8, a, "--archive") or std.mem.eql(u8, a, "--caller")) {
            if (i + 2 >= argv.len) usage("{s} needs a label and a path", .{a});
            const label = argv[i + 1];
            const path = argv[i + 2];
            if (a[2] == 'a') {
                const syms = elf.readArchive(alloc, readFile(alloc, path)) catch |err| switch (err) {
                    error.BadElf => usage("{s} ({s}): {s}", .{ path, label, elf.why }),
                    else => usage("{s}: {s}", .{ path, @errorName(err) }),
                };
                try o.archives.append(.{ .label = label, .syms = syms });
            } else {
                try o.callers.append(.{ .label = label, .calls = try calls.scanDir(alloc, path) });
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
    "check 3 (undefined komira_ symbols)",
    "check 4 (SONAME, NEEDED, run path)",
    "check 5 (glibc version floor)",
    "check 6 (DT_FLAGS DF_SYMBOLIC)",
    "check 7 (undefined symbols: GLIBC_, komira_ or the weak list)",
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) usage("usage: native_so dynsym|exports|check ... (see native_so.zig)", .{});
    const mode = argv[1];

    if (std.mem.eql(u8, mode, "dynsym")) {
        if (argv.len != 4) usage("usage: native_so dynsym <lib.so> <out.txt>", .{});
        var b = std.ArrayList(u8).init(alloc);
        try elf.writeShared(b.writer(), readShared(alloc, argv[2]));
        writeFile(argv[3], b.items);
        return;
    }

    if (std.mem.eql(u8, mode, "exports")) {
        const o = try parse(alloc, argv[2..]);
        if (o.archives.items.len == 0) usage("exports: no --archive", .{});
        if (o.callers.items.len == 0) usage("exports: no --caller", .{});
        const soname = need(o.soname, "--soname");
        var red = checks.Red.init(alloc);
        const e = try checks.exportList(alloc, o.archives.items, o.callers.items, &red);
        finish("the export list", soname, red);
        var list = std.ArrayList(u8).init(alloc);
        for (e.names) |n| try list.writer().print("{s}\n", .{n});
        writeFile(need(o.list, "--list"), list.items);
        writeFile(need(o.script, "--script"), try checks.versionScript(alloc, soname, e.names));
        writeFile(need(o.report, "--report"), e.report);
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
            try checks.scriptGlobals(alloc, readFile(alloc, need(o.script, "--script"))),
            &red,
        ),
        2 => blk: {
            if (o.archives.items.len == 0 or o.callers.items.len == 0) usage("check 2 needs --archive and --caller", .{});
            break :blk try checks.check2(alloc, so, o.archives.items, o.callers.items, &red);
        },
        3 => try checks.check3(alloc, so, o.weak.items, &red),
        4 => try checks.check4(alloc, so, need(o.soname, "--soname"), &red),
        5 => try checks.check5(alloc, so, need(o.floor, "--floor"), &red),
        6 => try checks.check6(alloc, so, &red),
        else => try checks.check7(alloc, so, o.weak.items, &red),
    };
    finish(titles[n - 1], soname, red);
    var out = std.ArrayList(u8).init(alloc);
    const w = out.writer();
    try w.writeAll("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": ");
    try std.json.encodeJsonString(try std.fmt.allocPrint(alloc, "{s} {s}: {s}", .{ soname, titles[n - 1], msg }), .{}, w);
    try w.writeAll("}}\n");
    writeFile(need(o.result, "--result"), out.items);
    std.debug.print("native_so: {s} {s} GREEN: {s}\n", .{ soname, titles[n - 1], msg });
}

test {
    _ = @import("native_so_test.zig");
}
