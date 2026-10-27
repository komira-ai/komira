# =============================================================================
# test_asof_walker -- the equi-key comparison and the ASOF merge walker
# (komira_op_asof.asof_walker)
# =============================================================================
#
#   * compare_keys / compare_equi_keys: multi-column INT32 / INT64 / FLOAT64
#     order, NULL ordering apart from NULL matching, length mismatch.
#   * asof_merge_into: BACKWARD / FORWARD / NEAREST, one group and several
#     (BY), empty sides, several batches, NULL ASOF values on either side,
#     tolerance, an unmatched key, duplicate right values.
#   * asof_merge_dispatch: the run-time switch, and its refusals.
#
# STRING / DICTIONARY keys and the DuckDB-semantics cases (a NULL-keyed row
# inside a run of equal keys, float keys) are in test_asof_walker_keys.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_collections.slab import Slab
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray

from komira_plan_ir.logical_plan import (
    AsofTolerance,
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
)
from komira_op_asof.asof_walker import (
    compare_keys,
    compare_equi_keys,
    asof_merge_into,
    asof_merge_dispatch,
)


# =============================================================================
# Helpers -- build typed PrimitiveArrays
# =============================================================================


def _arr_i32(vs: List[Int]) raises -> PrimitiveArray[DType.int32]:
    var a = PrimitiveArray[DType.int32].allocate(len(vs))
    var p = a._typed_ptr_mut()
    for i in range(len(vs)):
        p.store[width=1](i, Scalar[DType.int32](vs[i]))
    return a^


def _arr_i64(vs: List[Int]) raises -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate(len(vs))
    var p = a._typed_ptr_mut()
    for i in range(len(vs)):
        p.store[width=1](i, Scalar[DType.int64](vs[i]))
    return a^


def _arr_f64(vs: List[Float64]) raises -> PrimitiveArray[DType.float64]:
    var a = PrimitiveArray[DType.float64].allocate(len(vs))
    var p = a._typed_ptr_mut()
    for i in range(len(vs)):
        p.store[width=1](i, vs[i])
    return a^


def _batch_i64_2(
    c0: String, v0: List[Int], c1: String, v1: List[Int]
) raises -> RecordBatch:
    """Two-column non-null Int64 batch."""
    var a0 = _arr_i64(v0)
    var a1 = _arr_i64(v1)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, False))
    sb.add_field(Field(c1, ArrowType.INT64, False))
    return RecordBatch.from_columns_2(sb.build()^, a0^, a1^)


def _batch_i64_1(c0: String, v0: List[Int]) raises -> RecordBatch:
    var a0 = _arr_i64(v0)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build()^, a0^)


def _nullable_i64_array(
    v0: List[Int], nulls: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """Build a nullable PrimitiveArray[int64]. `nulls` are row indices
    to mark NULL."""
    var n = len(v0)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](v0[i]))
    for i in range(len(nulls)):
        arr.validity.value().clear(nulls[i])
    arr.null_count = len(nulls)
    return arr^


def _batch_i64_1_nullable(
    c0: String, v0: List[Int], nulls: List[Int]
) raises -> RecordBatch:
    """Single-column Int64 batch with explicit NULL rows."""
    var arr = _nullable_i64_array(v0, nulls)
    var col = Column.from_primitive[DType.int64](arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, True))
    return RecordBatch.from_typed_columns_1(sb.build()^, col^)


def _batch_i64_2_nullable_key(
    c0: String, v0: List[Int], nulls: List[Int], c1: String, v1: List[Int]
) raises -> RecordBatch:
    """`[<c0> (NULLABLE key), <c1> (non-null asof)]`.

    ⚠ THE NULL ROW'S DATA SLOT KEEPS ITS `v0[i]` VALUE. Writing a real value
    under a cleared validity bit is what makes a NULL-vs-NULL case
    non-vacuous -- a comparator that reads the value instead of the bit sees
    two equal numbers, which is precisely the wrong answer under test."""
    var a0 = _nullable_i64_array(v0, nulls)
    var a1 = _arr_i64(v1)
    var col0 = Column.from_primitive[DType.int64](a0^)
    var col1 = Column.from_primitive[DType.int64](a1^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT64, True))
    sb.add_field(Field(c1, ArrowType.INT64, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, col0^, col1^)


def _batch_i32_2(
    c0: String, v0: List[Int], c1: String, v1: List[Int]
) raises -> RecordBatch:
    """Two-column non-null Int32 batch."""
    var a0 = _arr_i32(v0)
    var a1 = _arr_i32(v1)
    var col0 = Column.from_primitive[DType.int32](a0^)
    var col1 = Column.from_primitive[DType.int32](a1^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.INT32, False))
    sb.add_field(Field(c1, ArrowType.INT32, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, col0^, col1^)


def _batch_f64_2(
    c0: String, v0: List[Float64], c1: String, v1: List[Float64]
) raises -> RecordBatch:
    var a0 = _arr_f64(v0)
    var a1 = _arr_f64(v1)
    var col0 = Column.from_primitive[DType.float64](a0^)
    var col1 = Column.from_primitive[DType.float64](a1^)
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, ArrowType.FLOAT64, False))
    sb.add_field(Field(c1, ArrowType.FLOAT64, False))
    return RecordBatch.from_typed_columns_2(sb.build()^, col0^, col1^)


