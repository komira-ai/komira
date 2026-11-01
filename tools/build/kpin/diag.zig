//! Messages a command collects instead of stopping at the first: every
//! problem in the inputs is reported in one run.

const std = @import("std");

pub const Diag = struct {
    a: std.mem.Allocator,
    msgs: std.ArrayList([]const u8) = .empty,

    pub fn init(a: std.mem.Allocator) Diag {
        return .{ .a = a };
    }

    pub fn add(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const m = std.fmt.allocPrint(self.a, fmt, args) catch return;
        self.msgs.append(self.a, m) catch return;
    }

    pub fn count(self: *const Diag) usize {
        return self.msgs.items.len;
    }
};

/// What `resolve` and `update` found. An alarm is a hash that changed for a
/// (name, version) already locked; everything else wrong is an error. Alarms
/// are kept apart because they are never fixed by regenerating and have their
/// own exit code.
pub const Report = struct {
    errors: Diag,
    alarms: Diag,

    pub fn init(a: std.mem.Allocator) Report {
        return .{ .errors = Diag.init(a), .alarms = Diag.init(a) };
    }

    pub fn clean(self: *const Report) bool {
        return self.errors.count() == 0 and self.alarms.count() == 0;
    }
};
