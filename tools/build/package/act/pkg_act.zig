// Why Zig: build tools are Zig (tools/build/README.md). pkg_act replaces the
// busybox scripts of tools/build/package (the bundle, the kcov guard, the OCI
// release manifest, the conda joins and checks, the release-set checks), so
// those actions run no shell.
//! pkg_act: the small actions of the package rules.
//!
//!   pkg_act bundle --out <dir> --name <n> --cpu <cpu> --launcher <f> --so <f>
//!       --runtime <dir> --version <f> [--file <dest> <src>]...
//!   pkg_act kcov-guard guard <kcov_sha256> <usage_line> <out> <what> [<dest> <path>]...
//!   pkg_act kcov-guard cases <kcov_sha256> <usage_line> <report_dir>
//!   pkg_act copy-dir <src> <dst>
//!   pkg_act oci-release-manifest --out <f> --digest <f> --name <n> --version <v>
//!       --platform <p> --file <f> --label <l> --repo <r> --from <where>
//!   pkg_act level-run <out> <exe>
//!   pkg_act conda-manifest-kci <out> <dir> <probe>...
//!   pkg_act release-stamp-check --out <f> --version <v> --build-number <n> --commit <c>
//!       --timestamp-ms <ms> --build <b> --meta <name> --meta-dir <dir> --set <f>
//!       --license <l> --summary <s> --home <h> [--member <name> <dir>]...
//!   pkg_act release-order-check --out <f> --set <f> --version <v> --build <b>
//!       [--member <name> <metadata.json>]...
//!   pkg_act release-order-test --out <f> --refuses <text> --set <f> --version <v>
//!       --build <b> [--member <name> <metadata.json>]...
//!
//! Each does what its busybox script did, with the same refusals in the same
//! words. Exit status: 0; 1 for a refusal (its text on stderr); 2 for a usage
//! error or a failure of the tool's own.

const std = @import("std");
const U = @import("act_util");
const kcov = @import("kcov_guard.zig");
const release = @import("release.zig");
const bundle = @import("bundle.zig");
const misc = @import("misc.zig");

const prog = "pkg_act";

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

fn parse(a: std.mem.Allocator, args: []const []const u8, spec: []const U.Spec, sub: []const u8) ?U.Flags {
    var bad: []const u8 = "";
    return U.parseFlags(a, args, spec, &bad) catch |e| {
        std.debug.print(prog ++ " {s}: {s}: {s}\n", .{ sub, @errorName(e), bad });
        return null;
    };
}

fn members(a: std.mem.Allocator, f: U.Flags) ![]release.Member {
    const items = try f.all(a, "member");
    const list = try a.alloc(release.Member, items.len);
    for (items, 0..) |it, i| list[i] = .{ .name = it.vals[0], .path = it.vals[1] };
    return list;
}

fn printRefusal(out: *U.Out) u8 {
    std.debug.print("{s}", .{out.items});
    return 1;
}

