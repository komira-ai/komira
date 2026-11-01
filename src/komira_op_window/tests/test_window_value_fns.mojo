# =============================================================================
# test_window_value_fns -- LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE
# =============================================================================
#
# Through `_execute_partition_by_sink`. Expected rows are derived by hand from
# docs/design/query_semantics.md §9.4 (no source row: the default, else
# NULL; a NULL default is no default), §9.10 (the value functions respect
# NULLs and read their frame; NULL over an empty frame or past the n-th row)
# and §9.1 (an ordered window's default frame is RANGE UNBOUNDED PRECEDING ..
# CURRENT ROW, so LAST_VALUE is the current row's last peer).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_physical_plan.physical_plan import PartitionBySinkData
from komira_plan_expr.partition_expr import (
    FRAME_BOUND_CURRENT_ROW,
    FRAME_BOUND_PRECEDING,
    FRAME_BOUND_UNBOUNDED_FOLLOWING,
    FRAME_BOUND_UNBOUNDED_PRECEDING,
    FRAME_UNITS_ROWS,
    PartitionExpr,
    PartitionFrame,
    partition_expr_output_field,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_op_window.partition_scan_sink import _execute_partition_by_sink


def _i64(vals: List[Int64], valid: List[Bool]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.store[1](i, vals[i])
        if not valid[i]:
            arr._set_null(i)
    return Column.from_primitive[DType.int64](arr)


def _plain_i64(vals: List[Int64]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.int64]]()
    for v in vals:
        l.append(v)
    return Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(l))


def _batch(names: List[String], var cols: List[Column[HeapRegion]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var bb = RecordBatchBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], cols[i].arrow_type, True))
    for i in range(len(cols)):
        bb.add_column(cols[i].share())
    return bb.build(sb.build())


def _run(
    var batch: RecordBatch,
    pkeys: List[String],
    okeys: List[String],
    var exprs: List[PartitionExpr],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    for i in range(batch.schema.num_columns()):
        sb.add_field(batch.schema.field_at(i))
    for i in range(len(exprs)):
        sb.add_field(partition_expr_output_field(exprs[i], batch.schema, i))
    var desc = List[Bool]()
    for _ in range(len(okeys)):
        desc.append(False)
    var spec = PartitionBySinkData(pkeys.copy(), okeys.copy(), desc^, exprs^, sb.build())
    return _execute_partition_by_sink(batch^, spec)


def _get(rb: RecordBatch, col: Int, row: Int) -> Int64:
    ref c = rb.column_at(col)
    return c._data.get_typed[Scalar[DType.int64]](c._offset + row)


def _null(rb: RecordBatch, col: Int, row: Int) -> Bool:
    return rb.column_at(col).is_null_at(row)


# The fixture: two partitions, g = 1 (o 1..4) and g = 2 (o 1..2), sorted by
# (g, o) already; v holds a NULL at (g=1, o=3) whose slot holds 77.
def _gov() raises -> RecordBatch:
    var g: List[Int64] = [1, 1, 1, 1, 2, 2]
    var o: List[Int64] = [1, 2, 3, 4, 1, 2]
    var v: List[Int64] = [10, 20, 77, 40, 50, 60]
    var vvalid: List[Bool] = [True, True, False, True, True, True]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(g))
    cols.append(_plain_i64(o))
    cols.append(_i64(v, vvalid))
    var names: List[String] = ["g", "o", "v"]
    return _batch(names, cols^)


def _check(rb: RecordBatch, col: Int, want: List[Int64], want_null: List[Bool]) raises:
    for r in range(len(want)):
        assert_equal(_null(rb, col, r), want_null[r], "null flag at row " + String(r))
        if not want_null[r]:
            assert_equal(_get(rb, col, r), want[r], "value at row " + String(r))


def test_lag_lead_edge_is_null_without_default() raises:
    # LAG(v): NULL at each partition's first row, and NULL where the source
    # row's v is NULL (g=1, o=4 lags onto the NULL). LEAD(v, 2): NULL in the
    # last two rows of each partition.
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.lag("v"))
    exprs.append(PartitionExpr.lead("v", 2))
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var out = _run(_gov(), pk, ok, exprs^)
    _check(out, 3, [0, 10, 20, 0, 0, 50], [True, False, False, True, True, False])
    _check(out, 4, [0, 40, 0, 0, 0, 0], [True, False, True, True, True, True])


def test_lag_default_answers_the_edge_and_null_default_does_not() raises:
    # LAG(v, 1, 99): 99 at each partition's first row; the NULL source row
    # still answers NULL. LAG(v, 1, NULL) is LAG(v, 1).
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.lag_default("v", 1, ScalarValue.from_int64(99)))
    exprs.append(PartitionExpr.lag_default("v", 1, ScalarValue.null(DType.int64)))
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var out = _run(_gov(), pk, ok, exprs^)
    _check(out, 3, [99, 10, 20, 0, 99, 50], [False, False, False, True, False, False])
    _check(out, 4, [0, 10, 20, 0, 0, 50], [True, False, False, True, True, False])


