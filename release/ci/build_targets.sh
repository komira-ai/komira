#!/bin/sh
# The per-change check's build of one unit, or of a batch of units (the
# union of their targets): the `build_targets` command of each build system
# in release/artifacts.textproto. kci appends the targets and runs this from
# the repository's root. Everything below is correct on a union: it gives
# the union of each unit's builds, lints and tests.
#
# Every target is built (a library's welded tests run inside its build),
# with --keep-going: a failed batch still builds every other target, so the
# unit-by-unit retries kci runs to name the failing units start warm.
# Then each test_weld lint among the targets is checked: building one checks
# nothing, because what it reads (which test files the graph's targets weld)
# only a BXL script can query (tools/build/lint/test_weld.bzl). Then
# `buck2 test` runs over the targets of this cell, so a standalone test
# target runs as `./buck2 test //...` runs it, and each target's `tests` are
# followed. The tests cell's targets (`tests//...`) are built only, as
# `./buck2 build tests//functional/...` builds them.
set -eu
if [ "$#" -eq 0 ]; then
  echo "build_targets.sh: no target given" >&2
  exit 2
fi
buck2 build --keep-going "$@"
universe=
for t in "$@"; do
  universe="${universe:+$universe + }$t"
done
# An assignment, so a failed query fails this script (`set -e`).
lints=$(buck2 cquery "kind('^test_weld_rule\$', $universe)")
for lint in $(printf '%s\n' "$lints" | sed 's/ .*//'); do
  buck2 bxl //tools/build/lint/test_weld.bxl:check -- --lint "$lint"
done
count=$#
i=0
while [ "$i" -lt "$count" ]; do
  t=$1
  shift
  case "$t" in
    tests//*) ;;
    *) set -- "$@" "$t" ;;
  esac
  i=$((i + 1))
done
if [ "$#" -gt 0 ]; then
  buck2 test "$@"
fi
