#!/usr/bin/env bash
# run_tests.sh -- end-to-end tests of the Mojo rules. Each test can fail.
#
# usage: tools/build/tests/run_tests.sh [--no-umbrella] [--no-run] [--no-uncached] [--host-check-only]
#        (from the repo root; BUCK2 overrides the binary)
#
# Where the tests run is where this checkout builds: read from the execution
# platforms buck2 registers (tools/build/platforms/default). With a
# `.buckconfig.local` naming a remote-execution service (`[komira_re]`), every
# action runs there and every test below runs. Without one, every action
# runs on this machine: the script says so on its first line, and skips,
# each with its own SKIP line, the tests that need a remote-execution service
# (7, 9, 10's registered multi-NUMA platform, 11's hardware stand-in, 12 and
# 24), and test 3, whose red needs the remote executor's input isolation. The remote and local executors are never mixed in one run.
#
# The tests are numbered, and the number is the test's name everywhere (the
# README, the docs). What a test builds lives in functional/ (behaviour that
# must work) or negative/ (planted defects that must go red); a test may have
# both halves, under the same package name.
#
#   1. The examples build and their run checks pass (stdout compared byte for
#      byte), and every action that executed ran on this checkout's executor
#      (remotely, or locally in a local-only run).
#   2. The gate: tests//negative/libgate_bad fails with GATED TEST FAILED, while its
#      [ungated] package builds -- the red comes from the test, not the compile.
#      A binary depending on it fails the same way, and a binary naming its
#      [ungated] sub-target in `deps` fails analysis (no gate bypass).
#   3. Packages reach the compiler only through `deps`: a binary importing
#      hellopkg without depending on it fails to compile.
#   4. The toolchain refuses an incomplete closure (exit 2) instead of falling
#      back to anything on the worker.
#   5. No action argv or env names an absolute host path (Mojo, Rust and
#      protobuf actions).
#   6. Built outputs are path-free: the linked binary's only run path is
#      DT_RUNPATH `$ORIGIN/lib`, and no string in it names a buck-out
#      directory. (Inside every compile action the
#      wrapper also refuses an output containing that action's working
#      directory, exit 4.)
#   7. A repository using komira as a cell -- a git submodule at ./komira or
#      ./third_party/komira, or a git external cell -- gets remote cache hits
#      with the same action digests as a standalone checkout, one of them
#      with a frozen copy of the toolchains cell, and an override in a
#      consumer's toolchains cell reaches the compile command; a consumer
#      with the remote settings in its root .buckconfig resolves to the
#      remote platforms, and refuses execution = remote with an incomplete
#      [komira_re] (tools/build/tests/functional/umbrella_cache.sh; five scratch
#      checkouts and daemons, skipped with --no-umbrella).
#   8. The host floor: during a real compile, and a run of the binary it
#      built, the loader maps libstdc++.so.6 and libgcc_s.so.1 from the
#      toolchain, and nothing from the worker except glibc's own objects
#      (tests//functional/runtime_libs:loader_trace, read from LD_DEBUG). The
#      toolchain libraries the run loaded are exactly the ones a runnable
#      directory carries in lib/ (komira//tools/build/toolchains:mojo_runtime), no more, no
#      fewer, and every run path those libraries carry is $ORIGIN-relative.
#   9. `buck2 run //tools/build/examples:hello` prints the greeting on this
#      machine from a fresh clone, downloads only the binary and its runtime libraries, and
#      the runnable directory still starts after it is moved
#      (tools/build/tests/functional/buck2_run.sh; skipped with --no-run).
#  10. Execution platforms: Mojo compiles, gated tests and run checks resolve
#      to `exec-mojo` (mojo_compile, numa_single); toolchain unpack/copy
#      targets, and third_party_srcs generation, drift test and fixture
#      archive, to `exec-light`. A target requiring numa_multi, with no
#      platform providing it, fails to configure and runs nothing; given one
#      (resolution only, nothing is built), it resolves to it.
#  11. The multi-NUMA run checks the hardware it got, not only the label:
#      numa_guard.sh gives the right verdict on 12 made-up topologies
#      (tests//functional/numa:guard_cases, a remote action); komira_execution_platforms
#      refuses a multi-NUMA property set equal to the mojo_compile one; and on
#      a stand-in platform whose multi-NUMA workers are the single-NUMA
#      mojo_compile workers (tests//negative/numa_standin), both the build's run
#      check and `buck2 test` refuse to start (numa_guard: REFUSING to run);
#      there, the same `buck2 test` command minus the guard
#      (tests//functional/numa:gate_run) passes through the gate runner, which is how
#      a multi-NUMA worker would run it.
#  12. Actions run with their platform's property set, read per action: an
#      uncached build of //tools/build/examples:hello and
#      //tools/build/third_party_srcs:aws_lc_mini_gen (its own daemon under a
#      fixed --isolation-dir, --no-remote-cache, so every action really executes)
#      must record the light set for zig_unpack, zig_build_exe, conda_unpack,
#      mojo_runtime, fixture_archive and third_party_srcs, and the mojo_compile set for mojo_build (`buck2 log
#      what-ran`; a cache hit records no properties, so a warm build cannot
#      answer this). Costs about 3 minutes of remote execution; the isolated
#      daemon's buck-out/komira_tests_uncached (~50 MB) is reused per run.
#  13. A program built as a bundle behaves as its executable: stdout, stderr
#      and exit status agree byte for byte across argv, environment, exit(),
#      an unhandled error, buffered output, a data file found through
#      /proc/self/exe, abort() and SIGSEGV (status and stdout exact, the
#      stack dump's first line), and a symlink invocation with another
#      argv[0] (tests//functional/bundle_parity:parity, a remote action).
#  14. The launcher's CPU level function gives glibc's level for the made-up
#      CPUs of tools/build/package/launcher/cpu_models.h: the hand-written ones, and one
#      per feature glibc requires, a CPU of that level or above with just that
#      bit cleared (//tools/build/package:level_test, a remote action). On an x86-64
#      glibc host, its level for this host's CPU agrees with this host's
#      glibc loader (tools/build/tests/functional/glibc_level.sh).
#  15. The bundle of //tools/build/examples:hello (tools/build/tests/functional/bundle.sh): layout, run paths
#      and SHA256SUMS; it runs from a relocated copy and through a symlink on
#      PATH; a CPU below x86-64-v3 gets the one-line refusal (test launcher);
#      two uncached builds give byte-identical bundles, tarballs and docker
#      archives and the same image digest (skipped with --no-uncached; about
#      3 minutes of remote execution).
#  16. The package formats of //tools/build/examples:hello (tools/build/tests/functional/formats.sh): the
#      tarball and the OCI image follow the determinism rules and hold the
#      bundle; the image's blobs, config (entrypoint, linux/amd64) and pinned
#      base layers are checked; the base is fetched only by pinned
#      downloads; `docker run` of the loaded image prints the greeting (SKIP
#      without docker).
#  17. Markdown links are a validation of the build: //:docs (every Markdown
#      file of the repository) and tests//functional/doc_links:ok build, and
#      tests//negative/doc_links:dead fails naming a missing file, a bad
#      #anchor and a link leaving the tree. Every package of the komira and
#      tests cells is in //:docs through the doc_tree its rules declare, the
#      toolchains cell (not in it) holds no Markdown, no BUCK file but one
#      names a doc_tree (the rules do), and neither cell sets `[project] package_boundary_exceptions` (a
#      prefix covering one package covers every package under it, so a
#      target could own another package's files).
#  18. The configuration hashes of exec-light, exec-mojo and linux-x86_64 equal
#      their pins: they are in the digest of every configured action.
#  19. What a repository using komira as a cell loads names no cell but
#      komira, prelude and toolchains: every label outside a comment in the
#      BUCK and .bzl files of tools/build/{mojo,rust,proto-codegen,toolchains,
#      platforms,package,examples,cells} and third_party. A label naming `tests`
#      (standalone-only) fails to load there.
#  20. C/C++ dependencies of Mojo targets: see tools/build/tests/cxx_tests.sh.
#  21. A Mojo binary whose own code records a source location (a List
#      index) builds and runs: the compile wrapper strips the staging
#      directory from recorded paths, so its exit-4 refusal does not fire
#      (tests//functional/location_path).
#  22. Rust rules, and rustc's host floor: see
#      tools/build/tests/rust_tests.sh.
#  23. mojo_proto_library and mojo_db_proto_library, and deterministic
#      generation across two uncached
#      builds (skipped with --no-uncached; about 16 minutes): see
#      tools/build/tests/proto_tests.sh.
#  24. The macOS arm64 target and execution platform: registration only when
#      configured, resolution, compile command lines, linux actions
#      unchanged, the osx-arm64 closure's Mach-O load commands (unpacked on
#      the farm), the macOS scripts against stand-ins (the wrapper's compile
#      watchdog included), and, when the macOS
#      workers are configured, a build and run check of
#      //tools/build/examples:hello on them (tools/build/tests/functional/darwin/check.sh).
#  25. A fresh clone with no `.buckconfig.local` builds locally: in a scratch
#      clone of the working tree, with no user or system buckconfig, every
#      registered execution platform is local-only, Mojo and toolchain
#      targets resolve to them, and forcing remote execution there refuses,
#      naming `[komira_re]`; and three toolchain actions (a zig unpack and two
#      concurrent zig program builds, no Mojo compile) run locally with an
#      empty PATH (tools/build/tests/functional/local_default.sh). Runs in both modes.
#  26. The vendored aws-lc and s2n-tls: source lists against their archives,
#      known-answer tests, a TLS handshake, the s2n-tls feature probes: see
#      tools/build/tests/c_libs_tests.sh.
#  27. mojo_library's tests_known_failing inverts rather than mutes
#      (tests//functional/known_failing): a held test that fails is satisfied (marker
#      `HELD`), a held test that passes is red (LEDGER STALE, naming its row),
#      an unheld red beside a hold is still red, and every inadmissible row
#      (no issue, an issue that is not a GitHub issue reference, an empty
#      reason, an entry that is not a test, an unknown field, byte-identical
#      reasons, every test held) is refused at analysis.
#  28. The compile watchdog of mojo_wrapper.sh on stand-in compilers
#      (tests//functional/watchdog:cases, a remote action): a process tree using no CPU
#      is killed with exit 124 and the message, its children and an orphaned
#      grandchild with it; a tree using CPU (itself, through a child, or
#      through an orphaned member of its session while it waits), a
#      short idle and a disabled watchdog are not killed; a compiler error
#      keeps its exit status; malformed knobs are refused (exit 2); and the
#      compiler dies with the wrapper: TERM to the wrapper kills compiler and
#      child before it exits 143, and after a KILL the tether in the
#      compiler's session kills them within 5 s. The macOS wrapper's
#      watchdog (ps rather than /proc) is part of test 24.
#  29. The test runtime contract (tests//functional/test_data): a gated test opens a
#      declared fixture by its repository path from its staged share/, and a
#      fixture it did not declare is absent (the gate goes red); TEST_TMPDIR
#      is private, empty and not /tmp in each of two actions; test_env and a
#      mojo_test's data and env arrive under `buck2 test`; a red test stays
#      red with test_env {HELD: 1} (library) and env {BIN: true} (mojo_test);
#      the runner itself, run twice in ONE action directory
#      (tests//functional/test_data:runner_cases), gives each run its own empty
#      TEST_TMPDIR under that directory and removes it, no --env reaches
#      the verdict, and a held test killed by SIGKILL fails (137, NO VERDICT)
#      with no marker while other signal deaths stay HELD; five inadmissible
#      data/env declarations are refused at analysis.
#  30. Optimization levels, read from each compile command (buck2 aquery,
#      analysis only): mojo_test and a mojo_library's gated tests at -O1,
#      mojo_binary and the shared libraries of a bundle at -O3, a per-target
#      override honoured either way; a level mojo build does not accept is
#      refused at analysis (tools/build/tests/functional/opt_level.sh).
#  31. Lints are part of the build: a planted shellcheck warning in a script
#      the rules run fails the build of a Mojo and a Rust example
#      (tools/build/tests/negative/lint_weld.sh).
#  32. The ./buck2 bootstrap installs only what tools/buck2 pins
#      (tools/build/tests/functional/bootstrap.sh; a made-up release, no network).
#  33. The client is Linux x86_64: several tests run binaries built for the
#      farm, and ELF tools, on this machine, so on any other client this
#      script stops before it builds anything (exit 2). `--host-check-only`
#      stops after that test; run with a `uname` reporting macOS arm64 it must
#      refuse, and with this machine's, pass.
#  34. aws-client-gen (tests//functional/aws_codegen): the CloudWatch Logs
#      GetLogEvents module, pure and client, and the layout probe of each,
#      equal their text goldens byte for byte; the generator refuses an empty
#      or missing operation list, an operation the model lacks, a protocol it
#      does not implement, a missing, malformed (not 64 lowercase hex digits)
#      or wrong --model-sha256, a zero-byte model, and --probe-import without
#      --probe-out, and writes no file when it refuses. A golden that
#      differs, and a refusal check given inputs the generator accepts, both
#      go red (tests//negative/aws_codegen).
set -uo pipefail

