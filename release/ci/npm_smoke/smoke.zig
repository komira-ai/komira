//! The smoke: the set's main package at the set's version, installed from the registry as a user installs it,
//! and one query through it. npm.yml's `smoke` job runs it after the publish, on a fresh runner with no
//! checkout, no identity and no permission: the one place a test reaches the network, and it reaches only the
//! npm registry.
//!
//! In `<work>/project`, made empty: a package.json that depends on `<main>` at exactly the set's version, and
//! `npm install --ignore-scripts --engine-strict`, so npm resolves the platform package for this host from the
//! main package's optionalDependencies and apache-arrow as its peer, as it does for a user. The install is tried
//! up to `attempts` times, `delay_ms` apart, while the registry catches up with the publish. Then, with no
//! command between the install and the query:
//!  - package-lock.json holds the main package and at least one platform package of the set, each at the set's
//!    version and with the set's integrity; it holds no other package of the scope and no package that has an
//!    install script;
//!  - `node smoke.mjs` imports the package by its name, runs `SELECT 1 AS n` in a Session and prints
//!    `<version> <column names> <value>`, which must be exactly `<set version> n 1`.
//! Each refusal names the package, the field or the command, with both texts where two differ.
const std = @import("std");
const common = @import("common.zig");
const npm = @import("npm.zig");
const set_mod = @import("set.zig");

const Allocator = common.Allocator;
const Error = common.Error;
const refuse = common.refuse;

/// The program the smoke runs in the project, after the install.
pub const program =
    \\import { Session, version } from "@komira-ai/komira";
    \\
    \\const session = new Session();
    \\try {
    \\  const table = await (await session.sql("SELECT 1 AS n")).toArrow();
    \\  const names = table.schema.fields.map((f) => f.name).join(",");
    \\  console.log(`${version} ${names} ${table.getChild("n")?.get(0)}`);
    \\} finally {
    \\  await session[Symbol.asyncDispose]();
    \\}
    \\
;

pub const Options = struct {
    tools: npm.Tools,
    attempts: u32,
    delay_ms: u64,
    /// The pause between two install attempts (the cases pass one that only counts).
    pause: Pause,
};

/// Waits `ms` milliseconds between two install attempts.
pub const Pause = struct {
    ctx: *anyopaque,
    pauseFn: *const fn (ctx: *anyopaque, ms: u64) void,

    pub fn wait(self: Pause, ms: u64) void {
        self.pauseFn(self.ctx, ms);
    }
};

/// The project's package.json: the main package alone, at exactly the set's version.
pub fn manifest(a: Allocator, set: set_mod.Set) Error![]const u8 {
    return std.fmt.allocPrint(a, "{{\n  \"name\": \"komira-npm-smoke\",\n  \"private\": true,\n  \"dependencies\": {{\n    \"{s}\": \"{s}\"\n  }}\n}}\n", .{ set.main, set.version });
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

/// Holds the package-lock.json npm wrote (`text`) to `set`.
pub fn checkLock(a: Allocator, why: *[]const u8, set: set_mod.Set, text: []const u8) Error!void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(a, why, "package-lock.json is not JSON ({s})", .{@errorName(e)}),
    };
    const packages = switch (root) {
        .object => |o| o.get("packages") orelse return refuse(a, why, "package-lock.json has no packages", .{}),
        else => return refuse(a, why, "package-lock.json is not an object", .{}),
    };
    const entries = switch (packages) {
        .object => |o| o,
        else => return refuse(a, why, "the packages of package-lock.json are not an object", .{}),
    };
    var platforms: usize = 0;
    var it = entries.iterator();
    while (it.next()) |kv| {
        const path = kv.key_ptr.*;
        const entry = switch (kv.value_ptr.*) {
            .object => |o| o,
            else => return refuse(a, why, "package-lock.json: {s} is not an object", .{path}),
        };
        if (entry.get("hasInstallScript")) |h| {
            if (h == .bool and h.bool) return refuse(a, why, "package-lock.json: {s} has an install script: the packages need none", .{path});
        }
        const at = std.mem.lastIndexOf(u8, path, "node_modules/") orelse continue;
        const name = path[at + "node_modules/".len ..];
        if (!std.mem.startsWith(u8, name, set_mod.scope)) continue;
        const p = set.find(name) orelse return refuse(a, why, "npm installed {s} ({s}), which is no package of the set", .{ name, path });
        if (!std.mem.eql(u8, path, try std.fmt.allocPrint(a, "node_modules/{s}", .{name})))
            return refuse(a, why, "npm installed {s} at {s}, not at the top of node_modules", .{ name, path });
        const version = str(entry.get("version")) orelse "<none>";
        if (!std.mem.eql(u8, version, set.version)) return refuse(a, why, "npm installed {s} at {s}, not the set's {s}", .{ name, version, set.version });
        const sri = str(entry.get("integrity")) orelse "<none>";
        if (!std.mem.eql(u8, sri, p.integrity)) return refuse(a, why, "npm installed {s} with the integrity {s}, not the set's {s}: the registry serves other bytes than were built", .{ name, sri, p.integrity });
        if (!std.mem.eql(u8, name, set.main)) platforms += 1;
    }
    const main_path = try std.fmt.allocPrint(a, "node_modules/{s}", .{set.main});
    if (entries.get(main_path) == null) return refuse(a, why, "package-lock.json does not hold {s}", .{set.main});
    if (platforms == 0) return refuse(a, why, "npm installed no platform package of the set for this host ({d} in the set)", .{set.packages.len - 1});
}

