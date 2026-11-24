//! The scenarios of `readme_e2e` (README.md, "Tests"): each stages made-up
//! packages with `readme_e2e assemble`, runs `readme_e2e verify` over them with
//! the stand-ins of fake.zig as mopm, compiler and gate (and the real README
//! examples tool), and checks the exit status, the verdict line and what was
//! and was not written. One build action per scenario (defs.bzl); it writes
//! `--out` only when every check held.
//!
//!     scenario --scenario NAME --tool EXE --fake EXE --readme-tool EXE --work DIR --out FILE

const std = @import("std");
const Allocator = std.mem.Allocator;
const fix = @import("fixture.zig");
const plan_mod = @import("plan.zig");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [8192]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "scenario: " ++ fmt ++ "\n", args) catch "scenario: failed\n";
    std.fs.File.stderr().writeAll(text) catch {};
    std.process.exit(1);
}

const Result = struct { code: u8, out: []const u8 };

/// The namespace of every package of the scenarios (a test namespace: the staged set is an overlay,
/// which takes any namespace). A `Pkg.name` is the import name; the full name is `example/<name>`.
const namespace = "example";

fn fullName(a: Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(a, namespace ++ "/{s}", .{name}) catch die("out of memory", .{});
}

const Pkg = struct {
    /// The import name.
    name: []const u8,
    version: []const u8 = "1.2.3",
    /// The import names of the packages it needs.
    deps: []const []const u8 = &.{},
    readme: []const u8,
    /// The import name of the package the file holds, for a scenario that needs another one.
    payload_name: ?[]const u8 = null,
    /// Static native libraries the package declares (and, unless `ship` is false, holds).
    natives: []const fix.Static = &.{},
};

const Env = struct {
    a: Allocator,
    tool: []const u8,
    fake: []const u8,
    readme_tool: []const u8,
    work: []const u8,

    fn join(self: Env, parts: []const []const u8) []u8 {
        var all: std.ArrayList([]const u8) = .empty;
        all.append(self.a, self.work) catch die("out of memory", .{});
        all.appendSlice(self.a, parts) catch die("out of memory", .{});
        return std.fs.path.join(self.a, all.items) catch die("out of memory", .{});
    }

    fn put(self: Env, rel: []const u8, bytes: []const u8) void {
        const p = self.join(&.{rel});
        if (std.fs.path.dirname(p)) |d| std.fs.cwd().makePath(d) catch |e| die("cannot make {s}: {s}", .{ d, @errorName(e) });
        std.fs.cwd().writeFile(.{ .sub_path = p, .data = bytes }) catch |e| die("cannot write {s}: {s}", .{ p, @errorName(e) });
    }

    fn get(self: Env, rel: []const u8) ?[]u8 {
        return std.fs.cwd().readFileAlloc(self.a, self.join(&.{rel}), 1 << 26) catch null;
    }

    fn exists(self: Env, rel: []const u8) bool {
        std.fs.cwd().access(self.join(&.{rel}), .{}) catch return false;
        return true;
    }

    fn exec(self: Env, argv: []const []const u8) Result {
        const r = std.process.Child.run(.{ .allocator = self.a, .argv = argv, .max_output_bytes = 4 << 20 }) catch |e|
            die("cannot run {s}: {s}", .{ argv[0], @errorName(e) });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .out = std.mem.concat(self.a, u8, &.{ r.stdout, r.stderr }) catch die("out of memory", .{}) };
    }

    /// The command file `name` holding `words`, one per line.
    fn cmd(self: Env, name: []const u8, words: []const []const u8) []const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (words) |w| {
            text.appendSlice(self.a, w) catch die("out of memory", .{});
            text.append(self.a, '\n') catch die("out of memory", .{});
        }
        const rel = std.fmt.allocPrint(self.a, "cmds/{s}", .{name}) catch die("out of memory", .{});
        self.put(rel, text.items);
        return self.join(&.{rel});
    }

    /// Makes the packages' `.conda` files and READMEs, and the staged set of them
    /// in `set`, with the real `assemble`. Returns its result.
    fn stage(self: Env, pkgs: []const Pkg, mojo: []const u8) Result {
        var argv: std.ArrayList([]const u8) = .empty;
        const build = std.fmt.allocPrint(self.a, "mojo{s}_0", .{mojo}) catch die("out of memory", .{});
        argv.appendSlice(self.a, &.{ self.tool, "assemble", "--out", self.join(&.{"set"}), "--mojo", mojo }) catch die("out of memory", .{});
        for (pkgs) |p| {
            const inside = p.payload_name orelse p.name;
            const mojoc = std.fmt.allocPrint(self.a, "mojoc of {s}", .{inside}) catch die("out of memory", .{});
            const deps = self.a.alloc([]const u8, p.deps.len) catch die("out of memory", .{});
            for (p.deps, deps) |d, *out| out.* = fullName(self.a, d);
            const bytes = fix.packageWith(self.a, fullName(self.a, inside), p.version, build, mojoc, deps, p.natives) catch die("cannot build the fixture {s}", .{p.name});
            const file = std.fmt.allocPrint(self.a, "in/{s}/linux-64/mojo-" ++ namespace ++ ".{s}-{s}-{s}.conda", .{ p.name, p.name, p.version, build }) catch die("out of memory", .{});
            self.put(file, bytes);
            const readme = std.fmt.allocPrint(self.a, "in/{s}/README.md", .{p.name}) catch die("out of memory", .{});
            self.put(readme, p.readme);
            argv.appendSlice(self.a, &.{ "--member", fullName(self.a, p.name), p.version, self.join(&.{file}), self.join(&.{readme}) }) catch die("out of memory", .{});
        }
        return self.exec(argv.items);
    }

    /// `readme_e2e verify` of `package` (an import name) over `set`, with `mopm` as the stand-in's name.
    fn verify(self: Env, package: []const u8, version: []const u8, mojo: []const u8, mopm: []const u8) Result {
        const fake = self.fake;
        const full = fullName(self.a, package);
        const argv = [_][]const u8{
            self.tool,                                              "verify",
            "--package",                                            full,
            "--version",                                            version,
            "--mojo",                                               mojo,
            "--staged",                                             self.join(&.{"set"}),
            "--work",                                               self.join(&.{"run"}),
            "--marker",                                             self.join(&.{"run.marker"}),
            "--mopm",                                               self.cmd("mopm", &.{ fake, mopm }),
            "--readme-tool",                                        self.cmd("readme", &.{self.readme_tool}),
            "--compile",                                            self.cmd("compile", &.{ fake, "compile", "build" }),
            "--run",                                                self.cmd("run", &.{ fake, "gate", "mojo" }),
        };
        return self.exec(&argv);
    }
};

