//! `release_staged_verify add`: what a user gets from prod when they add a package of this release.
//!
//!   release_staged_verify add --staged <dir> --mopm <file> --work <dir>
//!
//! `prod-add` of release.yml runs it after `prod-commit` and `prod-smoke`, when the group is visible.
//! `--staged` is the committed set (`plan.json` is what this release published), `--mopm` the pinned mopm
//! binary the stage job built (the one that staged and committed the set), and `--work` a directory that
//! must not exist: it is made here, so nothing of an earlier run is read, and the toolchain cache is in it.
//! Both are absolute paths (mopm runs in `<work>/project`, where a relative one would mean something else).
//!
//! In `<work>/project` it runs, as a user would, and stops at the first that exits other than 0, failing with
//! the command and the first line mopm wrote to stderr:
//!
//!   mopm init --name release-check/prod_add
//!   (set `[toolchain] mojo` of the mopm.toml init wrote to the Mojo this release was built for)
//!   mopm add komira-ai/<name> --registry prod      (once for each name of `add_set`)
//!   mopm sync --registry prod --cache <work>/cache
//!
//! `mopm init` writes the Mojo of its own default (`mojo = "1.0.0"` for mopm 0.0.138), and `mopm add` resolves the
//! newest version built for the project's Mojo, so a project left at that default gets the last release built for
//! it, not this one. A user who builds for this release's Mojo edits that line, and so does `add`: the version is
//! the `<mojo>` of the build string `mojo<mojo>_<n>` of every file of `add_set` in the plan (`releaseMojo`), which
//! must name one Mojo; the mopm.toml must hold exactly one `mojo =` line in `[toolchain]` (`setMojo`). Either
//! failing is refused before `mopm add` runs.
//!
//! Then it reads the `mopm.lock` they wrote and refuses, reporting every difference at once:
//!  - a `lock_version` other than 3, a `channels` other than exactly [`prod_channel`], or a `mojo` other than
//!    exactly [the release's Mojo];
//!  - an entry whose name is not a full name (`<namespace>/<name>`), whose `channel` is not
//!    `prod_channel` followed by its namespace and `/` (the namespace's own channel), whose name is not a
//!    member of the plan, whose version is not the plan's (the version of this run), or an artifact whose
//!    `url` is not `<channel><subdir>/<file>` for a file of the plan with the plan's sha256 and size;
//!  - a name of `add_set` that the lock does not hold.
//! For each entry of the host's subdir (or `noarch`) it then reads what `mopm sync` installed: the file
//! `.mopm/pkgs/<file>` must have the plan's sha256 and size, the environment's record
//! `.mopm/env/conda-meta/<file without .conda>.json` must name the plan's sha256, and
//! `.mopm/env/lib/mojo/<import name>.mopm.json` must be there.
//!
//! It holds no credential and writes nothing to a registry. mopm is reached through a `Runner` and the files
//! through the directory, so the cases (release_staged_verify_test.zig) run a mopm in memory.
const std = @import("std");
const rbf = @import("release_beta_fetch.zig");

const Allocator = std.mem.Allocator;

/// The one channel root prod serves; each namespace is its own channel below it.
pub const prod_channel = "https://conda.mopm.dev/";

/// The packages `add` installs from prod, from release/readme_e2e/packages.bzl: a library with no
/// dependency (json), one with dependencies (uuid: atomic_alias, awslc, clock) and one that ships a native
/// library (libc: `[native.komira_libc_posix]`).
pub const add_set = [_][]const u8{ "komira-ai/json", "komira-ai/uuid", "komira-ai/libc" };

/// The full name of the project `add` makes. Its namespace is no one's on prod, and nothing is published.
pub const project_name = "release-check/prod_add";

/// The most of mopm's stdout and stderr a run keeps (`mopm sync` prints a line per file).
pub const max_output_bytes: usize = 16 * 1024 * 1024;
const max_lock_bytes: usize = 16 * 1024 * 1024;
const max_record_bytes: usize = 4 * 1024 * 1024;

