//! analysis_refusals_rust: rust_library's test_srcs refusals
//! (tools/build/rust/defs.bzl), each with its exact message: no test crate,
//! a file outside tests/, a name that is no Rust identifier, and a file that
//! is not .rs. Catches the `.rs` check deleted. Also the refusals of the
//! Cargo-driven attributes (env, patch, proc_macro_extern), each with its
//! message.
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
    .{
        .name = "rust_cargo_env_reserved",
        .target = "tests//negative/rust_cargo:refuse_env_reserved",
        .text = "tests//negative/rust_cargo:refuse_env_reserved: env `PATH` is set by the compile wrapper and cannot be overridden",
    },
    .{
        .name = "rust_cargo_env_name",
        .target = "tests//negative/rust_cargo:refuse_env_name",
        .text = "tests//negative/rust_cargo:refuse_env_name: env name `A-B` is not a variable name",
    },
    .{
        .name = "rust_cargo_patch_key",
        .target = "tests//negative/rust_cargo:refuse_patch_key",
        .text = "tests//negative/rust_cargo:refuse_patch_key: patch has no `subs`; its keys are copy, sub and add",
    },
    .{
        .name = "rust_cargo_patch_sub",
        .target = "tests//negative/rust_cargo:refuse_patch_sub",
        .text = "tests//negative/rust_cargo:refuse_patch_sub: every patch.sub entry needs a string `to`",
    },
    .{
        .name = "rust_cargo_extern_not_proc_macro",
        .target = "tests//negative/rust_cargo:refuse_extern_not_proc_macro",
        .text = "tests//negative/rust_cargo:refuse_extern_not_proc_macro: proc_macro_extern is for a proc-macro crate; set proc_macro = True",
    },
};

fn body(c: *lib.Ctx) !void {
    try c.refusals(&ROWS);
}

pub fn main() u8 {
    return lib.main(body);
}
