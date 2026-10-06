#!/bin/sh
# kcov is GPL-2.0 and a build-only tool (tools/build/toolchains/kcov/README.md,
# "Licences"): no published artifact may hold it. This script is the check
# each package format runs over what it packs (README.md, "kcov is never
# packed"; kcov_guard.bzl):
#   sh kcov_guard.sh guard <busybox> <kcov_dir> <out> <what> [<dest> <path>]...
#       Refuses, naming each, every file of the <path>s whose sha256 is that
#       of <kcov_dir>/bin/kcov or whose bytes contain kcov's usage line
#       (MARKER below). A <path> is a file, or a directory whose every
#       regular file is read (symlinks followed). <dest> is where the packer
#       puts <path> (`.` for the root of a directory), and the message names
#       a file by it; <what> names the target. Writes <out> when nothing is
#       refused.
#   sh kcov_guard.sh cases <busybox> <kcov_dir> <report_dir>
#       Runs the guard on inputs whose answer is known, wrong ones included,
#       and writes <report_dir>/validation.json.
# Both first require MARKER in <kcov_dir>/bin/kcov, so a kcov whose usage line
# changed fails here rather than passing every file.
set -eu

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
MODE=$1
BB=$(abs "$2")
KCOV=$(abs "$3")
OUT=$(abs "$4")
shift 4

