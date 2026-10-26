//! release_json: the release set's tool (docs/ci.md, "release.yml"). The set
//! itself is built by Buck2 (//release:release_set); this program derives the
//! stamp the build is given, holds the set to release/artifacts.textproto, and
//! writes release.json and the set hash once the set is built.
//!
//!   release_json stamp --revision <id> [--work-dir <dir>] [--github-output <file>]
//!       The stamp of the revision, from git (release_lib/stamp.zig), as
//!       `build_number=`, `source_commit=` and `timestamp_ms=` lines.
//!
//!   release_json names --artifacts <file> --out <file> --metapackage <name>
//!       --license <v> --summary <v> --home <v> --extra-file <v> --label-prefix <v>
//!       -- <library name>...
//!       Red unless the artifacts file declares exactly these libraries and
//!       the metapackage, in this order, and gives the metapackage the
//!       arguments the release set gives it (release_lib/artifacts.zig).
//!       Run as a build action of //release:release_set; writes --out.
//!
//!   release_json write --release-dir <dir> --artifacts <file> --revision <id>
//!       --platform <platform> --run-id <id> --attempt <n> --out <file>
//!       [--hash-file <file>] [--summary-file <file>] [--github-output <file>]
//!       [--require-stamped <true|false>]
//!       Checks every member directory of --release-dir (release_lib/
//!       set_json.zig), then writes release.json to --out (kci.release_set
//!       major 2) and the set hash, as 64 hex characters and a newline, to
//!       --hash-file; --github-output gets `set_hash=<hash>`. A member that
//!       is not stamped is refused unless --require-stamped is false (the
//!       pull request's check of an unstamped set).
//!
//! Exit 0 on success, 1 on a refusal (the reason is on standard error), 2 on
//! a usage error.
const std = @import("std");
const lib = @import("release_lib");

const util = lib.util;
const set_json = lib.set_json;

const USAGE =
    \\usage: release_json stamp --revision <id> [--work-dir <dir>] [--github-output <file>]
    \\       release_json names --artifacts <file> --out <file> --metapackage <name> --license <v>
    \\                          --summary <v> --home <v> --extra-file <v> --label-prefix <v> -- <name>...
    \\       release_json write --release-dir <dir> --artifacts <file> --revision <id> --platform <platform>
    \\                          --run-id <id> --attempt <n> --out <file> [--hash-file <file>]
    \\                          [--summary-file <file>] [--github-output <file>] [--require-stamped <true|false>]
    \\
;

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().deprecatedWriter().print("release_json: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().deprecatedWriter().print("release_json: " ++ fmt ++ "\n{s}", args ++ .{USAGE}) catch {};
    std.process.exit(2);
}

pub fn main() void {
    run() catch |e| die(1, "{s}", .{@errorName(e)});
}

fn emit(path: ?[]const u8, text: []const u8) !void {
    if (path) |p| return util.appendFile(p, text);
    try std.fs.File.stdout().writeAll(text);
}

fn parseFlags(a: std.mem.Allocator, argv: []const []const u8, names: []const []const u8, required: []const []const u8) util.Flags {
    var bad: []const u8 = "";
    const flags = util.Flags.parse(a, argv, names, &bad) catch |e| usage("{s}: {s}", .{ @errorName(e), bad });
    for (required) |need| {
        if (flags.get(need) == null) usage("{s} is required", .{need});
    }
    return flags;
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) usage("a subcommand is required", .{});
    const sub = argv[1];
    const rest = argv[2..];
    if (std.mem.eql(u8, sub, "stamp")) return stampCmd(a, rest);
    if (std.mem.eql(u8, sub, "names")) return namesCmd(a, rest);
    if (std.mem.eql(u8, sub, "write")) return writeCmd(a, rest);
    usage("unknown subcommand '{s}'", .{sub});
}

fn stampCmd(a: std.mem.Allocator, argv: []const []const u8) !void {
    const flags = parseFlags(a, argv, &.{ "--revision", "--work-dir", "--github-output" }, &.{"--revision"});
    const git = util.RealGit{ .work_dir = flags.get("--work-dir") orelse "." };
    switch (try lib.stamp.derive(a, git, flags.get("--revision").?)) {
        .refuse => |why| die(1, "refused: {s}", .{why}),
        .ok => |s| {
            const text = try std.fmt.allocPrint(a, "build_number={d}\nsource_commit={s}\ntimestamp_ms={d}\n", .{ s.build_number, s.source_commit, s.timestamp_ms });
            try emit(flags.get("--github-output"), text);
        },
    }
}

