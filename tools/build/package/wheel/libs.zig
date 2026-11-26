//! komira_wheel libs: a finished wheel read from its bytes alone, and refused
//! unless the libraries in it load the way an install of it would load them:
//! from the wheel, through each library's own run path, with the Mojo runtime
//! inside it and nothing else beside it. The entry's format picks the walk:
//! an ELF entry is walked as ld.so walks it, a Mach-O entry as dyld does. It
//! reads the wheel, the few names of `Policy` and the runtime's copies of the
//! runtime libraries, and no other input of the rule that wrote the wheel. The zip is read as zip.zig
//! reads it (a zip that writer wrote: the build's wheel, or the same bytes as
//! an index serves them).
//!
//! What is held, in order, each refusal naming its check first:
//!   path     every member is a relative path of plain components (no `/`
//!            first, no `\`, no empty, `.` or `..` component);
//!   layout   every member is under the entry library's top directory (the
//!            import package) or the one `.dist-info` directory: no second
//!            top-level directory, so no `modular/` beside the package;
//!   entry    the entry library (the one the package opens) is a member and an
//!            ELF or a Mach-O file, and so is each opened library (one the
//!            package opens itself beside the entry, under the same package
//!            and of the entry's format);
//!   runtime  each Mojo runtime library is in the wheel exactly once, with the
//!            toolchain's bytes (a process holds one Mojo runtime);
//!   runpath  every run path entry of a library the entry loads is `$ORIGIN`
//!            or under it, and stays inside the import package once `$ORIGIN`
//!            is the library's own directory;
//!   needed   every DT_NEEDED of a library the entry loads is a manylinux
//!            system library (native_policy's policy.zig list), a library already loaded,
//!            or a member at `<run path entry>/<name>` for one of that
//!            library's run path entries, tried in order; a name holding `/`
//!            (opened as a path, not looked up) is refused;
//!   stray    every ELF and every Mach-O member is loaded from the entry or
//!            from an opened library, each walked on its own as the entry is:
//!            a library nothing loads is refused, and so is a library of the
//!            other format (a Linux `.so` in a macOS wheel is loaded by
//!            nothing);
//!   licence  each licence file of the runtime is a non-empty member of
//!            `.dist-info/licenses/` and a `License-File` of METADATA;
//!   requires no Requires-Dist of METADATA names a distribution of the
//!            runtime (a second copy of it).
//!
//! The walk is the loader's (ld.so(8)): breadth first from the entry, each
//! DT_NEEDED looked up among the libraries already loaded by file name (the
//! SONAME of every library komira ships is its file name) before the run path
//! of the library that needs it. It is stricter than the loader in one way:
//! the DT_RPATH of the libraries that loaded a library is not searched, only
//! the library's own run path (DT_RUNPATH and DT_RPATH as native_policy's elf.zig reads them).
//!
//! The Mach-O walk (dyld(1)), for a Mach-O entry, holds the same `runpath`,
//! `needed` and `stray` checks in Mach-O's terms:
//!   runpath  every LC_RPATH entry of a library the entry loads is
//!            `@loader_path` or under it, and stays inside the import package
//!            once `@loader_path` is the library's own directory;
//!   needed   every library a load command names (LC_LOAD_DYLIB and its weak,
//!            re-export, lazy and upward forms) is an operating system library
//!            (an absolute path under /usr/lib/ or /System/Library/, no `..`),
//!            or `@rpath/<file>` that is a library already loaded or a Mach-O
//!            member at `<run path entry>/<file>` for one of that library's
//!            LC_RPATH entries, tried in order, or `@loader_path/<path>` that
//!            is a Mach-O member inside the package; any other name (an
//!            `@executable_path` name, a path of the build machine, of
//!            Homebrew or of a conda prefix, a bare name) is refused.
//! It is stricter than dyld in the same way: the LC_RPATH entries of the
//! libraries that loaded a library are not searched, only its own.

