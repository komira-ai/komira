# =============================================================================
# Unit tests for typed_projects.mojo (ProjectList[*Outs]) and the RowTransform
# default bodies the ExprX traits supply (expr_x.mojo)
# =============================================================================
#
# What the tests prove:
#   - ProjectList.emit_projected builds one output column per `Outs[k]`, in
#     pack order, named `out{k}`, typed from `dtype_at[0]()` (numeric) or
#     STRING (`out_kind_at[0]() == SinkKind.STRING`), non-nullable, with one
#     row per survivor taken from that survivor's input row.
#   - ProjectList.bind reaches every stored output: each test leaf starts
#     on column 0 (`a`, a decoy whose values no expectation uses) and only
#     bind moves it to its named column, so a skipped output reads `a`.
#   - The ExprX trait defaults (out_kind_at / dtype_at / write_one /
#     project_one for I64, F64, F32, I32 and String) land the conformer's
#     value in the slot they are asked for.
#
# Input batch (all expectations are read off these lists by hand):
#   a = [-1, -1, -1, -1, -1]
#   x = [10, 20, 30, 40, 50]
#   y = [ 5,  4,  3,  2,  1]
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.multi_column_builder import (
    MultiColumnBuilder,
    ColumnSlot,
    SinkKind,
    StringColumnSlot,
    column_slot,
    string_column_slot,
)
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_plan_expr.expr import Expr
from komira_udf.column_resolver import ColumnResolver
from komira_expr.expr_x import ExprXI64, ExprXF64, ExprXF32, ExprXI32, ExprXString
from komira_expr.typed_projects import ProjectList


def _batch() raises -> RecordBatch:
    var a = List[Scalar[DType.int64]]()
    var x = List[Scalar[DType.int64]]()
    var y = List[Scalar[DType.int64]]()
    for i in range(5):
        a.append(Scalar[DType.int64](-1))
        x.append(Scalar[DType.int64](Int64(10 * (i + 1))))
        y.append(Scalar[DType.int64](Int64(5 - i)))
    var schema = Schema.from_fields_3(
        Field("a", DType.int64, False),
        Field("x", DType.int64, False),
        Field("y", DType.int64, False),
    )
    return RecordBatch.from_typed_columns_3(
        schema^,
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(a^)
        ),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(x^)
        ),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(y^)
        ),
    )


@always_inline
def _read[bo: Origin[mut=False]](batch: BatchView[bo], idx: Int, i: Int) -> Int64:
    return batch.col_i64(idx).load[1](i)[0]


# --- test leaves: each reads an Int64 column found by name at bind ----------


struct LeafI64[name: StringLiteral](ExprXI64):
    """The column's value."""

    var _idx: Int

    def __init__(out self):
        self._idx = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int64, W]:
        return batch.col_i64(self._idx).load[W](i)

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int64:
        return _read(batch, self._idx, i)

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("LeafI64.to_expr: not needed"))


struct QuarterF64[name: StringLiteral](ExprXF64):
    """The column's value divided by 4.0 (exact in binary)."""

    var _idx: Int

    def __init__(out self):
        self._idx = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float64, W]:
        return batch.col_i64(self._idx).load[W](i).cast[DType.float64]() / 4.0

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float64:
        return Float64(_read(batch, self._idx, i)) / 4.0

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("QuarterF64.to_expr: not needed"))


struct NegF32[name: StringLiteral](ExprXF32):
    """The column's value negated, as Float32."""

    var _idx: Int

    def __init__(out self):
        self._idx = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.float32, W]:
        return -batch.col_i64(self._idx).load[W](i).cast[DType.float32]()

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Float32:
        return -Float32(_read(batch, self._idx, i))

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("NegF32.to_expr: not needed"))


struct PlusI32[name: StringLiteral](ExprXI32):
    """The column's value plus 100, as Int32."""

    var _idx: Int

    def __init__(out self):
        self._idx = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))

    def eval_simd[
        W: Int, bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> SIMD[DType.int32, W]:
        return batch.col_i64(self._idx).load[W](i).cast[DType.int32]() + 100

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> Int32:
        return Int32(_read(batch, self._idx, i)) + 100

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("PlusI32.to_expr: not needed"))