fn expectCode(r: Result, code: u8, what: []const u8) void {
    if (r.code != code) die("{s}: exit {d}, want {d}; output:\n{s}", .{ what, r.code, code, r.out });
}

fn expectText(r: Result, text: []const u8) void {
    if (std.mem.indexOf(u8, r.out, text) == null) die("the output has no `{s}`:\n{s}", .{ text, r.out });
}

fn expectNoText(r: Result, text: []const u8) void {
    if (std.mem.indexOf(u8, r.out, text) != null) die("the output has `{s}`:\n{s}", .{ text, r.out });
}

/// A README of `package` with one ```mojo example per body.
fn readmeOf(env: Env, package: []const u8, bodies: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const head = std.fmt.allocPrint(env.a, "# {s}\n\nA package of the scenarios.\n\n", .{package}) catch die("out of memory", .{});
    out.appendSlice(env.a, head) catch die("out of memory", .{});
    for (bodies) |b| {
        out.appendSlice(env.a, "```mojo\n") catch die("out of memory", .{});
        out.appendSlice(env.a, b) catch die("out of memory", .{});
        out.appendSlice(env.a, "\n```\n\nMore prose.\n\n") catch die("out of memory", .{});
    }
    return out.items;
}

/// The 1-based line of the `n`th (from 1) ```mojo fence of `readme`.
fn fenceLine(readme: []const u8, n: usize) usize {
    var line: usize = 0;
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, readme, '\n');
    while (it.next()) |l| {
        line += 1;
        if (std.mem.eql(u8, l, "```mojo")) {
            seen += 1;
            if (seen == n) return line;
        }
    }
    die("README has no fence {d}", .{n});
}

fn lineText(env: Env, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(env.a, fmt, args) catch die("out of memory", .{});
}

const good_use = "from good import value\nprint(value())";

fn goodReadme(env: Env, bodies: []const []const u8) Pkg {
    return .{ .name = "good", .readme = readmeOf(env, "good", bodies) };
}

// ---- the scenarios ----------------------------------------------------------

