//! The command line:
//!
//!   main_red --repo <owner/name> --run-id <id> --workflow <name>...
//!            [--dry-run] [--gh <path>]
//!
//! `--workflow` names a workflow (its `name:`, as in a `workflow_run`
//! trigger's `workflows:` list) whose runs on main this alert reads; give it
//! once per workflow. A run of any other workflow is ignored.
const std = @import("std");

pub const USAGE =
    \\usage: main_red --repo <owner/name> --run-id <id> --workflow <name>...
    \\                [--dry-run] [--gh <path>]
    \\
;

pub const Args = struct {
    repo: []const u8 = "",
    run_id: u64 = 0,
    workflows: []const []const u8 = &.{},
    dry_run: bool = false,
    gh: []const u8 = "gh",
};

pub const ArgError = error{ MissingValue, UnknownArgument, MissingRepo, BadRepo, MissingRunId, BadRunId, NoWorkflow, EmptyWorkflow };

fn repoChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

/// Whether `s` is `owner/name`: two non-empty parts of letters, digits, `_`,
/// `.` and `-`.
pub fn validRepo(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    const owner = s[0..slash];
    const name = s[slash + 1 ..];
    if (owner.len == 0 or name.len == 0) return false;
    for (owner) |c| if (!repoChar(c)) return false;
    for (name) |c| if (!repoChar(c)) return false;
    return true;
}

pub fn parseArgs(a: std.mem.Allocator, argv: []const []const u8) !Args {
    var r = Args{};
    var workflows = std.ArrayList([]const u8).empty;
    var have_run_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            r.dry_run = true;
            continue;
        }
        const is_value = std.mem.eql(u8, arg, "--repo") or std.mem.eql(u8, arg, "--run-id") or
            std.mem.eql(u8, arg, "--workflow") or std.mem.eql(u8, arg, "--gh");
        if (!is_value) return error.UnknownArgument;
        i += 1;
        if (i >= argv.len) return error.MissingValue;
        const v = argv[i];
        if (std.mem.eql(u8, arg, "--repo")) {
            r.repo = v;
        } else if (std.mem.eql(u8, arg, "--run-id")) {
            r.run_id = std.fmt.parseInt(u64, v, 10) catch return error.BadRunId;
            have_run_id = true;
        } else if (std.mem.eql(u8, arg, "--workflow")) {
            if (std.mem.trim(u8, v, " ").len == 0) return error.EmptyWorkflow;
            try workflows.append(a, v);
        } else r.gh = v;
    }
    if (r.repo.len == 0) return error.MissingRepo;
    if (!validRepo(r.repo)) return error.BadRepo;
    if (!have_run_id) return error.MissingRunId;
    if (workflows.items.len == 0) return error.NoWorkflow;
    r.workflows = workflows.items;
    return r;
}
