//! The README examples tool: a README's ```mojo examples as programs, one
//! per example, and the line map of their reports (cli.zig has the commands;
//! examples.zig what an example is; program.zig the programs). mojo_library
//! runs `generate` as an action on its package's README.md
//! (tools/build/mojo/defs.bzl), and so do the coverage build and the README
//! API census (tools/build/lint/readme_api_coverage.bzl).

const std = @import("std");
const cli = @import("cli.zig");

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const raw = std.process.argsAlloc(a) catch @panic("out of memory");
    const argv = a.alloc([]const u8, raw.len) catch @panic("out of memory");
    for (raw, 0..) |arg, i| argv[i] = arg;
    const o = cli.run(a, std.fs.cwd(), argv);
    std.io.getStdOut().writeAll(o.stdout) catch {};
    std.process.exit(o.code);
}

// The unit tests, run by `zig test` on this file (BUCK: `:readme_examples_unit`).
test {
    _ = @import("examples_test.zig");
    _ = @import("program_test.zig");
    _ = @import("cli_test.zig");
}
