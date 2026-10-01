# =============================================================================
# test_filter_null_collapse_semantics.mojo — Arrow-standard NULL → FALSE
# enforcement at the legacy production filter boundary
# =============================================================================
#
# Regression test for NULL collapsing at the filter boundary.
#
# Pre-fix behavior (BUG)
# ----------------------
# `evaluate_filter_narrowed(batch, expr)` in `conjunction.mojo` calls
# `_eval_predicate(expr, batch)`. The hot fast paths in `comparison.mojo`
# (col-vs-lit kernels `_eval_cmp_gt[dtype]` and col-vs-col kernels
# `eval_col_gt[dtype]`) execute SIMD compare-pack on RAW BYTES — they
# never look at the input column's validity bitmap. The output is a
# non-nullable `BooleanArray` whose data bit at a NULL row depends on
# whatever bytes the allocator happened to leave in that buffer slot.
#
# For a row that is logically NULL but whose underlying int64 buffer slot
# stores e.g. 50, the filter `col > 10` produces data=TRUE — the NULL row
# is INCORRECTLY INCLUDED in the output selection.
#
# Post-fix behavior (Arrow standard)
# ----------------------------------
# `evaluate_predicate_selected` walks the predicate Expr to collect
# referenced column indices, ANDs their validity bitmaps, and masks the
# predicate result's data bits with the resulting input-validity mask.
# Any row where the predicate's input column is NULL gets data=FALSE,
# i.e. the row is filtered out.
#
# Test cases below construct nullable PrimitiveArrays whose underlying
# data buffers hold predicate-passing values at the NULL positions,
# forcing the pre-fix path to misbehave deterministically.
# =============================================================================

from std.sys import size_of
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.io.heap_region import HeapRegion
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.column import Column
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_eval.selection_vector import SelectionVector

from komira_core.plan.expr import (
    Expr,
    BIN_AND,
    BIN_GT,
    BIN_LT,
    BIN_OR,
    UN_NOT,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.conjunction import evaluate_filter_narrowed


# ---------------------------------------------------------------------------
# Helpers — build PrimitiveArrays with explicit data buffer + validity
# ---------------------------------------------------------------------------


def _build_nullable_int64(
    raw_values: List[Int64],
    null_indices: List[Int],
) raises -> PrimitiveArray[DType.int64]:
    """Build a nullable PrimitiveArray[Int64] with controlled NULL rows.

    The `raw_values` list is the underlying data buffer (one Int64 per
    row). `null_indices` lists the row indices whose validity bit is
    cleared. The data buffer at those rows STILL HOLDS the value from
    `raw_values` — this is the deterministic pre-fix-failure shape: the
    fast-path comparison kernel reads the raw byte and may erroneously
    let NULL rows pass.
    """
    var length = len(raw_values)
    comptime elem_size = size_of[Scalar[DType.int64]]()
    var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
    for i in range(length):
        buf.set_typed[Scalar[DType.int64]](
            i, Scalar[DType.int64](raw_values[i])
        )
    buf.set_length(Int64(length * elem_size))


    var validity = Bitmap.create_all_valid(length)
    for k in range(len(null_indices)):
        validity.clear(null_indices[k])
    var null_count = len(null_indices)
    return PrimitiveArray[DType.int64](
        buf^, length, Optional[Bitmap[HeapRegion]](validity^), null_count, 0
    )


def _build_nullable_float64(
    raw_values: List[Float64],
    null_indices: List[Int],
) raises -> PrimitiveArray[DType.float64]:
    """Float64 sibling of `_build_nullable_int64`."""
    var length = len(raw_values)
    comptime elem_size = size_of[Scalar[DType.float64]]()
    var buf = OwnedAlignedBuffer(max(length, 1) * elem_size)
    for i in range(length):
        buf.set_typed[Scalar[DType.float64]](
            i, Scalar[DType.float64](raw_values[i])
        )
    buf.set_length(Int64(length * elem_size))


    var validity = Bitmap.create_all_valid(length)
    for k in range(len(null_indices)):
        validity.clear(null_indices[k])
    var null_count = len(null_indices)
    return PrimitiveArray[DType.float64](
        buf^, length, Optional[Bitmap[HeapRegion]](validity^), null_count, 0
    )


def _build_int64_batch_with_nulls(
    col_name: String,
    raw_values: List[Int64],
    null_indices: List[Int],
) raises -> RecordBatch:
    """Single-column Int64 RecordBatch with controlled NULLs."""
    var arr = _build_nullable_int64(raw_values, null_indices)
    var sb = SchemaBuilder()
    sb.add_field(Field(col_name, ArrowType.INT64, True))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _build_two_int64_batch_with_nulls(
    name_a: String,
    raw_a: List[Int64],
    null_a: List[Int],
    name_b: String,
    raw_b: List[Int64],
    null_b: List[Int],
) raises -> RecordBatch:
    """Two-column Int64 RecordBatch where each column has controlled NULLs."""
    var aa = _build_nullable_int64(raw_a, null_a)
    var ab = _build_nullable_int64(raw_b, null_b)
    var sb = SchemaBuilder()
    sb.add_field(Field(name_a, ArrowType.INT64, True))
    sb.add_field(Field(name_b, ArrowType.INT64, True))
    return RecordBatch.from_columns_2(sb.build(), aa^, ab^)


def _build_float64_batch_with_nulls(
    col_name: String,
    raw_values: List[Float64],
    null_indices: List[Int],
) raises -> RecordBatch:
    """Single-column Float64 RecordBatch with controlled NULLs."""
    var arr = _build_nullable_float64(raw_values, null_indices)
    var sb = SchemaBuilder()
    sb.add_field(Field(col_name, ArrowType.FLOAT64, True))
    return RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.float64](arr^)
    )


