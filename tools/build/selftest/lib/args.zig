//! The scenario binary's command line, as selftest_scenario (defs.bzl) writes it:
//!
//!   <scenario> --scenario <name> --buck2 <path> --buck2-zst <path> --expect remote|local
//!       [--nested] [--keep-scratch]
//!
//! `--buck2-zst` is the release asset `--buck2` was unpacked from: the guard
//! holds its sha256 to the pin in `tools/buck2`, the one place the version is
//! written.
//!
//! `--nested` is given only under the recursion guard's config_setting
//! (`-c komira_selftest.inner=true`): it is a refusal, never a mode.
const std = @import("std");

pub const Expect = enum { remote, local };

pub const Args = struct {
    scenario: []const u8,
    buck2: []const u8,
    buck2_zst: []const u8,
    expect: Expect,
    nested: bool = false,
    keep_scratch: bool = false,
};

pub const Error = error{
    UnknownArgument,
    MissingValue,
    MissingScenario,
    MissingBuck2,
    MissingBuck2Zst,
    MissingExpect,
    BadExpect,
    BadScenarioName,
};

/// A scenario name is a target name: `[a-z][a-z0-9_]*`. It names the
/// isolation dir and the scratch tree, so nothing else may reach them.
pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s[0] < 'a' or s[0] > 'z') return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// `argv` without the program name.
pub fn parse(argv: []const []const u8) Error!Args {
    var scenario: ?[]const u8 = null;
    var buck2: ?[]const u8 = null;
    var zst: ?[]const u8 = null;
    var expect: ?Expect = null;
    var nested = false;
    var keep = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--nested")) {
            nested = true;
        } else if (std.mem.eql(u8, a, "--keep-scratch")) {
            keep = true;
        } else if (std.mem.eql(u8, a, "--scenario") or std.mem.eql(u8, a, "--buck2") or std.mem.eql(u8, a, "--buck2-zst") or std.mem.eql(u8, a, "--expect")) {
            if (i + 1 >= argv.len) return error.MissingValue;
            const v = argv[i + 1];
            i += 1;
            if (std.mem.eql(u8, a, "--scenario")) {
                if (!validName(v)) return error.BadScenarioName;
                scenario = v;
            } else if (std.mem.eql(u8, a, "--buck2")) {
                buck2 = v;
            } else if (std.mem.eql(u8, a, "--buck2-zst")) {
                zst = v;
            } else {
                expect = std.meta.stringToEnum(Expect, v) orelse return error.BadExpect;
            }
        } else {
            return error.UnknownArgument;
        }
    }
    return .{
        .scenario = scenario orelse return error.MissingScenario,
        .buck2 = buck2 orelse return error.MissingBuck2,
        .buck2_zst = zst orelse return error.MissingBuck2Zst,
        .expect = expect orelse return error.MissingExpect,
        .nested = nested,
        .keep_scratch = keep,
    };
}
