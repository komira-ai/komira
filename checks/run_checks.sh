#!/usr/bin/env bash
# run_checks.sh -- end-to-end checks of the Mojo rules. Each check can fail.
#
# usage: checks/run_checks.sh [--no-umbrella] [--no-run]
#        (from the repo root; BUCK2 overrides the binary)
#
#   1. The examples build and their run checks pass (stdout compared byte for
#      byte), and every action that executed ran remotely.
#   2. The gate: checks//libgate_bad fails with GATED TEST FAILED, while its
#      [ungated] package builds -- the red comes from the test, not the compile.
#      A binary depending on it fails the same way, and a binary naming its
#      [ungated] sub-target in `deps` fails analysis (no gate bypass).
#   3. Packages reach the compiler only through `deps`: a binary importing
#      hellopkg without depending on it fails to compile.
#   4. The toolchain refuses an incomplete closure (exit 2) instead of falling
#      back to anything on the worker.
#   5. No action argv or env names an absolute host path.
#   6. Built outputs are path-free: the linked binary's only run path is
#      DT_RUNPATH `$ORIGIN/lib`, and no string in it names a buck-out
#      directory. (Inside every compile action the
#      wrapper also refuses an output containing that action's working
#      directory, exit 4.)
#   7. A repository mounting komira as a git submodule gets remote cache hits
#      with the same action digests as a standalone checkout
#      (checks/umbrella_cache.sh; two scratch checkouts and daemons, skipped
#      with --no-umbrella).
#   8. The host floor: during a real compile, and a run of the binary it
#      built, the loader maps libstdc++.so.6 and libgcc_s.so.1 from the
#      toolchain, and nothing from the worker except glibc's own objects
#      (checks//runtime_libs:loader_trace, read from LD_DEBUG). The
#      toolchain libraries the run loaded are exactly the ones a runnable
#      directory carries in lib/ (toolchains//:mojo_runtime), no more, no fewer.
#   9. `buck2 run //examples:hello` prints the greeting on this machine from a
#      fresh clone, downloads only the binary and its runtime libraries, and
#      the runnable directory still starts after it is moved
#      (checks/buck2_run.sh; skipped with --no-run).
set -uo pipefail

umbrella=1
run=1
for a in "$@"; do
    case "$a" in
        --no-umbrella) umbrella=0 ;;
        --no-run) run=0 ;;
        *) echo "usage: $0 [--no-umbrella] [--no-run]" >&2; exit 2 ;;
    esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
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
)
# Sub-targets are built in their own invocation. (`buck2 build //... 'T[sub]'`
# was observed to skip the sub-target, so never rely on combining them with a
# recursive pattern.)
RUN_CHECKS=("//examples:hello[run_check]" "//examples:hello_pkg_user[run_check]")

# The execution platform disables local execution outright; this reads the
# build log to confirm it. Only meaningful when something executed (a remote
# run or a remote cache hit): an invocation with nothing to do proves
# nothing, and says so.
check_remote() { # name
    local name=$1 executed
    if ! "$BUCK2" log what-ran > "$LOG/$name.what_ran.txt" 2>&1; then
        fail "$name: cannot read what-ran"
        return
    fi
    executed=$(awk -F'\t' 'NF >= 3' "$LOG/$name.what_ran.txt" | wc -l)
    if awk -F'\t' 'NF >= 3 && $3 !~ /^(re\(|cache)/' "$LOG/$name.what_ran.txt" | grep -q .; then
        fail "$name: an action ran outside remote execution (see $LOG/$name.what_ran.txt)"
    elif [ "$executed" = 0 ]; then
        echo "SKIP  $name: nothing executed in this invocation, remote-only not re-observed"
    else
        pass "$name: all $executed executed actions were remote runs or remote cache hits"
    fi
}

# 1
expect_green examples "${EXAMPLES[@]}"
check_remote examples
expect_green run_checks "${RUN_CHECKS[@]}"
check_remote run_checks

# 2
expect_red gate_red "GATED TEST FAILED" checks//libgate_bad:libgate_bad
expect_green gate_ungated_green "checks//libgate_bad:libgate_bad[ungated]"
expect_red gate_consumer_red "GATED TEST FAILED" checks//libgate_bad:gated_consumer
expect_red gate_bypass_refused "MojoInfo" checks//libgate_bad:bypass_consumer

# 3
expect_red missing_dep "unable to locate module 'hellopkg'" checks//missing_dep:missing_dep

# 4
expect_red closure_refusal "REFUSING: toolchain member" checks//closure_refusal:hello_incomplete_toolchain

# 5
query="deps(set($(printf '"%s" ' "${EXAMPLES[@]}" "${RUN_CHECKS[@]}")))"
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

# 6
if ! "$BUCK2" build //examples:hello --materializations all --show-full-simple-output > "$LOG/outputs.txt" 2> "$LOG/outputs.log"; then
    fail "outputs: cannot materialize //examples:hello (see $LOG/outputs.log)"
