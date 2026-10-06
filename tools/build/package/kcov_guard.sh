#!/bin/sh
# kcov is GPL-2.0 and a build-only tool (tools/build/toolchains/kcov/README.md,
# "Licences"): no published artifact may hold it. This script is the check
# each package format runs over what it packs (README.md, "kcov is never
# packed"; kcov_guard.bzl):
#   sh kcov_guard.sh guard <busybox> <kcov_sha256> <usage_line> <out> <what> [<dest> <path>]...
#       Refuses, naming each, every file of the <path>s whose sha256 is
#       <kcov_sha256> or whose bytes contain <usage_line>: KCOV_BIN_SHA256
#       and KCOV_USAGE_LINE of tools/build/toolchains/kcov/identity.bzl,
#       which `:kcov_identity` there holds to the built bin/kcov. A <path> is
#       a file, or a directory whose every regular file is read (symlinks
#       followed). <dest> is where the packer puts <path> (`.` for the root
#       of a directory), and the message names a file by it; <what> names the
#       target. Writes <out> when nothing is refused. Reads no kcov.
#   sh kcov_guard.sh cases <busybox> <usage_line> <report_dir>
#       Runs the guard on inputs whose answer is known, wrong ones included,
#       with a fixture file standing for bin/kcov (its sha256 is FIXTURE_SHA256
#       below), and writes <report_dir>/validation.json.
set -eu
# shellcheck disable=SC3040 # busybox sh (ash) has pipefail
set -o pipefail

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
MODE=$1
BB=$(abs "$2")
case "$MODE" in
    guard)
        KSUM=$3
        MARKER=$4
        OUT=$(abs "$5")
        shift 5
        ;;
    cases)
        # The pinned sha256 and line the package rules pass (one helper in
        # kcov_guard.bzl builds both calls); the cases check their form and
        # use the line, and use a fixture's sha256 for the refusals.
        PINNED=$3
        MARKER=$4
        OUT=$(abs "$5")
        shift 5
        ;;
    *)
        echo "kcov_guard: unknown mode '$MODE'" >&2
        exit 1
        ;;
esac

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

# Fails unless <sha256> is 64 lowercase hex digits and <line> is not empty:
# a malformed sha256 would refuse nothing by it, and an empty line every file.
args_ok() {
    case "$1" in
        *[!0-9a-f]* | "") die "the kcov sha256 '$1' is not 64 lowercase hex digits (KCOV_BIN_SHA256, tools/build/toolchains/kcov/identity.bzl)" ;;
    esac
    [ "${#1}" = 64 ] || die "the kcov sha256 '$1' is not 64 lowercase hex digits (KCOV_BIN_SHA256, tools/build/toolchains/kcov/identity.bzl)"
    [ -n "$2" ] || die "the kcov usage line is empty (KCOV_USAGE_LINE, tools/build/toolchains/kcov/identity.bzl)"
}

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
    args_ok "$KSUM" "$MARKER"
    [ "$#" -ge 1 ] || die "no <what>"
    guard "$@" || exit 1
    rm -rf "$T"
    echo ok >"$OUT"
    ;;