fn passes(env: Env) void {
    const pkg = goodReadme(env, &.{ good_use, good_use ++ " + 1" });
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 0, "verify");
    expectText(r, "PASS example/good 1.2.3: 2 README example(s) compiled and ran against the installed package");
    const marker = env.get("run.marker") orelse die("no marker written", .{});
    if (std.mem.indexOf(u8, marker, "PASS example/good 1.2.3") == null) die("the marker is `{s}`", .{marker});
    // What the user has: the package unpacked in a prefix, a lock, a manifest.
    for ([_][]const u8{ "run/prefix/lib/mojo/good.mojoc", "run/prefix/lib/mojo/good.mopm.json", "run/project/mopm.lock", "run/project/mopm.toml" }) |f| {
        if (!env.exists(f)) die("{s} was not made", .{f});
    }
    const mojoc = env.get("run/prefix/lib/mojo/good.mojoc").?;
    if (!std.mem.eql(u8, mojoc, "mojoc of good")) die("the installed .mojoc is `{s}`", .{mojoc});
}

fn dependency(env: Env) void {
    // `app` sorts before `zlib` and needs it: the plan lists zlib first, and
    // installing app unpacks both.
    const z = Pkg{ .name = "zlib", .readme = readmeOf(env, "zlib", &.{"from zlib import value\nprint(value())"}) };
    const app = Pkg{ .name = "app", .deps = &.{"zlib"}, .readme = readmeOf(env, "app", &.{"from app import run\nfrom zlib import value\nprint(run(value()))"}) };
    expectCode(env.stage(&.{ app, z }, "1.0.0"), 0, "stage");
    var why: []const u8 = "";
    const plan = plan_mod.parsePlan(env.a, env.get("set/plan.json").?, &why) catch die("plan.json: {s}", .{why});
    if (plan.members.len != 2 or !std.mem.eql(u8, plan.members[0].name, "example/zlib") or !std.mem.eql(u8, plan.members[1].name, "example/app")) die("the plan is not in dependency order", .{});
    for (plan.members) |m| {
        if (!std.mem.eql(u8, m.action, "upload") or m.files.len != 1 or (m.manifest_sha256 orelse "").len != 64) die("{s}: not a complete upload member", .{m.name});
        const staged = env.get(lineText(env, "set/{s}/{s}", .{ m.files[0].subdir, m.files[0].filename })).?;
        if (!std.mem.eql(u8, &plan_mod.sha256Hex(staged), m.files[0].sha256) or staged.len != m.files[0].size) die("{s}: the plan's hash is not the staged file's", .{m.name});
        if (!std.mem.eql(u8, m.readme orelse "", lineText(env, "{s}/README.md", .{m.name}))) die("{s}: the README path is {s}", .{ m.name, m.readme orelse "" });
    }
    const r = env.verify("app", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 0, "verify");
    expectText(r, "install: 2 package(s) locked and unpacked");
    for ([_][]const u8{ "run/prefix/lib/mojo/app.mojoc", "run/prefix/lib/mojo/zlib.mojoc" }) |f| {
        if (!env.exists(f)) die("{s} was not unpacked", .{f});
    }
}

fn compileError(env: Env) void {
    const pkg = goodReadme(env, &.{ good_use, "from good import value\nCOMPILE_ERROR" });
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, lineText(env, "example README.md:{d}: compiled and passed", .{fenceLine(pkg.readme, 1)}));
    expectText(r, lineText(env, "FAIL compile: example/good: README.md:{d} does not compile against the installed package", .{fenceLine(pkg.readme, 2)}));
    // The compiler's message names the README, not the generated program.
    expectText(r, "example/good/README.md:1:1: error: use of unknown declaration 'COMPILE_ERROR'");
    expectNoText(r, "readme_good_");
    expectNoText(r, "PASS example/good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn importOutsideClosure(env: Env) void {
    // The second example imports `outside`, which no installed package provides. A module of
    // that name sits in the staged set and among the inputs, where a compile that looked
    // beyond the installed copy would find it.
    const pkg = goodReadme(env, &.{ good_use, "from good import value\nfrom outside import other" });
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    env.put("set/outside.mojoc", "mojoc of outside");
    env.put("set/lib/mojo/outside.mojoc", "mojoc of outside");
    env.put("in/outside.mojoc", "mojoc of outside");
    env.put("in/good/outside.mojoc", "mojoc of outside");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, lineText(env, "example README.md:{d}: compiled and passed", .{fenceLine(pkg.readme, 1)}));
    expectText(r, lineText(env, "FAIL compile: example/good: README.md:{d} does not compile against the installed package", .{fenceLine(pkg.readme, 2)}));
    expectText(r, "unable to locate module 'outside'");
    expectNoText(r, "PASS example/good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn runError(env: Env) void {
    const pkg = goodReadme(env, &.{ good_use, "from good import value\nRUN_ERROR" });
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, lineText(env, "FAIL run: example/good: README.md:{d} fails when run", .{fenceLine(pkg.readme, 2)}));
    expectNoText(r, "FAIL compile");
    expectNoText(r, "PASS example/good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn missingPackage(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("absent", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL staged: example/absent: the staged set has no member example/absent");
    if (env.exists("run/prefix")) die("something was installed for a package the set lacks", .{});
}

