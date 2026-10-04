# =============================================================================
# Tests for selection-vector conjunction narrowing
#
# flatten_and_conjuncts + conjunction.evaluate_conjunction_select +
# selection_vector.compose_mask + conjunction.evaluate_predicate_selected.
#
# Sections:
#   - flatten_and_conjuncts: AND-tree flattening
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.collections.slab import Slab
from komira_core.eval.selection_vector import SelectionVector
from komira_core.eval.comparison import eval_gt, eval_lt, eval_eq

from komira_core.plan.expr import (
    Expr,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
)
from komira_core.plan.expr_helpers import flatten_and_conjuncts
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.conjunction import (
    evaluate_predicate_selected,
    evaluate_conjunction_select,
    evaluate_filter_narrowed,
)


# ---------------------------------------------------------------------------
# helpers to build small predicates
# ---------------------------------------------------------------------------


def _col_eq_lit(name: String, v: Int64) -> Expr:
    """`col(name) == v` — int64 literal."""
    return Expr.binary(
        BIN_EQ,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _col_gt_lit(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _col_lt_lit(name: String, v: Int64) -> Expr:
    return Expr.binary(
        BIN_LT,
        Expr.col_ref(name),
        Expr.literal(ScalarValue.from_int64(v)),
    )


# ---------------------------------------------------------------------------
# flatten_and_conjuncts
# ---------------------------------------------------------------------------


def test_flatten_non_and_single_conjunct() raises:
    """Non-AND root: flatten returns a single-element array."""
    var e = _col_eq_lit("a", 1)
    var flat = flatten_and_conjuncts(e)
    assert_equal(len(flat), 1)
    # The single conjunct must be the original BinaryOp(EQ) — preserved by copy.
    assert_true(flat[0].tag == EXPR_BINARY_OP)
    assert_equal(Int(flat[0].binary_op()), Int(BIN_EQ))


def test_flatten_left_skew_two() raises:
    """`AND(A, B)` -> `[A, B]`."""
    var a = _col_eq_lit("a", 1)
    var b = _col_gt_lit("b", 10)
    var root = Expr.binary(BIN_AND, a^, b^)
    var flat = flatten_and_conjuncts(root)
    assert_equal(len(flat), 2)
    assert_equal(Int(flat[0].binary_op()), Int(BIN_EQ))
    assert_equal(Int(flat[1].binary_op()), Int(BIN_GT))


def test_flatten_left_skew_three() raises:
    """`AND(AND(A, B), C)` -> `[A, B, C]`."""
    var a = _col_eq_lit("a", 1)
    var b = _col_gt_lit("b", 10)
    var c = _col_lt_lit("c", 100)
    var ab = Expr.binary(BIN_AND, a^, b^)
    var root = Expr.binary(BIN_AND, ab^, c^)
    var flat = flatten_and_conjuncts(root)
    assert_equal(len(flat), 3)
    assert_equal(Int(flat[0].binary_op()), Int(BIN_EQ))  # A
    assert_equal(Int(flat[1].binary_op()), Int(BIN_GT))  # B
    assert_equal(Int(flat[2].binary_op()), Int(BIN_LT))  # C


def test_flatten_right_skew_three() raises:
    """`AND(A, AND(B, C))` -> `[A, B, C]`."""
    var a = _col_eq_lit("a", 1)
    var b = _col_gt_lit("b", 10)
    var c = _col_lt_lit("c", 100)
    var bc = Expr.binary(BIN_AND, b^, c^)
    var root = Expr.binary(BIN_AND, a^, bc^)
    var flat = flatten_and_conjuncts(root)
    assert_equal(len(flat), 3)
    assert_equal(Int(flat[0].binary_op()), Int(BIN_EQ))  # A
    assert_equal(Int(flat[1].binary_op()), Int(BIN_GT))  # B
    assert_equal(Int(flat[2].binary_op()), Int(BIN_LT))  # C


def test_flatten_mixed_four() raises:
    """`AND(AND(A, B), AND(C, D))` -> `[A, B, C, D]`."""
    var a = _col_eq_lit("a", 1)
    var b = _col_gt_lit("b", 10)
    var c = _col_lt_lit("c", 100)
    var d = _col_eq_lit("d", 7)
    var ab = Expr.binary(BIN_AND, a^, b^)
    var cd = Expr.binary(BIN_AND, c^, d^)
    var root = Expr.binary(BIN_AND, ab^, cd^)
    var flat = flatten_and_conjuncts(root)
    assert_equal(len(flat), 4)


def test_flatten_or_not_split() raises:
    """`OR(A, B)` at root: NOT an AND-tree, returns single element."""
    var a = _col_eq_lit("a", 1)
    var b = _col_gt_lit("b", 10)
    var root = Expr.binary(BIN_OR, a^, b^)
    var flat = flatten_and_conjuncts(root)
    assert_equal(len(flat), 1)
    assert_equal(Int(flat[0].binary_op()), Int(BIN_OR))


def test_flatten_and_containing_or() raises:
    """`AND(A, OR(B, C))` -> `[A, OR(B, C)]` — OR is opaque."""
    var a = _col_eq_lit("a", 1)
    var b = _col_gt_lit("b", 10)
    var c = _col_lt_lit("c", 100)
    var or_bc = Expr.binary(BIN_OR, b^, c^)
    var root = Expr.binary(BIN_AND, a^, or_bc^)
    var flat = flatten_and_conjuncts(root)
    assert_equal(len(flat), 2)
    assert_equal(Int(flat[0].binary_op()), Int(BIN_EQ))  # A
    assert_equal(Int(flat[1].binary_op()), Int(BIN_OR))  # OR(B, C)


def test_flatten_col_ref_leaf_preserved() raises:
    """Non-binary leaf (a bare col_ref) passes through as a single conjunct."""
    var e = Expr.col_ref(String("a"))
    var flat = flatten_and_conjuncts(e)
    assert_equal(len(flat), 1)
    assert_true(flat[0].tag == EXPR_COL_REF)


# ---------------------------------------------------------------------------
# SelectionVector.compose_mask
# ---------------------------------------------------------------------------


def _build_bool_mask(bits: List[Bool]) raises -> BooleanArray:
    """Build a BooleanArray from a Python-style list of Bool values."""
    var n = len(bits)
    var bm = Bitmap.create(n)
    for i in range(n):
        if bits[i]:
            bm.set(i)
        else:
            bm.clear(i)
    return BooleanArray.from_bitmap(bm^)


def test_compose_mask_selects_subset() raises:
    """compose_mask: narrow [0,2,4,6,8] by mask [T,F,T,F,T] -> [0,4,8]."""
    var idx_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](0),
        Scalar[DType.int32](2),
        Scalar[DType.int32](4),
        Scalar[DType.int32](6),
        Scalar[DType.int32](8),
    ]
    var sv = SelectionVector(PrimitiveArray[DType.int32].from_list(idx_vals))
    var mask = _build_bool_mask([True, False, True, False, True])
    var narrowed = sv.compose_mask(mask)
    assert_equal(narrowed.length(), 3)
    var ptr = narrowed.indices._typed_ptr_mut()
    assert_equal(Int(ptr[0]), 0)
    assert_equal(Int(ptr[1]), 4)
    assert_equal(Int(ptr[2]), 8)


