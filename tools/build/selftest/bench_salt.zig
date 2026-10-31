//! bench_salt: `-c komira.bench_salt=<string>` puts one more environment
//! variable (`KOMIRA_BENCH_SALT`) in every action a target's own rules run,
//! so each executes on the farm and reads its inputs from the content store,
//! and leaves every action key as it was when the value is empty or unset
//! (tools/build/bench_salt/README.md).
//!
//! The same targets are built four times, each in a fresh daemon (a fresh
//! daemon is what makes `log what-ran` list every action), and each build's
//! actions are read with their action digests:
//!
//!   1. no value: the baseline;
//!   2. `-c komira.bench_salt=` (empty): every listed action has the digest
//!      it has in the baseline, and the lists are the same;
//!   3. a value no build used before: every action of a listed target
//!      carries a new digest and executes on the farm (not a cache hit), and
//!      no tool action (the Zig launcher, the unpacked toolchains) changes
//!      key, so the compiler and the runners stay cache hits;
//!   4. the same value again: the same digests, every one a cache hit.
//!
//! And a value with a space, a quote or a slash is refused at load.
//! Catches: a rule that does not add the variable (its target's actions keep
//! their digests), the variable added when the value is empty (the digests
//! of 2 move), the salt reaching a tool (the launcher changes key), and a
//! value that is not a plain word accepted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const Kind = struct { rule: []const u8, target: []const u8 };

/// One target of each rule family that carries the salt.
const KINDS = [_]Kind{
    .{ .rule = "mojo_library", .target = "komira//tools/build/examples/libgate_ok:libgate_ok" },
    .{ .rule = "mojo_binary", .target = "komira//tools/build/examples:hello" },
    .{ .rule = "mojo_shared_lib", .target = "komira//tools/build/examples/shared_lib:plain" },
    .{ .rule = "rust_library", .target = "komira//tools/build/examples/rust/ext:ext" },
    .{ .rule = "rust_binary", .target = "komira//tools/build/examples/rust/ext:ext_consumer" },
    .{ .rule = "native_shared_library", .target = "komira//src/komira_async_api:komira_async_api_native" },
    .{ .rule = "komira_pack_tar", .target = "komira//tools/build/examples:hello_tarball" },
    .{ .rule = "komira_conda_package", .target = "komira//src/komira_retry:komira_retry_conda" },
};

/// The categories of the actions that build the tools and unpack the
/// toolchains: shared by every target, so they must keep their keys.
const TOOL_CATEGORIES = [_][]const u8{ "zig_", "conda_unpack", "tar_member" };

const Line = struct { identity: []const u8, executor: []const u8, digest: []const u8 };

fn parse(c: *lib.Ctx, text: []const u8) ![]Line {
    var out = std.ArrayList(Line).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        _ = f.next() orelse continue;
        const identity = f.next() orelse continue;
        const executor = f.next() orelse continue;
        const digest = f.next() orelse continue;
        try out.append(c.a, .{ .identity = identity, .executor = executor, .digest = digest });
    }
    return out.items;
}

/// The actions of all KINDS built with `cfg`, in a fresh daemon; null when
/// the build failed (reported).
fn actions(c: *lib.Ctx, what: []const u8, cfg: []const []const u8) !?[]Line {
    _ = try c.run(&.{"kill"}, .{ .configured = false, .track = false });
    var words = std.ArrayList([]const u8).empty;
    try words.append(c.a, "build");
    for (KINDS) |k| try words.append(c.a, k.target);
    const res = try c.run(words.items, .{ .cfg = cfg });
    if (!res.ok()) {
        c.fail("{s}: the build failed (see {s})", .{ what, res.log });
        return null;
    }
    const wr = try c.run(&.{ "log", "what-ran" }, .{ .configured = false });
    if (!wr.ok()) {
        c.fail("{s}: cannot read what-ran (see {s})", .{ what, wr.log });
        return null;
    }
    return try parse(c, wr.stdout);
}

fn find(ls: []const Line, identity: []const u8) ?Line {
    for (ls) |l| if (std.mem.eql(u8, l.identity, identity)) return l;
    return null;
}

fn ofKind(l: Line) ?Kind {
    for (KINDS) |k| if (lib.whatran.ofTarget(l.identity, k.target)) return k;
    return null;
}

fn isTool(identity: []const u8) bool {
    const open = std.mem.lastIndexOfScalar(u8, identity, '(') orelse return false;
    const category = identity[open + 1 ..];
    for (TOOL_CATEGORIES) |p| if (std.mem.startsWith(u8, category, p)) return true;
    return false;
}

fn farm(executor: []const u8) bool {
    return std.mem.startsWith(u8, executor, "re(") or std.mem.eql(u8, executor, "re");
}

fn sameKeys(c: *lib.Ctx, what: []const u8, base: []const Line, other: []const Line) void {
    var moved: usize = 0;
    var first: []const u8 = "";
    for (base) |b| {
        const o = find(other, b.identity);
        if (o == null or !std.mem.eql(u8, o.?.digest, b.digest)) {
            moved += 1;
            if (first.len == 0) first = b.identity;
        }
    }
    if (base.len == 0) {
        c.fail("{s}: the baseline build listed no action", .{what});
    } else if (moved > 0 or other.len != base.len) {
        c.fail("{s}: {d} of {d} action(s) changed key, first {s} (the other build lists {d})", .{ what, moved, base.len, first, other.len });
    } else {
        c.pass("{s}: all {d} actions keep their digest", .{ what, base.len });
    }
}

