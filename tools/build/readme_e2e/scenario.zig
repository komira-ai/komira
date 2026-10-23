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

const Pkg = struct {
    name: []const u8,
    version: []const u8 = "1.2.3",
    deps: []const []const u8 = &.{},
    readme: []const u8,
    /// The package's payload, for a scenario that needs another one.
    payload_name: ?[]const u8 = null,
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
            const bytes = fix.package(self.a, inside, p.version, build, mojoc, p.deps) catch die("cannot build the fixture {s}", .{p.name});
            const file = std.fmt.allocPrint(self.a, "in/{s}/linux-64/mojo-{s}-{s}-{s}.conda", .{ p.name, p.name, p.version, build }) catch die("out of memory", .{});
            self.put(file, bytes);
            const readme = std.fmt.allocPrint(self.a, "in/{s}/README.md", .{p.name}) catch die("out of memory", .{});
            self.put(readme, p.readme);
            argv.appendSlice(self.a, &.{ "--member", p.name, p.version, self.join(&.{file}), self.join(&.{readme}) }) catch die("out of memory", .{});
        }
        return self.exec(argv.items);
    }

    /// `readme_e2e verify` of `package` over `set`, with `mopm` as the stand-in's name.
    fn verify(self: Env, package: []const u8, version: []const u8, mojo: []const u8, mopm: []const u8) Result {
        const fake = self.fake;
        const argv = [_][]const u8{
            self.tool,                                              "verify",
            "--package",                                            package,
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
    expectText(r, "PASS good 1.2.3: 2 README example(s) compiled and ran against the installed package");
    const marker = env.get("run.marker") orelse die("no marker written", .{});
    if (std.mem.indexOf(u8, marker, "PASS good 1.2.3") == null) die("the marker is `{s}`", .{marker});
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
    if (plan.members.len != 2 or !std.mem.eql(u8, plan.members[0].name, "zlib") or !std.mem.eql(u8, plan.members[1].name, "app")) die("the plan is not in dependency order", .{});
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
    expectText(r, lineText(env, "FAIL compile: good: README.md:{d} does not compile against the installed package", .{fenceLine(pkg.readme, 2)}));
    // The compiler's message names the README, not the generated program.
    expectText(r, "good/README.md:1:1: error: use of unknown declaration 'COMPILE_ERROR'");
    expectNoText(r, "readme_good_");
    expectNoText(r, "PASS good");
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
    expectText(r, lineText(env, "FAIL compile: good: README.md:{d} does not compile against the installed package", .{fenceLine(pkg.readme, 2)}));
    expectText(r, "unable to locate module 'outside'");
    expectNoText(r, "PASS good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn runError(env: Env) void {
    const pkg = goodReadme(env, &.{ good_use, "from good import value\nRUN_ERROR" });
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, lineText(env, "FAIL run: good: README.md:{d} fails when run", .{fenceLine(pkg.readme, 2)}));
    expectNoText(r, "FAIL compile");
    expectNoText(r, "PASS good");
    if (env.exists("run.marker")) die("a marker was written for a package that did not pass", .{});
}

fn missingPackage(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("absent", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL staged: absent: the staged set has no member absent");
    if (env.exists("run/prefix")) die("something was installed for a package the set lacks", .{});
}

fn missingFile(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    std.fs.cwd().deleteFile(env.join(&.{"set/linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda"})) catch |e| die("cannot delete the staged file: {s}", .{@errorName(e)});
    // A lock made from the plan names the file the set lacks, so the mopm does not die
    // first: it is verify's own check that refuses.
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_plan");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: good: linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda is in the plan and not in the staged set");
    expectNoText(r, "PASS good");
    if (env.exists("run/prefix/lib/mojo/good.mojoc")) die("something was unpacked for a file the set lacks", .{});
    if (env.exists("run.marker")) die("a marker was written for a package that did not install", .{});
}

fn tamperedFile(env: Env) void {
    // The file in the set is another valid package's: a lock made from the
    // registry's index pins the plan's hash, and the file is not that.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const other = fix.package(env.a, "good", "1.2.3", "mojo1.0.0_0", "mojoc of something else", &.{}) catch die("fixture", .{});
    env.put("set/linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda", other);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_registry");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: good: linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda is not the file the lock pins");
    if (env.exists("run/prefix/lib/mojo/good.mojoc")) die("a file that is not the pinned one was unpacked", .{});
}

fn changedFile(env: Env) void {
    // The same, with a lock made from the file in the set: the plan disagrees.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const other = fix.package(env.a, "good", "1.2.3", "mojo1.0.0_0", "mojoc of something else", &.{}) catch die("fixture", .{});
    env.put("set/linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda", other);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "is not a file of the staged plan");
}

