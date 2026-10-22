//! What release/ci/mopm_publish.zig runs: the publish of the packages that
//! have mopm targets (`mopm publish`, docs/ci.md, "release.yml").
//!
//! The pieces are plain functions over text and a `runner` (the real one runs
//! the pinned mopm binary as a child process, argv and never a shell; the
//! cases of release/ci/tests/test_mopm_publish.zig use a fake), so every rule
//! is held by a case.
//!
//! For each package of the set (a directory `<name>/` holding `<name>.mojoc`
//! and the `.conda` that `//src/<name>:conda` built):
//!   1. `mopm publish --dry-run` over the checked-in manifest and the built
//!      `.mojoc`. It sends nothing and needs no token. Its `would upload`
//!      line must name the file and the sha256 of the `.conda` the build made:
//!      what would be uploaded is the tested package, byte for byte.
//!   2. In publish mode only, `mopm publish`. A version the registry already
//!      has (it answers "already exists ... versions are immutable") is
//!      skipped, so a re-run of the job is safe; any other refusal is a
//!      failure. A version is never replaced: the registry holds it
//!      immutable, and this program never asks to.
//!
//! In dry-run mode no argv without `--dry-run` is ever run (a case holds it).
//!
//! THE SET IS HELD TO THE PACKAGES: every directory of src/ that has a
//! mopm.toml must be in the set and every package of the set must have one
//! (`checkSync`), so a package moved to mopm and not added to
//! //release:mopm_set (or the reverse) is red on every push to main.
const std = @import("std");

/// One package of the set.
pub const Package = struct {
    name: []const u8,
    /// Path of the built `.mojoc`.
    mojoc: []const u8,
    /// Base name of the built `.conda`: `mojo-<name>-<version>-mojo<compiler>_0.conda`.
    conda_file: []const u8,
    /// sha256 of the built `.conda`, 64 lowercase hex characters.
    conda_sha256: []const u8,
};

pub const RunOut = struct { code: u8, stdout: []const u8, stderr: []const u8 };

pub const Options = struct {
    /// The pinned mopm binary.
    mopm: []const u8,
    /// `prod`, `gamma`, `beta` or a URL: mopm's `--registry`.
    registry: []const u8,
    /// The checkout root: the manifest of a package is `<repo>/src/<name>/mopm.toml`.
    repo: []const u8,
    /// True: only the dry run of each package.
    dry_run: bool,
};

pub const Result = union(enum) {
    /// The dry run passed and nothing was sent (dry-run mode).
    dry_run_ok,
    published,
    /// The registry has this version: nothing was sent.
    already_published,
    /// Why not: the message for the log.
    failed: []const u8,
};

/// The Mojo version a `.conda` was built for, from its file name
/// `mojo-<name>-<version>-mojo<compiler>_0.conda`; null if the name has
/// another shape.
pub fn compilerOf(name: []const u8, conda_file: []const u8) ?[]const u8 {
    const suffix = "_0.conda";
    if (!std.mem.endsWith(u8, conda_file, suffix)) return null;
    // The file is the package's: `mojo-<name>-`.
    if (!std.mem.startsWith(u8, conda_file, "mojo-")) return null;
    const rest = conda_file["mojo-".len..];
    if (!std.mem.startsWith(u8, rest, name)) return null;
    if (rest.len <= name.len or rest[name.len] != '-') return null;
    const stem = conda_file[0 .. conda_file.len - suffix.len];
    const at = std.mem.lastIndexOf(u8, stem, "-mojo") orelse return null;
    if (at < "mojo-".len + name.len) return null;
    const c = stem[at + "-mojo".len ..];
    if (c.len == 0) return null;
    for (c) |ch| if (!(ch >= '0' and ch <= '9') and ch != '.') return null;
    return c;
}

pub const WouldUpload = struct { file: []const u8, sha256: []const u8 };

/// The one `would upload <subdir>/<file> (<n> bytes, sha256 <hex>)` line of a
/// dry run. None or more than one (a package with several files) is null:
/// these packages ship one file, for linux-64.
pub fn parseWouldUpload(out: []const u8) ?WouldUpload {
    const prefix = "would upload linux-64/";
    var found: ?WouldUpload = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "would upload ")) {
            if (found != null) return null;
            if (!std.mem.startsWith(u8, line, prefix)) return null;
            const rest = line[prefix.len..];
            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
            const marker = "sha256 ";
            const m = std.mem.indexOf(u8, rest, marker) orelse return null;
            const tail = rest[m + marker.len ..];
            const close = std.mem.indexOfScalar(u8, tail, ')') orelse return null;
            found = .{ .file = rest[0..sp], .sha256 = tail[0..close] };
        }
    }
    return found;
}

