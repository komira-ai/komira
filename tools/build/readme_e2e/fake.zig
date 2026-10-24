//! Stand-ins for the programs `readme_e2e verify` runs, for the scenarios
//! (scenario.zig) and for the one target that runs the real compiler over a
//! real package before the pinned mopm has `--overlay` (tools/build/tests,
//! functional/readme_e2e).
//!
//!     fake mopm add NAME@=VERSION --overlay DIR --registry URL
//!         What `mopm add --overlay` does for a staged set that holds the whole
//!         closure: reads the registry's configuration (URL must be a loopback
//!         one, offline.zig), reads DIR/plan.json and the packages it names, and
//!         writes `mopm.lock` (version 1) in the current directory, one entry per
//!         package of the closure. A package the set lacks is asked of the
//!         registry, as the real one does, and the registry's refusal fails the
//!         command. Both options are required: the e2e names its registry itself.
//!     fake mopm_swallow add ...
//!         The same, but a refusal of the registry is ignored: the package is left
//!         out of the lock and the command exits 0.
//!     fake mopm_registry add ...
//!         The same, but the lock holds the sha256 and size the plan gives, as a
//!         lock made from a registry's index would: the file is not read for them.
//!     fake mopm_plan add ...
//!         The same, but the lock is made from the plan alone: no file is read, so a
//!         member's file the staged set lacks is still locked (with the plan's sha256
//!         and size and no dependencies), as a lock made from a registry's index
//!         would name a file this set does not carry.
//!     fake mopm_usage add ...
//!         A mopm that predates `--overlay` as the pinned release answers it: its usage
//!         text, exit 2 (recorded from mopm 0.0.25).
//!     fake mopm_old add ...
//!         A mopm that predates `--overlay`: refuses the option as unknown.
//!     fake compile build [options] -I<dir>... PROGRAM -o EXE
//!         Refuses a program containing COMPILE_ERROR, and one that imports a
//!         module no `-I` directory holds as `<module>.mojoc`; otherwise EXE is
//!         a copy of the program. Not a Mojo compiler: the real one is the
//!         toolchain's, and a target runs it over a real package.
//!     fake gate mojo ... --label L --test T --marker M
//!         Fails a test whose file contains RUN_ERROR; otherwise writes
//!         `PASS <label>` to the marker. The test must sit in `bin/` beside a
//!         `share/` directory, the root `gate mojo` runs it from.

const std = @import("std");
const Allocator = std.mem.Allocator;
const conda = @import("conda.zig");
const plan_mod = @import("plan.zig");
const offline = @import("offline.zig");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch "fake: error\n";
    std.fs.File.stderr().writeAll(text) catch {};
    std.process.exit(1);
}

fn fileOrDie(a: Allocator, dir: std.fs.Dir, path: []const u8) []u8 {
    return dir.readFileAlloc(a, path, 1 << 29) catch |e| die("mopm: cannot read {s}: {s}", .{ path, @errorName(e) });
}

/// `mojo<version>_0` out of `mojo-<name>-<version>-<build>.conda`.
fn buildOf(filename: []const u8, name: []const u8, version: []const u8) []const u8 {
    const head_len = "mojo-".len + name.len + 1 + version.len + 1;
    return filename[head_len .. filename.len - ".conda".len];
}

const Mode = enum { read_files, plan_hashes, plan_only, swallow };

/// What mopm does for a package the overlay lacks: asks the registry for its index. A refusal
/// (any answer but 200 and 404) is mopm's error, as the real one reports it; `swallow` mode
/// is a mopm that ignores it. Returns when the refusal was ignored.
fn askRegistry(a: Allocator, registry: []const u8, name: []const u8, mode: Mode) void {
    const target = offline.indexTarget(a, name) catch die("mopm: out of memory", .{});
    const answer = offline.get(a, registry, target) catch |e| die("mopm: cannot read {s}{s}: {s}", .{ registry, target, @errorName(e) });
    if (answer.status == 404) die("mopm: no package {s} in the overlay or the registry", .{name});
    if (answer.status == 200) die("mopm: this stand-in has no package {s} to take from the registry", .{name});
    if (mode == .swallow) return;
    die("mopm: {s}{s} answered HTTP {d}: {s}", .{ registry, target, answer.status, answer.body });
}

