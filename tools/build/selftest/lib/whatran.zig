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
