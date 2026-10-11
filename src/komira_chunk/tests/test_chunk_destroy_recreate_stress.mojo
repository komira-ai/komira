# =============================================================================
# DESTROY-RECREATE STRESS -- the chunk container keeps its heap state intact
# under destroy-recreate cycles and allocator churn.
# =============================================================================
#
# The hazard shape: a Movable struct whose fields OWN heap resources
# (List[Int64]) placed in a container, accessed via an @always_inline def method
# that reads `self.state[k]`, round-tripped through the container's
# destroy-recreate cycle. If a field held a wildcard-origin pointer, an
# early-destroyed inner List[Int64] header would point at a recycled allocator
# block and the checksum would DIVERGE.
#
# This test composes the container primitives the way a pipeline uses them:
#   * a `Chunk` (BumpArena byte region + inline-array POD vectors) filled with
#     numeric data, read back through a ChunkView, RESET, refilled;
#   * ALONGSIDE a `Slab[HeapRowProbe]` -- the heap-owning Movable struct (the
#     hazard shape) placed in the container harness.
# Both live in ONE parent `StressHarness`, destroyed and recreated N times under
# allocator churn. The oracle is a deterministic checksum computed from BOTH
# the chunk read-back AND the heap-probe @always_inline reads. The heap-owning
# state is routed through a live BumpArena reset cycle.
#
# Required invariants (review-time), all satisfied by the primitives:
#   (a) Chunk's arena is a `List[UInt8]` byte region behind `OwnedPointer` with a
#       CONCRETE origin -- NEVER a wildcard cast at a byte-slab boundary.
#   (b) ChunkVector is POD (inline-array-safe) -- no heap field to dangle.
#   (c) HeapRowProbe access is `ref [slab._bytes] T` (tight-origin) -- the byte
#       buffer outlives the borrow, so `state`'s heap buffer is kept alive.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true

from komira_collections.slab import Slab
from komira_chunk.chunk import Chunk, chunk_view_over

comptime _DT_I64: UInt8 = 10


# -----------------------------------------------------------------------------
# HeapRowProbe -- the hazard SHAPE: a Movable struct with a heap-owning
# List[Int64] field, read via an @always_inline def method.
# -----------------------------------------------------------------------------
struct HeapRowProbe(Movable, Deinitable):
    """A per-row heap-owning accumulator. `state[0]` is a running total; the
    trailing entries are payload the sum walks (so the @always_inline read
    dereferences the heap buffer, not just a header word)."""

    var state: List[Int64]
    var seed: Int64

    def __init__(out self, seed: Int64):
        self.state = [Int64(0), seed, seed * 2, seed * 3]
        self.seed = seed

    @always_inline
    def bump_first(mut self, delta: Int64):
        self.state[0] += delta + self.seed

    @always_inline
    def sum_state(self) -> Int64:
        # The hazard shape: reading `self.state[k]` from an @always_inline def
        # where self came through a slab ref. Tight-origin access keeps the
        # heap buffer alive for the borrow's scope.
        var s = Int64(0)
        for k in range(len(self.state)):
            s += self.state[k]
        return s


# -----------------------------------------------------------------------------
# StressHarness -- the container: a Chunk (new arena container) + a Slab of
# heap-owning probes, in ONE parent struct destroyed/recreated per iteration.
# -----------------------------------------------------------------------------
struct StressHarness(Movable, Deinitable):
    var chunk: Chunk
    var probes: Slab[HeapRowProbe]

    def __init__(out self, grain: Int):
        var cap = grain * 2 * size_of[Int64]() + 4096
        self.chunk = Chunk(grain, cap)
        _ = self.chunk.bind_column(_DT_I64, size_of[Int64]())
        _ = self.chunk.bind_column(_DT_I64, size_of[Int64]())
        self.probes = Slab[HeapRowProbe]()

    def add_probe(mut self, seed: Int64):
        self.probes.append(HeapRowProbe(seed))

    # Tight-origin accessor: chains through the inner Slab's `_bytes` field
    # (the tight-origin accessor shape).
    def get_probe(ref self, idx: Int) -> ref [self.probes._bytes] HeapRowProbe:
        return self.probes.get(idx)


