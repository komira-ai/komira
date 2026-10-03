# =============================================================================
# Trait conformance across the precompiled-package boundary
# =============================================================================
#
# komira_eval defines 64 expression structs (`ColXI64`, `GtXI64`, ...) that
# conform to the `ExprXBool` / `ExprXI64` / ... traits declared here, in
# komira_expr. Those traits refine `Predicate` / `RowTransform`, which live in
# a third package, komira_udf. So the conformance chain crosses two .mojoc
# boundaries: executor -> komira_expr -> komira_udf.
#
# This file is the falsifier for that chain. The two structs below are defined
# in the test file, OUTSIDE every precompiled package, exactly like the
# executor's conformers; each is passed through a generic function bounded on
# the trait and run. It fails to compile if conformance breaks (a required
# member added to a trait, a default body moved or dropped, a parent trait
# changed) and fails at run time if a default body inherited from a parent
# package stops forwarding to the conformer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections import batch_view_over
from komira_core.collections.batch_view import BatchView
from komira_core.plan.expr import Expr
from komira_expr.expr_x import ExprXBool, ExprXI64
from komira_udf.predicate import Predicate
from komira_udf.row_transform import RowTransform


struct ProbeXBool[keep: Bool](ExprXBool):
    """Constant boolean; parametric on purpose (the executor's are too)."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.bool, W]:
        return SIMD[DType.bool, W](fill=Self.keep)

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Bool:
        return Self.keep

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("ProbeXBool.to_expr: not needed"))


struct ProbeXI64[v: Int](ExprXI64):
    """Constant Int64; the value is a type parameter."""

    def __init__(out self):
        pass

    @always_inline
    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int64, W]:
        return SIMD[DType.int64, W](Int64(Self.v))

    @always_inline
    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int64:
        return Int64(Self.v)

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("ProbeXI64.to_expr: not needed"))


def _bool_through_expr_trait[
    E: ExprXBool, bo: Origin[mut=False]
](mut e: E, batch: BatchView[bo]) raises -> Bool:
    """Drives the ExprXBool surface and the Predicate parent default."""
    var simd = e.eval_simd[4](batch, 0)
    assert_equal(Bool(simd[0]), Bool(simd[3]))
    assert_equal(e.eval_scalar_s[bo](batch, 0), Bool(simd[0]))
    # `Predicate.eval_scalar` is a default body in komira_expr that forwards
    # to the conformer; its trait lives in komira_udf.
    return e.eval_scalar[bo](batch, 0)


def _bool_through_predicate[
    P: Predicate, bo: Origin[mut=False]
](mut p: P, batch: BatchView[bo]) raises -> Bool:
    """The conformer used only as the komira_udf parent trait."""
    return p.eval_scalar[bo](batch, 0)


def _i64_through_expr_trait[
    E: ExprXI64, bo: Origin[mut=False]
](mut e: E, batch: BatchView[bo]) raises -> Int64:
    var simd = e.eval_simd[4](batch, 0)
    assert_equal(simd[0], simd[3])
    assert_equal(e.eval_scalar_s[bo](batch, 0), simd[0])
    return e.eval_scalar_s[bo](batch, 0)


def _i64_dtype_through_row_transform[R: RowTransform]() -> DType:
    """The conformer used only as the komira_udf parent trait."""
    return R.dtype_at[0]()


def _batch() raises -> RecordBatch:
    var vals = List[Scalar[DType.int64]]()
    for i in range(8):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def test_expr_x_bool_conformer_across_boundary() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var yes = ProbeXBool[True]()
    var no = ProbeXBool[False]()
    assert_true(_bool_through_expr_trait(yes, bv))
    assert_equal(_bool_through_expr_trait(no, bv), False)
    assert_equal(ProbeXBool[True].depth(), 1)


def test_expr_x_bool_conformer_as_udf_predicate() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var yes = ProbeXBool[True]()
    var no = ProbeXBool[False]()
    assert_true(_bool_through_predicate(yes, bv))
    assert_equal(_bool_through_predicate(no, bv), False)


def test_expr_x_i64_conformer_across_boundary() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var seven = ProbeXI64[7]()
    assert_equal(_i64_through_expr_trait(seven, bv), Int64(7))
    var neg = ProbeXI64[-3]()
    assert_equal(_i64_through_expr_trait(neg, bv), Int64(-3))


def test_expr_x_i64_conformer_as_udf_row_transform() raises:
    # Defaults declared in komira_expr, required by a trait in komira_udf.
    assert_true(_i64_dtype_through_row_transform[ProbeXI64[1]]() == DType.int64)
    assert_equal(ProbeXI64[1].ARITY, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
