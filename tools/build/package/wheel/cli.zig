//! komira_wheel: the command line and the files it names, read into a
//! wheel.Input. Every refusal is returned (native_policy's diag.zig), so main.zig only
//! forwards.
//!
//! Flags are `--flag value` pairs. A command takes:
//!   --name N --summary S --readme <file> --requires-python R
//!   [--requires-dist R]... [--classifier C]... [--project-url <label>=<url>]...
//!   --license-expression E [--license-file <name>=<file>]...
//!   [--file <path>=<file or dir>]... [--exec-file <path>=<file or dir>]...
//!   --tag T [--max-glibcxx V] [--max-cxxabi V] [--external-needed <soname>]...
//!   --stamp N --commit C --timestamp-ms MS
//! `write` adds `--out <wheel>`; `check` adds `--wheel <wheel>`,
//! `--require-stamped true|false`, `[--twin <wheel>]` and `--out <marker>`.
//! A `--file` or `--exec-file` naming a directory adds each file under it,
//! at `<path>/<its path in the directory>`; an `--exec-file` is mode 0755
//! (a shared library), a `--file` 0644.

const std = @import("std");
const diag = @import("native_policy").diag;
const stamp_mod = @import("stamp.zig");
const wheel = @import("wheel.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

const max_file = 8 * 1024 * 1024 * 1024 - 1;

pub const Args = struct {
    pairs: []const [2][]const u8,

    pub fn all(a: Args, alloc: Alloc, flag: []const u8) ![]const []const u8 {
        var out = std.ArrayList([]const u8).empty;
        for (a.pairs) |kv| if (std.mem.eql(u8, kv[0], flag)) try out.append(alloc, kv[1]);
        return out.toOwnedSlice(alloc);
    }

    pub fn opt(a: Args, alloc: Alloc, d: *Diag, flag: []const u8) Refused!?[]const u8 {
        const vs = try a.all(alloc, flag);
        if (vs.len > 1) return refuse(d, alloc, "{s} is given {d} times", .{ flag, vs.len });
        return if (vs.len == 1) vs[0] else null;
    }

    pub fn one(a: Args, alloc: Alloc, d: *Diag, flag: []const u8) Refused![]const u8 {
        return (try a.opt(alloc, d, flag)) orelse refuse(d, alloc, "missing {s}", .{flag});
    }
};

pub const common_flags = [_][]const u8{
    "--name",
    "--summary",
    "--readme",
    "--requires-python",
    "--requires-dist",
    "--classifier",
    "--project-url",
    "--license-expression",
    "--license-file",
    "--file",
    "--exec-file",
    "--tag",
    "--max-glibcxx",
    "--max-cxxabi",
    "--external-needed",
    "--stamp",
    "--commit",
    "--timestamp-ms",
};

/// `argv` (after the command) as pairs, every flag in `common_flags` or
/// `extra`.
/// The commands of `komira_wheel`, by their first argument.
pub const Command = enum { write, check, libs, same };

/// The command `name` names; any other name, an empty one among them, is
/// refused with the usage line.
pub fn subcommand(alloc: Alloc, d: *Diag, name: []const u8) Refused!Command {
    return std.meta.stringToEnum(Command, name) orelse refuse(d, alloc, "usage: komira_wheel write|check|libs|same --flag value ...", .{});
}

pub fn parse(alloc: Alloc, d: *Diag, argv: []const []const u8, extra: []const []const u8) Refused!Args {
    return pairsOf(alloc, d, argv, &common_flags, extra);
}

/// `argv` as pairs, every flag in `flags`: a command that takes none of the
/// wheel's flags (`libs`).
pub fn parseOnly(alloc: Alloc, d: *Diag, argv: []const []const u8, flags: []const []const u8) Refused!Args {
    return pairsOf(alloc, d, argv, &.{}, flags);
}

fn pairsOf(alloc: Alloc, d: *Diag, argv: []const []const u8, base: []const []const u8, extra: []const []const u8) Refused!Args {
    if (argv.len % 2 != 0) return refuse(d, alloc, "{s} needs a value", .{argv[argv.len - 1]});
    var pairs = std.ArrayList([2][]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const k = argv[i];
        var known = false;
        for (base) |f| known = known or std.mem.eql(u8, f, k);
        for (extra) |f| known = known or std.mem.eql(u8, f, k);
        if (!known) return refuse(d, alloc, "unknown argument {s}", .{k});
        try pairs.append(alloc, .{ k, argv[i + 1] });
    }
    return .{ .pairs = try pairs.toOwnedSlice(alloc) };
}

/// `<name>=<value>`, split at the first `=`; both parts non-empty.
pub fn named(alloc: Alloc, d: *Diag, arg: []const u8, flag: []const u8) Refused![2][]const u8 {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return refuse(d, alloc, "{s} `{s}` is not <name>=<value>", .{ flag, arg });
    if (eq == 0 or eq + 1 == arg.len) return refuse(d, alloc, "{s} `{s}` is not <name>=<value>", .{ flag, arg });
    return .{ arg[0..eq], arg[eq + 1 ..] };
}

pub fn readFile(alloc: Alloc, d: *Diag, path: []const u8) Refused![]const u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, max_file) catch |err| refuse(d, alloc, "cannot read {s}: {s}", .{ path, @errorName(err) });
}