def test_compose_mask_all_true() raises:
    """compose_mask: full-pass mask returns a vector identical to input."""
    var idx_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](3),
        Scalar[DType.int32](7),
    ]
    var sv = SelectionVector(PrimitiveArray[DType.int32].from_list(idx_vals))
    var mask = _build_bool_mask([True, True, True])
    var narrowed = sv.compose_mask(mask)
    assert_equal(narrowed.length(), 3)
    var ptr = narrowed.indices._typed_ptr_mut()
    assert_equal(Int(ptr[0]), 1)
    assert_equal(Int(ptr[1]), 3)
    assert_equal(Int(ptr[2]), 7)


def test_compose_mask_all_false() raises:
    """compose_mask: empty output when mask rejects everything."""
    var idx_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](3),
    ]
    var sv = SelectionVector(PrimitiveArray[DType.int32].from_list(idx_vals))
    var mask = _build_bool_mask([False, False])
    var narrowed = sv.compose_mask(mask)
    assert_equal(narrowed.length(), 0)


def test_compose_mask_crosses_byte_boundary() raises:
    """compose_mask: 10 indices with narrow pattern crossing a byte boundary."""
    # indices 0..10, mask keeps positions 0, 3, 7, 9 — crosses byte 0→1.
    var idx_vals = List[Scalar[DType.int32]]()
    for i in range(10):
        idx_vals.append(Scalar[DType.int32](i * 10))
    var sv = SelectionVector(PrimitiveArray[DType.int32].from_list(idx_vals))
    var mask = _build_bool_mask([True, False, False, True, False, False, False, True, False, True])
    var narrowed = sv.compose_mask(mask)
    assert_equal(narrowed.length(), 4)
    var ptr = narrowed.indices._typed_ptr_mut()
    assert_equal(Int(ptr[0]), 0)
    assert_equal(Int(ptr[1]), 30)
    assert_equal(Int(ptr[2]), 70)
    assert_equal(Int(ptr[3]), 90)


