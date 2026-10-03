# =============================================================================
# test_arith_cast_offset_validity — validity-plane offset handling in the cast,
# arithmetic and binary-math seams
# =============================================================================
#
# A sliced operand's DATA plane is rebased by `PrimitiveArray.view_ro`, so its
# VALIDITY plane must be read at the same `offset`. This file covers three
# readers that must honour that offset:
#
#   CAST (`clone_array_validity`, used by `int64_to_float64` /
#   `float64_to_int64` / every `eval_cast` widen). An offset-blind
#   `Bitmap.copy_slice_from(src_bm, 0, src_bm.length)` copies from bit 0 and
#   copies the WHOLE bitmap. For an offset-2 view of a 5-row buffer with the
#   only NULL at ABSOLUTE row 0, the logical rows are all valid, yet such a
#   cast returns a 3-row array whose row 0 reads NULL. Move the NULL to
#   absolute row 3 and it returns all-valid with `null_count == 1`: a null
#   that is counted but cannot be found. Wrong in BOTH directions.
#
#   ARITHMETIC (`merge_binary_arith_validity`, behind every nullable
#   `a + b` / `a - b` / `a * b` / `a / b`). The same shape on both one-sided
#   arms, plus an offset-blind `bitmap_and` on the both-sided arm. It takes
#   `Column`s, whose `_offset` is on the struct it is already reading.
#
#   BINARY MATH (`scalar_math._propagate_binary_validity`, SEAM 3). Its
#   both-nullable arm spells the same whole-bitmap merge differently
#   (`left.validity.value().and_(right.validity.value())`).
#
# REACHABILITY. Neither seam is reached with a non-zero offset from a query
# today: `morsel._split_batch_into_morsels` gates its zero-copy
# `Column.slice` on `not src_col._validity`, and `Column.as_primitive`'s
# nullable arm copies and rebases. Both gates are PINNED here
# (`test_control_*_gate_*`), so the day either stops holding is a RED test
# rather than a wrong answer. `Column.slice`'s own docstring allows direct
# callers that read through an offset-honouring accessor to slice nullable
# columns, which is why the readers themselves must be offset-aware.
#
# NOT COVERED HERE: the per-row `X.validity.value().test(i)` walks in the join
# and binary-function operators. They stay offset-blind because every share
# gate (`can_share_as_primitive`, the morsel split) refuses a column carrying a
# validity bitmap; those gates must therefore stay as they are.
#
# Every case that varies the offset off zero fails against an offset-blind
# reader; the CONTROLS (offset 0, no bitmap, the production-gate pins) pass
# either way. `test_cast_offset_empty_slice` is NOT a control: a zero-row
# window over an all-null parent must report `null_count == 0`, and a reader
# that copies `bm.length` bits reports 3. A window SHORTER than its parent is
# enough to expose the whole-bitmap half of the defect, even at offset 0.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion

from komira_column_kernels.compiler_helpers import (
    clone_array_validity,
    int64_to_float64,
    merge_binary_arith_validity,
)
from komira_column_kernels.scalar_math import (
    KMATH2_ATAN2,
    KMATH_SQRT,
    eval_math_binary,
    eval_math_unary,
)


# ---------------------------------------------------------------------------
# Fixtures — the value in a NULL slot is CHOSEN, so a failure is deterministic
# rather than allocator-dependent. `null_abs` is in ABSOLUTE buffer
# coordinates, which is what `PrimitiveArray.slice` / `Column.slice` produce.
# ---------------------------------------------------------------------------


def _win_nulls(null_abs: List[Int], offset: Int, length: Int) -> Int:
    """The null count of the WINDOW — what `slice()` computes, not the
    whole-buffer count. Getting this wrong in the fixture would hand the
    assertions a pre-broken input and prove nothing."""
    var n = 0
    for k in range(len(null_abs)):
        var a = null_abs[k]
        if a >= offset and a < offset + length:
            n += 1
    return n


