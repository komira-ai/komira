# =============================================================================
# test_sink_timings_keepalive.mojo — Wave 3 Part 0 KeepAlive repro
# =============================================================================
#
# Wave 2 Part D revealed that `SinkPhaseTimings` SIGSEGVs when threaded
# through a downstream `Segment` whose `finalize` does heap allocation
# (e.g. `_execute_topn_sink`). Investigation:
# an internal doc Hypothesis 1 — the
# struct was `Deinitable` rather than `KeepAlive`, so Mojo
# ASAP-destroyed it before `execute_sink` returned.
#
# This test is the minimal repro of that pattern. Pre-fix
# (`SinkPhaseTimings(Deinitable)`) it crashes inside the
# Slab `Atomic` allocation simulation. Post-fix
# (`SinkPhaseTimings(KeepAlive)` with a `__keep_alive` body) it must
# return cleanly.
#
# Wave 3 prelude commit: this test guards against regression of the
# 4-LOC fix in `sink_timings.mojo`.
# =============================================================================

from std.testing import assert_equal

from komira_collections.slab import Slab
from komira_operator_api.sink_timings import SinkPhaseTimings


def test_sink_timings_keepalive_under_heap_alloc() raises:
    """Reproduces the Wave 2 Part D SIGSEGV.

    Pattern (per the investigation doc):
      1. Build `SinkPhaseTimings` on the stack.
      2. Mutate via a borrowed `Pointer` (mimics the streaming
         worker's `record_consume` call).
      3. Trigger a heap allocation that, under tcmalloc bucket reuse,
         could alias the timings storage if the compiler ASAP-
         destroyed it. Slab[Atomic[UInt64]] of 64 entries fits the
         shape closely (mimics _execute_topn_sink's K-bounded-heap
         alloc, which is the kernel that crashed in Wave 2 Part D).
      4. Read the timings counter via the borrow. Pre-fix this reads
         heap-corrupted bytes; post-fix the value is exact.

    Post-fix expectation: PASS.
    Pre-fix expectation (`SinkPhaseTimings(Deinitable)`):
        SIGSEGV or wrong value.
    """
    var timings = SinkPhaseTimings()

    # Phase 1: simulate a worker recording a consume delta via borrow.
    # We use Pointer(to=...) to mirror the way `_StreamingState`
    # threads `&timings` through the Segment's bitcast restore.
    var p = Pointer(to=timings)
    p[].record_consume(UInt64(100))

    # Phase 2: simulate `_execute_topn_sink`'s allocation pattern —
    # a Slab of K Atomics fits the K-bounded-heap shape closely. If
    # `timings` was prematurely destroyed, tcmalloc bucket reuse can
    # alias the freed atomic storage with `s`'s heap region.
    # Note: Atomic is not Movable so cannot be Slab-stored; UInt64
    # heap pressure is sufficient to expose the lifetime bug.
    var s = Slab[UInt64].create(64)
    for _ in range(64):
        s.append(UInt64(0))

    # Phase 3: read back the timings counter through the borrowed
    # Pointer. Pre-fix this would read heap-corrupted bytes; post-fix
    # it must read 100 exactly.
    var v = p[].load_consume()
    assert_equal(v, UInt64(100), "SinkPhaseTimings.load_consume readback")

    # Phase 4: explicit keepalive on `s` — the Slab destructor runs
    # on scope exit; we want to make sure the AOT compiler doesn't
    # reorder the destructor BEFORE the load_consume above. Belt-and-
    # suspenders given the canonical fix is on `SinkPhaseTimings`'s
    # `__keep_alive` body, not here.
    _ = s^


def test_sink_timings_keepalive_repeated() raises:
    """Repeated record/load cycles after a heap allocation.

    Stresses the lifetime by interleaving heap allocation and
    timing-counter reads. Pre-fix any post-alloc read could fail.
    """
    var timings = SinkPhaseTimings()
    var p = Pointer(to=timings)

    p[].record_consume(UInt64(10))
    p[].record_combine_local(UInt64(20))
    p[].record_combine_partition(UInt64(30))
    p[].record_finalize(UInt64(40))

    # Interleave heap pressure between two read sweeps.
    var s = Slab[UInt64].create(128)
    for _ in range(128):
        s.append(UInt64(0))

    assert_equal(p[].load_consume(), UInt64(10), "consume readback")
    assert_equal(p[].load_combine_local(), UInt64(20), "combine_local readback")
    assert_equal(
        p[].load_combine_partition(), UInt64(30), "combine_partition readback"
    )
    assert_equal(p[].load_finalize(), UInt64(40), "finalize readback")

    _ = s^


def main() raises:
    print("=== Wave 3 Part 0 SinkPhaseTimings KeepAlive repro ===")
    test_sink_timings_keepalive_under_heap_alloc()
    test_sink_timings_keepalive_repeated()
    print("=== all SinkPhaseTimings KeepAlive tests passed ===")
