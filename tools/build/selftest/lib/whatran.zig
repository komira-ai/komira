//! `buck2 log what-ran` (tabulated) read as actions and their executors.
//!
//! One action per line: `<reason>\t<identity>\t<executor>\t<reproducer>`.
//! An executor that starts `re(` or `cache` ran on the farm or was a farm
//! cache hit; anything else (`local`, `worker`) ran on the client.
const std = @import("std");

pub const Verdict = struct {
    actions: usize = 0,
    /// The first action that did not run on the farm, if any (its identity).
    first_local: ?[]const u8 = null,
    locals: usize = 0,
};

pub fn remoteExecutor(executor: []const u8) bool {
    return std.mem.startsWith(u8, executor, "re(") or std.mem.eql(u8, executor, "re") or
        std.mem.startsWith(u8, executor, "cache");
}

pub fn read(text: []const u8) Verdict {
    var v = Verdict{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue;
        const identity = fields.next() orelse continue;
        const executor = fields.next() orelse continue;
        v.actions += 1;
        if (!remoteExecutor(executor)) {
            v.locals += 1;
            if (v.first_local == null) v.first_local = identity;
        }
    }
    return v;
}

/// What a build that re-ran the tests of the targets `-c komira.rerun` named
/// shows in what-ran, read against those targets (labels, without the
/// configuration).
pub const Rerun = struct {
    actions: usize = 0,
    /// Actions of a named target that executed on the farm (not a cache hit).
    ran: usize = 0,
    /// Actions of a target not named: their keys changed too.
    others: usize = 0,
    first_other: ?[]const u8 = null,
    /// Actions of a named target that were a cache hit or did not run on the farm.
    stale: usize = 0,
    first_stale: ?[]const u8 = null,

    /// Only named targets' actions changed key, each executed on the farm.
    pub fn ok(r: Rerun) bool {
        return r.ran > 0 and r.others == 0 and r.stale == 0;
    }
};

/// An action's identity names `target` when it starts `<target> (`.
pub fn ofTarget(identity: []const u8, target: []const u8) bool {
    return std.mem.startsWith(u8, identity, target) and identity.len > target.len + 1 and
        std.mem.eql(u8, identity[target.len .. target.len + 2], " (");
}

fn named(identity: []const u8, targets: []const []const u8) bool {
    for (targets) |t| if (ofTarget(identity, t)) return true;
    return false;
}

fn farm(executor: []const u8) bool {
    return std.mem.startsWith(u8, executor, "re(") or std.mem.eql(u8, executor, "re");
}

pub fn rerun(text: []const u8, targets: []const []const u8) Rerun {
    var r = Rerun{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue;
        const identity = fields.next() orelse continue;
        const executor = fields.next() orelse continue;
        r.actions += 1;
        if (!named(identity, targets)) {
            r.others += 1;
            if (r.first_other == null) r.first_other = identity;
        } else if (farm(executor)) {
            r.ran += 1;
        } else {
            r.stale += 1;
            if (r.first_stale == null) r.first_stale = identity;
        }
    }
    return r;
}

/// The actions of `target` that executed on the farm.
pub fn ranOf(text: []const u8, target: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue;
        const identity = fields.next() orelse continue;
        const executor = fields.next() orelse continue;
        if (ofTarget(identity, target) and farm(executor)) n += 1;
    }
    return n;
}