/// How a run of mopm ended.
pub const Ran = struct {
    /// The exit status; null when mopm did not exit (a signal, or stopped).
    code: ?u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

/// Runs `argv` in `cwd`. An error is a mopm that could not be started or read.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran,

    pub fn run(self: Runner, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        return self.runFn(self.ctx, a, argv, cwd);
    }
};

/// The runner of the command line: a child process with the environment of this one, no stdin, and stdout and
/// stderr kept up to `max_output` bytes each (more is an error of the run).
pub const Process = struct {
    max_output: usize = max_output_bytes,

    pub fn runner(self: *Process) Runner {
        return .{ .ctx = self, .runFn = run };
    }

    fn run(ctx: *anyopaque, a: Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        const self: *Process = @ptrCast(@alignCast(ctx));
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .max_output_bytes = self.max_output });
        const code: ?u8 = switch (r.term) {
            .Exited => |c| c,
            else => null,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};

/// The conda subdir of a host, as mopm names it, or null when mopm installs no toolchain there.
pub fn subdirOf(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "linux-64",
            .aarch64 => "linux-aarch64",
            else => null,
        },
        .macos => if (arch == .aarch64) "osx-arm64" else null,
        else => null,
    };
}

pub const Report = struct { members: usize, entries: usize };

fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) rbf.Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

/// The first line of `text` that is not blank, without its line end; a fixed text when there is none.
pub fn firstLine(text: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len != 0) return t;
    }
    return "(nothing on stderr)";
}