def _collect_pass_indices(sv: SelectionVector) raises -> List[Int]:
    """Extract surviving row indices from a SelectionVector."""
    var out = List[Int]()
    var ptr = sv.indices._typed_ptr_ro()
    for i in range(sv.length()):
        out.append(Int(ptr[i]))
    return out^


def _col_gt_lit_i64(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _col_lt_lit_i64(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_LT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _col_lt_lit_f64(name: String, v: Float64) -> Expr:
    return Expr.binary(
        BIN_LT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_float(v)),
    )


# ---------------------------------------------------------------------------
# Bug-Fix Protocol regression tests (must FAIL pre-fix, PASS post-fix)
# ---------------------------------------------------------------------------


def test_filter_null_collapsed_int64_gt() raises:
    """`col > 10` on nullable Int64 column drops NULL rows even when the
    underlying data buffer slot stores a predicate-passing value.

    Logical column: [NULL=50, 5, 20, NULL=50, 100]
    Filter: a > 10
    Pre-fix: row 0 and row 3 incorrectly INCLUDED (raw byte 50 > 10).
    Post-fix: rows 0 and 3 EXCLUDED — final indices [2, 4].
    """
    var raw: List[Int64] = [50, 5, 20, 50, 100]
    var nulls: List[Int] = [0, 3]
    var batch = _build_int64_batch_with_nulls(String("a"), raw, nulls)
    var expr = _col_gt_lit_i64("a", 10)

    var sv = evaluate_filter_narrowed(batch, expr)
    var pass_idx = _collect_pass_indices(sv)

    assert_equal(len(pass_idx), 2)
    assert_equal(pass_idx[0], 2)
    assert_equal(pass_idx[1], 4)


def test_filter_null_collapsed_float64_lt() raises:
    """`col < 100.0` on nullable Float64 column drops NULL rows.

    Logical column: [NULL=50.0, 5.0, 99.0, NULL=50.0, 200.0]
    Filter: a < 100.0
    Pre-fix: rows 0 and 3 incorrectly INCLUDED (raw 50.0 < 100.0).
    Post-fix: NULL rows excluded — final indices [1, 2].
    """
    var raw: List[Float64] = [50.0, 5.0, 99.0, 50.0, 200.0]
    var nulls: List[Int] = [0, 3]
    var batch = _build_float64_batch_with_nulls(String("a"), raw, nulls)
    var expr = _col_lt_lit_f64("a", 100.0)

    var sv = evaluate_filter_narrowed(batch, expr)
    var pass_idx = _collect_pass_indices(sv)

    assert_equal(len(pass_idx), 2)
    assert_equal(pass_idx[0], 1)
    assert_equal(pass_idx[1], 2)


def test_filter_null_collapsed_col_vs_col() raises:
    """`a > b` on two nullable columns drops every row where EITHER is NULL.

    Logical:
      a = [NULL=100, 1,   50, 20,    NULL=100]
      b = [10,       0,   30, NULL=5, 50]
    Filter: a > b
    Pre-fix: many NULL rows incorrectly INCLUDED (raw 100 > 10, raw 20 > 5).
    Post-fix: NULL rows dropped on either side; only rows 1 (1 > 0)
    and 2 (50 > 30) survive — final indices [1, 2].
    """
    var raw_a: List[Int64] = [100, 1, 50, 20, 100]
    var nulls_a: List[Int] = [0, 4]
    var raw_b: List[Int64] = [10, 0, 30, 5, 50]
    var nulls_b: List[Int] = [3]
    var batch = _build_two_int64_batch_with_nulls(
        String("a"), raw_a, nulls_a, String("b"), raw_b, nulls_b
    )
    var expr = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.col_ref("b"))

    var sv = evaluate_filter_narrowed(batch, expr)
    var pass_idx = _collect_pass_indices(sv)

    assert_equal(len(pass_idx), 2)
    assert_equal(pass_idx[0], 1)
    assert_equal(pass_idx[1], 2)


