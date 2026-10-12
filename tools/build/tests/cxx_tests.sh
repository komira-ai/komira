# shellcheck shell=bash
# cxx_tests.sh -- tests of C/C++ libraries in Mojo builds. Sourced by
# tools/build/tests/run_tests.sh (uses its BUCK2, LOG, pass, fail, expect_green
# and expect_red); not run on its own.
#
#  20. C/C++ dependencies of Mojo targets (the prelude's cxx_library, built
#      with toolchains//:cxx):
#      - the link fails on the undefined symbol when the C library is not in
#        `deps` (a binary calling the C function with it in `deps` links and
#        prints the C result: tests//functional/c_deps:c_linked, whose run
#        check is a validation, in the gate);
#      - a binary linking C++ (snappy, with zig's static libc++) exports no
#        dynamic symbol, so its C++ runtime cannot interpose on the
#        libstdc++.so.6 the Mojo runtime loads, and the libc++ it carries is
#        really in it (the check is not vacuous).
#      `deps` refusing a target that is neither a Mojo package nor a C/C++
#      library is //tools/build/selftest:analysis_refusals_mojo; where C
#      targets execute is //tools/build/selftest:exec_platforms; the
#      unconfigured query through toolchains//:cxx_no_default_deps is
#      //tools/build/selftest:uquery_select_branches.

expect_red c_dep_missing "undefined symbol: komira_example_add" tests//negative/c_deps:c_missing

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
