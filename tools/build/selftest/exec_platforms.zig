//! exec_platforms: where targets execute, and what decides it.
//!
//! 1. Execution platform resolution (`buck2 audit
//!    execution-platform-resolution`): the Mojo compiles, gated tests and
//!    run checks, the toolchain unpack and copy targets, third_party_srcs'
//!    generation, drift test and fixture archive, and the C/C++ libraries
//!    and the Mojo targets that link them, each resolve to the one linux
//!    execution platform, `linux-x86_64`. The table is compared whole: a
//!    target missing from the answer, failing to configure, or resolving
//!    elsewhere is red. Catches a second platform registered first.
//! 2. The default platform's own key decides where actions run: with only
//!    the host platform's `[komira_re]` key set, the one execution platform
//!    is remote; with only another platform's key set, it is the one local
//!    platform and nothing fails. Catches a platform reading another
//!    platform's key.
//! 3. `[komira_re] linux_arm64_properties` registers the linux-arm64
//!    execution platform beside linux-x86_64's, both remote; naming the same
//!    property set as linux x86_64's is refused, so an arm64 action never
//!    matches an x86_64 worker. Catches the arm64 key read as nothing, or an
//!    arm64 platform that shares the x86_64 workers.
//! 4. The recursion guard's key moves no configuration: under
//!    `-c komira_selftest.inner=true` (every inner command passes it),
//!    `//tools/build/examples:hello` is configured for linux-x86_64 with the
//!    hash the platform table pins (`golden_config_hash`).
//! 5. third_party_srcs' generator runs where its action runs: under a
//!    darwin-arm64 target platform, the `:gen` that `aws_lc_mini_gen` takes is
//!    configured for linux-x86_64, the platform of the action that executes
//!    it, and not for darwin-arm64. Catches the generator taken as a plain
//!    dependency, so a Mach-O binary is handed to a Linux worker.
const std = @import("std");
const lib = @import("lib/lib.zig");

const LINUX = "komira//tools/build/platforms:linux-x86_64";
const DARWIN = "komira//tools/build/platforms:darwin-arm64";
const GEN = "komira//tools/build/third_party_srcs:gen";

/// target -> the execution platform it must resolve to.
const RESOLUTION = [_][2][]const u8{
    // Mojo, toolchain and third_party_srcs targets.
    .{ "komira//tools/build/examples:hello", LINUX },
    .{ "komira//tools/build/examples:hellopkg", LINUX },
    .{ "komira//tools/build/examples/libgate_ok:libgate_ok", LINUX },
    .{ "komira//tools/build/examples:test_hellopkg", LINUX },
    .{ "komira//tools/build/toolchains:zig", LINUX },
    .{ "komira//tools/build/toolchains:conda_unpack", LINUX },
    .{ "komira//tools/build/toolchains:mojo_compiler", LINUX },
    .{ "komira//tools/build/toolchains:mojo_runtime", LINUX },
    .{ "komira//tools/build/third_party_srcs:aws-lc-mini.tar.gz", LINUX },
    .{ "komira//tools/build/third_party_srcs:aws_lc_mini_gen", LINUX },
    .{ "komira//tools/build/third_party_srcs:aws_lc_mini_drift", LINUX },
    .{ "komira//third_party/aws-lc:srcs_gen", LINUX },
    // C and C++ libraries, and the Mojo targets depending on them.
    .{ "komira//tools/build/examples/cshim:add", LINUX },
    .{ "komira//third_party/snappy:snappy", LINUX },
    .{ "komira//third_party/snappy:src", LINUX },
    .{ "komira//tools/build/examples/cshim:cadd", LINUX },
    .{ "komira//tools/build/examples/snappy:test_snappy", LINUX },
};

const EP = "komira//tools/build/platforms/default:default";

/// `-c komira.execution=auto` and both keys stated, so a user buckconfig
/// forcing a mode, or an inherited key, cannot decide this. The host list is
/// read only for a macOS property set.
const HOST_ONLY = [_][]const u8{
    "komira.execution=auto",
    "komira_re.darwin_macos_hosts=26.5-0123456789abcdef",
    "komira_re.linux_x86_64_properties=pool=host-check",
    "komira_re.darwin_arm64_properties=",
};
const BOTH_LINUX = [_][]const u8{
    "komira.execution=auto",
    "komira_re.darwin_macos_hosts=26.5-0123456789abcdef",
    "komira_re.linux_x86_64_properties=pool=host-check",
    "komira_re.linux_arm64_properties=pool=arm-check",
    "komira_re.darwin_arm64_properties=",
};
const OTHER_ONLY = [_][]const u8{
    "komira.execution=auto",
    "komira_re.darwin_macos_hosts=26.5-0123456789abcdef",
    "komira_re.linux_x86_64_properties=",
    "komira_re.darwin_arm64_properties=pool=other-check",
};

const SAME_SET = [_]lib.Row{
    .{
        .name = "arm64_set_equals_x86_64_set",
        .target = EP,
        .text = "`linux_arm64` must name arm64 workers, but it equals the linux property set",
        .cfg = &.{
            "komira.execution=remote",
            "komira_re.linux_x86_64_properties=pool=host-check",
            "komira_re.linux_arm64_properties=pool=host-check",
            "komira_re.darwin_arm64_properties=",
        },
    },
};

