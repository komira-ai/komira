# =============================================================================
# Unit tests for the Chunk container (reset-not-reconstruct)
# =============================================================================
#
# Exercises: bind-time column binding (FLAT arena-resident) + DECLINE; per-pull
# fill + ChunkView read-back (the process_chunk seam); O(1) reset that reuses
# the geometry AND bumps the generation; the generation guard (stale-view
# stamp caught, fresh view valid); multi-column mixed-DType fill.
# =============================================================================

from std.sys import size_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
    assert_almost_equal,
)

from komira_chunk.chunk import (
    Chunk,
    ChunkView,
    ChunkVector,
    chunk_view_over,
    CHUNK_KIND_FLAT,
    CHUNK_KIND_UNBOUND,
    MAX_LIVE_COLS,
)

# Diagnostic dtype tags (the runtime shadow; the typed load is comptime-DType).
comptime _DT_I64: UInt8 = 10
comptime _DT_F64: UInt8 = 11
comptime _DT_I32: UInt8 = 12


# -----------------------------------------------------------------------------
# (a) bind FLAT columns, fill, read back through a ChunkView.
# -----------------------------------------------------------------------------
def test_bind_fill_and_view_readback() raises:
    # grain 128 rows, arena for 2 i64 cols (+ headroom).
    var grain = 128
    var cap = grain * 2 * size_of[Int64]() + 4096
    var c = Chunk(grain, cap)
    assert_true(c.bind_column(_DT_I64, size_of[Int64]()))
    assert_true(c.bind_column(_DT_I64, size_of[Int64]()))
    assert_equal(c.num_live_cols(), 2)
    assert_equal(Int(c.col_kind(0)), Int(CHUNK_KIND_FLAT))
    assert_true(c.col_is_bound(0))
    assert_true(c.col_is_bound(1))

    for i in range(grain):
        c.store_scalar[DType.int64](0, i, Int64(i))
        c.store_scalar[DType.int64](1, i, Int64(i * i))
    c.set_n_rows(grain)
    assert_equal(c.num_rows(), grain)

    var cv = chunk_view_over(c)
    assert_equal(cv.n_rows(), grain)
    assert_equal(cv.num_live_cols(), 2)
    assert_equal(cv.col_length(0), grain)
    assert_true(cv.is_valid())
    var acc = Int64(0)
    for i in range(grain):
        assert_equal(cv.col_load_scalar[DType.int64](0, i), Int64(i))
        assert_equal(cv.col_load_scalar[DType.int64](1, i), Int64(i * i))
        acc += cv.col_load_scalar[DType.int64](0, i)
    assert_equal(acc, Int64(grain * (grain - 1) // 2))


# -----------------------------------------------------------------------------
# (b) unbound slot state before any bind.
# -----------------------------------------------------------------------------
def test_unbound_slot_default() raises:
    var v = ChunkVector()
    assert_equal(Int(v.kind), Int(CHUNK_KIND_UNBOUND))
    assert_false(v.is_bound())


# -----------------------------------------------------------------------------
# (c) reset: O(1) reuse -- clears rows, bumps generation, re-binds geometry so
#     a second pull refills at the same handles and reads correctly.
# -----------------------------------------------------------------------------
def test_reset_reuses_geometry_and_bumps_generation() raises:
    var grain = 64
    var cap = grain * size_of[Float64]() + 2048
    var c = Chunk(grain, cap)
    assert_true(c.bind_column(_DT_F64, size_of[Float64]()))
    assert_equal(Int(c.gen()), 0)

    for i in range(grain):
        c.store_scalar[DType.float64](0, i, Float64(i) + 0.5)
    c.set_n_rows(grain)
    var cv1 = chunk_view_over(c)
    assert_almost_equal(cv1.col_load_scalar[DType.float64](0, 3), Float64(3.5))

    c.reset()
    assert_equal(Int(c.gen()), 1)   # generation bumped
    assert_equal(c.num_rows(), 0)   # rows cleared
    assert_equal(c.num_live_cols(), 1)  # geometry retained (re-bound)

    # Second pull: refill DIFFERENT data, read back through a fresh view.
    for i in range(grain):
        c.store_scalar[DType.float64](0, i, Float64(i) * 2.0)
    c.set_n_rows(grain)
    var cv2 = chunk_view_over(c)
    assert_equal(Int(cv2.generation()), 1)
    assert_true(cv2.is_valid())
    for i in range(grain):
        assert_almost_equal(cv2.col_load_scalar[DType.float64](0, i), Float64(i) * 2.0)


# -----------------------------------------------------------------------------
# (d) generation guard: a stamp captured before a reset is no longer
#     current after it; a fresh view stamps the new generation and IS current.
#     (A direct hold of a live view across a reset is compile-time forbidden by
#     the borrow checker -- the stronger guarantee; this exercises the runtime
#     belt via the value-level `is_generation_current`.)
# -----------------------------------------------------------------------------
def test_generation_guard_catches_stale_stamp() raises:
    var grain = 32
    var cap = grain * size_of[Int64]() + 1024
    var c = Chunk(grain, cap)
    _ = c.bind_column(_DT_I64, size_of[Int64]())
    c.set_n_rows(grain)

    var stamp_old = c.gen()             # capture the pre-reset stamp (value)
    assert_true(c.is_generation_current(stamp_old))

    c.reset()                            # invalidates any view stamped at stamp_old

    # The OLD stamp is now stale -- the guard catches it.
    assert_false(c.is_generation_current(stamp_old))
    # The live generation is current; a fresh view stamps it.
    var stamp_new = c.gen()
    assert_true(stamp_new != stamp_old)
    assert_true(c.is_generation_current(stamp_new))
    var cv = chunk_view_over(c)
    assert_true(cv.is_valid())
    assert_equal(Int(cv.generation()), Int(stamp_new))


# -----------------------------------------------------------------------------
# (e) bind DECLINEs when the arena cannot hold another column (never grows).
# -----------------------------------------------------------------------------
def test_bind_declines_on_arena_exhaustion() raises:
    var grain = 256
    # Arena sized for exactly ONE i64 column (no headroom for a second).
    var cap = grain * size_of[Int64]()
    var c = Chunk(grain, cap)
    assert_true(c.bind_column(_DT_I64, size_of[Int64]()))
    # Second bind cannot fit -> DECLINE (returns False), geometry unchanged.
    assert_false(c.bind_column(_DT_I64, size_of[Int64]()))
    assert_equal(c.num_live_cols(), 1)


# -----------------------------------------------------------------------------
# (f) multi-column mixed-DType fill + independent read-back (no aliasing).
# -----------------------------------------------------------------------------
def test_multi_column_mixed_dtype() raises:
    var grain = 100
    var row_w = size_of[Int64]() + size_of[Float64]() + size_of[Int32]()
    var cap = grain * row_w + 4096
    var c = Chunk(grain, cap)
    assert_true(c.bind_column(_DT_I64, size_of[Int64]()))
    assert_true(c.bind_column(_DT_F64, size_of[Float64]()))
    assert_true(c.bind_column(_DT_I32, size_of[Int32]()))
    assert_equal(c.num_live_cols(), 3)

    for i in range(grain):
        c.store_scalar[DType.int64](0, i, Int64(i - 50))
        c.store_scalar[DType.float64](1, i, Float64(i) * 0.1)
        c.store_scalar[DType.int32](2, i, Int32(i * 3))
    c.set_n_rows(grain)

    var cv = chunk_view_over(c)
    for i in range(grain):
        assert_equal(cv.col_load_scalar[DType.int64](0, i), Int64(i - 50))
        assert_almost_equal(cv.col_load_scalar[DType.float64](1, i), Float64(i) * 0.1)
        assert_equal(cv.col_load_scalar[DType.int32](2, i), Int32(i * 3))


# -----------------------------------------------------------------------------
# (g) set_n_rows clamps to grain.
# -----------------------------------------------------------------------------
def test_set_n_rows_clamps_to_grain() raises:
    var c = Chunk(16, 16 * size_of[Int64]() + 512)
    _ = c.bind_column(_DT_I64, size_of[Int64]())
    c.set_n_rows(999)
    assert_equal(c.num_rows(), 16)
    c.set_n_rows(-5)
    assert_equal(c.num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