def _sliced_i64(
    raw_all: List[Int64], null_abs: List[Int], offset: Int, length: Int
) raises -> PrimitiveArray[DType.int64]:
    """A SLICED nullable INT64 array: data buffer AND validity bitmap indexed
    ABSOLUTELY over `len(raw_all)` rows; logical row i == absolute row
    `offset + i`."""
    var total = len(raw_all)
    comptime elem = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(total, 1) * elem)
    for i in range(total):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](raw_all[i]))
    buf.set_length(Int64(total * elem))
    var validity = Bitmap.create_all_valid(total)
    for k in range(len(null_abs)):
        validity.clear(null_abs[k])
    return PrimitiveArray[DType.int64](
        buf^,
        length,
        Optional[Bitmap[HeapRegion]](validity^),
        _win_nulls(null_abs, offset, length),
        offset,
    )


def _sliced_i64_no_validity(
    raw_all: List[Int64], offset: Int, length: Int
) raises -> PrimitiveArray[DType.int64]:
    """The same shape with NO bitmap — the fast path of both seams, which must
    stay allocation-free and answer-identical."""
    var total = len(raw_all)
    comptime elem = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(total, 1) * elem)
    for i in range(total):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](raw_all[i]))
    buf.set_length(Int64(total * elem))
    return PrimitiveArray[DType.int64](
        buf^, length, Optional[Bitmap[HeapRegion]](None), 0, offset
    )


def _sliced_col(
    raw_all: List[Int64], null_abs: List[Int], offset: Int, length: Int
) raises -> Column[HeapRegion]:
    """A nullable Column carrying `_offset > 0` — byte-for-byte the shape
    `Column.slice` returns (it shares the WHOLE-column bitmap and sets
    `_offset`), which `Column.from_primitive` reproduces because it preserves
    `arr.offset` and copies `offset + length` elements."""
    return Column.from_primitive[DType.int64](
        _sliced_i64(raw_all, null_abs, offset, length)
    )


def _null_cell(
    got: PrimitiveArray[DType.float64], i: Int, want_null: Bool, label: String
) raises:
    if want_null:
        assert_true(got.is_null(i), label + " row " + String(i) + ": must be NULL")
    else:
        assert_false(got.is_null(i), label + " row " + String(i) + ": must be VALID")


def _null_cell_i64(
    got: PrimitiveArray[DType.int64], i: Int, want_null: Bool, label: String
) raises:
    if want_null:
        assert_true(got.is_null(i), label + " row " + String(i) + ": must be NULL")
    else:
        assert_false(got.is_null(i), label + " row " + String(i) + ": must be VALID")


def _alloc_i64(vals: List[Int64]) raises -> PrimitiveArray[DType.int64]:
    """A fresh, offset-0, non-nullable result array — what every arithmetic
    kernel hands `merge_binary_arith_validity`."""
    var n = len(vals)
    comptime elem = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(n, 1) * elem)
    for i in range(n):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](vals[i]))
    buf.set_length(Int64(n * elem))
    return PrimitiveArray[DType.int64](
        buf^, n, Optional[Bitmap[HeapRegion]](None), 0, 0
    )


# =============================================================================
# ★ SEAM 1 — the CAST path (`clone_array_validity`, via `int64_to_float64`)
# =============================================================================


def test_cast_offset_invents_a_null() raises:
    """★ offset-2 view of a 5-row buffer, the ONLY null at ABSOLUTE row 0 —
    i.e. OUTSIDE the window. Logical rows [100, 5, 200] are all valid.

    OFFSET-BLIND: `copy_slice_from(src_bm, 0, src_bm.length)` copies bits {0..4}
    verbatim onto a result whose offset is 0, so result row 0 inherits absolute
    row 0's cleared bit and reads NULL. A row the caller can see, that the
    source says is valid."""
    var raw: List[Int64] = [7, 7, 100, 5, 200]
    var nulls: List[Int] = [0]
    var src = _sliced_i64(raw, nulls, 2, 3)
    assert_false(src.is_null(0), "fixture: logical row 0 is VALID at abs 2")
    var got = int64_to_float64(src)
    assert_equal(got.length, 3, "cast keeps the window length")
    _null_cell(got, 0, False, "cast invents")
    _null_cell(got, 1, False, "cast invents")
    _null_cell(got, 2, False, "cast invents")
    assert_equal(got.null_count, 0, "cast invents: null_count")


