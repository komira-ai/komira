//! planted_red_builds_npm_modules: the node_modules rules' planted defects
//! (tools/build/node/modules.bzl; what each target plants is written above it
//! in tools/build/tests/negative/npm_modules/BUCK). Each row's build must
//! fail on the farm and print the row's text (lib/reds.zig):
//!
//!   - npm_modules: a lockfile package with no pinned tarball, a pinned lock
//!     that disagrees with the lockfile's integrity, a tarball whose bytes
//!     have another sha512, a package.json of another name or version, a
//!     bundled package its parent's tarball lacks, a non-optional package
//!     for another os, and a download pinned at the wrong sha256;
//!   - the programs: a program node_modules lacks, a program that fails
//!     (cdk_synth with a context the stand-in refuses, and with no
//!     environment), an out_dir the program never wrote, a TypeScript type
//!     error, a failing jest test and a jest run that finds no test.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "npm_modules_package_not_pinned",
        .target = "tests//negative/npm_modules:package_not_pinned",
        .text = "fx-c@1.0.0 (node_modules/fx-c) has no pinned tarball",
    },
    .{
        .name = "npm_modules_pinned_lock_disagrees",
        .target = "tests//negative/npm_modules:pinned_lock_disagrees",
        .text = "the pinned lock says sha512-QQQQ",
    },
    .{
        .name = "npm_modules_tarball_bytes_differ",
        .target = "tests//negative/npm_modules:tarball_bytes_differ",
        .text = "node_modules: fx-b@1.0.0: the tarball is sha512-",
    },
    .{
        .name = "npm_modules_package_json_differs",
        .target = "tests//negative/npm_modules:package_json_differs",
        .text = "node_modules: fx-b@1.0.0: its package.json says fx-b@2.0.0",
    },
    .{
        .name = "npm_modules_bundled_missing",
        .target = "tests//negative/npm_modules:bundled_missing",
        .text = "is bundled but its parent's tarball holds no",
    },
    .{
        .name = "npm_modules_other_os_not_optional",
        .target = "tests//negative/npm_modules:other_os_not_optional",
        .text = "needs os [\"darwin\"] and is not optional",
    },
    .{
        .name = "npm_modules_download_sha256_differs",
        .target = "tests//negative/npm_modules:download_sha256_differs",
        .text = "Invalid sha256 digest. Expected 0000000000000000000000000000000000000000000000000000000000000000",
    },
    .{
        .name = "node_tree_program_absent",
        .target = "tests//negative/npm_modules:program_absent",
        .text = "node_modules/.bin/absent is not in negative/npm_modules/",
    },
    .{
        .name = "node_tree_synth_wrong_context",
        .target = "tests//negative/npm_modules:synth_wrong_context",
        .text = "fake cdk: context is {\"hostedZoneId\":\"Z0DUMMYZONE\",\"stage\":\"gamma\"}",
    },
    .{
        .name = "node_tree_synth_no_env",
        .target = "tests//negative/npm_modules:synth_no_env",
        .text = "fake cdk: CDK_DEFAULT_REGION is undefined",
    },
    .{
        .name = "node_tree_out_dir_not_written",
        .target = "tests//negative/npm_modules:out_dir_not_written",
        .text = "passed but wrote no absent/",
    },
    .{
        .name = "node_tree_tsc_type_error",
        .target = "tests//negative/npm_modules:type_error",
        .text = "type_error.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'.",
    },
    .{
        .name = "node_tree_jest_fails",
        .target = "tests//negative/npm_modules:jest_fails",
        .text = "Expected: 6",
    },
    .{
        .name = "node_tree_jest_finds_nothing",
        .target = "tests//negative/npm_modules:jest_finds_nothing",
        .text = "No tests found, exiting with code 1",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.reds(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
