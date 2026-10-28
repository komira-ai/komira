//! planted_red_builds_abi_golden: komira_abi_golden (tools/build/mojo/abi_golden.bzl).
//!
//!   - each target of tests//negative/abi_golden fails on the farm naming its
//!     one defect: a changed return type, a changed argument type, a symbol the
//!     source no longer exports, a symbol the golden does not list, a type
//!     outside the type map, and a row whose `since` is above the golden
//!     version;
//!   - the example and the twin of the negatives build: the header made from
//!     the golden, the C driver that includes it and defines every function it
//!     declares (it compiles only if the header is valid C with the types of
//!     the definitions), the shared library of the same source, and
//!     tests//functional/abi_golden:ok.
const std = @import("std");
const lib = @import("lib/lib.zig");

const N = "tests//negative/abi_golden:";
const E = "komira//tools/build/examples/abi_golden:";

const ROWS = [_]lib.Row{
    .{
        .name = "abi_golden_return_type_changed",
        .target = N ++ "drift",
        .text = "`neg_add`: the return type changed: golden `Int64`, source `Int32`",
    },
    .{
        .name = "abi_golden_argument_type_changed",
        .target = N ++ "arg_drift",
        .text = "`neg_add`: the argument types changed: golden (Int32, Int64), source (Int32, Int32)",
    },
    .{
        .name = "abi_golden_symbol_removed",
        .target = N ++ "removed",
        .text = "missing symbol `neg_fill`",
    },
    .{
        .name = "abi_golden_symbol_added",
        .target = N ++ "added",
        .text = "extra symbol `neg_extra`",
    },
    .{
        .name = "abi_golden_unknown_type",
        .target = N ++ "unknown_type",
        .text = "the argument type `Bool` is not in the type map",
    },
    .{
        .name = "abi_golden_since_above_version",
        .target = N ++ "since_above_version",
        .text = "`neg_fill`: since 1.2 is above the golden version 1.1",
    },
};

const GREENS = [_][]const u8{
    E ++ "abi_header",
    E ++ "header_driver",
    E ++ "abi_lib",
    "tests//functional/abi_golden:ok",
};

fn builds(c: *lib.Ctx, target: []const u8) !void {
    const r = try c.run(&.{ "build", target }, .{});
    if (r.ok()) {
        c.pass("abi_golden_builds: {s}", .{target});
    } else {
        c.fail("abi_golden_builds: {s} failed (see {s}); its last lines:\n{s}", .{ target, r.log, r.stderr[r.stderr.len -| 800..] });
    }
}

fn body(c: *lib.Ctx) !void {
    try c.reds(&ROWS);
    for (GREENS) |t| try builds(c, t);
}

pub fn main() u8 {
    return lib.main(body);
}
