# =============================================================================
# test_broker_consume_pushdown_decode.mojo
#   Decode-time pushdown apply unit tests (no network)
# =============================================================================
#
# Coverage for the decode-time pushdown apply
# (`consume_pushdown._apply_consume_pushdown`), which the dual-tier consume
# calls on each decoded batch of both tiers. Only matching rows and projected
# columns are materialized. It is exercised directly over a hand-built
# RecordBatch, so no ConsumeCore or object store is needed.
#
# Cases:
#   * projection: 5-col batch, project [c1, c3] -> output has EXACTLY 2 columns,
#     correct names + correct values, in projection order.
#   * row filter: predicate `c0 < 3` -> only matching rows survive, exact set.
#   * two-way contract: pushed-down result == full-decode-then-filter result
#     (the helper's row set is byte-identical to applying the predicate by hand).
#   * combined filter+project where the predicate references a column the
#     projection DROPS (filter-before-project correctness).
#   * None/None -> identity (no-op pushdown returns the batch unchanged).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import Expr, BIN_LT, BIN_GE
from komira_plan_expr.scalar_value import ScalarValue

from komira_broker_compaction.consume_pushdown import _apply_consume_pushdown


# =============================================================================
# Fixtures — a 5-column INT64 batch (so column_value reads back exactly).
# =============================================================================


def _int64_col(var vals: List[Int64]) raises -> Column[HeapRegion]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, vals[i])
    return Column.from_primitive[DType.int64](arr^)


def _batch5(n: Int) raises -> RecordBatch:
    """5 INT64 columns c0..c4 over n rows. Values:
      c0 = row index (0..n-1)        — the filter column
      c1 = 100 + row index           — a projected-output column
      c2 = 200 + row index
      c3 = 300 + row index           — a projected-output column
      c4 = 400 + row index
    """
    var schema = Schema(
        names=[
            String("c0"),
            String("c1"),
            String("c2"),
            String("c3"),
            String("c4"),
        ],
        arrow_types=[
            ArrowType.INT64.type_id,
            ArrowType.INT64.type_id,
            ArrowType.INT64.type_id,
            ArrowType.INT64.type_id,
            ArrowType.INT64.type_id,
        ],
        dtypes=[
            DType.int64,
            DType.int64,
            DType.int64,
            DType.int64,
            DType.int64,
        ],
        nullables=[False, False, False, False, False],
    )
    var v0 = List[Int64]()
    var v1 = List[Int64]()
    var v2 = List[Int64]()
    var v3 = List[Int64]()
    var v4 = List[Int64]()
    for i in range(n):
        v0.append(Int64(i))
        v1.append(Int64(100) + Int64(i))
        v2.append(Int64(200) + Int64(i))
        v3.append(Int64(300) + Int64(i))
        v4.append(Int64(400) + Int64(i))
    var b = RecordBatchBuilder.with_capacity(5)
    b.add_column(_int64_col(v0^))
    b.add_column(_int64_col(v1^))
    b.add_column(_int64_col(v2^))
    b.add_column(_int64_col(v3^))
    b.add_column(_int64_col(v4^))
    return b.build(schema^)


def _col_lt(name: String, v: Int) raises -> Expr:
    return Expr.binary(
        BIN_LT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(v))
    )


# =============================================================================
# projection
# =============================================================================


def test_projection_selects_two_columns_in_order() raises:
    print("[test_projection_selects_two_columns_in_order] starting...")
    var batch = _batch5(6)
    var proj = Optional[List[String]]([String("c1"), String("c3")])
    var out = _apply_consume_pushdown(batch^, Optional[Expr](None), proj^)
    assert_equal(out.num_columns(), 2, "projected batch has EXACTLY 2 columns")
    assert_equal(out.num_rows(), 6, "projection does not drop rows")
    assert_equal(
        out.schema.field_name(0), String("c1"), "output col 0 is c1"
    )
    assert_equal(
        out.schema.field_name(1), String("c3"), "output col 1 is c3"
    )
    # Values come from the right source columns, in projection order.
    for i in range(6):
        assert_equal(
            out.column_value(0, i),
            Int64(100) + Int64(i),
            "projected c1 value at row " + String(i),
        )
        assert_equal(
            out.column_value(1, i),
            Int64(300) + Int64(i),
            "projected c3 value at row " + String(i),
        )
    _ = out^
    print("[test_projection_selects_two_columns_in_order] PASS")


# =============================================================================
# row filter + two-way contract
# =============================================================================


