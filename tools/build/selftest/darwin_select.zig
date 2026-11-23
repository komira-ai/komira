//! darwin_select: the command of the macOS part of the pull request's check,
//! `buck2 bxl komira//tools/build/ci/darwin.bxl:select
//! @tools/build/ci/darwin_affected.args @<list>`, run as pr.yml runs it, over
//! lists written into the scenario's work directory. Each row checks the
//! exit status, stdout (the labels, one per line, exactly) and the verdict
//! line on stderr.
//!
//!   - whole: a list holding the aggregate prints the whole macOS set alone.
//!   - some: the `:lib`s of set packages, with another target of one of
//!     them, print those `:lib`s once each in DARWIN_PACKAGES' order.
//!   - none: a list reaching no library of the set prints nothing.
//!   - empty: an empty list prints nothing.
//!   - broken: a line that is not a label fails the command, naming it, and
//!     prints nothing.
//! Catches the argument file and the command's flag disagreeing (every list
//! read as empty: whole and some fail), the verdict or the labels printed to
//! the wrong stream, and a refusal that no longer fails the command.
const std = @import("std");
const lib = @import("lib/lib.zig");

const SELECT = "komira//tools/build/ci/darwin.bxl:select";
const ARGS = "@tools/build/ci/darwin_affected.args";

const Row = struct {
    name: []const u8,
    list: []const u8,
    /// Null: the command must fail.
    stdout: ?[]const []const u8,
    /// What stderr must hold.
    verdict: []const u8,
};

const ROWS = [_]Row{
    .{ .name = "whole", .list = "komira//ci:pr\n", .stdout = &.{"komira//release:mopm_darwin_libs"}, .verdict = "darwin: WHOLE: the change is built as komira//ci:pr, so the whole macOS set is" },
    .{
        .name = "some",
        .list = "komira//src/wkt:lib\nkomira//src/encoding:test_hex\nkomira//src/encoding:lib\nkomira//src/wkt:lib\n",
        .stdout = &.{ "komira//src/encoding:lib", "komira//src/wkt:lib" },
        .verdict = "darwin: SOME: 2 of the ",
    },
    .{ .name = "none", .list = "komira//tools/build/ci:change\nkomira//src/encoding:test_hex\n", .stdout = &.{}, .verdict = "darwin: NONE: the change reaches no library of the macOS set" },
    .{ .name = "empty", .list = "", .stdout = &.{}, .verdict = "darwin: NONE: the change reaches no library of the macOS set" },
    .{ .name = "broken", .list = "komira//src/encoding:lib\nnot a label\n", .stdout = null, .verdict = "darwin: BROKEN: \"not a label\" is not a target label: the selector's output changed shape" },
};

fn body(c: *lib.Ctx) !void {
    for (ROWS) |row| {
        const path = try std.fs.path.join(c.a, &.{ c.tmp, try std.fmt.allocPrint(c.a, "{s}.txt", .{row.name}) });
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = row.list });
        // The inner key goes before the argument file: the `--` that file holds ends buck2's own
        // flags, and the runner places its `-c` only before a `--` among the words it is given.
        const res = try c.run(&.{ "bxl", SELECT, "-c", lib.runner.INNER_KEY, ARGS, try std.fmt.allocPrint(c.a, "@{s}", .{path}) }, .{ .configured = false });
        const said = lib.text.contains(res.stderr, row.verdict);
        const got = try lib.text.lines(c.a, res.stdout);
        if (row.stdout) |want| {
            const name = try std.fmt.allocPrint(c.a, "{s}: succeeds, prints exactly {d} label(s) and says `{s}`", .{ row.name, want.len, row.verdict });
            c.rep.check(res.ok() and said and lib.text.eqlLists(got, want), name, res.log);
        } else {
            const name = try std.fmt.allocPrint(c.a, "{s}: fails, prints no label and says `{s}`", .{ row.name, row.verdict });
            c.rep.check(!res.ok() and said and got.len == 0, name, res.log);
        }
    }
}

pub fn main() u8 {
    return lib.main(body);
}