/// The files `src` names at `dest`: `src` itself, or each regular file under
/// it. A symbolic link or a special file is refused.
pub fn stage(alloc: Alloc, d: *Diag, dest: []const u8, src: []const u8, mode: u32, out: *std.ArrayList(wheel.File)) Refused!void {
    const st = std.fs.cwd().statFile(src) catch |err| return refuse(d, alloc, "cannot stat {s}: {s}", .{ src, @errorName(err) });
    if (st.kind != .directory) {
        if (st.kind != .file) return refuse(d, alloc, "{s}: not a regular file or directory ({s})", .{ src, @tagName(st.kind) });
        try out.append(alloc, .{ .path = dest, .data = try readFile(alloc, d, src), .mode = mode });
        return;
    }
    var dir = std.fs.cwd().openDir(src, .{ .iterate = true }) catch |err| return refuse(d, alloc, "cannot open {s}: {s}", .{ src, @errorName(err) });
    defer dir.close();
    var w = try dir.walk(alloc);
    defer w.deinit();
    while (w.next() catch |err| return refuse(d, alloc, "cannot read {s}: {s}", .{ src, @errorName(err) })) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                const rel = try alloc.dupe(u8, entry.path);
                const data = dir.readFileAlloc(alloc, rel, max_file) catch |err| return refuse(d, alloc, "cannot read {s}/{s}: {s}", .{ src, rel, @errorName(err) });
                try out.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, rel }), .data = data, .mode = mode });
            },
            else => return refuse(d, alloc, "{s}/{s}: not a regular file or directory ({s})", .{ src, entry.path, @tagName(entry.kind) }),
        }
    }
}

pub fn flagBool(alloc: Alloc, d: *Diag, flag: []const u8, v: []const u8) Refused!bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return refuse(d, alloc, "{s} is `{s}`, not true or false", .{ flag, v });
}

/// The wheel's input and stamp, from `a`.
pub fn input(alloc: Alloc, d: *Diag, a: Args) Refused!struct { in: wheel.Input, stamp: stamp_mod.Stamp } {
    const st = try stamp_mod.of(alloc, d, try a.one(alloc, d, "--stamp"), try a.one(alloc, d, "--commit"), try a.one(alloc, d, "--timestamp-ms"));
    var urls = std.ArrayList(wheel.Url).empty;
    for (try a.all(alloc, "--project-url")) |u| {
        const kv = try named(alloc, d, u, "--project-url");
        try urls.append(alloc, .{ .label = kv[0], .url = kv[1] });
    }
    var lics = std.ArrayList(wheel.File).empty;
    for (try a.all(alloc, "--license-file")) |l| {
        const kv = try named(alloc, d, l, "--license-file");
        try lics.append(alloc, .{ .path = kv[0], .data = try readFile(alloc, d, kv[1]) });
    }
    var files = std.ArrayList(wheel.File).empty;
    for (try a.all(alloc, "--file")) |f| {
        const kv = try named(alloc, d, f, "--file");
        try stage(alloc, d, kv[0], kv[1], 0o644, &files);
    }
    for (try a.all(alloc, "--exec-file")) |f| {
        const kv = try named(alloc, d, f, "--exec-file");
        try stage(alloc, d, kv[0], kv[1], 0o755, &files);
    }
    return .{ .stamp = st, .in = .{
        .name = try a.one(alloc, d, "--name"),
        .version = st.version,
        .summary = try a.one(alloc, d, "--summary"),
        .readme = try readFile(alloc, d, try a.one(alloc, d, "--readme")),
        .requires_python = try a.one(alloc, d, "--requires-python"),
        .requires_dist = try a.all(alloc, "--requires-dist"),
        .classifiers = try a.all(alloc, "--classifier"),
        .project_urls = try urls.toOwnedSlice(alloc),
        .license_expression = try a.one(alloc, d, "--license-expression"),
        .licenses = try lics.toOwnedSlice(alloc),
        .files = try files.toOwnedSlice(alloc),
        .tag = try a.one(alloc, d, "--tag"),
        .max_glibcxx = try a.opt(alloc, d, "--max-glibcxx"),
        .max_cxxabi = try a.opt(alloc, d, "--max-cxxabi"),
        .external_needed = try a.all(alloc, "--external-needed"),
    } };
}
