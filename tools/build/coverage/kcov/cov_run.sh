#!/bin/sh
# cov_run.sh -- runs one welded test's coverage binary under kcov in a build
# action (`mojo_cov_run`, tools/build/mojo/coverage.bzl), through the release
# gate's runner (its environment, with the differences below), and writes the
# test's report in repository paths (README.md, "cov_run").
#
# usage: busybox sh <run_dir>/cov_run.sh <busybox> <gate> <compiler_dir> <label>
#            <test_binary> <share> <src_dir> <xml_out> <marker_out>
#            <src_repo> <test> <test_repo> <import> [--solib <file> [--solib-src <path>]...]
#            [--gen <file>]... [--env NAME=VALUE]...
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
#   --solib        the test is a shared library's driver (a mojo_shared_lib's
#                  gate_srcs entry): <file> is the library's coverage build in
#                  <share>, which the driver loads; kcov measures the
#                  libraries the driver loads
#   --solib-src    a source of that library, by its path in the package, which
#                  is how the library's line tables name it (as a test's name
#                  it), at that path in <share>: measured, and mapped to the
#                  package's repository directory (<test_repo> without
#                  <test>); the report must hold the first. --solib with
#                  none (every source generated) is refused
#   --gen <file>   a generated source in <src_dir> (its path there): not measured
#   <gate>         the gate (tools/build/run), which runs kcov as `gate mojo`
#   --env          passed to the gate as given
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
#      there lands (below). The one exception to the copies: each generated
#      source (--gen) is moved to gen/, outside share/ and lost/, and linked
#      from both, so its name resolves to gen/ and is outside every
#      --include-path (not measured, with no argument naming it).
#   2. `gate mojo` (the release gate's runner) runs bin/kcov as
#      the program of the test root: share/ is the working directory, PATH,
#      LD_LIBRARY_PATH, TMPDIR, TEST_TMPDIR and HOME are the gate's, each
#      --env is exported to kcov and so reaches the test. kcov's arguments:
#      --cobertura-only --skip-solibs --configure=cobertura-full-paths=1
#      (no --skip-solibs with --solib: kcov then preloads its library,
#      which reports each library the driver loads, and sets breakpoints in
#      it as it is loaded);
#      --include-path of exactly <src_dir> and this test, under share/ and
#      under lost/ (no --exclude-path: kcov takes no argument of 2048
#      bytes or more, and the run refuses one before kcov does);
#      --replace-src-path='^(?!/):<lost>/'; the output directory and
#      bin/<test>. komira's kcov exits with the test's status (128+N when a
#      signal N killed it), not another traced process's (the toolchain's
#      README.md, "Patches"), so a test that fails under kcov (at -O0, or
#      traced) fails this action, with the test's output from the gate
#      but not its banner (which says the release gate's test failed: that
#      one passed; this action's own message says what failed). With
#      coverage on, the conda package (<name>_conda) waits for this action
#      too, the library does not (tools/build/mojo/coverage.bzl). kcov refused by the executor
#      (ptrace, personality) is reported as that.
#      The run is bounded: `gate mojo --limit-s <limit> --limit-report
#      coverage` runs kcov in a session of its own, and when it has not
#      exited after <limit> seconds, the gate kills every process of that
#      session (kcov, the test and any child it left), checks that none
#      survived the kill (a /proc that does not show the gate as its own is
#      refused, since that scan would see nothing), prints the run's output
#      and fails the action with `COVERAGE RUN FAILED` (docs/design/zig_gate_runner.md,
#      C1). kcov waits for every process
#      the test started, so without the bound a test leaving a child running
#      would hold the action open.
#   3. kcov writes exactly one report (<out>/cov.xml); anything else fails.
#   4. cov_normalize maps <share>/<src_dir>/ to <src_repo> and the test's
#      directory under share/ to the repository's (and with --solib, share/
#      itself to the package's), requires the test's own source in the report
#      (and the first --solib-src, so a library kcov did not measure is
#      refused, not reported as no line) and refuses the action's directories in the
#      output. Its output is <xml_out>; then `PASS <label>` goes to
#      <marker_out>.
#
# What differs from the release gate: the test is traced (TracerPid is
# kcov's), runs without address randomization (kcov sets ADDR_NO_RANDOMIZE),
# its working directory share/ also holds its own source at <test> and the
# library's at <src_dir>, kcov shares its TMPDIR, its environment also holds
# KCOV_SOLIB_PATH, which kcov always sets (with --skip-solibs, no
# LD_PRELOAD), but nothing of this script's own (its LC_ALL=C, below), and
# the run ends when every process the test started has exited (kcov follows
# each fork), where the gate waits for the test alone;
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
# Exit status: the test's under kcov when it fails (the gate's); 1 when the
# binary names the sources elsewhere, a kcov argument is too long, the run
# passed its limit, or the report is missing or refused; 2
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

