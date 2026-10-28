# =============================================================================
# flat_agg_output -- a FlatHashAggregator's groups as a RecordBatch
# =============================================================================
#
# `build_flat_agg_output` emits one row per group of a `FlatHashAggregator`:
# the group's keys, then one column per aggregate, in the aggregator's
# iteration order (no ORDER BY is implied). The output fields are the
# caller's `output_schema` fields, metadata included.
#
# The column types follow from the aggregator's accumulators, which hold a
# Float64 sum, min and max and an Int64 count per aggregate. Each column's
# type is the one its output field names, and a field type the function does
# not produce for that column raises:
#
#   key k        INT32 or INT64, equal to `key_types[k]` and to the field
#   SUM          FLOAT64, INT64 or INT32 (the Float64 sum truncated toward
#                zero for the integer types)
#   MIN / MAX    likewise
#   COUNT        INT64 or INT32
#   MEAN         FLOAT64
#
# The integer outputs of SUM, MIN and MAX go through the Float64 accumulator,
# so they are exact only up to 2^53; a value that is NaN, infinite (MIN or MAX
# of a group that saw no value) or outside the output type's range raises.
# Any other aggregate raises. NULLs are not represented: the aggregator has no
# NULL group and no NULL accumulator, so every output column is all-valid.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_op_agg_hash.flat_hash_agg import EntryHandle, FlatHashAggregator
from komira_plan_expr.agg_expr import AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM
from komira_plan_ir.logical_plan import AggExprArray


comptime _V_SUM: Int = 0
comptime _V_MIN: Int = 1
comptime _V_MAX: Int = 2
comptime _V_MEAN: Int = 3


@always_inline
def _value(
    agg: FlatHashAggregator, entry: EntryHandle, a: Int, which: Int
) -> Float64:
    if which == _V_SUM:
        return agg.get_sum(entry, a)
    if which == _V_MIN:
        return agg.get_min(entry, a)
    if which == _V_MAX:
        return agg.get_max(entry, a)
    return agg.get_avg(entry, a)


def _float_column(
    agg: FlatHashAggregator, entries: List[EntryHandle], a: Int, which: Int
) -> Column[HeapRegion]:
    var n = len(entries)
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for g in range(n):
        arr.store[width=1](g, Scalar[DType.float64](_value(agg, entries[g], a, which)))
    return Column.from_primitive[DType.float64](arr^)


def _int_column(
    agg: FlatHashAggregator,
    entries: List[EntryHandle],
    a: Int,
    which: Int,
    is_i32: Bool,
) raises -> Column[HeapRegion]:
    """`which` of aggregate `a` per group, truncated toward zero, as an INT32
    column when `is_i32` else INT64. Raises on a value that is NaN, infinite
    or outside the output type's range."""
    var n = len(entries)
    if is_i32:
        var arr = PrimitiveArray[DType.int32].allocate(n)
        for g in range(n):
            var v = _value(agg, entries[g], a, which)
            if not (v > -2147483649.0 and v < 2147483648.0):
                raise Error(
                    "build_flat_agg_output: aggregate "
                    + String(a)
                    + " has a value that does not fit INT32"
                )
            arr.store[width=1](g, Scalar[DType.int32](Int32(Int(v))))
        return Column.from_primitive[DType.int32](arr^)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for g in range(n):
        var v = _value(agg, entries[g], a, which)
        if not (v >= -9223372036854775808.0 and v < 9223372036854775808.0):
            raise Error(
                "build_flat_agg_output: aggregate "
                + String(a)
                + " has a value that does not fit INT64"
            )
        arr.store[width=1](g, Scalar[DType.int64](Int(v)))
    return Column.from_primitive[DType.int64](arr^)


def _count_column(
    agg: FlatHashAggregator, entries: List[EntryHandle], a: Int, is_i32: Bool
) raises -> Column[HeapRegion]:
    var n = len(entries)
    if is_i32:
        var arr = PrimitiveArray[DType.int32].allocate(n)
        for g in range(n):
            if Int(agg.get_count(entries[g], a)) > 2147483647:
                raise Error(
                    "build_flat_agg_output: a count does not fit INT32"
                )
            arr.store[width=1](g, Scalar[DType.int32](Int32(agg.get_count(entries[g], a))))
        return Column.from_primitive[DType.int32](arr^)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for g in range(n):
        arr.store[width=1](g, Scalar[DType.int64](agg.get_count(entries[g], a)))
    return Column.from_primitive[DType.int64](arr^)


