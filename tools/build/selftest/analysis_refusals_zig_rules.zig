//! analysis_refusals_zig_rules: the analysis refusals of the Zig rules'
//! module graph, optimization mode and target (tools/build/mojo/toolchain.bzl)
//! and of script_test (tools/build/mojo/script_test.bzl), each with its exact
//! message (what each plants is written above it in
//! tools/build/tests/negative/zig_rules/BUCK). Catches the name-clash check
//! of the module closure deleted, the optimization mode not checked, the env
//! names the action sets itself accepted, and an empty command accepted.
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
        .name = "script_test_cmd_empty",
        .target = N ++ "cmd_empty",
        .text = N ++ "cmd_empty: cmd is empty",
    },
    .{
        .name = "script_test_env_bad_name",
        .target = N ++ "env_bad_name",
        .text = N ++ "env_bad_name: env name \"1BAD\" is not a shell variable name",
    },
    .{
        .name = "script_test_env_sets_home",
        .target = N ++ "env_sets_home",
        .text = N ++ "env_sets_home: env sets HOME, which the action sets itself",
    },
    .{
        .name = "script_test_env_sets_zig_cache",
        .target = N ++ "env_sets_zig_cache",
        .text = N ++ "env_sets_zig_cache: env sets ZIG_GLOBAL_CACHE_DIR, which the action sets itself",
    },
    .{
        .name = "script_test_tool_name_with_slash",
        .target = N ++ "tool_name_with_slash",
        .text = N ++ "tool_name_with_slash: tool name \"a/b\" is not a file name",
    },
    .{
        .name = "script_test_src_file_and_directory",
        .target = N ++ "src_file_and_directory",
        .text = N ++ "src_file_and_directory: data destination \"d\" is both a file and the directory of \"d/inner\"",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