fn resolution(c: *lib.Ctx) !void {
    var words = std.ArrayList([]const u8).empty;
    try words.appendSlice(c.a, &.{ "audit", "execution-platform-resolution" });
    var want = std.ArrayList([]const u8).empty;
    for (RESOLUTION) |row| {
        try words.append(c.a, row[0]);
        try want.append(c.a, try std.fmt.allocPrint(c.a, "{s} {s}", .{ row[0], row[1] }));
    }
    const res = try c.run(words.items, .{});
    if (!res.ok()) {
        c.fail("resolution: the audit failed (see {s})", .{res.log});
        return;
    }
    const got = try lib.parse.resolution(c.a, res.stdout);
    lib.text.sort(got);
    lib.text.sort(want.items);
    if (lib.text.eqlLists(want.items, got)) {
        c.pass("resolution: all {d} Mojo, toolchain, third_party_srcs and C/C++ targets resolve to {s}", .{ want.items.len, LINUX });
        return;
    }
    var diff = std.ArrayList(u8).empty;
    for (want.items) |w| {
        var found = false;
        for (got) |g| found = found or std.mem.eql(u8, g, w);
        if (!found) try diff.writer(c.a).print("\n  want {s}", .{w});
    }
    for (got) |g| {
        var found = false;
        for (want.items) |w| found = found or std.mem.eql(u8, g, w);
        if (!found) try diff.writer(c.a).print("\n  got  {s}", .{g});
    }
    c.fail("resolution differs (see {s}):{s}", .{ res.log, diff.items });
}

fn keyLeg(c: *lib.Ctx, what: []const u8, cfg: []const []const u8, want_remote: usize, want_local: usize) !void {
    const res = try c.run(&.{ "audit", "providers", EP }, .{ .cfg = cfg });
    const e = lib.parse.executors(res.stdout);
    if (res.ok() and e.platforms == 1 and e.remote == want_remote and e.local == want_local) {
        c.pass("{s}", .{what});
    } else {
        c.fail("{s}: exit {?d}, {d} platform(s), {d} remote, {d} local (see {s})", .{ what, res.exit, e.platforms, e.remote, e.local, res.log });
    }
}

fn bothLinux(c: *lib.Ctx) !void {
    const res = try c.run(&.{ "audit", "providers", EP }, .{ .cfg = &BOTH_LINUX });
    const e = lib.parse.executors(res.stdout);
    if (res.ok() and e.platforms == 2 and e.remote == 2 and e.local == 0) {
        c.pass("execution: with [komira_re] linux_x86_64_properties and linux_arm64_properties set, the platforms are linux-x86_64 and linux-arm64, both remote", .{});
    } else {
        c.fail("execution: with both linux keys set: exit {?d}, {d} platform(s), {d} remote, {d} local (see {s})", .{ res.exit, e.platforms, e.remote, e.local, res.log });
    }
}

fn innerKeyHash(c: *lib.Ctx) !void {
    const table = std.fs.cwd().readFileAlloc(c.a, "tools/build/platforms/table.bzl", 1 << 22) catch {
        c.fail("inner key: cannot read tools/build/platforms/table.bzl", .{});
        return;
    };
    const hash = lib.parse.goldenHash(table, "linux-x86_64") orelse {
        c.fail("inner key: table.bzl has no golden_config_hash for linux-x86_64", .{});
        return;
    };
    const res = try c.run(&.{ "cquery", "//tools/build/examples:hello" }, .{});
    const want = try std.fmt.allocPrint(c.a, "{s}#{s})", .{ LINUX, hash });
    if (res.ok() and lib.text.contains(res.stdout, want)) {
        c.pass("inner key: under -c {s}, hello is configured for {s}#{s}, the pinned hash", .{ lib.runner.INNER_KEY, LINUX, hash });
    } else {
        c.fail("inner key: under -c {s}, hello is not configured for {s}#{s} (see {s})", .{ lib.runner.INNER_KEY, LINUX, hash, res.log });
    }
}

/// Under a darwin-arm64 target platform, the line of `:gen` in the first-level
/// dependencies of `aws_lc_mini_gen` is configured for linux-x86_64. The
/// line is matched on its own: the generator's runner, `third_party_act`, is
/// a linux-x86_64 line whatever `:gen` is, so the whole output would not tell.
fn genExecConfig(c: *lib.Ctx) !void {
    const res = try c.run(&.{ "cquery", "deps(komira//tools/build/third_party_srcs:aws_lc_mini_gen, 1)" }, .{ .target_platforms = DARWIN });
    if (!res.ok()) {
        c.fail("third_party_srcs: the cquery of aws_lc_mini_gen's dependencies under {s} failed (see {s})", .{ DARWIN, res.log });
        return;
    }
    const prefix = GEN ++ " (";
    var seen: usize = 0;
    var wrong: usize = 0;
    for (try lib.text.lines(c.a, res.stdout)) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        seen += 1;
        if (!lib.parse.configuredFor(line, LINUX) or lib.parse.configuredFor(line, DARWIN)) wrong += 1;
    }
    if (seen == 1 and wrong == 0) {
        c.pass("third_party_srcs: under {s}, :gen is configured for {s}, where the action that runs it executes", .{ DARWIN, LINUX });
    } else {
        c.fail("third_party_srcs: under {s}, {d} line(s) of :gen, {d} not configured for {s} alone (see {s})", .{ DARWIN, seen, wrong, LINUX, res.log });
    }
}

fn body(c: *lib.Ctx) !void {
    try resolution(c);
    try genExecConfig(c);
    try innerKeyHash(c);
    try keyLeg(c, "execution: with only [komira_re] linux_x86_64_properties set, the one execution platform is remote", &HOST_ONLY, 1, 0);
    try keyLeg(c, "execution: with only [komira_re] darwin_arm64_properties set (another platform's key), the one execution platform is local and nothing fails", &OTHER_ONLY, 0, 1);
    try bothLinux(c);
    try c.refusals(&SAME_SET);
}

pub fn main() u8 {
    return lib.main(body);
}

