//! served: the `served` verb of release_staged_verify (release_staged_verify.zig, beside this file).
//!
//!   release_staged_verify served --stage <beta|prod> --staged <dir> --out <dir> [--attempts <n>] [--delay <seconds>]
//!
//! It is what the jobs `beta-served-readmes` and `prod-served-readmes` of release.yml run after `beta-commit` and
//! `prod-commit`, when the group is visible: it downloads from that registry what it now serves for every member of
//! the plan, at the plan's version, checks it against the plan, and writes it in the staged-set layout, so the README
//! e2e then runs on the bytes and the README a user gets.
//!
//! `--staged` is the set `mopm-stage` kept (`plan.json` and each member's README; its `.conda` files are never read).
//! `--stage` names the registry, and with it three pinned URLs (`Pins`): its index (`index/config.json` on its API
//! host), the channel and the API root of version 2 that index must name. What it does, in order:
//!  1. reads `plan.json` with release_beta_fetch's plan reader (which refuses a plan it cannot check: every member an
//!     `upload` with its files and README, full names, plain paths, a lowercase sha256, nothing listed twice or
//!     colliding), and each member's README from `--staged`;
//!  2. fetches the index and refuses one whose `stage` is not `--stage`, whose `channel_url` is not the pinned
//!     channel, or whose `api_v2_url` is not the pinned API root, before anything else is fetched;
//!  3. fetches every file of the plan from `<channel><namespace>/<subdir>/<filename>` and compares its sha256 and size
//!     with the plan (release_beta_fetch's `checkFiles`: a file not served, another size, another hash);
//!  4. fetches `<api_v2_url>/packages/<namespace>/<name>/<version>` (`getVersion` of mopm's `spec/api/openapi-v2.yaml`)
//!     for every member and requires the answer to name the member and the plan's version, in the state `published`,
//!     with a `readme` that is the plan's README byte for byte (a version not served, no `readme`, a `readme` of
//!     another length or with another byte, the first differing byte named);
//!  5. reports every difference of 3 and 4 at once; a pass that found one is repeated `--attempts` times (default 3)
//!     with `--delay` seconds between (default 20: the channel's cache can lag a commit); it fails when the last pass
//!     does;
//!  6. only when every file and every README matched, writes `--out` (absent or empty, apart from a checked-in
//!     `BUCK`): `plan.json`, each README as the registry served it, and each file as it was downloaded and hashed,
//!     whole or not at all (release_beta_fetch's writer).
//! A package the plan lacks is not this check's to find: `expect` of `mopm-stage` holds the plan to every package
//! of the release, and the README e2e of a package the set lacks fails at its phase `staged`.
//!
//! It makes read-only GET requests, follows no redirect, and holds no credential.
const std = @import("std");
const rbf = @import("release_beta_fetch.zig");
const prod_add = @import("prod_add.zig");

const Allocator = std.mem.Allocator;

/// The largest answer of `getVersion` read: a README of at most 64 KiB, escaped in JSON, beside the version's
/// other fields.
pub const max_version_bytes: usize = 1024 * 1024;

/// What one registry must be: the stage its index names, where that index is, and the channel and API root of
/// version 2 it must name. Pinned, so a changed index cannot send the check elsewhere.
pub const Pins = struct {
    stage: []const u8,
    config_url: []const u8,
    channel: []const u8,
    api_v2: []const u8,
};

pub const beta = Pins{
    .stage = "beta",
    .config_url = "https://api.beta.mopm.dev/index/config.json",
    .channel = rbf.beta_channel,
    .api_v2 = "https://api.beta.mopm.dev/api/v2",
};

pub const prod = Pins{
    .stage = "prod",
    .config_url = "https://api.mopm.dev/index/config.json",
    .channel = prod_add.prod_channel,
    .api_v2 = "https://api.mopm.dev/api/v2",
};

/// The pins of the registry `stage`, or null when it is neither `beta` nor `prod`.
pub fn pinsOf(stage: []const u8) ?Pins {
    if (std.mem.eql(u8, stage, "beta")) return beta;
    if (std.mem.eql(u8, stage, "prod")) return prod;
    return null;
}

