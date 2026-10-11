//! sql_oracle: the rule's refusals (tools/build/sql/defs.bzl), each with its
//! exact message, and the action's invocation. The analysis refusals are a
//! refusal table; the build failures are builds of tests//negative/sql_oracle
//! that must fail in the sql_oracle action itself, with DuckDB's (or the
//! rule's own) message. A failed action is never cached, so every red here is
//! a fresh execution on the farm (what-ran is checked after each). The
//! working fixture, tests//functional/sql_oracle:check, is built first: a red
//! is only proof while the same rule builds a correct oracle green. Then
//! `buck2 aquery` of tests//functional/sql_oracle:write must show the fixed
//! invocation piece by piece (INVOCATION).
//!
//! Catches: `.safe_mode` dropped (undeclared_output, input_outside_inputs,
//! absolute_path, glob_read, setting_changed and the dot_* targets build
//! green; the invocation lacks it), the existence check dropped or narrowed
//! to some positions (one of missing_{first,middle,last}_output fails with
//! buck2's message, not the rule's), `SET TimeZone = 'UTC'`, the version
//! check or the environment check dropped or made unable to fire (the
//! invocation pins each statement from SELECT to END, and what stands
//! between the pinned pieces: the pinned version exactly, a path with no
//! quote, or nothing, so no SQL can be added there; a dropped TZ, LC_ALL
//! or LD_LIBRARY_PATH entry fails the green fixture in the environment
//! check), and each of the sql_oracle analysis `fail()` calls deleted, or
//! one arm of a condition that no other arm covers: the empty, absolute and
//! trailing-`/` input paths each fall through to the segment message, a `*`
//! segment or output name passes once the name pattern is dropped or
//! narrowed to `/`, an output over an input's directory meets buck2's
//! conflict. Each list check has its bad entry past the first (the second
//! src, output or list input; the middle of three input paths, for both
//! input path loops), and each
//! suffix check a name that holds the suffix and ends in it without its dot
//! (`notes.sql.mysql`, `out.<f>.m<f>`), so a check of the first entry only,
//! a substring test or a suffix without its dot passes one of them. (The
//! `.`/`..` arms are covered by the name pattern too.)
//! Also: komira_test_oracle's case runner no longer calling its oracle
//! discipline (discipline_unplaced and discipline_unordered build green).
const std = @import("std");
const lib = @import("lib/lib.zig");

const PKG = "tests//negative/sql_oracle:";
const GREEN = "tests//functional/sql_oracle:check";
const WRITE = "tests//functional/sql_oracle:write";