/// The install from the registry and the query, in `opts.tools.work`, which must not exist or be empty.
pub fn run(a: Allocator, why: *[]const u8, runner: npm.Runner, opts: Options, set: set_mod.Set, log: *std.Io.Writer) !void {
    try common.requireFreeDir(a, why, "--work", opts.tools.work);
    try opts.tools.prepare(a, why);
    const project = try std.fs.path.join(a, &.{ opts.tools.work, "project" });
    std.fs.cwd().makePath(project) catch |e| return refuse(a, why, "cannot make {s}: {s}", .{ project, @errorName(e) });
    try common.writeFile(a, why, try std.fs.path.join(a, &.{ project, "package.json" }), try manifest(a, set));
    try common.writeFile(a, why, try std.fs.path.join(a, &.{ project, "smoke.mjs" }), program);

    const spec = try std.fmt.allocPrint(a, "{s}@{s}", .{ set.main, set.version });
    const install = try opts.tools.argv(a, &.{ "install", "--ignore-scripts", "--engine-strict" });
    const what = try std.fmt.allocPrint(a, "installing {s} from the registry", .{spec});
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        const r = try npm.run(a, why, runner, what, install, project);
        if (r.code != null and r.code.? == 0) break;
        if (attempt >= opts.attempts) return npm.failed(a, why, try std.fmt.allocPrint(a, "{s} (attempt {d} of {d})", .{ what, attempt, opts.attempts }), install, r);
        try log.print("npm_smoke: {s}: attempt {d} of {d} failed, trying again in {d} s\n", .{ what, attempt, opts.attempts, opts.delay_ms / 1000 });
        try log.flush();
        opts.pause.wait(opts.delay_ms);
    }
    const lock = try common.readFile(a, why, "the lock file", try std.fs.path.join(a, &.{ project, "package-lock.json" }));
    try checkLock(a, why, set, lock);

    const query = [_][]const u8{ opts.tools.node, "smoke.mjs" };
    const q = try npm.run(a, why, runner, "the query", &query, project);
    if (q.code == null or q.code.? != 0) return npm.failed(a, why, "the query", &query, q);
    const want = try std.fmt.allocPrint(a, "{s} n 1\n", .{set.version});
    if (!std.mem.eql(u8, q.stdout, want)) return refuse(a, why, "the query printed \"{s}\", not \"{s}\"", .{ q.stdout, want });
    try log.print("npm_smoke: {s} from the registry: the lock holds the set's integrity, and SELECT 1 answered 1\n", .{spec});
    try log.flush();
}
