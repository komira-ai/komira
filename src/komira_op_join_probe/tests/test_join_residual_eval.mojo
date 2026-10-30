# `execute_residual_join_probe`: a residual predicate over one equi-key or
# none (the cross product), for INNER, LEFT, SEMI and ANTI, against hand
# computed answers; RIGHT / FULL refused.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_NE, BIN_AND, BIN_GE, BIN_LE
from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI,
)
from komira_physical_plan.physical_plan import MorselOp

from komira_op_join_probe.nested_loop_join import execute_residual_join_probe


def _i64_arr(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](values[i]))
    return arr^


def _i64_batch_2(
    name0: String, vals0: List[Int], name1: String, vals1: List[Int],
) raises -> RecordBatch:
    var a0 = _i64_arr(vals0)
    var a1 = _i64_arr(vals1)
    var sb = SchemaBuilder()
    sb.add_field(Field(name0, ArrowType.INT64, False))
    sb.add_field(Field(name1, ArrowType.INT64, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(2)
    rb.add_column(Column.from_primitive[DType.int64](a0^))
    rb.add_column(Column.from_primitive[DType.int64](a1^))
    return rb.build(schema^)


def _l1_probe() raises -> RecordBatch:
    var ok: List[Int] = [1, 1, 2, 3]
    var sk: List[Int] = [10, 20, 30, 40]
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _l3_build() raises -> RecordBatch:
    var ok: List[Int] = [1, 1, 2]
    var sk: List[Int] = [10, 99, 30]
    return _i64_batch_2("l_orderkey", ok, "l_suppkey", sk)


def _residual_neq_suppkey() -> Expr:
    return Expr.binary(BIN_NE, Expr.col_ref("l_suppkey"), Expr.col_ref("l_suppkey_right"))


def _join_op(
    join_type: UInt8, var residual: Expr, with_equi: Bool = True,
) -> MorselOp:
    var lk = List[String]()
    var rk = List[String]()
    if with_equi:
        lk.append("l_orderkey")
        rk.append("l_orderkey")
    var no_cols: Optional[List[String]] = None
    return MorselOp.join_probe_with_residual(
        -1, lk^, rk^, join_type, residual^, no_cols^,
    )


def _col_at(batch: RecordBatch, name: String, row: Int) raises -> Int:
    var idx = batch.schema.column_index(name)
    ref col = batch.column_at(idx)
    var arr = col.as_primitive[DType.int64]()
    return Int(arr._typed_ptr_ro().load[width=1](row))


def _is_null_at(batch: RecordBatch, name: String, row: Int) raises -> Bool:
    var idx = batch.schema.column_index(name)
    ref col = batch.column_at(idx)
    var arr = col.as_primitive[DType.int64]()
    return arr.is_null(row)


def test_inner_join_residual_filters_matched_pairs() raises:
    var probe = _l1_probe()
    var build = _l3_build()
    var op = _join_op(JOIN_INNER, _residual_neq_suppkey())
    var out = execute_residual_join_probe(probe, build, op, op.probe_residual.value())
    assert_equal(out.num_rows(), 3)
    assert_equal(out.num_columns(), 4)
    for r in range(out.num_rows()):
        assert_true(
            _col_at(out, "l_suppkey", r) != _col_at(out, "l_suppkey_right", r),
            "residual l_suppkey != l_suppkey_right must hold for every emitted row",
        )
        assert_equal(
            _col_at(out, "l_orderkey", r), _col_at(out, "l_orderkey_right", r),
        )


def test_left_join_residual_nullfills_failed_matches() raises:
    var probe = _l1_probe()
    var build = _l3_build()
    var op = _join_op(JOIN_LEFT, _residual_neq_suppkey())
    var out = execute_residual_join_probe(probe, build, op, op.probe_residual.value())
    assert_equal(out.num_rows(), 5)
    assert_equal(out.num_columns(), 4)
    var nullfill = 0
    var saw_ok2 = False
    var saw_ok3 = False
    for r in range(out.num_rows()):
        if _is_null_at(out, "l_orderkey_right", r):
            nullfill += 1
            assert_true(
                _is_null_at(out, "l_suppkey_right", r),
                "LEFT NULL-fill must NULL both right columns",
            )
            var lk = _col_at(out, "l_orderkey", r)
            if lk == 2:
                saw_ok2 = True
            if lk == 3:
                saw_ok3 = True
        else:
            assert_true(_col_at(out, "l_suppkey", r) != _col_at(out, "l_suppkey_right", r))
            assert_equal(_col_at(out, "l_orderkey", r), _col_at(out, "l_orderkey_right", r))
    assert_equal(nullfill, 2)
    assert_true(saw_ok2 and saw_ok3, "the two unmatched probe rows must appear NULL-filled")


def test_semi_join_residual_keeps_rows_with_passing_match() raises:
    var probe = _l1_probe()
    var build = _l3_build()
    var op = _join_op(JOIN_SEMI, _residual_neq_suppkey())
    var out = execute_residual_join_probe(probe, build, op, op.probe_residual.value())
    assert_equal(out.num_rows(), 2)
    assert_equal(out.num_columns(), 2)  # probe-only: l_orderkey, l_suppkey
    var seen_10 = False
    var seen_20 = False
    for r in range(out.num_rows()):
        assert_equal(_col_at(out, "l_orderkey", r), 1)
        var sk = _col_at(out, "l_suppkey", r)
        if sk == 10:
            seen_10 = True
        if sk == 20:
            seen_20 = True
    assert_true(seen_10 and seen_20)


def test_anti_join_residual_keeps_rows_without_passing_match() raises:
    var probe = _l1_probe()
    var build = _l3_build()
    var op = _join_op(JOIN_ANTI, _residual_neq_suppkey())
    var out = execute_residual_join_probe(probe, build, op, op.probe_residual.value())
    assert_equal(out.num_rows(), 2)
    assert_equal(out.num_columns(), 2)
    var seen_2 = False
    var seen_3 = False
    for r in range(out.num_rows()):
        var ok = _col_at(out, "l_orderkey", r)
        if ok == 2:
            seen_2 = True
            assert_equal(_col_at(out, "l_suppkey", r), 30)
        if ok == 3:
            seen_3 = True
            assert_equal(_col_at(out, "l_suppkey", r), 40)
    assert_true(seen_2 and seen_3)


def test_anti_join_residual_empty_build_keeps_all() raises:
    var probe = _l1_probe()
    var empty_build = _i64_batch_2("l_orderkey", List[Int](), "l_suppkey", List[Int]())
    var op = _join_op(JOIN_ANTI, _residual_neq_suppkey())
    var out = execute_residual_join_probe(probe, empty_build, op, op.probe_residual.value())
    assert_equal(out.num_rows(), 4)


def test_pure_range_nlj_band_join() raises:
    var orders = _i64_batch_2("order_date", [5, 15, 25], "amount", [100, 200, 300])
    var promo = _i64_batch_2("start_date", [10, 0], "end_date", [20, 30])
    var residual = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GE, Expr.col_ref("order_date"), Expr.col_ref("start_date")),
        Expr.binary(BIN_LE, Expr.col_ref("order_date"), Expr.col_ref("end_date")),
    )
    var op = _join_op(JOIN_INNER, residual^, with_equi=False)
    var out = execute_residual_join_probe(orders, promo, op, op.probe_residual.value())
    assert_equal(out.num_rows(), 4)
    assert_equal(out.num_columns(), 4)
    for r in range(out.num_rows()):
        var d = _col_at(out, "order_date", r)
        var s = _col_at(out, "start_date", r)
        var e = _col_at(out, "end_date", r)
        assert_true(d >= s and d <= e, "every NLJ-emitted row must satisfy the band predicate")


def main() raises:
    var suite = TestSuite()
    suite.test[test_inner_join_residual_filters_matched_pairs]()
    suite.test[test_left_join_residual_nullfills_failed_matches]()
    suite.test[test_semi_join_residual_keeps_rows_with_passing_match]()
    suite.test[test_anti_join_residual_keeps_rows_without_passing_match]()
    suite.test[test_anti_join_residual_empty_build_keeps_all]()
    suite.test[test_pure_range_nlj_band_join]()
    suite^.run()