# =============================================================================
# compare_keys
# =============================================================================


def test_compare_keys_int64_single_column_order() raises:
    var b0 = _batch_i64_1("k", [10])
    var b1 = _batch_i64_1("k", [20])
    var cols: List[Int] = [0]
    assert_equal(compare_keys(b0, 0, b1, 0, cols, cols), -1, "10 < 20")
    assert_equal(compare_keys(b1, 0, b0, 0, cols, cols), 1, "20 > 10")
    assert_equal(compare_keys(b0, 0, b0, 0, cols, cols), 0, "10 == 10")


def test_compare_keys_multi_column_lexicographic() raises:
    # batch has (a, b). Rows: (1,10), (1,20), (2,5).
    var b = _batch_i64_2("a", [1, 1, 2], "b", [10, 20, 5])
    var cols: List[Int] = [0, 1]
    # row 0 (1,10) vs row 1 (1,20): equal on a, 10 < 20 -> -1
    assert_equal(compare_keys(b, 0, b, 1, cols, cols), -1, "(1,10) < (1,20)")
    # row 1 (1,20) vs row 2 (2,5): 1 < 2 -> -1 (ignores b)
    assert_equal(compare_keys(b, 1, b, 2, cols, cols), -1, "(1,20) < (2,5)")
    # row 0 vs row 0: equal
    assert_equal(compare_keys(b, 0, b, 0, cols, cols), 0, "(1,10) == (1,10)")


# =============================================================================
# Order and match are two questions about the same pair of rows
# =============================================================================
#
#   ORDER  "may the merge cursor move past this pair?": NULL has a place
#          (first), two NULLs are adjacent, the answer is 0. Break it and the
#          cursor can skip rows.
#
#   MATCH  "do these two rows join?": `NULL = NULL` is UNKNOWN in SQL, so
#          the answer is no. A walker that read the order's 0 as a match
#          would join a NULL-keyed left row to a NULL-keyed right group.
#
# `compare_equi_keys` returns both (`EquiKeyCmp`), so a caller cannot answer
# the second question with the first.
# =============================================================================


def test_compare_keys_null_equi_key_ordering() raises:
    """THE ORDERING HALF -- CORRECT, AND IT MUST STAY. `compare_keys` is the
    TOTAL ORDER the merge cursor walks: NULL is its own class sorting before
    every non-NULL, so two NULLs are adjacent and compare 0.

    ⚠ THE `0` HERE IS NOT A JOIN VERDICT. See
    `test_compare_equi_keys_null_never_matches` for the question this one does
    not answer."""
    var b_null = _batch_i64_1_nullable("k", [0, 42], [0])  # row 0 is NULL
    var b_val = _batch_i64_1_nullable("k", [42, 42], [])  # no nulls
    var cols: List[Int] = [0]
    var b_null2 = _batch_i64_1_nullable("k", [0], [0])
    assert_equal(
        compare_keys(b_null2, 0, b_null2, 0, cols, cols), 0,
        "two NULLs are ADJACENT in the sort order -- the cursor must not"
        " advance past one to reach the other",
    )
    # NULL vs 42: NULL < 42 -> -1
    assert_equal(compare_keys(b_null, 0, b_val, 0, cols, cols), -1,
                 "NULL < 42")
    # 42 vs NULL: -> +1
    assert_equal(compare_keys(b_val, 0, b_null, 0, cols, cols), 1,
                 "42 > NULL")