# ---------------------------------------------------------------------------
# SelectionVector.all
# ---------------------------------------------------------------------------


def test_sv_all_factory() raises:
    """SelectionVector.all(n) covers [0..n) and reports is_all(n)."""
    var sv = SelectionVector.all(5)
    assert_equal(sv.length(), 5)
    assert_true(sv.is_all(5))
    var ptr = sv.indices._typed_ptr_mut()
    for i in range(5):
        assert_equal(Int(ptr[i]), i)


# ---------------------------------------------------------------------------
# Evaluation helpers: build a RecordBatch with known columns
# ---------------------------------------------------------------------------


def _build_int_batch(col_name: String, values: List[Int64]) raises -> RecordBatch:
    """Build a single-column int64 RecordBatch."""
    var prim_vals = List[Scalar[DType.int64]]()
    for i in range(len(values)):
        prim_vals.append(Scalar[DType.int64](values[i]))
    var arr = PrimitiveArray[DType.int64].from_list(prim_vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(col_name, ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build(), arr^)


def _build_two_int_batch(
    name_a: String, values_a: List[Int64],
    name_b: String, values_b: List[Int64],
) raises -> RecordBatch:
    """Build a two-column int64 RecordBatch. Columns must have equal length."""
    var pa = List[Scalar[DType.int64]]()
    var pb = List[Scalar[DType.int64]]()
    for i in range(len(values_a)):
        pa.append(Scalar[DType.int64](values_a[i]))
        pb.append(Scalar[DType.int64](values_b[i]))
    var aa = PrimitiveArray[DType.int64].from_list(pa)
    var ab = PrimitiveArray[DType.int64].from_list(pb)
    var sb = SchemaBuilder()
    sb.add_field(Field(name_a, ArrowType.INT64, False))
    sb.add_field(Field(name_b, ArrowType.INT64, False))
    return RecordBatch.from_columns_2(sb.build(), aa^, ab^)


# ---------------------------------------------------------------------------
# evaluate_predicate_selected
# ---------------------------------------------------------------------------


def test_eps_full_cover_matches_naive() raises:
    """When sel covers every row, evaluate_predicate_selected == _eval_predicate."""
    var vals: List[Int64] = [1, 5, 10, 15, 20]
    var batch = _build_int_batch(String("a"), vals)
    var expr = _col_gt_lit("a", 7)
    var sv_all = SelectionVector.all(5)
    var mask = evaluate_predicate_selected(batch, expr, sv_all)
    # Rows matching a > 7: 10, 15, 20 -> positions 2,3,4.
    assert_equal(mask.true_count(), 3)
    assert_equal(mask.length, 5)


def test_eps_narrowed_sel_returns_sel_length_bits() raises:
    """With a 3-row selection, result has 3 bits — one per surviving row."""
    # Values [1,5,10,15,20]; pre-selected indices = [1, 2, 4] -> values [5, 10, 20].
    # Predicate a > 7: survivors at positions 1 (val 10) and 2 (val 20) within the
    # sub-batch, i.e. mask = [F, T, T].
    var vals: List[Int64] = [1, 5, 10, 15, 20]
    var batch = _build_int_batch(String("a"), vals)
    var pre_idx: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](4),
    ]
    var sv = SelectionVector(PrimitiveArray[DType.int32].from_list(pre_idx))
    var expr = _col_gt_lit("a", 7)
    var mask = evaluate_predicate_selected(batch, expr, sv)
    assert_equal(mask.length, 3)
    assert_equal(mask.true_count(), 2)
    assert_false(mask.get(0))
    assert_true(mask.get(1))
    assert_true(mask.get(2))


# ---------------------------------------------------------------------------
# evaluate_conjunction_select
# ---------------------------------------------------------------------------


