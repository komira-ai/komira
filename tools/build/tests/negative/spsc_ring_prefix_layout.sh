#!/usr/bin/env bash
# spsc_ring_prefix_layout.sh -- falsifier for the slot store's place in the ring.
#
# usage: tools/build/tests/negative/spsc_ring_prefix_layout.sh   (from the repo root; BUCK2 overrides the binary)
#
# The ring keeps its lazily created slot store in the shared block, not in the
# ring struct (see the header of spsc_ring.mojo, point 7). The regression test
# `test_consumer_polling_before_the_slot_store_exists` guards that, and this
# script proves the test can fail. `spsc_ring_prefix_layout/prefix_ring.mojo` is
# the ring as it was BEFORE the slot store moved into the shared block (boxed
# counters, slot store lazily created in the struct, sequentially consistent
# cursors). The same consumer-polling program is built against
#   green  the ring as it is                  must succeed every run (the control)
#   red    that old layout                    must FAIL in at least one of N runs
# The failure is a race (a crash on a null slot store), so `red` is run up to
# RUNS times (default 30) and stops at the first failure.
#
# What this does NOT show: the CURRENT algorithm with its slot store moved into
# the struct. That variant passed 30 of 30 runs in one measurement, so the
# program above does not by itself guard against that edit; the size assertion in
# `test_layout_guards` (the ring struct stays a small handle) does.
#
# The remote-execution settings come from `.buckconfig.local` in the repo root.
# Scratch goes under $TMPDIR; the snapshot is deleted on exit unless
# KEEP_SCRATCH=1, and its buck2 daemon is stopped.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
RUNS=${RUNS:-30}
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_spsc_prefix.XXXXXX")
die() { echo "FAIL  spsc ring slot-store layout: $1"; echo "logs: $W"; exit 1; }
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

P="$W/src/src/komira_spsc_prefix_probe"
mkdir "$P"
SRC="$ROOT/src/komira_spsc_ring/spsc_ring.mojo"
TEMPLATE="$ROOT/tools/build/tests/negative/spsc_ring_prefix_layout/consumer_polling.mojo"
echo "" > "$P/__init__.mojo"

cp "$ROOT/tools/build/tests/negative/spsc_ring_prefix_layout/prefix_ring.mojo" "$P/prefix_ring.mojo"
sed 's/RING_MODULE/komira_spsc_ring.spsc_ring/' "$TEMPLATE" > "$P/green.mojo"
sed 's/RING_MODULE/komira_spsc_prefix_probe.prefix_ring/' "$TEMPLATE" > "$P/red.mojo"
cat > "$P/BUCK" <<'B'
load("@komira//tools/build/mojo:defs.bzl", "mojo_binary", "mojo_library")

mojo_library(
    name = "komira_spsc_prefix_probe",
    srcs = ["__init__.mojo", "prefix_ring.mojo"],
    deps = ["//src/komira_core:komira_core", "//src/komira_atomic_alias:komira_atomic_alias"],
)
mojo_binary(name = "green", srcs = ["green.mojo"], deps = ["//src/komira_spsc_ring:komira_spsc_ring", "//src/komira_atomic_alias:komira_atomic_alias"])
mojo_binary(name = "red", srcs = ["red.mojo"], deps = [":komira_spsc_prefix_probe", "//src/komira_spsc_ring:komira_spsc_ring", "//src/komira_atomic_alias:komira_atomic_alias"])
B

bin() { # <target> -> path of the built binary
    (cd "$W/src" && "$BUCK2" build --show-output "//src/komira_spsc_prefix_probe:$1" 2> "$W/$1.log" | awk 'NR==1{print $2}')
}
G=$(bin green); [ -n "$G" ] || die "the control did not build (see $W/green.log)"
R=$(bin red); [ -n "$R" ] || die "the old layout did not build (see $W/red.log)"
# a mojo_binary's output is a link; the runnable tree beside it carries the shared libraries
G="$W/src/$G.runnable/$(basename "$G")"; R="$W/src/$R.runnable/$(basename "$R")"
for i in 1 2 3 4 5; do
    "$G" > "$W/green.run" 2>&1 || die "the control (current layout) failed on run $i: the ring itself is broken (see $W/green.run)"
done
fails=0
for i in $(seq 1 "$RUNS"); do
    if ! "$R" > "$W/red.run" 2>&1; then fails=$((fails + 1)); break; fi
done
[ "$fails" -gt 0 ] || die "the old layout (slot store in the struct) passed $RUNS runs: the regression test cannot fail on the bug it guards"
echo "PASS  spsc ring slot-store layout: the current ring passed 5 of 5 runs; the slot store in the struct failed (run $i of at most $RUNS)"
echo "logs: $W"
