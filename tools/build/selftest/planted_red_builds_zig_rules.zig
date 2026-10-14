//! planted_red_builds_zig_rules: the planted defects of the Zig rules and
//! script_test that fail in an action (what each plants is written above it
//! in tools/build/tests/negative/zig_rules/BUCK). Each row's build must fail
//! on the farm and print the row's text (lib/reds.zig):
//!
//!   - a module importing a module it does not declare, and an importer
//!     reaching a module only through another module's deps, are refused by
//!     the compiler (the closure gives each module the imports of its own
//!     deps only);
//!   - the red twins of the effects of optimize, strip and target: the same
//!     check, against the executable or test built without the attribute,
//!     fails (the attribute reaches the compile);
//!   - script_test's verdict: a command that exits non-zero fails the
//!     target, with its status and the tail of its output; a command that is
//!     not found, or a tool declared under another name, exits 127; a
//!     zig_exe that lists a failing script_test in unit_tests is not built.
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
        .name = "zig_exe_debug_is_not_release_safe",
        .target = N ++ "debug_is_not_release_safe",
        .text = "got '42 Debug', expected '42 ReleaseSafe'",
    },
    .{
        .name = "zig_exe_unstripped_is_not_stripped",
        .target = N ++ "unstripped_is_not_stripped",
        .text = "app_debug is unstripped, expected stripped",
    },
    .{
        .name = "script_test_fails",
        .target = N ++ "fails",
        .text = "script_test: sh exited with status 3",
        .also = &.{"boom: the line script_test must show"},
    },
    .{
        .name = "script_test_command_missing",
        .target = N ++ "command_missing",
        .text = "script_test: no_such_command_anywhere exited with status 127",
        .also = &.{"not found"},
    },
    .{
        .name = "script_test_tool_under_another_name",
        .target = N ++ "tool_under_another_name",
        .text = "script_test: zigg exited with status 127",
    },
    .{
        .name = "script_test_welded_to_a_failure",
        .target = N ++ "welded_to_a_failure",
        .text = "script_test: sh exited with status 3",
        .also = &.{"boom: the line script_test must show"},
    },
};

fn body(c: *lib.Ctx) !void {
    try c.reds(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
