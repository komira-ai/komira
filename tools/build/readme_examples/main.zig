//! The README examples tool: a README's ```mojo examples as programs, one
//! per example, and the line map of their reports (cli.zig has the commands;
//! examples.zig what an example is; program.zig the programs); a
//! the includes, `fill` and freshness check of every document that shows
//! files, a README or a task page (include.zig), the exact output compare
//! (output.zig), and `migrate` from the inline model (migrate.zig); the
//! check that a fixture's run fails as it must (expect_failure.zig); and the
//! check of the common-task pages (tasks.zig). mojo_library runs `generate`,
//! and for a source-first README `check` and `fill`, as actions on its
//! package's README.md (tools/build/mojo/readme.bzl), and so do the coverage
//! build and the README API census (tools/build/lint/readme_api_coverage.bzl).

const std = @import("std");
const cli = @import("cli.zig");

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const raw = std.process.argsAlloc(a) catch @panic("out of memory");
    const argv = a.alloc([]const u8, raw.len) catch @panic("out of memory");
    for (raw, 0..) |arg, i| argv[i] = arg;
    const o = cli.run(a, std.fs.cwd(), argv);
    std.fs.File.stdout().writeAll(o.stdout) catch {};
    std.process.exit(o.code);
}

// The unit tests, run by `zig test` on this file (BUCK: `:readme_examples_unit`).
test {
    _ = @import("examples_test.zig");
    _ = @import("program_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("link_test.zig");
    _ = @import("tasks_test.zig");
    _ = @import("task_page_test.zig");
    _ = @import("include_test.zig");
    _ = @import("migrate_test.zig");
    _ = @import("expect_failure_test.zig");
    _ = @import("output_test.zig");
    _ = @import("kinds_test.zig");
}
