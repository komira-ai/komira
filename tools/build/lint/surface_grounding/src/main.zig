//! surface_grounding: the validation of the surface capability matrix lint
//! that reads files (grounding.zig says what it checks).
//!
//! usage: surface_grounding --grounding <dir> --families <families.tsv>
//!            --named <named.tsv> --totals <line> --out <file>
//!            [--got <file> --want <file> --want-name <name>]...
//!
//! <families.tsv>: `path<TAB>prefixes` per line, a grounding file's path
//! under <dir> and its comma-separated identifier prefixes (`-` for none).
//! <named.tsv>: `what<TAB>identifier` per line, every grounding identifier a
//! capability or a not_capabilities row names. Each `--got` is compared with
//! the `--want` and `--want-name` of the same position. <file> is the
//! validation result Buck2 reads: status "failure" with the findings, else
//! "success" with <totals>, the census's totals line.
//!
//! Exit status: 0 the result is written (either status); 1 an input cannot
//! be read, or the result cannot be written; 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");
const g = @import("grounding.zig");

const usage =
    \\usage: surface_grounding --grounding <dir> --families <tsv> --named <tsv> --totals <line> --out <file>
    \\           [--got <file> --want <file> --want-name <name>]...
    \\
;

/// The most finding lines the result's message holds.
const max_message_lines = 200;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("surface_grounding: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("surface_grounding: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn read(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) []const u8 {
    return dir.readFileAlloc(alloc, path, 1 << 28) catch |err|
        fail("cannot read {s}: {s}", .{ path, @errorName(err) });
}

/// The lines of a TSV input, each split at its first tab.
fn pairs(alloc: std.mem.Allocator, text: []const u8, what: []const u8) [][2][]const u8 {
    var list = std.ArrayList([2][]const u8).init(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse fail("{s}: a line with no tab: {s}", .{ what, line });
        list.append(.{ line[0..tab], line[tab + 1 ..] }) catch fail("out of memory", .{});
    }
    return list.items;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});

    var grounding: ?[]const u8 = null;
    var families_path: ?[]const u8 = null;
    var named_path: ?[]const u8 = null;
    var totals: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var got = std.ArrayList([]const u8).init(alloc);
    var want = std.ArrayList([]const u8).init(alloc);
    var want_name = std.ArrayList([]const u8).init(alloc);
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usageFail("{s} needs a value", .{argv[i]});
        const v = argv[i + 1];
        const a = argv[i];
        if (std.mem.eql(u8, a, "--grounding")) {
            grounding = v;
        } else if (std.mem.eql(u8, a, "--families")) {
            families_path = v;
        } else if (std.mem.eql(u8, a, "--named")) {
            named_path = v;
        } else if (std.mem.eql(u8, a, "--totals")) {
            totals = v;
        } else if (std.mem.eql(u8, a, "--out")) {
            out = v;
        } else if (std.mem.eql(u8, a, "--got")) {
            got.append(v) catch fail("out of memory", .{});
        } else if (std.mem.eql(u8, a, "--want")) {
            want.append(v) catch fail("out of memory", .{});
        } else if (std.mem.eql(u8, a, "--want-name")) {
            want_name.append(v) catch fail("out of memory", .{});
        } else usageFail("unknown argument {s}", .{a});
    }
    const ground_path = grounding orelse usageFail("--grounding is required", .{});
    const fam_path = families_path orelse usageFail("--families is required", .{});
    const nam_path = named_path orelse usageFail("--named is required", .{});
    const totals_line = totals orelse usageFail("--totals is required", .{});
    const out_path = out orelse usageFail("--out is required", .{});
    if (got.items.len != want.items.len or got.items.len != want_name.items.len)
        usageFail("--got, --want and --want-name come in threes", .{});

    const cwd = std.fs.cwd();
    var ground = cwd.openDir(ground_path, .{}) catch |err|
        fail("cannot open {s}: {s}", .{ ground_path, @errorName(err) });
    defer ground.close();

    const fam_rows = pairs(alloc, read(alloc, cwd, fam_path), fam_path);
    const families = alloc.alloc(g.Family, fam_rows.len) catch fail("out of memory", .{});
    for (fam_rows, 0..) |r, k| {
        var prefixes = std.ArrayList([]const u8).init(alloc);
        if (!std.mem.eql(u8, r[1], "-")) {
            var it = std.mem.splitScalar(u8, r[1], ',');
            while (it.next()) |p| prefixes.append(p) catch fail("out of memory", .{});
        }
        families[k] = .{ .path = r[0], .prefixes = prefixes.items, .data = read(alloc, ground, r[0]) };
    }
    const nam_rows = pairs(alloc, read(alloc, cwd, nam_path), nam_path);
    const named = alloc.alloc(g.Named, nam_rows.len) catch fail("out of memory", .{});
    for (nam_rows, 0..) |r, k| named[k] = .{ .what = r[0], .id = r[1] };

    var report = std.ArrayList(u8).init(alloc);
    var count = g.check(alloc, families, named, &report) catch fail("out of memory", .{});
    for (got.items, want.items, want_name.items) |gp, wp, wn| {
        count += g.compare(alloc, read(alloc, cwd, gp), read(alloc, cwd, wp), wn, &report) catch fail("out of memory", .{});
    }

    var message = std.ArrayList(u8).init(alloc);
    const mw = message.writer();
    const status = if (count > 0) "failure" else "success";
    if (count > 0) {
        mw.print("surface_capability_matrix: {d} finding line(s)\n", .{count}) catch fail("out of memory", .{});
        var it = std.mem.splitScalar(u8, report.items, '\n');
        var n: usize = 0;
        while (it.next()) |l| : (n += 1) {
            if (n == max_message_lines or l.len == 0) break;
            mw.print("{s}\n", .{l}) catch fail("out of memory", .{});
        }
    } else {
        mw.print("surface_capability_matrix: {s}", .{totals_line}) catch fail("out of memory", .{});
    }
    var json = std.ArrayList(u8).init(alloc);
    const jw = json.writer();
    jw.print("{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": ", .{status}) catch fail("out of memory", .{});
    std.json.encodeJsonString(message.items, .{}, jw) catch fail("out of memory", .{});
    jw.writeAll("}}\n") catch fail("out of memory", .{});
    cwd.writeFile(out_path, json.items) catch |err|
        fail("cannot write {s}: {s}", .{ out_path, @errorName(err) });
    if (count > 0) std.debug.print("{s}", .{message.items});
}
