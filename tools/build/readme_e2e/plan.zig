//! The two files of mopm the e2e reads and writes: a staged set's `plan.json`
//! (spec/staged-set.md of mopm: the members of a release in dependency order,
//! each with the files and hashes that will be published) and the `mopm.lock`
//! a project gets from `mopm add` (spec/lock.md, version 3). Packages are named by their full
//! name, `<namespace>/<name>`: the part after the slash is the import name.
//!
//! Only the keys the e2e uses are read; others are ignored, as mopm's own
//! readers ignore the keys they do not know within a version.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Invalid, OutOfMemory };

fn invalid(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = std.fmt.allocPrint(a, fmt, args) catch "invalid file";
    return error.Invalid;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// A name that is one path segment: what `plan.json` and a lock may give as a
/// file name or a subdir (no `/`, no `\`, none starting with a dot).
pub fn plainName(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    return std.mem.indexOfAny(u8, s, "/\\") == null;
}

/// A relative path below a directory: no empty, `.` or `..` segment, no `\`.
pub fn relativePath(s: []const u8) bool {
    if (s.len == 0 or s[0] == '/' or std.mem.indexOfScalar(u8, s, '\\') != null) return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

// ---- names ------------------------------------------------------------------

pub const Name = struct { namespace: []const u8, name: []const u8 };

/// A full name `<namespace>/<name>` split at its one slash; null when it has none, or when either
/// side is empty or holds another slash.
pub fn splitName(full: []const u8) ?Name {
    const slash = std.mem.indexOfScalar(u8, full, '/') orelse return null;
    const ns = full[0..slash];
    const name = full[slash + 1 ..];
    if (ns.len == 0 or name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return .{ .namespace = ns, .name = name };
}

/// The name Mojo code imports, and that `lib/mojo/<name>.mojoc`, `<name>.mopm.json` and `<name>.bins/`
/// are named by: the part of a full name after the slash. A name without one is its own import name.
pub fn importName(full: []const u8) []const u8 {
    return if (splitName(full)) |n| n.name else full;
}

// ---- plan.json --------------------------------------------------------------

/// The version of `plan.json` that names its members by full name (spec/staged-set.md).
pub const plan_version: u32 = 2;

pub const PlanFile = struct {
    subdir: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
};

pub const Member = struct {
    name: []const u8,
    version: []const u8,
    action: []const u8,
    manifest_sha256: ?[]const u8 = null,
    files: []const PlanFile = &.{},
    readme: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

pub const Plan = struct {
    version: u32,
    members: []const Member,

    pub fn member(self: Plan, name: []const u8) ?Member {
        for (self.members) |m| {
            if (std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }
};

pub fn parsePlan(a: Allocator, text: []const u8, why: *[]const u8) Error!Plan {
    const plan = std.json.parseFromSliceLeaky(Plan, a, text, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(a, why, "plan.json: {s}", .{@errorName(e)}),
    };
    if (plan.version != plan_version) return invalid(a, why, "plan.json: version {d}, and only {d} is read", .{ plan.version, plan_version });
    for (plan.members, 0..) |m, i| {
        if (m.name.len == 0 or m.version.len == 0) return invalid(a, why, "plan.json: member {d} has no name or version", .{i});
        if (splitName(m.name) == null) return invalid(a, why, "plan.json: member {s} has no namespace: a name is <namespace>/<name>", .{m.name});
        for (plan.members[0..i]) |p| {
            if (std.mem.eql(u8, p.name, m.name)) return invalid(a, why, "plan.json: {s} is a member twice", .{m.name});
        }
        const known = [_][]const u8{ "upload", "skip", "refuse" };
        var ok = false;
        for (known) |k| ok = ok or std.mem.eql(u8, k, m.action);
        if (!ok) return invalid(a, why, "plan.json: {s}: action {s} is not upload, skip or refuse", .{ m.name, m.action });
    }
    return plan;
}

/// `plan` as the bytes of a plan.json: two-space indent, keys in the order of
/// the structs above, optional keys left out when null.
pub fn renderPlan(a: Allocator, plan: Plan) Error![]u8 {
    const body = try std.json.Stringify.valueAlloc(a, plan, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    return std.mem.concat(a, u8, &.{ body, "\n" });
}

// ---- mopm.lock --------------------------------------------------------------

/// The one `lock_version` mopm 0.0.113 writes (spec/lock.md). Version 1 and 2 locks predate
/// namespaces: their names are bare and their files `mojo-<name>-...`.
pub const lock_version: u32 = 3;

/// One build of a package, for one Mojo version.
pub const Artifact = struct {
    build: []const u8 = "",
    url: []const u8 = "",
    sha256: []const u8 = "",
    size: u64 = 0,

    /// The file name the artifact's `url` ends in.
    pub fn filename(self: Artifact) []const u8 {
        return std.fs.path.basename(self.url);
    }
};

pub const Locked = struct {
    /// The full name, `<namespace>/<name>`.
    name: []const u8,
    version: []const u8,
    subdir: []const u8 = "",
    channel: []const u8 = "",
    /// The builds, keyed by the Mojo version each was built with.
    artifacts: std.json.ArrayHashMap(Artifact) = .{},
    /// `path` for a path dependency, which has no file.
    source: ?[]const u8 = null,
    deps: []const []const u8 = &.{},
    native: []const std.json.Value = &.{},

    pub fn isPath(self: Locked) bool {
        return self.source != null;
    }

    /// The build for Mojo `mojo`, if the lock has one.
    pub fn artifact(self: Locked, mojo: []const u8) ?Artifact {
        return self.artifacts.map.get(mojo);
    }
};

pub const Lock = struct {
    lock_version: u32,
    packages: []const Locked,

    pub fn find(self: Lock, name: []const u8) ?Locked {
        for (self.packages) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

/// The file name mopm gives a package: `mojo-<namespace>.<name>-<version>-<build>.conda`, for the full
/// name `<namespace>/<name>`. Null for a name without a namespace.
pub fn packageFile(a: Allocator, full: []const u8, version: []const u8, build: []const u8) !?[]u8 {
    const n = splitName(full) orelse return null;
    return try std.fmt.allocPrint(a, "mojo-{s}.{s}-{s}-{s}.conda", .{ n.namespace, n.name, version, build });
}

pub fn parseLock(a: Allocator, text: []const u8, why: *[]const u8) Error!Lock {
    const lock = std.json.parseFromSliceLeaky(Lock, a, text, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(a, why, "mopm.lock: {s}", .{@errorName(e)}),
    };
    if (lock.lock_version != lock_version) {
        return invalid(a, why, "mopm.lock: lock_version {d}; mopm writes {d} for the e2e's project (a lock before namespaces is 1 or 2), and only {d} is read", .{ lock.lock_version, lock_version, lock_version });
    }
    for (lock.packages) |p| {
        if (splitName(p.name) == null) {
            return invalid(a, why, "mopm.lock: package {s} has no namespace: every name of a version {d} lock is <namespace>/<name>", .{ p.name, lock_version });
        }
        if (p.isPath()) continue;
        if (!plainName(p.subdir)) return invalid(a, why, "mopm.lock: {s} {s}: the subdir {s} is not a plain name", .{ p.name, p.version, p.subdir });
        var it = p.artifacts.map.iterator();
        while (it.next()) |e| {
            const art = e.value_ptr.*;
            const want = (try packageFile(a, p.name, p.version, art.build)).?;
            if (!std.mem.eql(u8, art.filename(), want)) {
                return invalid(a, why, "mopm.lock: {s} {s}: the url {s} does not end in {s}", .{ p.name, p.version, art.url, want });
            }
        }
    }
    return lock;
}

/// A version 3 lock of `packages`, in the form mopm writes: sorted by name.
pub fn renderLock(a: Allocator, mojo: []const u8, packages: []const Locked) Error![]u8 {
    const Out = struct {
        lock_version: u32,
        mojo: []const []const u8,
        toolchain: struct {},
        channels: []const []const u8,
        packages: []const Locked,
    };
    const body = try std.json.Stringify.valueAlloc(a, Out{
        .lock_version = lock_version,
        .mojo = &.{mojo},
        .toolchain = .{},
        .channels = &.{"https://conda.mopm.dev/"},
        .packages = packages,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    return std.mem.concat(a, u8, &.{ body, "\n" });
}

// ---- <name>.mopm.json -------------------------------------------------------

pub const Metadata = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    deps: []const struct { name: []const u8 } = &.{},
    native: []const std.json.Value = &.{},
};

pub fn parseMetadata(a: Allocator, text: []const u8, why: *[]const u8) Error!Metadata {
    return std.json.parseFromSliceLeaky(Metadata, a, text, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(a, why, "package metadata: {s}", .{@errorName(e)}),
    };
}