fn missingFile(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    std.fs.cwd().deleteFile(env.join(&.{"set/linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda"})) catch |e| die("cannot delete the staged file: {s}", .{@errorName(e)});
    // A lock made from the plan names the file the set lacks, so the mopm does not die
    // first: it is verify's own check that refuses.
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_plan");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda is in the plan and not in the staged set");
    expectNoText(r, "PASS example/good");
    if (env.exists("run/prefix/lib/mojo/good.mojoc")) die("something was unpacked for a file the set lacks", .{});
    if (env.exists("run.marker")) die("a marker was written for a package that did not install", .{});
}

fn tamperedFile(env: Env) void {
    // The file in the set is another valid package's: a lock made from the
    // registry's index pins the plan's hash, and the file is not that.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const other = fix.package(env.a, "example/good", "1.2.3", "mojo1.0.0_0", "mojoc of something else", &.{}) catch die("fixture", .{});
    env.put("set/linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda", other);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_registry");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda is not the file the lock pins");
    if (env.exists("run/prefix/lib/mojo/good.mojoc")) die("a file that is not the pinned one was unpacked", .{});
}

fn changedFile(env: Env) void {
    // The same, with a lock made from the file in the set: the plan disagrees.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const other = fix.package(env.a, "example/good", "1.2.3", "mojo1.0.0_0", "mojoc of something else", &.{}) catch die("fixture", .{});
    env.put("set/linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda", other);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "is not a file of the staged plan");
}

/// What `mopm stage` writes for a release built for two platforms: each member of the staged set also gets an
/// osx-arm64 build, a package of the same name, version and dependencies holding `mojoc of <name> for macOS`,
/// at `set/osx-arm64/<file>`, with its sha256 and size in the plan. With `keep_host` false the member's
/// linux-64 file is dropped from the plan, so the set holds no build for the host. `deps` gives each import
/// name's dependencies (import names).
fn addMacBuilds(env: Env, mojo: []const u8, deps: []const struct { []const u8, []const []const u8 }, keep_host: bool) void {
    var why: []const u8 = "";
    const plan = plan_mod.parsePlan(env.a, env.get("set/plan.json").?, &why) catch die("plan.json: {s}", .{why});
    const build = std.fmt.allocPrint(env.a, "mojo{s}_0", .{mojo}) catch die("out of memory", .{});
    var members: std.ArrayList(plan_mod.Member) = .empty;
    for (plan.members) |m| {
        const import = plan_mod.importName(m.name);
        var full_deps: std.ArrayList([]const u8) = .empty;
        for (deps) |d| if (std.mem.eql(u8, d[0], import)) for (d[1]) |n| full_deps.append(env.a, fullName(env.a, n)) catch die("out of memory", .{});
        const mojoc = std.fmt.allocPrint(env.a, "mojoc of {s} for macOS", .{import}) catch die("out of memory", .{});
        const bytes = fix.package(env.a, m.name, m.version, build, mojoc, full_deps.items) catch die("cannot build the macOS fixture of {s}", .{m.name});
        const filename = m.files[0].filename;
        env.put(lineText(env, "set/osx-arm64/{s}", .{filename}), bytes);
        var files: std.ArrayList(plan_mod.PlanFile) = .empty;
        if (keep_host) files.appendSlice(env.a, m.files) catch die("out of memory", .{});
        files.append(env.a, .{ .subdir = "osx-arm64", .filename = filename, .sha256 = env.a.dupe(u8, &plan_mod.sha256Hex(bytes)) catch die("out of memory", .{}), .size = bytes.len }) catch die("out of memory", .{});
        var with = m;
        with.files = files.items;
        members.append(env.a, with) catch die("out of memory", .{});
    }
    const text = plan_mod.renderPlan(env.a, .{ .version = plan.version, .members = members.items }) catch die("cannot write plan.json", .{});
    env.put("set/plan.json", text);
}