const std = @import("std");
const check_mod = @import("check.zig");
const cli = @import("cli.zig");
const diag = @import("native_policy").diag;
const elf = @import("native_policy").elf;
const macho = @import("native_policy").macho;
const policy = @import("native_policy").policy;
const zip = @import("zip.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

/// A Mojo runtime library the wheel must carry, with the toolchain's bytes.
pub const Runtime = struct { name: []const u8, data: []const u8 };

pub const Policy = struct {
    /// The library the package opens, as a member path
    /// (`komira/_lib/libkomira.so`). Its first component is the import
    /// package.
    entry: []const u8,
    /// The libraries the package opens itself beside the entry, as member
    /// paths under the same package (`komira/_lib/libkomira_udf_python.so`,
    /// the UDF runtime): each is walked from as the entry is, and what it
    /// loads counts as loaded.
    opened: []const []const u8 = &.{},
    /// The Mojo runtime libraries: carried once each by the wheel.
    runtime: []const Runtime,
    /// The names of the runtime's licence files under `.dist-info/licenses/`.
    runtime_licenses: []const []const u8,
    /// Distributions that carry the runtime (normalised names): the wheel
    /// requires none of them.
    runtime_dists: []const []const u8,
};

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn occurrences(list: []const []const u8, s: []const u8) usize {
    var n: usize = 0;
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) n += 1;
    }
    return n;
}

fn find(members: []const policy.Member, name: []const u8) ?policy.Member {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn topDir(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
}

fn plainPath(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    }
    return true;
}

/// The directory a run path entry names for a library in directory `dir`
/// (a member path without its file name), with `.` and `..` resolved; null
/// when the entry is not `$ORIGIN`-relative, and `""` when it climbs to or
/// above the wheel's root.
fn runDir(alloc: Alloc, dir: []const u8, entry: []const u8) !?[]const u8 {
    const rest = if (std.mem.startsWith(u8, entry, "${ORIGIN}"))
        entry["${ORIGIN}".len..]
    else if (std.mem.startsWith(u8, entry, "$ORIGIN"))
        entry["$ORIGIN".len..]
    else
        return null;
    return underDir(alloc, dir, rest);
}

/// `dir` followed by `rest` (empty, or `/` and a relative path), with `.` and
/// `..` resolved; null when `rest` is neither, `""` when it climbs to or above
/// the wheel's root.
fn underDir(alloc: Alloc, dir: []const u8, rest: []const u8) !?[]const u8 {
    if (rest.len != 0 and rest[0] != '/') return null;
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |p| if (p.len != 0) try parts.append(alloc, p);
    var more = std.mem.splitScalar(u8, rest, '/');
    while (more.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len == 0) return "";
            _ = parts.pop();
            continue;
        }
        try parts.append(alloc, p);
    }
    return try std.mem.join(alloc, "/", parts.items);
}

/// The members whose file name is `name`, joined with ", ".
fn wherever(alloc: Alloc, members: []const policy.Member, name: []const u8) ![]const u8 {
    var at = std.ArrayList([]const u8).empty;
    for (members) |m| if (std.mem.eql(u8, diag.baseName(m.name), name)) try at.append(alloc, m.name);
    return std.mem.join(alloc, ", ", at.items);
}

