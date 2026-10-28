//! analysis_refusals_node: the Node.js rules' analysis refusals
//! (tools/build/node/defs.bzl), each with its exact message: an empty
//! expect_error or exe, a source or bundle entry listed twice, a data
//! destination that is a source or a package, conflicting pins, and a
//! package in its own deps. Catches the staged-twice check deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "node_expect_error_empty",
        .target = "tests//negative/node:expect_error_empty",
        .text = "tests//negative/node:expect_error_empty: expect_error is empty: name the text the script must print on stderr, or leave expect_error out",
    },
    .{
        .name = "node_exe_empty",
        .target = "tests//negative/node:exe_empty",
        .text = "tests//negative/node:exe_empty: exe is empty: name the package's executable, or leave exe out",
    },
    .{
        .name = "node_src_listed_twice",
        .target = "tests//negative/node:src_listed_twice",
        .text = "tests//negative/node:src_listed_twice: pass.js is listed twice",
    },
    .{
        .name = "node_data_is_source",
        .target = "tests//negative/node:data_is_source",
        .text = "tests//negative/node:data_is_source: data destination pass.js is also a source",
    },
    .{
        .name = "node_data_is_package",
        .target = "tests//negative/node:data_is_package",
        .text = "tests//negative/node:data_is_package: data destination node_modules/tslib is also a package of deps",
    },
    .{
        .name = "node_version_conflict",
        .target = "tests//negative/node:version_conflict",
        .text = "tests//negative/node:version_conflict: tslib is pinned at 1.0.0 and at 2.0.0 in its deps",
    },
    .{
        .name = "node_bundle_listed_twice",
        .target = "tests//negative/node:bundle_listed_twice",
        .text = "tests//negative/node:bundle_listed_twice: bundle/main.mjs is listed twice",
    },
    .{
        .name = "node_own_dep",
        .target = "tests//negative/node:own_dep",
        .text = "tests//negative/node:own_dep: tslib is in its own deps",
    },
    .{
        .name = "node_binding_no_srcs",
        .target = "tests//negative/node:binding_no_srcs",
        .text = "tests//negative/node:binding_no_srcs: srcs is empty: name the test files node --test runs",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