def test_filter_null_collapsed_conjunction() raises:
    """`a > 10 AND b < 20` drops rows where EITHER operand is NULL.

    Logical:
      a = [NULL=50, 50, 50, 5,  100]    -- nulls: [0]
      b = [10,     10, NULL=10, 10, 10]  -- nulls: [2]
    Conjunction: a > 10 AND b < 20
    Row 0: a is NULL -> drop.
    Row 1: a=50>10 (T), b=10<20 (T) -> KEEP.
    Row 2: a=50>10 (T), b is NULL -> drop.
    Row 3: a=5>10 (F) -> drop.
    Row 4: a=100>10 (T), b=10<20 (T) -> KEEP.
    Expected: [1, 4].

    Pre-fix: rows 0 and 2 incorrectly INCLUDED (raw 50>10, raw 10<20).
    """
    var raw_a: List[Int64] = [50, 50, 50, 5, 100]
    var nulls_a: List[Int] = [0]
    var raw_b: List[Int64] = [10, 10, 10, 10, 10]
    var nulls_b: List[Int] = [2]
    var batch = _build_two_int64_batch_with_nulls(
        String("a"), raw_a, nulls_a, String("b"), raw_b, nulls_b
    )
    var expr = Expr.binary(
        BIN_AND,
        _col_gt_lit_i64("a", 10),
        _col_lt_lit_i64("b", 20),
    )

    var sv = evaluate_filter_narrowed(batch, expr)
    var pass_idx = _collect_pass_indices(sv)

    assert_equal(len(pass_idx), 2)
    assert_equal(pass_idx[0], 1)
    assert_equal(pass_idx[1], 4)


def test_filter_null_collapsed_all_valid_path_unchanged() raises:
    """Sanity: when no input column has any NULL, the result is identical
    to the existing non-NULL fast path. Verifies the fix's perf-equivalent
    all-valid short-circuit.

    Logical: a = [1, 5, 10, 15, 20]; filter a > 7 -> rows 2, 3, 4.
    """
    var raw: List[Int64] = [1, 5, 10, 15, 20]
    var nulls: List[Int] = []
    var batch = _build_int64_batch_with_nulls(String("a"), raw, nulls)
    var expr = _col_gt_lit_i64("a", 7)

    var sv = evaluate_filter_narrowed(batch, expr)
    var pass_idx = _collect_pass_indices(sv)

    assert_equal(len(pass_idx), 3)
    assert_equal(pass_idx[0], 2)
    assert_equal(pass_idx[1], 3)
    assert_equal(pass_idx[2], 4)