SOLIB=""
SOLIB_SRCS=""
if [ "$#" -gt 0 ] && [ "$1" = --solib ]; then
    [ "$#" -ge 2 ] || { echo "cov_run: --solib needs a file" >&2; exit 2; }
    case "$2" in "" | /* | */) echo "cov_run: --solib $2 must be a relative file path" >&2; exit 2 ;; esac
    SOLIB=$2
    shift 2
    while [ "$#" -gt 0 ] && [ "$1" = --solib-src ]; do
        [ "$#" -ge 2 ] || { echo "cov_run: --solib-src needs a path" >&2; exit 2; }
        case "$2" in "" | /* | */ | buck-out/* | *[,:\ ]*) echo "cov_run: --solib-src $2 must be a relative file path outside buck-out/ without a space, , or :" >&2; exit 2 ;; esac
        SOLIB_SRCS="$SOLIB_SRCS $2"
        shift 2
    done
fi
# The package's repository directory ("" or ending in /), for --solib.
case "$TEST_REPO" in "$TEST") PKG_REPO="" ;; */"$TEST") PKG_REPO=${TEST_REPO%"$TEST"} ;; *) PKG_REPO=- ;; esac
if [ -n "$SOLIB" ] && [ "$PKG_REPO" = - ]; then
    echo "cov_run: with --solib, <test_repo> $TEST_REPO must be a directory then <test> $TEST" >&2
    exit 2
fi
GEN=""
while [ "$#" -gt 0 ] && [ "$1" = --gen ]; do
    [ "$#" -ge 2 ] || { echo "cov_run: --gen needs a file" >&2; exit 2; }
    case "$2" in "" | /* | *[,:\ ]*) echo "cov_run: --gen $2 must be a relative path without a space, , or :" >&2; exit 2 ;; esac
    GEN="$GEN $2"
    shift 2
done
# What is left is the gate's (--env NAME=VALUE...); it checks them.

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
# LC_ALL=C is given to this script's own tools: per command before the test
# runs, exported after it. The test gets the gate's environment, and the gate
# sets no LC_ALL (the gate passes on what it does not set).
export PATH

red() {
    echo "==================================================================" >&2
    echo "COVERAGE RUN FAILED: $LABEL" >&2
    echo "$*" >&2
    echo "==================================================================" >&2
    exit 1
}

# A shared library's driver with no source of the library to require in the
# report: every one generated (not measured), so a run in which kcov did not
# measure the library could not be told from one in which it did.
if [ -n "$SOLIB" ] && [ -z "$SOLIB_SRCS" ]; then
    red "cov_run: --solib with no --solib-src: every source of the shared library $SOLIB is generated, so none is measured and whether kcov measured the library cannot be checked; its drivers have no coverage run."
fi

# 0. Where the binary names the library's sources. Each string is on a line
# of its own (tr), so the expression sees one name at a time. Only a
# src/<import> component inside an artifact (after buck2's __<target>__/
# directory) counts, and a name is cut after the last one: a komira
# library's package path is itself src/<import>
# (buck-out/v2/art/komira/src/<import>/__<import>__/<hash>/src/<import>).
LC_ALL=C tr '\000' '\n' <"$BIN" | LC_ALL=C grep -a -o -E '[A-Za-z0-9_./+@=-]*buck-out/[A-Za-z0-9_./+@=-]*' >"$K/names" || true
LC_ALL=C grep -E "/__[^/]+__/.*/src/$IMPORT(/|\$)" "$K/names" | LC_ALL=C sed -E "s|^(.*/src/$IMPORT)(/.*)?\$|\1|" | LC_ALL=C sort -u >"$K/dirs" || true
LC_ALL=C grep -v -x -F -e "$SRC_REL" "$K/dirs" >"$K/elsewhere" || true
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
[ -z "$SOLIB" ] || [ -f "$R/share/$SOLIB" ] || red "the shared library $SOLIB (--solib) is not in the test's share directory"
for p in $SOLIB_SRCS; do
    [ -f "$R/share/$p" ] || red "the shared library's source $p (--solib-src) is not in the test's share directory"
