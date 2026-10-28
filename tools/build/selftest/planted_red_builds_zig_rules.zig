//! planted_red_builds_zig_rules: the planted defects of the Zig rules that fail in an action (what each plants is written above it
//! in tools/build/tests/negative/zig_rules/BUCK). Each row's build must fail
//! on the farm and print the row's text (lib/reds.zig):
//!
//!   - a module importing a module it does not declare, and an importer
//!     reaching a module only through another module's deps, are refused by
//!     the compiler (the closure gives each module the imports of its own
//!     deps only);
//!   - the red twins of the effects of optimize, strip and target: the same
//!     check, against the executable or test built without the attribute,
//!     fails (the attribute reaches the compile).
//!
//! The analysis refusals of the same rules are analysis_refusals_zig_rules.
const std = @import("std");
const lib = @import("lib/lib.zig");

const N = "tests//negative/zig_rules:";

const ROWS = [_]lib.Row{
    .{
        .name = "zig_module_without_deps",
        .target = N ++ "module_without_deps",
        .text = "no module named 'zr_leaf' available within module zr_mid_nodeps",
    },
    .{
        .name = "zig_dep_of_dep_not_visible",
        .target = N ++ "dep_of_dep_not_visible",
        .text = "no module named 'zr_leaf' available within module root",
    },
    .{
        .name = "zig_test_optimize_not_applied",
        .target = N ++ "optimize_not_applied",
        .text = "expected builtin.OptimizeMode.ReleaseFast, found builtin.OptimizeMode.Debug",
    },
    .{
        .name = "zig_test_target_not_applied",
        .target = N ++ "target_not_applied",
        .text = "expected Target.Abi.gnu, found Target.Abi.musl",
    },
    .{
        .name = "zig_exe_optimize_and_strip_reach_the_compile",
        .target = N ++ "swapped_tools",
        .text = "got '42 Debug', expected '42 ReleaseSafe'",
        .also = &.{"app_debug is unstripped, expected stripped"},
    },
};

fn body(c: *lib.Ctx) !void {
    try c.reds(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
