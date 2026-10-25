//! release_beta_fetch: downloads what a registry published and proves it is what was staged.
//!
//!   release_beta_fetch --staged <dir> --config-url <url> --stage <name> --out <dir>
//!
//! `--staged` is a staged set as `mopm stage` wrote it (spec/staged-set.md of mopm): `plan.json`
//! and each member's README. Its `.conda` files, if the directory holds them, are never read: the
//! bytes under test are the ones the registry serves. release.yml's `mopm-e2e-beta` job runs this
//! after `mopm-publish-beta`, against the staged set `mopm-stage-beta` uploaded.
//!
//! What it does, in order:
//!  1. reads `plan.json` and refuses a plan it cannot check: no member, a member that is not an
//!     `upload` (its bytes are not in the set), a member without a file or a README, a file or
//!     README path that leaves its directory, a malformed sha256, a file named twice;
//!  2. fetches `--config-url` (the registry's `index/config.json`) over https, requires its
//!     `stage` to be `--stage` (so a beta check cannot read prod by a wrong URL) and takes its
//!     `channel_url`, which must be https too;
//!  3. fetches `<channel_url><subdir>/<filename>` for every file of the plan, with no redirect
//!     followed, and compares the sha256 and the size with the plan; every file is checked and
//!     every mismatch (a missing file, another size, another hash) is reported;
//!  4. only when every file matched, writes `--out`: `plan.json` as it was, each README, and the
//!     downloaded `.conda` files at `<subdir>/<filename>`: a staged set made of the published
//!     bytes. Nothing is written when anything failed. `--out` must be absent or empty.
//!
//! It makes read-only GET requests and holds no credential.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_config_bytes: usize = 64 * 1024;
const max_plan_bytes: usize = 4 * 1024 * 1024;
const max_readme_bytes: usize = 4 * 1024 * 1024;

pub const File = struct {
    subdir: []const u8,
    filename: []const u8,
    sha256: []const u8,
    size: u64,
};

pub const Member = struct {
    name: []const u8,
    version: []const u8,
    action: []const u8,
    files: []const File = &.{},
    readme: ?[]const u8 = null,
};

pub const Plan = struct {
    members: []const Member = &.{},
};

/// What a GET came to.
pub const Got = union(enum) {
    body: []u8,
    /// A status other than 200 (a redirect is one: none is followed).
    status: u16,
    /// The body is longer than the caller allowed.
    too_large,
    /// The URL is not one this tool fetches (https only; plain http only to loopback in tests).
    bad_url,
    /// The connection or the body failed.
    transport: anyerror,
};

pub const Fetcher = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, a: Allocator, url: []const u8, max: usize) Got,

    pub fn get(self: Fetcher, a: Allocator, url: []const u8, max: usize) Got {
        return self.getFn(self.ctx, a, url, max);
    }
};

pub const Error = error{ Refused, OutOfMemory };

fn refuse(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = try std.fmt.allocPrint(a, fmt, args);
    return error.Refused;
}

/// One path segment of a file name or directory: no separator, not `.` or `..`, no control byte.
fn safeSegment(s: []const u8) bool {
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (c == '/' or c == '\\' or c < 0x20 or c == 0x7f) return false;
    return true;
}

/// A relative path of safe segments (`name/README.md`).
fn safeRelative(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| if (!safeSegment(seg)) return false;
    return true;
}

