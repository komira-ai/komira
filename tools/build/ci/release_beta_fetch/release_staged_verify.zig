//! release_staged_verify: the two checks of the prod publish of release.yml that make no write to a registry.
//!
//!   release_staged_verify verify --staged <dir> --out <dir>
//!   release_staged_verify smoke  --staged <dir> --config-url <https url> [--attempts <n>] [--delay <seconds>]
//!
//! It shares the plan reader and the client of release_beta_fetch.zig (the file beside this one) and
//! holds no credential.
//!
//! `verify` is what the job `prod-test` runs between `prod-stage` and `prod-commit`. `--staged` is the
//! staged set `prod-stage` uploaded: `plan.json`, each member's README and each `.conda` file, with the
//! `state.json` and `report.json` that `mopm publish --staged --no-commit` wrote. The registry holds
//! exactly the bytes of that directory (it pinned each file's sha256 when the group was opened), and
//! will copy them when the group is committed. So `verify` reads `plan.json`, refuses a plan it cannot
//! check (release_beta_fetch's rules: every member an `upload` with its files and README, plain paths, a
//! lowercase sha256, a file below the cap, nothing listed twice or colliding), reads every file of the
//! plan from the directory and compares its sha256 and size with the plan, reporting every file that
//! differs (missing, another size, another hash). Only when every file matched does it write `--out`
//! (absent or empty, apart from a checked-in `BUCK`): `plan.json`, the READMEs and the files as they were
//! read and hashed, nothing else, so `state.json`, `report.json` and any file the plan does not name never
//! reach the README e2e, which then runs on exactly the bytes that were verified. `--out` is written whole
//! or not at all (release_beta_fetch's writer).
//!
//! `smoke` is what `prod-smoke` runs after `prod-commit`, when the group is visible. It reads the prod
//! index (`--config-url`, whose `stage` must be `prod` and whose `channel_url` must be exactly
//! `prod_channel`), downloads `<channel_url><subdir>/<filename>` for every file of the plan, as a user's
//! install would fetch them (no redirect followed, https only), and compares each file's sha256 and size
//! with the plan. A run that finds a difference is repeated `--attempts` times (default 3) with `--delay`
//! seconds between (default 20: the channel's cache can lag a commit by a minute); it fails when the last
//! attempt does. On failure it prints the yank command for the group `state.json` names, for a human to run:
//! it never sends one.
const std = @import("std");
const rbf = @import("release_beta_fetch.zig");

const Allocator = std.mem.Allocator;

/// The one channel the prod index may name, so a changed index cannot send the smoke check elsewhere.
pub const prod_channel = "https://conda.mopm.dev/";

pub const Report = struct { members: usize, files: usize };

