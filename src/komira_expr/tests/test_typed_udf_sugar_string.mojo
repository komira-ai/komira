# =============================================================================
# typed_udf_sugar.mojo: MapXString, SumOf2.update_scalar and the derived-id
# helpers at run time (test_typed_udf_sugar.mojo covers Map1 / Map2 / SumOf2
# update / merge / finalize and the comptime UDF_IDs)
# =============================================================================
#
# What each test proves:
#   - MapXString reads its bound column with the accessor its `in_dtype`
#     names (float64, int64, int32, float32), builds the customer's one-field
#     row, calls the customer's def and returns that row's String. Each def
#     maps distinct inputs to distinct labels, so a wrong row, column or
#     accessor reads as a wrong label.
#   - MapXString.bind resolves `in0` by name and refuses a column whose
#     ArrowType is not `in_dtype`'s, with its documented message.
#   - SumOf2.update_scalar folds the same values `update` does.
#   - `_fnv1a` is FNV-1a 32 (published vectors), and the run-time udf_id_1 /
#     udf_id_2 equal the value folded by hand from that definition.
#
# Batch (expectations read off it):
#   price f64 = [50.0, 150.0, 100.0]
#   n     i64 = [1, -1, 0]
#   k     i32 = [7, 8, 9]
#   w     f32 = [0.5, -0.5, 2.0]
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_udf.column_resolver import ColumnResolver
from komira_udf.schema_descriptor import DT_F64, DT_I64, DT_BOOL
from komira_expr.typed_udf_sugar import (
    MapXString,
    SumOf2,
    Row2,
    _fnv1a,
    _dtag_of_dtype,
    udf_id_1,
    udf_id_2,
)


@fieldwise_init
struct F64Row(Copyable, Movable):
    var v: Float64


@fieldwise_init
struct I64Row(Copyable, Movable):
    var v: Int64


@fieldwise_init
struct I32Row(Copyable, Movable):
    var v: Int32


@fieldwise_init
struct F32Row(Copyable, Movable):
    var v: Float32


@fieldwise_init
struct Label(Copyable, Movable):
    var text: String


def grade_of(row: F64Row) -> Label:
    if row.v >= 100.0:
        return Label(String("gold"))
    return Label(String("standard"))


def sign_of(row: I64Row) -> Label:
    if row.v > 0:
        return Label(String("pos"))
    if row.v < 0:
        return Label(String("neg"))
    return Label(String("zero"))


def parity_of(row: I32Row) -> Label:
    if row.v % 2 == 0:
        return Label(String("even"))
    return Label(String("odd"))


def size_of_w(row: F32Row) -> Label:
    if row.v < 0:
        return Label(String("neg"))
    if row.v > 1:
        return Label(String("big"))
    return Label(String("small"))


comptime Grade = MapXString[f=grade_of, in0="price", in_dtype=DType.float64]
comptime Sign = MapXString[f=sign_of, in0="n", in_dtype=DType.int64]
comptime Parity = MapXString[f=parity_of, in0="k", in_dtype=DType.int32]
comptime SizeW = MapXString[f=size_of_w, in0="w", in_dtype=DType.float32]


def _batch() raises -> RecordBatch:
    var price = List[Scalar[DType.float64]]()
    price.append(50.0)
    price.append(150.0)
    price.append(100.0)
    var n = List[Scalar[DType.int64]]()
    n.append(1)
    n.append(-1)
    n.append(0)
    var k = List[Scalar[DType.int32]]()
    k.append(7)
    k.append(8)
    k.append(9)
    var w = List[Scalar[DType.float32]]()
    w.append(0.5)
    w.append(-0.5)
    w.append(2.0)
    var sb = SchemaBuilder()
    sb.add_field(Field("price", DType.float64, False))
    sb.add_field(Field("n", DType.int64, False))
    sb.add_field(Field("k", DType.int32, False))
    sb.add_field(Field("w", DType.float32, False))
    return RecordBatch.from_typed_columns_4(
        sb.build(),
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(price^)
        ),
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(n^)
        ),
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(k^)
        ),
        Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].from_list(w^)
        ),
    )


# =============================================================================
# MapXString
# =============================================================================


