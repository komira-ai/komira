//! `readme_e2e verify`: one package of a staged set, tried as a user of it.
//!
//! The steps, each with the phase its failure is named by:
//!
//!   staged    the staged set's plan.json holds the package at the version
//!             (an `upload` member), names its README, and the README is there
//!   install   a fresh project (a mopm.toml of its own, nothing else) runs
//!             `mopm add <package>@=<version> --overlay <staged set>`; the lock
//!             it writes names the closure, each locked file is the staged
//!             file byte for byte (sha256 and size) and the plan's, and each is
//!             unpacked into the project's prefix, `lib/mojo/<name>.mojoc`
//!   readme    the README the set holds is cut into one program per example
//!             (tools/build/readme_examples, as the README gate of
//!             tools/build/mojo does), with no relative link
//!   compile   each program is compiled against the prefix and nothing else
//!   run       each program is run through the gate that runs every welded test
//!
//! Nothing of the package's source tree is an input: the packages, the README
//! and the lock all come from the staged set. `mopm sync` installs a lock with
//! pixi, which fetches the compiler from the network, so the closure is
//! unpacked here from the files the lock pins (sha256 and size checked first)
//! into the same `lib/mojo` layout that sync leaves in a prefix.
//!
//! The verdict is the last line of the log: `PASS ...` or `FAIL <phase>: ...`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const conda = @import("conda.zig");
const plan_mod = @import("plan.zig");

pub const Options = struct {
    package: []const u8,
    version: []const u8,
    /// The compiler version the packages must be built for (`1.0.0`).
    mojo: []const u8,
    /// The staged set: a directory with plan.json and `<subdir>/<file>.conda`.
    staged: []const u8,
    /// Where the project, the prefix and the programs are made.
    work: []const u8,
    /// Each command is its words; the e2e adds the arguments.
    mopm: []const []const u8,
    readme_tool: []const []const u8,
    compile: []const []const u8,
    run: []const []const u8,
};

const Verdict = error{ Failed, OutOfMemory };

const Ctx = struct {
    a: Allocator,
    opts: Options,
    log: *std.ArrayList(u8),

    fn say(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.a, fmt ++ "\n", args) catch return;
        self.log.appendSlice(self.a, line) catch {};
    }

    fn fail(self: *Ctx, phase: []const u8, comptime fmt: []const u8, args: anytype) Verdict {
        const why = std.fmt.allocPrint(self.a, fmt, args) catch return error.OutOfMemory;
        self.say("FAIL {s}: {s}: {s}", .{ phase, self.opts.package, why });
        return error.Failed;
    }

    fn path(self: *Ctx, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(self.a, parts);
    }
};

/// The last `n` lines of `text`, for a failure that prints a program's output.
pub fn tail(a: Allocator, text: []const u8, n: usize) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, text, "\n ");
    var start: usize = trimmed.len;
    var seen: usize = 0;
    while (start > 0) : (start -= 1) {
        if (trimmed[start - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
    }
    const body = trimmed[start..];
    if (start == 0) return a.dupe(u8, body);
    return std.fmt.allocPrint(a, "(last {d} lines)\n{s}", .{ n, body });
}

const Ran = struct { code: ?u8, output: []const u8 };

fn runProcess(c: *Ctx, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.EnvMap) !Ran {
    const r = std.process.Child.run(.{
        .allocator = c.a,
        .argv = argv,
        .cwd = cwd,
        .env_map = env,
        .max_output_bytes = 8 << 20,
    }) catch |e| return .{ .code = null, .output = try std.fmt.allocPrint(c.a, "cannot run {s}: {s}", .{ argv[0], @errorName(e) }) };
    const code: ?u8 = switch (r.term) {
        .Exited => |x| x,
        else => null,
    };
    return .{ .code = code, .output = try std.mem.concat(c.a, u8, &.{ r.stdout, r.stderr }) };
}

fn readFile(c: *Ctx, dir: []const u8, rel: []const u8, max: usize) ![]u8 {
    const p = try c.path(&.{ dir, rel });
    return std.fs.cwd().readFileAlloc(c.a, p, max);
}

/// `words` with each word that names an existing relative file made absolute,
/// for a command run from a directory other than this one's.
fn absolutize(a: Allocator, words: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (words) |w| {
        if (!std.fs.path.isAbsolute(w) and std.mem.indexOfScalar(u8, w, '/') != null) {
            if (std.fs.cwd().realpathAlloc(a, w)) |abs| {
                try out.append(a, abs);
                continue;
            } else |_| {}
        }
        try out.append(a, w);
    }
    return out.items;
}

fn concatArgs(a: Allocator, head: []const []const u8, tail_words: []const []const u8) ![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ head, tail_words });
}

