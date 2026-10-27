//! mopm_migrate: moves one komira Mojo library from `mojo_library` to buildrules' `mojo_package`
//! and a mopm package, as the hand migrations do (`plan.zig` says what it derives and refuses).
//!
//!   mopm_migrate --package <name> --description <text> [--repo <komira root>] [--mopm 0.0.73]
//!                [--test-layout installed|default] [--dev-dependencies] [--dry-run]
//!
//! `--dry-run` prints the whole plan (the `git mv` list, every file it would write, the rows it would
//! add, what is left to the farm) and writes nothing. Without it the tool runs the `git mv`s,
//! writes the files and `git add`s the new ones; it commits nothing. It prints, for every moved file,
//! the lines of the repository that still name the old path: those are edits for the author to make.
//!
//! The description is a flag because no old file states it: it is the sentence mopm shows.
const std = @import("std");
const plan_mod = @import("plan.zig");

const Allocator = std.mem.Allocator;

pub const RunOptions = struct {
    plan: plan_mod.Options,
    dry_run: bool,
    /// Moves with `git mv` and stages the new files; false renames only (the tests).
    use_git: bool,
};

const text_exts = [_][]const u8{ ".mojo", ".md", ".toml", ".bzl", ".tsv", ".lock", ".txt", ".textproto", ".bxl", ".zig" };
const max_text: usize = 4 << 20;

fn readable(path: []const u8) bool {
    if (std.mem.eql(u8, std.fs.path.basename(path), "BUCK")) return true;
    for (text_exts) |e| if (std.mem.endsWith(u8, path, e)) return true;
    return false;
}

fn addFile(a: Allocator, repo: std.fs.Dir, files: *std.ArrayList(plan_mod.File), path: []const u8) !void {
    const text: ?[]const u8 = if (readable(path)) (repo.readFileAlloc(a, path, max_text) catch null) else null;
    try files.append(a, .{ .path = path, .text = text });
}

/// The files `plan` reads: everything under src/<package>, the BUCK file and manifest of every
/// other package, and the shared rows.
pub fn load(a: Allocator, repo: std.fs.Dir, package: []const u8) !std.ArrayList(plan_mod.File) {
    var files = std.ArrayList(plan_mod.File).empty;
    const pkg_dir = try std.fmt.allocPrint(a, "src/{s}", .{package});
    if (repo.openDir(pkg_dir, .{ .iterate = true })) |opened| {
        var d = opened;
        defer d.close();
        var walker = try d.walk(a);
        defer walker.deinit();
        while (try walker.next()) |e| {
            if (e.kind != .file) continue;
            try addFile(a, repo, &files, try std.fmt.allocPrint(a, "{s}/{s}", .{ pkg_dir, e.path }));
        }
    } else |_| {}
    var src = repo.openDir("src", .{ .iterate = true }) catch return files;
    defer src.close();
    var it = src.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory or std.mem.eql(u8, e.name, package)) continue;
        for ([_][]const u8{ "BUCK", "mopm.toml" }) |f| {
            const path = try std.fmt.allocPrint(a, "src/{s}/{s}", .{ e.name, f });
            repo.access(path, .{}) catch continue;
            try addFile(a, repo, &files, path);
        }
    }
    for ([_][]const u8{ "release/readme_e2e/packages.bzl", "release/mopm_native_ids.bzl", "ci/targets.bzl", "release/BUCK", "release/artifacts.textproto" }) |p| {
        repo.access(p, .{}) catch continue;
        try addFile(a, repo, &files, p);
    }
    return files;
}

fn indented(out: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len == 0 and lines.peek() == null) break;
        try out.print("    {s}\n", .{l});
    }
}

fn runGit(a: Allocator, repo: std.fs.Dir, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, a);
    child.cwd_dir = repo;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitFailed;
}

/// Prints each line of the repository that names a moved file by its old path.
fn followUps(a: Allocator, repo: std.fs.Dir, out: *std.Io.Writer, package: []const u8, moves: []const plan_mod.Move) !void {
    var first = true;
    for (moves) |m| {
        const pattern = try std.fmt.allocPrint(a, "(?<!src/{s}/){s}", .{ package, m.from });
        const exclude = try std.fmt.allocPrint(a, ":!src/{s}/BUCK", .{package});
        const res = std.process.Child.run(.{
            .allocator = a,
            .argv = &.{ "git", "grep", "-nP", pattern, "--", ".", exclude },
            .cwd_dir = repo,
            .max_output_bytes = 1 << 20,
        }) catch continue;
        if (res.stdout.len == 0) continue;
        if (first) try out.writeAll("\nfollow-up: lines that still name a moved file by its old path (edit each; the tool does not):\n");
        first = false;
        try out.print("  {s}:\n", .{m.from});
        try indented(out, res.stdout);
    }
}

