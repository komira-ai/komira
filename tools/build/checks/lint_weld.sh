#!/usr/bin/env bash
# lint_weld.sh -- a lint finding in any script the rules run fails the build
# of a target that uses those rules, not only the build of the lint target.
#
# usage: tools/build/checks/lint_weld.sh        (from the repo root; BUCK2 overrides the binary)
#
# The lint of the rules' scripts is a validation reached through the Mojo and
# Rust toolchains: the `_script_lint` lists in tools/build/mojo/toolchain.bzl
# and tools/build/rust/defs.bzl. Those lists must equal MOJO_LINTS and
# RUST_LINTS below (a new entry is added to both places). Then, for every lint
# target in MOJO_LINTS or RUST_LINTS, in a snapshot of the working tree with a shellcheck warning
# (an unused variable, SC2034) planted in one of its scripts, and only there:
#   the Mojo example //tools/build/examples:hello (if the Mojo list names the
#   target) and the Rust example //tools/build/examples/rust:prost_roundtrip
#   (if the Rust list does) must fail, naming the validation of that lint
#   target and SC2034.
# So a target dropped from a .bzl list fails this check twice: the lists
# differ, and its planted warning no longer fails the example build. The unplanted tree builds both examples: that
# is part of `buck2 build //...`.
#
# The remote-execution settings come from `.buckconfig.local` in the repo
# root, copied into the snapshot when present, or from the machine-wide
# buckconfig. Scratch goes under $TMPDIR; the snapshot is deleted on exit
# unless KEEP_SCRATCH=1, and its buck2 daemon is stopped. Logs are kept.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_lint_weld.XXXXXX")
die() { echo "FAIL  lint weld: $1"; echo "logs: $W"; exit 1; }
cleanup() {
    [ -d "$W/src" ] && (cd "$W/src" && "$BUCK2" kill > /dev/null 2>&1)
    [ "${KEEP_SCRATCH:-0}" = 1 ] || rm -rf "${W:?}/src"
}
trap cleanup EXIT

MOJO_EXAMPLE=//tools/build/examples:hello
RUST_EXAMPLE=//tools/build/examples/rust:prost_roundtrip
script_lints() { # the `_script_lint` default list of a .bzl file, one label per line
    sed -n '/"_script_lint"/,/\]/p' "$ROOT/$1" | grep -oE '"komira//[^"]+"' | tr -d '"'
}
# What the rules run, and so what each toolchain must lint.
MOJO_LINTS=(komira//tools/build/lint:shell_lint komira//tools/build/mojo:shell_lint komira//tools/build/mojo/darwin:shell_lint)
RUST_LINTS=(komira//tools/build/lint:shell_lint komira//tools/build/mojo:shell_lint komira//tools/build/rust:shell_lint)
printf '%s\n' "${MOJO_LINTS[@]}" > "$W/mojo_lints.txt"
printf '%s\n' "${RUST_LINTS[@]}" > "$W/rust_lints.txt"
for tc in mojo:tools/build/mojo/toolchain.bzl rust:tools/build/rust/defs.bzl; do
    script_lints "${tc#*:}" > "$W/${tc%%:*}_bzl.txt"
    if ! diff <(LC_ALL=C sort "$W/${tc%%:*}_lints.txt") <(LC_ALL=C sort "$W/${tc%%:*}_bzl.txt") > "$W/${tc%%:*}_diff.txt"; then
        die "the _script_lint list of ${tc#*:} differs from lint_weld.sh's (< here, > there): $(grep '^[<>]' "$W/${tc%%:*}_diff.txt" | tr '\n' ' ')"
    fi
done

mkdir "$W/src"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) |
    while IFS= read -r -d '' f; do [ -e "$ROOT/$f" ] && printf '%s\0' "$f"; done |
    (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$W/src" || die "cannot snapshot the working tree"
[ ! -f "$ROOT/.buckconfig.local" ] || cp "$ROOT/.buckconfig.local" "$W/src/"

missed="" planted=0 builds=0
for lint in $(LC_ALL=C sort -u "$W/mojo_lints.txt" "$W/rust_lints.txt"); do
    # The first shell script the lint target checks.
    script=$(cd "$W/src" && "$BUCK2" uquery "inputs($lint)" 2> "$W/uquery.err" | grep -m1 '\.sh$')
    [ -n "$script" ] || { missed="$missed [$lint lists no .sh file; see $W/uquery.err]"; continue; }
    cp "$ROOT/$script" "$W/src/$script.orig"
    printf '\nkomira_planted_unused=1\n' >> "$W/src/$script"
    planted=$((planted + 1))
    targets=()
    grep -qxF "$lint" "$W/mojo_lints.txt" && targets+=("$MOJO_EXAMPLE")
    grep -qxF "$lint" "$W/rust_lints.txt" && targets+=("$RUST_EXAMPLE")
    for target in "${targets[@]}"; do
        builds=$((builds + 1))
        log="$W/$(echo "$lint $target" | tr -c 'a-zA-Z0-9_\n' _).log"
        if (cd "$W/src" && timeout 900 "$BUCK2" build "$target") > "$log" 2>&1; then
            missed="$missed [$target built with $script planted]"
        elif ! grep -qF "Validation for \`$lint" "$log" || ! grep -qF SC2034 "$log"; then
            missed="$missed [$target failed without naming the validation of $lint and SC2034; see $log]"
        fi
    done
    mv "$W/src/$script.orig" "$W/src/$script"
done
[ -z "$missed" ] || die "with a planted shellcheck warning:$missed"
echo "PASS  lint weld: a shellcheck warning planted in each of the $planted script lints the Mojo and Rust toolchains name fails the example builds ($builds builds), naming the validation"
echo "logs: $W"