fn cmdBundle(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "out" },   .{ .name = "name" },    .{ .name = "cpu" },     .{ .name = "launcher" },
        .{ .name = "so" },    .{ .name = "runtime" }, .{ .name = "version" }, .{ .name = "file", .arity = 2 },
    };
    const f = parse(a, args, &spec, "bundle") orelse return 2;
    const items = f.all(a, "file") catch return 2;
    const files = a.alloc([2][]const u8, items.len) catch return 2;
    for (items, 0..) |it, i| files[i] = .{ it.vals[0], it.vals[1] };
    const plan = bundle.Plan{
        .out = f.need("out") catch return usage("bundle needs --out", .{}),
        .name = f.need("name") catch return usage("bundle needs --name", .{}),
        .cpu = f.need("cpu") catch return usage("bundle needs --cpu", .{}),
        .launcher = f.need("launcher") catch return usage("bundle needs --launcher", .{}),
        .so = f.need("so") catch return usage("bundle needs --so", .{}),
        .runtime = f.need("runtime") catch return usage("bundle needs --runtime", .{}),
        .version = f.need("version") catch return usage("bundle needs --version", .{}),
        .files = files,
    };
    bundle.assemble(a, plan) catch |e| {
        std.debug.print("komira_bundle: {s}\n", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn cmdCopyDir(args: []const []const u8) u8 {
    if (args.len != 2) return usage("usage: pkg_act copy-dir <src> <dst>", .{});
    const cwd = std.fs.cwd();
    cwd.makePath(args[1]) catch |e| return usage("cannot create {s}: {s}", .{ args[1], @errorName(e) });
    var src = cwd.openDir(args[0], .{ .iterate = true }) catch |e| return usage("cannot read {s}: {s}", .{ args[0], @errorName(e) });
    defer src.close();
    var dst = cwd.openDir(args[1], .{ .iterate = true }) catch |e| return usage("cannot open {s}: {s}", .{ args[1], @errorName(e) });
    defer dst.close();
    U.copyTree(src, dst) catch |e| return usage("cannot copy {s} to {s}: {s}", .{ args[0], args[1], @errorName(e) });
    return 0;
}

fn cmdOci(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "out" },      .{ .name = "digest" }, .{ .name = "name" }, .{ .name = "version" }, .{ .name = "platform" },
        .{ .name = "file" },     .{ .name = "label" },  .{ .name = "repo" }, .{ .name = "from" },
    };
    const f = parse(a, args, &spec, "oci-release-manifest") orelse return 2;
    const digest_path = f.need("digest") catch return usage("oci-release-manifest needs --digest", .{});
    const digest = std.fs.cwd().readFileAlloc(a, digest_path, 1 << 16) catch |e| return usage("cannot read {s}: {s}", .{ digest_path, @errorName(e) });
    const m = misc.OciManifest{
        .digest_path = digest_path,
        .digest = digest,
        .name = f.need("name") catch return usage("needs --name", .{}),
        .version = f.need("version") catch return usage("needs --version", .{}),
        .platform = f.need("platform") catch return usage("needs --platform", .{}),
        .file = f.need("file") catch return usage("needs --file", .{}),
        .label = f.need("label") catch return usage("needs --label", .{}),
        .repo = f.need("repo") catch return usage("needs --repo", .{}),
        .from = f.need("from") catch return usage("needs --from", .{}),
    };
    var out = U.Out.init(a);
    const text = misc.ociManifest(a, &out, m) catch return printRefusal(&out);
    const out_path = f.need("out") catch return usage("needs --out", .{});
    U.writeAll(std.fs.cwd(), out_path, text) catch |e| return usage("cannot write {s}: {s}", .{ out_path, @errorName(e) });
    return 0;
}

fn cmdLevelRun(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 2) return usage("usage: pkg_act level-run <out> <exe>", .{});
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const exe = U.abs(a, cwd, args[1]) catch return 2;
    const r = U.runCapture(a, &.{exe}, null, null) catch |e| return usage("cannot run {s}: {s}", .{ args[1], @errorName(e) });
    U.writeAll(std.fs.cwd(), args[0], r.stdout) catch |e| return usage("cannot write {s}: {s}", .{ args[0], @errorName(e) });
    // The program's report is shown whatever it decided.
    std.debug.print("{s}{s}", .{ r.stderr, r.stdout });
    return 0;
}

