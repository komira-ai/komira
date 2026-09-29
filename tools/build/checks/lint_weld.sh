#!/usr/bin/env bash
# lint_weld.sh -- a lint finding in a script the rules run fails the build of
# a target that uses those rules, not only the build of the lint target.
#
# usage: tools/build/checks/lint_weld.sh        (from the repo root; BUCK2 overrides the binary)
#
# The lint of the rules' scripts is a validation reached through the Mojo and
# Rust toolchains (`_script_lint` in tools/build/mojo/toolchain.bzl and
# tools/build/rust/defs.bzl). In a snapshot of the working tree with a
# planted shellcheck warning in tools/build/mojo/run_check.sh (an unused
# variable, SC2034; the file is not an input of the targets built here, so
# nothing recompiles):
#   1. `buck2 build //tools/build/examples:hello` must fail, naming the
#      validation of komira//tools/build/mojo:shell_lint and SC2034.
#   2. The same for the Rust example //tools/build/examples/rust:prost_roundtrip.
# The unplanted tree builds both: that is part of `buck2 build //...`.
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

mkdir "$W/src"
(cd "$ROOT" && git ls-files -co --exclude-standard -z) |
    while IFS= read -r -d '' f; do [ -e "$ROOT/$f" ] && printf '%s\0' "$f"; done |
    (cd "$ROOT" && tar --null -T - -cf -) | tar -xf - -C "$W/src" || die "cannot snapshot the working tree"
[ ! -f "$ROOT/.buckconfig.local" ] || cp "$ROOT/.buckconfig.local" "$W/src/"
printf '\nkomira_planted_unused=1\n' >> "$W/src/tools/build/mojo/run_check.sh"

missed=""
for target in //tools/build/examples:hello //tools/build/examples/rust:prost_roundtrip; do
    log="$W/$(echo "$target" | tr -c 'a-zA-Z0-9_\n' _).log"
    if (cd "$W/src" && timeout 900 "$BUCK2" build "$target") > "$log" 2>&1; then
        missed="$missed [$target built]"
    elif ! grep -qF 'Validation for `komira//tools/build/mojo:shell_lint' "$log" || ! grep -qF SC2034 "$log"; then
        missed="$missed [$target failed without naming the shell_lint validation and SC2034; see $log]"
    fi
done
[ -z "$missed" ] || die "with a planted shellcheck warning:$missed"
echo "PASS  lint weld: a planted shellcheck warning in a rules script fails the Mojo and Rust example builds, naming the validation"
echo "logs: $W"