umbrella=1
run=1
uncached=1
host_only=0
for a in "$@"; do
    case "$a" in
        --no-umbrella) umbrella=0 ;;
        --no-run) run=0 ;;
        --no-uncached) uncached=0 ;;
        --host-check-only) host_only=1 ;;
        *) echo "usage: $0 [--no-umbrella] [--no-run] [--no-uncached] [--host-check-only]" >&2; exit 2 ;;
    esac
done

# Several tests run what the farm built for Linux x86_64 (the inspect tool,
# the example binaries and bundles) and readelf/objdump on this machine. On
# another client they would fail one by one, looking like defects; stop here
# instead. `./buck2 build //...` and `./buck2 test //...` work from any client.
client=$(uname -s) arch=$(uname -m)
if [ "$client $arch" != "Linux x86_64" ]; then
    echo "run_tests.sh: needs a Linux x86_64 client, this is $client $arch: the tests run Linux x86_64 binaries and ELF tools here. ./buck2 build //... and ./buck2 test //... run from any client." >&2
    exit 2
fi
if [ "$host_only" = 1 ]; then
    echo "run_tests.sh: client $client $arch"
    exit 0
fi

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
if [ -z "${BUCK2:-}" ]; then
    BUCK2="$ROOT/buck2"
fi
# Logs, and the scratch checkouts of tests 7 and 9, go under $TMPDIR. Where
# /tmp is memory, point TMPDIR at a disk directory. The checkouts are deleted
# on exit, pass or fail (KEEP_SCRATCH=1 keeps them); logs are kept.
LOG=$(mktemp -d "${TMPDIR:-/tmp}/komira_tests.XXXXXX")
export INSPECT_LOG="$LOG/inspect_build.log"
. "$ROOT/tools/build/tests/tool_lib.sh"
fails=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails + 1)); }
needs_remote() { echo "SKIP  $1: needs a remote-execution service; this run is local-only (DEVELOPMENT.md, step 3)"; }

