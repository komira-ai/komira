// Why Zig: build tools are Zig (tools/build/README.md). The actions that were
// busybox shell scripts (package, node, python, native, cloud, third_party)
// are Zig programs, and this is what they share: file-tree copies, modes,
// hashes, sorted listings, child processes. A tool imports it as
// `@import("act_util")` by naming `komira//tools/build/act_util:act_util` in
// its `deps`.
//! act_util: the small file and process helpers the action tools share.
//!
//! The zig 0.12 / 0.15 common subset: no `std.io` writers beyond
//! `ArrayList.writer()`, no `Dir.writeFile` with a struct, no
//! `MAX_PATH_BYTES`. `std.ArrayList(T).init` is the one mechanical edit for 0.15.

const std = @import("std");

/// Unpacking gzipped tar archives as `tar -xzf` does (extract.zig).
pub const extract = @import("extract.zig");

/// Where a check writes its refusal text: the caller prints it on stderr.
pub const Out = std.ArrayList(u8);

/// Appends the formatted text to `out` and returns `error.Refused`.
pub fn refuse(out: *Out, comptime fmt: []const u8, args: anytype) error{ Refused, OutOfMemory } {
    try out.writer().print(fmt, args);
    return error.Refused;
}

/// What a tool exits with when a child ended as `term`: the child's own
/// status, 128 + N for signal N (a shell's), 1 for anything else.
pub fn exitCodeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

/// `p` made absolute against `cwd`.
pub fn abs(a: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]u8 {
    return if (std.fs.path.isAbsolute(p)) a.dupe(u8, p) else std.fs.path.join(a, &.{ cwd, p });
}

/// The scratch directory of the action: where buck2 says (`buck_scratch`, its
/// BUCK_SCRATCH_PATH; relative to `cwd` when relative), else beside the
/// action's inputs.
pub fn scratchRoot(a: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fs.path.join(a, &.{ cwd, ".komira_action" });
    if (std.fs.path.isAbsolute(s)) return std.fs.path.join(a, &.{ s, "komira" });
    return std.fs.path.join(a, &.{ cwd, s, "komira" });
}

/// The sha256 of `data`, lower-case hex.
pub fn sha256Hex(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// `s` without its trailing newlines (what `$(cmd)` keeps of cmd's output).
pub fn trimNewlines(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n");
}

/// Whether `hay` holds `needle` anywhere (`grep -F -q`, except across lines:
/// a needle without a newline cannot span one).
pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

pub fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Copies the entries of `src` into `dst`, merging into directories that exist:
/// a symbolic link stays one (as `cp -R` does), a file's mode is kept.
pub fn copyTree(src: std.fs.Dir, dst: std.fs.Dir) !void {
    var it = src.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .directory => {
                dst.makeDir(e.name) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
                var s = try src.openDir(e.name, .{ .iterate = true });
                defer s.close();
                var d = try dst.openDir(e.name, .{ .iterate = true });
                defer d.close();
                try copyTree(s, d);
            },
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const target = try src.readLink(e.name, &buf);
                dst.deleteFile(e.name) catch {};
                try dst.symLink(target, e.name, .{});
            },
            .file => try src.copyFile(e.name, dst, e.name, .{}),
            else => return error.UnsupportedEntry,
        }
    }
}

/// Sets every directory under `dir` (and `dir` itself) to `dir_mode` and every
/// regular file to `file_mode`; symbolic links are left alone.
pub fn setModes(dir: std.fs.Dir, dir_mode: std.fs.File.Mode, file_mode: std.fs.File.Mode) !void {
    const self = std.fs.File{ .handle = dir.fd };
    try self.chmod(dir_mode);
    var it = dir.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .directory => {
                var d = try dir.openDir(e.name, .{ .iterate = true });
                defer d.close();
                try setModes(d, dir_mode, file_mode);
            },
            .file => {
                const f = try dir.openFile(e.name, .{});
                defer f.close();
                try f.chmod(file_mode);
            },
            else => {},
        }
    }
}

/// The regular files under `dir`, as paths relative to it joined by `/`,
/// sorted bytewise (`find -type f | LC_ALL=C sort`). With `follow`, symbolic
/// links to files and to directories are followed (`find -L`); a dangling link
/// is skipped. Without it, links are not files.
pub fn listFiles(a: std.mem.Allocator, dir: std.fs.Dir, follow: bool) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(a);
    try listInto(a, dir, "", follow, 0, &list);
    const items = try list.toOwnedSlice();
    std.mem.sort([]const u8, items, {}, lessBytes);
    return items;
}

