//! public_boundary: the validation behind the public_boundary rule
//! (tools/build/lint/defs.bzl). check.zig says what is read and the ledger
//! formats; rules.zig says what each rule matches.
//!
//! usage: public_boundary --tree <dir> --prefix <name prefix>
//!            --holds <file> --holds-name <name> --hosts <file> --hosts-name <name>
//!            [--deny <file>] --from <year> --public <YYYY-MM-01> --out <file>
//!
//! Reads every file of <dir> (the tree, each file at its path in it) and
//! writes <file>, the validation result Buck2 reads: status "failure" with
//! the findings as the message when there are any, "success" with the number
//! of files read otherwise. A finding names its file <name prefix><path>; the
//! ledgers are named by their <name>s.
//!
//! Exit status: 0 the result is written (either status); 1 the tree or a
//! ledger cannot be read, or the result cannot be written; 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");
const check = @import("check.zig");

const usage =
    \\usage: public_boundary --tree <dir> --prefix <name prefix>
    \\           --holds <file> --holds-name <name> --hosts <file> --hosts-name <name>
    \\           [--deny <file>] --from <year> --public <YYYY-MM-01> --out <file>
    \\
;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("public_boundary: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("public_boundary: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const FLAGS = [_][]const u8{ "--tree", "--prefix", "--holds", "--holds-name", "--hosts", "--hosts-name", "--deny", "--from", "--public", "--out" };

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});

    var values: [FLAGS.len]?[]const u8 = .{null} ** FLAGS.len;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usageFail("{s} needs a value", .{argv[i]});
        const slot = for (FLAGS, 0..) |f, k| {
            if (std.mem.eql(u8, argv[i], f)) break k;
        } else usageFail("unknown argument {s}", .{argv[i]});
        if (values[slot] != null) usageFail("{s} given twice", .{argv[i]});
        values[slot] = argv[i + 1];
    }
    for (FLAGS, values) |f, v| {
        if (v == null and !std.mem.eql(u8, f, "--deny")) usageFail("{s} is required", .{f});
    }
    const tree_path = values[0].?;
    const out_path = values[9].?;
    const cfg = check.Config{
        .prefix = values[1].?,
        .holds_name = values[3].?,
        .hosts_name = values[5].?,
        .from = values[7].?,
        .public = values[8].?,
    };
    const ledgers = check.Ledgers{
        .holds = readFile(alloc, values[2].?),
        .hosts = readFile(alloc, values[4].?),
        .deny = if (values[6]) |d| readFile(alloc, d) else "",
    };

    var dir = std.fs.cwd().openDir(tree_path, .{ .iterate = true }) catch |err|
        fail("cannot open the tree {s}: {s}", .{ tree_path, @errorName(err) });
    defer dir.close();
    const paths = check.list(alloc, dir) catch |err|
        fail("cannot read the tree {s}: {s}", .{ tree_path, @errorName(err) });
    // File contents are freed as soon as each is read, so the arena holds
    // only the paths and the findings.
    const reader = check.DirReader{ .dir = dir, .alloc = std.heap.page_allocator };
    const report = check.run(alloc, cfg, ledgers, paths, reader) catch |err|
        fail("cannot check the tree: {s}", .{@errorName(err)});
    const json = check.result(alloc, report) catch fail("out of memory", .{});
    std.fs.cwd().writeFile(out_path, json) catch |err|
        fail("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    if (report.lines.len > 0) {
        for (report.lines[0..@min(report.lines.len, 200)]) |l| std.debug.print("{s}\n", .{l});
    }
}

fn readFile(alloc: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 1 << 26) catch |err|
        fail("cannot read {s}: {s}", .{ path, @errorName(err) });
}