def test_compare_equi_keys_null_never_matches() raises:
    """The match half: `NULL = NULL` is UNKNOWN, never a match; two equal
    real keys still match; one NULL is UNKNOWN too.
    """
    var b_null2 = _batch_i64_1_nullable("k", [0], [0])
    var b_null = _batch_i64_1_nullable("k", [0, 42], [0])
    var b_val = _batch_i64_1_nullable("k", [42, 42], [])
    var cols: List[Int] = [0]

    var both_null = compare_equi_keys(b_null2, 0, b_null2, 0, cols, cols)
    assert_equal(
        both_null.order, 0,
        "ORDER is unchanged: two NULLs remain adjacent for the cursor",
    )
    assert_false(
        both_null.matched,
        "⛔ NULL = NULL is UNKNOWN, never a join match -- the DATA"
        " slots under both cleared validity bits hold 0, so"
        " a comparator reading the value instead of the bit sees equality",
    )

    var real_eq = compare_equi_keys(b_val, 0, b_val, 1, cols, cols)
    assert_equal(real_eq.order, 0, "42 == 42 orders equal")
    assert_true(
        real_eq.matched,
        "two REAL equal keys must still match -- the control that keeps the"
        " fix from being 'nothing ever matches'",
    )

    var one_null = compare_equi_keys(b_null, 0, b_val, 0, cols, cols)
    assert_equal(one_null.order, -1, "NULL orders before 42")
    assert_false(one_null.matched, "exactly one NULL is UNKNOWN too")


def test_compare_equi_keys_null_in_an_earlier_column_still_orders() raises:
    """A NULL IN COLUMN 0 MUST NOT SHORT-CIRCUIT THE TUPLE WALK. Two rows can
    be UNMATCHED because of column 0 and still be strictly ORDERED by column 1,
    and the cursor needs that order. Returning "unknown, order 0" on the first
    NULL would hand the walker a 0 for a pair whose real order is decided
    further right, and the cursor would stop advancing.

    This is the case the carry-forward `unmatched` flag exists for; a
    return-early implementation passes every other test in this file.
    """
    # (NULL, 5) vs (NULL, 3): col0 both NULL -> adjacent but unmatched;
    # col1 decides the order, 5 > 3.
    var b = _batch_i64_2_nullable_key("k", [0, 0], [0, 1], "t", [5, 3])
    var cols: List[Int] = [0, 1]
    var c = compare_equi_keys(b, 0, b, 1, cols, cols)
    assert_equal(
        c.order, 1,
        "the ORDER must come from column 1 even though column 0 was NULL on"
        " both sides",
    )
    assert_false(c.matched, "a NULL anywhere in the tuple means no match")

    # (NULL, 5) vs (NULL, 5): adjacent AND equal, still not a match.
    var b2 = _batch_i64_2_nullable_key("k", [0, 0], [0, 1], "t", [5, 5])
    var c2 = compare_equi_keys(b2, 0, b2, 1, cols, cols)
    assert_equal(c2.order, 0, "equal on every column -> adjacent")
    assert_false(c2.matched, "still UNKNOWN: column 0 is NULL on both sides")


def test_walker_null_equi_key_never_joins_a_null_group() raises:
    """End to end through the walker: both sides carry a NULL equi key whose
    data slot holds 0, and a real key 7.

    Every left row is emitted once either way, so the wrong answer is a value
    (a right row where NULL belongs), not a row count.
    """
    #   left : k=[NULL, 7], ts=[15, 15]
    #   right: k=[NULL, 7], ts=[10, 10]
    var left = _batch_i64_2_nullable_key("k", [0, 7], [0], "ts", [15, 15])
    var right = _batch_i64_2_nullable_key("k", [0, 7], [0], "ts", [10, 10])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )

    assert_equal(len(lb), 2, "LEFT-asof emits every left row exactly once")
    assert_equal(
        rb[0], -1,
        "⛔ a NULL equi-key must match NOTHING, including another NULL."
        " Pre-fix this row joined the NULL-keyed right group and reported"
        " right batch 0",
    )
    # The real key must be unaffected -- a fix that made everything unmatched
    # would satisfy the assertion above and be useless.
    assert_equal(rb[1], 0, "the real key 7 still finds its right batch")
    assert_equal(rr[1], 1, "...at right row 1 (ts=10 <= 15, BACKWARD)")


def test_compare_keys_length_mismatch_raises() raises:
    var b = _batch_i64_2("a", [1], "b", [2])
    var l: List[Int] = [0, 1]
    var r: List[Int] = [0]
    var raised = False
    try:
        _ = compare_keys(b, 0, b, 0, l, r)
    except e:
        raised = True
    assert_true(raised, "length mismatch raises")


