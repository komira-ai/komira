# parity.sh -- runs one program built two ways and compares them.
#
# usage: busybox sh parity.sh <busybox> <runnable dir> <binary> <bundle> <out>
#
# E/ is the executable: E/bin/<binary> with E/bin/lib/ (its run path), and
# the bundle's share/ copied next to it. B/ is a copy of the bundle. Each case
# runs `bin/<binary> ...` (or $PROG, a symlink to it) from the tree's root, with only the environment the
# case sets, stdin from /dev/null, stdout and stderr to files. Exit 1 when any
# case differs in stdout, stderr or exit status.
set -eu
abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac; }
BB=$(abspath "$1"); RUN=$(abspath "$2"); BIN=$3; BUNDLE=$(abspath "$4"); OUT=$(abspath "$5")
T="$PWD/.komira_parity"
"$BB" mkdir -p "$T/tools"
"$BB" --install -s "$T/tools"
# shellcheck disable=SC2123 # the busybox applets are the whole search path, on purpose
PATH="$T/tools"; export PATH
mkdir -p "$T/E"
cp -r "$RUN" "$T/E/bin"
cp -r "$BUNDLE/share" "$T/E/share"
cp -r "$BUNDLE" "$T/B"
chmod -R u+w "$T/E" "$T/B"

n=0
bad=0
: > "$OUT"
case_() { # name, env assignments..., --, args...
    name=$1; shift
    envs=""
    while [ "$1" != "--" ]; do envs="$envs $1"; shift; done
    shift
    n=$((n + 1))
    for tree in E B; do
        rc=0
        (cd "$T/$tree" && env -i $envs "${PROG:-bin/$BIN}" "$@" > "$T/$tree.$n.out" 2> "$T/$tree.$n.err" < /dev/null) || rc=$?
        echo "$rc" > "$T/$tree.$n.rc"
    done
    what=""
    cmp -s "$T/E.$n.out" "$T/B.$n.out" || what="$what stdout"
    if [ "${CMP:-}" = signal ]; then
        # A fatal signal prints the runtime's stack dump: raw addresses (ASLR,
        # different on every run) and module names (probe vs libprobe.so), so
        # only its first line is compared. Status and stdout stay exact.
        [ "$(head -n 1 "$T/E.$n.err")" = "$(head -n 1 "$T/B.$n.err")" ] && [ -s "$T/E.$n.err" ] || what="$what stderr-first-line"
    else
        cmp -s "$T/E.$n.err" "$T/B.$n.err" || what="$what stderr"
    fi
    cmp -s "$T/E.$n.rc" "$T/B.$n.rc" || what="$what exit($(cat "$T/E.$n.rc") vs $(cat "$T/B.$n.rc"))"
    if [ -n "$what" ]; then
        bad=$((bad + 1))
        echo "DIFF $name:$what" >> "$OUT"
        for tree in E B; do
            echo "  $tree rc=$(cat "$T/$tree.$n.rc") out=$(head -c 300 "$T/$tree.$n.out" | tr '\n' '|') err=$(head -c 300 "$T/$tree.$n.err" | tr '\n' '|')" >> "$OUT"
        done
    else
        echo "SAME $name: rc=$(cat "$T/E.$n.rc") stdout $(wc -c < "$T/E.$n.out")B stderr $(wc -c < "$T/E.$n.err")B $(head -c 120 "$T/E.$n.err" | tr '\n' '|')" >> "$OUT"
    fi
}

case_ no-args -- 
case_ args -- args "two words" "" "ünï✓" "--flag=x"
case_ env KOMIRA_PROBE_ENV=hello-env -- env
case_ env-unset -- env
case_ exit3 -- exit3
case_ raise -- raise
case_ buffered -- buffered
case_ data -- data
case_ unknown -- nosuchmode
CMP=signal case_ abort -- abort
CMP=signal case_ segv -- segv
CMP=
# argv[0] other than bin/<name>: a symlink with another name in another directory.
for tree in E B; do mkdir -p "$T/$tree/links" && ln -s "../bin/$BIN" "$T/$tree/links/other-name"; done
PROG=links/other-name case_ argv0-symlink -- args one
PROG=links/other-name case_ data-through-symlink -- data
PROG=

echo "$n cases, $bad differ" >> "$OUT"
cat "$OUT" >&2
rm -rf "$T"
[ "$bad" = 0 ]