def _collect_pass_indices(sv: SelectionVector) raises -> List[Int]:
    """Helper: extract indices from a SelectionVector into a plain List[Int]."""
    var out = List[Int]()
    var ptr = sv.indices._typed_ptr_ro()
    for i in range(sv.length()):
        out.append(Int(ptr[i]))
    return out^


def test_conj_full_pass_fast_path() raises:
    """All rows pass both conjuncts — result is the full row set."""
    # a: [10,20,30]; conjuncts: a > 0 AND a < 100 — everything passes.
    var vals: List[Int64] = [10, 20, 30]
    var batch = _build_int_batch(String("a"), vals)

    var conjuncts = Slab[Expr]()
    conjuncts.append(_col_gt_lit("a", 0))
    conjuncts.append(_col_lt_lit("a", 100))

    var sv = evaluate_conjunction_select(batch, conjuncts)
    assert_equal(sv.length(), 3)
    assert_true(sv.is_all(3))


def test_conj_first_rejects_all_short_circuits() raises:
    """First conjunct rejects every row: subsequent conjuncts skipped; empty result."""
    var vals: List[Int64] = [10, 20, 30]
    var batch = _build_int_batch(String("a"), vals)

    # a > 1000 passes nothing; a < 100 would pass everything.
    var conjuncts = Slab[Expr]()
    conjuncts.append(_col_gt_lit("a", 1000))
    conjuncts.append(_col_lt_lit("a", 100))

    var sv = evaluate_conjunction_select(batch, conjuncts)
    assert_equal(sv.length(), 0)


def test_conj_narrowing_two_stage() raises:
    """50% pass first, 30% of those pass second — verify final 15%.

    Rows: 10 values [0..10). Conj 1: a >= 5 -> keep [5,6,7,8,9] (5 rows).
    Conj 2: a < 7  -> from [5,6,7,8,9], keep [5,6] -> final indices [5,6].
    """
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)

# a >= 5 is `NOT (a < 5)` in BIN semantics; simplest to use GT 4.
    var conjuncts = Slab[Expr]()
    conjuncts.append(_col_gt_lit("a", 4))  # passes 5,6,7,8,9
    conjuncts.append(_col_lt_lit("a", 7))  # of those, passes 5,6

    var sv = evaluate_conjunction_select(batch, conjuncts)
    var out = _collect_pass_indices(sv)
    assert_equal(len(out), 2)
    assert_equal(out[0], 5)
    assert_equal(out[1], 6)


def test_conj_four_conjunct_matches_naive_reference() raises:
    """4-conjunct chain on a 16-row batch matches naive full-eval-then-AND mask.

    Batch: a in 0..16, b in 0..16 (same values). Conjuncts:
      (1) a > 2, (2) a < 13, (3) b > 4, (4) b < 11.
    Expected surviving set: rows where 2 < a < 13 AND 4 < b < 11, i.e. a in
    [3..12], b in [5..10]. Since a==b, final rows are a in [5..10] — 6 rows.
    """
    var a_vals = List[Int64]()
    var b_vals = List[Int64]()
    for i in range(16):
        a_vals.append(Int64(i))
        b_vals.append(Int64(i))
    var batch = _build_two_int_batch(String("a"), a_vals, String("b"), b_vals)

    var conjuncts = Slab[Expr]()
    conjuncts.append(_col_gt_lit("a", 2))
    conjuncts.append(_col_lt_lit("a", 13))
    conjuncts.append(_col_gt_lit("b", 4))
    conjuncts.append(_col_lt_lit("b", 10))

    var sv = evaluate_conjunction_select(batch, conjuncts)
    var got = _collect_pass_indices(sv)

    # Reference: build the naive full-eval AND mask, then materialize indices.
    var expected = List[Int]()
    for i in range(16):
        var ai = a_vals[i]
        var bi = b_vals[i]
        if ai > 2 and ai < 13 and bi > 4 and bi < 10:
            expected.append(i)

    assert_equal(len(got), len(expected))
    for i in range(len(expected)):
        assert_equal(got[i], expected[i])


def test_conj_no_conjuncts_returns_all_rows() raises:
    """Degenerate: empty conjunct list -> full row set (defensive path)."""
    var vals: List[Int64] = [1, 2, 3]
    var batch = _build_int_batch(String("a"), vals)
    var conjuncts = Slab[Expr]()  # empty
    var sv = evaluate_conjunction_select(batch, conjuncts)
    assert_equal(sv.length(), 3)