# Local or remote: read from the executor of every execution platform buck2
# registers, so `-c`, a user buckconfig and `.buckconfig.local` all count.
EP=$(cfg_value build.execution_platforms)
if [ -z "$EP" ] || ! "$BUCK2" audit providers "$EP" > "$LOG/mode.txt" 2>> "$LOG/mode.err"; then
    echo "FAIL  mode: cannot read the registered execution platforms (see $LOG/mode.err)"
    exit 1
fi
n_platforms=$(grep -c 'executor_config=' "$LOG/mode.txt")
n_local=$(grep -c 'executor: Local(' "$LOG/mode.txt")
if [ "$n_platforms" = 0 ]; then
    echo "FAIL  mode: $EP registers no execution platform (see $LOG/mode.txt)"
    exit 1
elif [ "$n_local" = "$n_platforms" ]; then
    MODE=local
    EXEC_RE='^local'
    echo "MODE  local: no remote-execution service is configured, so every action of these tests runs on this machine ($n_platforms local execution platforms from $EP)."
    echo "      Skipped here, they need one: 7 umbrella cache, 9 buck2 run, 10 registered multi-NUMA platform, 11 multi-NUMA hardware, 12 action platforms, 24 macOS. To run them, configure .buckconfig.local (DEVELOPMENT.md, step 3)."
elif [ "$n_local" = 0 ]; then
    MODE=remote
    EXEC_RE='^(re\(|cache)'
    echo "MODE  remote: every action runs on the remote-execution service in .buckconfig.local ($n_platforms remote execution platforms from $EP)."
else
    echo "FAIL  mode: $EP mixes $n_local local and $((n_platforms - n_local)) remote execution platforms; these tests expect one kind (see $LOG/mode.txt)"
    exit 1
fi
export KOMIRA_CHECKS_MODE=$MODE

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
    //tools/build/mojo/runtime_paths:komira_runtime_paths
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

# Each execution platform enables one executor, remote or local; this reads
# the build log to confirm every action used it. Only meaningful when
# something executed: an invocation with nothing to do proves nothing, and
# says so.
check_executor() { # name
    local name=$1 executed
    if ! "$BUCK2" log what-ran > "$LOG/$name.what_ran.txt" 2>&1; then
        fail "$name: cannot read what-ran"
        return
    fi
    executed=$(awk -F'\t' 'NF >= 3' "$LOG/$name.what_ran.txt" | wc -l)
    if awk -F'\t' -v re="$EXEC_RE" 'NF >= 3 && $3 !~ re' "$LOG/$name.what_ran.txt" | grep -q .; then
        fail "$name: an action ran outside $MODE execution (see $LOG/$name.what_ran.txt)"
    elif [ "$executed" = 0 ]; then
        echo "SKIP  $name: nothing executed in this invocation, $MODE-only not re-observed"
    elif [ "$MODE" = local ]; then
        pass "$name: all $executed executed actions ran locally"
    else
        pass "$name: all $executed executed actions were remote runs or remote cache hits"
    fi
}

