//! plan_expect: the `expect` verb of release_staged_verify (release_staged_verify.zig, beside this file).
//!
//!   release_staged_verify expect --staged <dir> --expect <file>
//!
//! `mopm stage` packs one `.conda` per subdir a member has a library in and writes `plan.json`; `verify`,
//! `smoke` and `add` check the files the plan names, so a plan that lost a platform or a package passes them
//! all. `expect` holds the plan to the set the release builds. `--expect` is the file
//! //release:mopm_plan_expectation writes from release/readme_e2e/packages.bzl (`PACKAGES`) and
//! release/darwin_libs.bzl (`DARWIN_PACKAGES`) (release/plan_expectation.bzl):
//!
//!   {"mojos": ["1.1.0", "1.2.0"], "members": [{"name": "<namespace>/<name>", "subdirs": ["linux-64", "osx-arm64"]}, ...]}
//!
//! `mopm stage` is given one build of every package per Mojo version of the release (`--artifacts <mojo>=<dir>`), and
//! names each file `...-mojo<mojo>_<n>.conda`. When `mojos` lists versions, every member needs one file for every
//! (subdir, Mojo) pair, so a package missing its build for one Mojo on one platform is refused. A plan file whose name
//! carries no Mojo of the list is refused too. With no `mojos` the plan is held per subdir only.
//!
//! It refuses an expectation with no member, a name that is not a full name, a name listed twice, a member
//! with no subdir, a subdir that is not a plain name or is listed twice, a Mojo version that is not digits and dots
//! or is listed twice. It reads `<staged>/plan.json` with
//! release_beta_fetch's plan reader (which refuses a plan it cannot check) and compares the two, reporting
//! every difference at once:
//!  - a package of the expectation that is not a member of the plan;
//!  - a member of the plan that the expectation does not name;
//!  - a member with no file for a subdir the expectation requires (for a Mojo of `mojos`, one file for each);
//!  - a member with a file built for no Mojo of `mojos`;
//!  - a member with a file for a subdir the expectation does not allow;
//!  - a member with more than one file for one subdir (`mopm stage` packs one per subdir).
//! It reads only `plan.json`: it opens none of the `.conda` files and holds no credential. The natives a
//! package ships are inside its `.conda`, not files of the plan, so this check cannot see them.
const std = @import("std");
const rbf = @import("release_beta_fetch.zig");

const Allocator = std.mem.Allocator;

pub const max_expect_bytes: usize = 1024 * 1024;

pub const Expected = struct {
    name: []const u8,
    subdirs: []const []const u8 = &.{},
};

pub const Expectation = struct {
    mojos: []const []const u8 = &.{},
    members: []const Expected = &.{},
};

/// What a plan that holds the expectation has: its members, its files, and the files of each subdir
/// (sorted by subdir).
pub const Report = struct {
    members: usize,
    files: usize,
    subdirs: []const SubdirCount,
};

pub const SubdirCount = struct { subdir: []const u8, files: usize };

fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) rbf.Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

fn plainName(s: []const u8) bool {
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (c == '/' or c == '\\' or c < 0x21 or c == 0x7f) return false;
    return true;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// The Mojo version a staged file name carries: `mojo-<namespace>.<name>-<version>-mojo<mojo>_<n>.conda` has
/// `<mojo>`. Null for a name that has no `-mojo<mojo>_<n>.conda` ending.
pub fn mojoOf(filename: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, filename, ".conda")) return null;
    const stem = filename[0 .. filename.len - ".conda".len];
    const at = std.mem.lastIndexOf(u8, stem, "-mojo") orelse return null;
    const build = stem[at + "-mojo".len ..];
    const us = std.mem.lastIndexOfScalar(u8, build, '_') orelse return null;
    if (us == 0 or us + 1 == build.len) return null;
    return build[0..us];
}

fn mojoVersion(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isDigit(s[0]) or !std.ascii.isDigit(s[s.len - 1])) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or c == '.')) return false;
    return true;
}

