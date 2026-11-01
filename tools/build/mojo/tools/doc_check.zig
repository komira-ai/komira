// Why Zig: build tools are Zig (tools/build/README.md). This replaces the
// busybox shell script (cmp, diff, awk, sort, grep) of the `mojo_doc_json`
// check, so that the check runs no shell.
//! doc_check: the checks of `mojo_doc_json` (doc.bzl) on a `mojo doc` JSON.
//!
//! usage: doc_check <json> <golden or -> <inspect dir or -> <out> <label> [<symbol>...]
//!
//! With a golden, the JSON must equal it byte for byte; a difference is shown as
//! the golden's lines with `-` and the JSON's with `+` (the first 40 lines).
//! With symbols, `<inspect>/inspect json <json>` (the JSON as one line per leaf,
//! path elements, key and value, tab-separated) is read for the declarations: an
//! object with a `name` leaf under `decl` / packages / modules / functions /
//! structs / traits / aliases, each followed by its index, is the declaration
//! whose dotted path is the names along the way; every symbol must be one.
//! When every check holds, the JSON is copied to <out>.
//!
//! Exit status: 0; 1 for a failed check (every one is reported first); 2 for a
//! usage error or a failure of the tool's own.

const std = @import("std");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("doc_check: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isKind(s: []const u8) bool {
    for ([_][]const u8{ "packages", "modules", "functions", "structs", "traits", "aliases" }) |k| {
        if (std.mem.eql(u8, s, k)) return true;
    }
    return false;
}

fn isIndex(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// The dotted paths of the declarations in `flat` (inspect's output), sorted
/// and unique.
pub fn declarations(a: std.mem.Allocator, flat: []const u8) ![]const []const u8 {
    var names = std.StringHashMap([]const u8).init(a);
    var objs = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, flat, '\n');
    while (lines.next()) |line| {
        var fields = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, line, '\t');
        while (it.next()) |f| try fields.append(a, f);
        const nf = fields.items.len;
        if (nf < 2 or !std.mem.eql(u8, fields.items[nf - 2], "name")) continue;
        // The object: fields 1 and 2 .. NF-2 (1-based) joined by tabs.
        var obj = std.ArrayList(u8).empty;
        try obj.appendSlice(a, fields.items[0]);
        var i: usize = 1;
        while (i + 2 < nf) : (i += 1) {
            try obj.append(a, '\t');
            try obj.appendSlice(a, fields.items[i]);
        }
        const key = try obj.toOwnedSlice(a);
        try names.put(key, fields.items[nf - 1]);
        try objs.append(a, key);
    }
    var out = std.ArrayList([]const u8).empty;
    for (objs.items) |o| {
        var f = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, o, '\t');
        while (it.next()) |x| try f.append(a, x);
        if (!std.mem.eql(u8, f.items[0], "decl")) continue;
        var key = std.ArrayList(u8).empty;
        try key.appendSlice(a, "decl");
        var path = std.ArrayList(u8).empty;
        var ok = true;
        var i: usize = 1;
        while (i < f.items.len) : (i += 2) {
            if (!isKind(f.items[i]) or i + 1 >= f.items.len or !isIndex(f.items[i + 1])) {
                ok = false;
                break;
            }
            try key.append(a, '\t');
            try key.appendSlice(a, f.items[i]);
            try key.append(a, '\t');
            try key.appendSlice(a, f.items[i + 1]);
            const nm = names.get(key.items) orelse {
                ok = false;
                break;
            };
            if (path.items.len > 0) try path.append(a, '.');
            try path.appendSlice(a, nm);
        }
        if (ok and path.items.len > 0) try out.append(a, try path.toOwnedSlice(a));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    var uniq = std.ArrayList([]const u8).empty;
    for (out.items) |p| {
        if (uniq.items.len == 0 or !std.mem.eql(u8, uniq.items[uniq.items.len - 1], p)) try uniq.append(a, p);
    }
    return uniq.toOwnedSlice(a);
}

/// The lines in which `golden` and `json` differ, from the first difference to
/// the last, golden's with `-` and json's with `+`, at most `max` lines.
pub fn differences(a: std.mem.Allocator, golden: []const u8, json: []const u8, max: usize) ![]u8 {
    var g = std.ArrayList([]const u8).empty;
    var j = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, golden, '\n');
    while (it.next()) |l| try g.append(a, l);
    it = std.mem.splitScalar(u8, json, '\n');
    while (it.next()) |l| try j.append(a, l);
    var head: usize = 0;
    while (head < g.items.len and head < j.items.len and std.mem.eql(u8, g.items[head], j.items[head])) head += 1;
    var tail: usize = 0;
    while (tail < g.items.len - head and tail < j.items.len - head and
        std.mem.eql(u8, g.items[g.items.len - 1 - tail], j.items[j.items.len - 1 - tail])) tail += 1;
    var out = std.ArrayList(u8).empty;
    var n: usize = 0;
    for (g.items[head .. g.items.len - tail]) |l| {
        if (n == max) return out.toOwnedSlice(a);
        try out.writer(a).print("-{s}\n", .{l});
        n += 1;
    }
    for (j.items[head .. j.items.len - tail]) |l| {
        if (n == max) return out.toOwnedSlice(a);
        try out.writer(a).print("+{s}\n", .{l});
        n += 1;
    }
    return out.toOwnedSlice(a);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 6) die("usage: doc_check <json> <golden or -> <inspect dir or -> <out> <label> [<symbol>...]", .{});
    const json_path = argv[1];
    const golden = argv[2];
    const inspect = argv[3];
    const out_path = argv[4];
    const label = argv[5];
    const symbols = argv[6..];

    const json = std.fs.cwd().readFileAlloc(a, json_path, 1 << 28) catch |e| die("cannot read {s}: {s}", .{ json_path, @errorName(e) });
    var bad = false;
    if (!std.mem.eql(u8, golden, "-")) {
        const want = std.fs.cwd().readFileAlloc(a, golden, 1 << 28) catch |e| die("cannot read {s}: {s}", .{ golden, @errorName(e) });
        if (!std.mem.eql(u8, want, json)) {
            std.debug.print("mojo_doc_json: {s}: the JSON differs from its golden {s} (first differences, golden first):\n{s}", .{ label, golden, try differences(a, want, json, 40) });
            bad = true;
        }
    }
    if (symbols.len > 0) {
        const exe = try std.fs.path.join(a, &.{ inspect, "inspect" });
        const r = std.process.Child.run(.{ .allocator = a, .argv = &.{ exe, "json", json_path }, .max_output_bytes = 1 << 28 }) catch |e| die("cannot run {s}: {s}", .{ exe, @errorName(e) });
        const ok = switch (r.term) {
            .Exited => |c| c == 0,
            else => false,
        };
        if (!ok) {
            std.debug.print("doc_check: {s} json {s} failed\n{s}", .{ exe, json_path, r.stderr });
            std.process.exit(1);
        }
        const decls = try declarations(a, r.stdout);
        for (symbols) |s| {
            var found = false;
            for (decls) |d| {
                if (std.mem.eql(u8, d, s)) found = true;
            }
            if (!found) {
                std.debug.print("mojo_doc_json: {s}: the JSON declares no `{s}`\n", .{ label, s });
                bad = true;
            }
        }
    }
    if (bad) std.process.exit(1);
    const out = std.fs.cwd().createFile(out_path, .{}) catch |e| die("cannot create {s}: {s}", .{ out_path, @errorName(e) });
    defer out.close();
    out.writeAll(json) catch |e| die("cannot write {s}: {s}", .{ out_path, @errorName(e) });
}