fn hexSha(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Reads every file of the plan under `staged`; returns the bytes of those that match, and one line per
/// difference.
fn checkLocal(a: Allocator, plan: rbf.Plan, staged: []const u8, log: *std.Io.Writer) !rbf.Outcome {
    var ok = std.ArrayList(rbf.Checked).empty;
    var bad = std.ArrayList([]const u8).empty;
    var failed: usize = 0;
    for (plan.members) |m| for (m.files) |f| {
        const label = try std.fmt.allocPrint(a, "{s} {s} {s}/{s}", .{ m.name, m.version, f.subdir, f.filename });
        const path = try std.fs.path.join(a, &.{ staged, f.subdir, f.filename });
        const max: usize = std.math.cast(usize, f.size +| 1) orelse std.math.maxInt(usize);
        const before = bad.items.len;
        defer if (bad.items.len > before) {
            failed += 1;
        };
        const body = std.fs.cwd().readFileAlloc(a, path, max) catch |e| {
            if (e == error.FileTooBig) {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: the file is larger than the plan's {d} bytes", .{ label, f.size }));
            } else {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: cannot read {s}: {s}", .{ label, path, @errorName(e) }));
            }
            continue;
        };
        const hex = hexSha(body);
        const size_ok = body.len == f.size;
        const hash_ok = std.mem.eql(u8, &hex, f.sha256);
        if (!size_ok or !hash_ok) {
            if (!size_ok) try bad.append(a, try std.fmt.allocPrint(a, "{s}: size {d}, the plan says {d}", .{ label, body.len, f.size }));
            if (!hash_ok) try bad.append(a, try std.fmt.allocPrint(a, "{s}: sha256 {s}, the plan says {s}", .{ label, &hex, f.sha256 }));
            continue;
        }
        try log.print("ok {s} {d} {s}\n", .{ &hex, body.len, label });
        try ok.append(a, .{ .member = m.name, .file = f, .bytes = body });
    };
    return .{ .checked = ok.items, .failures = bad.items, .failed_files = failed };
}

fn failureText(a: Allocator, outcome: rbf.Outcome, files: usize, what: []const u8) ![]const u8 {
    var all = std.Io.Writer.Allocating.init(a);
    try all.writer.print("{d} of {d} file(s) are not what the plan staged{s}:", .{ outcome.failed_files, files, what });
    for (outcome.failures) |f| try all.writer.print("\n  {s}", .{f});
    return all.written();
}

fn countFiles(plan: rbf.Plan) usize {
    var n: usize = 0;
    for (plan.members) |m| n += m.files.len;
    return n;
}

/// `verify` (header). `log` gets one `ok` line per file that matched.
pub fn verify(a: Allocator, why: *[]const u8, staged: []const u8, out: []const u8, log: *std.Io.Writer) !Report {
    try rbf.outIsFree(why, a, out);
    const plan_text = try rbf.readFileIn(a, why, staged, "plan.json", rbf.max_plan_bytes);
    const plan = try rbf.parsePlan(a, why, plan_text);
    const files = countFiles(plan);
    const outcome = try checkLocal(a, plan, staged, log);
    if (outcome.failures.len != 0) {
        why.* = try failureText(a, outcome, files, " in the directory");
        return error.Refused;
    }
    var readmes = std.ArrayList([]const u8).empty;
    for (plan.members) |m| try readmes.append(a, try rbf.readFileIn(a, why, staged, m.readme.?, rbf.max_readme_bytes));
    var entries = std.ArrayList(rbf.Entry).empty;
    try entries.append(a, .{ .rel = "plan.json", .data = plan_text });
    for (plan.members, readmes.items) |m, text| try entries.append(a, .{ .rel = m.readme.?, .data = text });
    for (outcome.checked) |c| try entries.append(a, .{ .rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ c.file.subdir, c.file.filename }), .data = c.bytes });
    try rbf.writeSet(a, why, out, entries.items);
    return .{ .members = plan.members.len, .files = files };
}

/// One pass of `smoke`: the index, then every file of the plan from the channel it names.
fn smokeOnce(a: Allocator, why: *[]const u8, plan: rbf.Plan, fetcher: rbf.Fetcher, config_url: []const u8, log: *std.Io.Writer) !void {
    const channel = try rbf.channelOf(a, why, fetcher, config_url, "prod", prod_channel);
    const outcome = try rbf.checkFiles(a, plan, fetcher, channel, log);
    if (outcome.failures.len != 0) {
        why.* = try failureText(a, outcome, countFiles(plan), " (served by the channel)");
        return error.Refused;
    }
}

/// `smoke` (header): up to `attempts` passes, `delay_ms` apart; the error of the last one.
pub fn smoke(a: Allocator, why: *[]const u8, staged: []const u8, fetcher: rbf.Fetcher, config_url: []const u8, attempts: u32, delay_ms: u64, log: *std.Io.Writer) !Report {
    const plan_text = try rbf.readFileIn(a, why, staged, "plan.json", rbf.max_plan_bytes);
    const plan = try rbf.parsePlan(a, why, plan_text);
    var n: u32 = 0;
    while (true) {
        n += 1;
        smokeOnce(a, why, plan, fetcher, config_url, log) catch |e| {
            if (e != error.Refused or n >= attempts) return e;
            try log.print("attempt {d} of {d} failed, trying again: {s}\n", .{ n, attempts, why.* });
            try log.flush();
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            continue;
        };
        return .{ .members = plan.members.len, .files = countFiles(plan) };
    }
}

