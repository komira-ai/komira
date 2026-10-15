//! node_tools: the program the node_modules rules run (modules.bzl).
//!
//!   node_tools assemble <spec.json> <out>   node_modules from package-lock.json and pinned tarballs
//!   node_tools run <spec.json> <out>        a program of node_modules over a copy of a source tree
//!
//! Paths in the spec are relative to the working directory (the action's
//! root). Everything is the Zig standard library: no shell, no npm, no network.
const std = @import("std");
const layout = @import("layout.zig");
const runner = @import("runner.zig");

fn die(comptime fmt: []const u8, args: anytype) u8 {
    std.io.getStdErr().writer().print("node_modules: " ++ fmt ++ "\n", args) catch {};
    return 1;
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn text(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn abs(a: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]u8 {
    return std.fs.path.resolve(a, &.{ cwd, p });
}

fn doAssemble(a: std.mem.Allocator, cwd: []const u8, spec_json: std.json.Value, out: []const u8) !void {
    const lock_path = text(field(spec_json, "lockfile")) orelse return error.BadSpec;
    var spec = layout.Spec{
        .lockfile = try std.fs.cwd().readFileAlloc(a, lock_path, 1 << 30),
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    const tb = field(spec_json, "tarballs") orelse return error.BadSpec;
    const sr = field(spec_json, "sri512") orelse return error.BadSpec;
    if (tb != .object or sr != .object) return error.BadSpec;
    for (tb.object.keys(), tb.object.values()) |k, v| {
        if (v != .string) return error.BadSpec;
        try spec.tarballs.put(k, try abs(a, cwd, v.string));
    }
    for (sr.object.keys(), sr.object.values()) |k, v| {
        if (v != .string) return error.BadSpec;
        try spec.sri512.put(k, v.string);
    }
    const out_abs = try abs(a, cwd, out);
    try std.fs.cwd().makePath(out_abs);
    var dir = try std.fs.cwd().openDir(out_abs, .{});
    defer dir.close();
    try layout.assemble(a, spec, dir, out_abs, std.io.getStdErr().writer());
}

fn doRun(a: std.mem.Allocator, cwd: []const u8, j: std.json.Value, out: []const u8) !void {
    const args_v = field(j, "args") orelse return error.BadSpec;
    const env_v = field(j, "env") orelse return error.BadSpec;
    if (args_v != .array or env_v != .object) return error.BadSpec;
    var args = std.ArrayList([]const u8).init(a);
    for (args_v.array.items) |x| {
        if (x != .string) return error.BadSpec;
        try args.append(x.string);
    }
    var env = std.ArrayList([2][]const u8).init(a);
    for (env_v.object.keys(), env_v.object.values()) |k, v| {
        if (v != .string) return error.BadSpec;
        try env.append(.{ k, v.string });
    }
    const out_dir_v = field(j, "outDir");
    const scratch = try runner.scratchDir(a, cwd, std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch null);
    const spec = runner.Spec{
        .tree = try abs(a, cwd, text(field(j, "tree")) orelse return error.BadSpec),
        .modules = try abs(a, cwd, text(field(j, "modules")) orelse return error.BadSpec),
        .node = try abs(a, cwd, text(field(j, "node")) orelse return error.BadSpec),
        .libs = try abs(a, cwd, text(field(j, "libs")) orelse return error.BadSpec),
        .package = text(field(j, "package")) orelse return error.BadSpec,
        .program = text(field(j, "program")) orelse return error.BadSpec,
        .args = args.items,
        .env = env.items,
        .out_dir = if (out_dir_v) |v| (if (v == .string) v.string else null) else null,
        .scratch = scratch,
    };
    try runner.run(a, spec, try abs(a, cwd, out), std.io.getStdErr().writer());
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return die("out of memory", .{});
    if (argv.len != 4 or (!std.mem.eql(u8, argv[1], "assemble") and !std.mem.eql(u8, argv[1], "run"))) {
        return die("usage: node_tools assemble|run <spec.json> <out>", .{});
    }
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return die("no working directory", .{});
    const spec_text = std.fs.cwd().readFileAlloc(a, argv[2], 1 << 30) catch |e| return die("cannot read {s}: {s}", .{ argv[2], @errorName(e) });
    const parsed = std.json.parseFromSlice(std.json.Value, a, spec_text, .{}) catch return die("{s} is not JSON", .{argv[2]});
    const result = if (std.mem.eql(u8, argv[1], "assemble"))
        doAssemble(a, cwd, parsed.value, argv[3])
    else
        doRun(a, cwd, parsed.value, argv[3]);
    result catch |e| switch (e) {
        error.Failed => return 1,
        else => return die("{s}", .{@errorName(e)}),
    };
    return 0;
}