fn twoPlatforms(env: Env) void {
    // a release staged for linux-64 and osx-arm64: mopm locks each package once per subdir, the e2e checks
    // every locked file against the plan and unpacks the host's alone (the macOS build would land on the same
    // paths of the prefix)
    const z = Pkg{ .name = "zlib", .readme = readmeOf(env, "zlib", &.{"from zlib import value\nprint(value())"}) };
    const app = Pkg{ .name = "app", .deps = &.{"zlib"}, .readme = readmeOf(env, "app", &.{"from app import run\nfrom zlib import value\nprint(run(value()))"}) };
    expectCode(env.stage(&.{ app, z }, "1.0.0"), 0, "stage");
    addMacBuilds(env, "1.0.0", &.{.{ "app", &.{"zlib"} }}, true);
    const r = env.verify("app", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 0, "verify");
    expectText(r, "install: 2 package(s) locked and unpacked");
    expectText(r, "PASS example/app 1.2.3");
    const lock = env.get("run/project/mopm.lock") orelse die("no lock written", .{});
    if (std.mem.count(u8, lock, "/osx-arm64/") != 2 or std.mem.count(u8, lock, "/linux-64/") != 2) die("the lock does not hold both platforms' builds of both packages: {s}", .{lock});
    for ([_][]const u8{ "app", "zlib" }) |n| {
        const got = env.get(lineText(env, "run/prefix/lib/mojo/{s}.mojoc", .{n})) orelse die("{s} was not unpacked", .{n});
        if (!std.mem.eql(u8, got, lineText(env, "mojoc of {s}", .{n}))) die("the installed {s}.mojoc is `{s}`, not the linux-64 build", .{ n, got });
    }
}

fn otherPlatformTampered(env: Env) void {
    // the osx-arm64 file in the set is not the one the plan names: the lock (from the registry's index) pins the
    // plan's hash, and the file the e2e never unpacks is still held to it
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    addMacBuilds(env, "1.0.0", &.{}, true);
    const other = fix.package(env.a, "example/good", "1.2.3", "mojo1.0.0_0", "mojoc of something else", &.{}) catch die("fixture", .{});
    env.put("set/osx-arm64/mojo-example.good-1.2.3-mojo1.0.0_0.conda", other);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_registry");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: osx-arm64/mojo-example.good-1.2.3-mojo1.0.0_0.conda is not the file the lock pins");
    expectNoText(r, "PASS example/good");
    if (env.exists("run.marker")) die("a marker was written for a set with a file that is not the plan's", .{});
}

fn otherPlatformOnly(env: Env) void {
    // a member built for osx-arm64 alone: nothing of it can be installed on the host, and the e2e says so at
    // install, not at the compile of an empty prefix
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    addMacBuilds(env, "1.0.0", &.{}, false);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: the lock pins no file for linux-64 (or noarch): nothing would be installed on this host");
    if (env.exists("run/prefix/lib/mojo/good.mojoc")) die("the macOS build was unpacked on the host", .{});
}

/// A set whose `app` needs `ghost` and does not hold it: both are staged (the tool refuses a
/// set with a hole), then `ghost` is taken out of the plan and the set, as a release whose
/// staging missed a member would be.
fn stageWithHole(env: Env) void {
    const ghost = Pkg{ .name = "ghost", .readme = readmeOf(env, "ghost", &.{"from ghost import x"}) };
    const app = Pkg{ .name = "app", .deps = &.{"ghost"}, .readme = readmeOf(env, "app", &.{"from app import run\nprint(run())"}) };
    expectCode(env.stage(&.{ app, ghost }, "1.0.0"), 0, "stage");
    var why: []const u8 = "";
    const plan = plan_mod.parsePlan(env.a, env.get("set/plan.json").?, &why) catch die("plan.json: {s}", .{why});
    var kept: std.ArrayList(plan_mod.Member) = .empty;
    for (plan.members) |m| {
        if (!std.mem.eql(u8, m.name, "example/ghost")) kept.append(env.a, m) catch die("out of memory", .{});
    }
    if (kept.items.len != 1) die("the plan held {d} member(s) besides ghost, want 1", .{kept.items.len});
    const text = plan_mod.renderPlan(env.a, .{ .version = plan.version, .members = kept.items }) catch die("cannot write the plan", .{});
    env.put("set/plan.json", text);
    std.fs.cwd().deleteFile(env.join(&.{"set/linux-64/mojo-example.ghost-1.2.3-mojo1.0.0_0.conda"})) catch |e| die("cannot delete the staged file: {s}", .{@errorName(e)});
}