const REFUSALS = [_]lib.Row{
    .{
        .name = "output_format_parquet",
        .target = PKG ++ "output_format_parquet",
        .text = PKG ++ "output_format_parquet: output \"out.parquet.mparquet\" must end in one of .parquet, .csv, .tsv",
    },
    .{
        .name = "output_format_csv",
        .target = PKG ++ "output_format_csv",
        .text = PKG ++ "output_format_csv: output \"out.csv.mcsv\" must end in one of .parquet, .csv, .tsv",
    },
    .{
        .name = "output_format_tsv",
        .target = PKG ++ "output_format_tsv",
        .text = PKG ++ "output_format_tsv: output \"out.tsv.mtsv\" must end in one of .parquet, .csv, .tsv",
    },
    .{
        .name = "output_glob",
        .target = PKG ++ "output_glob",
        .text = PKG ++ "output_glob: output \"o*.tsv\" is not a plain file name (^[A-Za-z0-9_][A-Za-z0-9_.-]*$): outputs land in the working directory itself",
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
    .{
        .name = "src_not_sql_second",
        .target = PKG ++ "src_not_sql_second",
        .text = PKG ++ "src_not_sql_second: srcs entry notes.sql.mysql is not a .sql file",
    },
    .{
        .name = "srcs_empty",
        .target = PKG ++ "srcs_empty",
        .text = PKG ++ "srcs_empty: srcs is empty: name the .sql file(s) to run",
    },
    .{
        .name = "output_twice",
        .target = PKG ++ "output_twice",
        .text = PKG ++ "output_twice: outputs names \"out.tsv\" twice",
    },
    .{
        .name = "output_is_input_directory",
        .target = PKG ++ "output_is_input_directory",
        .text = PKG ++ "output_is_input_directory: output \"out.tsv\" is also an input path",
    },
    .{
        .name = "input_twice",
        .target = PKG ++ "input_twice",
        .text = PKG ++ "input_twice: inputs names \"staged.csv\" twice",
    },
    .{
        .name = "input_file_and_directory",
        .target = PKG ++ "input_file_and_directory",
        .text = PKG ++ "input_file_and_directory: input \"data\" is both a file and the directory of \"data/staged.csv\"",
    },
    .{
        .name = "input_empty",
        .target = PKG ++ "input_empty",
        .text = PKG ++ "input_empty: input \"\" must be a relative file path",
    },
    .{
        .name = "input_absolute",
        .target = PKG ++ "input_absolute",
        .text = PKG ++ "input_absolute: input \"/staged.csv\" must be a relative file path",
    },
    .{
        .name = "input_trailing_slash",
        .target = PKG ++ "input_trailing_slash",
        .text = PKG ++ "input_trailing_slash: input \"data/\" must be a relative file path",
    },
    .{
        .name = "input_glob_segment",
        .target = PKG ++ "input_glob_segment",
        .text = PKG ++ "input_glob_segment: input \"data/*.csv\" holds a segment that is not a plain name (^[A-Za-z0-9_][A-Za-z0-9_.-]*$)",
    },
};

const Red = struct {
    name: []const u8,
    /// The message the failed action writes, exactly.
    text: []const u8,
};

const REDS = [_]Red{
    .{ .name = "undeclared_output", .text = "Permission Error: Cannot access file \"extra.tsv\" - file system operations are disabled by configuration" },
    .{ .name = "missing_first_output", .text = "Invalid Input Error: sql_oracle: the SQL wrote no first.tsv, a declared output" },
    .{ .name = "missing_middle_output", .text = "Invalid Input Error: sql_oracle: the SQL wrote no middle.tsv, a declared output" },
    .{ .name = "missing_last_output", .text = "Invalid Input Error: sql_oracle: the SQL wrote no last.tsv, a declared output" },
    .{ .name = "sql_error", .text = "Parser Error: syntax error at or near \"SELEC\"" },
    .{ .name = "input_outside_inputs", .text = "Permission Error: Cannot access file \"not_staged.csv\" - file system operations are disabled by configuration" },
    .{ .name = "absolute_path", .text = "Permission Error: Cannot access file \"/etc/passwd\" - file system operations are disabled by configuration" },
    .{ .name = "setting_changed", .text = "Invalid Input Error: Cannot change configuration option \"threads\" - the configuration has been locked" },
    .{ .name = "glob_read", .text = "Permission Error: Cannot access file \"*.csv\" - file system operations are disabled by configuration" },
    .{ .name = "dot_command", .text = ".sh/.system cannot be used in -safe mode" },
    .{ .name = "dot_system", .text = ".sh/.system cannot be used in -safe mode" },
    .{ .name = "dot_read", .text = ".read cannot be used in -safe mode" },
    .{ .name = "dot_output", .text = ".output/.once/.excel cannot be used in -safe mode" },
    .{ .name = "dot_cd", .text = ".cd cannot be used in -safe mode" },
    .{ .name = "dot_open", .text = ".open cannot be used in -safe mode" },
    .{ .name = "dot_import", .text = ".import cannot be used in -safe mode" },
    .{ .name = "discipline_unplaced", .text = "Invalid Input Error: oracle discipline: case.sql the ORDER BY key at byte 67 states no NULLS FIRST or NULLS LAST" },
    .{ .name = "discipline_unordered", .text = "Invalid Input Error: oracle discipline: case.sql its outermost query has no ORDER BY" },
};

/// The pieces of the sql_oracle action's argv, as `buck2 aquery` prints it
/// (`[word, word, ...]`), each required after the one before, and what may
/// stand between a piece and the one before it (`gap`). `SET TimeZone` is
/// one a farm build cannot see: every worker runs in UTC, so dropping it
/// builds every fixture green. The rest of the documented invocation is
/// pinned with it, so the README's invocation is the one that runs. The
/// existence checks, after the last src, are left to the missing_*_output
/// reds.
const Gap = enum {
    /// Anything, or nothing.
    any,
    /// Nothing: the piece follows the one before it directly.
    none,
    /// The version of `komira//third_party/duckdb:duckdb`, exactly.
    version,
    /// A buck-out path: letters, digits, `_`, `-` and `/` only, so it holds
    /// no quote that could close the SQL string it sits in and no `, ` that
    /// could add an argv word.
    path,
};

const Pin = struct { what: []const u8, gap: Gap, text: []const u8 };

const INVOCATION = [_]Pin{
    .{ .what = "the flags", .gap = .any, .text = "duckdb, -no-init, -batch, -bail, -cmd, .cd " },
    .{ .what = "threads and TimeZone, right after the working directory", .gap = .path, .text = ", -cmd, .mode trash, -cmd, SET threads = 1; SET TimeZone = 'UTC'; " },
    .{ .what = "no extensions, no temp directory, the allowed paths, then the version check", .gap = .none, .text = "SET autoinstall_known_extensions = false; SET autoload_known_extensions = false; SET temp_directory = ''; SET enable_progress_bar = false; SET allowed_paths = ['data.csv', 'expected.tsv', 'rows.csv', 'rows.parquet'], -cmd, SELECT CASE WHEN version() <> 'v" },
    .{ .what = "the version check's error, right after the pinned version", .gap = .version, .text = "' THEN error('sql_oracle: this duckdb is ' || version() || ', the pin says v" },
    .{ .what = "the version check's end, right after the pinned version", .gap = .version, .text = "') END, -cmd, " },
    .{ .what = "the environment check (TZ=UTC, LC_ALL=C, the dist's lib/), right after the version check", .gap = .none, .text = "SELECT CASE WHEN getenv('TZ') IS DISTINCT FROM 'UTC' OR getenv('LC_ALL') IS DISTINCT FROM 'C' OR getenv('LD_LIBRARY_PATH') IS DISTINCT FROM '" },
    .{ .what = "the environment check's error, right after the dist's lib/", .gap = .path, .text = "/lib' THEN error('sql_oracle: the action environment is TZ=' || coalesce(getenv('TZ'), '(unset)') || ' LC_ALL=' || coalesce(getenv('LC_ALL'), '(unset)') || ' LD_LIBRARY_PATH=' || coalesce(getenv('LD_LIBRARY_PATH'), '(unset)') || ', the rule sets TZ=UTC LC_ALL=C and the dist''s lib/') END" },
    .{ .what = ".safe_mode before the first src, right after the environment check", .gap = .none, .text = ", -cmd, .safe_mode, -cmd, .mode duckbox, -f, ../sql/0_write.sql, -cmd, .mode trash, -cmd, " },
    .{ .what = "the in-memory database, last", .gap = .any, .text = ", :memory:]\"" },
};

const DIST = "komira//third_party/duckdb:duckdb";

/// The `version` attribute of DIST, from `buck2 uquery`.
fn pinnedVersion(c: *lib.Ctx) !?[]const u8 {
    const res = try c.run(&.{ "uquery", DIST, "--output-attribute", "version", "--json" }, .{});
    if (!res.ok()) {
        c.fail("invocation: buck2 uquery {s} failed (see {s}); its last lines:\n{s}", .{ DIST, res.log, lib.text.tail(res.stderr, 12) });
        return null;
    }
    const key = "\"version\": \"";
    const at = std.mem.indexOf(u8, res.stdout, key);
    const end = if (at) |i| std.mem.indexOfScalarPos(u8, res.stdout, i + key.len, '"') else null;
    if (lib.text.count(res.stdout, key) != 1 or end == null) {
        c.fail("invocation: buck2 uquery {s} does not show one version (see {s})", .{ DIST, res.log });
        return null;
    }
    return res.stdout[at.? + key.len .. end.?];
}

fn isPathByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-' or b == '/';
}

