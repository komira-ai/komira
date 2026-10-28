//! planted_red_builds_node: the Node.js rules' planted defects that fail in
//! an action (tools/build/node/defs.bzl; what each target plants is written
//! above it in tools/build/tests/negative/node/BUCK). Each row's build must
//! fail on the farm and print the row's text (lib/reds.zig):
//!
//!   - node_test's verdict: a failing script fails its target with the
//!     script's own error; a wrong expected error, an error printed on
//!     stdout only, an expected failure that passed, and expect_error
//!     that differs only in case or is written as a pattern match nothing;
//!   - esbuild fails on an import it cannot resolve;
//!   - npm_package's pins: an integrity that is not `sha512-<base64>` or
//!     differs (to the last byte), no package.json, a name or version that
//!     differs or is a prefix, nested or absent, a version that is a number,
//!     an exe that does not run or prints another version;
//!   - node_dist's archive and version checks;
//!   - c_shared_lib compiles with `-Wall -Werror`;
//!   - node_binding_test: a failing test, a file that registers no test and a
//!     skipped test fail though node may exit 0, an addon that is not staged
//!     fails its test, and an addon that returns the wrong number fails it.
//!
//! The analysis refusals of the same rules are analysis_refusals_node.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "node_script_fails",
        .target = "tests//negative/node:script_fails",
        .text = "the negative fixture fails its own assertion",
    },
    .{
        .name = "node_error_not_on_stderr",
        .target = "tests//negative/node:error_not_on_stderr",
        .text = "failed, but its stderr does not hold: text the script never prints",
    },
    .{
        .name = "node_error_on_stdout",
        .target = "tests//negative/node:error_on_stdout",
        .text = "failed, but its stderr does not hold: printed on stdout only",
    },
    .{
        .name = "node_expected_fail_passed",
        .target = "tests//negative/node:expected_fail_passed",
        .text = "exited 0; it was expected to fail with: any error",
    },
    .{
        .name = "node_error_other_case",
        .target = "tests//negative/node:error_other_case",
        .text = "stderr does not hold: THE NEGATIVE FIXTURE FAILS ITS OWN ASSERTION",
    },
    .{
        .name = "node_error_as_pattern",
        .target = "tests//negative/node:error_as_pattern",
        .text = "stderr does not hold: negative fixture.fails",
    },
    .{
        .name = "node_unresolved_import",
        .target = "tests//negative/node:unresolved_import",
        .text = "Could not resolve \"./absent.mjs\"",
    },
    .{
        .name = "node_integrity_not_sha512",
        .target = "tests//negative/node:integrity_not_sha512",
        .text = "npm_package: tslib: integrity sha256-AAAA is not sha512-<base64>",
    },
    .{
        .name = "node_integrity_empty",
        .target = "tests//negative/node:integrity_empty",
        .text = "npm_package: tslib: integrity sha512- is not sha512-<base64>",
    },
    .{
        .name = "node_integrity_not_leading",
        .target = "tests//negative/node:integrity_not_leading",
        .text = "is not sha512-<base64>",
    },
    .{
        .name = "node_integrity_differs",
        .target = "tests//negative/node:integrity_differs",
        .text = "npm_package: tslib: the sha512 of",
    },
    .{
        .name = "node_integrity_last_byte",
        .target = "tests//negative/node:integrity_last_byte",
        .text = "npm_package: tslib: the sha512 of",
    },
    .{
        .name = "node_integrity_repeated_rows",
        .target = "tests//negative/node:integrity_repeated_rows",
        .text = "the pinned integrity sha512-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA== is 00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    },
    .{
        .name = "node_no_package_json",
        .target = "tests//negative/node:no_package_json",
        .text = "holds no package/package.json",
    },
    .{
        .name = "node_name_differs",
        .target = "tests//negative/node:name_differs",
        .text = "npm_package: tslib2: package.json of",
    },
    .{
        .name = "node_name_differs_key",
        .target = "tests//negative/node:name_differs",
        .text = "does not state \"name\":\"tslib2\"",
    },
    .{
        .name = "node_name_prefix",
        .target = "tests//negative/node:name_prefix",
        .text = "does not state \"name\":\"tsli\"",
    },
    .{
        .name = "node_version_differs",
        .target = "tests//negative/node:version_differs",
        .text = "does not state \"version\":\"2.8.0\"",
    },
    .{
        .name = "node_version_prefix",
        .target = "tests//negative/node:version_prefix",
        .text = "does not state \"version\":\"2.8\"",
    },
    .{
        .name = "node_exe_does_not_run",
        .target = "tests//negative/node:exe_does_not_run",
        .text = "npm_package: tslib: package.json does not run",
    },
    .{
        .name = "node_name_nested",
        .target = "tests//negative/node:name_nested",
        .text = "does not state \"name\":\"komira-fixture\" at its top level; its top-level \"name\" is \"komira-fixture-other\"",
    },
    .{
        .name = "node_name_absent",
        .target = "tests//negative/node:name_absent",
        .text = "does not state \"name\":\"komira-fixture\" at its top level; its top-level \"name\" is absent",
    },
    .{
        .name = "node_version_nested",
        .target = "tests//negative/node:version_nested",
        .text = "does not state \"version\":\"1.0.0\" at its top level; its top-level \"version\" is \"1.0.1\"",
    },
    .{
        .name = "node_version_number",
        .target = "tests//negative/node:version_number",
        .text = "does not state \"version\":\"1\" at its top level; its top-level \"version\" is 1",
    },
    .{
        .name = "node_nested_distractors",
        .target = "tests//negative/node:nested_distractors",
        .text = "npm_package: komira-fixture: package.json does not run",
    },
    .{
        .name = "node_exe_other_version",
        .target = "tests//negative/node:exe_other_version",
        .text = "npm_package: komira-fixture: bin/echo --version prints --version, the pin says 1.0.0",
    },
    .{
        .name = "node_dist_version_differs",
        .target = "tests//negative/node:version_differs_node",
        .text = "is v24.21.0, the pin says v24.20.0",
    },
    .{
        .name = "node_dist_version_prefix",
        .target = "tests//negative/node:version_prefix_node",
        .text = "is v24.21.0, the pin says v24.21",
    },
    .{
        .name = "node_dist_version_suffix",
        .target = "tests//negative/node:version_suffix_node",
        .text = "is v24.21.0, the pin says v4.21.0",
    },
    .{
        .name = "node_dist_not_node",
        .target = "tests//negative/node:not_node",
        .text = "holds no package/bin/node or package/include/node/node_api.h",
    },
    .{
        .name = "node_dist_no_bin_node",
        .target = "tests//negative/node:no_bin_node",
        .text = "holds no node-x/bin/node or node-x/include/node/node_api.h",
    },
    .{
        .name = "node_dist_no_header",
        .target = "tests//negative/node:no_header",
        .text = "holds no node-x/bin/node or node-x/include/node/node_api.h",
    },
    .{
        .name = "node_dist_header_is_dir",
        .target = "tests//negative/node:header_is_dir",
        .text = "holds no node-x/bin/node or node-x/include/node/node_api.h",
    },
    .{
        .name = "node_dist_not_executable",
        .target = "tests//negative/node:node_not_executable",
        .text = "holds no node-x/bin/node or node-x/include/node/node_api.h",
    },
    .{
        .name = "node_dist_does_not_run",
        .target = "tests//negative/node:node_does_not_run",
        .text = "/bin/node does not run",
    },
    .{
        .name = "node_binding_fails",
        .target = "tests//negative/node:binding_fails",
        .text = "binding_test: node --test exited 1",
    },
    .{
        .name = "node_binding_no_test",
        .target = "tests//negative/node:binding_no_test",
        .text = "binding_no_test.test.mjs registers no test of its own",
    },
    .{
        .name = "node_binding_skipped",
        .target = "tests//negative/node:binding_skipped",
        .text = "a test was skipped or left todo",
    },
    .{
        .name = "node_binding_addon_missing",
        .target = "tests//negative/node:binding_addon_missing",
        .text = "answer.node was not built or staged",
    },
    .{
        .name = "node_binding_addon_wrong",
        .target = "tests//negative/node:binding_addon_wrong",
        .text = "answer() must return 42",
    },
    .{
        .name = "node_c_warns",
        .target = "tests//negative/node:warns",
        .text = "error: unused variable 'unused_on_purpose'",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.reds(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
