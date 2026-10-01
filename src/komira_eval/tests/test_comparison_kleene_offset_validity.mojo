# =============================================================================
# test_comparison_kleene_offset_validity — the ONE kleene mechanism is
# OFFSET-BLIND, and a sliced operand both INVENTS rows and LOSES them
# =============================================================================
#
# WHY A ROUTE-LEVEL TEST CANNOT SEE THIS: every route from `_eval_predicate`
# into the seam goes through `Column.as_primitive`, whose copy path REBASES
# both halves — the value window to `offset == 0` and the validity bitmap from
# `_offset` to bit 0 (`column.mojo`, "Rebase the validity bitmap to the
# window"). So a test driving `StreamingFilterOp` -> `_eval_predicate` on a
# sliced column drives a route that normalises the very property under test.
# This file tests the SEAM directly.
#
# THE HAZARD. `PrimitiveArray` is offset-aware in its DATA accessors
# (`load[W](i)` reads element `offset + i`) and its per-row validity accessor
# (`is_null(i)` tests bit `offset + i`). A `merge_cmp_validity` that read
# `arr.validity` byte-by-byte FROM BIT 0 and never saw `arr.offset` would
# rebase the comparison DATA but not its VALIDITY, misaligning the two planes
# by exactly `offset` bits. For offset-2 views of length-5 buffers, `a > b`
# where logical `a = [NULL(100), 5, 200]` and `b = [1, 50, 1]`:
#
#     row 0 (the UNKNOWN row)       -> data=1, null=False  => SELECTED as TRUE
#     row 2 (genuinely TRUE, 200>1) -> data=0, null=True   => DROPPED as UNKNOWN
#
# Wrong in BOTH directions in a single call: a row that logically does not
# exist is returned, and a row that logically does is not.
#
# REACHABILITY. This is not reachable from `_eval_predicate` — `as_primitive`'s
# rebase stands in the way, and that is pinned below so the day it stops
# standing there is a RED test rather than a wrong answer. But
# `merge_cmp_validity` / `kleene_cmp_finalize{,_scalar}` /
# `eval_col_*_nullable` are the PUBLIC "ONE canonical mechanism" that other
# binders may bind straight onto, and `column.mojo` cites offset-blindness as
# the reason `COL_VIEW_ELIM_ENABLED` and `can_share_as_primitive` must refuse a
# NULLABLE column.
#
# Controls, each labelled and deliberate:
#   * `test_control_offset_zero_is_unchanged`               — the offset-0 CONTROL
#   * `test_control_offset_with_no_validity_bitmap...`      — the no-bitmap CONTROL
#   * `test_control_production_route_rebases_before_the_seam` — the route pin
#   * `test_offset_single_row_slice_valid`                  — right BY ACCIDENT
#   * `test_offset_empty_slice`                             — vacuous at length 0
# `test_offset_scalar_finalize_seam` and
# `test_merge_cmp_validity_offset_bits_directly` exercise the offset parameter
# of the seam directly.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, SchemaBuilder
from komira_core.io.heap_region import HeapRegion

from komira_eval.comparison_kleene import (
    NullPolicy,
    merge_cmp_validity,
    kleene_cmp_finalize,
    kleene_cmp_finalize_scalar,
    eval_col_gt_nullable,
    eval_col_lt_nullable,
    eval_col_eq_nullable,
    eval_col_ne_nullable,
    eval_col_le_nullable,
    eval_col_ge_nullable,
)


# ---------------------------------------------------------------------------
# Fixtures — the value sitting in a NULL slot is CHOSEN, so a failure is
# deterministic rather than allocator-dependent.
# ---------------------------------------------------------------------------


def _offset_i64(
    raw_all: List[Int64], null_abs: List[Int], offset: Int, length: Int
) raises -> PrimitiveArray[DType.int64]:
    """A SLICED INT64 array, exactly the shape `PrimitiveArray.slice` /
    `Column.slice` produce: data buffer AND validity bitmap indexed
    ABSOLUTELY over `len(raw_all)` elements, logical row i == absolute
    row `offset + i`."""
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
        buf^, length, Optional[Bitmap[HeapRegion]](validity^),
        len(null_abs), offset,
    )


