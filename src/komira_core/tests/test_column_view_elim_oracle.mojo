# =============================================================================
# `Column.as_primitive` copy-vs-share byte oracle
# =============================================================================
#
# `Column.as_primitive` on a NON-NULLABLE column replaces a MEMCPY of the
# value window with an Arc refcount bump over exactly that window
# (`SharedAlignedBuffer.share_range_as`) and rebases to `offset == 0`. A
# nullable column keeps the copy, because the copy's validity-rebase is
# load-bearing for a large population of offset-blind consumers (see
# `as_primitive` in `column.mojo`).
#
# The share and the copy agree on `offset`, on `data.len()`, and on every
# value. (A share that hands back the whole source buffer plus an offset
# makes `Column.from_primitive` and `PrimitiveArray.slice` — both of which
# copy `[0, offset + length)` from byte 0 — turn a window copy into a PREFIX
# copy downstream while every value stays right. This file asserts VALUES;
# the EXTENT half is asserted by
# `test_as_primitive_sliced_column_byte_equiv.mojo`.)
#
# This oracle asserts the property that must hold for the swap to be legal:
# **every logical cell read through the returned PrimitiveArray is identical
# under both branches** — values, validity, and null_count — INCLUDING on an
# Arc-sliced column where `_offset > 0` (the per-morsel shape `Column.slice`
# produces on the hot path).
#
# HOW THIS ORACLE CAN FAIL — it is written so it FAILS in the direction it
# guards:
#   * value drift  -> `expected_at(i)` mismatches (a share that forgot
#     `_offset` reads the wrong window and every assert fires).
#   * validity drift -> `is_null(i)` mismatches.
#   * null_count drift -> the window count assert fires.
#   * ★ GATE drift -> `test_nullable_keeps_rebased_validity_invariant` and
#     `test_nullable_clone_array_validity_consumer` fire. These two assert
#     the copy-path invariant that OFFSET-BLIND CONSUMERS depend on
#     (`offset == 0` and `validity.length == length`, i.e. bit `i` of the
#     bitmap describes row `i`), and they exercise it through a REAL such
#     consumer (`clone_array_validity`). Removing the `not self._validity`
#     gate in `as_primitive` turns both RED.
#
# The asserts are written against the SPEC (an independently computed
# expectation), NOT against whichever branch runs — a correct copy and a
# correct share are indistinguishable by construction. The one test that CAN
# tell them apart is `test_non_nullable_as_primitive_aliases_the_source`: it
# writes through one handle and reads another, and asserts the SHARE — the
# write must be visible through a second handle AT THE ABSOLUTE ROW, and at no
# other row. A copy arm cannot pass that. ⛔ IT IS THIS FILE'S ONLY
# REPRESENTATION ORACLE; do not weaken it into a value differential.
# ⚠ The mutation is legitimate THERE and nowhere else: writing through an
# `as_primitive` result is the mutate-through-alias hazard every caller must
# avoid. That test owns every handle involved and is proving aliasing on
# purpose — the same carve-out `test_sab_share_range_window.mojo` states for
# the primitive.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    PrimitiveArray,
    Column,
    ArrowType,
)
from komira_core.arrow.bitmap import Bitmap
from komira_core.helpers.compiler_helpers import clone_array_validity
from komira_core.io.heap_region import HeapRegion


comptime _N = 4096
comptime _SLICE_START = 1301  # deliberately not a multiple of 8 or 64
comptime _SLICE_LEN = 999


def _expected_i64(i: Int) -> Int64:
    """The value the fixture stores at absolute row `i`."""
    return Int64(i * 7 - 11)


def _expected_valid(i: Int) -> Bool:
    """The validity the nullable fixture stores at absolute row `i`.
    Chosen so the pattern is NOT byte-aligned (period 5) — a share that
    rebases validity to bit 0 or drops the offset reads a shifted mask."""
    return (i % 5) != 0


def _build_col() raises -> Column[HeapRegion]:
    var vals = List[Scalar[DType.int64]]()
    for i in range(_N):
        vals.append(_expected_i64(i))
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    return Column.from_primitive[DType.int64](arr)


def _build_nullable_col() raises -> Column[HeapRegion]:
    var vals = List[Scalar[DType.int64]]()
    for i in range(_N):
        vals.append(_expected_i64(i))
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var bm = Bitmap.create_all_valid(_N)
    var nulls = 0
    for i in range(_N):
        if not _expected_valid(i):
            bm.clear(i)
            nulls += 1
    arr.validity = bm^
    arr.null_count = nulls
    return Column.from_primitive[DType.int64](arr)


def test_view_elim_whole_column() raises:
    """offset == 0: both branches must read the whole column identically."""
    var col = _build_col()
    var pa = col.as_primitive[DType.int64]()
    assert_equal(pa.length, _N)
    assert_equal(pa.null_count, 0)
    for i in range(_N):
        assert_equal(pa.get(i), _expected_i64(i))