/// Parses the expectation file and refuses one that could let a short plan through (see the header).
pub fn parseExpectation(a: Allocator, why: *[]const u8, text: []const u8) rbf.Error!Expectation {
    const exp = std.json.parseFromSliceLeaky(Expectation, a, text, .{ .ignore_unknown_fields = true }) catch |e|
        return refuse(a, why, "the expectation does not parse: {s}", .{@errorName(e)});
    if (exp.members.len == 0) return refuse(a, why, "the expectation names no package: it would let an empty plan through", .{});
    for (exp.mojos, 0..) |v, i| {
        if (!mojoVersion(v)) return refuse(a, why, "the expectation gives the Mojo version '{s}', which is not digits and dots", .{v});
        if (contains(exp.mojos[0..i], v)) return refuse(a, why, "the expectation gives the Mojo version {s} twice", .{v});
    }
    for (exp.members, 0..) |m, i| {
        if (rbf.namespaceOf(m.name) == null) return refuse(a, why, "expectation entry {d}: '{s}' is not a full name <namespace>/<name>", .{ i, m.name });
        for (exp.members[0..i]) |o| if (std.mem.eql(u8, o.name, m.name))
            return refuse(a, why, "the expectation names {s} twice", .{m.name});
        if (m.subdirs.len == 0) return refuse(a, why, "the expectation gives {s} no subdir", .{m.name});
        for (m.subdirs, 0..) |s, j| {
            if (!plainName(s)) return refuse(a, why, "the expectation gives {s} the subdir '{s}', which is not a plain name", .{ m.name, s });
            if (contains(m.subdirs[0..j], s)) return refuse(a, why, "the expectation gives {s} the subdir {s} twice", .{ m.name, s });
        }
    }
    return exp;
}

fn joined(a: Allocator, list: []const []const u8) ![]const u8 {
    return std.mem.join(a, ", ", list);
}

/// Every difference between the plan and the expectation, one line each, in the expectation's order and
/// then the plan's; empty when the plan holds it.
pub fn differences(a: Allocator, plan: rbf.Plan, exp: Expectation) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (exp.members) |e| {
        const member: ?rbf.Member = for (plan.members) |m| {
            if (std.mem.eql(u8, m.name, e.name)) break m;
        } else null;
        const m = member orelse {
            try out.append(a, try std.fmt.allocPrint(a, "{s}: not a member of the plan (expected on {s})", .{ e.name, try joined(a, e.subdirs) }));
            continue;
        };
        for (e.subdirs) |s| {
            if (exp.mojos.len == 0) {
                var n: usize = 0;
                for (m.files) |f| if (std.mem.eql(u8, f.subdir, s)) {
                    n += 1;
                };
                if (n == 0) try out.append(a, try std.fmt.allocPrint(a, "{s}: no file for {s}", .{ e.name, s }));
                if (n > 1) try out.append(a, try std.fmt.allocPrint(a, "{s}: {d} files for {s}, where mopm stage packs one", .{ e.name, n, s }));
                continue;
            }
            for (exp.mojos) |v| {
                var n: usize = 0;
                for (m.files) |f| if (std.mem.eql(u8, f.subdir, s) and std.mem.eql(u8, mojoOf(f.filename) orelse "", v)) {
                    n += 1;
                };
                if (n == 0) try out.append(a, try std.fmt.allocPrint(a, "{s}: no file for {s} built for Mojo {s}", .{ e.name, s, v }));
                if (n > 1) try out.append(a, try std.fmt.allocPrint(a, "{s}: {d} files for {s} built for Mojo {s}, where mopm stage packs one", .{ e.name, n, s, v }));
            }
            for (m.files) |f| if (std.mem.eql(u8, f.subdir, s) and !contains(exp.mojos, mojoOf(f.filename) orelse "")) {
                try out.append(a, try std.fmt.allocPrint(a, "{s}: a file for {s} ({s}) built for no Mojo the expectation lists (only {s})", .{ e.name, s, f.filename, try joined(a, exp.mojos) }));
            };
        }
        for (m.files) |f| if (!contains(e.subdirs, f.subdir)) {
            try out.append(a, try std.fmt.allocPrint(a, "{s}: a file for {s} ({s}), a subdir the expectation does not allow (only {s})", .{ e.name, f.subdir, f.filename, try joined(a, e.subdirs) }));
        };
    }
    for (plan.members) |m| {
        const named = for (exp.members) |e| {
            if (std.mem.eql(u8, e.name, m.name)) break true;
        } else false;
        if (!named) try out.append(a, try std.fmt.allocPrint(a, "{s}: a member of the plan that the expectation does not name", .{m.name}));
    }
    return out.items;
}