def _offset_i64_no_validity(
    raw_all: List[Int64], offset: Int, length: Int
) raises -> PrimitiveArray[DType.int64]:
    """The same shape with NO validity bitmap — the `merge_cmp_validity` fast
    path, which must stay allocation-free and answer-identical."""
    var total = len(raw_all)
    comptime elem = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(total, 1) * elem)
    for i in range(total):
        buf.set_typed[Scalar[DType.int64]](i, Scalar[DType.int64](raw_all[i]))
    buf.set_length(Int64(total * elem))
    return PrimitiveArray[DType.int64](
        buf^, length, Optional[Bitmap[HeapRegion]](None), 0, offset,
    )


def _cell(
    got: BooleanArray, i: Int, want_data: Bool, want_null: Bool, label: String
) raises:
    """Assert BOTH planes of one result row — the data bit AND the validity
    bit. Asserting only the survivor set would miss half of this defect: the
    invented row and the lost row are each visible in only one plane."""
    if want_data:
        assert_true(got.get(i), label + " row " + String(i) + ": data must be 1")
    else:
        assert_false(got.get(i), label + " row " + String(i) + ": data must be 0")
    if want_null:
        assert_true(
            got.is_null(i), label + " row " + String(i) + ": must be UNKNOWN"
        )
    else:
        assert_false(
            got.is_null(i), label + " row " + String(i) + ": must be KNOWN"
        )


# =============================================================================
# ★ THE REVIEWER'S PROBE — wrong in BOTH directions in ONE call
# =============================================================================


def test_offset_gt_invents_a_row_and_loses_a_row() raises:
    """★ THE HEADLINE CORRECTION, as one assertion pair.

    offset-2 views of length-5 buffers. Logical `a = [NULL(100), 5, 200]`,
    `b = [1, 50, 1]`, predicate `a > b`.

      row 0: a is NULL -> UNKNOWN -> data 0, validity CLEARED
      row 1: 5 > 50    -> FALSE   -> data 0, validity SET
      row 2: 200 > 1   -> TRUE    -> data 1, validity SET

    `merge_cmp_validity` reads a's bitmap from bit 0, so it merges
    bits {0,1,2} = {valid, valid, NULL} against a DATA plane that was read at
    absolute {2,3,4}. Row 0 comes back data=1/valid (an INVENTED true) and
    row 2 comes back data=0/null (a LOST true)."""
    var raw_a: List[Int64] = [9, 9, 100, 5, 200]
    var null_a: List[Int] = [2]
    var raw_b: List[Int64] = [9, 9, 1, 50, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    assert_equal(len(got), 3, "sliced a > b: length")
    _cell(got, 0, False, True, "sliced a > b")
    _cell(got, 1, False, False, "sliced a > b")
    _cell(got, 2, True, False, "sliced a > b")
    assert_equal(got.null_count, 1, "sliced a > b: null_count")


def test_offset_gt_null_on_the_right_operand() raises:
    """The same probe with the NULL on the RIGHT — `merge_cmp_validity` reads
    the two operands through the same offset-blind path, so both sides need
    their own falsifier (an offset threaded on one side only would pass this
    file's left-null case and fail here).

    Logical `a = [10, 20, 30]` all-valid, `b = [NULL(1), 1, 1]`, `a > b`."""
    var raw_a: List[Int64] = [9, 9, 10, 20, 30]
    var null_a: List[Int] = []
    var raw_b: List[Int64] = [9, 9, 1, 1, 1]
    var null_b: List[Int] = [2]
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(got, 0, False, True, "sliced right-null a > b")
    _cell(got, 1, True, False, "sliced right-null a > b")
    _cell(got, 2, True, False, "sliced right-null a > b")
    assert_equal(got.null_count, 1, "sliced right-null: null_count")


def test_offset_nulls_on_both_operands_at_different_rows() raises:
    """Nulls on BOTH sides, at DIFFERENT logical rows — the merge is an AND,
    so a single-sided fix would still leave one row wrong.

    `a = [NULL(100), 5, 200]`, `b = [1, NULL(1), 1]`, `a > b`:
    rows 0 and 1 UNKNOWN, row 2 TRUE."""
    var raw_a: List[Int64] = [9, 9, 100, 5, 200]
    var null_a: List[Int] = [2]
    var raw_b: List[Int64] = [9, 9, 1, 1, 1]
    var null_b: List[Int] = [3]
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(got, 0, False, True, "both-null")
    _cell(got, 1, False, True, "both-null")
    _cell(got, 2, True, False, "both-null")
    assert_equal(got.null_count, 2, "both-null: null_count")


# =============================================================================
# VARY ONE PROPERTY AT A TIME OFF THE DEFECT
# =============================================================================


def test_offset_differs_between_the_two_operands() raises:
    """The two operands need not share an offset — a batch can hold columns
    sliced from different sources. Left offset 3, right offset 6: the relative
    shift is 3 bits, so a byte-wise merge cannot be right for both sides even
    after one of them is rebased.

    `a = [NULL(7), 5, 200]` (abs 3..5, null at abs 3),
    `b = [1, 50, 1]` (abs 6..8), `a > b`."""
    var raw_a: List[Int64] = [0, 0, 0, 7, 5, 200, 0, 0, 0]
    var null_a: List[Int] = [3]
    var raw_b: List[Int64] = [0, 0, 0, 0, 0, 0, 1, 50, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 3, 3), _offset_i64(raw_b, null_b, 6, 3)
    )
    _cell(got, 0, False, True, "mismatched offsets")
    _cell(got, 1, False, False, "mismatched offsets")
    _cell(got, 2, True, False, "mismatched offsets")