/// A distribution name as PEP 503 normalises it.
fn normalise(alloc: Alloc, name: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var sep = false;
    for (name) |c| {
        if (c == '-' or c == '_' or c == '.') {
            sep = true;
            continue;
        }
        if (sep and out.items.len != 0) try out.append(alloc, '-');
        sep = false;
        try out.append(alloc, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(alloc);
}

/// Refuses the wheel `members` unless its libraries load as described above;
/// returns the member paths of the libraries the entry loads, in load order,
/// the entry first, then those of each opened library that are not loaded yet,
/// in the order `opened` gives.
pub fn check(alloc: Alloc, d: *Diag, p: Policy, members: []const policy.Member) Refused![]const []const u8 {
    for (members) |m| {
        if (!plainPath(m.name)) return refuse(d, alloc, "path: the member `{s}` is not a relative path of plain components", .{m.name});
    }
    if (!plainPath(p.entry) or std.mem.indexOfScalar(u8, p.entry, '/') == null)
        return refuse(d, alloc, "entry: `{s}` is not a path under the import package", .{p.entry});
    const package = topDir(p.entry);

    var info_dir: ?[]const u8 = null;
    for (members) |m| {
        const top = topDir(m.name);
        if (top.len == m.name.len or !std.mem.endsWith(u8, top, ".dist-info")) continue;
        if (info_dir) |seen| {
            if (!std.mem.eql(u8, seen, top)) return refuse(d, alloc, "layout: the wheel has two .dist-info directories, {s} and {s}", .{ seen, top });
        } else info_dir = top;
    }
    const info = info_dir orelse return refuse(d, alloc, "layout: the wheel has no .dist-info directory", .{});
    for (members) |m| {
        const top = topDir(m.name);
        if (top.len == m.name.len or !(std.mem.eql(u8, top, package) or std.mem.eql(u8, top, info)))
            return refuse(d, alloc, "layout: {s} is outside {s}/ and {s}/", .{ m.name, package, info });
    }

    const entry = find(members, p.entry) orelse return refuse(d, alloc, "entry: the wheel has no {s}", .{p.entry});
    const is_macho = macho.isMachO(entry.data);
    if (!is_macho and !elf.isElf(entry.data)) return refuse(d, alloc, "entry: {s} is neither an ELF nor a Mach-O file", .{p.entry});
    const format: []const u8 = if (is_macho) "a Mach-O" else "an ELF";
    for (p.opened) |o| {
        if (!plainPath(o) or !std.mem.eql(u8, topDir(o), package) or topDir(o).len == o.len)
            return refuse(d, alloc, "entry: the opened library `{s}` is not a path under {s}/", .{ o, package });
        if (std.mem.eql(u8, o, p.entry) or occurrences(p.opened, o) > 1)
            return refuse(d, alloc, "entry: {s} is named twice", .{o});
        const lib = find(members, o) orelse return refuse(d, alloc, "entry: the wheel has no {s}", .{o});
        if (!(if (is_macho) macho.isMachO(lib.data) else elf.isElf(lib.data)))
            return refuse(d, alloc, "entry: the opened library {s} is not {s} file like {s}", .{ o, format, p.entry });
    }

    for (p.runtime) |r| {
        var count: usize = 0;
        var only: []const u8 = "";
        for (members) |m| {
            if (!std.mem.eql(u8, diag.baseName(m.name), r.name)) continue;
            count += 1;
            only = m.data;
        }
        if (count == 0) return refuse(d, alloc, "runtime: the wheel carries no {s}", .{r.name});
        if (count > 1) return refuse(d, alloc, "runtime: the wheel carries {s} {d} times ({s}), and a process holds one Mojo runtime", .{ r.name, count, try wherever(alloc, members, r.name) });
        if (!std.mem.eql(u8, only, r.data)) {
            var got: [32]u8 = undefined;
            var want: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(only, &got, .{});
            std.crypto.hash.sha2.Sha256.hash(r.data, &want, .{});
            return refuse(d, alloc, "runtime: {s} is not the toolchain's (sha256 {s}, the toolchain's {s})", .{ try wherever(alloc, members, r.name), &std.fmt.bytesToHex(got, .lower), &std.fmt.bytesToHex(want, .lower) });
        }
    }

    var roots = std.ArrayList([]const u8).empty;
    try roots.append(alloc, p.entry);
    try roots.appendSlice(alloc, p.opened);
    var loaded = std.ArrayList([]const u8).empty;
    for (roots.items) |root| {
        const walked = if (is_macho) try walkMachO(alloc, d, root, package, members) else try walkElf(alloc, d, root, package, members);
        for (walked) |w| {
            if (!has(loaded.items, w)) try loaded.append(alloc, w);
        }
    }

    for (members) |m| {
        if (!(elf.isElf(m.data) or macho.isMachO(m.data)) or has(loaded.items, m.name)) continue;
        if (p.opened.len == 0) return refuse(d, alloc, "stray: {s} is a shared library that {s} does not load", .{ m.name, p.entry });
        return refuse(d, alloc, "stray: {s} is a shared library that neither {s} nor {s} loads", .{ m.name, p.entry, try std.mem.join(alloc, " nor ", p.opened) });
    }
    return finish(alloc, d, p, members, info, try loaded.toOwnedSlice(alloc));
}

/// ld.so's walk from the ELF library `entry`: the member paths loaded, in
/// load order.
fn walkElf(alloc: Alloc, d: *Diag, entry_path: []const u8, package: []const u8, members: []const policy.Member) Refused![]const []const u8 {
    var loaded = std.ArrayList([]const u8).empty;
    try loaded.append(alloc, entry_path);
    var i: usize = 0;
    while (i < loaded.items.len) : (i += 1) {
        const path = loaded.items[i];
        const lib = find(members, path).?;
        const dir = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
        const got = try elf.read(alloc, d, path, lib.data);
        var dirs = std.ArrayList([]const u8).empty;
        for (got.runpath) |r| {
            const to = (try runDir(alloc, dir, r)) orelse
                return refuse(d, alloc, "runpath: {s} has the run path entry `{s}`, which is not $ORIGIN-relative", .{ path, r });
            if (to.len == 0 or !std.mem.eql(u8, topDir(to), package))
                return refuse(d, alloc, "runpath: {s} has the run path entry `{s}`, which leads out of {s}/", .{ path, r, package });
            try dirs.append(alloc, to);
        }
        next: for (got.needed) |n| {
            if (std.mem.indexOfScalar(u8, n, '/') != null)
                return refuse(d, alloc, "needed: {s} needs `{s}`, a path the loader opens as it is, not from the wheel", .{ path, n });
            if (has(&policy.system_libs, n)) continue;
            for (loaded.items) |l| if (std.mem.eql(u8, diag.baseName(l), n)) continue :next;
            for (dirs.items) |dr| {
                const cand = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dr, n });
                const m = find(members, cand) orelse continue;
                if (!elf.isElf(m.data)) return refuse(d, alloc, "needed: {s} needs {s}, and its run path reaches {s}, which is not an ELF file", .{ path, n, cand });
                try loaded.append(alloc, cand);
                continue :next;
            }
            const why = if (got.runpath.len == 0)
                try std.fmt.allocPrint(alloc, "needed: {s} needs {s}, and has no run path to find it in the wheel", .{ path, n })
            else
                try std.fmt.allocPrint(alloc, "needed: {s} needs {s}, which its run path `{s}` does not reach in the wheel", .{ path, n, try std.mem.join(alloc, ":", got.runpath) });
            const elsewhere = try wherever(alloc, members, n);
            if (elsewhere.len != 0) return refuse(d, alloc, "{s} (the wheel has it at {s})", .{ why, elsewhere });
            return refuse(d, alloc, "{s}, and it is not a manylinux system library", .{why});
        }
    }
    return loaded.toOwnedSlice(alloc);
}

