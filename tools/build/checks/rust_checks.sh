# rust_checks.sh -- check 22, the Rust rules. Sourced by run_checks.sh,
# whose pass/fail/expect_* helpers and $BUCK2, $LOG, $ROOT it uses.

# 22. The example binary uses prost's derive macro, so it compiles registry
#     crates, a proc-macro and the zig link; its run check compares stdout
#     byte for byte. A binary using prost without depending on it fails to
#     compile: crates reach rustc only through `deps`.
expect_green rust_example "//tools/build/examples/rust:prost_roundtrip[run_check]"
check_remote rust_example
expect_red rust_missing_dep "unresolved import \`prost\`" checks//rust_missing_dep:main