# =============================================================================
# asof_merge_into -- single-partition BACKWARD (no BY)
# =============================================================================
#
# Use a dummy equi-key that all rows share (value 0), so the walker
# reduces to a single-group run. This exercises the ASOF kernel end to
# end through the walker.


def test_walker_backward_single_partition() raises:
    # Left ts: 5, 15, 25, 35. Right ts: 10, 20, 30. All keys == 0.
    # Backward: 5->none; 15->10; 25->20; 35->30.
    var left = _batch_i64_2("k", [0, 0, 0, 0], "ts", [5, 15, 25, 35])
    var right = _batch_i64_2("k", [0, 0, 0], "ts", [10, 20, 30])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 4, "4 left rows emitted")
    # Row 0 (ts=5): no match
    assert_equal(rb[0], -1, "ts=5 unmatched")
    # Row 1 (ts=15): right row 0 (ts=10)
    assert_equal(rb[1], 0, "ts=15 -> batch 0")
    assert_equal(rr[1], 0, "ts=15 -> row 0 (ts=10)")
    # Row 2 (ts=25): right row 1 (ts=20)
    assert_equal(rr[2], 1, "ts=25 -> row 1 (ts=20)")
    # Row 3 (ts=35): right row 2 (ts=30)
    assert_equal(rr[3], 2, "ts=35 -> row 2 (ts=30)")


def test_walker_forward_single_partition() raises:
    # Left ts: 5, 15, 25, 35. Right ts: 10, 20, 30.
    # Forward: 5->10; 15->20; 25->30; 35->none.
    var left = _batch_i64_2("k", [0, 0, 0, 0], "ts", [5, 15, 25, 35])
    var right = _batch_i64_2("k", [0, 0, 0], "ts", [10, 20, 30])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_FORWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 0, "ts=5 -> ts=10")
    assert_equal(rr[1], 1, "ts=15 -> ts=20")
    assert_equal(rr[2], 2, "ts=25 -> ts=30")
    assert_equal(rb[3], -1, "ts=35 unmatched")


def test_walker_nearest_single_partition() raises:
    # Left ts: 12, 18, 25. Right ts: 10, 20, 30.
    # Nearest: 12->10 (|2|<|8|); 18->20 (|2|<|8|); 25->20 (|5|<|5| tie-backward).
    var left = _batch_i64_2("k", [0, 0, 0], "ts", [12, 18, 25])
    var right = _batch_i64_2("k", [0, 0, 0], "ts", [10, 20, 30])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_NEAREST, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 0, "12 -> 10")
    assert_equal(rr[1], 1, "18 -> 20")
    assert_equal(rr[2], 1, "25 -> 20 (tie-backward)")


# =============================================================================
# Multi-partition (BY=symbol)
# =============================================================================


def test_walker_backward_multi_partition() raises:
    # Symbols 1 and 2 each with their own ASOF stream.
    # Left: (1,10), (1,20), (2,30), (2,40). Right: (1,15), (2,25), (2,35).
    # Backward: (1,10)->none; (1,20)->(1,15); (2,30)->(2,25); (2,40)->(2,35).
    var left = _batch_i64_2("sym", [1, 1, 2, 2], "ts", [10, 20, 30, 40])
    var right = _batch_i64_2("sym", [1, 2, 2], "ts", [15, 25, 35])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 4, "4 left rows")
    assert_equal(rb[0], -1, "(1,10) unmatched")
    assert_equal(rr[1], 0, "(1,20) -> (1,15)")
    assert_equal(rr[2], 1, "(2,30) -> (2,25)")
    assert_equal(rr[3], 2, "(2,40) -> (2,35)")


def test_walker_unmatched_equi_key() raises:
    # Left has key=3 which is absent on the right.
    # Left: (3,10). Right: (1,5), (2,7).
    var left = _batch_i64_2("sym", [3], "ts", [10])
    var right = _batch_i64_2("sym", [1, 2], "ts", [5, 7])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 1, "1 left row")
    assert_equal(rb[0], -1, "key=3 absent -> unmatched")


# =============================================================================
# Empty sides
# =============================================================================


def test_walker_empty_left() raises:
    var left = _batch_i64_2("k", List[Int](), "ts", List[Int]())
    var right = _batch_i64_2("k", [0], "ts", [10])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 0, "empty left -> empty output")


