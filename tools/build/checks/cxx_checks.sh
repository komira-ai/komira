# cxx_checks.sh -- checks of C/C++ libraries in Mojo builds. Sourced by
# tools/build/checks/run_checks.sh (uses its BUCK2, LOG, pass, fail, expect_green,
# expect_red and resolve); not run on its own.
#
#  20. C/C++ dependencies of Mojo targets (the prelude's cxx_library, built
#      with toolchains//:cxx):
#      - a binary calling a C function links and prints the C result when
#        the library is in `deps`, and the link fails on the undefined symbol
#        when it is not (checks//c_deps);
#      - `deps` refuses a target that is neither a Mojo package nor a C/C++
#        library;
#      - C compiles and archives resolve to `exec-light`, the Mojo targets
#        depending on them to `exec-mojo`.

expect_green c_dep_linked "checks//c_deps:c_linked" "checks//c_deps:c_linked[run_check]"
expect_red c_dep_missing "undefined symbol: komira_example_add" checks//c_deps:c_missing
expect_red c_dep_kind "provides neither MojoInfo" checks//c_deps:bad_dep

C_PLATFORMS="
komira//tools/build/examples/cshim:add komira//tools/build/platforms:exec-light
komira//tools/build/examples/cshim:cadd komira//tools/build/platforms:exec-mojo"
want=$(printf '%s\n' "$C_PLATFORMS" | sed '/^$/d' | LC_ALL=C sort)
if ! got=$(resolve c_platforms $(printf '%s\n' "$want" | cut -d' ' -f1)); then
    fail "C exec platforms: audit failed (see $LOG/c_platforms.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$want" ]; then
    fail "C exec platforms: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got" | LC_ALL=C sort) | grep '^>' | tr '\n' ' ') (see $LOG/c_platforms.txt)"
else
    pass "C exec platforms: C targets on exec-light, their Mojo users on exec-mojo"
fi