pub const Report = struct { members: usize, files: usize, readmes: usize };

fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) rbf.Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

fn describe(a: Allocator, url: []const u8, got: rbf.Got, max: usize) ![]const u8 {
    return switch (got) {
        .body => unreachable,
        .status => |s| std.fmt.allocPrint(a, "GET {s}: HTTP {d}", .{ url, s }),
        .too_large => std.fmt.allocPrint(a, "GET {s}: the body is larger than {d} bytes", .{ url, max }),
        .bad_url => std.fmt.allocPrint(a, "{s} is not a URL this tool fetches", .{url}),
        .transport => |e| std.fmt.allocPrint(a, "GET {s}: {s}", .{ url, @errorName(e) }),
    };
}

const Config = struct {
    stage: []const u8 = "",
    channel_url: []const u8 = "",
    api_v2_url: []const u8 = "",
};

/// Step 2 of the header: the index names the pinned stage, channel and API root.
pub fn checkIndex(a: Allocator, why: *[]const u8, fetcher: rbf.Fetcher, pins: Pins) rbf.Error!void {
    const got = fetcher.get(a, pins.config_url, rbf.max_config_bytes);
    const body = switch (got) {
        .body => |b| b,
        else => {
            why.* = try describe(a, pins.config_url, got, rbf.max_config_bytes);
            return error.Refused;
        },
    };
    const cfg = std.json.parseFromSliceLeaky(Config, a, body, .{ .ignore_unknown_fields = true }) catch |e|
        return refuse(a, why, "{s} does not parse: {s}", .{ pins.config_url, @errorName(e) });
    if (!std.mem.eql(u8, cfg.stage, pins.stage))
        return refuse(a, why, "{s} says stage '{s}', wanted '{s}'", .{ pins.config_url, cfg.stage, pins.stage });
    if (!std.mem.eql(u8, cfg.channel_url, pins.channel))
        return refuse(a, why, "{s}: channel_url '{s}' is not the pinned channel {s}", .{ pins.config_url, cfg.channel_url, pins.channel });
    if (!std.mem.eql(u8, cfg.api_v2_url, pins.api_v2))
        return refuse(a, why, "{s}: api_v2_url '{s}' is not the pinned API root {s}", .{ pins.config_url, cfg.api_v2_url, pins.api_v2 });
}

const Detail = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    state: []const u8 = "",
    readme: ?[]const u8 = null,
};

/// The index of the first byte where `x` and `y` differ (the shorter one's length when one is a prefix of the other).
pub fn firstDifference(x: []const u8, y: []const u8) usize {
    const n = @min(x.len, y.len);
    for (0..n) |i| if (x[i] != y[i]) return i;
    return n;
}