fn cmdCondaManifestKci(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len < 3) return usage("usage: pkg_act conda-manifest-kci <out> <dir> <probe>...", .{});
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const dir = U.abs(a, cwd, args[1]) catch return 2;
    const listing = misc.condaDirListing(a, dir) catch |e| return usage("cannot read {s}: {s}", .{ dir, @errorName(e) });
    if (listing) |l| {
        std.debug.print("conda_manifest_kci: {s} holds [{s}], not exactly one .conda, manifest.json and metadata.json\n", .{ dir, l });
        return 1;
    }
    // A private scratch directory for the probe's TMPDIR and HOME.
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    const tmp = std.fs.path.join(a, &.{ scratch, "tmp" }) catch return 2;
    const home = std.fs.path.join(a, &.{ scratch, "home" }) catch return 2;
    std.fs.cwd().makePath(tmp) catch return 2;
    std.fs.cwd().makePath(home) catch return 2;
    defer std.fs.cwd().deleteTree(scratch) catch {};
    var env = U.envWithoutLoaderVars(a) catch return 2;
    env.put("TMPDIR", tmp) catch return 2;
    env.put("HOME", home) catch return 2;

    const manifest = std.fs.path.join(a, &.{ dir, "manifest.json" }) catch return 2;
    var argv = std.ArrayList([]const u8).init(a);
    argv.appendSlice(args[2..]) catch return 2;
    argv.append(manifest) catch return 2;
    const r = U.runCapture(a, argv.items, &env, null) catch |e| return usage("cannot run {s}: {s}", .{ args[2], @errorName(e) });
    const all = std.mem.concat(a, u8, &.{ r.stdout, r.stderr }) catch return 2;
    const line = U.trimNewlines(all);
    if (r.code != 0) {
        std.debug.print("conda_manifest_kci: kci's artifact-manifest parser refuses {s} (exit {d}): {s}\n", .{ manifest, r.code, line });
        return 1;
    }
    const ok = misc.kciLineOk(a, line, dir) catch return 2;
    if (!ok) {
        std.debug.print("conda_manifest_kci: kci reads {s} as [{s}]; it must be one OK CONDA line ending [ metadata=metadata.json metadata_path={s}/metadata.json render-identical=yes]\n", .{ manifest, line, dir });
        return 1;
    }
    const stripped = misc.stripDir(a, line, dir) catch return 2;
    const text = std.fmt.allocPrint(a, "{s}\n", .{stripped}) catch return 2;
    U.writeAll(std.fs.cwd(), args[0], text) catch |e| return usage("cannot write {s}: {s}", .{ args[0], @errorName(e) });
    return 0;
}

fn cmdStamp(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "out" },       .{ .name = "version" }, .{ .name = "build-number" }, .{ .name = "commit" },
        .{ .name = "timestamp-ms" }, .{ .name = "build" }, .{ .name = "meta" },        .{ .name = "meta-dir" },
        .{ .name = "set" },       .{ .name = "license" }, .{ .name = "summary" },      .{ .name = "home" },
        .{ .name = "member", .arity = 2 },
    };
    const f = parse(a, args, &spec, "release-stamp-check") orelse return 2;
    const s = release.Stamp{
        .version = f.need("version") catch return usage("release-stamp-check needs --version", .{}),
        .build_number = f.need("build-number") catch return usage("release-stamp-check needs --build-number", .{}),
        .commit = f.need("commit") catch return usage("release-stamp-check needs --commit", .{}),
        .timestamp_ms = f.need("timestamp-ms") catch return usage("release-stamp-check needs --timestamp-ms", .{}),
        .build = f.need("build") catch return usage("release-stamp-check needs --build", .{}),
        .meta = f.need("meta") catch return usage("release-stamp-check needs --meta", .{}),
        .meta_dir = f.need("meta-dir") catch return usage("release-stamp-check needs --meta-dir", .{}),
        .set = f.need("set") catch return usage("release-stamp-check needs --set", .{}),
        .license = f.need("license") catch return usage("release-stamp-check needs --license", .{}),
        .summary = f.need("summary") catch return usage("release-stamp-check needs --summary", .{}),
        .home = f.need("home") catch return usage("release-stamp-check needs --home", .{}),
        .members = members(a, f) catch return 2,
    };
    var out = U.Out.init(a);
    const text = release.stampCheck(a, &out, s) catch return printRefusal(&out);
    const out_path = f.need("out") catch return usage("release-stamp-check needs --out", .{});
    U.writeAll(std.fs.cwd(), out_path, text) catch |e| return usage("cannot write {s}: {s}", .{ out_path, @errorName(e) });
    return 0;
}

const order_spec = [_]U.Spec{
    .{ .name = "out" }, .{ .name = "set" }, .{ .name = "version" }, .{ .name = "build" }, .{ .name = "refuses" }, .{ .name = "member", .arity = 2 },
};