fn lowerHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Parses `plan.json` and refuses a plan that cannot be checked (see the header, point 1).
pub fn parsePlan(a: Allocator, why: *[]const u8, text: []const u8) Error!Plan {
    const plan = std.json.parseFromSliceLeaky(Plan, a, text, .{ .ignore_unknown_fields = true }) catch |e|
        return refuse(a, why, "plan.json does not parse: {s}", .{@errorName(e)});
    if (plan.members.len == 0) return refuse(a, why, "plan.json has no member: there is nothing to check", .{});
    for (plan.members, 0..) |m, i| {
        if (!safeSegment(m.name)) return refuse(a, why, "member {d}: name '{s}' is not a plain name", .{ i, m.name });
        if (!std.mem.eql(u8, m.action, "upload"))
            return refuse(a, why, "member {s}: action is '{s}', not 'upload': its bytes are not in the set, so what the registry serves cannot be checked against it", .{ m.name, m.action });
        if (m.version.len == 0) return refuse(a, why, "member {s}: no version", .{m.name});
        if (m.files.len == 0) return refuse(a, why, "member {s}: no file", .{m.name});
        const readme = m.readme orelse return refuse(a, why, "member {s}: no readme", .{m.name});
        if (!safeRelative(readme)) return refuse(a, why, "member {s}: readme path '{s}' leaves the set", .{ m.name, readme });
        for (m.files, 0..) |f, k| {
            if (!safeSegment(f.subdir) or !safeSegment(f.filename))
                return refuse(a, why, "member {s}: file {s}/{s} is not a plain subdir and file name", .{ m.name, f.subdir, f.filename });
            if (!lowerHex64(f.sha256)) return refuse(a, why, "member {s}: {s} has sha256 '{s}', not 64 lowercase hex digits", .{ m.name, f.filename, f.sha256 });
            for (m.files[0..k]) |o| {
                if (std.mem.eql(u8, o.subdir, f.subdir) and std.mem.eql(u8, o.filename, f.filename))
                    return refuse(a, why, "member {s}: {s}/{s} is listed twice", .{ m.name, f.subdir, f.filename });
            }
        }
        for (plan.members[0..i]) |o| {
            if (std.mem.eql(u8, o.name, m.name)) return refuse(a, why, "member {s} is listed twice", .{m.name});
            for (o.files) |of| for (m.files) |f| {
                if (std.mem.eql(u8, of.subdir, f.subdir) and std.mem.eql(u8, of.filename, f.filename))
                    return refuse(a, why, "{s}/{s} is a file of {s} and of {s}", .{ f.subdir, f.filename, o.name, m.name });
            };
        }
    }
    return plan;
}

/// A `https://` URL (or, when `allow_loopback`, `http://127.0.0.1`) with a host, no userinfo.
pub fn urlAllowed(url: []const u8, allow_loopback: bool) bool {
    const https = std.mem.startsWith(u8, url, "https://");
    const http = std.mem.startsWith(u8, url, "http://");
    if (!https and !http) return false;
    const rest = url[if (https) 8 else 7..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return false;
    if (https) return true;
    if (!allow_loopback) return false;
    const host_end = std.mem.lastIndexOfScalar(u8, authority, ':') orelse authority.len;
    return std.mem.eql(u8, authority[0..host_end], "127.0.0.1");
}

const Config = struct {
    channel_url: []const u8 = "",
    stage: []const u8 = "",
};

/// The channel the registry's `index/config.json` names, as a URL ending in `/`.
pub fn channelOf(a: Allocator, why: *[]const u8, fetcher: Fetcher, config_url: []const u8, stage: []const u8) Error![]const u8 {
    const body = switch (fetcher.get(a, config_url, max_config_bytes)) {
        .body => |b| b,
        .status => |s| return refuse(a, why, "GET {s}: HTTP {d}", .{ config_url, s }),
        .too_large => return refuse(a, why, "GET {s}: the body is larger than {d} bytes", .{ config_url, max_config_bytes }),
        .bad_url => return refuse(a, why, "{s} is not an https URL", .{config_url}),
        .transport => |e| return refuse(a, why, "GET {s}: {s}", .{ config_url, @errorName(e) }),
    };
    const cfg = std.json.parseFromSliceLeaky(Config, a, body, .{ .ignore_unknown_fields = true }) catch |e|
        return refuse(a, why, "{s} does not parse: {s}", .{ config_url, @errorName(e) });
    if (!std.mem.eql(u8, cfg.stage, stage))
        return refuse(a, why, "{s} says stage '{s}', wanted '{s}'", .{ config_url, cfg.stage, stage });
    // The scheme is judged again, with the real policy, by the client that fetches from it.
    if (!urlAllowed(cfg.channel_url, true))
        return refuse(a, why, "{s}: channel_url '{s}' is not an https URL", .{ config_url, cfg.channel_url });
    if (std.mem.endsWith(u8, cfg.channel_url, "/")) return cfg.channel_url;
    return std.fmt.allocPrint(a, "{s}/", .{cfg.channel_url});
}

/// One downloaded file that matched its plan entry.
pub const Checked = struct { member: []const u8, file: File, bytes: []const u8 };

pub const Outcome = struct {
    checked: []const Checked,
    /// One line per file that did not match; empty when every file did.
    failures: []const []const u8,
};

/// Fetches every file of `plan` from `channel` and compares each with its entry (header, point 3).
pub fn checkFiles(a: Allocator, plan: Plan, fetcher: Fetcher, channel: []const u8, log: *std.Io.Writer) !Outcome {
    var ok = std.ArrayList(Checked).empty;
    var bad = std.ArrayList([]const u8).empty;
    for (plan.members) |m| for (m.files) |f| {
        const url = try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ channel, f.subdir, f.filename });
        const label = try std.fmt.allocPrint(a, "{s} {s} {s}/{s}", .{ m.name, m.version, f.subdir, f.filename });
        const max: usize = std.math.cast(usize, f.size +| 1) orelse std.math.maxInt(usize);
        const body = switch (fetcher.get(a, url, max)) {
            .body => |b| b,
            .status => |s| {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: GET {s}: HTTP {d} (not published)", .{ label, url, s }));
                continue;
            },
            .too_large => {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: the registry serves more than the plan's {d} bytes", .{ label, f.size }));
                continue;
            },
            .bad_url => {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: {s} is not a URL this tool fetches", .{ label, url }));
                continue;
            },
            .transport => |e| {
                try bad.append(a, try std.fmt.allocPrint(a, "{s}: GET {s}: {s}", .{ label, url, @errorName(e) }));
                continue;
            },
        };
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
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
    return .{ .checked = ok.items, .failures = bad.items };
}