# ---------------------------------------------------------------------------
# ⛔⛔ THE SAME COLLAPSE, ONE LAYER UP: A **DISJUNCTION**
# ---------------------------------------------------------------------------
#
# The five cases above all have ONE null scope, so one mask per predicate is
# the right shape for them and they passed through the whole defect. The
# moment a predicate has TWO arms with DIFFERENT null sensitivity, it is not:
#
#     WHERE a > 25 OR b > 1000        -- `b` NULL on rows 1 and 3
#       pre-fix -> [2, 4]     the `b`-NULL rows were masked out of an arm
#                             about `a`
#       SQL     -> [2, 3, 4]  `TRUE OR NULL` is TRUE
#
# ⭐ THESE TWO CELLS ARE AT THE SHARED FUNNEL, NOT AT THE UDF DOOR. The defect
# was REPORTED through `udf_scratch_scope` (a wide batch makes it visible on
# more shapes), but `evaluate_filter_narrowed` is where it lives and every
# caller of it is exposed — which is why the fix and its pin are both here.
#
# ⚠ THE RAW BYTES AT THE NULL SLOTS ARE STILL PREDICATE-PASSING-ADJACENT ON
# PURPOSE, exactly as in the cases above: `999` under `b > 1000` is FALSE, so
# a "collapse NULL to FALSE at the leaf" shortcut would pass the OR cell and
# fail the NOT one. Both are here for that reason.


def test_filter_disjunction_keeps_TRUE_OR_NULL_rows() raises:
    """`a > 25 OR b > 1000` keeps row 3, where `a > 25` is TRUE and `b` is NULL.

    a = [10, 20, 30, 40, 50]            (no nulls)
    b = [999, NULL=999, 999, NULL=999, 999]

    `b > 1000` is FALSE where known and UNKNOWN on rows 1/3; `a > 25` is TRUE
    on rows 2/3/4. SQL: row 1 is `FALSE OR UNKNOWN` = UNKNOWN -> dropped; row 3
    is `TRUE OR UNKNOWN` = TRUE -> kept.

    ⛔ PRE-FIX: [2, 4]. `_compute_predicate_input_validity` built ONE mask over
    `{a, b}` for the whole conjunct and `_collapse_nulls_to_false` ANDed it
    into the OR's result, so row 3 lost to a NULL in the arm it did not need.
    POST-FIX: [2, 3, 4] — `_predicate_3vl` gives each arm its own scope and
    lets the Kleene `eval_or` decide.
    """
    var raw_a: List[Int64] = [10, 20, 30, 40, 50]
    var no_nulls: List[Int] = []
    var raw_b: List[Int64] = [999, 999, 999, 999, 999]
    var nulls_b: List[Int] = [1, 3]
    var batch = _build_two_int64_batch_with_nulls(
        String("a"), raw_a, no_nulls, String("b"), raw_b, nulls_b
    )
    var expr = Expr.binary(
        BIN_OR, _col_gt_lit_i64("a", 25), _col_gt_lit_i64("b", 1000)
    )

    var pass_idx = _collect_pass_indices(evaluate_filter_narrowed(batch, expr))

    assert_equal(len(pass_idx), 3)
    assert_equal(pass_idx[0], 2)
    assert_equal(pass_idx[1], 3)
    assert_equal(pass_idx[2], 4)