fn hexSha(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn memberOf(plan: rbf.Plan, name: []const u8) ?rbf.Member {
    for (plan.members) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn fileOf(m: rbf.Member, subdir: []const u8, filename: []const u8) ?rbf.File {
    for (m.files) |f| if (std.mem.eql(u8, f.subdir, subdir) and std.mem.eql(u8, f.filename, filename)) return f;
    return null;
}

/// Runs one mopm command in `cwd`; refuses, naming the command, when it cannot start or exits other than 0.
fn runStep(a: Allocator, why: *[]const u8, runner: Runner, mopm: []const u8, args: []const []const u8, cwd: []const u8, log: *std.Io.Writer) !void {
    const shown = try std.mem.join(a, " ", args);
    const argv = try a.alloc([]const u8, args.len + 1);
    argv[0] = mopm;
    @memcpy(argv[1..], args);
    try log.print("$ mopm {s}\n", .{shown});
    const r = runner.run(a, argv, cwd) catch |e|
        return refuse(a, why, "`mopm {s}` could not run {s}: {s}", .{ shown, mopm, @errorName(e) });
    try log.writeAll(r.stdout);
    try log.writeAll(r.stderr);
    try log.flush();
    const code = r.code orelse return refuse(a, why, "`mopm {s}` did not exit (killed by a signal): {s}", .{ shown, firstLine(r.stderr) });
    if (code != 0) return refuse(a, why, "`mopm {s}` exited with {d}: {s}", .{ shown, code, firstLine(r.stderr) });
}

const LockArtifact = struct {
    build: []const u8 = "",
    url: []const u8 = "",
    sha256: []const u8 = "",
    size: u64 = 0,
};

const LockEntry = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    source: []const u8 = "registry",
    subdir: []const u8 = "",
    channel: []const u8 = "",
    artifacts: std.json.ArrayHashMap(LockArtifact) = .{},
};

const Lock = struct {
    lock_version: u32 = 0,
    mojo: []const []const u8 = &.{},
    channels: []const []const u8 = &.{},
    packages: []const LockEntry = &.{},
};

/// The Mojo version this release built `names` for (header). Every file of each name is
/// `mojo-<namespace>.<name>-<version>-mojo<mojo>_<n>.conda`; a file named otherwise, files that name two Mojo
/// versions (one compiler builds a release), or names with no file at all are refused.
pub fn releaseMojo(a: Allocator, why: *[]const u8, plan: rbf.Plan, names: []const []const u8) ![]const u8 {
    var found: ?[]const u8 = null;
    var from: []const u8 = "";
    for (names) |n| {
        const m = memberOf(plan, n) orelse return refuse(a, why, "{s} is not a member of plan.json", .{n});
        const conda = try std.mem.replaceOwned(u8, a, m.name, "/", ".");
        const prefix = try std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo", .{ conda, m.version });
        for (m.files) |f| {
            const ok = std.mem.startsWith(u8, f.filename, prefix) and std.mem.endsWith(u8, f.filename, ".conda");
            const build = if (ok) f.filename[prefix.len .. f.filename.len - ".conda".len] else "";
            const us = std.mem.lastIndexOfScalar(u8, build, '_') orelse 0;
            if (us == 0 or us + 1 == build.len) return refuse(a, why, "{s}: {s} is not named {s}<mojo>_<n>.conda, so it names no Mojo version", .{ n, f.filename, prefix });
            const mojo = build[0..us];
            if (found) |seen| {
                if (!std.mem.eql(u8, seen, mojo)) return refuse(a, why, "plan.json names two Mojo versions for the packages add installs: {s} ({s}) and {s} ({s}); a project is set to one", .{ seen, from, mojo, f.filename });
            } else {
                found = mojo;
                from = f.filename;
            }
        }
    }
    return found orelse return refuse(a, why, "plan.json lists no file for {s}, so it names no Mojo version", .{try std.mem.join(a, ", ", names)});
}

/// `toml` with the one `mojo = ...` line of its `[toolchain]` table replaced by `mojo = "<mojo>"` (header). A table
/// with no such line, or with more than one, is refused: mopm's template is not the one this was written for.
pub fn setMojo(a: Allocator, why: *[]const u8, toml: []const u8, mojo: []const u8) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(a);
    var table: []const u8 = "";
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, toml, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "[")) table = trimmed;
        const key = std.mem.trimLeft(u8, if (std.mem.startsWith(u8, trimmed, "mojo")) trimmed["mojo".len..] else "", " \t");
        if (std.mem.eql(u8, table, "[toolchain]") and std.mem.startsWith(u8, key, "=")) {
            count += 1;
            try out.writer.print("mojo = \"{s}\"{s}", .{ mojo, if (std.mem.endsWith(u8, line, "\r")) "\r" else "" });
        } else try out.writer.writeAll(line);
    }
    if (count != 1) return refuse(a, why, "the mopm.toml `mopm init` wrote has {d} `mojo =` line(s) in [toolchain]; add sets exactly one to this release's Mojo {s}", .{ count, mojo });
    return out.written();
}

/// An entry of the lock that is one of this release's files, and the file of the plan it pins.
const Pinned = struct { entry: LockEntry, file: rbf.File };