fn readFileIn(a: Allocator, why: *[]const u8, dir: []const u8, rel: []const u8, max: usize) Error![]u8 {
    const path = try std.fs.path.join(a, &.{ dir, rel });
    return std.fs.cwd().readFileAlloc(a, path, max) catch |e|
        return refuse(a, why, "cannot read {s}: {s}", .{ path, @errorName(e) });
}

fn writeIn(a: Allocator, out: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ out, rel });
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

/// `out` is a directory that does not exist or is empty.
fn outIsFree(why: *[]const u8, a: Allocator, out: []const u8) Error!void {
    var dir = std.fs.cwd().openDir(out, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return refuse(a, why, "cannot open --out {s}: {s}", .{ out, @errorName(e) }),
    };
    defer dir.close();
    var it = dir.iterate();
    const first = it.next() catch |e| return refuse(a, why, "cannot list --out {s}: {s}", .{ out, @errorName(e) });
    if (first != null) return refuse(a, why, "--out {s} is not empty", .{out});
}

pub const Report = struct { members: usize, files: usize, channel: []const u8 };

/// The whole job (header, points 1 to 4). `failures` is set when files did not match.
pub fn run(a: Allocator, why: *[]const u8, staged: []const u8, fetcher: Fetcher, config_url: []const u8, stage: []const u8, out: []const u8, log: *std.Io.Writer) !Report {
    try outIsFree(why, a, out);
    const plan_text = try readFileIn(a, why, staged, "plan.json", max_plan_bytes);
    const plan = try parsePlan(a, why, plan_text);
    var files: usize = 0;
    for (plan.members) |m| files += m.files.len;
    const channel = try channelOf(a, why, fetcher, config_url, stage);
    const outcome = try checkFiles(a, plan, fetcher, channel, log);
    if (outcome.failures.len != 0) {
        var all = std.Io.Writer.Allocating.init(a);
        try all.writer.print("{d} of {d} file(s) are not what the plan staged:", .{ outcome.failures.len, files });
        for (outcome.failures) |f| try all.writer.print("\n  {s}", .{f});
        why.* = all.written();
        return error.Refused;
    }
    var readmes = std.ArrayList([]const u8).empty;
    for (plan.members) |m| try readmes.append(a, try readFileIn(a, why, staged, m.readme.?, max_readme_bytes));
    try writeIn(a, out, "plan.json", plan_text);
    for (plan.members, readmes.items) |m, text| try writeIn(a, out, m.readme.?, text);
    for (outcome.checked) |c| try writeIn(a, out, try std.fmt.allocPrint(a, "{s}/{s}", .{ c.file.subdir, c.file.filename }), c.bytes);
    return .{ .members = plan.members.len, .files = files, .channel = channel };
}