def test_filter_negated_conjunction_keeps_the_FALSE_AND_NULL_rows() raises:
    """`NOT (a > 25 AND b > 1000)` keeps row 1, where the AND is a KNOWN FALSE.

    Same two columns. `FALSE AND UNKNOWN` is FALSE (not UNKNOWN), so row 1's
    negation is TRUE; row 3 is `TRUE AND UNKNOWN` = UNKNOWN, whose negation is
    UNKNOWN and is therefore dropped at the filter boundary.

    ⛔ PRE-FIX: [0, 2, 4] — row 1 was masked out by `b`'s validity even though
    the AND had already resolved it to a known FALSE. POST-FIX: [0, 1, 2, 4].

    ⭐ IT IS THE CELL THAT PINS THE `NOT` DESCENT SPECIFICALLY. Treat `NOT` as
    a leaf — i.e. hand `_eval_predicate` the whole negation and mask its result
    with the union scope, which is what the pre-fix funnel did — and row 1 goes
    missing again while the OR cell above still passes.
    """
    var raw_a: List[Int64] = [10, 20, 30, 40, 50]
    var no_nulls: List[Int] = []
    var raw_b: List[Int64] = [999, 999, 999, 999, 999]
    var nulls_b: List[Int] = [1, 3]
    var batch = _build_two_int64_batch_with_nulls(
        String("a"), raw_a, no_nulls, String("b"), raw_b, nulls_b
    )
    var expr = Expr.unary(
        UN_NOT,
        Expr.binary(
            BIN_AND, _col_gt_lit_i64("a", 25), _col_gt_lit_i64("b", 1000)
        ),
    )

    var pass_idx = _collect_pass_indices(evaluate_filter_narrowed(batch, expr))

    assert_equal(len(pass_idx), 4)
    assert_equal(pass_idx[0], 0)
    assert_equal(pass_idx[1], 1)
    assert_equal(pass_idx[2], 2)
    assert_equal(pass_idx[3], 4)



# ===========================================================================
# ⭐ THE `not l.validity` GUARD ON `_predicate_3vl`'s FOUR SHORT-CIRCUITS
# ===========================================================================
#
# ⛔ THESE TWO CELLS PIN THE `not l.validity` GUARD ON THE SHORT-CIRCUITS.
# Without them, deleting the guard from BOTH connectives leaves the rest of
# this file green.
#
# ⭐ WHY THE TWO CELLS ABOVE CANNOT COVER IT, AND IT IS ONE WORD: WHICH ARM
# CARRIES THE NULLS. `test_filter_negated_conjunction_keeps_the_FALSE_AND_NULL_
# rows` spells `NOT (a > 25 AND b > 1000)` with the NULL-FREE arm FIRST, so the
# left mask's `true_count` is 3 of 5 — neither 0 nor `length` — and NO
# short-circuit fires at all. The guard is unreachable from that shape by
# construction. These cells swap the operands and nothing else.
#
# ⚠ ONLY THE TWO `true_count == 0` ARMS ARE REACHABLE WITH UNKNOWNS PRESENT,
# and that is a property of the encoding, not an oversight: this file's own
# invariant is DATA BIT 0 at every UNKNOWN row, so a mask with one unknown row
# cannot have `true_count == length`. The `TRUE AND r` / `TRUE OR r` halves
# therefore only ever fire on a fully-known left mask, where the guard is a
# no-op. Deleting them changes no answer and no test — reported, not papered
# over with a cell that cannot fail.
#
# This file gates `komira_compiler`'s build, so a red here withholds the
# library from every consumer.
#
# ORACLE: DuckDB 1.5.3, over the same five rows, same predicates —
#   NOT (b > 1000 AND a > 25) -> [0, 1, 2, 4]      (this file's `_expected`)
#   NOT (b > 1000 OR  a > 25) -> [0]
# Never the engine's other door (`compiler_eval_predicate._eval_short_circuit_
# {and,or}`): a control must not share the mechanism under test.