/// The command a human runs to take back the group `state.json` names, or null when it names none (or
/// something that is not a group id). The reason is a fixed text; nothing of the state is run.
pub fn yankCommand(a: Allocator, state_text: []const u8, stage: []const u8) !?[]const u8 {
    const State = struct { group_id: []const u8 = "" };
    const st = std.json.parseFromSliceLeaky(State, a, state_text, .{ .ignore_unknown_fields = true }) catch return null;
    if (st.group_id.len == 0 or st.group_id.len > 128) return null;
    for (st.group_id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return null;
    return try std.fmt.allocPrint(a, "mopm yank --group {s} --registry {s} --reason \"the release smoke check failed\"", .{ st.group_id, stage });
}

const usage =
    \\usage: release_staged_verify verify --staged <dir> --out <dir>
    \\       release_staged_verify smoke --staged <dir> --config-url <https url> [--attempts <n>] [--delay <seconds>]
    \\
;

fn parseNumber(s: []const u8, max: u64) ?u64 {
    const v = std.fmt.parseInt(u64, s, 10) catch return null;
    return if (v <= max) v else null;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ebuf: [1024]u8 = undefined;
    var err = std.fs.File.stderr().writer(&ebuf);
    var obuf: [1024]u8 = undefined;
    var out = std.fs.File.stdout().writer(&obuf);
    const args = try std.process.argsAlloc(a);
    if (args.len < 2 or !(std.mem.eql(u8, args[1], "verify") or std.mem.eql(u8, args[1], "smoke"))) {
        try err.interface.writeAll(usage);
        try err.interface.flush();
        return 2;
    }
    const is_verify = std.mem.eql(u8, args[1], "verify");
    var staged: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var config_url: ?[]const u8 = null;
    var attempts_s: ?[]const u8 = null;
    var delay_s: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const slot: *?[]const u8 = if (std.mem.eql(u8, flag, "--staged")) &staged else if (is_verify and std.mem.eql(u8, flag, "--out")) &out_dir else if (!is_verify and std.mem.eql(u8, flag, "--config-url")) &config_url else if (!is_verify and std.mem.eql(u8, flag, "--attempts")) &attempts_s else if (!is_verify and std.mem.eql(u8, flag, "--delay")) &delay_s else {
            try err.interface.print("release_staged_verify: unknown argument {s}\n{s}", .{ flag, usage });
            try err.interface.flush();
            return 2;
        };
        i += 1;
        if (i >= args.len or slot.* != null) {
            try err.interface.print("release_staged_verify: {s} needs one value, given once\n", .{flag});
            try err.interface.flush();
            return 2;
        }
        slot.* = args[i];
    }
    if (staged == null or (is_verify and out_dir == null) or (!is_verify and config_url == null)) {
        try err.interface.writeAll(usage);
        try err.interface.flush();
        return 2;
    }
    var why: []const u8 = "";
    if (is_verify) {
        const rep = verify(a, &why, staged.?, out_dir.?, &out.interface) catch |e| {
            const msg = if (e == error.Refused) why else @errorName(e);
            try out.interface.flush();
            try err.interface.print("release_staged_verify: FAILED: {s}\n", .{msg});
            try err.interface.flush();
            return 1;
        };
        try out.interface.print("release_staged_verify: {d} file(s) of {d} member(s) are the staged bytes (sha256 and size); written to {s}\n", .{ rep.files, rep.members, out_dir.? });
        try out.interface.flush();
        return 0;
    }
    const attempts = parseNumber(attempts_s orelse "3", 20) orelse {
        try err.interface.writeAll("release_staged_verify: --attempts is a number from 1 to 20\n");
        try err.interface.flush();
        return 2;
    };
    const delay = parseNumber(delay_s orelse "20", 300) orelse {
        try err.interface.writeAll("release_staged_verify: --delay is a number of seconds from 0 to 300\n");
        try err.interface.flush();
        return 2;
    };
    if (attempts == 0) {
        try err.interface.writeAll("release_staged_verify: --attempts is a number from 1 to 20\n");
        try err.interface.flush();
        return 2;
    }
    var http = rbf.Http{};
    const rep = smoke(a, &why, staged.?, http.fetcher(), config_url.?, @intCast(attempts), delay * 1000, &out.interface) catch |e| {
        const msg = if (e == error.Refused) why else @errorName(e);
        try out.interface.flush();
        try err.interface.print("release_staged_verify: SMOKE FAILED: {s}\n", .{msg});
        const state_text = rbf.readFileIn(a, &why, staged.?, "state.json", 1 << 20) catch "";
        if (try yankCommand(a, state_text, "prod")) |cmd| {
            try err.interface.print("The published group may be wrong. A human decides; to take it back, run:\n  {s}\n", .{cmd});
        } else {
            try err.interface.writeAll("state.json names no group: nothing here says what to yank.\n");
        }
        try err.interface.flush();
        return 1;
    };
    try out.interface.print("release_staged_verify: {d} file(s) of {d} member(s) are served by {s} as staged (sha256 and size)\n", .{ rep.files, rep.members, prod_channel });
    try out.interface.flush();
    return 0;
}
