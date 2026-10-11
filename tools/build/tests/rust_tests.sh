# shellcheck shell=bash
# rust_tests.sh -- test 22 (Rust rules), 35 (external tests). Sourced by run_tests.sh,
# whose pass/fail/expect_* helpers and $BUCK2, $LOG, $ROOT it uses.

# 22. A binary using prost without depending on it fails to compile: crates
#     reach rustc only through `deps`. (The example binary using prost's
#     derive macro, //tools/build/examples/rust:prost_roundtrip, is in the
#     gate; its run check is a validation of the binary.)
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
#     against its ungated rlib and run; their markers gate the library. The
#     greens, each held to its marker list, are in the gate
#     (komira//tools/build/examples/rust/ext). In tests//negative/rust_test,
#     `ext_red` (one external test fails) and a binary linking it cannot be
#     built, the harness reporting
#     `1 passed; 1 failed`. (The test_srcs refusals at analysis are
#     //tools/build/selftest:analysis_refusals_rust.) A library with both `tests` and `test_srcs` is
#     gated by the markers of both: `both_red`
#     (the external test passes, the unit test fails) and `both_ext_red` (the
#     unit test passes, an external test fails) cannot be built.
RX=tests//negative/rust_test
expect_red rust_ext_red "GATED TEST FAILED: $RX:ext_red tests/ext_fail.rs" "$RX:ext_red"
expect_red rust_ext_red_count "1 passed; 1 failed" "$RX:ext_red"
expect_red rust_ext_red_consumer "GATED TEST FAILED: $RX:ext_red tests/ext_fail.rs" "$RX:ext_red_consumer"
expect_red rust_ext_both_red "GATED TEST FAILED: $RX:red" "$RX:both_red"
expect_red rust_ext_both_ext_red "GATED TEST FAILED: $RX:both_ext_red tests/ext_fail.rs" "$RX:both_ext_red"
