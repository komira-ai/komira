#!/usr/bin/env bash
# spsc_ring_element.sh -- SpscRing[T] refuses an element that is not plain data.
#
# usage: tools/build/tests/negative/spsc_ring_element.sh   (from the repo root; BUCK2 overrides the binary)
#
# SpscRing's slots are zero-filled and a push assigns over one, so the
# assignment runs T's destructor and copy on a slot that was never constructed.
# A T that owns heap memory would free garbage. The ring therefore carries two
# `comptime assert`s in its constructor (trivial destructor, trivial copy), and
# this check is their falsifier, in a snapshot of the working tree with a
# scratch package that uses komira_spsc_ring:
#   ok_plain    SpscRing[<plain 32-byte record>]        must BUILD  (the control:
#               the scratch package itself is sound, so the reds below are the
#               ring's refusals and not a broken harness)
#   ring_string SpscRing[String]                         must FAIL, "trivially destructible"
#   ring_copy   SpscRing[<trivial destructor, user-written copy>]
#                                                         must FAIL, "trivially copyable"
# It cannot live in the tests cell: that cell cannot depend on komira//src
# libraries (a different load of the Mojo rules), and `komira//...` must hold
# no target that fails by design.
#
# The remote-execution settings come from `.buckconfig.local` in the repo root,
# copied into the snapshot when present, or from the machine-wide buckconfig.
# Scratch goes under $TMPDIR; the snapshot is deleted on exit unless
# KEEP_SCRATCH=1, and its buck2 daemon is stopped. Logs are kept.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
BUCK2=${BUCK2:-$ROOT/buck2}
case "$BUCK2" in /*) ;; */*) BUCK2="$PWD/$BUCK2" ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/komira_spsc_element.XXXXXX")
die() { echo "FAIL  spsc ring element contract: $1"; echo "logs: $W"; exit 1; }
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

P="$W/src/src/komira_spsc_element_probe"
mkdir "$P"
cat > "$P/BUCK" <<'B'
load("@komira//tools/build/mojo:defs.bzl", "mojo_binary")

mojo_binary(name = "ok_plain", srcs = ["ok_plain.mojo"], deps = ["//src/komira_spsc_ring:komira_spsc_ring"])
mojo_binary(name = "ring_string", srcs = ["ring_string.mojo"], deps = ["//src/komira_spsc_ring:komira_spsc_ring"])
mojo_binary(name = "ring_copy", srcs = ["ring_copy.mojo"], deps = ["//src/komira_spsc_ring:komira_spsc_ring"])
B
cat > "$P/ok_plain.mojo" <<'M'
from komira_spsc_ring.spsc_ring import SpscRing


struct Plain(Copyable, Movable, Deinitable):
    var a: UInt64
    var b: UInt64
    var c: UInt32

    def __init__(out self):
        self.a = 0
        self.b = 0
        self.c = 0


def main() raises:
    var ring = SpscRing[Plain](16)
    _ = ring.try_push(Plain())
M
cat > "$P/ring_string.mojo" <<'M'
from komira_spsc_ring.spsc_ring import SpscRing


def main() raises:
    var ring = SpscRing[String](16)
    _ = ring.try_push(String("x"))
M
cat > "$P/ring_copy.mojo" <<'M'
from komira_spsc_ring.spsc_ring import SpscRing


struct Counted(Copyable, Movable, Deinitable):
    """Trivially destructible, but its copy is user code, not a memcpy."""

    var copies: Int

    def __init__(out self):
        self.copies = 0

    def __init__(out self, *, copy: Self):
        self.copies = copy.copies + 1


def main() raises:
    var ring = SpscRing[Counted](16)
    _ = ring.try_push(Counted())
M

build() { # <target> -> log in $W, status in $?
    (cd "$W/src" && "$BUCK2" build "//src/komira_spsc_element_probe:$1") > "$W/$1.log" 2>&1
}
build ok_plain || die "the control did not build: a plain record must instantiate SpscRing (see $W/ok_plain.log)"
build ring_string && die "SpscRing[String] BUILT: the element contract is not enforced"
grep -q "trivially destructible" "$W/ring_string.log" || die "SpscRing[String] failed, but not with the element-contract message (see $W/ring_string.log)"
build ring_copy && die "SpscRing of a user-copied element BUILT: the copy contract is not enforced"
grep -q "trivially copyable" "$W/ring_copy.log" || die "the user-copied element failed, but not with the copy-contract message (see $W/ring_copy.log)"
echo "PASS  spsc ring element contract: a plain record builds; String is refused (trivially destructible) and a user-copied element is refused (trivially copyable)"
echo "logs: $W"