def test_map_x_string_float64() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var m = Grade()
    assert_equal(m._idx, -1)
    m.bind(ColumnResolver.from_arrow_schema(batch.schema))
    assert_equal(m._idx, 0)
    assert_equal(m.eval_scalar_s(bv, 0), "standard")
    assert_equal(m.eval_scalar_s(bv, 1), "gold")
    assert_equal(m.eval_scalar_s(bv, 2), "gold")


def test_map_x_string_int64() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var m = Sign()
    m.bind(ColumnResolver.from_arrow_schema(batch.schema))
    assert_equal(m._idx, 1)
    assert_equal(m.eval_scalar_s(bv, 0), "pos")
    assert_equal(m.eval_scalar_s(bv, 1), "neg")
    assert_equal(m.eval_scalar_s(bv, 2), "zero")


def test_map_x_string_int32() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var m = Parity()
    m.bind(ColumnResolver.from_arrow_schema(batch.schema))
    assert_equal(m._idx, 2)
    assert_equal(m.eval_scalar_s(bv, 0), "odd")
    assert_equal(m.eval_scalar_s(bv, 1), "even")
    assert_equal(m.eval_scalar_s(bv, 2), "odd")


def test_map_x_string_float32() raises:
    var batch = _batch()
    var bv = batch_view_over(batch)
    var m = SizeW()
    m.bind(ColumnResolver.from_arrow_schema(batch.schema))
    assert_equal(m._idx, 3)
    assert_equal(m.eval_scalar_s(bv, 0), "small")
    assert_equal(m.eval_scalar_s(bv, 1), "neg")
    assert_equal(m.eval_scalar_s(bv, 2), "big")


def test_map_x_string_bind_refuses_wrong_arrow_type() raises:
    """`price` is float64; a transform declaring int64 for it is refused."""
    var batch = _batch()
    var m = MapXString[f=sign_of, in0="price", in_dtype=DType.int64]()
    var msg = String("")
    try:
        m.bind(ColumnResolver.from_arrow_schema(batch.schema))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "MapXString[in0=\"price\"].bind: file's ArrowType is float64,"
        " expected int64 (the declared `in_dtype`)",
    )


def test_map_x_string_depth_and_to_expr() raises:
    assert_equal(Grade.depth(), 1)
    var msg = String("")
    try:
        _ = Grade.to_expr()
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "MapXString.to_expr: a customer Mojo function has no runtime-Expr"
        " equivalent. The typed path emits this transform directly; there"
        " is nothing to lower.",
    )


# =============================================================================
# SumOf2.update_scalar
# =============================================================================


def mul(a: Int64, b: Int64) -> Int64:
    return a * b


comptime SumMul = SumOf2[f=mul, out_name="s", in0="a", in1="b"]


def test_sum_of2_update_scalar_matches_update() raises:
    """3*4 + 5*(-2) = 2 by update_scalar; the same rows by update agree."""
    var agg = SumMul()
    var s = agg.init()
    agg.update_scalar(s, Int64(3), Int64(4))
    agg.update_scalar(s, Int64(5), Int64(-2))
    assert_equal(agg.finalize(s), Int64(2))
    var t = agg.init()
    agg.update(t, Row2[Int64, Int64](3, 4))
    agg.update(t, Row2[Int64, Int64](5, -2))
    assert_equal(agg.finalize(t), agg.finalize(s))


# =============================================================================
# Derived ids at run time
# =============================================================================


def test_fnv1a_published_vectors() raises:
    assert_equal(_fnv1a(StringSlice("")), UInt32(0x811C9DC5))
    assert_equal(_fnv1a(StringSlice("a")), UInt32(0xE40C292C))
    assert_equal(_fnv1a(StringSlice("foobar")), UInt32(0xBF9CF968))


def test_udf_ids_at_run_time() raises:
    """10000 + (fnv(out) ^ fnv(in0)*31 [^ fnv(in1)*131]) mod 4294957295,
    32-bit wrapping products, folded by hand."""
    assert_equal(udf_id_1["y", "a"](), UInt32(1635047856))
    assert_equal(udf_id_2["o", "p", "q"](), UInt32(2755011979))


def test_dtag_of_dtype_forwards() raises:
    assert_equal(_dtag_of_dtype(DType.float64), DT_F64)
    assert_equal(_dtag_of_dtype(DType.int64), DT_I64)
    assert_equal(_dtag_of_dtype(DType.bool), DT_BOOL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