def test_string_lag_respects_nulls() raises:
    # A STRING value column with a NULL: LAG answers NULL at the edge and on
    # the NULL source, the string elsewhere; LEAD with a default.
    var s = List[String]()
    s.append("a")
    s.append("")
    s.append("c")
    var valid: List[Bool] = [True, False, True]
    var cols = List[Column[HeapRegion]]()
    var o: List[Int64] = [1, 2, 3]
    cols.append(_plain_i64(o))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(s, valid)))
    var names: List[String] = ["o", "s"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.lag("s"))
    exprs.append(PartitionExpr.lead_default("s", 1, ScalarValue.from_string("z")))
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    var lag_col = out.column_at(2).as_string()
    assert_true(lag_col.is_null(0))
    assert_equal(lag_col.get(1), "a")
    assert_true(lag_col.is_null(2))
    var lead_col = out.column_at(3).as_string()
    assert_true(lead_col.is_null(0))
    assert_equal(lead_col.get(1), "c")
    assert_equal(lead_col.get(2), "z")


def test_last_value_default_frame_is_last_peer() raises:
    # One partition, o = 1, 2, 2, 3 (a tie at 2), v = 10, 20, 30, 40.
    # LAST_VALUE(v) under the default RANGE frame: 10, 30, 30, 40 (both peers
    # at o=2 see the frame up to the second of them). FIRST_VALUE(v): 10.
    var o: List[Int64] = [1, 2, 2, 3]
    var v: List[Int64] = [10, 20, 30, 40]
    var cols = List[Column[HeapRegion]]()
    cols.append(_plain_i64(o))
    cols.append(_plain_i64(v))
    var names: List[String] = ["o", "v"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.last_value("v"))
    exprs.append(PartitionExpr.first_value("v"))
    var ok: List[String] = ["o"]
    var out = _run(_batch(names, cols^), List[String](), ok, exprs^)
    _check(out, 2, [10, 30, 30, 40], [False, False, False, False])
    _check(out, 3, [10, 10, 10, 10], [False, False, False, False])


def test_nth_value_counts_frame_rows_and_nulls() raises:
    # NTH_VALUE(v, 2) under the default frame: NULL on a partition's first
    # row (the frame holds one row), then the second row's v. The second row
    # of g=1 is 20; NTH_VALUE(v, 3) reaches the NULL row (o=3) and answers
    # NULL there and after.
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.nth_value("v", 2))
    exprs.append(PartitionExpr.nth_value("v", 3))
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var out = _run(_gov(), pk, ok, exprs^)
    _check(out, 3, [0, 20, 20, 20, 0, 60], [True, False, False, False, True, False])
    _check(out, 4, [0, 0, 0, 0, 0, 0], [True, True, True, True, True, True])


def test_first_value_rows_frame_and_empty_frame() raises:
    # FIRST_VALUE(v) over ROWS BETWEEN 1 PRECEDING AND CURRENT ROW: the row
    # before (or the row itself on a partition's first row); the NULL is
    # respected. LAST_VALUE(v) over ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING:
    # NULL on the first row of a partition (an empty frame).
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.first_value("v").with_frame(
            PartitionFrame(
                FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 1, FRAME_BOUND_CURRENT_ROW, 0
            )
        )
    )
    exprs.append(
        PartitionExpr.last_value("v").with_frame(
            PartitionFrame(
                FRAME_UNITS_ROWS, FRAME_BOUND_PRECEDING, 2, FRAME_BOUND_PRECEDING, 1
            )
        )
    )
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var out = _run(_gov(), pk, ok, exprs^)
    _check(out, 3, [10, 10, 20, 0, 50, 50], [False, False, False, True, False, False])
    _check(out, 4, [0, 10, 20, 0, 0, 50], [True, False, False, True, True, False])


def test_last_value_whole_partition() raises:
    # LAST_VALUE(v) over the whole partition: 40 for g=1, 60 for g=2.
    var exprs = List[PartitionExpr]()
    exprs.append(
        PartitionExpr.last_value("v").with_frame(
            PartitionFrame(
                FRAME_UNITS_ROWS,
                FRAME_BOUND_UNBOUNDED_PRECEDING, 0,
                FRAME_BOUND_UNBOUNDED_FOLLOWING, 0,
            )
        )
    )
    var pk: List[String] = ["g"]
    var ok: List[String] = ["o"]
    var out = _run(_gov(), pk, ok, exprs^)
    _check(out, 3, [40, 40, 40, 40, 60, 60], [False, False, False, False, False, False])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