def test_cast_offset_loses_a_null() raises:
    """★ The inverse, one property varied: the same 5-row buffer with the only
    null at ABSOLUTE row 3 — i.e. INSIDE the window, logical row 1.

    OFFSET-BLIND: bit 3 of the verbatim copy lands past the 3-row window, so every
    visible row reads VALID while `null_count` says 1 — a null that is counted
    but cannot be found. `Bitmap.popcount`-based consumers and `is_null`
    consumers then disagree about the same array."""
    var raw: List[Int64] = [7, 7, 100, 5, 200]
    var nulls: List[Int] = [3]
    var src = _sliced_i64(raw, nulls, 2, 3)
    assert_true(src.is_null(1), "fixture: logical row 1 is NULL at abs 3")
    var got = int64_to_float64(src)
    assert_equal(got.length, 3, "cast keeps the window length")
    _null_cell(got, 0, False, "cast loses")
    _null_cell(got, 1, True, "cast loses")
    _null_cell(got, 2, False, "cast loses")
    assert_equal(got.null_count, 1, "cast loses: null_count")
    assert_equal(
        got.validity.value().length,
        3,
        "cast: the result bitmap is the WINDOW, not the whole source",
    )


def test_cast_offset_unaligned_crosses_a_byte() raises:
    """Offset 6, length 5 — the window straddles the byte boundary, so the
    bit-unaligned fallback in `copy_slice_from` is the code under test rather
    than its memcpy fast path. Nulls at absolute 6 and 10 => logical 0 and 4."""
    var raw: List[Int64] = [0, 0, 0, 0, 0, 0, 11, 12, 13, 14, 15]
    var nulls: List[Int] = [6, 10]
    var src = _sliced_i64(raw, nulls, 6, 5)
    var got = int64_to_float64(src)
    assert_equal(got.length, 5, "unaligned cast: length")
    _null_cell(got, 0, True, "unaligned cast")
    _null_cell(got, 1, False, "unaligned cast")
    _null_cell(got, 2, False, "unaligned cast")
    _null_cell(got, 3, False, "unaligned cast")
    _null_cell(got, 4, True, "unaligned cast")
    assert_equal(got.null_count, 2, "unaligned cast: null_count")


def test_cast_offset_all_null_window() raises:
    """The all-null slice. Every logical row NULL, and a VALID row sitting
    outside the window on each side so a bit-0 read cannot accidentally
    produce the right answer."""
    var raw: List[Int64] = [1, 2, 3, 4, 5]
    var nulls: List[Int] = [1, 2, 3]
    var src = _sliced_i64(raw, nulls, 1, 3)
    var got = int64_to_float64(src)
    _null_cell(got, 0, True, "all-null cast")
    _null_cell(got, 1, True, "all-null cast")
    _null_cell(got, 2, True, "all-null cast")
    assert_equal(got.null_count, 3, "all-null cast: null_count")


def test_cast_offset_single_row_slice() raises:
    """The single-row window. ⚠ Two directions, because the previous null
    landings each found a shape that was passing BY ACCIDENT: the VALID
    single-row case is right for an offset-blind reader whenever bit 0 happens to be set, so only
    the NULL single-row case discriminates."""
    var raw: List[Int64] = [1, 2, 3]
    var nulls_in: List[Int] = [2]
    var got_null = int64_to_float64(_sliced_i64(raw, nulls_in, 2, 1))
    assert_equal(got_null.length, 1, "single-row NULL: length")
    _null_cell(got_null, 0, True, "single-row NULL")
    assert_equal(got_null.null_count, 1, "single-row NULL: null_count")

    var nulls_out: List[Int] = [0]
    var got_valid = int64_to_float64(_sliced_i64(raw, nulls_out, 2, 1))
    _null_cell(got_valid, 0, False, "single-row VALID")
    assert_equal(got_valid.null_count, 0, "single-row VALID: null_count")


def test_cast_offset_empty_slice() raises:
    """★ NOT a control.

    A zero-length window over an all-null parent must report
    `null_count == 0`; a reader that copies `bm.length` bits regardless of the
    result's row count reports 3. So the whole-bitmap half of this defect
    bites at `offset == 0` too, whenever the window is SHORTER than its
    parent."""
    var raw: List[Int64] = [1, 2, 3]
    var nulls: List[Int] = [0, 1, 2]
    var got = int64_to_float64(_sliced_i64(raw, nulls, 2, 0))
    assert_equal(got.length, 0, "empty slice: length")
    assert_equal(got.null_count, 0, "empty slice: null_count")


