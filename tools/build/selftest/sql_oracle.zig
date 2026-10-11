//! sql_oracle: the rule's refusals (tools/build/sql/defs.bzl), each with its
//! exact message. The analysis refusals are a refusal table; the build
//! failures are builds of tests//negative/sql_oracle that must fail in the
//! sql_oracle action itself, with DuckDB's (or the rule's own) message. A
//! failed action is never cached, so every red here is a fresh execution on
//! the farm (what-ran is checked after each). The working fixture,
//! tests//functional/sql_oracle:check, is built first: a red is only proof
//! while the same rule builds a correct oracle green.
//!
//! Catches: `.safe_mode` dropped (undeclared_output, input_outside_inputs,
//! absolute_path, setting_changed and dot_command build green), the
//! existence check dropped (missing_output fails with buck2's message, not
//! the rule's), and each analysis `fail()` deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const PKG = "tests//negative/sql_oracle:";
const GREEN = "tests//functional/sql_oracle:check";

const REFUSALS = [_]lib.Row{
    .{
        .name = "output_format",
        .target = PKG ++ "output_format",
        .text = PKG ++ "output_format: output \"out.txt\" must end in one of .parquet, .csv, .tsv",
    },
    .{
        .name = "output_in_directory",
        .target = PKG ++ "output_in_directory",
        .text = PKG ++ "output_in_directory: output \"sub/out.tsv\" is not a plain file name (^[A-Za-z0-9_][A-Za-z0-9_.-]*$): outputs land in the working directory itself",
    },
    .{
        .name = "no_outputs",
        .target = PKG ++ "no_outputs",
        .text = PKG ++ "no_outputs: outputs is empty: an oracle writes its answer to declared files (COPY ... TO)",
    },
    .{
        .name = "output_is_input",
        .target = PKG ++ "output_is_input",
        .text = PKG ++ "output_is_input: output \"out.tsv\" is also an input path",
    },
    .{
        .name = "built_input_in_list",
        .target = PKG ++ "built_input_in_list",
        .text = PKG ++ "built_input_in_list: inputs entry work/out.tsv is built by " ++ PKG ++ "sql_error; a list entry is staged at its path in the package, so name a build output in the dict form, {path: target}",
    },
    .{
        .name = "input_dotdot",
        .target = PKG ++ "input_dotdot",
        .text = PKG ++ "input_dotdot: input \"../staged.csv\" holds a segment that is not a plain name (^[A-Za-z0-9_][A-Za-z0-9_.-]*$)",
    },
    .{
        .name = "src_not_sql",
        .target = PKG ++ "src_not_sql",
        .text = PKG ++ "src_not_sql: srcs entry staged.csv is not a .sql file",
    },
};

const Red = struct {
    name: []const u8,
    /// The message the failed action writes, exactly.
    text: []const u8,
};

const REDS = [_]Red{
    .{ .name = "undeclared_output", .text = "Permission Error: Cannot access file \"extra.tsv\" - file system operations are disabled by configuration" },
    .{ .name = "missing_output", .text = "Invalid Input Error: sql_oracle: the SQL wrote no missing.tsv, a declared output" },
    .{ .name = "sql_error", .text = "Parser Error: syntax error at or near \"SELEC\"" },
    .{ .name = "input_outside_inputs", .text = "Permission Error: Cannot access file \"not_staged.csv\" - file system operations are disabled by configuration" },
    .{ .name = "absolute_path", .text = "Permission Error: Cannot access file \"/etc/passwd\" - file system operations are disabled by configuration" },
    .{ .name = "setting_changed", .text = "Invalid Input Error: Cannot change configuration option \"threads\" - the configuration has been locked" },
    .{ .name = "dot_command", .text = ".sh/.system cannot be used in -safe mode" },
};

fn holds(r: anytype, want: []const u8) bool {
    return lib.text.contains(r.stderr, want) or lib.text.contains(r.stdout, want);
}

fn farmOnly(c: *lib.Ctx, what: []const u8) !void {
    var why: []const u8 = "";
    const n = c.r.checkWhatRan(null, &why) catch {
        c.fail("{s}: {s}", .{ what, why });
        return;
    };
    c.pass("{s}: what-ran lists {d} actions, all on the farm", .{ what, n });
}

fn red(c: *lib.Ctx, row: Red) !void {
    const target = try std.fmt.allocPrint(c.a, "{s}{s}", .{ PKG, row.name });
    const res = try c.run(&.{ "build", target }, .{});
    if (res.ok()) {
        c.fail("{s}: {s} built, but it must fail with `{s}` (see {s})", .{ row.name, target, row.text, res.log });
        return;
    }
    // The failure is the sql_oracle action's own: buck2 names the target
    // and the action's category around the configuration hash.
    const action = try std.fmt.allocPrint(c.a, "Action failed: {s} (", .{target});
    if (!holds(res, action) or !holds(res, ") (sql_oracle)")) {
        c.fail("{s}: {s} failed, but not in its sql_oracle action (see {s}); its last lines:\n{s}", .{ row.name, target, res.log, lib.text.tail(res.stderr, 12) });
        return;
    }
    if (!holds(res, row.text)) {
        c.fail("{s}: {s} failed without `{s}` (see {s}); its last lines:\n{s}", .{ row.name, target, row.text, res.log, lib.text.tail(res.stderr, 12) });
        return;
    }
    c.pass("{s}: {s} fails in its sql_oracle action: {s}", .{ row.name, target, row.text });
    try farmOnly(c, row.name);
}

fn body(c: *lib.Ctx) !void {
    const green = try c.run(&.{ "build", GREEN }, .{});
    if (!green.ok()) {
        c.fail("precondition: {s} does not build (see {s}); its last lines:\n{s}", .{ GREEN, green.log, lib.text.tail(green.stderr, 12) });
        return;
    }
    c.pass("precondition: {s} builds", .{GREEN});
    try farmOnly(c, "precondition");
    try c.refusals(&REFUSALS);
    for (REDS) |row| try red(c, row);
}

pub fn main() u8 {
    return lib.main(body);
}