def test_filter_keeps_only_matching_rows() raises:
    print("[test_filter_keeps_only_matching_rows] starting...")
    var batch = _batch5(10)
    # c0 < 3 -> rows 0,1,2 survive (c0 == row index).
    var out = _apply_consume_pushdown(
        batch^, Optional[Expr](_col_lt(String("c0"), 3)), Optional[List[String]](None)
    )
    assert_equal(out.num_rows(), 3, "filter c0<3 keeps exactly 3 rows")
    assert_equal(out.num_columns(), 5, "filter does not drop columns")
    for i in range(3):
        assert_equal(
            out.column_value(0, i), Int64(i), "surviving c0 value row " + String(i)
        )
        # other columns track the same surviving rows.
        assert_equal(
            out.column_value(3, i),
            Int64(300) + Int64(i),
            "surviving c3 value row " + String(i),
        )
    _ = out^
    print("[test_filter_keeps_only_matching_rows] PASS")


def test_two_way_contract_pushed_down_equals_manual_filter() raises:
    print("[test_two_way_contract_pushed_down_equals_manual_filter] starting...")
    # The "pushed-down result == full-decode-then-filter result" contract:
    # apply c0 >= 7 via the helper, and assert the surviving row set is EXACTLY
    # the rows a by-hand filter of the full batch would keep (rows 7,8,9).
    var batch = _batch5(10)
    var pred = Expr.binary(
        BIN_GE, Expr.col_ref(String("c0")), Expr.literal(ScalarValue.from_int(7))
    )
    var out = _apply_consume_pushdown(
        batch^, Optional[Expr](pred^), Optional[List[String]](None)
    )
    assert_equal(out.num_rows(), 3, "c0>=7 keeps rows 7,8,9")
    # Manual oracle: the surviving rows are exactly {7,8,9}, in order, all cols.
    for j in range(3):
        var expected_row = 7 + j
        assert_equal(
            out.column_value(0, j),
            Int64(expected_row),
            "c0 == oracle row " + String(expected_row),
        )
        assert_equal(
            out.column_value(1, j),
            Int64(100) + Int64(expected_row),
            "c1 == oracle row " + String(expected_row),
        )
        assert_equal(
            out.column_value(4, j),
            Int64(400) + Int64(expected_row),
            "c4 == oracle row " + String(expected_row),
        )
    _ = out^
    print("[test_two_way_contract_pushed_down_equals_manual_filter] PASS")


# =============================================================================
# combined filter + projection (filter-before-project)
# =============================================================================


def test_filter_before_project_predicate_on_dropped_column() raises:
    print("[test_filter_before_project_predicate_on_dropped_column] starting...")
    # Predicate references c0; projection KEEPS only [c1, c3] (drops c0). The
    # filter MUST run over the full batch first (sees c0), THEN project. If the
    # order were reversed, c0 would be gone and the filter would raise / be wrong.
    var batch = _batch5(8)
    var pred = _col_lt(String("c0"), 4)  # rows 0,1,2,3
    var proj = Optional[List[String]]([String("c1"), String("c3")])
    var out = _apply_consume_pushdown(batch^, Optional[Expr](pred^), proj^)
    assert_equal(out.num_rows(), 4, "filter c0<4 keeps 4 rows")
    assert_equal(
        out.num_columns(), 2, "projection drops to 2 columns (c0 not present)"
    )
    assert_equal(out.schema.field_name(0), String("c1"), "output col 0 is c1")
    assert_equal(out.schema.field_name(1), String("c3"), "output col 1 is c3")
    for i in range(4):
        assert_equal(
            out.column_value(0, i),
            Int64(100) + Int64(i),
            "c1 value of surviving row " + String(i),
        )
        assert_equal(
            out.column_value(1, i),
            Int64(300) + Int64(i),
            "c3 value of surviving row " + String(i),
        )
    _ = out^
    print("[test_filter_before_project_predicate_on_dropped_column] PASS")


# =============================================================================
# None/None identity
# =============================================================================


def test_no_pushdown_is_identity() raises:
    print("[test_no_pushdown_is_identity] starting...")
    var batch = _batch5(5)
    var out = _apply_consume_pushdown(
        batch^, Optional[Expr](None), Optional[List[String]](None)
    )
    assert_equal(out.num_rows(), 5, "no-pushdown preserves all rows")
    assert_equal(out.num_columns(), 5, "no-pushdown preserves all columns")
    for i in range(5):
        assert_equal(out.column_value(0, i), Int64(i), "c0 unchanged")
        assert_equal(
            out.column_value(2, i), Int64(200) + Int64(i), "c2 unchanged"
        )
    _ = out^
    print("[test_no_pushdown_is_identity] PASS")


def main() raises:
    test_projection_selects_two_columns_in_order()
    test_filter_keeps_only_matching_rows()
    test_two_way_contract_pushed_down_equals_manual_filter()
    test_filter_before_project_predicate_on_dropped_column()
    test_no_pushdown_is_identity()
    print(
        "[OK] test_broker_consume_pushdown_decode — decode apply:"
        " projection selects N cols in order, row filter keeps exact matching"
        " set (two-way contract vs manual oracle), filter-before-project when"
        " the predicate references a dropped column, None/None identity."
    )