/// dyld's walk from the Mach-O library `entry`: the member paths loaded, in
/// load order.
fn walkMachO(alloc: Alloc, d: *Diag, entry_path: []const u8, package: []const u8, members: []const policy.Member) Refused![]const []const u8 {
    var loaded = std.ArrayList([]const u8).empty;
    try loaded.append(alloc, entry_path);
    var i: usize = 0;
    while (i < loaded.items.len) : (i += 1) {
        const path = loaded.items[i];
        const lib = find(members, path).?;
        const dir = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse 0];
        const got = try macho.read(alloc, d, path, lib.data);
        var dirs = std.ArrayList([]const u8).empty;
        for (got.rpaths) |r| {
            const to = (try loaderDir(alloc, dir, r)) orelse
                return refuse(d, alloc, "runpath: {s} has the run path entry `{s}`, which is not @loader_path-relative", .{ path, r });
            if (to.len == 0 or !std.mem.eql(u8, topDir(to), package))
                return refuse(d, alloc, "runpath: {s} has the run path entry `{s}`, which leads out of {s}/", .{ path, r, package });
            try dirs.append(alloc, to);
        }
        next: for (got.loads) |n| {
            if (systemLibrary(n)) continue;
            if (std.mem.startsWith(u8, n, "@rpath/") and std.mem.indexOfScalar(u8, n["@rpath/".len..], '/') == null and n.len > "@rpath/".len) {
                const file = n["@rpath/".len..];
                for (loaded.items) |l| if (std.mem.eql(u8, diag.baseName(l), file)) continue :next;
                for (dirs.items) |dr| {
                    const cand = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dr, file });
                    const m = find(members, cand) orelse continue;
                    if (!macho.isMachO(m.data)) return refuse(d, alloc, "needed: {s} loads {s}, and its run path reaches {s}, which is not a Mach-O file", .{ path, n, cand });
                    try loaded.append(alloc, cand);
                    continue :next;
                }
                const why = if (got.rpaths.len == 0)
                    try std.fmt.allocPrint(alloc, "needed: {s} loads {s}, and has no run path to find it in the wheel", .{ path, n })
                else
                    try std.fmt.allocPrint(alloc, "needed: {s} loads {s}, which its run path `{s}` does not reach in the wheel", .{ path, n, try std.mem.join(alloc, ":", got.rpaths) });
                const elsewhere = try wherever(alloc, members, file);
                if (elsewhere.len != 0) return refuse(d, alloc, "{s} (the wheel has it at {s})", .{ why, elsewhere });
                return refuse(d, alloc, "{s}", .{why});
            }
            if (std.mem.startsWith(u8, n, "@loader_path/")) {
                const to = (try underDir(alloc, dir, n["@loader_path".len..])) orelse "";
                if (to.len != 0 and std.mem.eql(u8, topDir(to), package) and !std.mem.eql(u8, to, dir)) {
                    for (loaded.items) |l| if (std.mem.eql(u8, l, to)) continue :next;
                    if (find(members, to)) |m| {
                        if (!macho.isMachO(m.data)) return refuse(d, alloc, "needed: {s} loads {s}, which is {s}, not a Mach-O file", .{ path, n, to });
                        try loaded.append(alloc, to);
                        continue :next;
                    }
                    return refuse(d, alloc, "needed: {s} loads {s}, and the wheel has no {s}", .{ path, n, to });
                }
                return refuse(d, alloc, "needed: {s} loads `{s}`, which leads out of {s}/", .{ path, n, package });
            }
            return refuse(d, alloc, "needed: {s} loads `{s}`, a path outside the wheel that is not a macOS system library", .{ path, n });
        }
    }
    return loaded.toOwnedSlice(alloc);
}

