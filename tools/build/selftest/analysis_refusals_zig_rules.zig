//! analysis_refusals_zig_rules: the analysis refusals of the Zig rules'
//! module graph, optimization mode and target, and of zig_test's exec_tools
//! and data (tools/build/mojo/toolchain.bzl), each with its exact
//! message (what each plants is written above it in
//! tools/build/tests/negative/zig_rules/BUCK). Catches the name-clash check
//! of the module closure deleted, the optimization mode not checked, a
//! driver tool named like a variable the action sets accepted.
//!
//! What fails in an action is planted_red_builds_zig_rules.
const std = @import("std");
const lib = @import("lib/lib.zig");

const N = "tests//negative/zig_rules:";

const ROWS = [_]lib.Row{
    .{
        .name = "zig_module_name_clash",
        .target = N ++ "name_clash",
        .text = N ++ "name_clash: two different modules are imported as \"shared\": " ++ "tests//negative/zig_rules/clash_a:shared and tests//negative/zig_rules/clash_b:shared",
    },
    .{
        .name = "zig_exe_unknown_optimize",
        .target = N ++ "exe_unknown_optimize",
        .text = N ++ "exe_unknown_optimize: optimize \"Fast\" is not a zig optimization mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)",
    },
    .{
        .name = "zig_test_unknown_optimize",
        .target = N ++ "test_unknown_optimize",
        .text = N ++ "test_unknown_optimize: optimize \"Fast\" is not a zig optimization mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)",
    },
    .{
        .name = "zig_test_bad_target",
        .target = N ++ "test_bad_target",
        .text = "target \"x86 64\" is not a zig target triple",
        .also = &.{N ++ "test_bad_target"},
    },
    .{
        .name = "zig_test_exec_tools_bad_name",
        .target = N ++ "exec_tools_bad_name",
        .text = N ++ "exec_tools_bad_name: exec_tools name \"1BAD\" is not a shell variable name",
    },
    .{
        .name = "zig_test_exec_tools_sets_home",
        .target = N ++ "exec_tools_sets_home",
        .text = N ++ "exec_tools_sets_home: exec_tools name HOME is set by the action or by env_tools",
    },
    .{
        .name = "zig_test_data_file_and_directory",
        .target = N ++ "data_file_and_directory",
        .text = N ++ "data_file_and_directory: data destination \"d\" is both a file and the directory of \"d/inner\"",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