struct TagStr[name: StringLiteral](ExprXString):
    """"<name>=<value>" for the column's value."""

    var _idx: Int

    def __init__(out self):
        self._idx = 0

    def bind(mut self, resolver: ColumnResolver) raises:
        self._idx = resolver.index_for(String(Self.name))

    def eval_scalar_s[
        bo: Origin[mut=False]
    ](self, batch: BatchView[bo], i: Int) -> String:
        return String(Self.name) + "=" + String(_read(batch, self._idx, i))

    @staticmethod
    def depth() -> Int:
        return 1

    @staticmethod
    def to_expr() raises -> Expr:
        raise Error(String("TagStr.to_expr: not needed"))


comptime Five = ProjectList[
    LeafI64["y"], QuarterF64["x"], NegF32["x"], PlusI32["y"], TagStr["x"]
]


def _five() -> Five:
    return Five(
        LeafI64["y"](), QuarterF64["x"](), NegF32["x"](), PlusI32["y"](), TagStr["x"]()
    )


def _survivors_1_3_4() -> List[Int]:
    var s = List[Int]()
    s.append(1)
    s.append(3)
    s.append(4)
    return s^


# =============================================================================
# ProjectList
# =============================================================================


def test_arity_and_pdescribe() raises:
    assert_equal(Five.arity(), 5)
    assert_equal(Five.pdescribe(), 5)
    assert_equal(ProjectList[LeafI64["y"]].arity(), 1)
    assert_equal(ProjectList[LeafI64["y"]].pdescribe(), 1)


def test_emit_projected_mixed_pack() raises:
    """Survivors [1, 3, 4] (x = 20, 40, 50; y = 4, 2, 1) through five
    outputs of five kinds, after one bind."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var p = _five()
    p.bind(ColumnResolver.from_arrow_schema(batch.schema))
    var rb = p.emit_projected(bv, _survivors_1_3_4())

    assert_equal(rb.num_columns(), 5)
    assert_equal(rb.num_rows(), 3)
    for k in range(5):
        assert_equal(rb.schema.field_name(k), String("out", k))
        assert_false(rb.schema.field_nullable(k))
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(rb.schema.field_arrow_type(1) == ArrowType.FLOAT64)
    assert_true(rb.schema.field_arrow_type(2) == ArrowType.FLOAT32)
    assert_true(rb.schema.field_arrow_type(3) == ArrowType.INT32)
    assert_true(rb.schema.field_arrow_type(4) == ArrowType.STRING)

    var c0 = rb.column_as_primitive_int64(0)
    assert_equal(c0.get(0), Int64(4))
    assert_equal(c0.get(1), Int64(2))
    assert_equal(c0.get(2), Int64(1))
    var c1 = rb.column_as_primitive_float64(1)
    assert_equal(c1.get(0), 5.0)
    assert_equal(c1.get(1), 10.0)
    assert_equal(c1.get(2), 12.5)
    var c2 = rb.column_as_primitive_float32(2)
    assert_equal(c2.get(0), Float32(-20.0))
    assert_equal(c2.get(1), Float32(-40.0))
    assert_equal(c2.get(2), Float32(-50.0))
    var c3 = rb.column_as_primitive_int32(3)
    assert_equal(c3.get(0), Int32(104))
    assert_equal(c3.get(1), Int32(102))
    assert_equal(c3.get(2), Int32(101))
    var c4 = rb.column_as_string(4)
    assert_equal(len(c4), 3)
    assert_equal(c4.get(0), "x=20")
    assert_equal(c4.get(1), "x=40")
    assert_equal(c4.get(2), "x=50")


def test_emit_projected_without_bind_reads_decoy() raises:
    """The control for the bind assertions above: unbound, every leaf reads
    column `a` (-1), so out0 is -1 where the bound run gave 4."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var p = ProjectList[LeafI64["y"], TagStr["x"]](LeafI64["y"](), TagStr["x"]())
    var rb = p.emit_projected(bv, _survivors_1_3_4())
    assert_equal(rb.column_as_primitive_int64(0).get(0), Int64(-1))
    assert_equal(rb.column_as_string(1).get(0), "x=-1")