fn hexSha(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Step 4 of the header for one member: null when the registry serves the plan's README for it, else the difference.
pub fn readmeDifference(a: Allocator, fetcher: rbf.Fetcher, pins: Pins, m: rbf.Member, want: []const u8) !?[]const u8 {
    const label = try std.fmt.allocPrint(a, "{s} {s} {s}", .{ m.name, m.version, m.readme orelse "README" });
    const ns = rbf.namespaceOf(m.name) orelse return try std.fmt.allocPrint(a, "{s}: '{s}' is not a full name <namespace>/<name>", .{ label, m.name });
    const name = m.name[ns.len + 1 ..];
    const url = try std.fmt.allocPrint(a, "{s}/packages/{s}/{s}/{s}", .{ pins.api_v2, ns, name, m.version });
    const got = fetcher.get(a, url, max_version_bytes);
    const body = switch (got) {
        .body => |b| b,
        .status => |s| return try std.fmt.allocPrint(a, "{s}: GET {s}: HTTP {d} (the version is not served)", .{ label, url, s }),
        else => return try std.fmt.allocPrint(a, "{s}: {s}", .{ label, try describe(a, url, got, max_version_bytes) }),
    };
    const d = std.json.parseFromSliceLeaky(Detail, a, body, .{ .ignore_unknown_fields = true }) catch |e|
        return try std.fmt.allocPrint(a, "{s}: GET {s}: the answer does not parse: {s}", .{ label, url, @errorName(e) });
    if (!std.mem.eql(u8, d.name, m.name) or !std.mem.eql(u8, d.version, m.version))
        return try std.fmt.allocPrint(a, "{s}: GET {s} answers {s} {s}, not the plan's member", .{ label, url, d.name, d.version });
    if (!std.mem.eql(u8, d.state, "published"))
        return try std.fmt.allocPrint(a, "{s}: the registry serves the version in the state '{s}', not 'published'", .{ label, d.state });
    const got_readme = d.readme orelse return try std.fmt.allocPrint(a, "{s}: the registry serves no readme for the version", .{label});
    if (std.mem.eql(u8, got_readme, want)) return null;
    const got_hex = hexSha(got_readme);
    const want_hex = hexSha(want);
    return try std.fmt.allocPrint(a, "{s}: the served readme is not the plan's: {d} bytes (sha256 {s}), the plan's {d} bytes (sha256 {s}), first different at byte {d}", .{
        label, got_readme.len, &got_hex, want.len, &want_hex, firstDifference(got_readme, want),
    });
}

/// The bytes of one pass that matched, and one line per difference.
const Pass = struct {
    files: rbf.Outcome,
    readme_failures: []const []const u8,

    fn failed(self: Pass) bool {
        return self.files.failures.len != 0 or self.readme_failures.len != 0;
    }
};

/// One pass: the index, every file of the plan, every member's README.
fn servedOnce(a: Allocator, why: *[]const u8, plan: rbf.Plan, readmes: []const []const u8, fetcher: rbf.Fetcher, pins: Pins, log: *std.Io.Writer) !Pass {
    try checkIndex(a, why, fetcher, pins);
    const files = try rbf.checkFiles(a, plan, fetcher, pins.channel, log);
    var bad = std.ArrayList([]const u8).empty;
    for (plan.members, readmes) |m, want| {
        if (try readmeDifference(a, fetcher, pins, m, want)) |line| {
            try bad.append(a, line);
            continue;
        }
        const hex = hexSha(want);
        try log.print("ok readme {s} {d} {s} {s}\n", .{ &hex, want.len, m.name, m.version });
    }
    return .{ .files = files, .readme_failures = bad.items };
}

fn failureText(a: Allocator, pass: Pass, files: usize, members: usize, stage: []const u8) ![]const u8 {
    var all = std.Io.Writer.Allocating.init(a);
    try all.writer.print("the registry {s} does not serve what the plan staged: {d} of {d} file(s) and {d} of {d} readme(s) differ:", .{
        stage, pass.files.failed_files, files, pass.readme_failures.len, members,
    });
    for (pass.files.failures) |f| try all.writer.print("\n  {s}", .{f});
    for (pass.readme_failures) |f| try all.writer.print("\n  {s}", .{f});
    return all.written();
}

/// `served` (header). `backing` holds each pass's downloads, freed when the pass ends; `a` holds the plan, the
/// READMEs and `why`. `log` gets one `ok` line per file and README that matched.
pub fn served(a: Allocator, backing: Allocator, why: *[]const u8, staged: []const u8, fetcher: rbf.Fetcher, pins: Pins, out: []const u8, attempts: u32, delay_ms: u64, log: *std.Io.Writer) !Report {
    try rbf.outIsFree(why, a, out);
    const plan_text = try rbf.readFileIn(a, why, staged, "plan.json", rbf.max_plan_bytes);
    const plan = try rbf.parsePlan(a, why, plan_text);
    var readmes = std.ArrayList([]const u8).empty;
    for (plan.members) |m| try readmes.append(a, try rbf.readFileIn(a, why, staged, m.readme.?, rbf.max_readme_bytes));
    var files: usize = 0;
    for (plan.members) |m| files += m.files.len;
    var n: u32 = 0;
    while (true) {
        n += 1;
        var pass_arena = std.heap.ArenaAllocator.init(backing);
        defer pass_arena.deinit();
        const p = pass_arena.allocator();
        var pass_why: []const u8 = "";
        // A pass is refused (the index, before any file) or done; a done pass with a difference is a failure too.
        const pass: ?Pass = servedOnce(p, &pass_why, plan, readmes.items, fetcher, pins, log) catch |e| blk: {
            if (e != error.Refused) return e;
            why.* = try a.dupe(u8, pass_why);
            break :blk null;
        };
        if (pass) |done| {
            if (!done.failed()) {
                var entries = std.ArrayList(rbf.Entry).empty;
                try entries.append(p, .{ .rel = "plan.json", .data = plan_text });
                for (plan.members, readmes.items) |m, text| try entries.append(p, .{ .rel = m.readme.?, .data = text });
                for (done.files.checked) |c| try entries.append(p, .{ .rel = try std.fmt.allocPrint(p, "{s}/{s}", .{ c.file.subdir, c.file.filename }), .data = c.bytes });
                try rbf.writeSet(a, why, out, entries.items);
                return .{ .members = plan.members.len, .files = files, .readmes = plan.members.len };
            }
            why.* = try failureText(a, done, files, plan.members.len, pins.stage);
        }
        if (n >= attempts) return error.Refused;
        try log.print("attempt {d} of {d} failed, trying again: {s}\n", .{ n, attempts, why.* });
        try log.flush();
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
    }
}

pub const usage = "usage: release_staged_verify served --stage <beta|prod> --staged <dir> --out <dir> [--attempts <n>] [--delay <seconds>]\n";

fn parseNumber(s: []const u8, min: u64, max: u64) ?u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (v >= min and v <= max) v else null;
}

