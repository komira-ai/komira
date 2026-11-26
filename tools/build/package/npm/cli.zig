//! komira_npm: the command line and the files it names, read into an
//! npm.Input. Every refusal is returned (native_policy's diag.zig), so
//! main.zig only forwards.
//!
//! Flags are `--flag value` pairs. Both commands take:
//!   --name N --manifest <package.json> --license L
//!   [--file <path>=<file or dir>]...
//!   [--os O --cpu C [--libc L]] (the manifest's platform fields)
//!   [--glibc V --arch A | --macos V] [--max-glibcxx V] [--max-cxxabi V]
//!   --stamp N --commit C --timestamp-ms MS
//! `write` adds `--out <tarball>`; `check` adds `--tarball <tarball>`,
//! `--require-stamped true|false`, `[--twin <tarball>]` and `--out <marker>`.
//! A `--file` naming a directory adds each file under it, at
//! `<path>/<its path in the directory>`.

const std = @import("std");
const diag = @import("native_policy").diag;
const stamp_mod = @import("package_stamp");
const npm = @import("npm.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

const max_file = 8 * 1024 * 1024 * 1024 - 1;

pub const Args = struct {
    pairs: []const [2][]const u8,

    pub fn all(a: Args, alloc: Alloc, flag: []const u8) Alloc.Error![]const []const u8 {
        var out = std.ArrayList([]const u8).empty;
        for (a.pairs) |kv| {
            if (std.mem.eql(u8, kv[0], flag)) try out.append(alloc, kv[1]);
        }
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
    "--manifest",
    "--license",
    "--file",
    "--os",
    "--cpu",
    "--libc",
    "--glibc",
    "--macos",
    "--arch",
    "--max-glibcxx",
    "--max-cxxabi",
    "--stamp",
    "--commit",
    "--timestamp-ms",
};

/// The commands of `komira_npm`, by their first argument.
pub const Command = enum { write, check };

/// The command `name` names; any other name, an empty one among them, is
/// refused with the usage line.
pub fn subcommand(alloc: Alloc, d: *Diag, name: []const u8) Refused!Command {
    return std.meta.stringToEnum(Command, name) orelse refuse(d, alloc, "usage: komira_npm write|check --flag value ...", .{});
}

/// `argv` (after the command) as pairs, every flag in `common_flags` or
/// `extra`.
pub fn parse(alloc: Alloc, d: *Diag, argv: []const []const u8, extra: []const []const u8) Refused!Args {
    if (argv.len % 2 != 0) return refuse(d, alloc, "{s} needs a value", .{argv[argv.len - 1]});
    var pairs = std.ArrayList([2][]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const k = argv[i];
        var known = false;
        for (common_flags) |f| known = known or std.mem.eql(u8, f, k);
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
pub fn stage(alloc: Alloc, d: *Diag, dest: []const u8, src: []const u8, out: *std.ArrayList(npm.File)) Refused!void {
    const st = std.fs.cwd().statFile(src) catch |err| return refuse(d, alloc, "cannot stat {s}: {s}", .{ src, @errorName(err) });
    if (st.kind != .directory) {
        if (st.kind != .file) return refuse(d, alloc, "{s}: not a regular file or directory ({s})", .{ src, @tagName(st.kind) });
        try out.append(alloc, .{ .path = dest, .data = try readFile(alloc, d, src) });
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
                try out.append(alloc, .{ .path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, rel }), .data = data });
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

/// The package's input, from `a`. A platform is the manifest's fields and
/// the native policy's floor together: `--glibc` with `--arch`, `--os` and
/// `--cpu` (and `--libc`), or `--macos` with `--os` and `--cpu`; with none
/// of them the package has no platform.
pub fn input(alloc: Alloc, d: *Diag, a: Args) Refused!npm.Input {
    const st = try stamp_mod.of(alloc, d, try a.one(alloc, d, "--stamp"), try a.one(alloc, d, "--commit"), try a.one(alloc, d, "--timestamp-ms"));
    var files = std.ArrayList(npm.File).empty;
    for (try a.all(alloc, "--file")) |f| {
        const kv = try named(alloc, d, f, "--file");
        try stage(alloc, d, kv[0], kv[1], &files);
    }
    const os = try a.opt(alloc, d, "--os");
    const cpu = try a.opt(alloc, d, "--cpu");
    const libc = try a.opt(alloc, d, "--libc");
    const glibc = try a.opt(alloc, d, "--glibc");
    const macos = try a.opt(alloc, d, "--macos");
    const arch = try a.opt(alloc, d, "--arch");
    if (glibc != null and macos != null) return refuse(d, alloc, "--glibc and --macos are both given: a package is for one platform", .{});
    if ((glibc == null) != (arch == null)) return refuse(d, alloc, "--glibc and --arch go together: the floor and the machine of a Linux package", .{});
    const has_floor = glibc != null or macos != null;
    if (has_floor != (os != null and cpu != null) or (!has_floor and libc != null))
        return refuse(d, alloc, "--os and --cpu are given exactly when --glibc or --macos is: a platform package names its platform to npm and to the native policy", .{});
    return .{
        .name = try a.one(alloc, d, "--name"),
        .manifest = try readFile(alloc, d, try a.one(alloc, d, "--manifest")),
        .version = st.version,
        .stamped = st.stamped,
        .license = try a.one(alloc, d, "--license"),
        .files = try files.toOwnedSlice(alloc),
        .platform = .{ .os = os, .cpu = cpu, .libc = libc },
        .glibc = glibc,
        .macos = macos,
        .arch = arch orelse "x86_64",
        .max_glibcxx = try a.opt(alloc, d, "--max-glibcxx"),
        .max_cxxabi = try a.opt(alloc, d, "--max-cxxabi"),
    };
}