/// An operating system library: an absolute path under /usr/lib/ or
/// /System/Library/, with no `..` step out of them (native_policy's policy.zig rule).
fn systemLibrary(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/usr/lib/") and !std.mem.startsWith(u8, path, "/System/Library/")) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |x| if (std.mem.eql(u8, x, "..")) return false;
    return true;
}

/// The directory an LC_RPATH entry names for a library in directory `dir`;
/// null when the entry is not `@loader_path`-relative, `""` when it climbs to
/// or above the wheel's root.
fn loaderDir(alloc: Alloc, dir: []const u8, entry: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, entry, "@loader_path")) return null;
    return underDir(alloc, dir, entry["@loader_path".len..]);
}

/// The licence and requirement checks, after the walk; returns `loaded`.
fn finish(alloc: Alloc, d: *Diag, p: Policy, members: []const policy.Member, info: []const u8, loaded: []const []const u8) Refused![]const []const u8 {
    const metadata = find(members, try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info})) orelse
        return refuse(d, alloc, "licence: the wheel has no {s}/METADATA", .{info});
    const listed = try check_mod.headerValues(alloc, metadata.data, "License-File");
    for (p.runtime_licenses) |name| {
        const at = try std.fmt.allocPrint(alloc, "{s}/licenses/{s}", .{ info, name });
        const m = find(members, at) orelse return refuse(d, alloc, "licence: the wheel carries the Mojo runtime and no {s}", .{at});
        if (m.data.len == 0) return refuse(d, alloc, "licence: {s} is empty", .{at});
        if (!has(listed, name)) return refuse(d, alloc, "licence: METADATA has no `License-File: {s}`", .{name});
    }

    const reqs = try check_mod.headerValues(alloc, metadata.data, "Requires-Dist");
    for (reqs) |req| {
        var end: usize = 0;
        while (end < req.len and (std.ascii.isAlphanumeric(req[end]) or req[end] == '-' or req[end] == '_' or req[end] == '.')) end += 1;
        const name = try normalise(alloc, req[0..end]);
        if (!has(p.runtime_dists, name)) continue;
        return refuse(d, alloc, "requires: METADATA requires {s} (`Requires-Dist: {s}`), which carries a second Mojo runtime", .{ name, req });
    }
    return loaded;
}

