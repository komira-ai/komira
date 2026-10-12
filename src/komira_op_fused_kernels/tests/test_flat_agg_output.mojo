# =============================================================================
# build_flat_agg_output: a FlatHashAggregator's groups as a RecordBatch.
#
# The groups are fed by hand, so every expected value is known exactly. The
# checks are per group, looked up by key (the output order is the
# aggregator's), and cover each aggregate's column type for an integer and a
# floating output field (an INT32 field gets an INT32 column, never INT64
# data under an INT32 field), INT32 against INT64 keys, two-key groups, the
# truncation of a fractional sum into an INT64 field, the field names and
# metadata, an empty aggregator, and the raise for an unsupported aggregate.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatch, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator
from komira_plan_expr.agg_expr import (
    AggExpr,
    AGG_COUNT,
    AGG_COUNT_DISTINCT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
)
from komira_plan_ir.logical_plan import AggExprArray

from komira_op_fused_kernels.flat_agg_output import build_flat_agg_output


def _aggs(funcs: List[UInt8]) -> AggExprArray:
    var a = AggExprArray()
    for i in range(len(funcs)):
        a.append(AggExpr(funcs[i], None, None))
    return a^


def _schema(names: List[String], types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], False))
    return sb.build()


def _i64(b: RecordBatch, c: Int, r: Int) raises -> Int:
    assert_true(b.schema.field_arrow_type(c) == ArrowType.INT64)
    assert_true(b.column_at(c).arrow_type == ArrowType.INT64, "column type is not its field's")
    return Int(b.column_at(c).as_primitive[DType.int64]().get(r))


def _i32(b: RecordBatch, c: Int, r: Int) raises -> Int:
    assert_true(b.schema.field_arrow_type(c) == ArrowType.INT32)
    assert_true(b.column_at(c).arrow_type == ArrowType.INT32, "column type is not its field's")
    return Int(b.column_at(c).as_primitive[DType.int32]().get(r))


def _f64(b: RecordBatch, c: Int, r: Int) raises -> Float64:
    assert_true(b.schema.field_arrow_type(c) == ArrowType.FLOAT64)
    return Float64(b.column_at(c).as_primitive[DType.float64]().get(r))


def _row_of_key(b: RecordBatch, key: Int) raises -> Int:
    for r in range(b.num_rows()):
        var k: Int
        if b.schema.field_arrow_type(0) == ArrowType.INT32:
            k = Int(b.column_at(0).as_primitive[DType.int32]().get(r))
        else:
            k = Int(b.column_at(0).as_primitive[DType.int64]().get(r))
        if k == key:
            return r
    raise Error("no group with key " + String(key))


def _feed(mut agg: FlatHashAggregator, key: Int, value: Float64, num_aggs: Int):
    var e = agg.find_or_create_1(Int64(key))
    for a in range(num_aggs):
        agg._update_agg(e, a, value)


def test_single_key_every_aggregate() raises:
    # Group 7 gets 1.5, 4.0, -2.0; group 9 gets 10.0.
    var agg = FlatHashAggregator(num_keys=1, num_aggs=9, initial_capacity=16)
    _feed(agg, 7, 1.5, 9)
    _feed(agg, 7, 4.0, 9)
    _feed(agg, 7, -2.0, 9)
    _feed(agg, 9, 10.0, 9)
    var funcs: List[UInt8] = [
        AGG_SUM, AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MIN, AGG_MAX, AGG_MAX,
        AGG_MEAN, AGG_COUNT,
    ]
    var names: List[String] = [
        "k", "sum_i", "sum_f", "cnt", "min_i", "min_f", "max_i", "max_f",
        "avg", "cnt2",
    ]
    var types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.INT64, ArrowType.FLOAT64, ArrowType.INT64,
        ArrowType.INT32, ArrowType.FLOAT64, ArrowType.INT64, ArrowType.FLOAT64,
        ArrowType.FLOAT64, ArrowType.INT32,
    ]
    var key_types: List[UInt8] = [ArrowType.INT64.type_id]
    var got = build_flat_agg_output(
        agg, _aggs(funcs), _schema(names, types), 1, key_types
    )
    assert_equal(got.num_rows(), 2)
    assert_equal(got.num_columns(), 10)
    for c in range(10):
        assert_equal(got.schema.field_name(c), names[c])
    var r = _row_of_key(got, 7)
    # SUM 3.5 into an INT64 field truncates to 3; into FLOAT64 stays 3.5.
    assert_equal(_i64(got, 1, r), 3)
    assert_equal(_f64(got, 2, r), 3.5)
    assert_equal(_i64(got, 3, r), 3)
    # An INT32 output field gets an INT32 column (MIN here, COUNT below).
    assert_equal(_i32(got, 4, r), -2)
    assert_equal(_f64(got, 5, r), -2.0)
    assert_equal(_i64(got, 6, r), 4)
    assert_equal(_f64(got, 7, r), 4.0)
    assert_true(abs(_f64(got, 8, r) - 3.5 / 3.0) < 1e-12)
    assert_equal(_i32(got, 9, r), 3)
    var r9 = _row_of_key(got, 9)
    assert_equal(_i64(got, 1, r9), 10)
    assert_equal(_i64(got, 3, r9), 1)
    assert_equal(_f64(got, 8, r9), 10.0)