/// Why `gap`, the argv text before a piece, is not what `kind` allows, or
/// null when it is.
fn badGap(kind: Gap, gap: []const u8, version: []const u8) ?[]const u8 {
    switch (kind) {
        .any => return null,
        .none => return if (gap.len == 0) null else "nothing may stand there",
        .version => return if (std.mem.eql(u8, gap, version)) null else "only the pinned version may stand there",
        .path => {
            for (gap) |b| if (!isPathByte(b)) return "only a path of letters, digits, _, - and / may stand there";
            return null;
        },
    }
}

/// `buck2 aquery` of the working oracle's action: its argv holds every
/// INVOCATION piece in order, each gap what the piece allows, `-f` once (no
/// src before `.safe_mode`).
fn invocation(c: *lib.Ctx) !void {
    const version = try pinnedVersion(c) orelse return;
    const res = try c.run(&.{ "aquery", WRITE, "--output-attribute", "cmd", "--output-attribute", "category", "--json" }, .{});
    if (!res.ok()) {
        c.fail("invocation: buck2 aquery {s} failed (see {s}); its last lines:\n{s}", .{ WRITE, res.log, lib.text.tail(res.stderr, 12) });
        return;
    }
    if (lib.text.count(res.stdout, "\"category\": \"sql_oracle\"") != 1) {
        c.fail("invocation: buck2 aquery {s} does not show one sql_oracle action (see {s})", .{ WRITE, res.log });
        return;
    }
    var pos: usize = 0;
    for (INVOCATION) |pin| {
        const at = std.mem.indexOfPos(u8, res.stdout, pos, pin.text) orelse {
            c.fail("invocation: the sql_oracle action of {s} lacks {s}: no `{s}` after byte {d} of its argv (see {s})", .{ WRITE, pin.what, pin.text, pos, res.log });
            return;
        };
        if (badGap(pin.gap, res.stdout[pos..at], version)) |why| {
            c.fail("invocation: the sql_oracle action of {s} holds `{s}` before {s}: {s} (see {s})", .{ WRITE, res.stdout[pos..at], pin.what, why, res.log });
            return;
        }
        pos = at + pin.text.len;
    }
    if (lib.text.count(res.stdout, ", -f, ") != 1) {
        c.fail("invocation: the sql_oracle action of {s} runs -f {d} times, not once (see {s})", .{ WRITE, lib.text.count(res.stdout, ", -f, "), res.log });
        return;
    }
    c.pass("invocation: the sql_oracle action of {s} runs with all {d} pinned pieces in order, duckdb v{s}", .{ WRITE, INVOCATION.len, version });
}

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
    try invocation(c);
    try c.refusals(&REFUSALS);
    for (REDS) |row| try red(c, row);
}

pub fn main() u8 {
    return lib.main(body);
}