fn readFile(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 24) catch |e| die(1, "cannot read {s}: {s}", .{ path, @errorName(e) });
}

fn namesCmd(a: std.mem.Allocator, argv: []const []const u8) !void {
    var split: usize = argv.len;
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            split = i;
            break;
        }
    }
    const flag_names = [_][]const u8{ "--artifacts", "--out", "--metapackage", "--license", "--summary", "--home", "--extra-file", "--label-prefix" };
    const flags = parseFlags(a, argv[0..split], &flag_names, &flag_names);
    const members = if (split < argv.len) argv[split + 1 ..] else argv[0..0];
    const text = try readFile(a, flags.get("--artifacts").?);
    const why = try lib.artifacts.disagreement(a, text, .{
        .members = members,
        .metapackage = flags.get("--metapackage").?,
        .license = flags.get("--license").?,
        .summary = flags.get("--summary").?,
        .home = flags.get("--home").?,
        .extra_file = flags.get("--extra-file").?,
        .label_prefix = flags.get("--label-prefix").?,
    });
    if (why) |w| die(1, "the release set is not the artifacts file's: {s}", .{w});
    const out = flags.get("--out").?;
    try std.fs.cwd().writeFile(.{ .sub_path = out, .data = try std.fmt.allocPrint(a, "{d} artifacts\n", .{members.len + 1}) });
}

fn writeCmd(a: std.mem.Allocator, argv: []const []const u8) !void {
    const flag_names = [_][]const u8{ "--release-dir", "--artifacts", "--revision", "--platform", "--run-id", "--attempt", "--out", "--hash-file", "--summary-file", "--github-output", "--require-stamped" };
    const flags = parseFlags(a, argv, &flag_names, &.{ "--release-dir", "--artifacts", "--revision", "--platform", "--run-id", "--attempt", "--out" });
    const attempt = std.fmt.parseInt(u32, flags.get("--attempt").?, 10) catch usage("--attempt is not a number", .{});
    const stamped = flags.getOr("--require-stamped");
    if (stamped.len != 0 and !std.mem.eql(u8, stamped, "true") and !std.mem.eql(u8, stamped, "false")) {
        usage("--require-stamped is true or false", .{});
    }
    var ctx = set_json.Ctx{ .a = a, .require_stamped = !std.mem.eql(u8, stamped, "false") };
    const id = set_json.Identity{
        .revision = flags.get("--revision").?,
        .platform = flags.get("--platform").?,
        .run_id = flags.get("--run-id").?,
        .attempt = attempt,
    };
    writeSet(a, &ctx, flags, id) catch |e| switch (e) {
        error.Refused => die(1, "refused: {s}", .{ctx.why}),
        else => return e,
    };
}

fn writeSet(a: std.mem.Allocator, ctx: *set_json.Ctx, flags: util.Flags, id: set_json.Identity) !void {
    try set_json.checkIdentity(ctx, id);
    const arts = try lib.artifacts.parse(a, try readFile(a, flags.get("--artifacts").?));
    if (arts.len == 0) return ctx.fail("the artifacts file declares no artifact", .{});
    const names = try a.alloc([]const u8, arts.len);
    for (arts, names) |art, *n| n.* = art.name;
    var dir = std.fs.cwd().openDir(flags.get("--release-dir").?, .{ .iterate = true }) catch |e| {
        return ctx.fail("cannot open --release-dir: {s}", .{@errorName(e)});
    };
    defer dir.close();
    const members = try set_json.verifySet(ctx, dir, names, id.platform);
    const json = try set_json.renderReleaseJson(ctx, id, members);
    const hash = try set_json.setHash(a, id.revision, id.platform, members);
    try std.fs.cwd().writeFile(.{ .sub_path = flags.get("--out").?, .data = json });
    if (flags.get("--hash-file")) |p| {
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = try std.fmt.allocPrint(a, "{s}\n", .{hash}) });
    }
    if (flags.get("--summary-file")) |p| {
        try util.appendFile(p, try std.fmt.allocPrint(a, "release set {s}: {d} packages built from {s} (nothing published)\n", .{ hash, members.len, id.revision[0..8] }));
    }
    try emit(flags.get("--github-output"), try std.fmt.allocPrint(a, "set_hash={s}\n", .{hash}));
}