done
[ ! -e "$R/share/$SRC_REL" ] || red "the share directory already holds $SRC_REL (a data file under it?)"
mkdir -p "$R/share/$SRC_REL"
cp -RL "$SRC/." "$R/share/$SRC_REL/"
mkdir -p "$L/$SRC_REL" "$L/$TEST_DIR"
cp -RL "$SRC/." "$L/$SRC_REL/"
cp -L "$SHARE/$TEST" "$L/$TEST"
for p in $SOLIB_SRCS; do
    case "$p" in */*) mkdir -p "$L/${p%/*}" ;; esac
    cp -L "$SHARE/$p" "$L/$p"
done
R=$(realpath "$R")
L=$(realpath "$L")
S="$R/share"
for p in "$S" "$L" "$SRC_REL" "$TEST"; do
    case "$p" in *[,:]*) echo "cov_run: $p holds a , or :, which kcov's options split on" >&2; exit 2 ;; esac
done
OUT="$K/kout"

# The generated sources: in share/ and lost/, each is a symbolic link to a
# copy under gen/, outside both. kcov resolves a name with realpath before
# it filters (filter.cc, mangleSourcePath and PathHandler), so a generated
# source resolves to gen/, outside every --include-path, and is not
# measured. No argument names them: kcov reads every argument before the
# program as a path when it looks for the program (configuration.cc, its
# argv scan) and fails "Too long string!" at one of 2048 bytes or more
# (utils.cc, peek_file), and it keeps only the last --exclude-path given,
# so a list of them cannot be split over several.
G="$K/gen"
for g in $GEN; do
    [ -f "$S/$SRC_REL/$g" ] && [ ! -L "$S/$SRC_REL/$g" ] || red "the generated source $g is not a file in $SRC_REL"
    case "$g" in */*) mkdir -p "$G/${g%/*}" ;; *) mkdir -p "$G" ;; esac
    mv "$S/$SRC_REL/$g" "$G/$g"
    ln -s "$G/$g" "$S/$SRC_REL/$g"
    rm "$L/$SRC_REL/$g"
    ln -s "$G/$g" "$L/$SRC_REL/$g"
done

# 2. kcov under the gate's runner. The --include-path list: <src_dir> and
# the test, and each --solib-src, under share/ and under lost/.
INC="$S/$SRC_REL,$S/$TEST,$L/$SRC_REL,$L/$TEST"
for p in $SOLIB_SRCS; do
    INC="$INC,$S/$p,$L/$p"
done
set -- "$@" --arg --cobertura-only
[ -n "$SOLIB" ] || set -- "$@" --arg --skip-solibs
set -- "$@" \
    --arg --configure=cobertura-full-paths=1 \
    --arg "--include-path=$INC" \
    --arg "--replace-src-path=^(?!/):$L/" \
    --arg "$OUT" \
    --arg "$R/bin/$NAME"
# Each of kcov's arguments is shorter than its 2048 bytes (above): each
# holds this action's directory, and --include-path also grows with the
# --solib-src paths of a shared library's driver (two per source). Bytes,
# counted under LC_ALL=C (the shell's ${#a} counts characters in the gate's
# locale, which this script does not set).
KCOV_ARG_MAX=2047
prev=""
for a in "$@"; do
    if [ "$prev" = --arg ]; then
        n=$(( $(printf '%s' "$a" | LC_ALL=C wc -c) ))
        if [ "$n" -gt "$KCOV_ARG_MAX" ]; then
            red "cov_run: a kcov argument of $n bytes ($(printf '%s' "$a" | LC_ALL=C cut -c 1-80)...) is longer than kcov takes ($KCOV_ARG_MAX): kcov reads each argument before the program as a path and fails \"Too long string!\" (README.md, \"cov_run\")."
        fi
    fi
    prev=$a
done
# The gate runs kcov in a session of its own and bounds it (step 2); past
# the limit it kills the session, prints the run's output and its own
# COVERAGE RUN FAILED message, and exits 1.
rc=0
"$GATE" mojo --busybox "$BB" --runtime-lib "$TC/lib" --label "$LABEL" --test "$R/bin/kcov" \
    --marker "$K/gate.passed" --limit-s "$LIMIT" --limit-report coverage "$@" 2>"$K/gate.err" || rc=$?
export LC_ALL=C
if [ "$rc" = 1 ] && grep -qxF "COVERAGE RUN FAILED: $LABEL" "$K/gate.err"; then
    cat "$K/gate.err" >&2
    exit 1
fi
if [ "$rc" != 0 ]; then
    # The gate's banner says the release gate's test failed, which it did
    # not (this is the coverage run). Its other lines, the test's output
    # among them, are kept.
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
if [ -n "$SOLIB" ]; then
    # A driver at the package's top has that map already (its directory's).
    [ -z "$TEST_DIR" ] || set -- "$@" --map "$S/=$PKG_REPO"
    for p in $SOLIB_SRCS; do
        set -- "$@" --must-contain "$PKG_REPO$p"
        break
    done
fi
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
