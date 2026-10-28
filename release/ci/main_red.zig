//! main_red: the alert of .github/workflows/main_red.yml (docs/ci.md, "The
//! main red alert").
//!
//!   main_red --repo <owner/name> --run-id <id> --workflow <name>... [--dry-run]
//!
//! It runs when a run of one of the named workflows completes, and reads that
//! run back from the GitHub API with the `gh` CLI (GH_TOKEN in the
//! environment). Only a run started by a PUSH to main counts: a manual run
//! may build another revision, and a run of any other branch is not main.
//!
//!   failure, timed_out or startup_failure: main is red.
//!     1. The last green: of the successful push runs of the named workflows
//!        on main (newest first), the first whose commit is an ancestor of (or
//!        is) the red head. If one is a DESCENDANT of the red head first, main
//!        is already green past this commit (a re-run of an old run failed):
//!        nothing is written.
//!     2. The culprits: the pull requests merged into main between the last
//!        green and the head: the first-parent commits of main in that range,
//!        newest first, each one's pull request from the API (a merged pull
//!        request into main) or from its subject (`Merge pull request #N` or a
//!        squash's trailing `(#N)`). No last green, or no number found:
//!        `Culprits: unknown`.
//!     3. The failing targets: the `Action failed: <target>`, `GATED TEST
//!        FAILED: <target>` and ``Validation for `<target>` failed`` lines of
//!        the failed jobs' logs (buck2's own output), the first five, each
//!        without its configuration; with none, the failed job and step; with
//!        no failed job (a job could not start), the workflow.
//!     4. If an issue labelled `main-red` is open, a comment on the oldest
//!        one; otherwise a new issue `main red: <first failing>` with that
//!        label (created if missing). The body, and the comment, are the
//!        contract an outside reader parses (issue.issueBody): one `Key:
//!        value` line each, in this order, nothing else:
//!          Run: <run url>
//!          Head: <full commit id>
//!          Last green: <full commit id, or none>
//!          Culprits: #N, #M          (or `Culprits: unknown`)
//!          Failing: <target>         (one line per target)
//!          Log: <key log line>       (none, one or two lines)
//!        After creating an issue it lists the open ones again: if two runs
//!        raced, every issue but the oldest is closed as its duplicate, its
//!        body posted on the oldest.
//!   success: every open `main-red` issue is closed, with the comment `Fixed:
//!     main is green at <sha> (run <url>)`, unless it records a head the green
//!     commit does not contain (a re-run of an older commit went green): then
//!     it stays open. The recorded heads are the `Head:` lines of the issue's
//!     body and of the comments the workflow's own login wrote; anyone can
//!     comment on a public issue, so no other comment counts. A head the
//!     compare API does not know (404) or places off main's line (diverged) is
//!     logged and skipped.
//!   cancelled, skipped, anything else: nothing.
//!
//! Exit 0 when it wrote what the run calls for (or nothing was called for),
//! 2 on a usage error, 1 on any API failure, so the workflow's run is red and
//! visible.
const std = @import("std");
const lib = @import("main_red_lib");

pub fn main() void {
    run() catch |e| {
        std.fs.File.stderr().deprecatedWriter().print("main_red: {s}\n", .{@errorName(e)}) catch {};
        std.process.exit(1);
    };
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = lib.args.parseArgs(a, argv[1..]) catch |e| {
        const msg = switch (e) {
            error.BadRepo => "--repo is not owner/name",
            error.BadRunId => "--run-id is not a number",
            error.EmptyWorkflow => "--workflow is empty",
            else => @errorName(e),
        };
        std.fs.File.stderr().deprecatedWriter().print("main_red: {s}\n{s}", .{ msg, lib.args.USAGE }) catch {};
        std.process.exit(2);
    };
    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    const out = &stdout.interface;
    var api = lib.gh.GhApi{ .a = a, .gh = args.gh, .dry_run = args.dry_run, .out = out };
    const alert = lib.run.Alert(lib.gh.GhApi){
        .a = a,
        .api = &api,
        .cfg = .{ .repo = args.repo, .workflows = args.workflows },
        .out = out,
    };
    alert.run(args.run_id) catch |e| {
        out.flush() catch {};
        if (e == error.GhFailed) {
            const why = if (api.last_err.len > 0) api.last_err else "(gh printed nothing on stderr)";
            std.fs.File.stderr().deprecatedWriter().print("main_red: gh api {s} failed: {s}\n", .{ api.last_call, why }) catch {};
            std.process.exit(1);
        }
        return e;
    };
    try out.flush();
}