# 1
expect_green examples "${EXAMPLES[@]}"
check_executor examples
expect_green run_checks "${RUN_CHECKS[@]}"
check_executor run_checks

# 2
expect_red gate_red "GATED TEST FAILED" tests//negative/libgate_bad:libgate_bad
expect_green gate_ungated_green "tests//negative/libgate_bad:libgate_bad[ungated]"
expect_red gate_consumer_red "GATED TEST FAILED" tests//negative/libgate_bad:gated_consumer
expect_red gate_bypass_refused "MojoInfo" tests//negative/libgate_bad:bypass_consumer

# 3
# Its red depends on the executor staging only declared inputs. A local action
# is not sandboxed and runs in the checkout root, where the compiler might find
# hellopkg's source without the dep; nobody has measured whether it does, so a
# local run does not quote this test as a gate.
if [ "$MODE" = local ]; then
    echo "SKIP  missing_dep: needs remote input isolation; a local action is not sandboxed and may see the undeclared package in the checkout (DEVELOPMENT.md, step 4)"
else
    expect_red missing_dep "unable to locate module 'hellopkg'" tests//negative/missing_dep:missing_dep
fi

# 4
expect_red closure_refusal "REFUSING: toolchain member" tests//negative/closure_refusal:hello_incomplete_toolchain

