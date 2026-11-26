//! changelog: the command line of the build actions that assemble the Python package's changelog
//! (python/changelog/defs.bzl).
//!
//!   changelog assemble    --root <dir> --prefix <text> --stamp <n> --out <file>
//!   changelog description --root <dir> --prefix <text> --stamp <n> --readme <file> --out <file>
//!
//! `--root` holds `CHANGELOG.md` and the directory `changelog.d` of fragments (no directory is no
//! fragment). `--prefix` is what the messages put before those names (`python/`), `--stamp` the build's
//! `komira.package_stamp` (`0` for none). `assemble` writes CHANGELOG.md with the new section
//! (changelog.zig `assemble`); `description` writes `--readme` followed by that text with its headings one
//! level down (`description`). The exit status is 0 when the file was written, 1 when an input was
//! refused or unreadable (`changelog: FAILED: <why>` on stderr, nothing written) and 2 for a usage error.
//! Everything is a flag; no environment is read.
const std = @import("std");
const changelog = @import("changelog.zig");

const Allocator = std.mem.Allocator;

pub const usage =
    \\usage: changelog assemble --root <dir> --prefix <text> --stamp <n> --out <file>
    \\       changelog description --root <dir> --prefix <text> --stamp <n> --readme <file> --out <file>
    \\
;

const Flags = struct {
    root: []const u8,
    prefix: []const u8,
    stamp: []const u8,
    readme: ?[]const u8,
    out: []const u8,
};

/// The flags of a command, each given once; `readme` only when `with_readme`. Null after the usage error was
/// written to `err`.
fn parse(args: []const []const u8, with_readme: bool, err: *std.Io.Writer) !?Flags {
    var root: ?[]const u8 = null;
    var prefix: ?[]const u8 = null;
    var stamp: ?[]const u8 = null;
    var readme: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const slot: ?*?[]const u8 = if (std.mem.eql(u8, flag, "--root"))
            &root
        else if (std.mem.eql(u8, flag, "--prefix"))
            &prefix
        else if (std.mem.eql(u8, flag, "--stamp"))
            &stamp
        else if (std.mem.eql(u8, flag, "--out"))
            &out
        else if (with_readme and std.mem.eql(u8, flag, "--readme"))
            &readme
        else
            null;
        if (slot == null) {
            try err.print("changelog: unknown argument {s}\n{s}", .{ flag, usage });
            try err.flush();
            return null;
        }
        i += 1;
        if (i >= args.len or slot.?.* != null) {
            try err.print("changelog: {s} needs one value, given once\n", .{flag});
            try err.flush();
            return null;
        }
        slot.?.* = args[i];
    }
    if (root == null or prefix == null or stamp == null or out == null or (with_readme and readme == null)) {
        try err.writeAll(usage);
        try err.flush();
        return null;
    }
    return .{ .root = root.?, .prefix = prefix.?, .stamp = stamp.?, .readme = readme, .out = out.? };
}

fn failed(err: *std.Io.Writer, why: []const u8) !u8 {
    try err.print("changelog: FAILED: {s}\n", .{why});
    try err.flush();
    return 1;
}

fn readFile(a: Allocator, why: *[]const u8, dir: std.fs.Dir, path: []const u8, shown: []const u8) changelog.Error![]u8 {
    return dir.readFileAlloc(a, path, 1 << 26) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return changelog.refuse(a, why, "{s}: cannot read it: {s}", .{ shown, @errorName(e) }),
    };
}

/// The fragments of `<root>/changelog.d`, none when the directory is not there.
fn readFragments(a: Allocator, why: *[]const u8, root: std.fs.Dir, shown_dir: []const u8) changelog.Error![]changelog.Fragment {
    var list = std.ArrayList(changelog.Fragment).empty;
    var dir = root.openDir("changelog.d", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return list.toOwnedSlice(a),
        else => return changelog.refuse(a, why, "{s}: cannot open it: {s}", .{ shown_dir, @errorName(e) }),
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |e| return changelog.refuse(a, why, "{s}: cannot list it: {s}", .{ shown_dir, @errorName(e) })) |entry| {
        const name = try a.dupe(u8, entry.name);
        const shown = try std.fmt.allocPrint(a, "{s}{s}", .{ shown_dir, name });
        if (entry.kind != .file and entry.kind != .sym_link) return changelog.refuse(a, why, "{s}: not a file: fragments are files directly in {s}", .{ shown, shown_dir });
        try list.append(a, .{ .name = name, .text = try readFile(a, why, dir, name, shown) });
    }
    return list.toOwnedSlice(a);
}

/// The assembled changelog of the flags' root, and the changelog's name in messages.
fn assembled(a: Allocator, why: *[]const u8, f: Flags, root: std.fs.Dir) changelog.Error!struct { text: []u8, path: []const u8 } {
    const heading = try changelog.headingOf(a, why, f.stamp);
    const path = try std.fmt.allocPrint(a, "{s}CHANGELOG.md", .{f.prefix});
    const dir = try std.fmt.allocPrint(a, "{s}changelog.d/", .{f.prefix});
    const text = try readFile(a, why, root, "CHANGELOG.md", path);
    const fragments = try readFragments(a, why, root, dir);
    const done = try changelog.assemble(a, why, .{ .changelog_path = path, .changelog = text, .fragments_dir = dir, .fragments = fragments }, heading);
    return .{ .text = done, .path = path };
}

fn command(a: Allocator, why: *[]const u8, f: Flags) changelog.Error!void {
    var root = std.fs.cwd().openDir(f.root, .{}) catch |e|
        return changelog.refuse(a, why, "--root {s}: cannot open it: {s}", .{ f.root, @errorName(e) });
    defer root.close();
    const made = try assembled(a, why, f, root);
    const text = if (f.readme) |readme_path| blk: {
        const readme = try readFile(a, why, std.fs.cwd(), readme_path, readme_path);
        break :blk try changelog.description(a, why, readme, made.path, made.text);
    } else made.text;
    std.fs.cwd().writeFile(.{ .sub_path = f.out, .data = text }) catch |e|
        return changelog.refuse(a, why, "--out {s}: cannot write it: {s}", .{ f.out, @errorName(e) });
}

/// The command line after the program's name. Returns the exit status.
pub fn run(a: Allocator, args: []const []const u8, err: *std.Io.Writer) !u8 {
    if (args.len >= 1) {
        const with_readme = std.mem.eql(u8, args[0], "description");
        if (with_readme or std.mem.eql(u8, args[0], "assemble")) {
            const flags = (try parse(args[1..], with_readme, err)) orelse return 2;
            var why: []const u8 = "";
            command(a, &why, flags) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Refused => return failed(err, why),
            };
            return 0;
        }
    }
    try err.writeAll(usage);
    try err.flush();
    return 2;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ebuf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&ebuf);
    const argv = try std.process.argsAlloc(a);
    const rest = try a.alloc([]const u8, if (argv.len > 0) argv.len - 1 else 0);
    for (rest, argv[1..]) |*r, arg| r.* = arg;
    return run(a, rest, &err.interface);
}