def test_offset_window_crosses_a_byte_boundary() raises:
    """Offset 6, length 5 — the logical window spans validity bytes 0 and 1,
    so the merged byte must be assembled from TWO source bytes. A fix that
    only shifts within one byte passes the offset-2 case and fails here.

    `a = [NULL(1), 2, 3, NULL(4), 5]` (abs 6..10, nulls at abs 6 and 9),
    `b = [0, 0, 0, 0, 0]`, `a > b`: rows 0 and 3 UNKNOWN, rows 1/2/4 TRUE."""
    var raw_a: List[Int64] = [0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5]
    var null_a: List[Int] = [6, 9]
    var raw_b: List[Int64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 6, 5), _offset_i64(raw_b, null_b, 6, 5)
    )
    assert_equal(len(got), 5, "byte-crossing: length")
    _cell(got, 0, False, True, "byte-crossing")
    _cell(got, 1, True, False, "byte-crossing")
    _cell(got, 2, True, False, "byte-crossing")
    _cell(got, 3, False, True, "byte-crossing")
    _cell(got, 4, True, False, "byte-crossing")
    assert_equal(got.null_count, 2, "byte-crossing: null_count")


def test_offset_beyond_one_byte() raises:
    """Offset 9 — past the first validity byte entirely, and not byte-aligned.
    Distinguishes "the fix masks the low byte" from "the fix indexes bits".

    `a = [NULL(100), 5, 200]` (abs 9..11, null at abs 9), `b = [1, 50, 1]`."""
    var raw_a: List[Int64] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 5, 200
    ]
    var null_a: List[Int] = [9]
    var raw_b: List[Int64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 50, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 9, 3), _offset_i64(raw_b, null_b, 9, 3)
    )
    _cell(got, 0, False, True, "offset 9")
    _cell(got, 1, False, False, "offset 9")
    _cell(got, 2, True, False, "offset 9")