/// `words` with `--source-root=<root>` put before the first `--`, where the
/// compile wrapper (tools/build/mojo/tools/mojo_compile.zig) takes its options.
/// The wrapper then has the compiler strip the root from the paths it records, so
/// a program's binary holds no working directory (an assertion in an example
/// names its file). A command with no `--` is not one of the wrapper's: unchanged.
pub fn withSourceRoot(a: Allocator, words: []const []const u8, root: []const u8) ![]const []const u8 {
    for (words, 0..) |w, i| {
        if (!std.mem.eql(u8, w, "--")) continue;
        const option = try std.fmt.allocPrint(a, "--source-root={s}", .{root});
        return std.mem.concat(a, []const u8, &.{ words[0..i], &.{option}, words[i..] });
    }
    return words;
}

/// `output` with each `readme_<package>_<line>.mojo:<n>` of an example's program
/// rewritten to the README line (the examples tool's `map`, as the README gate
/// reports); `output` itself when that cannot be done.
fn mapped(c: *Ctx, output: []const u8, display: []const u8, report: []const u8) []const u8 {
    std.fs.cwd().makePath(std.fs.path.dirname(report) orelse ".") catch return output;
    std.fs.cwd().writeFile(.{ .sub_path = report, .data = output }) catch return output;
    const argv = concatArgs(c.a, c.opts.readme_tool, &.{ "map", "--package", c.opts.package, "--display", display, "--report", report }) catch return output;
    const r = runProcess(c, argv, null, null) catch return output;
    if (r.code != 0) return output;
    return r.output;
}

const project_manifest =
    \\[package]
    \\name = "readme_e2e_user"
    \\version = "0.0.0"
    \\
    \\[toolchain]
    \\mojo = "{s}"
    \\
    \\[dependencies]
    \\
;

/// Runs every phase. True when the package passed; the log holds the verdict.
pub fn verify(a: Allocator, opts: Options, log: *std.ArrayList(u8)) !bool {
    var c = Ctx{ .a = a, .opts = opts, .log = log };
    run(&c) catch |e| switch (e) {
        error.Failed => return false,
        else => return e,
    };
    return true;
}