# 5
# The scan covers the Rust and protobuf actions too (rustc, protoc, the
# plugin, the generated packages), and aws-lc's and s2n-tls's.
SCAN=("${EXAMPLES[@]}" "${RUN_CHECKS[@]}" //tools/build/examples/rust:prost_roundtrip
    tests//functional/proto:test_person tests//functional/proto:team_proto
    //tools/build/examples/aws_lc:test_aws_lc //tools/build/examples/s2n_tls:test_s2n_handshake)
query="deps(set($(printf '"%s" ' "${SCAN[@]}")))"
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
if ! "$BUCK2" build tests//functional/runtime_libs:loader_trace --show-full-simple-output > "$LOG/loader.txt" 2> "$LOG/loader.log"; then
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
tests//functional/numa:hello komira//tools/build/platforms:exec-mojo
komira//tools/build/toolchains:zig komira//tools/build/platforms:exec-light
komira//tools/build/toolchains:conda_unpack komira//tools/build/platforms:exec-light
komira//tools/build/toolchains:mojo_compiler komira//tools/build/platforms:exec-light
komira//tools/build/toolchains:mojo_runtime komira//tools/build/platforms:exec-light
komira//tools/build/third_party_srcs:aws-lc-mini.tar.gz komira//tools/build/platforms:exec-light
komira//tools/build/third_party_srcs:aws_lc_mini_gen komira//tools/build/platforms:exec-light
komira//tools/build/third_party_srcs:aws_lc_mini_drift komira//tools/build/platforms:exec-light
komira//third_party/aws-lc:srcs_gen komira//tools/build/platforms:exec-light
tests//functional/numa:hello_multi_numa FAILED"
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
if printf '%s\n' "${got:-}" | grep -qx 'tests//functional/numa:hello_multi_numa FAILED'; then
    if "$BUCK2" build "${NO_MULTI[@]}" tests//functional/numa:hello_multi_numa > "$LOG/numa_refusal.log" 2>&1; then
        fail "multi-NUMA refusal: tests//functional/numa:hello_multi_numa built with no numa_multi platform"
    # Literal wording of buck2 2026-09-15 (tools/buck2). A buck2 release that
    # rewords it turns this test red, not green; update it with the pin.
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
    fail "multi-NUMA refusal: not attempted, the audit resolved tests//functional/numa:hello_multi_numa"
fi
if [ "$MODE" = local ]; then
    needs_remote "multi-NUMA platform (registered only from [komira_re])"
elif ! got=$(resolve platforms_multi -c komira_re.mojo_compile_multi_numa_properties=pool=unreachable-check-only \
        tests//functional/numa:hello_multi_numa komira//tools/build/examples:hello); then
    fail "multi-NUMA platform: audit failed (see $LOG/platforms_multi.txt)"
elif [ "$(printf '%s\n' "$got" | LC_ALL=C sort)" != "$(printf '%s\n' 'tests//functional/numa:hello_multi_numa komira//tools/build/platforms:exec-mojo-multi-numa' 'komira//tools/build/examples:hello komira//tools/build/platforms:exec-mojo' | LC_ALL=C sort)" ]; then
    fail "multi-NUMA platform: with one registered, got [$(printf '%s\n' "$got" | tr '\n' ' ')] (see $LOG/platforms_multi.txt)"
else
    pass "multi-NUMA platform: when registered, only the multi-NUMA run resolves to it"
fi

# 11
if ! "$BUCK2" build tests//functional/numa:guard_cases --show-full-simple-output > "$LOG/guard_cases.txt" 2> "$LOG/guard_cases.log"; then
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
    cfg_value "komira_re.$1"
}
action_platforms() { # what-ran json: every category ran remotely, with its platform's set
    local light mojo acts
    light=$(props_norm "$LIGHT_PROPS")
    mojo=$(props_norm "$MC_PROPS")
    if [ "$light" = "$mojo" ]; then
        echo "light and mojo_compile property sets are equal; nothing to tell apart"
        return 1
    fi
    acts=$(whatran_actions "$1") || { echo "cannot read $1"; return 1; }
    printf '%s\n' "$acts" | awk -F '\t' -v L="$light" -v M="$mojo" '
        BEGIN {
            n = split("conda_unpack fixture_archive mojo_build mojo_runtime third_party_srcs zig_build_exe zig_unpack", order, " ")
            for (i = 1; i <= n; i++) want[order[i]] = L
            want["mojo_build"] = M
        }
        !($1 in want) { next }
        {
            seen[$1]++; total++
            if ($2 != "Re" || $3 == "-") msg = $1 " ran as " $2 ", not a remote execution"
            else if ($3 != want[$1]) msg = $1 " ran with the " ($3 == M ? "mojo_compile" : ($3 == L ? "light" : "an unknown")) " set"
            else next
            bad = bad (bad == "" ? "" : "; ") msg
        }
        END {
            for (i = 1; i <= n; i++) if (!(order[i] in seen)) missing = missing " " order[i]
            if (missing != "") bad = bad (bad == "" ? "" : "; ") "not executed:" missing
            if (bad != "") { print bad; exit 1 }
            printf "%d actions: conda_unpack/fixture_archive/mojo_runtime/third_party_srcs/zig_build_exe/zig_unpack on light, mojo_build on mojo_compile\n", total
        }'
}
MC_PROPS=$(re_value mojo_compile_properties)
LIGHT_PROPS=$(re_value light_properties)
if [ "$MODE" = local ]; then
    needs_remote "multi-NUMA hardware (the stand-in reuses the [komira_re] worker sets)"
elif [ -z "$MC_PROPS" ] || [ -z "$LIGHT_PROPS" ]; then
    fail "multi-NUMA hardware: cannot read [komira_re] mojo_compile_properties / light_properties"
else
    if "$BUCK2" audit execution-platform-resolution -c "komira_re.mojo_compile_multi_numa_properties=$MC_PROPS" \
            tests//functional/numa:hello_multi_numa > "$LOG/numa_same_set.log" 2>&1; then
        fail "multi-NUMA hardware: a multi-NUMA property set equal to mojo_compile was accepted"
    elif ! grep -qF 'but it equals `mojo_compile`' "$LOG/numa_same_set.log"; then
        fail "multi-NUMA hardware: the equal-set refusal failed for another reason (see $LOG/numa_same_set.log)"
    else
        pass "multi-NUMA hardware: a multi-NUMA property set equal to mojo_compile is refused at load"
    fi
    # The stand-in routes numa_multi to the single-NUMA workers. A timeout
    # bounds each invocation: an unknown property set queues forever.
    STANDIN=(-c build.execution_platforms=tests//negative/numa_standin:single_numa_standin
             -c "tests//komira_re.mojo_compile_properties=$MC_PROPS"
             -c "tests//komira_re.light_properties=$LIGHT_PROPS")
    if timeout 600 "$BUCK2" build "${STANDIN[@]}" tests//functional/numa:hello_multi_numa > "$LOG/numa_standin.log" 2>&1; then
        fail "multi-NUMA hardware: the run check went green on single-NUMA workers"
    elif ! grep -qF 'numa_guard: REFUSING to run' "$LOG/numa_standin.log"; then
        fail "multi-NUMA hardware: the stand-in build failed without the guard's refusal (see $LOG/numa_standin.log)"
    else
        pass "multi-NUMA hardware: run check refused on single-NUMA workers ($(grep -o -m1 'usable NUMA nodes \[[^]]*\]' "$LOG/numa_standin.log"))"
    fi
    if timeout 600 "$BUCK2" test "${STANDIN[@]}" tests//functional/numa:hello_multi_numa > "$LOG/numa_standin_test.log" 2>&1; then
        fail "multi-NUMA hardware: buck2 test passed on single-NUMA workers"
    elif ! grep -qF 'numa_guard: REFUSING to run' "$LOG/numa_standin_test.log"; then
        fail "multi-NUMA hardware: buck2 test failed without the guard's refusal (see $LOG/numa_standin_test.log)"
    else
        pass "multi-NUMA hardware: buck2 test refused on single-NUMA workers"
    fi
    if ! timeout 600 "$BUCK2" build "${STANDIN[@]}" tests//functional/numa:gate_run --show-full-simple-output > "$LOG/numa_gate_run.txt" 2> "$LOG/numa_gate_run.log"; then
        fail "multi-NUMA gate run: tests//functional/numa:gate_run failed to build (see $LOG/numa_gate_run.log)"
    else
        report=$(tail -n 1 "$LOG/numa_gate_run.txt")
        if [ "$(head -n 1 "$report")" = "rc 0" ]; then
            pass "multi-NUMA gate run: the rule's buck2 test command, minus the guard, passes the gate runner"
        else
            fail "multi-NUMA gate run: $(head -n 4 "$report" | tr '\n' ' ')(see $report)"
        fi
    fi
fi

# 12
ISO=komira_tests_uncached
if [ "$MODE" = local ]; then
    needs_remote "action platforms (per-action worker property sets)"
elif [ -z "${MC_PROPS:-}" ] || [ -z "${LIGHT_PROPS:-}" ]; then
    fail "action platforms: cannot read [komira_re] mojo_compile_properties / light_properties"
# The isolated daemon keeps its outputs between runs, and --no-remote-cache
# does not rerun an action whose output is already on disk: clean first, or
# a second run of these tests in the same checkout executes nothing.
elif ! "$BUCK2" --isolation-dir "$ISO" clean > "$LOG/uncached_clean.log" 2>&1; then
    fail "action platforms: cannot clean the isolated buck-out (see $LOG/uncached_clean.log)"
elif ! timeout 900 "$BUCK2" --isolation-dir "$ISO" build --no-remote-cache //tools/build/examples:hello //tools/build/third_party_srcs:aws_lc_mini_gen > "$LOG/uncached.log" 2>&1; then
    fail "action platforms: uncached build failed (see $LOG/uncached.log)"
elif ! "$BUCK2" --isolation-dir "$ISO" log what-ran --format json > "$LOG/uncached.what_ran.json" 2>&1; then
    fail "action platforms: cannot read what-ran"
elif ! verdict=$(action_platforms "$LOG/uncached.what_ran.json"); then
    fail "action platforms: ${verdict:-no verdict} (see $LOG/uncached.what_ran.json)"
else
    pass "action platforms: $verdict"
fi
[ "$MODE" = local ] || "$BUCK2" --isolation-dir "$ISO" kill > /dev/null 2>&1

# 13
if "$BUCK2" build tests//functional/bundle_parity:parity --show-full-simple-output > "$LOG/parity.txt" 2> "$LOG/parity.log"; then
    pass "bundle parity: $(tail -n 1 "$(tail -n 1 "$LOG/parity.txt")") between executable and bundle"
else
    fail "bundle parity: $(grep -m1 -E '^[0-9]+ cases' "$LOG/parity.log") (see $LOG/parity.log)"
fi

# 14
if "$BUCK2" build //tools/build/package:level_test --show-full-simple-output > "$LOG/level.txt" 2> "$LOG/level.log"; then
    lt=$(tail -n 1 "$LOG/level.txt")
    ltbin=$("$BUCK2" build '//tools/build/package:level_test[bin]' --show-full-simple-output 2>> "$LOG/level.log" | tail -n 1)
    rc=0; here=$("$ROOT/tools/build/tests/functional/glibc_level.sh" "$ltbin") || rc=$?
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
BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/bundle.sh" ${bundle_args[@]+"${bundle_args[@]}"} > "$LOG/bundle.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  bundle "*) pass "${line#PASS  }" ;;
        "FAIL  bundle "*) fail "${line#FAIL  } (see $LOG/bundle.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/bundle.log"
grep -qE '^(PASS|FAIL)  bundle ' "$LOG/bundle.log" || fail "bundle: tools/build/tests/functional/bundle.sh reported nothing (see $LOG/bundle.log)"

# 16
BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/formats.sh" > "$LOG/formats.log" 2>&1
while IFS= read -r line; do
    case "$line" in
        "PASS  formats "*) pass "${line#PASS  }" ;;
        "FAIL  formats "*) fail "${line#FAIL  } (see $LOG/formats.log)" ;;
        "SKIP  "*) echo "$line" ;;
    esac
