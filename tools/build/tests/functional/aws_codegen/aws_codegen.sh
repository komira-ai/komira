# aws_codegen.sh -- runs aws-client-gen for the checks of aws_codegen.bzl.
#
# usage:
#   busybox sh aws_codegen.sh <busybox> gen <generator> <out dir> <module> <probe 0|1> -- <generator args>...
#   busybox sh aws_codegen.sh <busybox> refuse <generator> <stamp> <message> <probe 0|1> -- <generator args>...
#   busybox sh aws_codegen.sh <busybox> cmp <stamp> <gen dir> <module> <golden> <golden probe|-> [<must contain>...]
#
# gen writes <out dir>/<module>.mojo, and <out dir>/_layout_probe.mojo when
# <probe> is 1. refuse requires the generator to exit non-zero, print
# <message> on stderr and write no file; it is given --probe-out when <probe>
# is 1. cmp requires the generated files to equal their goldens byte for
# byte, and prints the first differing lines when they do not. Each
# <must contain> is then looked for in the GENERATED module, independently of
# the golden, so a golden re-copied over a regression still goes red. Lines
# match with their leading spaces removed, so a needle may span lines.
set -eu
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
BB=$(abspath "$1"); MODE=$2; shift 2
T="$PWD/.komira_aws_codegen"
"$BB" mkdir -p "$T/tools"
"$BB" --install -s "$T/tools"
# shellcheck disable=SC2123 # the busybox applets are the whole search path, on purpose
PATH="$T/tools"; export PATH

case "$MODE" in
gen)
    GEN=$1; OUT=$2; MODULE=$3; PROBE=$4; shift 4
    [ "$1" = "--" ] && shift
    mkdir -p "$OUT"
    if [ "$PROBE" = 1 ]; then
        "$GEN" --module "$MODULE" --out "$OUT/$MODULE.mojo" --probe-out "$OUT/_layout_probe.mojo" "$@"
    else
        "$GEN" --module "$MODULE" --out "$OUT/$MODULE.mojo" "$@"
    fi
    ;;
refuse)
    GEN=$1; STAMP=$2; WANT=$3; PROBE=$4; shift 4
    [ "$1" = "--" ] && shift
    mkdir -p "$T/out"
    if [ "$PROBE" = 1 ]; then
        set -- --probe-out "$T/out/_layout_probe.mojo" "$@"
    fi
    rc=0
    "$GEN" --module refused --out "$T/out/refused.mojo" "$@" 2> "$T/stderr" || rc=$?
    if [ "$rc" = 0 ]; then
        echo "aws_codegen: expected a refusal, and the generator exited 0" >&2
        exit 1
    fi
    if ! grep -qF -- "$WANT" "$T/stderr"; then
        echo "aws_codegen: the refusal does not say: $WANT" >&2
        echo "it said:" >&2
        head -c 2000 "$T/stderr" >&2
        exit 1
    fi
    if [ -n "$(ls -A "$T/out")" ]; then
        echo "aws_codegen: the generator refused but wrote: $(ls -A "$T/out")" >&2
        exit 1
    fi
    printf 'refused (exit %s): %s\n' "$rc" "$WANT" > "$STAMP"
    ;;
cmp)
    STAMP=$1; GEN_DIR=$2; MODULE=$3; GOLDEN=$4; GOLDEN_PROBE=$5; shift 5
    bad=0
    check() { # generated, golden
        if ! cmp -s "$1" "$2"; then
            echo "aws_codegen: $1 differs from the golden $2:" >&2
            diff -u "$2" "$1" | head -60 >&2 || true
            bad=1
        fi
    }
    check "$GEN_DIR/$MODULE.mojo" "$GOLDEN"
    if [ "$GOLDEN_PROBE" != - ]; then
        check "$GEN_DIR/_layout_probe.mojo" "$GOLDEN_PROBE"
    elif [ -e "$GEN_DIR/_layout_probe.mojo" ]; then
        echo "aws_codegen: a probe was generated and no golden names it" >&2
        bad=1
    fi
    # One line per file, leading spaces dropped; \036 stands for a newline.
    flat() { sed 's/^ *//' | tr '\n' '\036'; }
    flat < "$GEN_DIR/$MODULE.mojo" > "$T/flat"
    for want in "$@"; do
        if ! grep -qF -- "$(printf '%s\n' "$want" | flat)" "$T/flat"; then
            echo "aws_codegen: $MODULE.mojo does not contain:" >&2
            printf '%s\n' "$want" >&2
            bad=1
        fi
    done
    [ "$bad" = 0 ] || exit 1
    printf 'equal to the golden: %s\n' "$MODULE.mojo" > "$STAMP"
    ;;
*)
    echo "aws_codegen: unknown mode $MODE" >&2
    exit 2
    ;;
esac