def test_control_cast_offset_zero_unchanged() raises:
    """CONTROL, green BEFORE and AFTER: at offset 0 with a bitmap whose length
    is the row count, the offset-aware reader must produce the offset-0 bytes exactly. This is
    the shape every production caller has today."""
    var raw: List[Int64] = [10, 20, 30, 40]
    var nulls: List[Int] = [1]
    var got = int64_to_float64(_sliced_i64(raw, nulls, 0, 4))
    _null_cell(got, 0, False, "offset-0 control")
    _null_cell(got, 1, True, "offset-0 control")
    _null_cell(got, 2, False, "offset-0 control")
    _null_cell(got, 3, False, "offset-0 control")
    assert_equal(got.null_count, 1, "offset-0 control: null_count")


def test_control_cast_offset_no_bitmap_stays_non_nullable() raises:
    """CONTROL, green BEFORE and AFTER: a sliced NON-nullable source must not
    start allocating a bitmap. The fast path is the hot path."""
    var raw: List[Int64] = [1, 2, 3, 4, 5]
    var got = int64_to_float64(_sliced_i64_no_validity(raw, 2, 3))
    assert_false(
        Bool(got.validity), "non-nullable cast must not allocate a bitmap"
    )
    assert_equal(got.null_count, 0, "non-nullable cast: null_count")
    assert_equal(Int(got.get(0)), 3, "non-nullable cast: data is still rebased")
    assert_equal(Int(got.get(2)), 5, "non-nullable cast: data is still rebased")


def test_cast_data_and_validity_planes_agree() raises:
    """★ THE INVARIANT THIS FILE IS ABOUT, asserted as one loop: for
    every logical row, the cast result's NULL-ness must equal the source's
    NULL-ness, and its VALUE must equal the source's value. Asserting only one
    plane would miss half of this defect — the data plane was never wrong."""
    var raw: List[Int64] = [90, 91, 100, 5, 200, 92]
    var nulls: List[Int] = [0, 3, 5]
    var src = _sliced_i64(raw, nulls, 2, 4)
    var got = int64_to_float64(src)
    for i in range(4):
        _null_cell(got, i, src.is_null(i), "plane agreement")
        if not src.is_null(i):
            assert_equal(
                Int(got.get(i)),
                Int(src.get(i)),
                "plane agreement row " + String(i) + ": value",
            )


def test_clone_array_validity_seam_directly() raises:
    """The seam itself, one layer under `int64_to_float64`, so a future cast
    that calls it directly is covered by name."""
    var raw: List[Int64] = [7, 7, 100, 5, 200]
    var nulls: List[Int] = [0, 3]
    var src = _sliced_i64(raw, nulls, 2, 3)
    var dst = PrimitiveArray[DType.int64].allocate(3)
    clone_array_validity[DType.int64, DType.int64](src, dst)
    _null_cell_i64(dst, 0, False, "clone seam")
    _null_cell_i64(dst, 1, True, "clone seam")
    _null_cell_i64(dst, 2, False, "clone seam")
    assert_equal(dst.null_count, 1, "clone seam: null_count")


# =============================================================================
# ★ SEAM 2 — the ARITHMETIC path (`merge_binary_arith_validity`)
# =============================================================================


def test_arith_offset_both_operands_nullable() raises:
    """★ Both operands sliced and nullable, nulls on DIFFERENT sides at
    DIFFERENT rows, and one null OUTSIDE each window.

    left  abs nulls {0, 3} -> window(2,3) logical NULL at row 1
    right abs nulls {4}    -> window(2,3) logical NULL at row 2
    result must be NULL at rows 1 and 2, VALID at row 0.

    OFFSET-BLIND: `bitmap_and` ANDs the two WHOLE bitmaps from bit 0 — {0,3} AND
    {4} over five bits — so row 0 comes back NULL (invented, from left's
    absolute row 0) and row 2 comes back VALID (lost, because right's null bit
    sits past the window)."""
    var lraw: List[Int64] = [9, 9, 10, 20, 30]
    var lnull: List[Int] = [0, 3]
    var rraw: List[Int64] = [9, 9, 1, 2, 3]
    var rnull: List[Int] = [4]
    var lcol = _sliced_col(lraw, lnull, 2, 3)
    var rcol = _sliced_col(rraw, rnull, 2, 3)
    var sums: List[Int64] = [11, 22, 33]
    var result = _alloc_i64(sums)
    merge_binary_arith_validity[DType.int64](lcol, rcol, result)
    _null_cell_i64(result, 0, False, "arith both-nullable")
    _null_cell_i64(result, 1, True, "arith both-nullable")
    _null_cell_i64(result, 2, True, "arith both-nullable")
    assert_equal(result.null_count, 2, "arith both-nullable: null_count")
    assert_equal(
        result.validity.value().length,
        3,
        "arith: the merged bitmap is the WINDOW, not the whole source",
    )


