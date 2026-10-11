//! analysis_refusals_mojo: the Mojo rules' analysis refusals, each with its
//! exact message (tools/build/mojo/defs.bzl, test_runtime.bzl, test_deps.bzl,
//! defines.bzl, test_limit.bzl).
//!
//!   - a binary naming a library's `[ungated]` sub-target in `deps` (no gate
//!     bypass), and a `deps` entry that is neither a Mojo package nor a C/C++
//!     library: catches `[ungated]` returning MojoInfo, or such deps skipped;
//!   - a mojo_shared_lib with empty `exports`: catches the empty-exports
//!     `fail()` deleted;
//!   - test_data and test_deps refusals (a bad data destination, a
//!     destination both file and directory, data keyed to no test, an env
//!     name the runner owns or that is no shell name, a test_deps entry that
//!     is no package or is also in deps): catches the shell-name check of
//!     test_runtime.bzl deleted;
//!   - assert level, defines and memory cap refusals: catches the
//!     define-twice `fail()` deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "gate_bypass_refused",
        .target = "tests//negative/libgate_bad:bypass_consumer",
        .text = " provides neither MojoInfo (a Mojo package) nor MergedLinkInfo (a C/C++ library)",
        .also = &.{ "tests//negative/libgate_bad:bypass_consumer (", ": dep tests//negative/libgate_bad:libgate_bad[ungated] (" },
    },
    .{
        .name = "sharedlib_empty_exports_refused",
        .target = "tests//negative/shared_lib:empty_exports",
        .text = "`exports` is empty: a gate that expects no symbol checks nothing",
        .also = &.{ "tests//negative/shared_lib:empty_exports (" },
    },
    .{
        .name = "td_bad_dest",
        .target = "tests//negative/test_data:bad_dest",
        .text = "tests//negative/test_data:bad_dest: test_data[\"tests/test_reads_declared.mojo\"]: data destination \"../escape.txt\" holds an empty, `.` or `..` segment",
    },
    .{
        .name = "td_bad_dest_clash",
        .target = "tests//negative/test_data:bad_dest_clash",
        .text = "tests//negative/test_data:bad_dest_clash: test_data[\"tests/test_reads_declared.mojo\"]: data destination \"a\" is both a file and the directory of \"a/b.txt\"",
    },
    .{
        .name = "td_bad_data_entry",
        .target = "tests//negative/test_data:bad_data_entry",
        .text = "tests//negative/test_data:bad_data_entry: test_data[\"tests/test_nope.mojo\"]: not a test_srcs entry (entries: tests/test_reads_declared.mojo). Data keyed to no test is staged for nothing.",
    },
    .{
        .name = "td_bad_env_owned",
        .target = "tests//negative/test_data:bad_env_owned",
        .text = "tests//negative/test_data:bad_env_owned: test_env: env sets TEST_TMPDIR, which the test runner sets itself (runner-owned: PATH, LD_LIBRARY_PATH, LD_PRELOAD, DYLD_LIBRARY_PATH, DYLD_FALLBACK_LIBRARY_PATH, DYLD_INSERT_LIBRARIES, TMPDIR, TEST_TMPDIR, HOME, PWD)",
    },
    .{
        .name = "td_test_deps_not_mojo",
        .target = "tests//negative/test_deps:not_mojo",
        .text = "tests//negative/test_deps:not_mojo: test_deps entry tests//negative/test_deps:not_a_package is not a Mojo package (a mojo_library); test_deps holds test-support packages only",
    },
    .{
        .name = "td_test_deps_also_in_deps",
        .target = "tests//negative/test_deps:also_in_deps",
        .text = "tests//negative/test_deps:also_in_deps: tests//functional/test_deps:tdhelper is in both deps and test_deps; a test already sees every dep, so name it once, in deps",
    },
    .{
        .name = "td_bad_env_name",
        .target = "tests//negative/test_data:bad_env_name",
        .text = "tests//negative/test_data:bad_env_name: env: env name \"NOT-A-NAME\" is not a shell variable name",
    },
    .{
        .name = "assert_level_bad_level",
        .target = "tests//negative/assert_level:bad_level",
        .text = "tests//negative/assert_level:bad_level: test_assert_level `fast` is not one of none, warn, safe, all",
    },
    .{
        .name = "assert_level_bad_binary_level",
        .target = "tests//negative/assert_level:bad_binary_level",
        .text = "tests//negative/assert_level:bad_binary_level: assert_level `off` is not one of none, warn, safe, all",
    },
    .{
        .name = "assert_level_define_assert",
        .target = "tests//negative/assert_level:define_assert",
        .text = "tests//negative/assert_level:define_assert: test_defines sets ASSERT; set `test_assert_level` instead",
    },
    .{
        .name = "assert_level_define_not_identifier",
        .target = "tests//negative/assert_level:define_not_identifier",
        .text = "tests//negative/assert_level:define_not_identifier: defines entry \"1ST=x\" is not NAME or NAME=VALUE with NAME an identifier",
    },
    .{
        .name = "assert_level_define_twice",
        .target = "tests//negative/assert_level:define_twice",
        .text = "tests//negative/assert_level:define_twice: defines sets KOMIRA_X twice",
    },
    .{
        .name = "assert_level_bad_cap",
        .target = "tests//negative/assert_level:bad_cap",
        .text = "tests//negative/assert_level:bad_cap: test_memory_cap_mib is -1; it must be a number of MiB, or 0 for no cap",
    },
    .{
        .name = "c_dep_kind",
        .target = "tests//negative/c_deps:bad_dep",
        .text = " provides neither MojoInfo (a Mojo package) nor MergedLinkInfo (a C/C++ library)",
        .also = &.{ "tests//negative/c_deps:bad_dep (", ": dep tests//negative/c_deps:not_a_library (" },
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