def test_offset_byte_aligned_eight() raises:
    """Offset 8 — byte-ALIGNED but non-zero. The aligned case is its own arm
    in every bit-copy primitive in this repo, so it gets its own falsifier."""
    var raw_a: List[Int64] = [0, 0, 0, 0, 0, 0, 0, 0, 100, 5, 200]
    var null_a: List[Int] = [8]
    var raw_b: List[Int64] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 50, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 8, 3), _offset_i64(raw_b, null_b, 8, 3)
    )
    _cell(got, 0, False, True, "offset 8")
    _cell(got, 1, False, False, "offset 8")
    _cell(got, 2, True, False, "offset 8")


def test_offset_all_null_slice() raises:
    """The ALL-NULL slice: every logical row UNKNOWN, so NO row survives and
    every data bit is 0. Pre-fix the misaligned merge marks the first rows
    VALID and hands back their raw compare bits."""
    var raw_a: List[Int64] = [9, 9, 100, 200, 300]
    var null_a: List[Int] = [2, 3, 4]
    var raw_b: List[Int64] = [9, 9, 1, 1, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(got, 0, False, True, "all-null slice")
    _cell(got, 1, False, True, "all-null slice")
    _cell(got, 2, False, True, "all-null slice")
    assert_equal(got.null_count, 3, "all-null slice: null_count")


def test_offset_single_row_slice_null() raises:
    """Length 1 at offset 3, the single row NULL. The smallest window there
    is — no full byte to copy, all tail."""
    var raw_a: List[Int64] = [9, 9, 9, 100, 9]
    var null_a: List[Int] = [3]
    var raw_b: List[Int64] = [9, 9, 9, 1, 9]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 3, 1), _offset_i64(raw_b, null_b, 3, 1)
    )
    assert_equal(len(got), 1, "single-row slice: length")
    _cell(got, 0, False, True, "single-row null slice")
    assert_equal(got.null_count, 1, "single-row slice: null_count")


def test_offset_single_row_slice_valid() raises:
    """The INVERSE of the case above — the one row VALID and TRUE. GREEN
    PRE-FIX, BY ACCIDENT: this fixture's only NULL sits at absolute row 4, and
    the offset-blind read looked at bit 0, which happens to be valid. That is
    exactly the shape a per-case fix would have declared "already correct".
    Guards the
    fix against over-nulling (a rebase that reads one bit too far would clear
    a valid row here and go unnoticed by the null-row cases)."""
    var raw_a: List[Int64] = [9, 9, 9, 100, 9]
    var null_a: List[Int] = [4]
    var raw_b: List[Int64] = [9, 9, 9, 1, 9]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 3, 1), _offset_i64(raw_b, null_b, 3, 1)
    )
    _cell(got, 0, True, False, "single-row valid slice")
    assert_equal(got.null_count, 0, "single-row valid slice: null_count")


def test_offset_empty_slice() raises:
    """Length 0 at offset 2 — no rows, no crash, no bogus null_count.

    GREEN PRE-FIX, vacuously: there is no row to be wrong about. Kept because
    the fix shifts bits, and an off-by-one in the shift is most likely to show
    up first as a crash on a zero-length window."""
    var raw_a: List[Int64] = [9, 9, 100, 5, 200]
    var null_a: List[Int] = [2]
    var raw_b: List[Int64] = [9, 9, 1, 50, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 0), _offset_i64(raw_b, null_b, 2, 0)
    )
    assert_equal(len(got), 0, "empty slice: length")
    assert_equal(got.null_count, 0, "empty slice: null_count")