def test_view_elim_offset_window() raises:
    """THE discriminating case: an Arc-sliced column with `_offset > 0`.

    Both branches MUST read the same logical cells — `pa.get(j) == value at
    absolute row (_SLICE_START + j)`. A share that loses the window's start
    reads from absolute row `j` instead and every assert below fires.

    ⚠ The two branches also agree on `offset` (both 0) and on `data.len()`;
    the share narrows the Arc-shared range to the window rather than handing
    back the whole source buffer plus an offset. This case does NOT assert
    that — it is the VALUE oracle. The extent assertions live in
    `test_as_primitive_sliced_column_byte_equiv.mojo`.
    """
    var col = _build_col()
    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    assert_equal(sliced.length(), _SLICE_LEN)
    var pa = sliced.as_primitive[DType.int64]()
    assert_equal(pa.length, _SLICE_LEN)
    assert_equal(pa.null_count, 0)
    for j in range(_SLICE_LEN):
        assert_equal(pa.get(j), _expected_i64(_SLICE_START + j))


def test_view_elim_offset_window_nullable() raises:
    """Same discriminating slice, WITH a non-byte-aligned validity mask.

    Whichever branch runs, the per-row null mask and the WINDOW null_count
    read through the array's own (offset-aware) accessors must match spec.
    """
    var col = _build_nullable_col()
    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    var pa = sliced.as_primitive[DType.int64]()
    assert_equal(pa.length, _SLICE_LEN)

    var expected_nulls = 0
    for j in range(_SLICE_LEN):
        var abs_i = _SLICE_START + j
        var want_valid = _expected_valid(abs_i)
        if want_valid:
            assert_false(pa.is_null(j), "row must be VALID")
            assert_equal(pa.get(j), _expected_i64(abs_i))
        else:
            assert_true(pa.is_null(j), "row must be NULL")
            expected_nulls += 1
    assert_equal(pa.null_count, expected_nulls)


def test_nullable_keeps_rebased_validity_invariant() raises:
    """★ F2 GATE GUARD. A NULLABLE column must come back on the COPY path.

    A large population of consumers reads `arr.validity` directly and indexes
    it from bit 0, ignoring `arr.offset` — `clone_array_validity`,
    `merge_binary_arith_validity`, `merge_cmp_validity` (behind every kleene
    predicate finalize), and the per-row `validity.test(i)` walks in the join
    and binary-fn operators. They are correct ONLY because the copy path
    guarantees two things about the returned array:

        offset == 0                    (bit `i` describes row `i`)
        validity.length == length      (no bits past the window)

    Both are asserted here on the discriminating `_offset > 0` slice. This is
    the same invariant `Column.slice`'s docstring calls out for
    `split_record_batch`, which likewise diverts nullable columns to the copy.

    FAILS IN THE DIRECTION IT GUARDS: delete the `not self._validity` gate in
    `Column.as_primitive` — the shared array comes back with
    `offset == 1301` and `validity.length == 4096` against
    `length == 999`, and both asserts fire.
    """
    var col = _build_nullable_col()
    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    var pa = sliced.as_primitive[DType.int64]()

    assert_equal(
        pa.offset,
        0,
        "nullable as_primitive must rebase to offset 0 (offset-blind"
        " validity consumers index the bitmap from bit 0)",
    )
    assert_true(pa.validity, "nullable column must keep its validity bitmap")
    assert_equal(
        pa.validity.value().length,
        pa.length,
        "nullable as_primitive must rebase validity to exactly the window"
        " (a shared whole-column bitmap over-counts null_count/popcount)",
    )


def test_nullable_clone_array_validity_consumer() raises:
    """★ F2 CONSUMER GUARD — the silent-wrong this gate exists to prevent.

    `clone_array_validity` is a REAL, live consumer (reached from
    `int64_to_float64` / `float64_to_int64` casts and ~8 sites in
    `compiler_eval_column`). Its body is
    `Bitmap.copy_slice_from(src_bm, 0, src_bm.length)` — bit-offset 0, whole
    bitmap. Run a nullable `_offset > 0` slice through it and assert the
    cloned mask describes the WINDOW's rows.

    FAILS IN THE DIRECTION IT GUARDS: with the gate removed,
    `src.validity` is the shared whole-column bitmap, so the clone reproduces
    absolute rows [0, 4096) instead of [1301, 2300) — the mask is shifted by
    1301 rows and the null_count is the whole column's. Because
    `_expected_valid` has period 5 and 1301 % 5 == 1, the shift is visible on
    the very first rows, and the length assert fires immediately.

    No crash, no raise — just a wrong answer. That is the whole point.
    """
    var col = _build_nullable_col()
    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    var src = sliced.as_primitive[DType.int64]()

    var dst = PrimitiveArray[DType.float64].allocate(_SLICE_LEN)
    clone_array_validity[DType.int64, DType.float64](src, dst)

    assert_true(dst.validity, "clone must carry the nullable mask across")
    assert_equal(
        dst.validity.value().length,
        _SLICE_LEN,
        "cloned validity must span exactly the window's rows",
    )

    var expected_nulls = 0
    for j in range(_SLICE_LEN):
        var want_valid = _expected_valid(_SLICE_START + j)
        assert_equal(
            dst.validity.value().test(j),
            want_valid,
            "cloned validity bit must describe the WINDOW row, not an"
            " absolute row shifted by the slice offset",
        )
        if not want_valid:
            expected_nulls += 1
    assert_equal(dst.null_count, expected_nulls)