/// The real client: https GETs, no redirect followed, a body bounded by the caller.
pub const Http = struct {
    allow_loopback: bool = false,

    pub fn fetcher(self: *Http) Fetcher {
        return .{ .ctx = self, .getFn = get };
    }

    fn get(ctx: *anyopaque, a: Allocator, url: []const u8, max: usize) Got {
        const self: *Http = @ptrCast(@alignCast(ctx));
        if (!urlAllowed(url, self.allow_loopback)) return .bad_url;
        const uri = std.Uri.parse(url) catch return .bad_url;
        var client = std.http.Client{ .allocator = a, .read_buffer_size = 16 * 1024 };
        defer client.deinit();
        var req = client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "release_beta_fetch" },
            },
        }) catch |e| return .{ .transport = e };
        defer req.deinit();
        req.sendBodiless() catch |e| return .{ .transport = e };
        var response = req.receiveHead(&.{}) catch |e| return .{ .transport = e };
        if (response.head.status != .ok) return .{ .status = @intFromEnum(response.head.status) };
        const claimed = response.head.content_length;
        if (claimed) |c| if (c > max) return .too_large;
        var transfer: [64]u8 = undefined;
        const body = response.reader(&transfer);
        var list = std.ArrayList(u8).empty;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = body.readSliceShort(&buf) catch {
                return .{ .transport = response.bodyErr() orelse error.ReadFailed };
            };
            if (list.items.len + n > max) return .too_large;
            list.appendSlice(a, buf[0..n]) catch |e| return .{ .transport = e };
            if (n < buf.len) break;
        }
        if (claimed) |c| if (list.items.len != c) return .{ .transport = error.TruncatedBody };
        return .{ .body = list.items };
    }
};

const usage = "usage: release_beta_fetch --staged <dir> --config-url <https url> --stage <name> --out <dir>\n";

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
    var staged: ?[]const u8 = null;
    var config_url: ?[]const u8 = null;
    var stage: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const slot: *?[]const u8 = if (std.mem.eql(u8, flag, "--staged")) &staged else if (std.mem.eql(u8, flag, "--config-url")) &config_url else if (std.mem.eql(u8, flag, "--stage")) &stage else if (std.mem.eql(u8, flag, "--out")) &out_dir else {
            try err.interface.print("release_beta_fetch: unknown argument {s}\n{s}", .{ flag, usage });
            try err.interface.flush();
            return 2;
        };
        i += 1;
        if (i >= args.len or slot.* != null) {
            try err.interface.print("release_beta_fetch: {s} needs one value, given once\n", .{flag});
            try err.interface.flush();
            return 2;
        }
        slot.* = args[i];
    }
    if (staged == null or config_url == null or stage == null or out_dir == null) {
        try err.interface.writeAll(usage);
        try err.interface.flush();
        return 2;
    }
    var http = Http{};
    var why: []const u8 = "";
    const rep = run(a, &why, staged.?, http.fetcher(), config_url.?, stage.?, out_dir.?, &out.interface) catch |e| {
        const msg = if (e == error.Refused) why else @errorName(e);
        try out.interface.flush();
        try err.interface.print("release_beta_fetch: FAILED: {s}\n", .{msg});
        try err.interface.flush();
        return 1;
    };
    try out.interface.print("release_beta_fetch: {d} file(s) of {d} member(s) from {s} are the staged bytes (sha256 and size); written to {s}\n", .{ rep.files, rep.members, rep.channel, out_dir.? });
    try out.interface.flush();
    return 0;
}