/// Whether mopm's output says the registry already has the version (the
/// registry's own words: "'<name>' <version> already exists (sha256 <hex>);
/// versions are immutable.").
pub fn alreadyExists(out: []const u8) bool {
    return std.mem.indexOf(u8, out, " already exists ") != null and
        std.mem.indexOf(u8, out, "versions are immutable") != null;
}

fn publishArgv(a: std.mem.Allocator, o: Options, pkg: Package, compiler: []const u8, dry: bool) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{
        o.mopm,
        "publish",
        "--compiler",
        compiler,
        "--mojoc",
        try std.fmt.allocPrint(a, "linux-64={s}", .{pkg.mojoc}),
        "--manifest",
        try std.fmt.allocPrint(a, "{s}/src/{s}/mopm.toml", .{ o.repo, pkg.name }),
        "--registry",
        o.registry,
    });
    if (dry) try argv.append(a, "--dry-run");
    return argv.items;
}

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    return .{ .failed = std.fmt.allocPrint(a, fmt, args) catch "out of memory" };
}

/// One package: the dry run, the check of its bytes against the build, and in
/// publish mode the publish. `runner.run(a, argv) !RunOut`.
pub fn publishOne(a: std.mem.Allocator, o: Options, pkg: Package, runner: anytype) Result {
    const compiler = compilerOf(pkg.name, pkg.conda_file) orelse
        return fail(a, "{s}: the built file '{s}' is not named mojo-{s}-<version>-mojo<compiler>_0.conda", .{ pkg.name, pkg.conda_file, pkg.name });
    const dry_argv = publishArgv(a, o, pkg, compiler, true) catch return fail(a, "{s}: out of memory", .{pkg.name});
    const dry = runner.run(a, dry_argv) catch |e| return fail(a, "{s}: running mopm: {s}", .{ pkg.name, @errorName(e) });
    if (dry.code != 0) return fail(a, "{s}: the dry run failed (exit {d}): {s}{s}", .{ pkg.name, dry.code, dry.stdout, dry.stderr });
    const w = parseWouldUpload(dry.stdout) orelse
        return fail(a, "{s}: the dry run has no single 'would upload linux-64/<file>' line: {s}", .{ pkg.name, dry.stdout });
    if (!std.mem.eql(u8, w.file, pkg.conda_file) or !std.mem.eql(u8, w.sha256, pkg.conda_sha256))
        return fail(a, "{s}: publish would upload {s} (sha256 {s}) but the build made {s} (sha256 {s}): not the tested package", .{ pkg.name, w.file, w.sha256, pkg.conda_file, pkg.conda_sha256 });

    if (o.dry_run) return .dry_run_ok;

    const argv = publishArgv(a, o, pkg, compiler, false) catch return fail(a, "{s}: out of memory", .{pkg.name});
    const real = runner.run(a, argv) catch |e| return fail(a, "{s}: running mopm: {s}", .{ pkg.name, @errorName(e) });
    if (real.code == 0) return .published;
    if (alreadyExists(real.stdout) or alreadyExists(real.stderr)) return .already_published;
    return fail(a, "{s}: mopm publish failed (exit {d}): {s}{s}", .{ pkg.name, real.code, real.stdout, real.stderr });
}

/// Null when `listed` (the set's packages) and `found` (the directories of
/// src/ that have a mopm.toml) are the same names; else why not.
pub fn checkSync(a: std.mem.Allocator, listed: []const []const u8, found: []const []const u8) !?[]const u8 {
    var msg = std.ArrayList(u8).empty;
    for (found) |f| {
        if (!contains(listed, f))
            try msg.appendSlice(a, try std.fmt.allocPrint(a, "src/{s} has a mopm.toml but is not in //release:mopm_set; ", .{f}));
    }
    for (listed) |l| {
        if (!contains(found, l))
            try msg.appendSlice(a, try std.fmt.allocPrint(a, "{s} is in //release:mopm_set but src/{s}/mopm.toml does not exist; ", .{ l, l }));
    }
    if (msg.items.len == 0) return null;
    return msg.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Real mopm: a child process, run in the current directory, with this
/// process's environment (`MOPM_TOKEN` among it).
pub const RealRunner = struct {
    pub fn run(self: RealRunner, a: std.mem.Allocator, argv: []const []const u8) anyerror!RunOut {
        _ = self;
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 1 << 22 });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};