done < "$LOG/formats.log"
grep -qE '^(PASS|FAIL)  formats ' "$LOG/formats.log" || fail "formats: tools/build/tests/functional/formats.sh reported nothing (see $LOG/formats.log)"

# 17
# //:docs is the repository's Markdown: its validation fails on a dead link.
# The negative fixture plants one link per diagnostic beside two that
# resolve; the validation must name each dead one with its reason, and only
# those.
expect_green docs //:docs tests//functional/doc_links:ok
DEAD=(
    'dead.md:4: sub/missing.md (no such file)'
    'dead.md:5: sub/a.md#nope (no heading #nope)'
    'dead.md:6: ../outside.md (leaves the repository)'
    'doc links: 3 of 5 relative links do not resolve'
)
missed=""
if "$BUCK2" build tests//negative/doc_links:dead > "$LOG/doc_links_dead.log" 2>&1; then
    missed="(it built)"
else
    for want in "${DEAD[@]}"; do
        grep -qF "$want" "$LOG/doc_links_dead.log" || missed="$missed [$want]"
    done
fi
if [ -n "$missed" ]; then
    fail "doc links: tests//negative/doc_links:dead must fail naming each planted link; missed $missed (see $LOG/doc_links_dead.log)"
else
    pass "doc links: tests//negative/doc_links:dead fails naming its missing file, bad anchor and escaping link"
fi
# Each package's rules declare its doc_tree, which names its own files (a
# glob stops at a subpackage) and collects its subpackages' doc_trees, so
# //:docs holds every package with no list. A package left out would drop
# its Markdown from the check without a word, and a BUCK file naming its
# doc_tree is the boilerplate the rules replace.
pkgs() { sed -e 's/:[^:]*$//' | LC_ALL=C sort -u; }
if "$BUCK2" uquery '//... + tests//...' > "$LOG/doc_pkgs_all.txt" 2> "$LOG/doc_pkgs.log" &&
   "$BUCK2" uquery 'kind(doc_tree, deps(//:docs))' > "$LOG/doc_pkgs_docs.txt" 2>> "$LOG/doc_pkgs.log"; then
    missing=$(LC_ALL=C comm -23 <(pkgs < "$LOG/doc_pkgs_all.txt") <(pkgs < "$LOG/doc_pkgs_docs.txt") | tr '\n' ' ')
    n=$(pkgs < "$LOG/doc_pkgs_all.txt" | wc -l)
    if [ "$n" -lt 2 ]; then
        fail "doc links: \`uquery //... + tests//...\` found $n packages (see $LOG/doc_pkgs_all.txt)"
    elif [ -n "$missing" ]; then
        fail "doc links: packages with no doc_tree in //:docs: $missing"
    else
        pass "doc links: all $n packages of the komira and tests cells are in //:docs, each through the doc_tree its rules declare"
    fi
else
    fail "doc links: the package queries failed (see $LOG/doc_pkgs.log)"
fi
# The toolchains cell is not in //:docs (the root BUCK says why), so it may
# hold no Markdown.
tc_md=$(cd "$ROOT" && git ls-files -- 'tools/build/cells/*.md' | tr '\n' ' ')
if [ -n "$tc_md" ]; then
    fail "doc links: the toolchains cell, which //:docs does not read, holds Markdown: $tc_md"
else
    pass "doc links: the toolchains cell, which //:docs does not read, holds no Markdown"
fi
# The one BUCK file that calls package_docs() itself declares a target only
# when configured (tools/build/lint/doc_tree.bzl).
named=$(cd "$ROOT" && git ls-files -- BUCK '*/BUCK' | xargs grep -lE '^[[:space:]]*(doc_tree|package_docs)[(]' | grep -vxF tools/build/tests/negative/numa_standin/BUCK | tr '\n' ' ' || true)
if [ -n "$named" ]; then
    fail "doc links: BUCK files name a doc_tree or call package_docs, which the rules declare: $named"
else
    pass "doc links: no BUCK file names a doc_tree; the rules declare each package's"
fi
exc=""
for cell in komira tests; do
    v=$("$BUCK2" audit config --cell "$cell" project.package_boundary_exceptions 2>> "$LOG/doc_pkgs.log") || { exc="$exc $cell:(audit failed)"; continue; }
    v=$(printf '%s\n' "$v" | grep -v '^\[' | grep -v '^ *$' || true)
    [ -z "$v" ] || exc="$exc $cell:[$v]"