def test_filter_negated_conjunction_with_the_NULL_ARM_FIRST_keeps_its_rows() raises:
    """`NOT (b > 1000 AND a > 25)` — the operands of the cell above, SWAPPED.

    b = [999, NULL=999, 999, NULL=999, 999]   a = [10, 20, 30, 40, 50]

    `b > 1000` is FALSE where known and UNKNOWN on rows 1/3, so its
    `true_count` is ZERO and `_predicate_3vl`'s `FALSE AND r = FALSE` arm is
    reachable — which it is NOT in the sibling cell, where `a > 25` leads.

    SQL (DuckDB 1.5.3): row 1 is `UNKNOWN AND FALSE` = a KNOWN FALSE, so its
    negation is TRUE; row 3 is `UNKNOWN AND TRUE` = UNKNOWN and drops.
    -> [0, 1, 2, 4].

    ⛔ WITHOUT THE `not l.validity` GUARD the short-circuit returns the LEFT
    mask itself — still UNKNOWN on rows 1/3 — and `eval_not` propagates that
    UNKNOWN, so row 1 is collapsed away: [0, 2, 4]. MEASURED, by deleting the
    guard and re-running this file.
    """
    var raw_a: List[Int64] = [10, 20, 30, 40, 50]
    var no_nulls: List[Int] = []
    var raw_b: List[Int64] = [999, 999, 999, 999, 999]
    var nulls_b: List[Int] = [1, 3]
    var batch = _build_two_int64_batch_with_nulls(
        String("a"), raw_a, no_nulls, String("b"), raw_b, nulls_b
    )
    var expr = Expr.unary(
        UN_NOT,
        Expr.binary(
            BIN_AND, _col_gt_lit_i64("b", 1000), _col_gt_lit_i64("a", 25)
        ),
    )

    var pass_idx = _collect_pass_indices(evaluate_filter_narrowed(batch, expr))

    assert_equal(len(pass_idx), 4)
    assert_equal(pass_idx[0], 0)
    assert_equal(pass_idx[1], 1)
    assert_equal(pass_idx[2], 2)
    assert_equal(pass_idx[3], 4)


def test_filter_negated_disjunction_with_the_NULL_ARM_FIRST_drops_only_UNKNOWN() raises:
    """`NOT (b > 1000 OR a > 25)` — the OR half of the same guard.

    Same two columns. `b > 1000` has `true_count` ZERO, so
    `_predicate_3vl`'s `FALSE OR r = r` arm is the reachable one.

    SQL (DuckDB 1.5.3): row 0 is `FALSE OR FALSE` = FALSE -> negation TRUE;
    row 1 is `UNKNOWN OR FALSE` = UNKNOWN -> drops; rows 2/3/4 have `a > 25`
    TRUE so the OR is TRUE and the negation FALSE. -> [0].

    ⛔ WITHOUT THE GUARD the short-circuit returns the RIGHT mask alone,
    discarding the left arm's UNKNOWNs entirely, and row 1 comes back as a
    KNOWN FALSE whose negation is TRUE: [0, 1]. This cell is the only one in
    the repo whose failure direction is a row the engine must NOT return —
    the OR guard's removal ADDS a row, where the AND guard's removal LOSES
    one, so one shape cannot cover both.
    """
    var raw_a: List[Int64] = [10, 20, 30, 40, 50]
    var no_nulls: List[Int] = []
    var raw_b: List[Int64] = [999, 999, 999, 999, 999]
    var nulls_b: List[Int] = [1, 3]
    var batch = _build_two_int64_batch_with_nulls(
        String("a"), raw_a, no_nulls, String("b"), raw_b, nulls_b
    )
    var expr = Expr.unary(
        UN_NOT,
        Expr.binary(
            BIN_OR, _col_gt_lit_i64("b", 1000), _col_gt_lit_i64("a", 25)
        ),
    )

    var pass_idx = _collect_pass_indices(evaluate_filter_narrowed(batch, expr))

    # ⚠ NON-EMPTY IS ASSERTED SEPARATELY: `[]` is what "the filter refused
    # everything" also looks like, and this cell's expected set is one row.
    assert_true(len(pass_idx) > 0)
    assert_equal(len(pass_idx), 1)
    assert_equal(pass_idx[0], 0)


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_filter_null_collapsed_int64_gt]()
    suite.test[test_filter_null_collapsed_float64_lt]()
    suite.test[test_filter_null_collapsed_col_vs_col]()
    suite.test[test_filter_null_collapsed_conjunction]()
    suite.test[test_filter_null_collapsed_all_valid_path_unchanged]()
    suite.test[test_filter_disjunction_keeps_TRUE_OR_NULL_rows]()
    suite.test[test_filter_negated_conjunction_keeps_the_FALSE_AND_NULL_rows]()
    suite.test[
        test_filter_negated_conjunction_with_the_NULL_ARM_FIRST_keeps_its_rows
    ]()
    suite.test[
        test_filter_negated_disjunction_with_the_NULL_ARM_FIRST_drops_only_UNKNOWN
    ]()
    suite^.run()