def test_walker_empty_right_all_unmatched() raises:
    var left = _batch_i64_2("k", [0, 0], "ts", [1, 2])
    var right = _batch_i64_2("k", List[Int](), "ts", List[Int]())
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 2, "2 left rows")
    assert_equal(rb[0], -1, "row 0 unmatched")
    assert_equal(rb[1], -1, "row 1 unmatched")


# =============================================================================
# Multi-batch input
# =============================================================================


def test_walker_multi_batch_left() raises:
    # Two left batches in one run; group buffering must persist across
    # the batch boundary if the equi-key is unchanged.
    # Batch 0: (0,10), (0,20). Batch 1: (0,30). Right: (0,15), (0,25).
    # Expected BACKWARD: 10->none, 20->15, 30->25.
    var left0 = _batch_i64_2("k", [0, 0], "ts", [10, 20])
    var left1 = _batch_i64_2("k", [0], "ts", [30])
    var right = _batch_i64_2("k", [0, 0], "ts", [15, 25])

    var left_b = Slab[RecordBatch]()
    left_b.append(left0^)
    left_b.append(left1^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 3, "3 rows across 2 batches")
    assert_equal(lb[0], 0, "row 0 in batch 0")
    assert_equal(lb[2], 1, "row 2 in batch 1")
    assert_equal(rb[0], -1, "ts=10 unmatched")
    assert_equal(rr[1], 0, "ts=20 -> ts=15")
    assert_equal(rr[2], 1, "ts=30 -> ts=25")


def test_walker_multi_batch_right() raises:
    # Right has groups split across batches.
    # Left: (1,10), (2,10). Right batch 0: (1,5). Right batch 1: (2,7).
    var left = _batch_i64_2("k", [1, 2], "ts", [10, 10])
    var right0 = _batch_i64_2("k", [1], "ts", [5])
    var right1 = _batch_i64_2("k", [2], "ts", [7])

    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right0^)
    right_b.append(right1^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rb[0], 0, "(1,10) -> batch 0")
    assert_equal(rr[0], 0, "(1,10) -> row 0")
    assert_equal(rb[1], 1, "(2,10) -> batch 1")
    assert_equal(rr[1], 0, "(2,10) -> row 0")


# =============================================================================
# NULL ASOF handling
# =============================================================================


def test_walker_null_left_asof_emits_null_right() raises:
    # Left ts has NULL at row 1; walker should emit unmatched for it.
    # Build left: sym=[0,0,0], ts=[10, NULL, 30].
    var sym = _arr_i64([0, 0, 0])
    var ts_arr = _nullable_i64_array([10, 0, 30], [1])
    var ts_col = Column.from_primitive[DType.int64](ts_arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("ts", ArrowType.INT64, True))
    var left = RecordBatch.from_typed_columns_2(
        sb.build()^,
        Column.from_primitive[DType.int64](sym^),
        ts_col^,
    )

    var right = _batch_i64_2("k", [0, 0], "ts", [15, 25])

    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rb[0], -1, "ts=10 no backward match (right=15,25)")
    assert_equal(rb[1], -1, "NULL ts -> unmatched")
    assert_equal(rr[2], 1, "ts=30 -> ts=25")


def test_walker_null_right_asof_filtered_from_group() raises:
    # Right ts has NULL at row 0; walker should skip it when gathering
    # the group. Group becomes [25] only; BACKWARD of ts=20 -> unmatched.
    var sym = _arr_i64([0, 0])
    var ts_arr = _nullable_i64_array([0, 25], [0])
    var ts_col = Column.from_primitive[DType.int64](ts_arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("ts", ArrowType.INT64, True))
    var right = RecordBatch.from_typed_columns_2(
        sb.build()^,
        Column.from_primitive[DType.int64](sym^),
        ts_col^,
    )

    var left = _batch_i64_2("k", [0, 0], "ts", [20, 30])

    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    # ts=20: group is only [25], backward -> unmatched
    assert_equal(rb[0], -1, "ts=20 backward of {25} unmatched")
    # ts=30: backward of {25} -> row 1 (the only non-NULL)
    assert_equal(rr[1], 1, "ts=30 -> ts=25 (NULL @ row 0 skipped)")


# =============================================================================
# Tolerance
# =============================================================================


def test_walker_tolerance_respected() raises:
    # Backward; tolerance=2. ts=10 -> 8 (|2|<=2 match); ts=20 -> 15 (|5|>2 NULL).
    var left = _batch_i64_2("k", [0, 0], "ts", [10, 20])
    var right = _batch_i64_2("k", [0, 0], "ts", [8, 15])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.int64(2), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 0, "ts=10 within tol=2 of 8")
    assert_equal(rb[1], -1, "ts=20 outside tol=2 of 15")


