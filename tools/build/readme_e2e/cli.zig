//! The commands of `readme_e2e` (main.zig): flags, files and exit status.
//!
//!     readme_e2e verify --package P --version V --mojo M --staged DIR --work DIR
//!                       --marker FILE --mopm CMD --readme-tool CMD --compile CMD --run CMD
//!         Installs P from the staged set DIR into a fresh project, compiles and
//!         runs the examples of the README the set holds (verify.zig). Each CMD is
//!         a file holding one word of a command per line; the e2e adds the
//!         arguments. Writes --marker, and only then, when every phase passed.
//!         Exit 0 when the package passed, 1 when it did not.
//!     readme_e2e assemble --out DIR --mojo M (--member NAME VERSION CONDA README)...
//!         Writes the staged set of the packages (assemble.zig). Exit 0, or 1
//!         when a member is refused (nothing is written then).
//!
//! A flag is `--name value`. Everything goes to stdout. Exit 2: bad usage, or a
//! file that cannot be read or written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const verify = @import("verify.zig");
const assemble = @import("assemble.zig");

const USAGE =
    "usage: readme_e2e verify --package P --version V --mojo M --staged DIR --work DIR --marker FILE --mopm CMD --readme-tool CMD --compile CMD --run CMD\n" ++
    "       readme_e2e assemble --out DIR --mojo M (--member NAME VERSION CONDA README)...\n";

fn usage(a: Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !u8 {
    const text = try std.fmt.allocPrint(a, "readme_e2e: " ++ fmt ++ "\n" ++ USAGE, args);
    try out.appendSlice(a, text);
    return 2;
}

/// The words of a command file: one per non-empty line.
fn words(a: Allocator, path: []const u8) ![]const []const u8 {
    const text = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |w| try list.append(a, w);
    return list.items;
}

const verify_flags = [_][]const u8{ "--package", "--version", "--mojo", "--staged", "--work", "--marker", "--mopm", "--readme-tool", "--compile", "--run" };

/// Runs the command in `args` (argv without the program name), writing what
/// the process prints to `out`; returns the exit status.
pub fn execute(a: Allocator, args: []const []const u8, out: *std.ArrayList(u8)) !u8 {
    if (args.len == 0) return usage(a, out, "no command", .{});
    if (std.mem.eql(u8, args[0], "verify")) return verifyCommand(a, args[1..], out);
    if (std.mem.eql(u8, args[0], "assemble")) return assembleCommand(a, args[1..], out);
    return usage(a, out, "unknown command {s}", .{args[0]});
}

fn verifyCommand(a: Allocator, args: []const []const u8, out: *std.ArrayList(u8)) !u8 {
    var values: [verify_flags.len]?[]const u8 = .{null} ** verify_flags.len;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        var matched = false;
        for (verify_flags, 0..) |f, k| {
            if (!std.mem.eql(u8, args[i], f)) continue;
            if (i + 1 >= args.len) return usage(a, out, "{s} takes a value", .{f});
            if (values[k] != null) return usage(a, out, "{s} is given twice", .{f});
            values[k] = args[i + 1];
            matched = true;
        }
        if (!matched) return usage(a, out, "unknown argument {s}", .{args[i]});
    }
    for (verify_flags, 0..) |f, k| {
        if (values[k] == null or values[k].?.len == 0) return usage(a, out, "{s} is required", .{f});
    }
    const v = struct {
        fn get(vals: []const ?[]const u8, name: []const u8) []const u8 {
            for (verify_flags, 0..) |f, k| {
                if (std.mem.eql(u8, f, name)) return vals[k].?;
            }
            unreachable;
        }
    }.get;
    const opts = verify.Options{
        .package = v(&values, "--package"),
        .version = v(&values, "--version"),
        .mojo = v(&values, "--mojo"),
        .staged = v(&values, "--staged"),
        .work = v(&values, "--work"),
        .mopm = words(a, v(&values, "--mopm")) catch |e| return usage(a, out, "cannot read --mopm: {s}", .{@errorName(e)}),
        .readme_tool = words(a, v(&values, "--readme-tool")) catch |e| return usage(a, out, "cannot read --readme-tool: {s}", .{@errorName(e)}),
        .compile = words(a, v(&values, "--compile")) catch |e| return usage(a, out, "cannot read --compile: {s}", .{@errorName(e)}),
        .run = words(a, v(&values, "--run")) catch |e| return usage(a, out, "cannot read --run: {s}", .{@errorName(e)}),
    };
    for ([_][]const []const u8{ opts.mopm, opts.readme_tool, opts.compile, opts.run }) |cmd| {
        if (cmd.len == 0) return usage(a, out, "a command file holds no word", .{});
    }
    const ok = try verify.verify(a, opts, out);
    if (!ok) return 1;
    // The marker is the proof the build keeps: written only after every phase passed.
    const marker = v(&values, "--marker");
    const last = std.mem.lastIndexOfScalar(u8, std.mem.trimRight(u8, out.items, "\n"), '\n');
    const verdict = std.mem.trimRight(u8, out.items[if (last) |l| l + 1 else 0..], "\n");
    const text = try std.fmt.allocPrint(a, "{s}\n", .{verdict});
    std.fs.cwd().writeFile(.{ .sub_path = marker, .data = text }) catch |e| return usage(a, out, "cannot write {s}: {s}", .{ marker, @errorName(e) });
    return 0;
}

fn assembleCommand(a: Allocator, args: []const []const u8, out: *std.ArrayList(u8)) !u8 {
    var out_dir: ?[]const u8 = null;
    var mojo: ?[]const u8 = null;
    var members: std.ArrayList(assemble.Member) = .empty;
    var i: usize = 0;
    while (i < args.len) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--member")) {
            if (i + 4 >= args.len) return usage(a, out, "--member takes NAME VERSION CONDA README", .{});
            try members.append(a, .{ .name = args[i + 1], .version = args[i + 2], .conda = args[i + 3], .readme = args[i + 4] });
            i += 5;
            continue;
        }
        if (i + 1 >= args.len) return usage(a, out, "{s} takes a value", .{flag});
        if (std.mem.eql(u8, flag, "--out")) {
            if (out_dir != null) return usage(a, out, "--out is given twice", .{});
            out_dir = args[i + 1];
        } else if (std.mem.eql(u8, flag, "--mojo")) {
            if (mojo != null) return usage(a, out, "--mojo is given twice", .{});
            mojo = args[i + 1];
        } else return usage(a, out, "unknown argument {s}", .{flag});
        i += 2;
    }
    const dir = out_dir orelse return usage(a, out, "--out is required", .{});
    const m = mojo orelse return usage(a, out, "--mojo is required", .{});
    if (members.items.len == 0) return usage(a, out, "at least one --member is required", .{});
    const ok = try assemble.assemble(a, .{ .out = dir, .mojo = m, .members = members.items }, out);
    return if (ok) 0 else 1;
}
