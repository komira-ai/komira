//! A scenario's report: one PASS or FAIL line per assertion. A scenario
//! passes only when it asserted something and nothing failed, so a scenario
//! that asserts nothing (a table emptied, an early return) is red.
const std = @import("std");

pub const Report = struct {
    a: std.mem.Allocator,
    scenario: []const u8,
    passes: usize = 0,
    fails: usize = 0,
    out: std.ArrayList(u8),

    pub fn init(a: std.mem.Allocator, scenario: []const u8) Report {
        return .{ .a = a, .scenario = scenario, .out = std.ArrayList(u8).init(a) };
    }

    fn line(self: *Report, s: []const u8) void {
        self.out.appendSlice(s) catch {};
        self.out.append('\n') catch {};
        std.io.getStdOut().writer().print("{s}\n", .{s}) catch {};
    }

    pub fn pass(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.passes += 1;
        const s = std.fmt.allocPrint(self.a, "PASS  {s}: " ++ fmt, .{self.scenario} ++ args) catch return;
        self.line(s);
    }

    pub fn fail(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.fails += 1;
        const s = std.fmt.allocPrint(self.a, "FAIL  {s}: " ++ fmt, .{self.scenario} ++ args) catch return;
        self.line(s);
    }

    /// `cond` passes as `what`; otherwise fails as `what: why`.
    pub fn check(self: *Report, cond: bool, what: []const u8, why: []const u8) void {
        if (cond) self.pass("{s}", .{what}) else self.fail("{s}: {s}", .{ what, why });
    }

    pub const Outcome = enum { passed, failed, asserted_nothing };

    pub fn outcome(self: *const Report) Outcome {
        if (self.fails > 0) return .failed;
        if (self.passes == 0) return .asserted_nothing;
        return .passed;
    }

    /// The final line, and the exit status: 0 only for `.passed`.
    pub fn finish(self: *Report) u8 {
        switch (self.outcome()) {
            .passed => {
                self.line(std.fmt.allocPrint(self.a, "{s}: all {d} assertions passed", .{ self.scenario, self.passes }) catch "");
                return 0;
            },
            .failed => {
                self.line(std.fmt.allocPrint(self.a, "{s}: {d} of {d} assertions failed", .{ self.scenario, self.fails, self.fails + self.passes }) catch "");
                return 1;
            },
            .asserted_nothing => {
                self.line(std.fmt.allocPrint(self.a, "FAIL  {s}: asserted nothing; a scenario that checks nothing is red", .{self.scenario}) catch "");
                return 1;
            },
        }
    }
};
