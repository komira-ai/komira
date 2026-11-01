# The residual join's late materialisation: only the columns the predicate
# names are assembled (counted by `residual_latemat_counter`), and the rows
# equal the eager full assembly's for INNER, LEFT, SEMI and ANTI.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.expr import Expr, BIN_AND, BIN_GT, BIN_LT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    JOIN_INNER, JOIN_LEFT, JOIN_SEMI, JOIN_ANTI,
)
from komira_physical_plan.physical_plan import MorselOp

from komira_op_join_probe.nested_loop_join import execute_residual_join_probe
from komira_op_join_probe.residual_latemat_counter import (
    residual_mask_assembled_cells,
    reset_residual_mask_assembled_cells,
)


def _i64_arr(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int64](values[i]))
    return arr^


def _i64_batch_4(
    n0: String, v0: List[Int], n1: String, v1: List[Int],
    n2: String, v2: List[Int], n3: String, v3: List[Int],
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(n0, ArrowType.INT64, False))
    sb.add_field(Field(n1, ArrowType.INT64, False))
    sb.add_field(Field(n2, ArrowType.INT64, False))
    sb.add_field(Field(n3, ArrowType.INT64, False))
    var schema = sb.build()
    var rb = RecordBatchBuilder.with_capacity(4)
    rb.add_column(Column.from_primitive[DType.int64](_i64_arr(v0)^))
    rb.add_column(Column.from_primitive[DType.int64](_i64_arr(v1)^))
    rb.add_column(Column.from_primitive[DType.int64](_i64_arr(v2)^))
    rb.add_column(Column.from_primitive[DType.int64](_i64_arr(v3)^))
    return rb.build(schema^)


def _probe() raises -> RecordBatch:
    return _i64_batch_4(
        "pk", [1, 1, 2, 3], "pa", [10, 20, 30, 40],
        "pb", [100, 200, 300, 400], "pc", [5, 6, 7, 8],
    )


def _build() raises -> RecordBatch:
    return _i64_batch_4(
        "bk", [1, 1, 2], "ba", [1, 2, 3], "bb", [7, 8, 9], "bc", [0, 0, 0],
    )


def _residual_pa_bb() -> Expr:
    return Expr.binary(
        BIN_AND,
        Expr.binary(BIN_GT, Expr.col_ref("pa"), Expr.literal(ScalarValue.from_int64(15))),
        Expr.binary(BIN_LT, Expr.col_ref("bb"), Expr.literal(ScalarValue.from_int64(9))),
    )


def _op(join_type: UInt8, var residual: Expr) -> MorselOp:
    var lk = List[String]()
    var rk = List[String]()
    lk.append("pk")
    rk.append("bk")
    var no_cols: Optional[List[String]] = None
    return MorselOp.join_probe_with_residual(
        -1, lk^, rk^, join_type, residual^, no_cols^,
    )


def _run(join_type: UInt8, late_mat: Bool = True) raises -> RecordBatch:
    """`late_mat=True` (default) = the production late-materializing arm;
    `late_mat=False` = the EAGER full-assembly oracle.
    """
    var probe = _probe()
    var build = _build()
    var op = _op(join_type, _residual_pa_bb())
    return execute_residual_join_probe(
        probe, build, op, op.probe_residual.value(), late_mat
    )


def _batches_equal(a: RecordBatch, b: RecordBatch) raises -> Bool:
    if a.num_rows() != b.num_rows():
        return False
    if a.num_columns() != b.num_columns():
        return False
    for c in range(a.num_columns()):
        if a.schema.field_name(c) != b.schema.field_name(c):
            return False
        ref ca = a.column_at(c)
        ref cb = b.column_at(c)
        var aa = ca.as_primitive[DType.int64]()
        var ba = cb.as_primitive[DType.int64]()
        for r in range(a.num_rows()):
            if aa.is_null(r) != ba.is_null(r):
                return False
            if not aa.is_null(r):
                if aa._typed_ptr_ro().load[width=1](r) != ba._typed_ptr_ro().load[width=1](r):
                    return False
    return True