cases)
    args_ok "$PINNED" "$MARKER"
    REPORT=$OUT
    SELF=$(abs "$0")
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

    # The fixture stands for bin/kcov: the cases need no kcov. Its sha256 is
    # written here, not computed, so a wrong sha() is red as well.
    FIXTURE_SHA256=177f9e3e45d0314ec5a7001df49c20a2f2ca26c5ac681aa5a89e387c4b64854b
    F="$C/fixture"
    printf 'kcov_guard cases: this file stands for bin/kcov; the guard is given its sha256\n' >"$F"
    [ "$(sha "$F")" = "$FIXTURE_SHA256" ] || red "sha: the fixture's sha256 is $(sha "$F"), want $FIXTURE_SHA256"
    if has_marker "$F"; then red "the fixture holds the usage line, so the sha256 cases show nothing"; fi
    args_ok "$FIXTURE_SHA256" "$MARKER"
    KSUM=$FIXTURE_SHA256

    # The arguments: a sha256 one digit short, one in upper case, and an
    # empty usage line are refused before any file is read.
    for bad in "${FIXTURE_SHA256%?}|$MARKER" "$(echo "$FIXTURE_SHA256" | tr a-f A-F)|$MARKER" "$FIXTURE_SHA256|"; do
        if (args_ok "${bad%%|*}" "${bad#*|}") 2>"$T/err"; then red "args_ok accepted the sha256 '${bad%%|*}' and the line '${bad#*|}'"; fi
        N=$((N + 1))
    done

    # Refused by sha256 (the fixture holds no usage line): renamed, as a
    # directory's file, as a file, and under a destination path.
    mkdir -p "$C/copy/lib"
    cp "$F" "$C/copy/lib/libcopy.so"
    expect copy_in_dir 1 lib/libcopy.so -- . "$C/copy"
    grep -F -q "lib/libcopy.so is kcov's bin/kcov (sha256 $KSUM)" "$T/err" || red "copy_in_dir: not refused by sha256: $(cat "$T/err")"
    expect copy_as_file 1 lib/mojo/x.mojoc -- lib/mojo/x.mojoc "$C/copy/lib/libcopy.so"
    expect copy_under_dest 1 opt/x/lib/libcopy.so -- opt/x "$C/copy"

    # Refused by the usage line: a kcov built otherwise (another sha256)
    # holding the line, and the line alone between NUL bytes, as in a
    # binary's string table.
    mkdir -p "$C/changed/bin" "$C/embed/share"
    { cat "$F"; printf '\000%s\000' "$MARKER"; } >"$C/changed/bin/tool"
    expect changed 1 bin/tool -- . "$C/changed"
    grep -F -q "bin/tool holds kcov's usage line" "$T/err" || red "changed: not refused by the usage line: $(cat "$T/err")"
    { printf 'ELF\000\001\002 text\000'; printf '%s' "$MARKER"; printf '\000tail'; } >"$C/embed/share/blob.bin"
    expect embedded 1 share/blob.bin -- . "$C/embed"

    # Every offending file is named, across arguments.
    expect two 1 lib/libcopy.so share/blob.bin -- . "$C/copy" . "$C/embed"

    # Symlinks are followed: one to the fixture's copy, and one to a
    # directory holding it, are each refused under the link's name.
    mkdir -p "$C/link/share"
    ln -s "$C/copy/lib/libcopy.so" "$C/link/share/k"
    ln -s "$C/copy" "$C/link/dir"
    expect symlinked 1 share/k dir/lib/libcopy.so -- . "$C/link"

    # Accepted: near misses of kcov's line (written out, so a usage line
    # shortened in identity.bzl refuses one and is red here), the line
    # broken by a NUL or a newline, and the fixture with one byte more (the
    # sha256 is of the whole file).
    mkdir -p "$C/near/share" "$C/near/lib"
    printf 'Usage: kcov [OPTIONS] out-dir in-file [args..]\n' >"$C/near/share/dots.txt"
    printf 'usage: kcov [OPTIONS] out-dir in-file [args...]\n' >"$C/near/share/case.txt"
    printf 'Usage: kcov [OPTIONS] out-dir\000in-file [args...]\n' >"$C/near/share/nul.bin"
    printf 'Usage: kcov [OPTIONS] out-dir\nin-file [args...]\n' >"$C/near/share/newline.txt"
    printf 'kcov v42\nv42\000Usage: kcov [OPTIONS]\n' >"$C/near/share/version.txt"
    { cat "$F"; printf 'x'; } >"$C/near/lib/longer.so"
    expect near_misses 0 -- . "$C/near"
    [ ! -s "$T/err" ] || red "near_misses: the guard printed $(cat "$T/err")"
    expect nothing 0 --

    # The guard through its command line, as the package rules run it, in
    # its own process: the sha256 and the line reach the checks from their
    # positions (one read from the wrong position or altered on the way is
    # red here), and <out> is written only when nothing is refused.
    cli() {
        # cli <case> <rc> <message> <dir>: the guard over <dir> as `.`.
        rm -f "$C/cli.out"
        rc=0
        BUCK_SCRATCH_PATH="$C/cli_scratch" "$BB" sh "$SELF" guard "$BB" "$KSUM" "$MARKER" "$C/cli.out" "cli_$1" . "$4" 2>"$T/err" || rc=$?
        [ "$rc" = "$2" ] || red "cli_$1: guard exited $rc, want $2: $(cat "$T/err")"
        if [ "$2" = 0 ]; then
            [ "$(cat "$C/cli.out")" = ok ] || red "cli_$1: accepted, but <out> is not 'ok'"
            [ ! -s "$T/err" ] || red "cli_$1: accepted, but the guard printed $(cat "$T/err")"
        else
            [ ! -e "$C/cli.out" ] || red "cli_$1: refused, but <out> was written"
            grep -F -q -e "$3" "$T/err" || red "cli_$1: the refusal does not say '$3': $(cat "$T/err")"
        fi
        N=$((N + 1))
    }
    cli sha 1 "lib/libcopy.so is kcov's bin/kcov (sha256 $KSUM)" "$C/copy"
    cli line 1 "share/blob.bin holds kcov's usage line '$MARKER'" "$C/embed"
    cli near 0 "" "$C/near"

    rm -rf "$T"
    printf '{"version": 1, "data": {"status": "success", "message": "kcov_guard cases: %s cases passed"}}\n' "$N" >"$REPORT/validation.json"
    ;;
esac
