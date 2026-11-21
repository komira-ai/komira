//! komira_wheel libs: a finished wheel read from its bytes alone, and refused
//! unless the libraries in it load the way an install of it would load them:
//! from the wheel, through each library's own run path, with the Mojo runtime
//! as its flavour gives it and nothing else beside it. A wheel is bundled
//! (it carries the runtime) or, with `Policy.requirement` set, external (it
//! carries none of it and requires the distribution that installs it). It
//! reads the wheel, the few names
//! of `Policy` and the toolchain's copies of the runtime libraries, and no
//! other input of the rule that wrote the wheel. The zip is read as zip.zig
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
//!            ELF file;
//!   runtime  bundled: each Mojo runtime library is in the wheel exactly once,
//!            with the toolchain's bytes (a process holds one Mojo runtime);
//!            external: no member has a runtime library's file name or bytes;
//!   runpath  every run path entry of a library the entry loads is `$ORIGIN`
//!            or under it, and stays inside the import package once `$ORIGIN`
//!            is the library's own directory;
//!   needed   every DT_NEEDED of a library the entry loads is a manylinux
//!            system library (policy.zig's list), a library already loaded,
//!            or a member at `<run path entry>/<name>` for one of that
//!            library's run path entries, tried in order, or (external) a
//!            runtime library, which the requirement installs; a name holding
//!            `/` (opened as a path, not looked up) is refused;
//!   stray    every ELF member is loaded from the entry: a library nothing
//!            loads is refused;
//!   licence  bundled: each licence file of the runtime is a non-empty member
//!            of `.dist-info/licenses/` and a `License-File` of METADATA;
//!            external: none of them is a member (it carries nothing of the
//!            runtime's);
//!   requires bundled: no Requires-Dist of METADATA names a distribution of
//!            the runtime (a second copy of it); external: the requirement is
//!            a Requires-Dist, and no other line names such a distribution.
//!
//! The walk is the loader's (ld.so(8)): breadth first from the entry, each
//! DT_NEEDED looked up among the libraries already loaded by file name (the
//! SONAME of every library komira ships is its file name) before the run path
//! of the library that needs it. It is stricter than the loader in one way:
//! the DT_RPATH of the libraries that loaded a library is not searched, only
//! the library's own run path (DT_RUNPATH and DT_RPATH as elf.zig reads them).

const std = @import("std");
const check_mod = @import("check.zig");
const cli = @import("cli.zig");
const diag = @import("diag.zig");
const elf = @import("elf.zig");
const policy = @import("policy.zig");
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
    /// The Mojo runtime libraries: carried once each by a bundled wheel, never
    /// by an external one.
    runtime: []const Runtime,
    /// The names of the runtime's licence files under `.dist-info/licenses/`.
    runtime_licenses: []const []const u8,
    /// Distributions that carry the runtime (normalised names): a bundled
    /// wheel requires none of them.
    runtime_dists: []const []const u8,
    /// The external flavour: the Requires-Dist line that installs the
    /// runtime (`mojo-compiler==1.0.0`). Null for a bundled wheel.
    requirement: ?[]const u8 = null,
};

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
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
/// the entry first.
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
    if (!elf.isElf(entry.data)) return refuse(d, alloc, "entry: {s} is not an ELF file", .{p.entry});

    if (p.requirement) |req| {
        for (p.runtime) |r| {
            for (members) |m| {
                if (std.mem.eql(u8, diag.baseName(m.name), r.name))
                    return refuse(d, alloc, "runtime: the external wheel carries {s}, a Mojo runtime library it leaves to {s}", .{ m.name, req });
                if (std.mem.eql(u8, m.data, r.data))
                    return refuse(d, alloc, "runtime: the external wheel carries {s}, the bytes of {s}, a Mojo runtime library it leaves to {s}", .{ m.name, r.name, req });
            }
        }
    } else {
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
    }

    // The loader's walk.
    var loaded = std.ArrayList([]const u8).empty;
    try loaded.append(alloc, p.entry);
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
            if (p.requirement != null) {
                for (p.runtime) |r| if (std.mem.eql(u8, r.name, n)) continue :next;
            }
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

    for (members) |m| {
        if (!elf.isElf(m.data) or has(loaded.items, m.name)) continue;
        return refuse(d, alloc, "stray: {s} is a shared library that {s} does not load", .{ m.name, p.entry });
    }

    const metadata = find(members, try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info})) orelse
        return refuse(d, alloc, "licence: the wheel has no {s}/METADATA", .{info});
    const listed = try check_mod.headerValues(alloc, metadata.data, "License-File");
    for (p.runtime_licenses) |name| {
        const at = try std.fmt.allocPrint(alloc, "{s}/licenses/{s}", .{ info, name });
        if (p.requirement != null) {
            if (find(members, at) != null) return refuse(d, alloc, "licence: the external wheel carries {s}, a licence of the runtime it does not carry", .{at});
            continue;
        }
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
        const want = p.requirement orelse
            return refuse(d, alloc, "requires: METADATA requires {s} (`Requires-Dist: {s}`), which carries a second Mojo runtime", .{ name, req });
        if (!std.mem.eql(u8, req, want))
            return refuse(d, alloc, "requires: METADATA requires {s} (`Requires-Dist: {s}`), and the external wheel's runtime is {s}", .{ name, req, want });
    }
    if (p.requirement) |want| {
        if (!has(reqs, want))
            return refuse(d, alloc, "requires: METADATA does not require {s}, which installs the Mojo runtime the external wheel loads", .{want});
    }
    return loaded.toOwnedSlice(alloc);
}

pub const flags = [_][]const u8{ "--wheel", "--entry", "--runtime-lib", "--runtime-license", "--runtime-dist", "--runtime-requirement", "--expect-refusal", "--out" };

/// What `komira_wheel libs` writes: the marker, and the path it goes to.
pub const Result = struct { out: []const u8, marker: []const u8 };

/// `komira_wheel libs <argv>`: the flags (main.zig's usage) parsed, the files
/// they name read with `files.read(alloc, d, path)`, the wheel checked; the
/// marker lists the libraries the entry loads, one member path a line.
/// `--runtime-requirement` makes the wheel external (`Policy.requirement`). With
/// `--expect-refusal TEXT` the run is a negative case: it ends ok, with the
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
        .runtime = runtime.items,
        .runtime_licenses = try a.all(alloc, "--runtime-license"),
        .runtime_dists = try a.all(alloc, "--runtime-dist"),
        .requirement = try a.opt(alloc, d, "--runtime-requirement"),
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
