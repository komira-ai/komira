#!/usr/bin/env bash
# run_checks.sh -- end-to-end checks of the Mojo rules. Each check can fail.
#
# usage: tools/build/checks/run_checks.sh [--no-umbrella] [--no-run] [--no-uncached]
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
#   7. A repository using komira as a cell -- a git submodule at ./komira or
#      ./third_party/komira, or a git external cell -- gets remote cache hits
#      with the same action digests as a standalone checkout
#      (tools/build/checks/umbrella_cache.sh; four scratch checkouts and
#      daemons, skipped with --no-umbrella).
#   8. The host floor: during a real compile, and a run of the binary it
#      built, the loader maps libstdc++.so.6 and libgcc_s.so.1 from the
#      toolchain, and nothing from the worker except glibc's own objects
#      (checks//runtime_libs:loader_trace, read from LD_DEBUG). The
#      toolchain libraries the run loaded are exactly the ones a runnable
#      directory carries in lib/ (komira//tools/build/toolchains:mojo_runtime), no more, no
#      fewer, and every run path those libraries carry is $ORIGIN-relative.
#   9. `buck2 run //tools/build/examples:hello` prints the greeting on this
#      machine from a fresh clone, downloads only the binary and its runtime libraries, and
#      the runnable directory still starts after it is moved
#      (tools/build/checks/buck2_run.sh; skipped with --no-run).
#  10. Execution platforms: Mojo compiles, gated tests and run checks resolve
#      to `exec-mojo` (mojo_compile, numa_single) and toolchain unpack/copy
#      targets to `exec-light`. A target requiring numa_multi, with no
#      platform providing it, fails to configure and runs nothing; given one
#      (resolution only, nothing is built), it resolves to it.
#  11. The multi-NUMA run checks the hardware it got, not only the label:
#      numa_guard.sh gives the right verdict on 12 made-up topologies
#      (checks//numa:guard_cases, a remote action); komira_execution_platforms
#      refuses a multi-NUMA property set equal to the mojo_compile one; and on
#      a stand-in platform whose multi-NUMA workers are the single-NUMA
#      mojo_compile workers (checks//numa/standin), both the build's run
#      check and `buck2 test` refuse to start (numa_guard: REFUSING to run).
#  12. Actions run with their platform's property set, read per action: an
#      uncached build of //tools/build/examples:hello (its own daemon under a
#      fixed --isolation-dir, --no-remote-cache, so every action really executes)
#      must record the light set for zig_unpack, zig_build_exe, conda_unpack
#      and mojo_runtime, and the mojo_compile set for mojo_build (`buck2 log
#      what-ran`; a cache hit records no properties, so a warm build cannot
#      answer this). Costs about 80 s of remote execution; the isolated
#      daemon's buck-out/komira_checks_uncached (~50 MB) is reused per run.
#  13. A program built as a bundle behaves as its executable: stdout, stderr
#      and exit status agree byte for byte across argv, environment, exit(),
#      an unhandled error, buffered output, a data file found through
#      /proc/self/exe, abort() and SIGSEGV (status and stdout exact, the
#      stack dump's first line), and a symlink invocation with another
#      argv[0] (checks//bundle_parity:parity, a remote action).
#  14. The launcher's CPU level function gives glibc's level for the made-up
#      CPUs of tools/build/package/launcher/cpu_models.h: the hand-written ones, and one
#      per feature glibc requires, a CPU of that level or above with just that
#      bit cleared (//tools/build/package:level_test, a remote action). On an x86-64
#      glibc host, its level for this host's CPU agrees with this host's
#      glibc loader (tools/build/checks/glibc_level.sh).
#  15. The bundle of //tools/build/examples:hello (tools/build/checks/bundle.sh): layout, run paths
#      and SHA256SUMS; it runs from a relocated copy and through a symlink on
#      PATH; a CPU below x86-64-v3 gets the one-line refusal (test launcher);
#      two uncached builds give byte-identical bundles, tarballs and docker
#      archives and the same image digest (skipped with --no-uncached; about
#      3 minutes of remote execution).
#  16. The package formats of //tools/build/examples:hello (tools/build/checks/formats.sh): the
#      tarball and the OCI image follow the determinism rules and hold the
#      bundle; the image's blobs, config (entrypoint, linux/amd64) and pinned
#      base layers are checked; the base is fetched only by pinned
#      downloads; `docker run` of the loaded image prints the greeting (SKIP
#      without docker).
#  17. Every relative link in the repository's Markdown resolves to a tracked
#      file (doc_links.sh), and on a planted git tree the link checker names
#      a missing file, a bad #anchor, a link leaving the tree and a link to an
#      untracked file.
#  18. The configuration hashes of exec-light, exec-mojo and linux-x86_64 equal
#      their pins: they are in the digest of every configured action.
#  19. What a repository using komira as a cell loads names no cell but
#      komira, prelude and toolchains: every label outside a comment in the
#      BUCK and .bzl files of tools/build/{mojo,rust,proto-codegen,toolchains,
#      platforms,package,examples,cells} and third_party. A label naming `checks`
#      (standalone-only) fails to load there.
#  20. C/C++ dependencies of Mojo targets: see tools/build/checks/cxx_checks.sh.
#  21. A Mojo binary whose own code records a source location (a List
#      index) builds and runs: the compile wrapper strips the staging
#      directory from recorded paths, so its exit-4 refusal does not fire
#      (checks//location_path).
#  22. Rust rules: see tools/build/checks/rust_checks.sh.
#  23. mojo_proto_library: see tools/build/checks/proto_checks.sh.
set -uo pipefail