def test_arith_offset_left_only_nullable() raises:
    """One property varied: only the LEFT operand carries a bitmap — the
    `copy_slice_from(bm, 0, bm.length)` arm. Null at absolute 4 => logical
    row 2; a decoy null-free right operand must not rescue it."""
    var lraw: List[Int64] = [9, 9, 10, 20, 30]
    var lnull: List[Int] = [0, 4]
    var rraw: List[Int64] = [9, 9, 1, 2, 3]
    var lcol = _sliced_col(lraw, lnull, 2, 3)
    var rcol = Column.from_primitive[DType.int64](
        _sliced_i64_no_validity(rraw, 2, 3)
    )
    var sums: List[Int64] = [11, 22, 33]
    var result = _alloc_i64(sums)
    merge_binary_arith_validity[DType.int64](lcol, rcol, result)
    _null_cell_i64(result, 0, False, "arith left-only")
    _null_cell_i64(result, 1, False, "arith left-only")
    _null_cell_i64(result, 2, True, "arith left-only")
    assert_equal(result.null_count, 1, "arith left-only: null_count")


def test_arith_offset_right_only_nullable() raises:
    """The mirror arm — the two are separate code paths in the helper, so
    each is covered on its own."""
    var lraw: List[Int64] = [9, 9, 10, 20, 30]
    var rraw: List[Int64] = [9, 9, 1, 2, 3]
    var rnull: List[Int] = [0, 2]
    var lcol = Column.from_primitive[DType.int64](
        _sliced_i64_no_validity(lraw, 2, 3)
    )
    var rcol = _sliced_col(rraw, rnull, 2, 3)
    var sums: List[Int64] = [11, 22, 33]
    var result = _alloc_i64(sums)
    merge_binary_arith_validity[DType.int64](lcol, rcol, result)
    _null_cell_i64(result, 0, True, "arith right-only")
    _null_cell_i64(result, 1, False, "arith right-only")
    _null_cell_i64(result, 2, False, "arith right-only")
    assert_equal(result.null_count, 1, "arith right-only: null_count")


def test_arith_offsets_that_differ_between_operands() raises:
    """The operands need not share an offset — columns can be sliced from
    different sources. A fix that rebases by ONE offset, or that assumes the
    two are equal, is RED here. Left offset 3, right offset 6: a 3-bit
    relative shift."""
    var lraw: List[Int64] = [0, 0, 0, 10, 20, 30]
    var lnull: List[Int] = [0, 4]
    var rraw: List[Int64] = [0, 0, 0, 0, 0, 0, 1, 2, 3]
    var rnull: List[Int] = [8]
    var lcol = _sliced_col(lraw, lnull, 3, 3)
    var rcol = _sliced_col(rraw, rnull, 6, 3)
    var sums: List[Int64] = [11, 22, 33]
    var result = _alloc_i64(sums)
    merge_binary_arith_validity[DType.int64](lcol, rcol, result)
    _null_cell_i64(result, 0, False, "arith differing offsets")
    _null_cell_i64(result, 1, True, "arith differing offsets")
    _null_cell_i64(result, 2, True, "arith differing offsets")
    assert_equal(result.null_count, 2, "arith differing offsets: null_count")


def test_control_arith_offset_zero_unchanged() raises:
    """CONTROL, green BEFORE and AFTER — the shape every production caller has
    today must be bit-identical across the fix."""
    var lraw: List[Int64] = [10, 20, 30]
    var lnull: List[Int] = [0]
    var rraw: List[Int64] = [1, 2, 3]
    var rnull: List[Int] = [2]
    var lcol = _sliced_col(lraw, lnull, 0, 3)
    var rcol = _sliced_col(rraw, rnull, 0, 3)
    var sums: List[Int64] = [11, 22, 33]
    var result = _alloc_i64(sums)
    merge_binary_arith_validity[DType.int64](lcol, rcol, result)
    _null_cell_i64(result, 0, True, "arith offset-0 control")
    _null_cell_i64(result, 1, False, "arith offset-0 control")
    _null_cell_i64(result, 2, True, "arith offset-0 control")
    assert_equal(result.null_count, 2, "arith offset-0 control: null_count")