fn usageError(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !u8 {
    try err.print(fmt, args);
    try err.flush();
    return 2;
}

/// `served` on the command line, after the verb: its flags, each given once, then `served` with `fetcher`. Returns
/// the exit status: 0 when every file and README is the plan's, 1 with `SERVED FAILED: <why>` on `err` when one is
/// not, 2 on a usage error.
pub fn cliServed(a: Allocator, backing: Allocator, args: []const []const u8, fetcher: rbf.Fetcher, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var stage: ?[]const u8 = null;
    var staged: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var attempts_s: ?[]const u8 = null;
    var delay_s: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const slot: *?[]const u8 = if (std.mem.eql(u8, flag, "--stage")) &stage else if (std.mem.eql(u8, flag, "--staged")) &staged else if (std.mem.eql(u8, flag, "--out")) &out_dir else if (std.mem.eql(u8, flag, "--attempts")) &attempts_s else if (std.mem.eql(u8, flag, "--delay")) &delay_s else
            return usageError(err, "release_staged_verify: unknown argument {s}\n{s}", .{ flag, usage });
        i += 1;
        if (i >= args.len or slot.* != null) return usageError(err, "release_staged_verify: {s} needs one value, given once\n", .{flag});
        slot.* = args[i];
    }
    if (stage == null or staged == null or out_dir == null) return usageError(err, "{s}", .{usage});
    const pins = pinsOf(stage.?) orelse return usageError(err, "release_staged_verify: --stage is beta or prod, not {s}\n", .{stage.?});
    const attempts = parseNumber(attempts_s orelse "3", 1, 20) orelse return usageError(err, "release_staged_verify: --attempts is a number from 1 to 20\n", .{});
    const delay = parseNumber(delay_s orelse "20", 0, 300) orelse return usageError(err, "release_staged_verify: --delay is a number of seconds from 0 to 300\n", .{});
    var why: []const u8 = "";
    const rep = served(a, backing, &why, staged.?, fetcher, pins, out_dir.?, @intCast(attempts), delay * 1000, out) catch |e| {
        const msg = if (e == error.Refused) why else @errorName(e);
        try out.flush();
        try err.print("release_staged_verify: SERVED FAILED: {s}\n", .{msg});
        try err.flush();
        return 1;
    };
    try out.print("release_staged_verify: the registry {s} serves the {d} file(s) and {d} readme(s) of {d} member(s) as staged (sha256 and size; readmes byte for byte); written to {s}\n", .{ pins.stage, rep.files, rep.readmes, rep.members, out_dir.? });
    try out.flush();
    return 0;
}
