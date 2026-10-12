//! analysis_refusals_rust: rust_library's test_srcs refusals
//! (tools/build/rust/defs.bzl), each with its exact message: no test crate,
//! a file outside tests/, a name that is no Rust identifier, and a file that
//! is not .rs. Catches the `.rs` check deleted.
const std = @import("std");
const lib = @import("lib/lib.zig");

const ROWS = [_]lib.Row{
    .{
        .name = "rust_ext_no_crate",
        .target = "tests//negative/rust_test:ext_no_crate",
        .text = "tests//negative/rust_test:ext_no_crate: test_srcs has no test crate (a file tests/<name>.rs)",
    },
    .{
        .name = "rust_ext_outside",
        .target = "tests//negative/rust_test:ext_outside",
        .text = "tests//negative/rust_test:ext_outside: test_srcs `src/ext_misplaced.rs` is not under tests/",
    },
    .{
        .name = "rust_ext_bad_name",
        .target = "tests//negative/rust_test:ext_bad_name",
        .text = "tests//negative/rust_test:ext_bad_name: test_srcs `tests/1bad.rs` does not name a Rust identifier",
    },
    .{
        .name = "rust_ext_not_rs",
        .target = "tests//negative/rust_test:ext_not_rs",
        .text = "tests//negative/rust_test:ext_not_rs: test_srcs `tests/ext_data.txt` is not a .rs file",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