def test_offset_all_six_ops() raises:
    """All SIX ops, not just `>`. They are six separate entry points into the
    same finalize, and a per-op fix is exactly the arm-by-arm mistake to
    avoid.

    Logical `a = [NULL(100), 5, 200]`, `b = [1, 50, 200]`. Row 0 is UNKNOWN
    under every op; the other two rows differ per op."""
    var raw_a: List[Int64] = [9, 9, 100, 5, 200]
    var null_a: List[Int] = [2]
    var raw_b: List[Int64] = [9, 9, 1, 50, 200]
    var null_b: List[Int] = []

    var gt = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(gt, 0, False, True, "six-ops gt")
    _cell(gt, 1, False, False, "six-ops gt")   # 5 > 50
    _cell(gt, 2, False, False, "six-ops gt")   # 200 > 200

    var lt = eval_col_lt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(lt, 0, False, True, "six-ops lt")
    _cell(lt, 1, True, False, "six-ops lt")    # 5 < 50
    _cell(lt, 2, False, False, "six-ops lt")   # 200 < 200

    var eq = eval_col_eq_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(eq, 0, False, True, "six-ops eq")
    _cell(eq, 1, False, False, "six-ops eq")
    _cell(eq, 2, True, False, "six-ops eq")    # 200 == 200

    var ne = eval_col_ne_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(ne, 0, False, True, "six-ops ne")
    _cell(ne, 1, True, False, "six-ops ne")
    _cell(ne, 2, False, False, "six-ops ne")

    var le = eval_col_le_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(le, 0, False, True, "six-ops le")
    _cell(le, 1, True, False, "six-ops le")
    _cell(le, 2, True, False, "six-ops le")

    var ge = eval_col_ge_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64(raw_b, null_b, 2, 3)
    )
    _cell(ge, 0, False, True, "six-ops ge")
    _cell(ge, 1, False, False, "six-ops ge")
    _cell(ge, 2, True, False, "six-ops ge")


def test_offset_scalar_finalize_seam() raises:
    """`kleene_cmp_finalize_scalar` — the col-vs-LITERAL half of the same
    mechanism, reached from six arms of `_eval_predicate`. It merges ONE
    operand's validity, so it loses the offset the same way.

    Result data staged on all lanes as [1, 0, 1] (what a scalar compare of
    logical [NULL(100), 5, 200] against `> 50` produces), operand validity
    cleared at ABSOLUTE bit 2 with offset 2 -> logical row 0 UNKNOWN."""
    var raw: List[Int64] = [9, 9, 100, 5, 200]
    var nulls: List[Int] = [2]
    var arr = _offset_i64(raw, nulls, 2, 3)
    var staged = BooleanArray.allocate(3)
    staged.set(0, True)
    staged.set(1, False)
    staged.set(2, True)
    var got = kleene_cmp_finalize_scalar(
        staged^, arr.validity, NullPolicy.three_valued(), arr.offset
    )
    _cell(got, 0, False, True, "scalar finalize sliced")
    _cell(got, 1, False, False, "scalar finalize sliced")
    _cell(got, 2, True, False, "scalar finalize sliced")


def test_merge_cmp_validity_offset_bits_directly() raises:
    """The mechanism itself, with no kernel in front of it. Left validity
    `[1,1,0,1,1]` read at offset 2 must yield merged `[0,1,1]`."""
    var bm = Bitmap.create_all_valid(5)
    bm.clear(2)
    var left = Optional[Bitmap[HeapRegion]](bm^)
    var right = Optional[Bitmap[HeapRegion]](None)
    var merged = merge_cmp_validity(
        left, right, 3, NullPolicy.three_valued(), 2, 0
    )
    assert_true(Bool(merged), "merged validity must be present")
    ref mv = merged.value()
    assert_false(mv.test(0), "merged bit 0 (abs 2) must be NULL")
    assert_true(mv.test(1), "merged bit 1 (abs 3) must be VALID")
    assert_true(mv.test(2), "merged bit 2 (abs 4) must be VALID")
    assert_equal(mv.null_count(), 1, "merged null_count")


# =============================================================================
# CONTROLS — green BEFORE and AFTER. Without them the failures above are not
# attributable to the offset.
# =============================================================================