fn mopmAdd(a: Allocator, args: []const []const u8, mode: Mode) void {
    const from_plan = mode == .plan_hashes or mode == .plan_only;
    // add NAME@=VERSION --overlay DIR --registry URL: the e2e names an offline registry itself
    // (offline.zig) and never leaves mopm its default one.
    if (args.len != 6 or !std.mem.eql(u8, args[0], "add") or !std.mem.eql(u8, args[2], "--overlay") or !std.mem.eql(u8, args[4], "--registry")) {
        die("mopm: usage: add NAME@=VERSION --overlay DIR --registry URL", .{});
    }
    const registry = args[5];
    if (!std.mem.startsWith(u8, registry, "http://127.0.0.1:")) die("mopm: the registry {s} is not a loopback URL: the e2e must be offline", .{registry});
    const at = std.mem.indexOf(u8, args[1], "@=") orelse die("mopm: {s} is not name@=version", .{args[1]});
    const want_name = args[1][0..at];
    const want_version = args[1][at + 2 ..];
    var why: []const u8 = "";
    var staged = std.fs.cwd().openDir(args[3], .{}) catch |e| die("mopm: cannot open the overlay {s}: {s}", .{ args[3], @errorName(e) });
    defer staged.close();
    // A registry that is not the production one is asked for its configuration, once, for the
    // channel the lock names (the real mopm does the same).
    const config = offline.get(a, registry, "/index/config.json") catch |e| die("mopm: cannot read the configuration of {s}: {s}", .{ registry, @errorName(e) });
    if (config.status != 200) die("mopm: {s}/index/config.json answered HTTP {d}", .{ registry, config.status });
    const plan = plan_mod.parsePlan(a, fileOrDie(a, staged, "plan.json"), &why) catch die("mopm: {s}", .{why});
    const manifest = fileOrDie(a, std.fs.cwd(), "mopm.toml");
    if (std.mem.indexOf(u8, manifest, "[toolchain]") == null) die("mopm: mopm.toml has no [toolchain] mojo", .{});

    var locked: std.ArrayList(plan_mod.Locked) = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    todo.append(a, want_name) catch die("mopm: out of memory", .{});
    while (todo.pop()) |name| {
        var seen = false;
        for (locked.items) |l| seen = seen or std.mem.eql(u8, l.name, name);
        if (seen) continue;
        const m = plan.member(name) orelse {
            askRegistry(a, registry, name, mode);
            continue;
        };
        if (std.mem.eql(u8, name, want_name) and !std.mem.eql(u8, m.version, want_version)) {
            die("mopm: no {s} {s} (the overlay holds {s})", .{ name, want_version, m.version });
        }
        if (m.files.len != 1) die("mopm: {s}: this stand-in reads one file per member", .{name});
        const f = m.files[0];
        const rel = std.fs.path.join(a, &.{ f.subdir, f.filename }) catch die("mopm: out of memory", .{});
        const bytes: []const u8 = if (mode == .plan_only) "" else fileOrDie(a, staged, rel);
        var deps: std.ArrayList([]const u8) = .empty;
        if (mode != .plan_only) {
            const files = conda.read(a, bytes, &why) catch die("mopm: {s}: {s}", .{ rel, why });
            const meta_path = std.fmt.allocPrint(a, "lib/mojo/{s}.mopm.json", .{name}) catch die("mopm: out of memory", .{});
            const meta_bytes = conda.find(files, meta_path) orelse die("mopm: {s} holds no {s}", .{ rel, meta_path });
            const meta = plan_mod.parseMetadata(a, meta_bytes, &why) catch die("mopm: {s}", .{why});
            for (meta.deps) |d| {
                deps.append(a, d.name) catch die("mopm: out of memory", .{});
                todo.append(a, d.name) catch die("mopm: out of memory", .{});
            }
        }
        const build = buildOf(f.filename, name, m.version);
        locked.append(a, .{
            .name = name,
            .version = m.version,
            .build = build,
            .subdir = f.subdir,
            .url = std.fmt.allocPrint(a, "https://conda.mopm.dev/{s}/{s}", .{ f.subdir, f.filename }) catch die("mopm: out of memory", .{}),
            .sha256 = if (from_plan) f.sha256 else a.dupe(u8, &plan_mod.sha256Hex(bytes)) catch die("mopm: out of memory", .{}),
            .size = if (from_plan) f.size else bytes.len,
            .mojo = if (std.mem.startsWith(u8, build, "mojo") and build.len > "mojo_0".len) build["mojo".len .. build.len - "_0".len] else "",
            .deps = deps.items,
        }) catch die("mopm: out of memory", .{});
    }
    std.mem.sort(plan_mod.Locked, locked.items, {}, struct {
        fn less(_: void, x: plan_mod.Locked, y: plan_mod.Locked) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    const mojo = if (locked.items.len > 0) locked.items[0].mojo else "";
    const text = plan_mod.renderLock(a, mojo, locked.items) catch die("mopm: cannot write the lock", .{});
    std.fs.cwd().writeFile(.{ .sub_path = "mopm.lock", .data = text }) catch |e| die("mopm: cannot write mopm.lock: {s}", .{@errorName(e)});
}

fn compile(a: Allocator, args: []const []const u8) void {
    var includes: std.ArrayList([]const u8) = .empty;
    var program: ?[]const u8 = null;
    var exe: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const w = args[i];
        if (std.mem.startsWith(u8, w, "-I")) {
            includes.append(a, w[2..]) catch die("error: out of memory", .{});
        } else if (std.mem.eql(u8, w, "-o")) {
            i += 1;
            if (i >= args.len) die("error: -o takes a path", .{});
            exe = args[i];
        } else if (std.mem.endsWith(u8, w, ".mojo")) {
            program = w;
        }
    }
    const src_path = program orelse die("error: no program", .{});
    const out_path = exe orelse die("error: no -o", .{});
    const src = fileOrDie(a, std.fs.cwd(), src_path);
    if (std.mem.indexOf(u8, src, "COMPILE_ERROR") != null) die("{s}:1:1: error: use of unknown declaration 'COMPILE_ERROR'", .{src_path});
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimLeft(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "from ")) continue;
        var words = std.mem.tokenizeScalar(u8, line["from ".len..], ' ');
        const module = words.next() orelse continue;
        const root = if (std.mem.indexOfScalar(u8, module, '.')) |dot| module[0..dot] else module;
        if (std.mem.eql(u8, root, "std")) continue;
        var found = false;
        for (includes.items) |dir| {
            const p = std.fmt.allocPrint(a, "{s}/{s}.mojoc", .{ dir, root }) catch die("error: out of memory", .{});
            if (std.fs.cwd().access(p, .{})) |_| found = true else |_| {}
        }
        if (!found) die("{s}: error: unable to locate module '{s}'", .{ src_path, root });
    }
    const h = std.fs.cwd().createFile(out_path, .{ .mode = 0o755 }) catch |e| die("error: cannot write {s}: {s}", .{ out_path, @errorName(e) });
    defer h.close();
    h.writeAll(src) catch |e| die("error: cannot write {s}: {s}", .{ out_path, @errorName(e) });
}