fn lessSubdir(_: void, x: SubdirCount, y: SubdirCount) bool {
    return std.mem.lessThan(u8, x.subdir, y.subdir);
}

fn countSubdirs(a: Allocator, plan: rbf.Plan) ![]const SubdirCount {
    var counts = std.ArrayList(SubdirCount).empty;
    for (plan.members) |m| for (m.files) |f| {
        for (counts.items) |*c| {
            if (std.mem.eql(u8, c.subdir, f.subdir)) {
                c.files += 1;
                break;
            }
        } else try counts.append(a, .{ .subdir = f.subdir, .files = 1 });
    };
    std.mem.sort(SubdirCount, counts.items, {}, lessSubdir);
    return counts.items;
}

/// `expect` (header): the plan of `staged` held to the expectation file `expect_path`.
pub fn expect(a: Allocator, why: *[]const u8, staged: []const u8, expect_path: []const u8) !Report {
    const exp_text = std.fs.cwd().readFileAlloc(a, expect_path, max_expect_bytes) catch |e|
        return refuse(a, why, "cannot read the expectation {s}: {s}", .{ expect_path, @errorName(e) });
    const exp = try parseExpectation(a, why, exp_text);
    const plan_text = try rbf.readFileIn(a, why, staged, "plan.json", rbf.max_plan_bytes);
    const plan = try rbf.parsePlan(a, why, plan_text);
    const diff = try differences(a, plan, exp);
    var files: usize = 0;
    for (plan.members) |m| files += m.files.len;
    if (diff.len != 0) {
        var all = std.Io.Writer.Allocating.init(a);
        try all.writer.print("plan.json is not the set the release builds: {d} difference(s) (the expectation names {d} package(s), the plan has {d} member(s) and {d} file(s)):", .{ diff.len, exp.members.len, plan.members.len, files });
        for (diff) |d| try all.writer.print("\n  {s}", .{d});
        why.* = all.written();
        return error.Refused;
    }
    return .{ .members = plan.members.len, .files = files, .subdirs = try countSubdirs(a, plan) };
}

pub const usage = "usage: release_staged_verify expect --staged <dir> --expect <file>\n";

/// `expect` on the command line, after the verb: `--staged` and `--expect`, each given once. Returns the exit
/// status: 0 when the plan holds the expectation, 1 with `EXPECT FAILED: <why>` on `err` when it does not, 2 on
/// a usage error.
pub fn cliExpect(a: Allocator, args: []const []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var staged: ?[]const u8 = null;
    var expect_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const slot: *?[]const u8 = if (std.mem.eql(u8, flag, "--staged")) &staged else if (std.mem.eql(u8, flag, "--expect")) &expect_path else {
            try err.print("release_staged_verify: unknown argument {s}\n{s}", .{ flag, usage });
            try err.flush();
            return 2;
        };
        i += 1;
        if (i >= args.len or slot.* != null) {
            try err.print("release_staged_verify: {s} needs one value, given once\n", .{flag});
            try err.flush();
            return 2;
        }
        slot.* = args[i];
    }
    if (staged == null or expect_path == null) {
        try err.writeAll(usage);
        try err.flush();
        return 2;
    }
    var why: []const u8 = "";
    const rep = expect(a, &why, staged.?, expect_path.?) catch |e| {
        const msg = if (e == error.Refused) why else @errorName(e);
        try err.print("release_staged_verify: EXPECT FAILED: {s}\n", .{msg});
        try err.flush();
        return 1;
    };
    try out.print("release_staged_verify: plan.json stages every package of the expectation, each with one file for every subdir (and every Mojo version) it requires and none other: {d} member(s), {d} file(s) (", .{ rep.members, rep.files });
    for (rep.subdirs, 0..) |s, n| try out.print("{s}{s} {d}", .{ if (n == 0) "" else ", ", s.subdir, s.files });
    try out.writeAll(")\n");
    try out.flush();
    return 0;
}