done
if [ -n "$exc" ]; then
    fail "package boundaries: [project] package_boundary_exceptions is set:$exc (see $LOG/doc_pkgs.log)"
else
    pass "package boundaries: neither cell sets [project] package_boundary_exceptions"
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
. "$ROOT/tools/build/tests/cxx_tests.sh"

# 21
expect_green location_path "tests//functional/location_path:main[run_check]"

# 22
# shellcheck source=tools/build/tests/rust_tests.sh
. "$ROOT/tools/build/tests/rust_tests.sh"

# 23
# shellcheck source=tools/build/tests/proto_tests.sh
. "$ROOT/tools/build/tests/proto_tests.sh"

# 26 (before 24, which prints its own lines)
# shellcheck source=tools/build/tests/c_libs_tests.sh
. "$ROOT/tools/build/tests/c_libs_tests.sh"

# 24
if [ "$MODE" = local ]; then
    needs_remote "darwin (macOS arm64 builds run on macOS workers of a remote service)"
else
darwin_rc=0
darwin_out=$(cd "$ROOT" && BUCK2="$BUCK2" bash tools/build/tests/functional/darwin/check.sh "$LOG" 2>&1) || darwin_rc=$?
printf '%s\n' "$darwin_out" > "$LOG/darwin.log"
grep -E '^(PASS|FAIL|SKIP)  ' "$LOG/darwin.log"
darwin_fails=$(grep -c '^FAIL  ' "$LOG/darwin.log" || true)
if [ "$darwin_rc" != 0 ] && [ "$darwin_fails" = 0 ]; then
    fail "darwin: tools/build/tests/functional/darwin/check.sh exited $darwin_rc without a FAIL line (see $LOG/darwin.log)"
fi
fails=$((fails + darwin_fails))
fi

# 25
if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/local_default.sh" > "$LOG/local_default.log" 2>&1; then
    pass "local default: $(grep -o 'PASS  local default: .*' "$LOG/local_default.log" | cut -c 22-)"
else
    fail "local default: $(grep -o 'FAIL  local default: .*' "$LOG/local_default.log" | cut -c 22-) (see $LOG/local_default.log)"
fi

# 27
if "$BUCK2" build tests//functional/known_failing:held_ok --show-full-simple-output > "$LOG/kf_held_ok.log" 2>&1; then
    "$BUCK2" build 'tests//functional/known_failing:held_ok[tests][test_fails]' --show-full-simple-output > "$LOG/kf_marker.log" 2>&1
    kf_marker=$(tail -n 1 "$LOG/kf_marker.log")
    if [ "$(cat "$kf_marker" 2> /dev/null)" = "HELD tests//functional/known_failing:held_ok:tests/test_fails.mojo" ]; then
        pass "known_failing: a held test that fails satisfies the gate (HELD marker)"
    else
        fail "known_failing: held_ok built, but its held marker is '$(cat "$kf_marker" 2> /dev/null)' (see $LOG/kf_marker.log)"
    fi
else
    fail "known_failing: held_ok must build (see $LOG/kf_held_ok.log)"
fi
expect_red kf_held_passing 'tests_known_failing["tests/test_passes_too.mojo"]' tests//negative/known_failing:held_passing
expect_red kf_held_passing_stale "LEDGER STALE" tests//negative/known_failing:held_passing
expect_red kf_unheld_red "GATED TEST FAILED: tests//negative/known_failing:unheld_red:tests/test_fails_too.mojo" tests//negative/known_failing:unheld_red
expect_red kf_no_issue "no \`issue\`" tests//negative/known_failing:bad_no_issue
expect_red kf_issue_ref "is not a GitHub issue number" tests//negative/known_failing:bad_issue_ref
expect_red kf_empty_reason "empty \`reason\`" tests//negative/known_failing:bad_empty_reason
expect_red kf_entry "not a test_srcs entry" tests//negative/known_failing:bad_entry
expect_red kf_field "unknown field \`card\`" tests//negative/known_failing:bad_field
expect_red kf_same_reason "byte-identical reasons" tests//negative/known_failing:bad_same_reason
expect_red kf_all_held "holds all 2 tests" tests//negative/known_failing:bad_all_held

# 28
if ! "$BUCK2" build tests//functional/watchdog:cases --show-full-simple-output > "$LOG/watchdog_cases.txt" 2> "$LOG/watchdog_cases.log"; then
    fail "compile watchdog cases: $(grep '^BAD ' "$LOG/watchdog_cases.log" | sort -u | tr '\n' ' ')(see $LOG/watchdog_cases.log)"
