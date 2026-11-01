//! The native libraries of an installed package, as the e2e uses them. Which libraries a closure links,
//! in which order and with which flags, is `mopm build`'s link plan; this file decides none of it. The
//! e2e asks `mopm build --print-cmd` for the command it would run, takes the linker words out of it for
//! the compile it runs itself (with the toolchain's compiler, not `<prefix>/bin/mojo`), and uses the
//! declarations below only to check that mopm's plan names every library the installed packages say they
//! ship: a plan that leaves one out is a failure of the e2e, not a program that happens to link without it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One native library a package declares, in its `.mopm.json` or in the lock.
pub const Native = struct {
    package: []const u8,
    soname: []const u8,
    /// `shared` (the default), `static` or `both`.
    kind: []const u8 = "shared",
};

const Entry = struct {
    soname: []const u8 = "",
    kind: []const u8 = "shared",
};

pub const Error = error{ OutOfMemory, Invalid };

/// The libraries of `values` (a `native` array of metadata or lock), appended to `out`.
pub fn collect(a: Allocator, package: []const u8, values: []const std.json.Value, out: *std.ArrayList(Native), why: *[]const u8) Error!void {
    for (values) |v| {
        const e = std.json.parseFromValueLeaky(Entry, a, v, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                why.* = try std.fmt.allocPrint(a, "{s}: a `native` entry is not a library declaration ({s})", .{ package, @errorName(err) });
                return error.Invalid;
            },
        };
        if (e.soname.len == 0) {
            why.* = try std.fmt.allocPrint(a, "{s}: a `native` entry names no soname", .{package});
            return error.Invalid;
        }
        var seen = false;
        for (out.items) |o| seen = seen or (std.mem.eql(u8, o.package, package) and std.mem.eql(u8, o.soname, e.soname));
        if (!seen) try out.append(a, .{ .package = package, .soname = e.soname, .kind = e.kind });
    }
}

/// The words of one line of POSIX shell, as `mopm build --print-cmd` writes it: a word is bare or in
/// single quotes, and a quote inside a word is `'\''`.
pub fn shellWords(a: Allocator, line: []const u8) error{ OutOfMemory, Unterminated }![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var have = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ' ', '\t', '\n', '\r' => if (have) {
                try words.append(a, try cur.toOwnedSlice(a));
                have = false;
            },
            '\'' => {
                have = true;
                i += 1;
                while (i < line.len and line[i] != '\'') : (i += 1) try cur.append(a, line[i]);
                if (i >= line.len) return error.Unterminated;
            },
            '\\' => {
                have = true;
                i += 1;
                if (i >= line.len) return error.Unterminated;
                try cur.append(a, line[i]);
            },
            else => |ch| {
                have = true;
                try cur.append(a, ch);
            },
        }
    }
    if (have) try words.append(a, try cur.toOwnedSlice(a));
    return words.items;
}

/// The linker words of mopm's `mojo build` command: what stands between `build` and `-o`. Null when the
/// line is not such a command.
pub fn linkWords(words: []const []const u8) ?[]const []const u8 {
    var start: ?usize = null;
    for (words, 0..) |w, i| {
        if (std.mem.eql(u8, w, "build")) {
            start = i + 1;
            break;
        }
    }
    const from = start orelse return null;
    var i = from;
    while (i < words.len) : (i += 1) {
        if (std.mem.eql(u8, words[i], "-o")) return words[from..i];
    }
    return null;
}

/// `args` without the `-Xlinker --push-state` and `-Xlinker --pop-state` pairs. mopm brackets the libraries it
/// links with `--no-as-needed` between them, so that the binary names a library it never calls (a stock
/// `mojo build` links through the system C driver, which has both). The toolchain's linker driver is zig's, which
/// refuses them (`unsupported linker arg: --push-state`); `--no-as-needed` itself it takes, and it is that
/// driver's default for what follows. Which libraries are linked, and in what order, is left as mopm planned it.
pub fn forZigLinker(a: Allocator, args: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-Xlinker") and i + 1 < args.len) {
            const next = args[i + 1];
            if (std.mem.eql(u8, next, "--push-state") or std.mem.eql(u8, next, "--pop-state")) {
                i += 1;
                continue;
            }
        }
        try out.append(a, args[i]);
    }
    return out.items;
}

/// `x` of `libx.so.1`, `libx.a` and `libx.dylib`; null for a name that does not start `lib`.
fn libName(soname: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, soname, "lib")) return null;
    const rest = soname[3..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    if (dot == 0) return null;
    return rest[0..dot];
}

fn linked(n: Native, args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, std.fs.path.basename(arg), n.soname)) return true;
        if (libName(n.soname)) |name| {
            if (std.mem.startsWith(u8, arg, "-l") and std.mem.eql(u8, arg[2..], name)) return true;
        }
    }
    return false;
}

/// The declared libraries that mopm's link words leave out, as messages.
pub fn unlinked(a: Allocator, natives: []const Native, args: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (natives) |n| {
        if (linked(n, args)) continue;
        try out.append(a, try std.fmt.allocPrint(a, "{s} ships the native library {s} ({s}) and mopm's link command does not link it", .{ n.package, n.soname, n.kind }));
    }
    return out.items;
}
