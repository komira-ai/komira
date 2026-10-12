//! prefix_tool: the prefix header of a vendored C library and the symbol
//! check of its prefixed archive (README.md). The commands are in cli.zig,
//! what they compute in prefix.zig. It reads archives through `elfsyms`
//! (elfsyms.c) and runs nothing else.

const std = @import("std");
const P = @import("prefix.zig");
const cli = @import("cli.zig");

pub fn main() void {
    const raw = std.process.argsAlloc(P.a()) catch P.oom();
    const argv = P.a().alloc([]const u8, raw.len) catch P.oom();
    for (raw, 0..) |arg, i| argv[i] = arg;
    const cwd = std.process.getCwdAlloc(P.a()) catch P.oom();
    const o = cli.outcome(argv, cwd);
    std.io.getStdOut().writeAll(o.stdout) catch {};
    std.io.getStdErr().writeAll(o.stderr) catch {};
    std.process.exit(o.code);
}

// The unit tests, run by `zig test` on this file (BUCK: `:prefix_tool_unit`).
test {
    _ = @import("prefix_test.zig");
    _ = @import("cli_test.zig");
}