def test_view_elim_source_column_unmodified() raises:
    """Aliasing guard: reading through the returned array must not disturb the
    source column, and the source must still read correctly AFTER the array is
    dropped (the share branch's Arc must keep the bytes pinned)."""
    var col = _build_col()
    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    var checksum = Int64(0)
    var pa = sliced.as_primitive[DType.int64]()
    for j in range(_SLICE_LEN):
        checksum += pa.get(j)
    # `pa` dies here; under the share branch the source column's Arc'd bytes
    # must survive its destructor.
    var recomputed = Int64(0)
    var pa2 = sliced.as_primitive[DType.int64]()
    for j in range(_SLICE_LEN):
        recomputed += pa2.get(j)
    assert_equal(checksum, recomputed)
    # And the ORIGINAL (unsliced) column is untouched.
    var whole = col.as_primitive[DType.int64]()
    for i in range(0, _N, 97):
        assert_equal(whole.get(i), _expected_i64(i))


def test_non_nullable_as_primitive_aliases_the_source() raises:
    """★ THE MECHANISM ORACLE — a share and a memcpy, told apart.

    Every read-only assertion in this file passes under BOTH branches by
    design. Only a WRITE can distinguish them: write through one handle on a
    NON-NULLABLE column, read another handle onto the same column.

    The fixture is the whole point. `_N` is 4096 rows and the window starts at
    `_SLICE_START = 1301`, so a share whose base byte-offset is computed WRONG
    but stays in bounds — the mis-index this is here to catch, notably an
    `offset == 0` mis-base — lands the write
    on a DIFFERENT LIVE ROW instead of faulting. A small fixture would red for
    an out-of-bounds reason, which is not coverage of anything. The three
    negative reads below are what turn "the write landed somewhere" into "the
    write landed at absolute row `_SLICE_START + j` and nowhere else":
    row `j` is exactly where a base-0 mis-share would have scribbled.

    ⚠ MUTATION CARVE-OUT: writing through an `as_primitive` result is the
    mutate-through-alias hazard every caller must avoid. It is legitimate in
    this test and nowhere else —
    this function owns the column and both handles, and aliasing is the
    property under test. Same carve-out `test_sab_share_range_window.mojo`
    states for `share_range_as` itself.
    """
    var sentinel = Int64(-424242)
    var j = 500  # inside [0, _SLICE_LEN)

    var col = _build_col()
    # Taken BEFORE the write. Under sharing it aliases the same bytes; under
    # copying it is an independent snapshot.
    var whole = col.as_primitive[DType.int64]()
    var sliced = col.slice(_SLICE_START, _SLICE_LEN)
    var win = sliced.as_primitive[DType.int64]()

    assert_equal(
        win.get(j),
        _expected_i64(_SLICE_START + j),
        "fixture: window row j reads absolute row _SLICE_START + j",
    )
    win.set(j, sentinel)
    assert_equal(win.get(j), sentinel, "the write is visible in its own handle")

    # SHARE: the window aliases `[_SLICE_START, _SLICE_START + _SLICE_LEN)`
    # of the column's own buffer, so the write must be observable through a
    # second handle onto that column, AT THE ABSOLUTE ROW.
    assert_equal(
        whole.get(_SLICE_START + j),
        sentinel,
        "as_primitive share: a write at window row j must land at ABSOLUTE"
        " row _SLICE_START + j of the shared buffer",
    )
    # ...and NOWHERE ELSE. A base-0 mis-share would have written row j.
    assert_equal(
        whole.get(j),
        _expected_i64(j),
        "the share must not be based at byte 0 — row j is where a"
        " mis-based (offset-dropping) share would scribble",
    )
    assert_equal(
        whole.get(_SLICE_START + j - 1),
        _expected_i64(_SLICE_START + j - 1),
        "neighbour below the written row is untouched",
    )
    assert_equal(
        whole.get(_SLICE_START + j + 1),
        _expected_i64(_SLICE_START + j + 1),
        "neighbour above the written row is untouched",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