fn cmdOrderCheck(a: std.mem.Allocator, args: []const []const u8) u8 {
    const f = parse(a, args, &order_spec, "release-order-check") orelse return 2;
    var out = U.Out.init(a);
    const text = release.orderCheck(
        a,
        &out,
        f.need("set") catch return usage("needs --set", .{}),
        f.need("version") catch return usage("needs --version", .{}),
        f.need("build") catch return usage("needs --build", .{}),
        members(a, f) catch return 2,
    ) catch return printRefusal(&out);
    const out_path = f.need("out") catch return usage("needs --out", .{});
    U.writeAll(std.fs.cwd(), out_path, text) catch |e| return usage("cannot write {s}: {s}", .{ out_path, @errorName(e) });
    return 0;
}

/// The order check run over fixtures, in its own process: red unless it
/// refuses with one line of stderr containing `--refuses`, or, when that is
/// empty, passes with no stderr.
fn cmdOrderTest(a: std.mem.Allocator, args: []const []const u8, exe: []const u8) u8 {
    const f = parse(a, args, &order_spec, "release-order-test") orelse return 2;
    const want = f.need("refuses") catch return usage("needs --refuses", .{});
    const out_path = f.need("out") catch return usage("needs --out", .{});
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return 2;
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    std.fs.cwd().makePath(scratch) catch return 2;
    defer std.fs.cwd().deleteTree(scratch) catch {};
    const marker = std.fs.path.join(a, &.{ scratch, "out" }) catch return 2;

    var argv = std.ArrayList([]const u8).init(a);
    argv.appendSlice(&.{ exe, "release-order-check", "--out", marker, "--set", f.need("set") catch return 2, "--version", f.need("version") catch return 2, "--build", f.need("build") catch return 2 }) catch return 2;
    const ms = f.all(a, "member") catch return 2;
    for (ms) |m| argv.appendSlice(&.{ "--member", m.vals[0], m.vals[1] }) catch return 2;
    const r = U.runCapture(a, argv.items, null, null) catch |e| return usage("cannot run the order check: {s}", .{@errorName(e)});
    const verdict = release.judgeOrderRun(a, r.code, r.stderr, want) catch return 2;
    if (verdict) |why| {
        std.debug.print("release_order_test: {s}\n", .{why});
        return 1;
    }
    U.writeAll(std.fs.cwd(), out_path, "ok\n") catch |e| return usage("cannot write {s}: {s}", .{ out_path, @errorName(e) });
    return 0;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    if (argv.len < 2) std.process.exit(usage("usage: pkg_act (bundle|kcov-guard|copy-dir|oci-release-manifest|level-run|conda-manifest-kci|release-stamp-check|release-order-check|release-order-test) ...", .{}));
    const sub = argv[1];
    const rest = argv[2..];
    const plain = a.alloc([]const u8, rest.len) catch std.process.exit(2);
    for (rest, 0..) |s, i| plain[i] = s;
    const exe = std.fs.selfExePathAlloc(a) catch std.process.exit(2);
    const rc: u8 = if (std.mem.eql(u8, sub, "bundle"))
        cmdBundle(a, plain)
    else if (std.mem.eql(u8, sub, "kcov-guard"))
        (if (plain.len >= 1 and std.mem.eql(u8, plain[0], "guard")) kcov.runGuard(a, plain[1..]) else if (plain.len >= 1 and std.mem.eql(u8, plain[0], "cases")) kcov.runCases(a, plain[1..], exe) else usage("kcov-guard is `guard` or `cases`", .{}))
    else if (std.mem.eql(u8, sub, "copy-dir"))
        cmdCopyDir(plain)
    else if (std.mem.eql(u8, sub, "oci-release-manifest"))
        cmdOci(a, plain)
    else if (std.mem.eql(u8, sub, "level-run"))
        cmdLevelRun(a, plain)
    else if (std.mem.eql(u8, sub, "conda-manifest-kci"))
        cmdCondaManifestKci(a, plain)
    else if (std.mem.eql(u8, sub, "release-stamp-check"))
        cmdStamp(a, plain)
    else if (std.mem.eql(u8, sub, "release-order-check"))
        cmdOrderCheck(a, plain)
    else if (std.mem.eql(u8, sub, "release-order-test"))
        cmdOrderTest(a, plain, exe)
    else
        usage("unknown subcommand {s}", .{sub});
    if (rc != 0) std.process.exit(rc);
}