fn salted(c: *lib.Ctx, base: []const Line, salt: []const Line) void {
    for (KINDS) |k| {
        var n: usize = 0;
        var moved: usize = 0;
        var ran: usize = 0;
        var first_same: []const u8 = "";
        for (base) |b| {
            if (!lib.whatran.ofTarget(b.identity, k.target)) continue;
            n += 1;
            const s = find(salt, b.identity) orelse continue;
            if (!std.mem.eql(u8, s.digest, b.digest)) {
                moved += 1;
            } else if (first_same.len == 0) {
                first_same = b.identity;
            }
            if (farm(s.executor)) ran += 1;
        }
        if (n == 0) {
            c.fail("{s}: {s}: no action in the baseline", .{ k.rule, k.target });
        } else if (moved != n) {
            c.fail("{s}: {s}: {d} of {d} action(s) kept their key under the salt, first {s}", .{ k.rule, k.target, n - moved, n, first_same });
        } else if (ran != n) {
            c.fail("{s}: {s}: {d} of {d} action(s) did not execute on the farm", .{ k.rule, k.target, n - ran, n });
        } else {
            c.pass("{s}: {s}: all {d} actions have a new digest and executed on the farm", .{ k.rule, k.target, n });
        }
    }
    var tools: usize = 0;
    var moved_tool: usize = 0;
    var first: []const u8 = "";
    for (base) |b| {
        if (ofKind(b) != null or !isTool(b.identity)) continue;
        tools += 1;
        const s = find(salt, b.identity);
        if (s == null or !std.mem.eql(u8, s.?.digest, b.digest)) {
            moved_tool += 1;
            if (first.len == 0) first = b.identity;
        }
    }
    if (tools == 0) {
        c.fail("tools: the baseline lists no tool action", .{});
    } else if (moved_tool > 0) {
        c.fail("tools: {d} of {d} tool action(s) changed key under the salt, first {s}", .{ moved_tool, tools, first });
    } else {
        c.pass("tools: {d} tool actions (the launcher, the unpacked toolchains) keep their key under the salt", .{tools});
    }
}

fn replay(c: *lib.Ctx, first: []const Line, again: []const Line) void {
    sameKeys(c, "the same salt again", first, again);
    var ran: usize = 0;
    for (again) |l| {
        if (ofKind(l) != null and farm(l.executor)) ran += 1;
    }
    c.rep.check(ran == 0, "the same salt again: every action of the targets is a cache hit", "an action executed again");
}

const REFUSED = [_]lib.Row{
    .{
        .name = "bench_salt_space",
        .target = "komira//tools/build/examples:hello",
        .text = "[komira] bench_salt = \"a b\": it must be empty or letters, digits, `.`, `_` and `-` (tools/build/bench_salt/README.md)",
        .cfg = &.{"komira.bench_salt=a b"},
    },
    .{
        .name = "bench_salt_slash",
        .target = "komira//tools/build/examples:hello",
        .text = "[komira] bench_salt = \"a/b\": it must be empty or letters, digits, `.`, `_` and `-` (tools/build/bench_salt/README.md)",
        .cfg = &.{"komira.bench_salt=a/b"},
    },
};

const FIXTURE = "tests//functional/bench_salt:env";
const MARK = "\"KOMIRA_BENCH_SALT_FIXTURE\": \"1\"";

/// The environment `salted` gives under each value, in the provider dump of
/// the fixture: the environment as given and no `KOMIRA_BENCH_SALT` when the
/// value is unset or empty, the variable with the value otherwise.
fn envRows(c: *lib.Ctx) !void {
    const Row = struct { what: []const u8, cfg: []const []const u8, want: ?[]const u8 };
    const rows = [_]Row{
        .{ .what = "unset", .cfg = &.{}, .want = null },
        .{ .what = "empty", .cfg = &.{"komira.bench_salt="}, .want = null },
        .{ .what = "blank", .cfg = &.{"komira.bench_salt=  "}, .want = null },
        .{ .what = "a value", .cfg = &.{"komira.bench_salt=run-1.b_2"}, .want = "\"KOMIRA_BENCH_SALT\": \"run-1.b_2\"" },
    };
    for (rows) |row| {
        const res = try c.run(&.{ "audit", "providers", FIXTURE }, .{ .cfg = row.cfg });
        const given = res.ok() and lib.text.contains(res.stdout, MARK);
        const has = lib.text.contains(res.stdout, "KOMIRA_BENCH_SALT\"");
        const ok = given and (if (row.want) |w| lib.text.contains(res.stdout, w) else !has);
        c.rep.check(ok, try std.fmt.allocPrint(c.a, "{s}: the environment of an action {s}", .{ row.what, if (row.want == null) "is as given, with no KOMIRA_BENCH_SALT" else "has KOMIRA_BENCH_SALT with the value" }), res.log);
    }
}

fn body(c: *lib.Ctx) !void {
    try c.refusals(&REFUSED);
    try envRows(c);
    const base = (try actions(c, "baseline", &.{})) orelse return;
    const empty = (try actions(c, "empty value", &.{"komira.bench_salt="})) orelse return;
    sameKeys(c, "an empty value", base, empty);
    const value = try std.fmt.allocPrint(c.a, "komira.bench_salt=x{d}", .{std.time.nanoTimestamp()});
    const salt = (try actions(c, "salted", &.{value})) orelse return;
    salted(c, base, salt);
    const again = (try actions(c, "salted again", &.{value})) orelse return;
    replay(c, salt, again);
}

pub fn main() u8 {
    return lib.main(body);
}