def test_control_arith_no_bitmap_stays_non_nullable() raises:
    """CONTROL, green BEFORE and AFTER: neither operand nullable => the helper
    must return without allocating anything. This is the documented hot-path
    no-op and the fix must not disturb it."""
    var lraw: List[Int64] = [10, 20, 30, 40, 50]
    var rraw: List[Int64] = [1, 2, 3, 4, 5]
    var lcol = Column.from_primitive[DType.int64](
        _sliced_i64_no_validity(lraw, 2, 3)
    )
    var rcol = Column.from_primitive[DType.int64](
        _sliced_i64_no_validity(rraw, 2, 3)
    )
    var sums: List[Int64] = [11, 22, 33]
    var result = _alloc_i64(sums)
    merge_binary_arith_validity[DType.int64](lcol, rcol, result)
    assert_false(
        Bool(result.validity), "no-bitmap arith must not allocate a bitmap"
    )
    assert_equal(result.null_count, 0, "no-bitmap arith: null_count")


# =============================================================================
# ★ SEAM 3 — `scalar_math._propagate_binary_validity`
# =============================================================================
#
# This reader does not match the `copy_slice_from(bm, 0, bm.length)` shape:
# its both-nullable arm is `left.validity.value().and_(
# right.validity.value())` — a different spelling of the same offset-blind,
# whole-bitmap merge. Its one-sided arms call `clone_array_validity`, so they
# are covered by seam 1; only the both-nullable arm needs its own case.
# `eval_math_unary` goes through `clone_array_validity` only;
# `eval_math_binary` does not.


def _f64_sliced(
    raw_all: List[Float64], null_abs: List[Int], offset: Int, length: Int
) raises -> PrimitiveArray[DType.float64]:
    var total = len(raw_all)
    comptime elem = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(total, 1) * elem)
    for i in range(total):
        buf.set_typed[Scalar[DType.float64]](i, Scalar[DType.float64](raw_all[i]))
    buf.set_length(Int64(total * elem))
    var validity = Bitmap.create_all_valid(total)
    for k in range(len(null_abs)):
        validity.clear(null_abs[k])
    return PrimitiveArray[DType.float64](
        buf^,
        length,
        Optional[Bitmap[HeapRegion]](validity^),
        _win_nulls(null_abs, offset, length),
        offset,
    )


def test_math_binary_offset_both_operands_nullable() raises:
    """★ `eval_math_binary` (atan2) over two sliced nullable operands.

    left  abs nulls {0, 3} -> logical NULL at row 1
    right abs nulls {4}    -> logical NULL at row 2

    OFFSET-BLIND: `Bitmap.and_` walks both WHOLE bitmaps from bit 0, so row 0 comes
    back NULL (invented, from left's absolute row 0) and row 2 comes back VALID
    (lost, because right's null bit sits past the window)."""
    var lraw: List[Float64] = [9.0, 9.0, 1.0, 2.0, 3.0]
    var lnull: List[Int] = [0, 3]
    var rraw: List[Float64] = [9.0, 9.0, 1.0, 1.0, 1.0]
    var rnull: List[Int] = [4]
    var got = eval_math_binary(
        KMATH2_ATAN2,
        _f64_sliced(lraw, lnull, 2, 3),
        _f64_sliced(rraw, rnull, 2, 3),
    )
    assert_equal(got.length, 3, "math binary sliced: length")
    _null_cell(got, 0, False, "math binary sliced")
    _null_cell(got, 1, True, "math binary sliced")
    _null_cell(got, 2, True, "math binary sliced")
    assert_equal(got.null_count, 2, "math binary sliced: null_count")
    assert_equal(
        got.validity.value().length,
        3,
        "math binary: the merged bitmap is the WINDOW, not the whole source",
    )


