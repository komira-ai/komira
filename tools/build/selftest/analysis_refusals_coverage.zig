//! analysis_refusals_coverage: the coverage rules' analysis refusals
//! (tools/build/mojo/coverage.bzl, coverage_branch.bzl), each with its exact
//! message: a coverage run's data clashing with a source or under buck-out/;
//! coverage_tests naming a test that does not depend on the library, has
//! args, a generated main or no coverage build; a test with a source's path;
//! an enforced shared-library gate; and a branch run's test_env setting
//! LLVM_PROFILE_FILE. Catches the buck-out check, the no-args check and the
//! LLVM_PROFILE_FILE `fail()` deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "coverage_run_data_clash",
        .target = "tests//negative/coverage:clash",
        .text = "tests//negative/coverage:clash: coverage run of tests/test_lost.mojo: the test's data destination \"tests/test_lost.mojo\" collides with its source, which a coverage run stages at \"tests/test_lost.mojo\"",
    },
    .{
        .name = "coverage_run_data_buckout",
        .target = "tests//negative/coverage:clash_buckout",
        .text = "tests//negative/coverage:clash_buckout: coverage run of tests/test_lost.mojo: the data destination \"buck-out/data.txt\" is under buck-out/, where a coverage run stages the library's sources",
    },
    .{
        .name = "coverage_gate_mojo_test_stray",
        .target = "tests//negative/coverage:covmt_stray_cov_gate",
        .text = "tests//negative/coverage:covmt_stray_cov_gate: coverage_tests of tests//negative/coverage:covmt_stray: tests//negative/coverage:test_tracer_mt does not name tests//negative/coverage:covmt_stray in its deps: a test covers a library it imports",
    },
    .{
        .name = "coverage_gate_mojo_test_args",
        .target = "tests//negative/coverage:covmt_args_cov_gate",
        .text = "tests//negative/coverage:covmt_args_cov_gate: coverage_tests of tests//negative/coverage:covmt_args: tests//negative/coverage:test_args cannot run under kcov: it has `args`, which a coverage run does not pass",
    },
    .{
        .name = "coverage_gate_mojo_test_gen",
        .target = "tests//negative/coverage:covmt_gen_cov_gate",
        .text = "tests//negative/coverage:covmt_gen_cov_gate: coverage_tests of tests//negative/coverage:covmt_gen: tests//negative/coverage:test_gen_main cannot run under kcov: its main source tests/test_gen_main.mojo is generated",
    },
    .{
        .name = "coverage_gate_mojo_test_nocov",
        .target = "tests//negative/coverage:covmt_nocov_cov_gate",
        .text = "tests//negative/coverage:covmt_nocov_cov_gate: coverage_tests of tests//negative/coverage:covmt_nocov: tests//negative/coverage:test_nocov is not a mojo_test with a coverage build",
    },
    .{
        .name = "coverage_gate_test_path",
        .target = "tests//negative/coverage:testpath",
        .text = "tests//negative/coverage:testpath: coverage gate: the test lostlib/value.mojo has the path of a source of the library",
    },
    .{
        .name = "coverage_shared_lib_enforce",
        .target = "tests//negative/coverage:covso_enforce",
        .text = "tests//negative/coverage:covso_enforce: a mojo_shared_lib's coverage gate is reported, never enforced (COVERAGE_SHARED_LIB_MODE, tools/build/coverage/policy.bzl): mode `enforce` is refused",
    },
    .{
        .name = "coverage_branch_test_env",
        .target = "tests//negative/coverage:branchenv",
        .text = "tests//negative/coverage:branchenv: branch coverage of tests/test_one.mojo: test_env sets LLVM_PROFILE_FILE, which a branch coverage run sets itself (where the test's profile is written)",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