umbrella=1
run=1
uncached=1
for a in "$@"; do
    case "$a" in
        --no-umbrella) umbrella=0 ;;
        --no-run) run=0 ;;
        --no-uncached) uncached=0 ;;
        *) echo "usage: $0 [--no-umbrella] [--no-run] [--no-uncached]" >&2; exit 2 ;;
    esac
done

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    if command -v buck2 > /dev/null; then BUCK2=buck2; else BUCK2="$ROOT/tools/buck2"; fi
fi
# Logs, and the scratch checkouts of checks 7 and 9, go under $TMPDIR. Where
# /tmp is memory, point TMPDIR at a disk directory. The checkouts are deleted
# on exit, pass or fail (KEEP_SCRATCH=1 keeps them); logs are kept.
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
    //tools/build/examples:hello //tools/build/examples:hellopkg //tools/build/examples:hello_pkg_user
    //tools/build/examples/libgate_ok:libgate_ok //tools/build/examples:test_hellopkg
    //tools/build/examples:hello_bundle //tools/build/package:level_test
    //tools/build/examples/cshim:add //tools/build/examples/cshim:cadd
    //tools/build/examples/cshim:cadd_user //tools/build/examples/cshim:test_add_direct
    //third_party/snappy:snappy //tools/build/examples/snappy:test_snappy
)
# Sub-targets are built in their own invocation. (`buck2 build //... 'T[sub]'`
# was observed to skip the sub-target, so never rely on combining them with a
# recursive pattern.)
RUN_CHECKS=("//tools/build/examples:hello[run_check]" "//tools/build/examples:hello_pkg_user[run_check]"
    "//tools/build/examples/cshim:cadd_user[run_check]")

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
if ! "$BUCK2" build //tools/build/examples:hello --materializations all --show-full-simple-output > "$LOG/outputs.txt" 2> "$LOG/outputs.log"; then
    fail "outputs: cannot materialize //tools/build/examples:hello (see $LOG/outputs.log)"
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
    if ! "$BUCK2" build "//tools/build/examples:hello[runnable]" --show-full-simple-output > "$LOG/runnable.txt" 2> "$LOG/runnable.log"; then
        fail "runtime libs: cannot build //tools/build/examples:hello[runnable] (see $LOG/runnable.log)"
    elif ! (cd "$(tail -n 1 "$LOG/runnable.txt")/lib" && ls -1) 2> /dev/null | LC_ALL=C sort > "$LOG/runtime_shipped.txt"; then
        fail "runtime libs: no lib/ in $(tail -n 1 "$LOG/runnable.txt")"
    elif [ ! -s "$LOG/runtime_loaded.txt" ]; then
        fail "runtime libs: the loader trace records no toolchain library for the run"
    elif ! cmp -s "$LOG/runtime_loaded.txt" "$LOG/runtime_shipped.txt"; then
        fail "runtime libs: loaded [$(tr '\n' ' ' < "$LOG/runtime_loaded.txt")] but lib/ ships [$(tr '\n' ' ' < "$LOG/runtime_shipped.txt")]"
    else
        pass "runtime libs: lib/ ships exactly the $(wc -l < "$LOG/runtime_shipped.txt" | tr -d ' ') toolchain libraries a run loads"
    fi
    # Every run path a shipped library carries (vendor DT_RPATH included) must
    # be relative to the library itself, or it names a directory on the
    # machine that built it.
    libdir="$(tail -n 1 "$LOG/runnable.txt")/lib"
    : > "$LOG/runtime_runpaths.txt"
    for so in "$libdir"/*; do
        [ -f "$so" ] || continue
        readelf -d "$so" 2> /dev/null | sed -nE 's/.*\((RPATH|RUNPATH)\).*\[(.*)\]$/\2/p' | tr ':' '\n' |
            sed "s|^|$(basename "$so") |" >> "$LOG/runtime_runpaths.txt"
    done
    if [ ! -s "$LOG/runtime_runpaths.txt" ]; then
        fail "runtime run paths: read none from $libdir; the scan saw nothing"
    elif grep -v -E '^[^ ]+ \$ORIGIN(/|$)' "$LOG/runtime_runpaths.txt" > "$LOG/runtime_runpaths_bad.txt"; then
        fail "runtime run paths: not \$ORIGIN-relative: $(head -n 3 "$LOG/runtime_runpaths_bad.txt" | tr '\n' ' ')"
    else
        pass "runtime run paths: all $(wc -l < "$LOG/runtime_runpaths.txt" | tr -d ' ') run path entries in lib/ are \$ORIGIN-relative"
    fi
fi

# 10
# `buck2 audit execution-platform-resolution` prints, per target, either
# "Execution platform: <label>" or "Failed to configure: ...". The
# multi-NUMA key is set explicitly both ways so the result does not depend on
# .buckconfig.local.
resolve() { # log name, extra args..., targets...: prints "<target> <platform|FAILED>"
    local name=$1; shift
    "$BUCK2" audit execution-platform-resolution "$@" > "$LOG/$name.txt" 2>&1 || return 1
    awk '/^[^ ].* \(.*\):$/ { t = $1; next }
         t != "" && /^  Execution platform: / { print t, $3; t = "" }
         t != "" && /^  Failed to configure/ { print t, "FAILED"; t = "" }' "$LOG/$name.txt"
}
NO_MULTI=(-c komira_re.mojo_compile_multi_numa_properties=)
EXPECT_PLATFORMS="
komira//tools/build/examples:hello komira//tools/build/platforms:exec-mojo
komira//tools/build/examples:hellopkg komira//tools/build/platforms:exec-mojo
komira//tools/build/examples/libgate_ok:libgate_ok komira//tools/build/platforms:exec-mojo
komira//tools/build/examples:test_hellopkg komira//tools/build/platforms:exec-mojo
checks//numa:hello komira//tools/build/platforms:exec-mojo
komira//tools/build/toolchains:zig komira//tools/build/platforms:exec-light
komira//tools/build/toolchains:conda_unpack komira//tools/build/platforms:exec-light
komira//tools/build/toolchains:mojo_compiler komira//tools/build/platforms:exec-light
komira//tools/build/toolchains:mojo_runtime komira//tools/build/platforms:exec-light
checks//numa:hello_multi_numa FAILED"
want=$(printf '%s\n' "$EXPECT_PLATFORMS" | sed '/^$/d' | LC_ALL=C sort)
if ! got=$(resolve platforms "${NO_MULTI[@]}" $(printf '%s\n' "$want" | cut -d' ' -f1)); then
    fail "exec platforms: audit failed (see $LOG/platforms.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$want" ]; then
    fail "exec platforms: resolution differs: $(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got" | LC_ALL=C sort) | grep '^>' | tr '\n' ' ') (see $LOG/platforms.txt)"
elif ! grep -qF 'exec_compatible_with requires `komira//tools/build/platforms:numa_multi` but it was not satisfied' "$LOG/platforms.txt"; then
    fail "exec platforms: the multi-NUMA refusal does not name numa_multi (see $LOG/platforms.txt)"
else
    pass "exec platforms: $(printf '%s\n' "$want" | grep -c exec-mojo) Mojo targets on exec-mojo, $(printf '%s\n' "$want" | grep -c exec-light) toolchain targets on exec-light, numa_multi unresolvable"
fi
# The refusal holds for a real build too, and nothing runs. (Skipped if the
# audit above did not refuse, so a broken constraint never runs the binary on
# a single-NUMA worker here.)
if printf '%s\n' "${got:-}" | grep -qx 'checks//numa:hello_multi_numa FAILED'; then
    if "$BUCK2" build "${NO_MULTI[@]}" checks//numa:hello_multi_numa > "$LOG/numa_refusal.log" 2>&1; then
        fail "multi-NUMA refusal: checks//numa:hello_multi_numa built with no numa_multi platform"
    # Literal wording of buck2 2026-09-15 (tools/buck2). A buck2 release that
    # rewords it turns this check red, not green; update it with the pin.
    elif ! grep -qF "Can't find toolchain_dep execution platform" "$LOG/numa_refusal.log"; then
        fail "multi-NUMA refusal: failed for another reason (see $LOG/numa_refusal.log)"
    elif ! "$BUCK2" log what-ran > "$LOG/numa_refusal.what_ran.txt" 2>&1; then
        fail "multi-NUMA refusal: cannot read what-ran"
    elif awk -F'\t' 'NF >= 3' "$LOG/numa_refusal.what_ran.txt" | grep -q .; then
        fail "multi-NUMA refusal: actions ran before the refusal (see $LOG/numa_refusal.what_ran.txt)"
    else
        pass "multi-NUMA refusal: the build fails to configure and runs no action"
    fi
else
    fail "multi-NUMA refusal: not attempted, the audit resolved checks//numa:hello_multi_numa"
fi
if ! got=$(resolve platforms_multi -c komira_re.mojo_compile_multi_numa_properties=pool=unreachable-check-only \
        checks//numa:hello_multi_numa komira//tools/build/examples:hello); then
    fail "multi-NUMA platform: audit failed (see $LOG/platforms_multi.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$(printf '%s\n' 'checks//numa:hello_multi_numa komira//tools/build/platforms:exec-mojo-multi-numa' 'komira//tools/build/examples:hello komira//tools/build/platforms:exec-mojo' | LC_ALL=C sort)" ]; then
    fail "multi-NUMA platform: with one registered, got [$(printf '%s\n' "$got" | tr '\n' ' ')] (see $LOG/platforms_multi.txt)"
else
    pass "multi-NUMA platform: when registered, only the multi-NUMA run resolves to it"
fi

# 11
if ! "$BUCK2" build checks//numa:guard_cases --show-full-simple-output > "$LOG/guard_cases.txt" 2> "$LOG/guard_cases.log"; then
    fail "NUMA guard cases: failed (see $LOG/guard_cases.log)"
else
    report=$(tail -n 1 "$LOG/guard_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 12 ] || ! grep -q ' run$' "$report" || ! grep -q ' refuse$' "$report"; then
        fail "NUMA guard cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "NUMA guard cases: $ok topologies, each run or refused as required"
    fi
fi
re_value() { # key: prints [komira_re] <key> of the root cell
    "$BUCK2" audit config "komira_re.$1" --style json 2> /dev/null |
        python3 -c 'import json, sys; print(list(json.load(sys.stdin).values())[0])' 2> /dev/null
}
MC_PROPS=$(re_value mojo_compile_properties)
LIGHT_PROPS=$(re_value light_properties)
if [ -z "$MC_PROPS" ] || [ -z "$LIGHT_PROPS" ]; then
    fail "multi-NUMA hardware: cannot read [komira_re] mojo_compile_properties / light_properties"
else
    if "$BUCK2" audit execution-platform-resolution -c "komira_re.mojo_compile_multi_numa_properties=$MC_PROPS" \
            checks//numa:hello_multi_numa > "$LOG/numa_same_set.log" 2>&1; then
        fail "multi-NUMA hardware: a multi-NUMA property set equal to mojo_compile was accepted"
    elif ! grep -qF 'but it equals `mojo_compile`' "$LOG/numa_same_set.log"; then
        fail "multi-NUMA hardware: the equal-set refusal failed for another reason (see $LOG/numa_same_set.log)"
    else
        pass "multi-NUMA hardware: a multi-NUMA property set equal to mojo_compile is refused at load"
    fi
    # The stand-in routes numa_multi to the single-NUMA workers. A timeout
    # bounds each invocation: an unknown property set queues forever.
    STANDIN=(-c build.execution_platforms=checks//numa/standin:single_numa_standin
             -c "checks//komira_re.mojo_compile_properties=$MC_PROPS"
             -c "checks//komira_re.light_properties=$LIGHT_PROPS")
    if timeout 600 "$BUCK2" build "${STANDIN[@]}" checks//numa:hello_multi_numa > "$LOG/numa_standin.log" 2>&1; then
        fail "multi-NUMA hardware: the run check went green on single-NUMA workers"
    elif ! grep -qF 'numa_guard: REFUSING to run' "$LOG/numa_standin.log"; then
        fail "multi-NUMA hardware: the stand-in build failed without the guard's refusal (see $LOG/numa_standin.log)"
    else
        pass "multi-NUMA hardware: run check refused on single-NUMA workers ($(grep -o -m1 'usable NUMA nodes \[[^]]*\]' "$LOG/numa_standin.log"))"
    fi
    if timeout 600 "$BUCK2" test "${STANDIN[@]}" checks//numa:hello_multi_numa > "$LOG/numa_standin_test.log" 2>&1; then
        fail "multi-NUMA hardware: buck2 test passed on single-NUMA workers"
    elif ! grep -qF 'numa_guard: REFUSING to run' "$LOG/numa_standin_test.log"; then
        fail "multi-NUMA hardware: buck2 test failed without the guard's refusal (see $LOG/numa_standin_test.log)"
    else
        pass "multi-NUMA hardware: buck2 test refused on single-NUMA workers"
    fi
fi

# 12
ISO=komira_checks_uncached
if [ -z "${MC_PROPS:-}" ] || [ -z "${LIGHT_PROPS:-}" ]; then
    fail "action platforms: cannot read [komira_re] mojo_compile_properties / light_properties"
# The isolated daemon keeps its outputs between runs, and --no-remote-cache
# does not rerun an action whose output is already on disk: clean first, or
# a second run of these checks in the same checkout executes nothing.
elif ! "$BUCK2" --isolation-dir "$ISO" clean > "$LOG/uncached_clean.log" 2>&1; then
    fail "action platforms: cannot clean the isolated buck-out (see $LOG/uncached_clean.log)"
elif ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache //tools/build/examples:hello > "$LOG/uncached.log" 2>&1; then
    fail "action platforms: uncached build failed (see $LOG/uncached.log)"
elif ! "$BUCK2" --isolation-dir "$ISO" log what-ran --format json > "$LOG/uncached.what_ran.json" 2>&1; then
    fail "action platforms: cannot read what-ran"
elif ! verdict=$(LIGHT="$LIGHT_PROPS" MOJO="$MC_PROPS" python3 - "$LOG/uncached.what_ran.json" << 'PY'
import json, os, sys

def props(raw):
    return dict(p.strip().split("=", 1) for p in raw.split(",") if p.strip())

light, mojo = props(os.environ["LIGHT"]), props(os.environ["MOJO"])
if light == mojo:
    print("light and mojo_compile property sets are equal; nothing to tell apart")
    sys.exit(1)
want = {c: light for c in ("zig_unpack", "zig_build_exe", "conda_unpack", "mojo_runtime")}
want["mojo_build"] = mojo
seen, bad = {}, []
for line in open(sys.argv[1]):
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    category = d["identity"].rsplit(" (", 1)[-1].rstrip(")")
    rep = d["reproducer"]
    if category not in want:
        continue
    seen[category] = seen.get(category, 0) + 1
    got = rep.get("details", {}).get("platform_properties")
    if rep.get("executor") != "Re" or got is None:
        bad.append("%s ran as %s, not a remote execution" % (category, rep.get("executor")))
    elif got != want[category]:
        bad.append("%s ran with the %s set" % (category, "mojo_compile" if got == mojo else "light" if got == light else "an unknown"))
missing = sorted(set(want) - set(seen))
if missing:
    bad.append("not executed: " + " ".join(missing))
if bad:
    print("; ".join(bad))
    sys.exit(1)
print("%d actions: %s on light, mojo_build on mojo_compile" % (sum(seen.values()), "/".join(sorted(c for c in want if c != "mojo_build"))))
PY
); then
    fail "action platforms: ${verdict:-no verdict} (see $LOG/uncached.what_ran.json)"
else
    pass "action platforms: $verdict"
fi
"$BUCK2" --isolation-dir "$ISO" kill > /dev/null 2>&1

# 13
if "$BUCK2" build checks//bundle_parity:parity --show-full-simple-output > "$LOG/parity.txt" 2> "$LOG/parity.log"; then
    pass "bundle parity: $(tail -n 1 "$(tail -n 1 "$LOG/parity.txt")") between executable and bundle"
else
    fail "bundle parity: $(grep -m1 -E '^[0-9]+ cases' "$LOG/parity.log") (see $LOG/parity.log)"
fi

# 14
if "$BUCK2" build //tools/build/package:level_test --show-full-simple-output > "$LOG/level.txt" 2> "$LOG/level.log"; then
    lt=$(tail -n 1 "$LOG/level.txt")
    ltbin=$("$BUCK2" build '//tools/build/package:level_test[bin]' --show-full-simple-output 2>> "$LOG/level.log" | tail -n 1)
    rc=0; here=$("$ROOT/tools/build/checks/glibc_level.sh" "$ltbin") || rc=$?
    case "$rc" in
    0 | 2) pass "launcher levels: $(grep -c '^ok ' "$lt") made-up CPUs judged as glibc does ($(sed -n 's/^models: //p' "$lt")); $here" ;;
    *) fail "launcher levels: $here (see $LOG/level.log)" ;;
    esac
else
    fail "launcher levels: $(grep -m3 '^BAD' "$LOG/level.log" | tr '\n' ' ')(see $LOG/level.log)"
fi

# 15
bundle_args=()
[ "$uncached" = 1 ] || bundle_args+=(--no-uncached)
BUCK2="$BUCK2" "$ROOT/tools/build/checks/bundle.sh" ${bundle_args[@]+"${bundle_args[@]}"} > "$LOG/bundle.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  bundle "*) pass "${line#PASS  }" ;;
        "FAIL  bundle "*) fail "${line#FAIL  } (see $LOG/bundle.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/bundle.log"
grep -qE '^(PASS|FAIL)  bundle ' "$LOG/bundle.log" || fail "bundle: tools/build/checks/bundle.sh reported nothing (see $LOG/bundle.log)"

# 16
BUCK2="$BUCK2" "$ROOT/tools/build/checks/formats.sh" > "$LOG/formats.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  formats "*) pass "${line#PASS  }" ;;
        "FAIL  formats "*) fail "${line#FAIL  } (see $LOG/formats.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/formats.log"
grep -qE '^(PASS|FAIL)  formats ' "$LOG/formats.log" || fail "formats: tools/build/checks/formats.sh reported nothing (see $LOG/formats.log)"

# 17
# The planted tree is a git repository with one link per diagnostic, plus two
# links that must resolve (a tracked directory, a real heading): the checker
# must name each dead link with its reason, and only those.
P="$LOG/doc_links_planted"
mkdir -p "$P/sub"
printf '# planted\n\n[ok](sub/)\n[dead](sub/missing.md)\n[anchor](sub/a.md#nope)\n[escape](../outside.md)\n[untracked](sub/untracked.md)\n[heading](sub/a.md#a)\n' > "$P/README.md"
printf '# A\n' > "$P/sub/a.md"
printf '# untracked\n' > "$P/sub/untracked.md"
git -C "$P" init -q && git -C "$P" add README.md sub/a.md
PLANTED=(
    'README.md:4: sub/missing.md (no such file)'
    'README.md:5: sub/a.md#nope (no heading #nope)'
    'README.md:6: ../outside.md (leaves the repository)'
    'README.md:7: sub/untracked.md (not tracked by git)'
    'FAIL  doc links: 4 of 6 relative links do not resolve'
)
missed=""
if "$ROOT/tools/build/checks/doc_links.sh" "$P" > "$LOG/doc_links_planted.log" 2>&1; then
    missed="(it passed)"
else
    for want in "${PLANTED[@]}"; do
        grep -qF "$want" "$LOG/doc_links_planted.log" || missed="$missed [$want]"
    done
fi
if [ -n "$missed" ]; then
    fail "doc links: on the planted tree the checker missed $missed (see $LOG/doc_links_planted.log)"
elif "$ROOT/tools/build/checks/doc_links.sh" > "$LOG/doc_links.log" 2>&1; then
    pass "doc links: $(grep -o 'all [0-9]* relative links resolve' "$LOG/doc_links.log"); planted missing, bad-anchor, escaping and untracked links are each caught"
else
    fail "$(grep -m1 '^FAIL' "$LOG/doc_links.log" | cut -c 7-) $(grep '^dead link' "$LOG/doc_links.log" | head -n 3 | cut -c 12- | tr '\n' ' ')(see $LOG/doc_links.log)"
fi

# 18
# The configuration hashes. The target platform's label and constraints key
# every configuration, and the hash appears in the output paths, and so in
# the digest, of every configured action: moving or renaming
# komira//tools/build/platforms, or changing a constraint, changes every action digest in
# the repository and every repository mounting it (a buck2 upgrade may too).
# The pins make such a change a deliberate edit of this list.
EXPECT_CFGS="
komira//tools/build/platforms:exec-light#6dbe0803a8efd9e4
komira//tools/build/platforms:exec-mojo#a37dd214722ae04e
komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be"
want=$(printf '%s\n' "$EXPECT_CFGS" | sed '/^$/d')
if ! "$BUCK2" cquery 'deps(komira//tools/build/examples:hello)' > "$LOG/cfg_hashes.txt" 2>&1; then
    fail "configuration hashes: cquery failed (see $LOG/cfg_hashes.txt)"
elif got=$(grep -oE '\([^ ()]*:(exec-light|exec-mojo|linux-x86_64)#[0-9a-f]+\)' "$LOG/cfg_hashes.txt" | tr -d '()' | LC_ALL=C sort -u) \
        && [ "$got" != "$want" ]; then
    fail "configuration hashes moved, so every action digest did: got $(printf '%s' "$got" | tr '\n' ' '); if deliberate, update EXPECT_CFGS (see $LOG/cfg_hashes.txt)"
else
    pass "configuration hashes: exec-light, exec-mojo and linux-x86_64 keep their pinned hashes"
fi

# 19
EXPORTED="tools/build/mojo tools/build/rust tools/build/proto-codegen tools/build/toolchains tools/build/platforms tools/build/package tools/build/examples
    tools/build/cells third_party"
missing=""
for d in $EXPORTED; do [ -d "$ROOT/$d" ] || missing="$missing $d"; done
labels=$(cd "$ROOT" && git ls-files -z $EXPORTED |
    grep -zE '(^|/)(BUCK|[^/]*\.bzl)$' | xargs -0 grep -nE '[a-z_]+//' |
    awk -F: '{ line = $0; sub(/^[^:]*:[^:]*:/, "", line) } line !~ /^[ \t]*#/ { print }' |
    grep -oE '^[^:]*:[0-9]+:|(^|[^a-z_])[a-z_]+//' | tr -d '"(' )
n=$(printf '%s\n' "$labels" | grep -cE '[a-z_]+//$')
foreign=$(printf '%s\n' "$labels" | awk '/:[0-9]+:$/ { at = $0; next } /\/\/$/ { c = $0; sub(/^[^a-z_]*/, "", c); sub(/\/\/$/, "", c); if (c != "komira" && c != "prelude" && c != "toolchains") print at c "//" }')
if [ -n "$missing" ]; then
    fail "exported cells: searched directories missing:$missing"
