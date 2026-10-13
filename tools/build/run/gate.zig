//! gate: runs and supervises welded tests in build actions, in place of the
//! shell runners (docs/design/zig_gate_runner.md; README.md here).
//!
//!   gate mojo ...   one gated Mojo test (and its memory cap, its time limit,
//!                   or a coverage run's limit): mojo.zig
//!   gate rust ...   one rust_test harness: rust.zig
//!   gate step ...   one mutation step, its result recorded: step.zig
//!
//! Exit status: per mode (README.md, "Exit status"); 2 for a usage error.

const std = @import("std");
const util = @import("util.zig");
const mojo = @import("mojo.zig");
const rust = @import("rust.zig");
const step = @import("step.zig");

/// The tool's entry point without the process around it: `argv` after the
/// program name. Returns the exit status.
pub fn entry(alloc: std.mem.Allocator, argv: []const []const u8) u8 {
    if (argv.len == 0) {
        util.err("gate: usage: gate mojo|rust|step <options> (README.md)\n", .{});
        return 2;
    }
    const rest = argv[1..];
    if (std.mem.eql(u8, argv[0], "mojo")) return mojo.main(alloc, rest);
    if (std.mem.eql(u8, argv[0], "rust")) return rust.main(alloc, rest);
    if (std.mem.eql(u8, argv[0], "step")) return step.main(alloc, rest);
    util.err("gate: unknown mode {s}; the modes are mojo, rust and step\n", .{argv[0]});
    return 2;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const args = std.process.argsAlloc(alloc) catch std.process.exit(2);
    var list = std.ArrayList([]const u8).init(alloc);
    for (args[1..]) |a| list.append(a) catch std.process.exit(2);
    std.process.exit(entry(alloc, list.items));
}