def test_evaluate_filter_narrowed_single_predicate() raises:
    """evaluate_filter_narrowed on a non-AND predicate behaves like a 1-conjunct list."""
    var vals: List[Int64] = [1, 5, 10, 15, 20]
    var batch = _build_int_batch(String("a"), vals)
    var expr = _col_gt_lit("a", 7)
    var sv = evaluate_filter_narrowed(batch, expr)
    var out = _collect_pass_indices(sv)
    assert_equal(len(out), 3)
    assert_equal(out[0], 2)
    assert_equal(out[1], 3)
    assert_equal(out[2], 4)


def test_evaluate_filter_narrowed_three_conjunct_and_tree() raises:
    """evaluate_filter_narrowed flattens an AND(AND(A,B),C) tree and narrows.

    Batch: a in 0..10. Predicate: (a > 2) AND ((a < 8) AND (a != 5)).
    The interior AND is a right-subtree of the root AND — flatten must
    produce 3 conjuncts. Expected surviving rows: a in {3, 4, 6, 7}.
    """
    var vals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var batch = _build_int_batch(String("a"), vals)

    var a_gt2 = _col_gt_lit("a", 2)
    var a_lt8 = _col_lt_lit("a", 8)
    var a_ne5 = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("a")),
        Expr.literal(ScalarValue.from_int64(5)),
    )  # a == 5
# We want a != 5; since the predicate evaluator supports BIN_EQ +
    # logical negation only at the predicate layer (not a generic NOT here),
    # we instead build the target set with (a > 5) OR (a < 5). But OR is
    # opaque to AND-flatten, which is exactly the property we want to verify.
    var a_not5 = Expr.binary(
        BIN_OR,
        _col_gt_lit("a", 5),
        _col_lt_lit("a", 5),
    )

    # AND(AND(a > 2, a < 8), OR(a > 5, a < 5))
    _ = a_ne5  # unused; kept for clarity above
    var inner = Expr.binary(BIN_AND, a_gt2^, a_lt8^)
    var root = Expr.binary(BIN_AND, inner^, a_not5^)

    var sv = evaluate_filter_narrowed(batch, root)
    var got = _collect_pass_indices(sv)
    # Expected: a in {3,4,6,7}, which are indices {3,4,6,7}.
    assert_equal(len(got), 4)
    assert_equal(got[0], 3)
    assert_equal(got[1], 4)
    assert_equal(got[2], 6)
    assert_equal(got[3], 7)


# ---------------------------------------------------------------------------
# compose_mask — branchless compaction
#
# `compose_mask` stores UNCONDITIONALLY and advances the write cursor BY THE
# BIT, so its eight per-bit arms carry no data-dependent branch. That form has
# one hazard the conditional-store form did not: a CLEAR bit still writes at
# `write_pos`, so every clear bit AFTER THE LAST SET ONE targets the element
# one past the last survivor. `compose_mask` allocates `pass_count + 1` and
# shrinks the logical length back for exactly that reason.
#
# Every case below therefore ends in a run of clear bits — the shape that
# overruns an output buffer sized at exactly `pass_count` — and every case
# asserts BOTH the survivors and that the scratch element is invisible in the
# returned array's own byte length.
# ---------------------------------------------------------------------------


def _compose_reference(indices: List[Int], bits: List[Bool]) -> List[Int]:
    """compose_mask's definition, spelled out independently of its loop shape."""
    var out = List[Int]()
    for i in range(len(bits)):
        if bits[i]:
            out.append(indices[i])
    return out^


def _check_compose(indices: List[Int], bits: List[Bool], label: String) raises:
    """Assert `compose_mask` over (indices, bits) equals the reference exactly."""
    var idx_vals = List[Scalar[DType.int32]]()
    for i in range(len(indices)):
        idx_vals.append(Scalar[DType.int32](indices[i]))
    var sv = SelectionVector(PrimitiveArray[DType.int32].from_list(idx_vals))
    var mask = _build_bool_mask(bits)
    var narrowed = sv.compose_mask(mask)
    var want = _compose_reference(indices, bits)

    assert_equal(narrowed.length(), len(want), label + ": survivor count")
    # The scratch element the unconditional store needs must be INVISIBLE: the
    # returned array reports exactly 4 bytes per survivor, not one more.
    assert_equal(
        Int(narrowed.indices.data.length()),
        len(want) * 4,
        label + ": output byte length",
    )
    var ptr = narrowed.indices._typed_ptr_mut()
    for i in range(len(want)):
        assert_equal(Int(ptr[i]), want[i], label + ": survivor " + String(i))


