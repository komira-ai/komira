#!/usr/bin/env bash
# run_checks.sh -- end-to-end checks of the Mojo rules. Each check can fail.
#
# usage: checks/run_checks.sh            (from the repo root; BUCK2 overrides the binary)
#
#   1. The examples build and their run checks pass (stdout compared byte for
#      byte), and every action that executed ran remotely.
#   2. The gate: checks//libgate_bad fails with GATED TEST FAILED, while its
#      [ungated] package builds -- the red comes from the test, not the compile.
#   3. Packages reach the compiler only through `deps`: a binary importing
#      hellopkg without depending on it fails to compile.
#   4. The toolchain refuses an incomplete closure (exit 2) instead of falling
#      back to anything on the worker.
#   5. No action argv or env names an absolute host path.
set -uo pipefail

BUCK2=${BUCK2:-buck2}
LOG=$(mktemp -d "${TMPDIR:-/tmp}/komira_checks.XXXXXX")
fails=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }

expect_green() { # name, targets...
    local name=$1; shift
    if "$BUCK2" build "$@" > "$LOG/$name.log" 2>&1; then pass "$name"; else fail "$name (see $LOG/$name.log)"; fi
}

expect_red() { # name, required text, target
    local name=$1 text=$2 target=$3
    if "$BUCK2" build "$target" > "$LOG/$name.log" 2>&1; then
        fail "$name: $target built, but it must fail"
    elif grep -qF -- "$text" "$LOG/$name.log"; then
        pass "$name"
    else
        fail "$name: failed without '$text' (see $LOG/$name.log)"
    fi
}

EXAMPLES=(
    //examples:hello //examples:hellopkg //examples:hello_pkg_user
    //examples/libgate_ok:libgate_ok //examples:test_hellopkg
    "//examples:hello[run_check]" "//examples:hello_pkg_user[run_check]"
)

# 1
expect_green examples "${EXAMPLES[@]}"
# The execution platform disables local execution outright; this reads the
# build log to confirm it. Only meaningful when something executed: a fully
# up-to-date build executes nothing and proves nothing, and says so.
if ! "$BUCK2" log what-ran > "$LOG/what_ran.txt" 2>&1; then
    fail "examples: cannot read what-ran"
else
    executed=$(awk -F'\t' 'NF >= 4' "$LOG/what_ran.txt" | wc -l)
    if awk -F'\t' 'NF >= 4 && $4 !~ /^(re|cache)/' "$LOG/what_ran.txt" | grep -q .; then
        fail "examples: an action ran outside remote execution (see $LOG/what_ran.txt)"
    elif [ "$executed" = 0 ]; then
        echo "SKIP  examples: nothing executed in this invocation (already up to date), remote-only not re-observed"
    else
        pass "examples: all $executed executed actions were remote or cache hits"
    fi
fi

# 2
expect_red gate_red "GATED TEST FAILED" checks//libgate_bad:libgate_bad
expect_green gate_ungated_green "checks//libgate_bad:libgate_bad[ungated]"

# 3
expect_red missing_dep "unable to locate module 'hellopkg'" checks//missing_dep:missing_dep

# 4
expect_red closure_refusal "REFUSING: toolchain member" checks//closure_refusal:hello_incomplete_toolchain

# 5
query="deps(set($(printf '"%s" ' "${EXAMPLES[@]}")))"
abs_path_re="[\"' =:]/[A-Za-z][A-Za-z0-9_.-]*"
if ! printf '%s\n' "\"cmd\": \"['/bin/sh', 'x']\"" | grep -qE "$abs_path_re"; then
    fail "host paths: the scan pattern does not detect a planted absolute path"
elif ! "$BUCK2" aquery "$query" --output-attribute cmd --output-attribute env --json > "$LOG/aquery.json" 2> "$LOG/aquery.err"; then
    fail "host paths: aquery failed (see $LOG/aquery.err)"
elif ! grep -q '"cmd"' "$LOG/aquery.json"; then
    fail "host paths: aquery returned no commands"
elif grep -oE "$abs_path_re" "$LOG/aquery.json" > "$LOG/abs_paths.txt"; then
    fail "host paths: absolute paths in action commands: $(sort -u "$LOG/abs_paths.txt" | tr '\n' ' ')"
else
    pass "host paths: no absolute path in $(grep -c '"cmd"' "$LOG/aquery.json") action commands"
fi

echo "logs: $LOG"
[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
