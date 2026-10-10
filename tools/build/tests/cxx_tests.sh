# shellcheck shell=bash
# cxx_tests.sh -- tests of C/C++ libraries in Mojo builds. Sourced by
# tools/build/tests/run_tests.sh (uses its BUCK2, LOG, pass, fail, expect_green,
# expect_red and resolve); not run on its own.
#
#  20. C/C++ dependencies of Mojo targets (the prelude's cxx_library, built
#      with toolchains//:cxx):
#      - a binary calling a C function links and prints the C result when
#        the library is in `deps`, and the link fails on the undefined symbol
#        when it is not (tests//functional/c_deps);
#      - `deps` refuses a target that is neither a Mojo package nor a C/C++
#        library;
#      - gated library tests and mojo_tests recording source locations build
#        (the staging directory is stripped from them);
#      - C compiles and archives, and the Mojo targets depending on them,
#        resolve to the linux execution platform (`linux-x86_64`);
#      - a binary linking C++ (snappy, with zig's static libc++) exports no
#        dynamic symbol, so its C++ runtime cannot interpose on the
#        libstdc++.so.6 the Mojo runtime loads, and the libc++ it carries is
#        really in it (the check is not vacuous);
#      - an unconfigured query over a C/C++ library answers: the prelude's
#        C/C++ toolchain select names toolchains//:cxx_no_default_deps on
#        the branch no configured build takes, and uquery follows it.

expect_green c_dep_linked "tests//functional/c_deps:c_linked" "tests//functional/c_deps:c_linked[run_check]"
expect_red c_dep_missing "undefined symbol: komira_example_add" tests//negative/c_deps:c_missing
expect_red c_dep_kind "provides neither MojoInfo" tests//negative/c_deps:bad_dep
# Test builds strip the staging directory from the source locations they
# record: test_cadd (a gated library test) and test_add_direct (a mojo_test)
# use assert_equal on Int32 and index a List, which record them. Without
# -strip-file-prefix in mojo_wrapper.sh both fail with exit 4 on the worker's
# absolute path (test_hellopkg does not record one).
expect_green test_source_paths //tools/build/examples/cshim:cadd //tools/build/examples/cshim:test_add_direct

# Unconfigured queries follow every select branch, including the prelude's
# never-taken `toolchains//:cxx_no_default_deps`; without that target in the
# toolchains cell this fails with `Unknown target `cxx_no_default_deps``. The
# label must be in the answer, or the query did not traverse the select.
if ! "$BUCK2" uquery 'deps(//tools/build/examples/cshim:cadd_user)' > "$LOG/cxx_uquery.txt" 2> "$LOG/cxx_uquery.log"; then
    fail "C unconfigured query: uquery deps(cshim:cadd_user) failed: $(grep -m 1 -o 'Unknown target .*' "$LOG/cxx_uquery.log") (see $LOG/cxx_uquery.log)"
elif ! grep -qx 'toolchains//:cxx_no_default_deps' "$LOG/cxx_uquery.txt"; then
    fail "C unconfigured query: deps(cshim:cadd_user) does not reach toolchains//:cxx_no_default_deps (see $LOG/cxx_uquery.txt)"
else
    pass "C unconfigured query: uquery deps of a C/C++ user answers, through toolchains//:cxx_no_default_deps"
fi

C_PLATFORMS="
komira//tools/build/examples/cshim:add komira//tools/build/platforms:linux-x86_64
komira//third_party/snappy:snappy komira//tools/build/platforms:linux-x86_64
komira//third_party/snappy:src komira//tools/build/platforms:linux-x86_64
komira//tools/build/examples/cshim:cadd komira//tools/build/platforms:linux-x86_64
komira//tools/build/examples/snappy:test_snappy komira//tools/build/platforms:linux-x86_64"
want=$(printf '%s\n' "$C_PLATFORMS" | sed '/^$/d' | LC_ALL=C sort)
# shellcheck disable=SC2046 # one target label per line, split into arguments on purpose
if ! got=$(resolve c_platforms $(printf '%s\n' "$want" | cut -d' ' -f1)); then
    fail "C exec platforms: audit failed (see $LOG/c_platforms.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$want" ]; then
    fail "C exec platforms: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got" | LC_ALL=C sort) | grep '^>' | tr '\n' ' ') (see $LOG/c_platforms.txt)"
else
    pass "C exec platforms: C/C++ targets and their Mojo users on linux-x86_64"
fi

if ! "$BUCK2" build //tools/build/examples/snappy:test_snappy --materializations all --show-full-simple-output > "$LOG/snappy_bin.txt" 2> "$LOG/snappy_bin.log"; then
    fail "C++ runtime: cannot build //tools/build/examples/snappy:test_snappy (see $LOG/snappy_bin.log)"
else
    bin=$(tail -n 1 "$LOG/snappy_bin.txt")
    readelf --dyn-syms -W "$bin" > "$LOG/snappy_dynsym.txt" 2>&1
    # Defined dynamic symbols: the section index column is not UND.
    exported=$(awk '$1 ~ /^[0-9]+:$/ && $7 != "UND" && $8 != "" { print $8 }' "$LOG/snappy_dynsym.txt")
    if ! grep -q 'Symbol table' "$LOG/snappy_dynsym.txt"; then
        fail "C++ runtime: readelf read no dynamic symbol table from $bin"
    elif ! grep -qa 'libc++abi' "$bin"; then
        fail "C++ runtime: $bin carries no libc++abi; the C++ library was not linked as expected"
    elif [ -n "$exported" ]; then
        fail "C++ runtime: $bin exports $(printf '%s\n' "$exported" | wc -l | tr -d ' ') dynamic symbols, e.g. $(printf '%s\n' "$exported" | head -n 3 | tr '\n' ' ')"
    else
        pass "C++ runtime: $bin links libc++ statically and exports no dynamic symbol"
    fi
fi