pub fn run(a: Allocator, c: *plan_mod.Ctx, repo: std.fs.Dir, ro: RunOptions, out: *std.Io.Writer) !void {
    const files = try load(a, repo, ro.plan.package);
    const p = try plan_mod.plan(c, files.items, ro.plan);
    try out.print("mopm_migrate: plan for src/{s}{s}\n\n", .{ ro.plan.package, if (ro.dry_run) " (dry run: nothing is written)" else "" });
    try out.print("move {d} file(s) into src/{s}/src/{s}/:\n", .{ p.moves.len, ro.plan.package, ro.plan.package });
    for (p.moves) |m| try out.print("  git mv {s} {s}\n", .{ m.from, m.to });
    for (p.writes) |w| {
        try out.print("\n{s} {s}:\n", .{ if (w.replaces) "edit" else "create", w.path });
        try indented(out, w.shown);
    }
    if (p.notes.len > 0) try out.writeAll("\nnotes:\n");
    for (p.notes) |n| try out.print("  - {s}\n", .{n});
    try out.writeAll("\nleft to the farm (this tool builds nothing):\n");
    for (p.farm) |f| try out.print("  - {s}\n", .{f});
    if (ro.dry_run) {
        try out.flush();
        return;
    }
    for (p.moves) |m| {
        if (std.fs.path.dirname(m.to)) |d| try repo.makePath(d);
        if (ro.use_git) {
            try runGit(a, repo, &.{ "git", "mv", m.from, m.to });
        } else try repo.rename(m.from, m.to);
    }
    for (p.writes) |w| {
        try repo.writeFile(.{ .sub_path = w.path, .data = w.text });
        if (ro.use_git and !w.replaces) try runGit(a, repo, &.{ "git", "add", w.path });
    }
    if (ro.use_git) try followUps(a, repo, out, ro.plan.package, p.moves);
    try out.print("\nmopm_migrate: src/{s} migrated in the working tree; nothing is committed\n", .{ro.plan.package});
    try out.flush();
}

fn usage(err: *std.Io.Writer) !u8 {
    try err.writeAll("usage: mopm_migrate --package <name> --description <text> [--repo <dir>] [--mopm <version>] [--test-layout installed|default] [--dev-dependencies] [--dry-run]\n");
    try err.flush();
    return 2;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ebuf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&ebuf);
    var obuf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&obuf);
    const args = try std.process.argsAlloc(a);

    var repo_path: []const u8 = ".";
    var package: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var mopm: []const u8 = "0.0.73";
    var layout: ?[]const u8 = null;
    var dev = false;
    var dry = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--dev-dependencies")) {
            dev = true;
        } else if (std.mem.eql(u8, flag, "--dry-run")) {
            dry = true;
        } else {
            var known = false;
            for ([_][]const u8{ "--package", "--description", "--test-layout", "--repo", "--mopm" }) |k| known = known or std.mem.eql(u8, k, flag);
            if (!known) {
                try err.interface.print("mopm_migrate: unknown argument {s}\n", .{flag});
                return usage(&err.interface);
            }
            i += 1;
            if (i >= args.len) {
                try err.interface.print("mopm_migrate: {s} needs a value\n", .{flag});
                return usage(&err.interface);
            }
            const v = args[i];
            if (std.mem.eql(u8, flag, "--package")) {
                package = v;
            } else if (std.mem.eql(u8, flag, "--description")) {
                description = v;
            } else if (std.mem.eql(u8, flag, "--test-layout")) {
                layout = v;
            } else if (std.mem.eql(u8, flag, "--repo")) {
                repo_path = v;
            } else mopm = v;
        }
    }
    if (package == null or description == null) return usage(&err.interface);

    var repo = std.fs.cwd().openDir(repo_path, .{}) catch |e| {
        try err.interface.print("mopm_migrate: cannot open {s}: {s}\n", .{ repo_path, @errorName(e) });
        try err.interface.flush();
        return 2;
    };
    defer repo.close();
    var c = plan_mod.Ctx{ .a = a };
    run(a, &c, repo, .{
        .plan = .{ .package = package.?, .description = description.?, .mopm = mopm, .test_layout = layout, .dev_dependencies = dev },
        .dry_run = dry,
        .use_git = true,
    }, &out.interface) catch |e| {
        const msg = if (e == error.Refused) c.why else @errorName(e);
        try err.interface.print("mopm_migrate: refused: {s}\n", .{msg});
        try err.interface.flush();
        return 1;
    };
    return 0;
}