fn gate(a: Allocator, args: []const []const u8) void {
    var label: ?[]const u8 = null;
    var test_path: ?[]const u8 = null;
    var marker: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--label")) label = args[i + 1];
        if (std.mem.eql(u8, args[i], "--test")) test_path = args[i + 1];
        if (std.mem.eql(u8, args[i], "--marker")) marker = args[i + 1];
    }
    const t = test_path orelse die("gate: no --test", .{});
    const l = label orelse die("gate: no --label", .{});
    const m = marker orelse die("gate: no --marker", .{});
    const bin = std.fs.path.dirname(t) orelse die("gate: --test {s} is in no directory", .{t});
    const share = std.fs.path.join(a, &.{ bin, "..", "share" }) catch die("gate: out of memory", .{});
    std.fs.cwd().access(share, .{}) catch die("gate: {s} has no share/ beside its bin/", .{t});
    const body = fileOrDie(a, std.fs.cwd(), t);
    if (std.mem.indexOf(u8, body, "RUN_ERROR") != null) die("FAIL {s}: the test raised RUN_ERROR", .{l});
    const text = std.fmt.allocPrint(a, "PASS {s}\n", .{l}) catch die("gate: out of memory", .{});
    std.fs.cwd().writeFile(.{ .sub_path = m, .data = text }) catch |e| die("gate: cannot write {s}: {s}", .{ m, @errorName(e) });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) die("fake: usage: fake mopm|mopm_old|compile|gate ...", .{});
    const rest = argv[2..];
    if (std.mem.eql(u8, argv[1], "mopm")) return mopmAdd(a, rest, .read_files);
    if (std.mem.eql(u8, argv[1], "mopm_registry")) return mopmAdd(a, rest, .plan_hashes);
    if (std.mem.eql(u8, argv[1], "mopm_plan")) return mopmAdd(a, rest, .plan_only);
    if (std.mem.eql(u8, argv[1], "mopm_swallow")) return mopmAdd(a, rest, .swallow);
    if (std.mem.eql(u8, argv[1], "mopm_old")) die("mopm: unknown option '--overlay'", .{});
    if (std.mem.eql(u8, argv[1], "mopm_usage")) {
        std.fs.File.stderr().writeAll("usage: mopm lock   [--registry <prod|gamma|beta|url>]\n       mopm update [<package>...] [--registry <prod|gamma|beta|url>]\n       mopm tree\n       mopm sync   [--locked] [--registry <prod|gamma|beta|url>] [--pixi <path>]\n       mopm add    <package>[@<requirement>] [--dev] [--path <dir>] [--registry <prod|gamma|beta|url>]\n") catch {};
        std.process.exit(2);
    }
    if (std.mem.eql(u8, argv[1], "compile")) return compile(a, rest);
    if (std.mem.eql(u8, argv[1], "gate")) return gate(a, rest);
    die("fake: unknown program {s}", .{argv[1]});
}