/// Checks every entry of `lock` against the plan (header); appends one line per difference to `bad` and returns the
/// entries of `subdir` (or `noarch`) whose artifact for the first locked Mojo, the one `mopm sync` installs, is the
/// plan's file: the ones the installed files are then checked for.
fn checkLock(a: Allocator, lock: Lock, plan: rbf.Plan, names: []const []const u8, subdir: []const u8, release_mojo: []const u8, bad: *std.ArrayList([]const u8)) ![]const Pinned {
    if (lock.lock_version != 3) try bad.append(a, try std.fmt.allocPrint(a, "mopm.lock has lock_version {d}; lock 3 (full names, a channel per namespace) is the one wanted", .{lock.lock_version}));
    if (lock.channels.len != 1 or !std.mem.eql(u8, lock.channels[0], prod_channel)) {
        const listed = try std.mem.join(a, ", ", lock.channels);
        try bad.append(a, try std.fmt.allocPrint(a, "mopm.lock lists the channel roots [{s}]; wanted exactly [{s}]", .{ listed, prod_channel }));
    }
    if (lock.mojo.len != 1 or !std.mem.eql(u8, lock.mojo[0], release_mojo)) {
        const listed = try std.mem.join(a, ", ", lock.mojo);
        try bad.append(a, try std.fmt.allocPrint(a, "mopm.lock is locked for mojo [{s}]; this release was built for mojo {s}", .{ listed, release_mojo }));
    }
    const mojo: ?[]const u8 = if (lock.mojo.len > 0) lock.mojo[0] else null;
    var pinned = std.ArrayList(Pinned).empty;
    for (lock.packages) |e| {
        if (!std.mem.eql(u8, e.source, "registry")) {
            try bad.append(a, try std.fmt.allocPrint(a, "{s}: locked with source '{s}'; every package of this project comes from the registry", .{ e.name, e.source }));
            continue;
        }
        const ns = rbf.namespaceOf(e.name) orelse {
            try bad.append(a, try std.fmt.allocPrint(a, "{s}: a flat name; lock 3 records the full name <namespace>/<name>", .{e.name}));
            continue;
        };
        const channel = try std.fmt.allocPrint(a, "{s}{s}/", .{ prod_channel, ns });
        if (!std.mem.eql(u8, e.channel, channel)) {
            try bad.append(a, try std.fmt.allocPrint(a, "{s}: channel '{s}'; wanted '{s}', the channel of its namespace", .{ e.name, e.channel, channel }));
            continue;
        }
        const m = memberOf(plan, e.name) orelse {
            try bad.append(a, try std.fmt.allocPrint(a, "{s} {s}: not a member of this release's plan.json", .{ e.name, e.version }));
            continue;
        };
        if (!std.mem.eql(u8, e.version, m.version)) {
            try bad.append(a, try std.fmt.allocPrint(a, "{s}: the lock records version {s}; this release published {s}", .{ e.name, e.version, m.version }));
            continue;
        }
        if (e.artifacts.map.count() == 0) {
            try bad.append(a, try std.fmt.allocPrint(a, "{s} {s}: no artifact in the lock", .{ e.name, e.version }));
            continue;
        }
        var it = e.artifacts.map.iterator();
        while (it.next()) |kv| {
            const art = kv.value_ptr.*;
            const filename = if (std.mem.lastIndexOfScalar(u8, art.url, '/')) |i| art.url[i + 1 ..] else art.url;
            const label = try std.fmt.allocPrint(a, "{s} {s} {s}/{s}", .{ e.name, e.version, e.subdir, filename });
            const f = fileOf(m, e.subdir, filename) orelse {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} is not a file of the plan", .{ label, art.url }));
                continue;
            };
            const url = try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ channel, e.subdir, filename });
            const before = bad.items.len;
            if (!std.mem.eql(u8, art.url, url)) try bad.append(a, try std.fmt.allocPrint(a, "{s}: url '{s}', wanted '{s}'", .{ label, art.url, url }));
            if (!std.mem.eql(u8, art.sha256, f.sha256)) try bad.append(a, try std.fmt.allocPrint(a, "{s}: the lock pins sha256 {s}, the plan says {s}", .{ label, art.sha256, f.sha256 }));
            if (art.size != f.size) try bad.append(a, try std.fmt.allocPrint(a, "{s}: the lock pins size {d}, the plan says {d}", .{ label, art.size, f.size }));
            // the installed files of an entry are read only once its pin is the plan's, so one cause is one line
            if (bad.items.len != before) continue;
            const host = std.mem.eql(u8, e.subdir, subdir) or std.mem.eql(u8, e.subdir, "noarch");
            const installed = mojo != null and std.mem.eql(u8, kv.key_ptr.*, mojo.?);
            if (host and installed) try pinned.append(a, .{ .entry = e, .file = f });
        }
    }
    for (names) |n| {
        var found = false;
        for (lock.packages) |e| found = found or std.mem.eql(u8, e.name, n);
        if (!found) try bad.append(a, try std.fmt.allocPrint(a, "{s}: `mopm add {s}` left it out of mopm.lock", .{ n, n }));
    }
    return pinned.items;
}

