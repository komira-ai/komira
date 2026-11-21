//! buck2_failure: release-macos.yml's report of a failed buck2 step.
//!
//!   buck2_failure --log <path> --step <name> --github-output <path>
//!                 --summary-file <path>
//!
//! It reads the log of the failed step (buck2's output, as the buck2-farm
//! action tees it), takes what buck2 said after its last failure line
//! (`BUILD FAILED`, `BXL FAILED`, `TEST FAILED`, `Command failed:`), or the
//! last lines of the log when there is none, and appends
//!   - to --github-output, one line `message=<message>` (the message as one
//!     line: `%`, CR and LF escaped as in a workflow command), and
//!   - to --summary-file, the failed step and the lines as a code block.
//! A missing or empty log is "no buck2 output", not an error.
//!
//! Exit 0 when both files were written, 2 on a usage error or when a file
//! cannot be written.
const std = @import("std");
const lib = @import("buck2_failure_lib");

pub fn main() void {
    run() catch |e| fail("{s}", .{@errorName(e)});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().deprecatedWriter().print("buck2_failure: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(2);
}

fn appendFile(path: []const u8, text: []const u8) void {
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch |e| fail("cannot open {s}: {s}", .{ path, @errorName(e) });
    defer f.close();
    f.seekFromEnd(0) catch |e| fail("cannot write {s}: {s}", .{ path, @errorName(e) });
    f.writeAll(text) catch |e| fail("cannot write {s}: {s}", .{ path, @errorName(e) });
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = lib.parseArgs(argv[1..]) catch |e| {
        std.fs.File.stderr().deprecatedWriter().print("buck2_failure: {s}\n{s}", .{ lib.argErrorText(e), lib.USAGE }) catch {};
        std.process.exit(2);
    };
    const log: []const u8 = std.fs.cwd().readFileAlloc(a, args.log, 1 << 28) catch "";
    const block = try lib.failureBlock(a, log);
    const msg = try lib.message(a, args.step, block);
    appendFile(args.github_output, try lib.outputLine(a, msg));
    appendFile(args.summary_file, try lib.summaryText(a, args.step, block));
}