def test_math_unary_offset_carried_by_the_cast_fix() raises:
    """`eval_math_unary` reaches validity ONLY through `clone_array_validity`,
    so it is fixed by seam 1 with no edit of its own. Asserted rather than
    assumed — 'it shares the helper' is exactly the reasoning that would have
    missed `eval_math_binary`'s second arm."""
    var raw: List[Float64] = [9.0, 9.0, 0.25, 4.0, 9.0]
    var nulls: List[Int] = [0, 3]
    var got = eval_math_unary(KMATH_SQRT, _f64_sliced(raw, nulls, 2, 3))
    assert_equal(got.length, 3, "math unary sliced: length")
    _null_cell(got, 0, False, "math unary sliced")
    _null_cell(got, 1, True, "math unary sliced")
    _null_cell(got, 2, False, "math unary sliced")
    assert_equal(got.null_count, 1, "math unary sliced: null_count")
    assert_equal(Int(got.get(0)), 0, "sqrt(0.25) == 0.5 truncates to 0")
    assert_equal(Int(got.get(2)), 3, "sqrt(9.0) == 3.0 — data still rebased")


def test_control_math_binary_offset_zero_unchanged() raises:
    """CONTROL, green BEFORE and AFTER."""
    var lraw: List[Float64] = [1.0, 2.0, 3.0]
    var lnull: List[Int] = [0]
    var rraw: List[Float64] = [1.0, 1.0, 1.0]
    var rnull: List[Int] = [2]
    var got = eval_math_binary(
        KMATH2_ATAN2,
        _f64_sliced(lraw, lnull, 0, 3),
        _f64_sliced(rraw, rnull, 0, 3),
    )
    _null_cell(got, 0, True, "math binary offset-0 control")
    _null_cell(got, 1, False, "math binary offset-0 control")
    _null_cell(got, 2, True, "math binary offset-0 control")
    assert_equal(got.null_count, 2, "math binary offset-0 control: null_count")


# =============================================================================
# ★ THE PRODUCTION GATES — pinned, so the day one stops holding is a RED test
# rather than a wrong query answer
# =============================================================================


def test_control_gate_morsel_split_refuses_nullable_zero_copy() raises:
    """CONTROL, green BEFORE and AFTER. `_split_batch_into_morsels` gates its
    zero-copy `Column.slice` on `supports_zero_copy_slice() and not _validity`.
    This pins BOTH halves of that gate on the same column: the layout is
    zero-copy-capable (so the gate's decision turns on nullability alone), and
    a nullable slice really does carry `_offset > 0` with a WHOLE-column
    bitmap — which is what makes the offset-blind readers wrong when they see
    one."""
    var raw: List[Int64] = [9, 9, 100, 5, 200]
    var nulls: List[Int] = [0, 3]
    var col = _sliced_col(raw, nulls, 0, 5)
    assert_true(
        col.supports_zero_copy_slice(),
        "INT64 is on the zero-copy whitelist, so the morsel gate turns on"
        " nullability alone",
    )
    assert_true(Bool(col._validity), "fixture column is nullable")
    var sliced = col.slice(2, 3)
    assert_equal(sliced._offset, 2, "Column.slice carries an absolute offset")
    assert_equal(
        sliced._validity.value().length,
        5,
        "Column.slice SHARES the whole-column bitmap — it does not rebase",
    )
    assert_equal(sliced._null_count, 1, "Column.slice recomputes the WINDOW count")


def test_control_gate_as_primitive_rebases_nullable() raises:
    """CONTROL, green BEFORE and AFTER — the other closed path from a query to
    these seams. `Column.as_primitive`'s nullable arm copies and rebases BOTH
    planes, so a seam downstream of it sees `offset == 0` no matter what it
    was sliced from."""
    var raw: List[Int64] = [9, 9, 100, 5, 200]
    var nulls: List[Int] = [0, 3]
    var sliced = _sliced_col(raw, nulls, 0, 5).slice(2, 3)
    var arr = sliced.as_primitive[DType.int64]()
    assert_equal(arr.offset, 0, "as_primitive rebases the value window")
    assert_equal(
        arr.validity.value().length, 3, "as_primitive rebases the bitmap"
    )
    assert_false(arr.is_null(0), "rebased row 0 (abs 2) is valid")
    assert_true(arr.is_null(1), "rebased row 1 (abs 3) is the NULL row")
    assert_false(arr.is_null(2), "rebased row 2 (abs 4) is valid")


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