/// Checks what `mopm sync` installed for each pinned entry (header); appends one line per difference.
fn checkInstalled(a: Allocator, project: std.fs.Dir, pinned: []const Pinned, bad: *std.ArrayList([]const u8), log: *std.Io.Writer) !void {
    for (pinned) |p| {
        const f = p.file;
        const label = try std.fmt.allocPrint(a, "{s} {s}", .{ p.entry.name, p.entry.version });
        const kept = try std.fmt.allocPrint(a, ".mopm/pkgs/{s}", .{f.filename});
        const max: usize = std.math.cast(usize, f.size +| 1) orelse std.math.maxInt(usize);
        const before = bad.items.len;
        if (project.readFileAlloc(a, kept, max)) |body| {
            const hex = hexSha(body);
            if (body.len != f.size) try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} has size {d}, the plan says {d}", .{ label, kept, body.len, f.size }));
            if (!std.mem.eql(u8, &hex, f.sha256)) try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} has sha256 {s}, the plan says {s}", .{ label, kept, &hex, f.sha256 }));
        } else |e| {
            const what = if (e == error.FileTooBig) "is larger than the plan says" else @errorName(e);
            try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} {s}", .{ label, kept, what }));
        }
        const stem = f.filename[0 .. f.filename.len - @as(usize, if (std.mem.endsWith(u8, f.filename, ".conda")) 6 else 0)];
        const record = try std.fmt.allocPrint(a, ".mopm/env/conda-meta/{s}.json", .{stem});
        if (project.readFileAlloc(a, record, max_record_bytes)) |text| {
            const Rec = struct { sha256: []const u8 = "" };
            const rec = std.json.parseFromSliceLeaky(Rec, a, text, .{ .ignore_unknown_fields = true }) catch Rec{ .sha256 = "(not JSON)" };
            if (!std.mem.eql(u8, rec.sha256, f.sha256)) try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} records sha256 '{s}', the plan says {s}", .{ label, record, rec.sha256, f.sha256 }));
        } else |e| try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} {s}", .{ label, record, @errorName(e) }));
        const import = p.entry.name[(std.mem.indexOfScalar(u8, p.entry.name, '/') orelse 0) + 1 ..];
        const meta = try std.fmt.allocPrint(a, ".mopm/env/lib/mojo/{s}.mopm.json", .{import});
        project.access(meta, .{}) catch |e| try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} {s}", .{ label, meta, @errorName(e) }));
        if (bad.items.len == before) try log.print("installed {s} {s} {s}\n", .{ f.sha256, label, f.filename });
    }
}

/// Sets `[toolchain] mojo` of `<project>/mopm.toml` to `mojo` (`setMojo`), as a user building for it would.
fn setProjectMojo(a: Allocator, why: *[]const u8, project: []const u8, mojo: []const u8, log: *std.Io.Writer) !void {
    var dir = std.fs.cwd().openDir(project, .{}) catch |e| return refuse(a, why, "cannot open {s}: {s}", .{ project, @errorName(e) });
    defer dir.close();
    const text = dir.readFileAlloc(a, "mopm.toml", max_lock_bytes) catch |e|
        return refuse(a, why, "the mopm.toml `mopm init` wrote in {s}: {s}", .{ project, @errorName(e) });
    dir.writeFile(.{ .sub_path = "mopm.toml", .data = try setMojo(a, why, text, mojo) }) catch |e|
        return refuse(a, why, "cannot write mopm.toml in {s}: {s}", .{ project, @errorName(e) });
    try log.print("set [toolchain] mojo = \"{s}\" in mopm.toml: the Mojo this release was built for\n", .{mojo});
}