fn oldMopm(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_old");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: good: `mopm add good@=1.2.3 --overlay <staged set>` exited 1");
    expectText(r, "the pinned mopm may predate `--overlay`");
    if (env.exists("run.marker")) die("a marker was written although nothing was installed", .{});
}

fn oldMopmUsage(env: Env) void {
    // The pinned mopm (0.0.25) answers `add ... --overlay` with its usage text and exit 2.
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm_usage");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: good: `mopm add good@=1.2.3 --overlay <staged set>` exited 2");
    expectText(r, "usage: mopm lock");
    expectText(r, "the pinned mopm may predate `--overlay`");
    if (env.exists("run.marker")) die("a marker was written although nothing was installed", .{});
}

fn wrongCompiler(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.1.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL install: good: good 1.2.3 is built as mojo1.1.0_0, and the release's compiler is 1.0.0");
}

fn wrongVersion(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "9.9.9", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL staged: good: the staged set holds good 1.2.3, and the release is 9.9.9");
}

fn skippedMember(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{good_use})}, "1.0.0"), 0, "stage");
    const text = env.get("set/plan.json").?;
    const at = std.mem.indexOf(u8, text, "\"upload\"") orelse die("no upload in the plan", .{});
    const edited = std.mem.concat(env.a, u8, &.{ text[0..at], "\"skip\"", text[at + "\"upload\"".len ..] }) catch die("out of memory", .{});
    env.put("set/plan.json", edited);
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL staged: good: the staged set's member is `skip`, not `upload`");
}

fn noExample(env: Env) void {
    expectCode(env.stage(&.{goodReadme(env, &.{})}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL readme: good: the README holds no ```mojo example, so nothing would be compiled or run");
}

fn refusedReadme(env: Env) void {
    const pkg = Pkg{ .name = "good", .readme = "# good\n\n```mojo skip\nfrom good import value\n```\n" };
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL readme: good: the README is refused");
    expectText(r, "good/README.md:3");
}

fn relativeLink(env: Env) void {
    const pkg = Pkg{ .name = "good", .readme = "# good\n\nSee [the design](docs/design.md).\n\n```mojo\nfrom good import value\nprint(value())\n```\n" };
    expectCode(env.stage(&.{pkg}, "1.0.0"), 0, "stage");
    const r = env.verify("good", "1.2.3", "1.0.0", "mopm");
    expectCode(r, 1, "verify");
    expectText(r, "FAIL readme: good: the README is refused");
    expectText(r, "good/README.md:3");
}

fn assembleMissingDependency(env: Env) void {
    const app = Pkg{ .name = "app", .deps = &.{"ghost"}, .readme = readmeOf(env, "app", &.{"from app import run"}) };
    const r = env.stage(&.{app}, "1.0.0");
    expectCode(r, 1, "stage");
    expectText(r, "app needs ghost, which is not in the set");
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
    expectText(r, "readme_e2e assemble: good: ");
    expectText(r, "holds no lib/mojo/good.mopm.json");
}

fn assembleLink(env: Env) void {
    // A package whose payload is a symbolic link is refused.
    const tar = fix.tarWithLink(env.a, "lib/mojo/good.mojoc", "/etc/passwd") catch die("fixture", .{});
    const bytes = fix.condaOf(env.a, "mojo-good-1.2.3-mojo1.0.0_0", tar) catch die("fixture", .{});
    env.put("in/good/linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda", bytes);
    env.put("in/good/README.md", "# good\n");
    const r = env.exec(&.{
        env.tool,                                           "assemble",
        "--out",                                            env.join(&.{"set"}),
        "--mojo",                                           "1.0.0",
        "--member",                                         "good",
        "1.2.3",                                            env.join(&.{"in/good/linux-64/mojo-good-1.2.3-mojo1.0.0_0.conda"}),
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
    .{ .name = "old_mopm", .run = oldMopm },
    .{ .name = "old_mopm_usage", .run = oldMopmUsage },
    .{ .name = "wrong_compiler", .run = wrongCompiler },
    .{ .name = "wrong_version", .run = wrongVersion },
    .{ .name = "skipped_member", .run = skippedMember },
    .{ .name = "no_example", .run = noExample },
    .{ .name = "refused_readme", .run = refusedReadme },
    .{ .name = "relative_link", .run = relativeLink },
    .{ .name = "assemble_missing_dependency", .run = assembleMissingDependency },
    .{ .name = "assemble_cycle", .run = assembleCycle },
    .{ .name = "assemble_wrong_package", .run = assembleWrongPackage },
    .{ .name = "assemble_link", .run = assembleLink },
    .{ .name = "usage", .run = usageError },
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