elif [ "$n" -lt 20 ]; then
    fail "exported cells: only $n cell-qualified labels found, the scan is not reading the rules"
elif [ -n "$foreign" ]; then
    fail "exported cells: labels naming a cell a consuming repository lacks: $(printf '%s' "$foreign" | head -n 5 | tr '\n' ' ')"
else
    pass "exported cells: $n cell-qualified labels in the exported packages name only komira, prelude and toolchains"
fi

# 20
. "$ROOT/tools/build/checks/cxx_checks.sh"

# 21
expect_green location_path "checks//location_path:main[run_check]"

# 22
# shellcheck source=tools/build/checks/rust_checks.sh
. "$ROOT/tools/build/checks/rust_checks.sh"

# 23
# shellcheck source=tools/build/checks/proto_checks.sh
. "$ROOT/tools/build/checks/proto_checks.sh"

# 9
if [ "$run" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/tools/build/checks/buck2_run.sh" > "$LOG/buck2_run.log" 2>&1; then
        pass "buck2 run: $(grep -o 'PASS  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-)"
    else
        fail "buck2 run: $(grep -o 'FAIL  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-) (see $LOG/buck2_run.log)"
    fi
else
    echo "SKIP  buck2 run (--no-run)"
fi

# 7
if [ "$umbrella" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/tools/build/checks/umbrella_cache.sh" > "$LOG/umbrella.log" 2>&1; then
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