def test_latemat_assembles_fewer_cells_than_eager() raises:
    comptime N_CAND = 5
    comptime RESIDUAL_COLS = 2
    comptime TOTAL_COLS = 8

    reset_residual_mask_assembled_cells()
    var out_late = _run(JOIN_INNER)
    var late_cells = residual_mask_assembled_cells()

    reset_residual_mask_assembled_cells()
    var out_eager = _run(JOIN_INNER, late_mat=False)
    var eager_cells = residual_mask_assembled_cells()

    assert_equal(late_cells, N_CAND * RESIDUAL_COLS)
    assert_equal(eager_cells, N_CAND * TOTAL_COLS)
    assert_true(
        late_cells < eager_cells,
        "late-mat must assemble strictly fewer residual-mask cells than eager",
    )

    assert_equal(out_late.num_rows(), 2)
    assert_equal(out_eager.num_rows(), 2)


def _assert_mode_byte_equiv(join_type: UInt8, expect_rows: Int) raises:
    var out_late = _run(join_type)
    var out_eager = _run(join_type, late_mat=False)
    assert_equal(out_late.num_rows(), expect_rows)
    assert_true(
        _batches_equal(out_late, out_eager),
        "late-mat result must be byte-identical to the eager full-assembly result",
    )


def test_latemat_inner_byte_equiv() raises:
    _assert_mode_byte_equiv(JOIN_INNER, 2)


def test_latemat_left_nullfill_byte_equiv() raises:
    _assert_mode_byte_equiv(JOIN_LEFT, 5)
    var out = _run(JOIN_LEFT)
    var nullfill = 0
    var idx_bk = out.schema.column_index("bk")
    ref col_bk = out.column_at(idx_bk)
    var arr_bk = col_bk.as_primitive[DType.int64]()
    for r in range(out.num_rows()):
        if arr_bk.is_null(r):
            nullfill += 1
    assert_equal(nullfill, 3)


def test_latemat_semi_byte_equiv() raises:
    _assert_mode_byte_equiv(JOIN_SEMI, 1)


def test_latemat_anti_byte_equiv() raises:
    _assert_mode_byte_equiv(JOIN_ANTI, 3)


def test_latemat_pure_range_nlj_byte_equiv() raises:
    var probe = _probe()
    var build = _build()
    var residual = _residual_pa_bb()
    var lk = List[String]()
    var rk = List[String]()
    var no_cols: Optional[List[String]] = None
    var op = MorselOp.join_probe_with_residual(
        -1, lk^, rk^, JOIN_INNER, residual^, no_cols^,
    )

    reset_residual_mask_assembled_cells()
    var out_late = execute_residual_join_probe(
        probe, build, op, op.probe_residual.value()
    )
    var late_cells = residual_mask_assembled_cells()

    var probe2 = _probe()
    var build2 = _build()
    var residual2 = _residual_pa_bb()
    var lk2 = List[String]()
    var rk2 = List[String]()
    var no_cols2: Optional[List[String]] = None
    var op2 = MorselOp.join_probe_with_residual(
        -1, lk2^, rk2^, JOIN_INNER, residual2^, no_cols2^,
    )
    reset_residual_mask_assembled_cells()
    var out_eager = execute_residual_join_probe(
        probe2, build2, op2, op2.probe_residual.value(), False
    )
    var eager_cells = residual_mask_assembled_cells()

    assert_equal(late_cells, 12 * 2)
    assert_equal(eager_cells, 12 * 8)
    assert_true(_batches_equal(out_late, out_eager))


def main() raises:
    var suite = TestSuite()
    suite.test[test_latemat_assembles_fewer_cells_than_eager]()
    suite.test[test_latemat_inner_byte_equiv]()
    suite.test[test_latemat_left_nullfill_byte_equiv]()
    suite.test[test_latemat_semi_byte_equiv]()
    suite.test[test_latemat_anti_byte_equiv]()
    suite.test[test_latemat_pure_range_nlj_byte_equiv]()
    suite^.run()