fn closureMemberMissing(env: Env) void {
    // mopm needs `ghost`, which the set lacks: it asks the registry, which is the offline one and
    // refuses, so the install fails with the refusal. Nothing is fetched and nothing unpacked.
    stageWithHole(env);
    const r = env.verify("app", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/app: ");
    expectText(r, "the offline registry refused 1 request(s) beyond its configuration (GET /index/v2/ex/am/example/ghost)");
    // mopm's own message carries the registry's refusal.
    expectText(r, "answered HTTP 403");
    expectText(r, "the README e2e is offline");
    expectNoText(r, "PASS example/app");
    if (env.exists("run/prefix/lib/mojo/app.mojoc")) die("a package was unpacked from a closure the set does not hold", .{});
    if (env.exists("run.marker")) die("a marker was written for a package that did not install", .{});
}

fn swallowedRefusal(env: Env) void {
    // A mopm that ignores the refusal exits 0 with a lock that leaves `ghost` out. The e2e still
    // fails: the registry remembers the request, and any request beyond its configuration is a
    // fetch the set should have made unnecessary.
    stageWithHole(env);
    const r = env.verify("app", "1.2.3", "1.0.0", "mopm_swallow");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/app: `mopm add example/app@=1.2.3` exited 0, and the offline registry refused 1 request(s) beyond its configuration (GET /index/v2/ex/am/example/ghost)");
    expectNoText(r, "PASS example/app");
    if (env.exists("run/prefix/lib/mojo/app.mojoc")) die("a package was unpacked although mopm asked the registry for more than the set", .{});
    if (env.exists("run.marker")) die("a marker was written for a package that did not install", .{});
}

fn oldMopm(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_old");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: `mopm add example/good@=1.2.3 --overlay <staged set>` exited 1");
    expectText(r, "the pinned mopm may predate `--overlay`");
    if (env.exists("run.marker")) die("a marker was written although nothing was installed", .{});
}

fn oldMopmUsage(env: Env) void {
    // The pinned mopm (0.0.25) answers `add ... --overlay` with its usage text and exit 2.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_usage");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: `mopm add example/good@=1.2.3 --overlay <staged set>` exited 2");
    expectText(r, "usage: mopm lock");
    expectText(r, "the pinned mopm may predate `--overlay`");
    if (env.exists("run.marker")) die("a marker was written although nothing was installed", .{});
}

fn wrongCompiler(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.1.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: example/good 1.2.3 is built as mojo1.1.0_0, and the release's compiler is 1.0.0");
}

fn lockWithoutCompilerBuild(env: Env) void {
    // A lock that keys the package's build by the compiler the file names (1.1.0), not the project's
    // (1.0.0): it has no build for the release's compiler.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.1.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_keyed_by_build");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: example/good: example/good 1.2.3 has no build for the release's compiler 1.0.0");
    if (env.exists("run/prefix/lib/mojo/good.mojoc")) die("a package without a build for the compiler was unpacked", .{});
}

fn wrongVersion(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "9.9.9", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL staged: example/good: the staged set holds example/good 1.2.3, and the release is 9.9.9");
}

fn skippedMember(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const text = env.get("set/plan.json").?;
    const at = std.mem.indexOf(u8, text, "\"upload\"") orelse die("no upload in the plan", .{});
    const edited = std.mem.concat(env.a, u8, &.{ text[0..at], "\"skip\"", text[at + "\"upload\"".len ..] }) catch die("out of memory", .{});
    env.put("set/plan.json", edited);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL staged: example/good: the staged set's member is `skip`, not `upload`");
}