def test_control_offset_zero_is_unchanged() raises:
    """Offset 0, same fixture values. This is the shape every production
    caller hands the seam today, and it must be byte-identical across the
    fix — the falsifier has to indict the OFFSET, not the 3VL rule."""
    var raw_a: List[Int64] = [100, 5, 200]
    var null_a: List[Int] = [0]
    var raw_b: List[Int64] = [1, 50, 1]
    var null_b: List[Int] = []
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 0, 3), _offset_i64(raw_b, null_b, 0, 3)
    )
    _cell(got, 0, False, True, "offset-0 control")
    _cell(got, 1, False, False, "offset-0 control")
    _cell(got, 2, True, False, "offset-0 control")
    assert_equal(got.null_count, 1, "offset-0 control: null_count")


def test_control_offset_with_no_validity_bitmap_stays_non_nullable() raises:
    """A sliced operand with NO bitmap: `merge_cmp_validity`'s both-absent
    fast path returns None and the result must stay NON-nullable, with the
    data read at the offset. The fix must not make this allocate a bitmap."""
    var raw_a: List[Int64] = [9, 9, 100, 5, 200]
    var raw_b: List[Int64] = [9, 9, 1, 50, 1]
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64_no_validity(raw_a, 2, 3),
        _offset_i64_no_validity(raw_b, 2, 3),
    )
    assert_false(Bool(got.validity), "no-bitmap operands: result non-nullable")
    assert_equal(got.null_count, 0, "no-bitmap operands: null_count")
    _cell(got, 0, True, False, "no-bitmap sliced")   # 100 > 1
    _cell(got, 1, False, False, "no-bitmap sliced")  # 5 > 50
    _cell(got, 2, True, False, "no-bitmap sliced")   # 200 > 1


def test_control_one_sided_bitmap_with_offset() raises:
    """Left nullable + sliced, right non-nullable + sliced. Exercises the
    `_validity_byte` absent-operand arm (0xFF) alongside a real offset."""
    var raw_a: List[Int64] = [9, 9, 100, 5, 200]
    var null_a: List[Int] = [2]
    var raw_b: List[Int64] = [9, 9, 1, 50, 1]
    var got = eval_col_gt_nullable[DType.int64](
        _offset_i64(raw_a, null_a, 2, 3), _offset_i64_no_validity(raw_b, 2, 3)
    )
    _cell(got, 0, False, True, "one-sided bitmap sliced")
    _cell(got, 1, False, False, "one-sided bitmap sliced")
    _cell(got, 2, True, False, "one-sided bitmap sliced")


def test_control_production_route_rebases_before_the_seam() raises:
    """★ WHY A ROUTE-LEVEL TEST PASSES REGARDLESS — pinned, so that the day
    `Column.as_primitive` stops rebasing is a RED test rather than a wrong
    query answer.

    A nullable `Column.slice` carries `_offset > 0` and SHARES the whole-column
    validity bitmap (`column.mojo`: "VALIDITY IS OFFSET-BASED"). Reading it back
    through `as_primitive` must hand out an array whose offset is 0 and whose
    validity has been rebased to bit 0 — i.e. the seam never sees the offset on
    this route. This test asserts that normalisation directly; it is NOT
    evidence that the seam handles an offset."""
    var raw: List[Int64] = [9, 9, 100, 5, 200]
    var nulls: List[Int] = [2]
    var col = Column.from_primitive[DType.int64](_offset_i64(raw, nulls, 0, 5))
    var sliced = col.slice(2, 3)
    assert_equal(sliced._offset, 2, "Column.slice keeps an absolute offset")
    var arr = sliced.as_primitive[DType.int64]()
    assert_equal(arr.offset, 0, "as_primitive rebases the value window")
    assert_true(Bool(arr.validity), "as_primitive keeps the null mask")
    assert_true(arr.is_null(0), "rebased row 0 is the NULL row")
    assert_false(arr.is_null(1), "rebased row 1 is valid")
    assert_false(arr.is_null(2), "rebased row 2 is valid")
    assert_equal(
        Int(arr.validity.value().test(0)), 0, "validity rebased to bit 0"
    )


# =============================================================================
# Entry point
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