# =============================================================================
# Duplicate right timestamps
# =============================================================================


def test_walker_backward_duplicate_right_ts() raises:
    # Right ts has duplicates: [20, 20, 20]. Backward of 20 picks LAST.
    var left = _batch_i64_2("k", [0], "ts", [20])
    var right = _batch_i64_2("k", [0, 0, 0], "ts", [20, 20, 20])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_BACKWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 2, "Backward of 20 in [20,20,20] -> LAST (idx 2)")


def test_walker_forward_duplicate_right_ts() raises:
    # Forward of 20 in [20,20,20] -> FIRST (idx 0).
    var left = _batch_i64_2("k", [0], "ts", [20])
    var right = _batch_i64_2("k", [0, 0, 0], "ts", [20, 20, 20])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_FORWARD, DType.int64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 0, "Forward of 20 in [20,20,20] -> FIRST (idx 0)")


# =============================================================================
# Int32 + Float64 dtype coverage
# =============================================================================


def test_walker_int32_backward() raises:
    # Same as the basic int64 test but on int32 columns.
    var left = _batch_i32_2("k", [0, 0], "ts", [15, 35])
    var right = _batch_i32_2("k", [0, 0], "ts", [10, 30])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    # Note: in this test the equi-key is Int32 too, so compare_keys takes
    # the INT32 path.
    asof_merge_into[ASOF_BACKWARD, DType.int32](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(rr[0], 0, "ts=15 -> ts=10")
    assert_equal(rr[1], 1, "ts=35 -> ts=30")


def test_walker_float64_nearest() raises:
    var left = _batch_f64_2("k", [0.0, 0.0], "ts", [1.5, 2.8])
    var right = _batch_f64_2("k", [0.0, 0.0, 0.0], "ts", [1.0, 2.0, 3.0])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_into[ASOF_NEAREST, DType.float64](
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    # 1.5 equidistant from 1.0 and 2.0; tie-backward picks 1.0 (idx 0).
    assert_equal(rr[0], 0, "1.5 -> 1.0 (tie-backward)")
    # 2.8 closer to 3.0 (|0.2|<|0.8|).
    assert_equal(rr[1], 2, "2.8 -> 3.0")


# =============================================================================
# asof_merge_dispatch -- runtime 9-arm shim
# =============================================================================


def test_dispatch_backward_int64_matches_direct() raises:
    var left = _batch_i64_2("k", [0, 0], "ts", [15, 35])
    var right = _batch_i64_2("k", [0, 0], "ts", [10, 30])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)

    var lkc: List[Int] = [0]
    var rkc: List[Int] = [0]
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    asof_merge_dispatch(
        ASOF_BACKWARD, DType.int64,
        left_b, right_b, lkc, rkc, 1, 1,
        AsofTolerance.none(), lb, lr, rb, rr,
    )
    assert_equal(len(lb), 2, "2 rows")
    assert_equal(rr[0], 0, "dispatched BACKWARD int64 ts=15 -> ts=10")


def test_dispatch_unsupported_dtype_raises() raises:
    var left = _batch_i64_1("k", [0])
    var right = _batch_i64_1("k", [0])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)
    var lkc: List[Int] = []
    var rkc: List[Int] = []
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    var raised = False
    try:
        asof_merge_dispatch(
            ASOF_BACKWARD, DType.uint32,
            left_b, right_b, lkc, rkc, 0, 0,
            AsofTolerance.none(), lb, lr, rb, rr,
        )
    except e:
        raised = True
    assert_true(raised, "uint32 dtype raises")


def test_dispatch_unknown_strategy_raises() raises:
    var left = _batch_i64_1("k", [0])
    var right = _batch_i64_1("k", [0])
    var left_b = Slab[RecordBatch]()
    left_b.append(left^)
    var right_b = Slab[RecordBatch]()
    right_b.append(right^)
    var lkc: List[Int] = []
    var rkc: List[Int] = []
    var lb = List[Int]()
    var lr = List[Int]()
    var rb = List[Int]()
    var rr = List[Int]()
    var raised = False
    try:
        asof_merge_dispatch(
            UInt8(99), DType.int64,
            left_b, right_b, lkc, rkc, 0, 0,
            AsofTolerance.none(), lb, lr, rb, rr,
        )
    except e:
        raised = True
    assert_true(raised, "unknown strategy raises")

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
