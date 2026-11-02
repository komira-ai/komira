# =============================================================================
# Unit tests for BumpArena (the O(1)-reset arena allocator)
# =============================================================================
#
# Exercises: bind-time alloc + 64-alignment; the DECLINE-on-overflow contract
# (never grows); O(1) reset (rewind, reuse); typed SIMD store/load roundtrips;
# the ByteView public surface; capacity queries.
# =============================================================================

from std.sys import size_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
    assert_almost_equal,
)

from komira_bump_arena.bump_arena import BumpArena, ARENA_DECLINE, ARENA_ALIGN


# -----------------------------------------------------------------------------
# (a) alloc hands out non-negative, 64-aligned handles and advances the cursor.
# -----------------------------------------------------------------------------
def test_alloc_aligned_and_advances() raises:
    var a = BumpArena(4096)
    assert_equal(a.capacity() % ARENA_ALIGN, 0)
    assert_true(a.capacity() >= 4096)
    assert_equal(a.used(), 0)

    var h0 = a.alloc(64)
    assert_equal(h0, 0)
    assert_equal(a.used(), 64)

    # A 1-byte request rounds up to the 64-byte alignment boundary.
    var h1 = a.alloc(1)
    assert_equal(h1, 64)
    assert_equal(h1 % ARENA_ALIGN, 0)
    assert_equal(a.used(), 128)

    var h2 = a.alloc(100)  # rounds to 128
    assert_equal(h2, 128)
    assert_equal(a.used(), 256)
    assert_equal(a.remaining(), a.capacity() - 256)


# -----------------------------------------------------------------------------
# (b) DECLINE-on-overflow: a request past capacity returns the sentinel and does
#     NOT grow / does NOT advance the cursor.
# -----------------------------------------------------------------------------
def test_decline_on_overflow_never_grows() raises:
    var a = BumpArena(256)
    var cap = a.capacity()
    var h = a.alloc(cap)  # exactly fills
    assert_equal(h, 0)
    assert_equal(a.remaining(), 0)
    assert_false(a.would_fit(1))

    var declined = a.alloc(1)
    assert_equal(declined, ARENA_DECLINE)
    # Capacity + cursor unchanged -- no growth.
    assert_equal(a.capacity(), cap)
    assert_equal(a.used(), cap)


# -----------------------------------------------------------------------------
# (c) reset is O(1) reuse: rewinds the cursor, capacity unchanged, handles
#     re-issue at the same offsets.
# -----------------------------------------------------------------------------
def test_reset_rewinds_and_reuses() raises:
    var a = BumpArena(1024)
    var cap = a.capacity()
    var h0 = a.alloc(128)
    var h1 = a.alloc(128)
    assert_equal(a.used(), 256)

    a.reset()
    assert_equal(a.used(), 0)
    assert_equal(a.capacity(), cap)  # no free, no realloc

    # Re-issued handles land at the identical (deterministic) offsets.
    assert_equal(a.alloc(128), h0)
    assert_equal(a.alloc(128), h1)


# -----------------------------------------------------------------------------
# (d) typed scalar store/load roundtrip across DTypes at a handle.
# -----------------------------------------------------------------------------
def test_typed_scalar_roundtrip() raises:
    var a = BumpArena(4096)
    var h = a.alloc(64 * size_of[Int64]())

    for i in range(64):
        a.store_scalar[DType.int64](h, i, Int64(i * 7 - 3))
    for i in range(64):
        assert_equal(a.load_scalar[DType.int64](h, i), Int64(i * 7 - 3))

    var hf = a.alloc(32 * size_of[Float64]())
    for i in range(32):
        a.store_scalar[DType.float64](hf, i, Float64(i) * 0.25)
    for i in range(32):
        assert_almost_equal(a.load_scalar[DType.float64](hf, i), Float64(i) * 0.25)

    # Two handles do not alias: the i64 region is intact after the f64 writes.
    for i in range(64):
        assert_equal(a.load_scalar[DType.int64](h, i), Int64(i * 7 - 3))


# -----------------------------------------------------------------------------
# (e) SIMD-width store/load roundtrip (the kernel-ABI seam).
# -----------------------------------------------------------------------------
def test_simd_roundtrip() raises:
    var a = BumpArena(4096)
    var h = a.alloc(16 * size_of[Int32]())
    var v = SIMD[DType.int32, 4](10, 20, 30, 40)
    a.store_simd[DType.int32, 4](h, 0, v)
    a.store_simd[DType.int32, 4](h, 4, v + 1)
    var r0 = a.load_simd[DType.int32, 4](h, 0)
    var r1 = a.load_simd[DType.int32, 4](h, 4)
    for lane in range(4):
        assert_equal(r0[lane], v[lane])
        assert_equal(r1[lane], v[lane] + 1)


# -----------------------------------------------------------------------------
# (f) ByteView public surface: mutate + read back the same bytes.
# -----------------------------------------------------------------------------
def test_byteview_surface() raises:
    var a = BumpArena(1024)
    var h = a.alloc(64)
    var bytes_needed = 8 * size_of[Int64]()
    var view = a.view(h, bytes_needed)
    assert_equal(view.len(), bytes_needed)
    for i in range(8):
        view.set_typed[Int64](i, Int64(i * i))
    # Read back through the arena's typed load (same bytes).
    for i in range(8):
        assert_equal(a.load_scalar[DType.int64](h, i), Int64(i * i))


# -----------------------------------------------------------------------------
# (g) empty arena: every alloc DECLINEs.
# -----------------------------------------------------------------------------
def test_empty_arena_declines() raises:
    var a = BumpArena(0)
    assert_equal(a.capacity(), 0)
    assert_equal(a.alloc(8), ARENA_DECLINE)
    assert_false(a.would_fit(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