/// `add` (header). `names` is `add_set` on the command line; `subdir` the host's (`subdirOf`). `log` gets every
/// command, what mopm printed, and one `installed` line per file that matched.
pub fn add(a: Allocator, why: *[]const u8, staged: []const u8, mopm: []const u8, work: []const u8, names: []const []const u8, subdir: []const u8, runner: Runner, log: *std.Io.Writer) !Report {
    const plan = try rbf.parsePlan(a, why, try rbf.readFileIn(a, why, staged, "plan.json", rbf.max_plan_bytes));
    // the child runs in <work>/project, so a relative path would be read from there, not from here
    if (!std.fs.path.isAbsolute(mopm)) return refuse(a, why, "--mopm {s} is not an absolute path", .{mopm});
    if (!std.fs.path.isAbsolute(work)) return refuse(a, why, "--work {s} is not an absolute path", .{work});
    for (names) |n| if (memberOf(plan, n) == null)
        return refuse(a, why, "{s} is not a member of plan.json: this release did not publish it, so it cannot be added from prod", .{n});
    const mojo = try releaseMojo(a, why, plan, names);
    if (std.fs.path.dirname(work)) |parent| std.fs.cwd().makePath(parent) catch |e|
        return refuse(a, why, "cannot make {s}: {s}", .{ parent, @errorName(e) });
    std.fs.cwd().makeDir(work) catch |e| {
        if (e == error.PathAlreadyExists) return refuse(a, why, "--work {s} exists; add runs in a directory it makes", .{work});
        return refuse(a, why, "cannot make --work {s}: {s}", .{ work, @errorName(e) });
    };
    const project = try std.fs.path.join(a, &.{ work, "project" });
    const cache = try std.fs.path.join(a, &.{ work, "cache" });
    for ([_][]const u8{ project, cache }) |d| std.fs.cwd().makeDir(d) catch |e|
        return refuse(a, why, "cannot make {s}: {s}", .{ d, @errorName(e) });

    try runStep(a, why, runner, mopm, &.{ "init", "--name", project_name }, project, log);
    try setProjectMojo(a, why, project, mojo, log);
    for (names) |n| try runStep(a, why, runner, mopm, &.{ "add", n, "--registry", "prod" }, project, log);
    try runStep(a, why, runner, mopm, &.{ "sync", "--registry", "prod", "--cache", cache }, project, log);

    var dir = std.fs.cwd().openDir(project, .{}) catch |e| return refuse(a, why, "cannot open {s}: {s}", .{ project, @errorName(e) });
    defer dir.close();
    const lock_text = dir.readFileAlloc(a, "mopm.lock", max_lock_bytes) catch |e|
        return refuse(a, why, "mopm.lock of {s}: {s}", .{ project, @errorName(e) });
    const lock = std.json.parseFromSliceLeaky(Lock, a, lock_text, .{ .ignore_unknown_fields = true }) catch |e|
        return refuse(a, why, "mopm.lock does not parse: {s}", .{@errorName(e)});
    var bad = std.ArrayList([]const u8).empty;
    const pinned = try checkLock(a, lock, plan, names, subdir, mojo, &bad);
    if (pinned.len == 0 and bad.items.len == 0) try bad.append(a, try std.fmt.allocPrint(a, "mopm.lock pins no file for {s}: nothing was installed", .{subdir}));
    try checkInstalled(a, dir, pinned, &bad, log);
    if (bad.items.len != 0) {
        var all = std.Io.Writer.Allocating.init(a);
        try all.writer.print("{d} problem(s) with what `mopm add` installed from prod:", .{bad.items.len});
        for (bad.items) |b| try all.writer.print("\n  {s}", .{b});
        why.* = all.written();
        return error.Refused;
    }
    return .{ .members = names.len, .entries = lock.packages.len };
}
