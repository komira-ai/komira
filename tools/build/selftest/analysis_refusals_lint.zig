//! analysis_refusals_lint: the lints' refusals.
//!
//!   - All five copies of the files xor (pointer_lint, public_boundary,
//!     readme_api_coverage, surface_capability_matrix, test_weld): naming
//!     neither `tree` nor `files`, or both, is refused at analysis. Catches
//!     any one of the five `fail()`s deleted.
//!   - The surface capability matrix in a scratch tree (scratch.zig): a row
//!     naming a target that does not exist, and a row naming a test
//!     incompatible with the lint's platform under a package pattern, are
//!     each refused (their fixtures, tools/build/tests/negative/
//!     surface_capability_matrix/{dangling,incompatible}.BUCK, are copied
//!     into BUCK files of the scratch tree only: loadable in the checkout,
//!     they would fail every query over tests//...). Catches the matrix's
//!     dependencies made soft.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "pointer_lint_no_tree",
        .target = "tests//negative/pointer_lint:no_tree",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "pointer_lint tests//negative/pointer_lint:no_tree (" },
    },
    .{
        .name = "pointer_lint_both_tree_and_files",
        .target = "tests//negative/pointer_lint:both_tree_and_files",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "pointer_lint tests//negative/pointer_lint:both_tree_and_files (" },
    },
    .{
        .name = "public_boundary_no_tree",
        .target = "tests//negative/public_boundary:no_tree",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "public_boundary tests//negative/public_boundary:no_tree (" },
    },
    .{
        .name = "public_boundary_both_tree_and_files",
        .target = "tests//negative/public_boundary:both_tree_and_files",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "public_boundary tests//negative/public_boundary:both_tree_and_files (" },
    },
    .{
        .name = "readme_api_coverage_no_tree",
        .target = "tests//negative/readme_api_coverage:no_tree",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "readme_api_coverage tests//negative/readme_api_coverage:no_tree (" },
    },
    .{
        .name = "readme_api_coverage_both_tree_and_files",
        .target = "tests//negative/readme_api_coverage:both_tree_and_files",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "readme_api_coverage tests//negative/readme_api_coverage:both_tree_and_files (" },
    },
    .{
        .name = "test_weld_no_tree",
        .target = "tests//negative/test_weld:no_tree",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "test_weld tests//negative/test_weld:no_tree (" },
    },
    .{
        .name = "test_weld_both_tree_and_files",
        .target = "tests//negative/test_weld:both_tree_and_files",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "test_weld tests//negative/test_weld:both_tree_and_files (" },
    },
    .{
        .name = "surface_capability_matrix_no_tree",
        .target = "tests//negative/surface_capability_matrix:no_tree",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "surface_capability_matrix tests//negative/surface_capability_matrix:no_tree (" },
    },
    .{
        .name = "surface_capability_matrix_both_tree_and_files",
        .target = "tests//negative/surface_capability_matrix:both_tree_and_files",
        .text = "name the files in exactly one of `tree` and `files`",
        .also = &.{ "surface_capability_matrix tests//negative/surface_capability_matrix:both_tree_and_files (" },
    },
};

const E = "tests//functional/surface_capability_matrix/src/tests/e2e";
const D = "tools/build/tests/negative/surface_capability_matrix";

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
    const tree = c.scratchTree() catch return;
    try lib.scratch.copy(tree, D ++ "/dangling.BUCK", D ++ "/dangling/BUCK");
    try lib.scratch.copy(tree, D ++ "/incompatible.BUCK", D ++ "/incompatible/BUCK");
    try c.refusals(&.{
        .{
            .name = "surface_capability_matrix_dangling",
            .target = "tests//negative/surface_capability_matrix/dangling:dangling",
            .text = "Unknown target `test_join_left` from package `" ++ E ++ "/polars_e2e`",
            .cwd = tree.root,
        },
        .{
            .name = "surface_capability_matrix_incompatible",
            .target = "tests//negative/surface_capability_matrix/incompatible:",
            .text = "because its transitive dep " ++ E ++ "/pandas_e2e:test_mac",
            .cwd = tree.root,
        },
    });
}


pub fn main() u8 {
    return lib.main(body);
}