def _key_column(
    agg: FlatHashAggregator, entries: List[EntryHandle], k: Int, is_i32: Bool
) -> Column[HeapRegion]:
    var n = len(entries)
    if is_i32:
        var arr = PrimitiveArray[DType.int32].allocate(n)
        for g in range(n):
            arr.store[width=1](g, Scalar[DType.int32](Int32(Int(agg.get_key(entries[g], k)))))
        return Column.from_primitive[DType.int32](arr^)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for g in range(n):
        arr.store[width=1](g, Scalar[DType.int64](agg.get_key(entries[g], k)))
    return Column.from_primitive[DType.int64](arr^)


def build_flat_agg_output(
    agg: FlatHashAggregator,
    agg_exprs: AggExprArray,
    output_schema: Schema,
    num_key_cols: Int,
    key_types: List[UInt8],
) raises -> RecordBatch:
    """One row per group of `agg`: `num_key_cols` key columns, then one column
    per aggregate of `agg_exprs`.

    Args:
        agg: The aggregator holding the groups.
        agg_exprs: The aggregates, in output order; `agg_exprs[a]` is the
            aggregator's accumulator `a`.
        output_schema: The output fields, keys first; field `i` names and
            types output column `i`.
        num_key_cols: Group-by key columns.
        key_types: The `ArrowType.type_id` of each key column; each is INT32
            or INT64 and equals its output field's type.

    Returns:
        The groups as a RecordBatch.

    Raises:
        If an aggregate is not SUM, COUNT, MIN, MAX or MEAN; if the schema is
        narrower than the columns to emit; if a key or output field has a type
        the function does not produce for it; or if an integer output value is
        NaN, infinite or out of range.
    """
    if output_schema.num_columns() < num_key_cols + len(agg_exprs):
        raise Error(
            "build_flat_agg_output: the output schema has "
            + String(output_schema.num_columns())
            + " fields, fewer than the "
            + String(num_key_cols + len(agg_exprs))
            + " columns to emit"
        )
    if len(key_types) < num_key_cols:
        raise Error("build_flat_agg_output: fewer key types than key columns")

    var entries = agg.iter_entries()
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()

    for k in range(num_key_cols):
        var key_at = ArrowType(type_id=key_types[k])
        if key_at != ArrowType.INT32 and key_at != ArrowType.INT64:
            raise Error(
                "build_flat_agg_output: key column "
                + String(k)
                + " is neither INT32 nor INT64"
            )
        if output_schema.field_arrow_type(k) != key_at:
            raise Error(
                "build_flat_agg_output: the output field of key column "
                + String(k)
                + " has a different type than the key"
            )
        sb.add_field(output_schema.field_at(k))
        builder.add_column(_key_column(agg, entries, k, key_at == ArrowType.INT32))

    for a in range(len(agg_exprs)):
        var out_idx = num_key_cols + a
        sb.add_field(output_schema.field_at(out_idx))
        var out_at = output_schema.field_arrow_type(out_idx)
        var is_i32 = out_at == ArrowType.INT32
        var int_out = out_at == ArrowType.INT64 or is_i32
        var func = agg_exprs[a].func
        if func == AGG_COUNT:
            if not int_out:
                raise Error(
                    "build_flat_agg_output: COUNT needs an INT32 or INT64 field"
                )
            builder.add_column(_count_column(agg, entries, a, is_i32))
        elif func == AGG_MEAN:
            if out_at != ArrowType.FLOAT64:
                raise Error("build_flat_agg_output: MEAN needs a FLOAT64 field")
            builder.add_column(_float_column(agg, entries, a, _V_MEAN))
        elif func == AGG_SUM or func == AGG_MIN or func == AGG_MAX:
            var which = _V_SUM
            if func == AGG_MIN:
                which = _V_MIN
            elif func == AGG_MAX:
                which = _V_MAX
            if int_out:
                builder.add_column(_int_column(agg, entries, a, which, is_i32))
            elif out_at == ArrowType.FLOAT64:
                builder.add_column(_float_column(agg, entries, a, which))
            else:
                raise Error(
                    "build_flat_agg_output: SUM, MIN and MAX need an INT32, "
                    "INT64 or FLOAT64 field"
                )
        else:
            raise Error(
                "build_flat_agg_output: unsupported aggregate function "
                + String(Int(func))
            )
    return builder.build(sb.build())