def test_compose_mask_single_survivor_then_trailing_zeros() raises:
    """One survivor at bit 0, then 15 clear bits — the exact overrun shape.

    `pass_count` is 1, so an output buffer sized at `pass_count` is FOUR BYTES;
    each of the 15 clear bits that follow stores at element 1, i.e. four bytes
    past the end of it.
    """
    var indices = List[Int]()
    var bits = List[Bool]()
    for i in range(16):
        indices.append(i * 7)
        bits.append(i == 0)
    _check_compose(indices, bits, String("single survivor, 15 trailing zeros"))


def test_compose_mask_lone_survivor_at_every_bit_position() raises:
    """A lone survivor at each of 24 bit positions — every arm, every offset."""
    for k in range(24):
        var indices = List[Int]()
        var bits = List[Bool]()
        for i in range(24):
            indices.append(i + 100)
            bits.append(i == k)
        _check_compose(
            indices, bits, String("lone survivor at bit ") + String(k)
        )


def test_compose_mask_whole_trailing_bytes_clear() raises:
    """Survivors confined to byte 0; bytes 1..4 entirely clear.

    Those bytes take the zero-byte skip, so this pins that the skip and the
    unconditional store agree about where the write cursor is.
    """
    var indices = List[Int]()
    var bits = List[Bool]()
    for i in range(40):
        indices.append(i * 5)
        bits.append(i < 8 and (i % 2) == 0)
    _check_compose(indices, bits, String("survivors in byte 0 only"))


def test_compose_mask_every_length_through_the_partial_tail() raises:
    """Lengths 1..40 — the branchless full-byte loop plus every tail width.

    `length & 7` takes all eight values here, so the hand-off from the
    full-byte loop to the per-bit tail is covered at every offset.
    """
    for n in range(1, 41):
        var indices = List[Int]()
        var bits = List[Bool]()
        for i in range(n):
            indices.append(i * 3 + 1)
            bits.append((i % 3) == 0)
        _check_compose(indices, bits, String("length ") + String(n))


def test_compose_mask_all_true_and_all_false() raises:
    """The two degenerate masks: full pass, and the `pass_count == 0` return."""
    var indices = List[Int]()
    var all_true = List[Bool]()
    var all_false = List[Bool]()
    for i in range(19):
        indices.append(i * 11)
        all_true.append(True)
        all_false.append(False)
    _check_compose(indices, all_true, String("all true, 19 bits"))
    _check_compose(indices, all_false, String("all false, 19 bits"))


def test_compose_mask_survivor_count_fills_an_aligned_buffer() raises:
    """16 survivors, then clear bits inside a NON-ZERO byte.

    This is the one shape in which the scratch element is not absorbed by
    allocator padding. `OwnedAlignedBuffer` pads to a 64-byte boundary, so a
    16-survivor output occupies EXACTLY its padded allocation (16 * 4 == 64)
    and element 16 is the first byte past it. The trailing clear bits are put
    in a non-zero byte on purpose: a wholly-zero byte takes the zero-byte skip
    and never reaches the store arms at all, so a mask that merely ends in
    zero BYTES does not exercise this.

    Survivors: bits 0..14 and bit 16 (15 + 1 == 16). Bit 15 and bits 17..23
    are clear, and bits 17..23 share byte 2 with the last survivor.
    """
    var indices = List[Int]()
    var bits = List[Bool]()
    for i in range(64):
        indices.append(i * 9 + 4)
        bits.append(i < 15 or i == 16)
    _check_compose(indices, bits, String("16 survivors, aligned-exact output"))


def test_compose_mask_pseudorandom_half_selectivity() raises:
    """4,096 bits at p~=0.5 — the `sdk/f3_compound_and` shape, at scale.

    This is the selectivity at which the old conditional store mispredicted on
    every other bit. Deterministic LCG, so any failure reproduces. The final 37
    bits are forced clear to put the overrun shape at the end of a long run.
    """
    var n = 4096
    var indices = List[Int]()
    var bits = List[Bool]()
    var state = UInt64(88172645463325252)
    for i in range(n):
        state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        indices.append(i * 2)
        bits.append(((state >> UInt64(33)) & UInt64(1)) == UInt64(1))
    for i in range(n - 37, n):
        bits[i] = False
    _check_compose(indices, bits, String("pseudorandom 4096 bits"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
