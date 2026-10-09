# shellcheck shell=bash
# rust_tests.sh -- test 22 (Rust rules), 35 (external tests). Sourced by run_tests.sh,
# whose pass/fail/expect_* helpers and $BUCK2, $LOG, $ROOT it uses.

# 22. The example binary uses prost's derive macro, so it compiles registry
#     crates, a proc-macro and the zig link; its run check compares stdout
#     byte for byte. A binary using prost without depending on it fails to
#     compile: crates reach rustc only through `deps`.
expect_green rust_example "//tools/build/examples/rust:prost_roundtrip[run_check]"
check_executor rust_example
expect_red rust_missing_dep "unresolved import \`prost\`" tests//negative/rust_missing_dep:main

# 22, host floor. rustc's host floor. Every NEEDED entry of bin/rustc and of each shared
#      library in the sysroot is either glibc's or a file in a directory its
#      own $ORIGIN-relative run path names, and no run path is absolute: the
#      compiler takes nothing from the worker except glibc.
RUSTC_GLIBC="ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1"
if ! command -v readelf > /dev/null; then
    fail "rust host floor: readelf is not installed; cannot read the sysroot"
elif ! "$BUCK2" build komira//tools/build/toolchains/rust:sysroot --materializations all --show-full-simple-output > "$LOG/rust_sysroot.txt" 2> "$LOG/rust_sysroot.log"; then
    fail "rust host floor: cannot materialize komira//tools/build/toolchains/rust:sysroot (see $LOG/rust_sysroot.log)"
else
    sysroot=$(tail -n 1 "$LOG/rust_sysroot.txt")
    problems="" objects=0 needs=0
    for f in "$sysroot/bin/rustc" "$sysroot"/lib/*.so*; do
        # lib/ also holds a linker script named like a library (text, 42 bytes).
        [ "$(head -c 4 "$f" | od -An -c | tr -d ' ')" = '177ELF' ] || continue
        if ! dyn=$(readelf -d "$f" 2> /dev/null); then
            problems="$problems ${f#"$sysroot"/}:unreadable"
            continue
        fi
        objects=$((objects + 1))
        dirs=""
        for rp in $(printf '%s\n' "$dyn" | sed -nE 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]$/\2/p' | tr ':' ' '); do
            case "$rp" in
                '$ORIGIN'*) dirs="$dirs ${f%/*}${rp#'$ORIGIN'}" ;;
                *) problems="$problems ${f#"$sysroot"/}:runpath=$rp" ;;
            esac
        done
        for need in $(printf '%s\n' "$dyn" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]$/\1/p'); do
            needs=$((needs + 1))
            case " $RUSTC_GLIBC " in *" $need "*) continue ;; esac
            found=0
            for d in $dirs; do [ -s "$d/$need" ] && found=1; done
            [ "$found" = 1 ] || problems="$problems ${f#"$sysroot"/}:$need"
        done
    done
    if [ "$objects" -lt 3 ] || [ "$needs" = 0 ]; then
        fail "rust host floor: read $objects objects and $needs NEEDED entries under $sysroot; expected rustc and its libraries"
    elif [ -n "$problems" ]; then
        fail "rust host floor: taken from the worker or unresolvable in the sysroot:$problems"
    else
        pass "rust host floor: $needs NEEDED entries of $objects sysroot objects resolve to glibc or the sysroot"
    fi
fi

# 35, external tests. A rust_library's `test_srcs` (tests/*.rs) are compiled
#     against its ungated rlib and run; their markers gate the library. In
#     tests//negative/rust_test, `ext` (its test passes, using a module under
#     tests/) and a binary linking it build; `ext_red` (one external test
#     fails) and a binary linking it cannot be built, the harness reporting
#     `1 passed; 1 failed`. Refused at analysis, each naming its cause:
#     `test_srcs` with no tests/<name>.rs crate (`ext_no_crate`), a file
#     outside tests/ (`ext_outside`), a tests/<name>.rs whose name is not a
#     Rust identifier (`ext_bad_name`), a file directly under tests/ that is
#     not .rs (`ext_not_rs`). A library with both `tests` and `test_srcs` is
#     gated by the markers of both: `both` (each passes) builds; `both_red`
#     (the external test passes, the unit test fails) and `both_ext_red` (the
#     unit test passes, an external test fails) cannot be built.
RX=tests//negative/rust_test
expect_green rust_ext_green "$RX:ext" "$RX:ext_consumer"
expect_red rust_ext_red "GATED TEST FAILED: $RX:ext_red tests/ext_fail.rs" "$RX:ext_red"
expect_red rust_ext_red_count "1 passed; 1 failed" "$RX:ext_red"
expect_red rust_ext_red_consumer "GATED TEST FAILED: $RX:ext_red tests/ext_fail.rs" "$RX:ext_red_consumer"
expect_red rust_ext_no_crate "test_srcs has no test crate" "$RX:ext_no_crate"
expect_red rust_ext_outside "test_srcs \`src/ext_misplaced.rs\` is not under tests/" "$RX:ext_outside"
expect_red rust_ext_bad_name "test_srcs \`tests/1bad.rs\` does not name a Rust identifier" "$RX:ext_bad_name"
expect_red rust_ext_not_rs "test_srcs \`tests/ext_data.txt\` is not a .rs file" "$RX:ext_not_rs"
expect_green rust_ext_both "$RX:both"
expect_red rust_ext_both_red "GATED TEST FAILED: $RX:red" "$RX:both_red"
expect_red rust_ext_both_ext_red "GATED TEST FAILED: $RX:both_ext_red tests/ext_fail.rs" "$RX:both_ext_red"