fn listInto(a: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, follow: bool, depth: usize, list: *std.ArrayList([]const u8)) !void {
    if (depth > 64) return error.TooDeep;
    var it = dir.iterate();
    while (try it.next()) |e| {
        const rel = if (prefix.len == 0) try a.dupe(u8, e.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        var kind = e.kind;
        if (kind == .sym_link) {
            if (!follow) continue;
            const st = dir.statFile(e.name) catch continue;
            kind = st.kind;
        }
        switch (kind) {
            .file => try list.append(rel),
            .directory => {
                var d = try dir.openDir(e.name, .{ .iterate = true });
                defer d.close();
                try listInto(a, d, rel, follow, depth + 1, list);
            },
            else => {},
        }
    }
}

/// The names directly in `dir` (hidden ones included, as `ls -A`), sorted bytewise.
pub fn listNames(a: std.mem.Allocator, dir: std.fs.Dir) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(a);
    var it = dir.iterate();
    while (try it.next()) |e| try list.append(try a.dupe(u8, e.name));
    const items = try list.toOwnedSlice();
    std.mem.sort([]const u8, items, {}, lessBytes);
    return items;
}

/// `names` as `ls -A | tr '\n' ' '` shows them: each followed by a space.
pub fn spaced(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var b = std.ArrayList(u8).init(a);
    for (names) |n| {
        try b.appendSlice(n);
        try b.append(' ');
    }
    return b.toOwnedSlice();
}

/// Creates `path`'s parent directories (relative to `dir`).
pub fn makeParent(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
}

pub fn readAll(a: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(a, path, 1 << 30);
}

/// Writes `data` to `path` (relative to `dir`), replacing the file.
pub fn writeAll(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    const f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

/// A finished child: its exit status (see `exitCodeOf`) and what it wrote.
pub const Ran = struct { code: u8, stdout: []u8, stderr: []u8 };

/// Runs `argv` (stdin empty) in `cwd` (null: the current one) with `env` (null:
/// ours) and collects its standard output and error.
pub fn runCapture(a: std.mem.Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap, cwd: ?[]const u8) !Ran {
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try child.collectOutput(&out, &err, 1 << 28);
    const term = try child.wait();
    return .{ .code = exitCodeOf(term), .stdout = out.items, .stderr = err.items };
}

/// The environment without the variables that make a child load libraries
/// from elsewhere (`LD_LIBRARY_PATH`, `LD_PRELOAD`).
pub fn envWithoutLoaderVars(a: std.mem.Allocator) !std.process.EnvMap {
    var base = try std.process.getEnvMap(a);
    base.remove("LD_LIBRARY_PATH");
    base.remove("LD_PRELOAD");
    return base;
}

/// A copy of `env` (`EnvMap.copy` is not public in zig 0.12).
pub fn cloneEnv(a: std.mem.Allocator, env: std.process.EnvMap) !std.process.EnvMap {
    var out = std.process.EnvMap.init(a);
    var it = env.iterator();
    while (it.next()) |e| try out.put(e.key_ptr.*, e.value_ptr.*);
    return out;
}

/// Prints `<prog>: <message>` on stderr and exits 2 (a failure of the tool's own).
pub fn die(prog: []const u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("{s}: ", .{prog});
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(2);
}

/// One flag a tool takes: `--name` followed by `arity` values.
pub const Spec = struct { name: []const u8, arity: usize = 1 };

/// The flags of a command line: `--name value...` in any order, each as often
/// as it is given. Anything else is an error.
pub const Flags = struct {
    pub const Item = struct { name: []const u8, vals: []const []const u8 };
    items: []const Item,
    /// The arguments after a lone `--`, for the tools that run a command.
    rest: []const []const u8,

    /// The first value of the first `--name`, or null.
    pub fn one(self: Flags, name: []const u8) ?[]const u8 {
        for (self.items) |it| {
            if (std.mem.eql(u8, it.name, name)) return it.vals[0];
        }
        return null;
    }

    /// The value of `--name`; `error.MissingFlag` when it was not given.
    pub fn need(self: Flags, name: []const u8) error{MissingFlag}![]const u8 {
        return self.one(name) orelse error.MissingFlag;
    }

    /// Every occurrence of `--name`, in order.
    pub fn all(self: Flags, a: std.mem.Allocator, name: []const u8) ![]const Item {
        var list = std.ArrayList(Item).init(a);
        for (self.items) |it| {
            if (std.mem.eql(u8, it.name, name)) try list.append(it);
        }
        return list.toOwnedSlice();
    }
};

pub const FlagError = error{ UnknownFlag, MissingValue, OutOfMemory };

/// Parses `args` by `spec`. On an error, `bad` names the argument at fault.
pub fn parseFlags(a: std.mem.Allocator, args: []const []const u8, spec: []const Spec, bad: *[]const u8) FlagError!Flags {
    var items = std.ArrayList(Flags.Item).init(a);
    var i: usize = 0;
    var rest: []const []const u8 = &.{};
    outer: while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            rest = args[i + 1 ..];
            break;
        }
        for (spec) |sp| {
            if (arg.len == sp.name.len + 2 and std.mem.startsWith(u8, arg, "--") and std.mem.eql(u8, arg[2..], sp.name)) {
                if (i + sp.arity >= args.len) {
                    bad.* = arg;
                    return error.MissingValue;
                }
                try items.append(.{ .name = sp.name, .vals = args[i + 1 .. i + 1 + sp.arity] });
                i += 1 + sp.arity;
                continue :outer;
            }
        }
        bad.* = arg;
        return error.UnknownFlag;
    }
    return .{ .items = try items.toOwnedSlice(), .rest = rest };
}