pub const flags = [_][]const u8{ "--wheel", "--entry", "--opened", "--runtime-lib", "--runtime-license", "--runtime-dist", "--expect-refusal", "--out" };

/// What `komira_wheel libs` writes: the marker, and the path it goes to.
pub const Result = struct { out: []const u8, marker: []const u8 };

/// `komira_wheel libs <argv>`: the flags (main.zig's usage) parsed, the files
/// they name read with `files.read(alloc, d, path)`, the wheel checked; the
/// marker lists the libraries the entry and each `--opened` library load, one
/// member path a line.
/// With `--expect-refusal TEXT` the run is a negative case: it ends ok, with the
/// marker `refused: TEXT`, only if the check refuses the wheel with exactly
/// TEXT, and is refused itself if the wheel passes or is refused otherwise.
pub fn command(alloc: Alloc, d: *Diag, argv: []const []const u8, files: anytype) Refused!Result {
    const a = try cli.parseOnly(alloc, d, argv, &flags);
    var runtime = std.ArrayList(Runtime).empty;
    for (try a.all(alloc, "--runtime-lib")) |r| {
        const kv = try cli.named(alloc, d, r, "--runtime-lib");
        try runtime.append(alloc, .{ .name = kv[0], .data = try files.read(alloc, d, kv[1]) });
    }
    if (runtime.items.len == 0) return refuse(d, alloc, "missing --runtime-lib", .{});
    const p = Policy{
        .entry = try a.one(alloc, d, "--entry"),
        .opened = try a.all(alloc, "--opened"),
        .runtime = runtime.items,
        .runtime_licenses = try a.all(alloc, "--runtime-license"),
        .runtime_dists = try a.all(alloc, "--runtime-dist"),
    };
    const out = try a.one(alloc, d, "--out");
    const expect = try a.opt(alloc, d, "--expect-refusal");
    const bytes = try files.read(alloc, d, try a.one(alloc, d, "--wheel"));
    const loaded = readAndCheck(alloc, d, p, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Refused => {
            const want = expect orelse return err;
            if (!std.mem.eql(u8, d.msg, want)) return refuse(d, alloc, "the wheel is refused with `{s}`, not the expected `{s}`", .{ d.msg, want });
            return .{ .out = out, .marker = try std.fmt.allocPrint(alloc, "refused: {s}\n", .{want}) };
        },
    };
    if (expect) |want| return refuse(d, alloc, "the wheel passes, and the case expects it refused with `{s}`", .{want});
    var marker = std.ArrayList(u8).empty;
    for (loaded) |l| {
        try marker.appendSlice(alloc, l);
        try marker.append(alloc, '\n');
    }
    return .{ .out = out, .marker = try marker.toOwnedSlice(alloc) };
}

fn readAndCheck(alloc: Alloc, d: *Diag, p: Policy, bytes: []const u8) Refused![]const []const u8 {
    var members = std.ArrayList(policy.Member).empty;
    for (try zip.read(alloc, d, bytes)) |m| try members.append(alloc, .{ .name = m.name, .data = m.data });
    return check(alloc, d, p, members.items);
}
