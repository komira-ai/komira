#!/bin/sh
# cov_run.sh -- runs one welded test's coverage binary under kcov in a build
# action (`mojo_cov_run`, tools/build/mojo/coverage.bzl), through the release
# gate's runner (its environment, with the differences below), and writes the
# test's report in repository paths (README.md, "cov_run").
#
# usage: busybox sh <run_dir>/cov_run.sh <busybox> <gate_runner> <compiler_dir> <label>
#            <test_binary> <share> <src_dir> <xml_out> <marker_out>
#            <src_repo> <test> <test_repo> <import> [--gen <file>]... [--env NAME=VALUE]...
#
#   <run_dir>      the cov_run_dir: this script, kcov/ (bin/kcov, lib/), cov_normalize
#                  and limit (the seconds the run may take: 450, or a tests
#                  cell fixture's own)
#   <test_binary>  the test built at -O0 with line tables ([coverage][bin][<test>])
#   <share>        the test's declared data at their destinations, and its
#                  source at <test>, its path in the package (what the line
#                  tables name it by: `tests/test_x.mojo`)
#   <src_dir>      the library's staged sources ([src]); its path from the
#                  action's directory is the directory the line tables name
#                  them by (`buck-out/v2/art/<cell>/<package>/__<t>__/<hash>/src/<import>`)
#   <src_repo>     the repository directory <src_dir> stages, with a trailing
#                  `/` (empty for the repository's root)
#   <test_repo>    the repository path of the test source
#   <import>       the library's import name: <src_dir> ends in src/<import>
#   --gen <file>   a generated source in <src_dir> (its path there): not measured
#   --env          passed to gate_runner.sh as given
#
# Steps:
#   0. Every directory the binary names a source of the library by (a string
#      holding `buck-out/` and, inside an artifact, the path component
#      src/<import>) must be
#      <src_dir>: the run stages the sources there, and kcov drops a file it
#      cannot open without an error, so a binary that names them elsewhere
#      (another [src], an absolute compilation directory) is refused here.
#   1. A root is built from COPIES (never links: kcov resolves every source
#      name with realpath, which would leave a linked tree): bin/kcov and
#      lib/ (kcov's own libgcc_s, found through its DT_RPATH $ORIGIN/../lib),
#      bin/<test>, and share/ holding the test's data, its source at <test>
#      and the library's sources at <src_dir>. The pinned Mojo names every
#      source by a relative path and records no compilation directory, so
#      kcov, started in share/, resolves each name to the copy. A second
#      copy of the sources, lost/, is where a name that does NOT resolve
#      there lands (below).
#   2. gate_runner.sh (unchanged: the release gate's runner) runs bin/kcov as
#      the program of the test root: share/ is the working directory, PATH,
#      LD_LIBRARY_PATH, TMPDIR, TEST_TMPDIR and HOME are the gate's, each
#      --env is exported to kcov and so reaches the test. kcov's arguments:
#      --cobertura-only --skip-solibs --configure=cobertura-full-paths=1;
#      --include-path of exactly <src_dir> and this test, under share/ and
#      under lost/ (an --exclude-path per generated source);
#      --replace-src-path='^(?!/):<lost>/'; the output directory and
#      bin/<test>. komira's kcov exits with the test's status (128+N when a
#      signal N killed it), not another traced process's (the toolchain's
#      README.md, "Patches"), so a test that fails under kcov (at -O0, or
#      traced) fails this action, with the test's output from gate_runner
#      but not its banner (which says the library's package is not produced:
#      the package does not depend on a coverage run). kcov refused by the
#      executor (ptrace, personality) is reported as that.
#      The run is bounded: gate_runner runs in a session of its own (setsid),
#      and when it has not exited after <limit> seconds, every process of
#      that session (gate_runner, kcov, the test and any child it left) is
#      killed and the action fails, saying so. kcov waits for every process
#      the test started, so without the bound a test leaving a child running
#      would hold the action open.
#   3. kcov writes exactly one report (<out>/cov.xml); anything else fails.
#   4. cov_normalize maps <share>/<src_dir>/ to <src_repo> and the test's
#      directory under share/ to the repository's, requires the test's own
#      source in the report and refuses the action's directories in the
#      output. Its output is <xml_out>; then `PASS <label>` goes to
#      <marker_out>.
#
# What differs from the release gate: the test is traced (TracerPid is
# kcov's), runs without address randomization (kcov sets ADDR_NO_RANDOMIZE),
# its working directory share/ also holds its own source at <test> and the
# library's at <src_dir>, kcov shares its TMPDIR, its environment also holds
# KCOV_SOLIB_PATH, which kcov always sets (with --skip-solibs, no
# LD_PRELOAD), and the run ends when every process the test started has
# exited (kcov follows each fork), where the gate waits for the test alone;
# so it is bounded (step 2). Its CPUs are the gate's (kcov's pin is patched
# out).
#
# Why lost/: kcov drops a source file it cannot open without any error, so a
# source staged where the line tables do not name it would leave the report
# silently without it. kcov resolves a name with realpath first; a relative
# name that does not resolve from share/ stays relative, and the
# replacement makes it <lost>/<name>, which exists (the second copy), so kcov
# keeps it and the report names it under lost/. No --map covers lost/, so
# cov_normalize refuses it as unmapped, naming the file. A name that did
# resolve is absolute and the expression (a relative name) leaves it alone.
# lost/ only catches a name under <src_dir> or <test>; a name elsewhere is
# step 0's.
# The other names the binary holds (the Mojo standard library's
# `oss/modular/...`, zig's C runtime's `/___.../buck-out/...`) are outside the
# --include-path list and never reach the report; were one to, it would be
# unmapped too.
#
# <share> and <lost> are canonical (realpath) before they are given to kcov
# and used as a --map ABS: kcov reports realpath'd names (README.md, "Why").
#
# Exit status: the test's under kcov when it fails (gate_runner's); 1 when the
# binary names the sources elsewhere, the run passed its limit, or the report
# is missing or refused; 2
# for a usage error, which includes a `,` or `:` in a path given to kcov (its
# options split on them).
set -euf
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
[ "$#" -ge 13 ] || { echo "cov_run: usage error" >&2; exit 2; }
HERE=$(abs "${0%/*}")
BB=$(abs "$1")
GATE=$(abs "$2")
TC=$3
LABEL=$4
BIN=$(abs "$5")
SHARE=$(abs "$6")
SRC_REL=$7
XML=$(abs "$8")
MARKER=$(abs "$9")
shift 9
SRC_REPO=$1
TEST=$2
TEST_REPO=$3
IMPORT=$4
shift 4
case "$SRC_REL" in /* | "" | */) echo "cov_run: <src_dir> $SRC_REL must be a relative path from the action's directory" >&2; exit 2 ;; esac
case "$TEST" in /* | "" | */) echo "cov_run: <test> $TEST must be a relative file path" >&2; exit 2 ;; esac
case "$TEST_REPO" in /* | "" | */) echo "cov_run: <test_repo> $TEST_REPO must be a relative file path" >&2; exit 2 ;; esac
case "$SRC_REPO" in /* | ?*[!/]) echo "cov_run: <src_repo> $SRC_REPO must be empty or relative with a trailing /" >&2; exit 2 ;; esac
case "$IMPORT" in "" | *[!A-Za-z0-9_]*) echo "cov_run: <import> $IMPORT is not an import name" >&2; exit 2 ;; esac
case "$SRC_REL" in */src/"$IMPORT") ;; *) echo "cov_run: <src_dir> $SRC_REL does not end in src/$IMPORT" >&2; exit 2 ;; esac
SRC=$(abs "$SRC_REL")
LIMIT=$(cat "$HERE/limit")
case "$LIMIT" in "" | 0* | *[!0-9]*) echo "cov_run: $HERE/limit holds '$LIMIT', not a number of seconds" >&2; exit 2 ;; esac
case "$TEST" in */*) TEST_DIR=${TEST%/*}/ ;; *) TEST_DIR="" ;; esac
case "$TEST_REPO" in */*) TEST_REPO_DIR=${TEST_REPO%/*}/ ;; *) TEST_REPO_DIR="" ;; esac

GEN=""
while [ "$#" -gt 0 ] && [ "$1" = --gen ]; do
    [ "$#" -ge 2 ] || { echo "cov_run: --gen needs a file" >&2; exit 2; }
    case "$2" in "" | /* | *[,:\ ]*) echo "cov_run: --gen $2 must be a relative path without a space, , or :" >&2; exit 2 ;; esac
    GEN="$GEN $2"
    shift 2
done
# What is left is gate_runner's (--env NAME=VALUE...); it checks them.

# Private scratch (as in tools/build/mojo/toolchain.bzl): a local action runs
# in the checkout root, so it takes the directory buck2 names for it.
case "${BUCK_SCRATCH_PATH:-}" in
    "") K="$PWD/.cov_run" ;;
    /*) K="$BUCK_SCRATCH_PATH/cov_run" ;;
    *) K="$PWD/$BUCK_SCRATCH_PATH/cov_run" ;;
esac
"$BB" mkdir -p "$K/bin"
"$BB" --install -s "$K/bin"
PATH="$K/bin"
export PATH LC_ALL=C

red() {
    echo "==================================================================" >&2
    echo "COVERAGE RUN FAILED: $LABEL" >&2
    echo "$*" >&2
    echo "==================================================================" >&2
    exit 1
}

# 0. Where the binary names the library's sources. Each string is on a line
# of its own (tr), so the expression sees one name at a time. Only a
# src/<import> component inside an artifact (after buck2's __<target>__/
# directory) counts, and a name is cut after the last one: a komira
# library's package path is itself src/<import>
# (buck-out/v2/art/komira/src/<import>/__<import>__/<hash>/src/<import>).
tr '\000' '\n' <"$BIN" | grep -a -o -E '[A-Za-z0-9_./+@=-]*buck-out/[A-Za-z0-9_./+@=-]*' >"$K/names" || true
grep -E "/__[^/]+__/.*/src/$IMPORT(/|\$)" "$K/names" | sed -E "s|^(.*/src/$IMPORT)(/.*)?\$|\1|" | sort -u >"$K/dirs" || true
grep -v -x -F -e "$SRC_REL" "$K/dirs" >"$K/elsewhere" || true
if [ -s "$K/elsewhere" ]; then
    red "the test binary names the library's sources by $(tr '\n' ' ' <"$K/elsewhere")but this run stages them at $SRC_REL: kcov would drop them without an error (README.md, \"cov_run\")."
fi

# 1. The root and lost/, all copies.
R="$K/root"
L="$K/lost"
mkdir -p "$R/bin" "$R/lib" "$R/share"
NAME=${BIN##*/}
cp -L "$HERE/kcov/bin/kcov" "$R/bin/kcov"
cp -RL "$HERE/kcov/lib/." "$R/lib/"
cp -L "$BIN" "$R/bin/$NAME"
cp -RL "$SHARE/." "$R/share/"
[ -f "$R/share/$TEST" ] || red "the test's source $TEST is not in its share directory"
[ ! -e "$R/share/$SRC_REL" ] || red "the share directory already holds $SRC_REL (a data file under it?)"
mkdir -p "$R/share/$SRC_REL"
cp -RL "$SRC/." "$R/share/$SRC_REL/"
mkdir -p "$L/$SRC_REL" "$L/$TEST_DIR"
cp -RL "$SRC/." "$L/$SRC_REL/"
cp -L "$SHARE/$TEST" "$L/$TEST"
R=$(realpath "$R")
L=$(realpath "$L")
S="$R/share"
for p in "$S" "$L" "$SRC_REL" "$TEST"; do
    case "$p" in *[,:]*) echo "cov_run: $p holds a , or :, which kcov's options split on" >&2; exit 2 ;; esac
done
OUT="$K/kout"

EXCL=""
for g in $GEN; do
    EXCL="${EXCL:+$EXCL,}$S/$SRC_REL/$g,$L/$SRC_REL/$g"
done

# 2. kcov under the gate's runner.
set -- "$@" \
    --arg --cobertura-only \
    --arg --skip-solibs \
    --arg --configure=cobertura-full-paths=1 \
    --arg "--include-path=$S/$SRC_REL,$S/$TEST,$L/$SRC_REL,$L/$TEST"
[ -z "$EXCL" ] || set -- "$@" --arg "--exclude-path=$EXCL"
set -- "$@" \
    --arg "--replace-src-path=^(?!/):$L/" \
    --arg "$OUT" \
    --arg "$R/bin/$NAME"
# gate_runner leads a new session and process group, which kcov, the test
# and every child it starts join (setsid needs no fork: this shell has no job
# control, so its background job leads no group, and $! is gate_runner's
# pid). The watcher kills that whole group once the limit has passed; it
# stops when gate_runner has exited (and been reaped by the wait below).
rc=0
setsid "$BB" sh "$GATE" "$BB" "$TC" "$LABEL" "$R/bin/kcov" "$K/gate.passed" "$@" 2>"$K/gate.err" &
gate=$!
(
    s=0
    while kill -0 "$gate" 2>/dev/null; do
        if [ "$s" -ge "$LIMIT" ]; then
            : >"$K/timed_out"
            kill -s KILL "-$gate" 2>/dev/null
            exit 0
        fi
        sleep 1
        s=$((s + 1))
    done
) &
watch=$!
wait "$gate" || rc=$?
kill "$watch" 2>/dev/null || true
wait "$watch" || true
if [ -e "$K/timed_out" ]; then
    # gate_runner was killed, so its directory (mktemp under this one) and
    # the test's output in it are still there.
    find . -maxdepth 2 -path './.komira_test.*/log' -type f >"$K/logs" 2>/dev/null || true
    while read -r l; do
        echo "------------------------------------------------------------------ output (last 200 lines)" >&2
        tail -n 200 "$l" >&2
    done <"$K/logs"
    red "The test left processes running or did not finish within $LIMIT s under kcov, and every process of the run was killed: kcov waits for every process the test started, where the release gate waits for the test alone. A test must wait for (or kill) every child it starts."
fi
if [ "$rc" != 0 ]; then
    # gate_runner's banner says the library's package is not produced: not
    # so here (the package does not depend on a coverage run). Its other
    # lines, the test's output among them, are kept.
    awk -v H="GATED TEST FAILED: $LABEL (exit $rc)" \
        -v P="The library's package is not produced until this test passes." '
        !done && $0 == H { held = 1; next }
        held && $0 == P { held = 0; done = 1; next }
        held { print H; held = 0 }
        { print }' "$K/gate.err" >&2
    # kcov's own lines (perror's, and its error macro's): the test's output
    # is in the same log, so a line must start with them.
    if grep -E "^Can't set me as ptraced: |^Can't [gs]et personality: |^Can't attach to [0-9]" "$K/gate.err" >/dev/null; then
        why="kcov could not trace the test: this executor refuses ptrace or personality(ADDR_NO_RANDOMIZE) (a seccomp profile), and coverage cannot be measured on it."
    elif grep -E "^kcov: error: |^Usage: kcov " "$K/gate.err" >/dev/null; then
        why="kcov itself failed (its message is above), not the test."
    else
        why="The test failed under kcov (exit $rc). A coverage run builds the test at -O0 and runs it traced; a test that passes in the release gate and fails here fails this action, and is a bug to fix."
    fi
    echo "==================================================================" >&2
    echo "COVERAGE RUN FAILED: $LABEL" >&2
    echo "$why" >&2
    echo "==================================================================" >&2
    exit "$rc"
fi

# 3. Exactly one report.
[ -d "$OUT" ] || red "kcov wrote no output directory ($OUT)"
find "$OUT" -type f -name '*.xml' >"$K/xmls"
[ "$(grep -c . "$K/xmls")" = 1 ] || red "kcov wrote $(grep -c . "$K/xmls") XML report(s), expected exactly one: $(tr '\n' ' ' <"$K/xmls")"
IN=$(cat "$K/xmls")

# 4. Repository paths.
set -- --map "$S/$SRC_REL/=$SRC_REPO" --map "$S/$TEST_DIR=$TEST_REPO_DIR" \
    --must-contain "$TEST_REPO" --forbid "$PWD" --forbid "$R" --forbid "$L"
P=$(realpath "$PWD")
[ "$P" = "$PWD" ] || set -- "$@" --forbid "$P"
"$HERE/cov_normalize" --in "$IN" --out "$XML" "$@" >"$K/norm.log" 2>&1 || {
    cat "$K/norm.log" >&2
    if grep -F "'$L/" "$K/norm.log" >/dev/null; then
        red "cov_normalize refused kcov's report (above): kcov could not resolve these sources from its working directory $S, so they were not staged where the line tables name them ($SRC_REL/ and $TEST); their names fell through to $L/."
    fi
    red "cov_normalize refused kcov's report (above)."
}
printf 'PASS %s\n' "$LABEL" >"$MARKER"
rm -rf "$K"