def test_int32_and_two_key_groups() raises:
    var agg = FlatHashAggregator(num_keys=2, num_aggs=1, initial_capacity=16)
    var e = agg.find_or_create_2(Int64(-3), Int64(1) << 40)
    agg._update_count_only(e, 0)
    var e2 = agg.find_or_create_2(Int64(-3), Int64(1) << 40)
    agg._update_count_only(e2, 0)
    var e3 = agg.find_or_create_2(Int64(5), Int64(6))
    agg._update_count_only(e3, 0)
    var funcs: List[UInt8] = [AGG_COUNT]
    var names: List[String] = ["k0", "k1", "n"]
    var types: List[ArrowType] = [ArrowType.INT32, ArrowType.INT64, ArrowType.INT64]
    var key_types: List[UInt8] = [ArrowType.INT32.type_id, ArrowType.INT64.type_id]
    var got = build_flat_agg_output(
        agg, _aggs(funcs), _schema(names, types), 2, key_types
    )
    assert_equal(got.num_rows(), 2)
    var r = _row_of_key(got, -3)
    assert_true(got.column_at(0).arrow_type == ArrowType.INT32)
    assert_equal(_i64(got, 1, r), Int(Int64(1) << 40))
    assert_equal(_i64(got, 2, r), 2)
    var r5 = _row_of_key(got, 5)
    assert_equal(_i64(got, 1, r5), 6)
    assert_equal(_i64(got, 2, r5), 1)


def test_field_metadata_is_kept() raises:
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    _feed(agg, 1, 2.0, 1)
    var sb = SchemaBuilder()
    var fk = Field("k", ArrowType.INT64, False)
    fk.set_metadata("role", "key")
    sb.add_field(fk^)
    var fs = Field("s", ArrowType.FLOAT64, True)
    fs.set_metadata("role", "sum")
    sb.add_field(fs^)
    var funcs: List[UInt8] = [AGG_SUM]
    var key_types: List[UInt8] = [ArrowType.INT64.type_id]
    var got = build_flat_agg_output(agg, _aggs(funcs), sb.build(), 1, key_types)
    assert_equal(got.schema.field_at(0).get_metadata("role").value(), "key")
    assert_equal(got.schema.field_at(1).get_metadata("role").value(), "sum")
    assert_true(got.schema.field_nullable(1))


def test_empty_aggregator() raises:
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    var funcs: List[UInt8] = [AGG_MAX]
    var names: List[String] = ["k", "m"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.FLOAT64]
    var key_types: List[UInt8] = [ArrowType.INT64.type_id]
    var got = build_flat_agg_output(
        agg, _aggs(funcs), _schema(names, types), 1, key_types
    )
    assert_equal(got.num_rows(), 0)
    assert_equal(got.num_columns(), 2)


def test_unsupported_aggregate_raises() raises:
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    _feed(agg, 1, 2.0, 1)
    var funcs: List[UInt8] = [AGG_COUNT_DISTINCT]
    var names: List[String] = ["k", "d"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    var key_types: List[UInt8] = [ArrowType.INT64.type_id]
    var raised = False
    try:
        _ = build_flat_agg_output(
            agg, _aggs(funcs), _schema(names, types), 1, key_types
        )
    except e:
        raised = True
        assert_true("unsupported" in String(e), String(e))
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