fn noExample(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL readme: example/good: the README holds no ```mojo example, so nothing would be compiled or run");
}

fn refusedReadme(env: Env) void {
    const pkg = Pkg{ .name = "good", .readme = "# good\n\n```mojo skip\nfrom good import value\n```\n" };
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL readme: example/good: the README is refused");
    expectText(r, "example/good/README.md:3");
}

fn relativeLink(env: Env) void {
    const pkg = Pkg{ .name = "good", .readme = "# good\n\nSee [the design](docs/design.md).\n\n```mojo\nfrom good import value\nprint(value())\n```\n" };
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL readme: example/good: the README is refused");
    expectText(r, "example/good/README.md:3");
}

fn assembleMissingDependency(env: Env) void {
    const app = Pkg{ .name = "app", .deps = &.{"ghost"}, .readme = readmeOf(env, "app", &.{"from app import run"}) };
    const r = env.stage(&.{app}, "1.0.0");
    expectCode(r, 1, "stage");
    expectText(r, "example/app needs example/ghost, which is not in the set");
    if (env.exists("set/plan.json")) die("a plan was written for a set that was refused", .{});
}

fn assembleCycle(env: Env) void {
    const a = Pkg{ .name = "aa", .deps = &.{"bb"}, .readme = readmeOf(env, "aa", &.{"from aa import x"}) };
    const b = Pkg{ .name = "bb", .deps = &.{"aa"}, .readme = readmeOf(env, "bb", &.{"from bb import x"}) };
    const r = env.stage(&.{ a, b }, "1.0.0");
    expectCode(r, 1, "stage");
    expectText(r, "form a cycle");
    if (env.exists("set/plan.json")) die("a plan was written for a set that was refused", .{});
}

fn assembleWrongPackage(env: Env) void {
    // The file is named for `good`, and the package inside is `other`.
    const pkg = Pkg{ .name = "good", .payload_name = "other", .readme = readmeOf(env, "good", &.{good_use}) };
    const r = env.stage(&.{pkg}, "1.0.0");
    expectCode(r, 1, "stage");
    expectText(r, "readme_e2e assemble: example/good: ");
    expectText(r, "holds no lib/mojo/good.mopm.json");
}

fn assembleLink(env: Env) void {
    // A package whose payload is a symbolic link is refused.
    const tar = fix.tarWithLink(env.a, "lib/mojo/good.mojoc", "/etc/passwd") catch die("fixture", .{});
    const bytes = fix.condaOf(env.a, "mojo-good-1.2.3-mojo1.0.0_0", tar) catch die("fixture", .{});
    env.put("in/good/linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda", bytes);
    env.put("in/good/README.md", "# good\n");
    const r = env.exec(&.{
        env.tool,                                           "assemble",
        "--out",                                            env.join(&.{"set"}),
        "--mojo",                                           "1.0.0",
        "--member",                                         "example/good",
        "1.2.3",                                            env.join(&.{"in/good/linux-64/mojo-example.good-1.2.3-mojo1.0.0_0.conda"}),
        env.join(&.{"in/good/README.md"}),
    });
    expectCode(r, 1, "assemble");
    expectText(r, "not a regular file");
}

fn usageError(env: Env) void {
    const r = env.exec(&.{ env.tool, "verify", "--package", "good" });
    expectCode(r, 2, "verify");
    expectText(r, "--version is required");
    const none = env.exec(&.{env.tool});
    expectCode(none, 2, "no command");
}

// ---- native libraries -------------------------------------------------------

/// A made-up static archive that defines `symbol` (the stand-in compiler looks for the name).
fn archiveOf(env: Env, symbol: []const u8) []const u8 {
    return lineText(env, "!<arch>\n{s}\n", .{symbol});
}

const native_use = "from good import value\n# NATIVE_CALL good_native_add\nprint(value())";

fn nativePkg(env: Env, body: []const u8, ship: bool) Pkg {
    // On the heap: the package outlives this function.
    const natives = env.a.alloc(fix.Static, 1) catch die("out of memory", .{});
    natives[0] = .{ .soname = "libgood_native.a", .bytes = archiveOf(env, "good_native_add"), .ship = ship };
    return .{ .name = "good", .readme = readmeOf(env, "good", &.{body}), .natives = natives };
}

fn native(env: Env) void {
    // The README calls a native symbol: it compiles and runs only because the compile
    // took the archive from the command `mopm build --print-cmd` printed.
    expectCode(env.stage(&.{nativePkg(env, native_use, true)}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 0, "verify");
    expectText(r, "link: mopm links 1 native librar(ies)");
    expectText(r, "PASS example/good 1.2.3: 1 README example(s) compiled and ran against the installed package");
    if (!env.exists("run/prefix/lib/libgood_native.a")) die("the archive was not unpacked into the prefix", .{});
}

fn nativeDependency(env: Env) void {
    // The native belongs to a package the README's package needs, not to the package itself.
    const z = Pkg{
        .name = "zlib",
        .readme = readmeOf(env, "zlib", &.{"from zlib import value\nprint(value())"}),
        .natives = &.{.{ .soname = "libgood_native.a", .bytes = archiveOf(env, "good_native_add") }},
    };
    const app = Pkg{ .name = "app", .deps = &.{"zlib"}, .readme = readmeOf(env, "app", &.{"from app import run\n# NATIVE_CALL good_native_add\nprint(run(1))"}) };
    expectCode(env.stage(&.{ app, z }, "1.0.0"), 0, "stage");
    const r = env.verify("app", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 0, "verify");
    expectText(r, "install: 2 package(s) locked and unpacked");
    expectText(r, "link: mopm links 1 native librar(ies)");
    expectText(r, "PASS example/app 1.2.3");
}

fn nativeMissingArchive(env: Env) void {
    // The metadata declares libgood_native.a and the package holds no such file.
    expectCode(env.stage(&.{nativePkg(env, native_use, false)}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL link: example/good: `mopm build --print-cmd --prefix <installed closure>` exited 1");
    expectText(r, "refused (missing_file)");
    expectText(r, "libgood_native.a is named by the installed metadata but is not on disk");
    expectNoText(r, "compiled and passed");
    expectNoText(r, "PASS example/good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn nativeUnlinked(env: Env) void {
    // A mopm whose command leaves the archive out: the e2e refuses it, naming the library,
    // before any example is compiled.
    expectCode(env.stage(&.{nativePkg(env, native_use, true)}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_nolink");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL link: example/good: example/good ships the native library libgood_native.a (static) and mopm's link command does not link it");
    expectNoText(r, "compiled and passed");
    expectNoText(r, "PASS example/good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn nativeUndefinedSymbol(env: Env) void {
    // The README calls a symbol the shipped archive does not define: the link fails, and the
    // verdict is the compile's, naming the README line.
    const body = "from good import value\n# NATIVE_CALL other_symbol\nprint(value())";
    expectCode(env.stage(&.{nativePkg(env, body, true)}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "link: mopm links 1 native librar(ies)");
    expectText(r, "FAIL compile: example/good: README.md:");
    expectText(r, "undefined symbol: other_symbol");
    expectNoText(r, "PASS example/good");
}

const Scenario = struct { name: []const u8, run: *const fn (Env) void };

const table = [_]Scenario{
    .{ .name = "passes", .run = passes },
    .{ .name = "dependency", .run = dependency },
    .{ .name = "compile_error", .run = compileError },
    .{ .name = "import_outside_closure", .run = importOutsideClosure },
    .{ .name = "run_error", .run = runError },
    .{ .name = "missing_package", .run = missingPackage },
    .{ .name = "missing_file", .run = missingFile },
    .{ .name = "tampered_file", .run = tamperedFile },
    .{ .name = "changed_file", .run = changedFile },
    .{ .name = "closure_member_missing", .run = closureMemberMissing },
    .{ .name = "swallowed_refusal", .run = swallowedRefusal },
    .{ .name = "old_mopm", .run = oldMopm },
    .{ .name = "old_mopm_usage", .run = oldMopmUsage },
    .{ .name = "wrong_compiler", .run = wrongCompiler },
    .{ .name = "lock_without_compiler_build", .run = lockWithoutCompilerBuild },
    .{ .name = "wrong_version", .run = wrongVersion },
    .{ .name = "skipped_member", .run = skippedMember },
    .{ .name = "no_example", .run = noExample },
    .{ .name = "refused_readme", .run = refusedReadme },
    .{ .name = "relative_link", .run = relativeLink },
    .{ .name = "assemble_missing_dependency", .run = assembleMissingDependency },
    .{ .name = "assemble_cycle", .run = assembleCycle },
    .{ .name = "assemble_wrong_package", .run = assembleWrongPackage },
    .{ .name = "assemble_link", .run = assembleLink },
    .{ .name = "native", .run = native },
    .{ .name = "native_dependency", .run = nativeDependency },
    .{ .name = "native_missing_archive", .run = nativeMissingArchive },
    .{ .name = "native_unlinked", .run = nativeUnlinked },
    .{ .name = "native_undefined_symbol", .run = nativeUndefinedSymbol },
    .{ .name = "usage", .run = usageError },
    .{ .name = "two_platforms", .run = twoPlatforms },
    .{ .name = "other_platform_tampered", .run = otherPlatformTampered },
    .{ .name = "other_platform_only", .run = otherPlatformOnly },
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var name: ?[]const u8 = null;
    var tool: ?[]const u8 = null;
    var fake: ?[]const u8 = null;
    var readme_tool: ?[]const u8 = null;
    var work: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const f = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, f, "--scenario")) name = v else if (std.mem.eql(u8, f, "--tool")) tool = v else if (std.mem.eql(u8, f, "--fake")) fake = v else if (std.mem.eql(u8, f, "--readme-tool")) readme_tool = v else if (std.mem.eql(u8, f, "--work")) work = v else if (std.mem.eql(u8, f, "--out")) out = v else die("unknown argument {s}", .{f});
    }
    const env = Env{
        .a = a,
        .tool = tool orelse die("--tool is required", .{}),
        .fake = fake orelse die("--fake is required", .{}),
        .readme_tool = readme_tool orelse die("--readme-tool is required", .{}),
        .work = work orelse die("--work is required", .{}),
    };
    const want = name orelse die("--scenario is required", .{});
    try std.fs.cwd().makePath(env.work);
    for (table) |s| {
        if (!std.mem.eql(u8, s.name, want)) continue;
        s.run(env);
        const marker = out orelse die("--out is required", .{});
        try std.fs.cwd().writeFile(.{ .sub_path = marker, .data = lineText(env, "scenario {s}: every check held\n", .{want}) });
        return;
    }
    die("no scenario {s}", .{want});
}