# -----------------------------------------------------------------------------
# One iteration: build the harness, fill the chunk arena, populate + drive the
# heap probes, RESET the chunk and refill, and return a deterministic checksum
# over BOTH the chunk read-back and the heap-probe @always_inline reads. The
# harness drops on return (Chunk arena bytes + Slab probe state both released).
# -----------------------------------------------------------------------------
def stress_iter(grain: Int, n_probes: Int) raises -> Int64:
    var h = StressHarness(grain)
    var checksum = Int64(0)

    # ---- Fill the chunk arena (pull 1) and read it back through a view. ----
    for i in range(grain):
        h.chunk.store_scalar[DType.int64](0, i, Int64(i + 1))
        h.chunk.store_scalar[DType.int64](1, i, Int64((i + 1) * 3))
    h.chunk.set_n_rows(grain)
    var cv1 = chunk_view_over(h.chunk)
    for i in range(grain):
        checksum += cv1.col_load_scalar[DType.int64](0, i)
        checksum += cv1.col_load_scalar[DType.int64](1, i)

    # ---- Populate the heap-owning probes; drive the hazard-shape read. ----
    for p in range(n_probes):
        h.add_probe(Int64(p + 1))
    for p in range(n_probes):
        ref probe = h.get_probe(p)
        probe.bump_first(Int64(p))
        checksum += probe.sum_state()

    # ---- RESET the chunk arena (rewind + generation bump), refill (pull 2). ----
    h.chunk.reset()
    for i in range(grain):
        h.chunk.store_scalar[DType.int64](0, i, Int64(i + 1) * 5)
        h.chunk.store_scalar[DType.int64](1, i, Int64(i + 1) * 7)
    h.chunk.set_n_rows(grain)
    var cv2 = chunk_view_over(h.chunk)
    for i in range(grain):
        checksum += cv2.col_load_scalar[DType.int64](0, i)
        checksum += cv2.col_load_scalar[DType.int64](1, i)

    # ---- Re-drive the heap probes AFTER the chunk reset (interleaved). ----
    for p in range(n_probes):
        ref probe = h.get_probe(p)
        checksum += probe.sum_state()

    return checksum


# -----------------------------------------------------------------------------
# tcmalloc churn between iterations: dirties the small-object freelist with a
# different size class than the arena / probe state use. If a field had left a
# dangling pointer in recycled bytes, the next stress_iter would diverge.
# -----------------------------------------------------------------------------
def churn_round(rounds: Int):
    for _ in range(rounds):
        var scratch = List[Int64]()
        scratch.resize(2048, Int64(0))
        for k in range(2048):
            scratch[k] = Int64(k * 31 + 7)
        # scratch drops here.


# -----------------------------------------------------------------------------
# The oracle test: the reference checksum computed once must be reproduced
# by every subsequent destroy-recreate iteration under tcmalloc churn.
# -----------------------------------------------------------------------------
def test_chunk_container_destroy_recreate() raises:
    var GRAIN = 128
    var PROBES = 64
    var ITERS = 12

    var reference = stress_iter(GRAIN, PROBES)

    for it in range(ITERS):
        # Churn a different size class than the arena/probe allocations.
        churn_round(8)
        var checksum = stress_iter(GRAIN, PROBES)
        assert_equal(
            checksum,
            reference,
            "divergence at iter "
            + String(it)
            + ": container corruption under destroy-recreate + churn",
        )


# -----------------------------------------------------------------------------
# A second oracle at a DIFFERENT scale (more probes, smaller grain) to vary
# the arena vs probe-state size-class interplay (the parent-struct
# teardown-ordering check).
# -----------------------------------------------------------------------------
def test_chunk_container_destroy_recreate_scaled() raises:
    var GRAIN = 64
    var PROBES = 200
    var ITERS = 6

    var reference = stress_iter(GRAIN, PROBES)
    var fails = 0
    for _ in range(ITERS):
        churn_round(16)
        var checksum = stress_iter(GRAIN, PROBES)
        if checksum != reference:
            fails += 1
    assert_equal(fails, 0)


# -----------------------------------------------------------------------------
# Sanity: the checksum is non-trivial (the read path actually touched data --
# guards against a vacuously-passing all-zero oracle).
# -----------------------------------------------------------------------------
def test_destroy_recreate_oracle_is_nontrivial() raises:
    var v = stress_iter(32, 16)
    assert_true(v > Int64(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