fn run(c: *Ctx) !void {
    const opts = c.opts;
    var why: []const u8 = "";

    // ---- staged -------------------------------------------------------------
    const plan_text = readFile(c, opts.staged, "plan.json", 8 << 20) catch |e|
        return c.fail("staged", "cannot read plan.json of the staged set {s}: {s}", .{ opts.staged, @errorName(e) });
    const plan = plan_mod.parsePlan(c.a, plan_text, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return c.fail("staged", "{s}", .{why}),
    };
    const member = plan.member(opts.package) orelse
        return c.fail("staged", "the staged set has no member {s}; it holds {d} member(s)", .{ opts.package, plan.members.len });
    if (!std.mem.eql(u8, member.action, "upload")) {
        return c.fail("staged", "the staged set's member is `{s}`, not `upload`, so its bytes are not in the set", .{member.action});
    }
    if (!std.mem.eql(u8, member.version, opts.version)) {
        return c.fail("staged", "the staged set holds {s} {s}, and the release is {s}", .{ opts.package, member.version, opts.version });
    }
    const readme_rel = member.readme orelse
        return c.fail("staged", "the staged set names no README for the package", .{});
    if (!plan_mod.relativePath(readme_rel)) return c.fail("staged", "the README path {s} is not a path below the set", .{readme_rel});
    const readme = readFile(c, opts.staged, readme_rel, 1 << 20) catch |e|
        return c.fail("staged", "cannot read the README {s}: {s}", .{ readme_rel, @errorName(e) });
    c.say("staged: {s} {s}, README {s} ({d} bytes)", .{ opts.package, opts.version, readme_rel, readme.len });

    // ---- install ------------------------------------------------------------
    const cwd = std.fs.cwd();
    cwd.makePath(opts.work) catch |e| return c.fail("install", "cannot make {s}: {s}", .{ opts.work, @errorName(e) });
    const project = try c.path(&.{ opts.work, "project" });
    const home = try c.path(&.{ opts.work, "home" });
    cwd.makePath(project) catch |e| return c.fail("install", "cannot make {s}: {s}", .{ project, @errorName(e) });
    cwd.makePath(home) catch |e| return c.fail("install", "cannot make {s}: {s}", .{ home, @errorName(e) });
    const manifest = try std.fmt.allocPrint(c.a, project_manifest, .{opts.mojo});
    const manifest_path = try c.path(&.{ project, "mopm.toml" });
    cwd.writeFile(.{ .sub_path = manifest_path, .data = manifest }) catch |e|
        return c.fail("install", "cannot write {s}: {s}", .{ manifest_path, @errorName(e) });

    const staged_abs = cwd.realpathAlloc(c.a, opts.staged) catch |e|
        return c.fail("install", "cannot resolve {s}: {s}", .{ opts.staged, @errorName(e) });
    const home_abs = try cwd.realpathAlloc(c.a, home);
    const project_abs = try cwd.realpathAlloc(c.a, project);
    var env = std.process.EnvMap.init(c.a);
    try env.put("HOME", home_abs);
    try env.put("XDG_CONFIG_HOME", home_abs);

    const spec = try std.fmt.allocPrint(c.a, "{s}@={s}", .{ opts.package, opts.version });
    const add = try concatArgs(c.a, try absolutize(c.a, opts.mopm), &.{ "add", spec, "--overlay", staged_abs });
    const added = try runProcess(c, add, project_abs, &env);
    if (added.code != 0) {
        const hint = if (std.ascii.indexOfIgnoreCase(added.output, "overlay") != null or std.ascii.indexOfIgnoreCase(added.output, "usage:") != null)
            "\nthe pinned mopm may predate `--overlay` (it needs a mopm release that has it); bump the pin"
        else
            "";
        const how: []const u8 = if (added.code) |x| try std.fmt.allocPrint(c.a, "exited {d}", .{x}) else "did not exit";
        return c.fail("install", "`mopm add {s} --overlay <staged set>` {s}:\n{s}{s}", .{
            spec,
            how,
            try tail(c.a, added.output, 20),
            hint,
        });
    }
    const lock_text = readFile(c, project, "mopm.lock", 8 << 20) catch |e|
        return c.fail("install", "`mopm add` wrote no mopm.lock: {s}", .{@errorName(e)});
    const lock = plan_mod.parseLock(c.a, lock_text, &why) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return c.fail("install", "{s}", .{why}),
    };
    const root = lock.find(opts.package) orelse
        return c.fail("install", "the lock does not name {s}", .{opts.package});
    if (!std.mem.eql(u8, root.version, opts.version)) {
        return c.fail("install", "the lock names {s} {s}, not {s}", .{ opts.package, root.version, opts.version });
    }

    const prefix = try c.path(&.{ opts.work, "prefix" });
    cwd.makePath(prefix) catch |e| return c.fail("install", "cannot make {s}: {s}", .{ prefix, @errorName(e) });
    var prefix_dir = try cwd.openDir(prefix, .{});
    defer prefix_dir.close();
    const want_build = try std.fmt.allocPrint(c.a, "mojo{s}_0", .{opts.mojo});
    var installed: usize = 0;
    for (lock.packages) |p| {
        if (p.isPath()) return c.fail("install", "the lock holds the path dependency {s}, which no staged file carries", .{p.name});
        if (!std.mem.eql(u8, p.build, want_build)) {
            return c.fail("install", "{s} {s} is built as {s}, and the release's compiler is {s}", .{ p.name, p.version, p.build, opts.mojo });
        }
        if (p.native.len != 0) {
            return c.fail("install", "{s} ships native libraries; the e2e links none and refuses a package that needs one", .{p.name});
        }
        const staged_member = plan.member(p.name) orelse
            return c.fail("install", "the lock needs {s} {s}, which the staged set does not hold", .{ p.name, p.version });
        var planned = false;
        for (staged_member.files) |f| {
            if (std.mem.eql(u8, f.filename, p.filename()) and std.mem.eql(u8, f.subdir, p.subdir) and std.mem.eql(u8, f.sha256, p.sha256) and f.size == p.size) planned = true;
        }
        if (!planned) {
            return c.fail("install", "the lock's {s} ({s} in {s}, sha256 {s}) is not a file of the staged plan", .{ p.name, p.filename(), p.subdir, p.sha256 });
        }
        const rel = try c.path(&.{ p.subdir, p.filename() });
        const bytes = readFile(c, opts.staged, rel, 1 << 29) catch |e|
            return c.fail("install", "{s} is in the plan and not in the staged set: {s}", .{ rel, @errorName(e) });
        const got = plan_mod.sha256Hex(bytes);
        if (!std.mem.eql(u8, &got, p.sha256) or bytes.len != p.size) {
            return c.fail("install", "{s} is not the file the lock pins (sha256 {s}, {d} bytes; the lock says {s}, {d})", .{ rel, &got, bytes.len, p.sha256, p.size });
        }
        const files = conda.read(c.a, bytes, &why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Corrupt => return c.fail("install", "{s}: {s}", .{ rel, why }),
        };
        const mojoc = try std.fmt.allocPrint(c.a, "lib/mojo/{s}.mojoc", .{p.name});
        const lib = conda.find(files, mojoc) orelse return c.fail("install", "{s} holds no {s}", .{ rel, mojoc });
        if (lib.len == 0) return c.fail("install", "{s}: {s} is empty", .{ rel, mojoc });
        conda.extract(prefix_dir, files) catch |e| return c.fail("install", "cannot unpack {s} into {s}: {s}", .{ rel, prefix, @errorName(e) });
        installed += 1;
    }
    c.say("install: {d} package(s) locked and unpacked into {s}", .{ installed, prefix });

    // ---- readme -------------------------------------------------------------
    const readme_dir = try c.path(&.{ opts.work, "readme" });
    cwd.makePath(readme_dir) catch |e| return c.fail("readme", "cannot make {s}: {s}", .{ readme_dir, @errorName(e) });
    const readme_file = try c.path(&.{ readme_dir, "README.md" });
    cwd.writeFile(.{ .sub_path = readme_file, .data = readme }) catch |e|
        return c.fail("readme", "cannot write {s}: {s}", .{ readme_file, @errorName(e) });
    try cwd.makePath(try c.path(&.{ opts.work, "examples" }));
    const programs = try c.path(&.{ opts.work, "examples", "src" });
    const examples_file = try c.path(&.{ opts.work, "examples", "list" });
    const display = try std.fmt.allocPrint(c.a, "{s}/README.md", .{opts.package});
    const gen = try concatArgs(c.a, opts.readme_tool, &.{
        "generate",  "--readme",    readme_file,
        "--display", display,       "--package",
        opts.package, "--links",    "refuse",
        "--out-dir", programs,      "--examples",
        examples_file,
    });
    const generated = try runProcess(c, gen, null, null);
    if (generated.code != 0) {
        return c.fail("readme", "the README is refused:\n{s}", .{try tail(c.a, generated.output, 20)});
    }
    const list = try cwd.readFileAlloc(c.a, examples_file, 1 << 20);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, list, "\n");
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len != 0) try lines.append(c.a, t);
    }
    if (lines.items.len == 0) {
        return c.fail("readme", "the README holds no ```mojo example, so nothing would be compiled or run", .{});
    }
    c.say("readme: {d} example(s)", .{lines.items.len});

    // ---- compile and run, one example at a time -----------------------------
    const include = try std.fmt.allocPrint(c.a, "-I{s}/lib/mojo", .{prefix});
    const bin_dir = try c.path(&.{ opts.work, "bin" });
    try cwd.makePath(bin_dir);
    for (lines.items) |line| {
        const stem = try std.fmt.allocPrint(c.a, "readme_{s}_{s}", .{ opts.package, line });
        const program = try c.path(&.{ programs, try std.fmt.allocPrint(c.a, "{s}.mojo", .{stem}) });
        const exe = try c.path(&.{ bin_dir, stem });
        const build = try concatArgs(c.a, try withSourceRoot(c.a, opts.compile, programs), &.{ include, program, "-o", exe });
        const built = try runProcess(c, build, null, null);
        if (built.code != 0) {
            const report = try c.path(&.{ opts.work, "reports", try std.fmt.allocPrint(c.a, "{s}.compile.txt", .{line}) });
            return c.fail("compile", "README.md:{s} does not compile against the installed package:\n{s}", .{ line, try tail(c.a, mapped(c, built.output, display, report), 30) });
        }
        // The test root `gate mojo` runs: bin/<test> and share/, the working
        // directory of the test.
        const test_root = try c.path(&.{ opts.work, "root", line });
        const root_bin = try c.path(&.{ test_root, "bin" });
        try cwd.makePath(root_bin);
        try cwd.makePath(try c.path(&.{ test_root, "share" }));
        const staged_exe = try c.path(&.{ root_bin, stem });
        cwd.copyFile(exe, cwd, staged_exe, .{}) catch |e|
            return c.fail("run", "cannot stage {s}: {s}", .{ exe, @errorName(e) });
        const markers = try c.path(&.{ opts.work, "markers" });
        try cwd.makePath(markers);
        const marker = try c.path(&.{ markers, line });
        const label = try std.fmt.allocPrint(c.a, "{s}:README.md:{s}", .{ opts.package, line });
        const ran = try concatArgs(c.a, opts.run, &.{ "--label", label, "--test", staged_exe, "--marker", marker });
        const result = try runProcess(c, ran, null, null);
        if (result.code != 0) {
            const report = try c.path(&.{ opts.work, "reports", try std.fmt.allocPrint(c.a, "{s}.run.txt", .{line}) });
            return c.fail("run", "README.md:{s} fails when run:\n{s}", .{ line, try tail(c.a, mapped(c, result.output, display, report), 30) });
        }
        c.say("example README.md:{s}: compiled and passed", .{line});
    }
    c.say("PASS {s} {s}: {d} README example(s) compiled and ran against the installed package", .{ opts.package, opts.version, lines.items.len });
}