else
    report=$(tail -n 1 "$LOG/watchdog_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 15 ]; then
        fail "compile watchdog cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "compile watchdog: $ok stand-in compilers, each killed (124) or left alone as required"
    fi
fi

# 29
expect_green td_declared tests//functional/test_data:declared
expect_red td_undeclared "No such file or directory" tests//negative/test_data:undeclared
expect_red td_undeclared_gate "GATED TEST FAILED: tests//negative/test_data:undeclared:" tests//negative/test_data:undeclared
if timeout 900 "$BUCK2" test tests//functional/test_data:mojo_test_data > "$LOG/td_mojo_test.log" 2>&1; then
    pass "td_mojo_test: buck2 test of a mojo_test with data and env"
else
    fail "td_mojo_test: buck2 test tests//functional/test_data:mojo_test_data failed (see $LOG/td_mojo_test.log)"
fi
expect_red td_env_held "GATED TEST FAILED: tests//negative/test_data:env_held:tests/test_red.mojo" tests//negative/test_data:env_held
if timeout 900 "$BUCK2" test tests//negative/test_data:env_bin > "$LOG/td_env_bin.log" 2>&1; then
    fail "td_env_bin: buck2 test tests//negative/test_data:env_bin passed, but its test is red (env BIN reached the runner; see $LOG/td_env_bin.log)"
elif grep -qF "test_red: DELIBERATE FAILURE" "$LOG/td_env_bin.log"; then
    pass "td_env_bin: env {BIN: true} does not replace a red mojo_test"
else
    fail "td_env_bin: failed without the test's own failure (see $LOG/td_env_bin.log)"
fi
if ! "$BUCK2" build tests//functional/test_data:runner_cases --show-full-simple-output > "$LOG/runner_cases.txt" 2> "$LOG/runner_cases.log"; then
    fail "gate runner cases: $(grep '^BAD ' "$LOG/runner_cases.log" | sort -u | tr '\n' ' ')(see $LOG/runner_cases.log)"
else
    report=$(tail -n 1 "$LOG/runner_cases.txt")
    ok=$(grep -c '^ok ' "$report" || true)
    if grep -q '^BAD ' "$report" || [ "$ok" -lt 5 ]; then
        fail "gate runner cases: $(grep -v '^ok ' "$report" | tr '\n' ' ') ($ok ok; see $report)"
    else
        pass "gate runner: $ok cases in one action (private TEST_TMPDIR per run; env cannot reach the verdict)"
    fi
fi
expect_red td_bad_dest "holds an empty, \`.\` or \`..\` segment" tests//negative/test_data:bad_dest
expect_red td_bad_dest_clash "is both a file and the directory of" tests//negative/test_data:bad_dest_clash
expect_red td_bad_data_entry "test_data[\"tests/test_nope.mojo\"]: not a test_srcs entry" tests//negative/test_data:bad_data_entry
expect_red td_bad_env_owned "env sets TEST_TMPDIR, which the test runner sets itself" tests//negative/test_data:bad_env_owned
expect_red td_bad_env_name "is not a shell variable name" tests//negative/test_data:bad_env_name

# 30
if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/opt_level.sh" "$LOG" > "$LOG/opt_level.log" 2>&1; then
    pass "$(grep -o 'PASS  optimization levels: .*' "$LOG/opt_level.log" | cut -c 7-)"
else
    fail "$(grep -o 'FAIL  optimization levels: .*' "$LOG/opt_level.log" | cut -c 7-) (see $LOG/opt_level.log)"
fi
expect_red opt_bad_level "optimization level \`fast\` is not one of 0, 1, 2, 3" tests//negative/opt_level:bad_level

# 31
if "$ROOT/tools/build/tests/negative/lint_weld.sh" > "$LOG/lint_weld.log" 2>&1; then
    pass "$(grep -m1 '^PASS' "$LOG/lint_weld.log" | cut -c 7-)"
else
    fail "$(grep -m1 '^FAIL' "$LOG/lint_weld.log" | cut -c 7-) (see $LOG/lint_weld.log)"
fi

# 32
if "$ROOT/tools/build/tests/functional/bootstrap.sh" "$LOG/bootstrap" > "$LOG/bootstrap.log" 2>&1; then
    pass "./buck2 bootstrap: $(grep -c '^PASS' "$LOG/bootstrap.log") cases: installs and caches a matching pin, refuses a wrong sha256 or size leaving the cache empty, reads tools/buck2"
else
    fail "./buck2 bootstrap: $(grep '^FAIL' "$LOG/bootstrap.log" | cut -c 18- | tr '\n' ' ')(see $LOG/bootstrap.log)"
fi

# 33
S="$LOG/uname_shim"
mkdir -p "$S/mac" "$S/here"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$S/mac/uname"
printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; *) echo %s ;; esac\n' "$(uname -s)" "$(uname -m)" "$(uname -s)" > "$S/here/uname"
chmod +x "$S/mac/uname" "$S/here/uname"
PATH="$S/mac:$PATH" "$ROOT/tools/build/tests/run_tests.sh" --host-check-only > "$LOG/client_mac.log" 2>&1
mac_rc=$?
PATH="$S/here:$PATH" "$ROOT/tools/build/tests/run_tests.sh" --host-check-only > "$LOG/client_here.log" 2>&1
here_rc=$?
if [ "$mac_rc" != 2 ] || ! grep -qF 'needs a Linux x86_64 client, this is Darwin arm64' "$LOG/client_mac.log"; then
    fail "client: on a macOS arm64 client run_tests.sh did not refuse (exit $mac_rc, see $LOG/client_mac.log)"
elif [ "$here_rc" != 0 ]; then
    fail "client: on this client run_tests.sh --host-check-only exited $here_rc (see $LOG/client_here.log)"
else
    pass "client: run_tests.sh refuses a macOS arm64 client (exit 2) and accepts $(uname -s) $(uname -m)"
fi

# 34
expect_green aws_codegen tests//functional/aws_codegen:
expect_red aws_codegen_golden_differs "differs from the golden" tests//negative/aws_codegen:golden_differs
expect_red aws_codegen_accepted "expected a refusal, and the generator exited 0" tests//negative/aws_codegen:accepted

# 9
if [ "$MODE" = local ]; then
    needs_remote "buck2 run (measures what a remote build downloads)"
elif [ "$run" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/buck2_run.sh" > "$LOG/buck2_run.log" 2>&1; then
        pass "buck2 run: $(grep -o 'PASS  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-)"
    else
        fail "buck2 run: $(grep -o 'FAIL  buck2 run: .*' "$LOG/buck2_run.log" | cut -c 18-) (see $LOG/buck2_run.log)"
    fi
else
    echo "SKIP  buck2 run (--no-run)"
fi

# 7
if [ "$MODE" = local ]; then
    needs_remote "umbrella cache (remote cache hits across checkouts)"
elif [ "$umbrella" = 1 ]; then
    if BUCK2="$BUCK2" "$ROOT/tools/build/tests/functional/umbrella_cache.sh" > "$LOG/umbrella.log" 2>&1; then
        pass "umbrella cache: $(grep -o 'PASS  umbrella cache: .*' "$LOG/umbrella.log" | cut -c 23-)"
    else
        fail "umbrella cache: $(grep -o 'FAIL  umbrella cache: .*' "$LOG/umbrella.log" | cut -c 23-) (see $LOG/umbrella.log)"
    fi
else
    echo "SKIP  umbrella cache (--no-umbrella)"
fi

echo "logs: $LOG"
[ "$fails" = 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all tests passed"