def test_emit_projected_no_survivors() raises:
    """An empty survivor list gives the full schema and zero rows."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var p = _five()
    p.bind(ColumnResolver.from_arrow_schema(batch.schema))
    var rb = p.emit_projected(bv, List[Int]())
    assert_equal(rb.num_columns(), 5)
    assert_equal(rb.num_rows(), 0)
    assert_equal(rb.column_length(0), 0)
    assert_equal(rb.column_length(4), 0)
    assert_true(rb.schema.field_arrow_type(4) == ArrowType.STRING)


# =============================================================================
# ExprX RowTransform defaults
# =============================================================================


def test_out_kind_and_dtype_defaults() raises:
    assert_true(LeafI64["y"].out_kind_at[0]() == SinkKind.NUMERIC)
    assert_true(QuarterF64["x"].out_kind_at[0]() == SinkKind.NUMERIC)
    assert_true(NegF32["x"].out_kind_at[0]() == SinkKind.NUMERIC)
    assert_true(PlusI32["y"].out_kind_at[0]() == SinkKind.NUMERIC)
    assert_true(TagStr["x"].out_kind_at[0]() == SinkKind.STRING)
    assert_true(LeafI64["y"].dtype_at[0]() == DType.int64)
    assert_true(QuarterF64["x"].dtype_at[0]() == DType.float64)
    assert_true(NegF32["x"].dtype_at[0]() == DType.float32)
    assert_true(PlusI32["y"].dtype_at[0]() == DType.int32)
    # The documented STRING placeholder.
    assert_true(TagStr["x"].dtype_at[0]() == DType.uint8)


def test_write_one_defaults_land_in_slot_zero() raises:
    """write_one writes the row's value into slot 0 of the builder."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var resolver = ColumnResolver.from_arrow_schema(batch.schema)

    var li = LeafI64["y"]()
    li.bind(resolver)
    var bi = MultiColumnBuilder[ColumnSlot[DType.int64]](column_slot[DType.int64](1))
    li.write_one(bv, 2, bi)
    assert_equal(
        bi.finalize_at[0]().as_primitive[DType.int64]().get(0),
        Int64(3),
    )

    var hf = QuarterF64["x"]()
    hf.bind(resolver)
    var bf = MultiColumnBuilder[ColumnSlot[DType.float64]](
        column_slot[DType.float64](1)
    )
    hf.write_one(bv, 2, bf)
    assert_equal(
        bf.finalize_at[0]().as_primitive[DType.float64]().get(0),
        7.5,
    )

    var nf = NegF32["x"]()
    nf.bind(resolver)
    var bf32 = MultiColumnBuilder[ColumnSlot[DType.float32]](
        column_slot[DType.float32](1)
    )
    nf.write_one(bv, 0, bf32)
    assert_equal(
        bf32.finalize_at[0]().as_primitive[DType.float32]().get(0),
        Float32(-10.0),
    )

    var pi = PlusI32["y"]()
    pi.bind(resolver)
    var bi32 = MultiColumnBuilder[ColumnSlot[DType.int32]](
        column_slot[DType.int32](1)
    )
    pi.write_one(bv, 4, bi32)
    assert_equal(
        bi32.finalize_at[0]().as_primitive[DType.int32]().get(0),
        Int32(101),
    )

    var ts = TagStr["x"]()
    ts.bind(resolver)
    var bs = MultiColumnBuilder[StringColumnSlot](string_column_slot(1))
    ts.write_one(bv, 4, bs)
    var sa = bs.finalize_at[0]().as_string()
    assert_equal(len(sa), 1)
    assert_equal(sa.get(0), "x=50")


def test_project_one_honours_destination_slot() raises:
    """project_one[dst_k=1] lands in slot 1 and leaves slot 0 empty."""
    var batch = _batch()
    var bv = batch_view_over(batch)
    var resolver = ColumnResolver.from_arrow_schema(batch.schema)
    var li = LeafI64["x"]()
    li.bind(resolver)
    var b = MultiColumnBuilder[ColumnSlot[DType.int64], ColumnSlot[DType.int64]](
        column_slot[DType.int64](1), column_slot[DType.int64](1)
    )
    li.project_one[dst_k=1](bv, 3, b)
    assert_equal(b.length_at[0](), 0)
    assert_equal(b.length_at[1](), 1)
    assert_equal(
        b.finalize_at[1]().as_primitive[DType.int64]().get(0),
        Int64(40),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