else
    bin=$(tail -n 1 "$LOG/outputs.txt")
    if [ ! -s "$bin" ]; then
        fail "outputs: no binary at '$bin'"
    elif ! grep -qa 'libKGENCompilerRTShared' "$bin"; then
        fail "outputs: scan cannot see the binary's dynamic section (no NEEDED name found)"
    elif ! command -v readelf > /dev/null; then
        fail "outputs: readelf is not installed; cannot read the run path"
    elif [ "$(readelf -d "$bin" | grep -E 'RPATH|RUNPATH' | sed -E 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]$/\1 \2/')" != 'RUNPATH $ORIGIN/lib' ]; then
        fail "outputs: $bin run path is not exactly RUNPATH \$ORIGIN/lib: $(readelf -d "$bin" | grep -E 'RPATH|RUNPATH' | tr -s ' ')"
    elif grep -qa 'buck-out/' "$bin"; then
        fail "outputs: $bin names a buck-out path: $(grep -ao '[^[:cntrl:]]*buck-out/[^[:cntrl:]]*' "$bin" | head -n 1)"
    else
        pass "outputs: $bin has run path \$ORIGIN/lib only and names no buck-out path"
    fi
fi

# 8
GLIBC_FLOOR="/lib64/ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0"
if ! "$BUCK2" build checks//runtime_libs:loader_trace --show-full-simple-output > "$LOG/loader.txt" 2> "$LOG/loader.log"; then
    fail "host floor: loader trace failed (see $LOG/loader.log)"
else
    report=$(tail -n 1 "$LOG/loader.txt")
    problems=""
    for phase in compile run; do
        grep -qx "$phase rc=0" "$report" || problems="$problems $phase-did-not-succeed"
        for lib in libstdc++.so.6 libgcc_s.so.1; do
            grep -q "^$phase init <toolchain>/.*/$lib\$" "$report" || problems="$problems $phase:$lib-not-from-toolchain"
        done
    done
    # Every object mapped from outside the toolchain must be glibc's.
    while read -r _ _ path; do
        case "$path" in "<toolchain>/"*) continue ;; esac
        ok=0
        for g in $GLIBC_FLOOR; do
            case "$path" in "$g" | */"$g") ok=1 ;; esac
        done
        [ "$ok" = 1 ] || problems="$problems host:$path"
    done < <(grep ' init ' "$report")
    if [ -n "$problems" ]; then
        fail "host floor:$problems (see $report)"
    else
        pass "host floor: libstdc++/libgcc_s from the toolchain in compile and run; host objects only glibc ($(grep -c ' init ' "$report") mapped)"
    fi
    # What the run loaded from the toolchain must be what a runnable directory ships.
    sed -n 's|^run init <toolchain>/lib/||p' "$report" | LC_ALL=C sort > "$LOG/runtime_loaded.txt"
    if ! "$BUCK2" build "//examples:hello[runnable]" --show-full-simple-output > "$LOG/runnable.txt" 2> "$LOG/runnable.log"; then
        fail "runtime libs: cannot build //examples:hello[runnable] (see $LOG/runnable.log)"
    elif ! (cd "$(tail -n 1 "$LOG/runnable.txt")/lib" && ls -1) 2> /dev/null | LC_ALL=C sort > "$LOG/runtime_shipped.txt"; then
        fail "runtime libs: no lib/ in $(tail -n 1 "$LOG/runnable.txt")"
    elif [ ! -s "$LOG/runtime_loaded.txt" ]; then
        fail "runtime libs: the loader trace records no toolchain library for the run"
    elif ! cmp -s "$LOG/runtime_loaded.txt" "$LOG/runtime_shipped.txt"; then
        fail "runtime libs: loaded [$(tr '\n' ' ' < "$LOG/runtime_loaded.txt")] but lib/ ships [$(tr '\n' ' ' < "$LOG/runtime_shipped.txt")]"
    else
        pass "runtime libs: lib/ ships exactly the $(wc -l < "$LOG/runtime_shipped.txt" | tr -d ' ') toolchain libraries a run loads"
    fi
fi

# 9
if [ "$run" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/checks/buck2_run.sh" > "$LOG/buck2_run.log" 2>&1; then
        pass "buck2 run: $(grep -o 'PASS  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-)"
    else
        fail "buck2 run: $(grep -o 'FAIL  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-) (see $LOG/buck2_run.log)"
    fi
else
    echo "SKIP  buck2 run (--no-run)"
fi

# 7
if [ "$umbrella" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/checks/umbrella_cache.sh" > "$LOG/umbrella.log" 2>&1; then
        pass "umbrella cache: $(grep -o 'PASS  umbrella cache: .*' "$LOG/umbrella.log" | cut -c 23-)"
    else
        fail "umbrella cache: $(grep -o 'FAIL  umbrella cache: .*' "$LOG/umbrella.log" | cut -c 23-) (see $LOG/umbrella.log)"
    fi
else
    echo "SKIP  umbrella cache (--no-umbrella)"
fi

echo "logs: $LOG"
[ "$fails" = 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