case "${BUCK_SCRATCH_PATH:-}" in
    "") T="$PWD/.kcov_guard_$MODE" ;;
    /*) T="$BUCK_SCRATCH_PATH/kcov_guard_$MODE" ;;
    *) T="$PWD/$BUCK_SCRATCH_PATH/kcov_guard_$MODE" ;;
esac
"$BB" mkdir -p "$T/bin"
"$BB" --install -s "$T/bin"
PATH="$T/bin"
export PATH LC_ALL=C

die() {
    echo "kcov_guard $MODE: $*" >&2
    exit 1
}

# kcov's usage line, the start of one string literal of its
# src/configuration.cc (the C++ compiler joins the adjacent literals), so the
# bytes are contiguous in bin/kcov whatever the version. Not the version: kcov
# prints `kcov %s` with the string `v42` of version.c, and no `kcov v42` is in
# the binary. A file holds this line only if it is kcov, embeds it, or quotes
# its help text verbatim.
MARKER='Usage: kcov [OPTIONS] out-dir in-file [args...]'
K="$KCOV/bin/kcov"

# Whether file $1 holds MARKER. A binary's lines hold NUL bytes; busybox grep
# matches past them (the case `embedded` puts MARKER after one).
has_marker() {
    rc=0
    grep -F -q -e "$MARKER" "$1" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) die "grep failed (exit $rc) on $1" ;;
    esac
}

sha() {
    s=$(sha256sum <"$1") || die "cannot read $1"
    printf '%s' "${s%% *}"
}

[ -f "$K" ] || die "$K is not a file: the guard is given kcov's distribution directory"
KSUM=$(sha "$K")
has_marker "$K" || die "$K does not hold kcov's usage line '$MARKER': its usage text changed, so the guard would find no kcov by it; update MARKER"

REFUSED=""
# The guard runs as the left side of `||`, where `set -e` does not apply:
# every step that can fail says so itself.
scan_file() {
    # $1: the file's name in the package; $2: the file.
    s=$(sha "$2") || exit 1
    if [ "$s" = "$KSUM" ]; then
        REFUSED="$REFUSED  $1 is kcov's bin/kcov (sha256 $s)
"
    elif has_marker "$2"; then
        REFUSED="$REFUSED  $1 holds kcov's usage line '$MARKER': it is kcov, embeds kcov, or copies its help text
"
    fi
}

# guard <what> [<dest> <path>]...: prints the refusal and returns 1, or returns 0.
guard() {
    what=$1
    shift
    REFUSED=""
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || die "$what: <dest> $1 has no <path>"
        dest=$1
        src=$2
        shift 2
        if [ -d "$src" ]; then
            find -L "$src" -type f >"$T/found" || die "$what: cannot list $src"
            sort "$T/found" >"$T/list" || die "$what: cannot sort the list of $src"
            while IFS= read -r f; do
                rel=${f#"$src"/}
                case "$dest" in
                    .) scan_file "$rel" "$f" ;;
                    *) scan_file "$dest/$rel" "$f" ;;
                esac
            done <"$T/list"
            rm -f "$T/found" "$T/list"
        elif [ -f "$src" ]; then
            scan_file "$dest" "$src"
        else
            die "$what: $src ($dest) is neither a file nor a directory"
        fi
    done
    [ -n "$REFUSED" ] || return 0
    printf '%s packs kcov, a build-only tool: kcov is GPL-2.0, and no published artifact may contain it (tools/build/toolchains/kcov/README.md, "Licences"). Refused:\n%s' "$what" "$REFUSED" >&2
    return 1
}

case "$MODE" in
guard)
    [ "$#" -ge 1 ] || die "no <what>"
    guard "$@" || exit 1
    rm -rf "$T"
    echo ok >"$OUT"
    ;;
cases)
    REPORT=$OUT
    C="$T/cases"
    mkdir -p "$REPORT" "$C"
    N=0
    red() { die "RED: $*"; }
    # expect <case> <rc> <name>... -- <guard args>: the guard's exit status is
    # <rc>, and a refusal names each <name> (and only on rc 1).
    expect() {
        case_name=$1
        want=$2
        shift 2
        names=""
        while [ "$1" != "--" ]; do
            names="$names $1"
            shift
        done
        shift
        rc=0
        (guard "$case_name" "$@") 2>"$T/err" || rc=$?
        [ "$rc" = "$want" ] || red "$case_name: guard exited $rc, want $want: $(cat "$T/err")"
        for n in $names; do
            grep -F -q -e "  $n " "$T/err" || red "$case_name: the refusal does not name $n: $(cat "$T/err")"
        done
        N=$((N + 1))
    }

    # Refused by sha256: kcov renamed, as a directory's file and as a file.
    mkdir -p "$C/copy/lib"
    cp "$K" "$C/copy/lib/libcopy.so"
    expect copy_in_dir 1 lib/libcopy.so -- . "$C/copy"
    grep -F -q "lib/libcopy.so is kcov's bin/kcov (sha256 $KSUM)" "$T/err" || red "copy_in_dir: not refused by sha256: $(cat "$T/err")"
    expect copy_as_file 1 lib/mojo/x.mojoc -- lib/mojo/x.mojoc "$C/copy/lib/libcopy.so"
    expect copy_under_dest 1 opt/x/lib/libcopy.so -- opt/x "$C/copy"

    # Refused by the usage line: kcov with one byte more (another sha256),
    # and the line alone between NUL bytes, as in a binary's string table.
    mkdir -p "$C/changed/bin" "$C/embed/share"
    { cat "$K"; printf 'x'; } >"$C/changed/bin/tool"
    expect changed 1 bin/tool -- . "$C/changed"
    grep -F -q "bin/tool holds kcov's usage line" "$T/err" || red "changed: not refused by the usage line: $(cat "$T/err")"
    { printf 'ELF\000\001\002 text\000'; printf '%s' "$MARKER"; printf '\000tail'; } >"$C/embed/share/blob.bin"
    expect embedded 1 share/blob.bin -- . "$C/embed"

    # Every offending file is named, across arguments.
    expect two 1 lib/libcopy.so share/blob.bin -- . "$C/copy" . "$C/embed"

    # Symlinks are followed: one to kcov's copy, and one to a directory
    # holding it, are each refused under the link's name.
    mkdir -p "$C/link/share"
    ln -s "$C/copy/lib/libcopy.so" "$C/link/share/k"
    ln -s "$C/copy" "$C/link/dir"
    expect symlinked 1 share/k dir/lib/libcopy.so -- . "$C/link"

    # Accepted: near misses of the line, the line broken by a NUL or a
    # newline, and kcov's other file (libgcc_s.so.1, which bundles ship as
    # the Mojo runtime's).
    mkdir -p "$C/near/share" "$C/near/lib"
    printf 'Usage: kcov [OPTIONS] out-dir in-file [args..]\n' >"$C/near/share/dots.txt"
    printf 'usage: kcov [OPTIONS] out-dir in-file [args...]\n' >"$C/near/share/case.txt"
    printf 'Usage: kcov [OPTIONS] out-dir\000in-file [args...]\n' >"$C/near/share/nul.bin"
    printf 'Usage: kcov [OPTIONS] out-dir\nin-file [args...]\n' >"$C/near/share/newline.txt"
    printf 'kcov v42\nv42\000Usage: kcov [OPTIONS]\n' >"$C/near/share/version.txt"
    cp "$KCOV/lib/libgcc_s.so.1" "$C/near/lib/libgcc_s.so.1"
    expect near_misses 0 -- . "$C/near"
    [ ! -s "$T/err" ] || red "near_misses: the guard printed $(cat "$T/err")"
    expect nothing 0 --

    rm -rf "$T"
    printf '{"version": 1, "data": {"status": "success", "message": "kcov_guard cases: %s cases passed"}}\n' "$N" >"$REPORT/validation.json"
    ;;
*)
    die "unknown mode"
    ;;
esac
