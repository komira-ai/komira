# =============================================================================
# table_stats: the corners of the eager fold and of the provider.
#
# What each test proves:
#   * the eager fold decodes INT8/INT16/INT32 columns as signed 32-bit and
#     FLOAT32 columns as 32-bit floats, folds float bounds across row groups,
#     keeps the smaller min of an earlier row group when a later one is
#     larger, and gives no bound for a statistic shorter than its type;
#   * the provider maps every parquet physical type to its plan type, and
#     answers None for a type it does not know and for a name in an empty
#     schema;
#   * a footer without row groups answers no bound, no count, no registers
#     and "no HLL";
#   * a column missing from one row group, a statistics block without
#     min/max and registers of the wrong length decline every fold that
#     needs them, and the estimate falls back to the summed distinct counts;
#   * a FLOAT column's per-row-group bounds are decoded as floats;
#   * numeric comparison of a decoded integer with a decoded float goes by
#     value.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.hyperloglog import HLL_NUM_REGISTERS, HyperLogLog
from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    RowGroup,
    SchemaElement,
    Statistics,
)
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    ParquetType,
)
from komira_plan_stats.physical_type import PhysicalType
from komira_plan_expr.scalar_value import ScalarValue
from komira_parquet.table_stats import ParquetStatsProvider, _scalar_lt, collect_table_stats


def _le(v: UInt64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(width):
        out.append(UInt8((v >> UInt64(8 * i)) & 0xFF))
    return out^


def _i64(v: Int64) -> List[UInt8]:
    return _le(bitcast[DType.uint64](v), 8)


def _i32(v: Int64) -> List[UInt8]:
    return _le(UInt64(bitcast[DType.uint32](Int32(v))), 4)


def _f64(v: Float64) -> List[UInt8]:
    return _le(bitcast[DType.uint64](v), 8)


def _stats(
    var mn: List[UInt8],
    var mx: List[UInt8],
    nulls: Optional[Int] = None,
    distinct: Optional[Int] = None,
    var regs: Optional[List[UInt8]] = None,
) -> Optional[Statistics]:
    return Statistics(null_count=nulls, distinct_count=distinct, min_value=mn^, max_value=mx^, hll_registers=regs^)


def _chunk(name: String, t: ParquetType, var stats: Optional[Statistics]) -> ColumnChunk:
    var path: List[String] = [name]
    return _chunk_at(path^, t, stats^)


def _chunk_at(var path: List[String], t: ParquetType, var stats: Optional[Statistics]) -> ColumnChunk:
    var meta = ColumnMetaData(
        type=t,
        encodings=List[Encoding](),
        path_in_schema=path^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=10,
        total_uncompressed_size=0,
        total_compressed_size=0,
        data_page_offset=4,
        statistics=stats^,
    )
    return ColumnChunk(file_offset=0, meta_data=meta^)


def _leaf(name: String, t: ParquetType, conv: Optional[Int] = None, scale: Optional[Int] = None) -> SchemaElement:
    return SchemaElement(name=name, type=t, converted_type=conv, scale=scale)


def _regs(lo: Int, hi: Int) -> List[UInt8]:
    var sk = HyperLogLog()
    for v in range(lo, hi):
        sk.add_int64(Int64(v))
    var out = List[UInt8]()
    for j in range(HLL_NUM_REGISTERS):
        out.append(sk.register(j))
    return out^



def _two_group_file(var schema: List[SchemaElement], var rg0: List[ColumnChunk], var rg1: List[ColumnChunk]) -> FileMetaData:
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=rg0^, total_byte_size=0, num_rows=10))
    groups.append(RowGroup(columns=rg1^, total_byte_size=0, num_rows=10))
    return FileMetaData(version=2, schema=schema^, num_rows=20, row_groups=groups^)


def _f32_bytes(v: Float32) -> List[UInt8]:
    return _le(UInt64(bitcast[DType.uint32](v)), 4)


def test_eager_fold_decodes_narrow_ints_floats_and_short_bytes() raises:
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=6),
        _leaf("x8", ParquetType.INT32),
        _leaf("f32", ParquetType.FLOAT),
        _leaf("dd", ParquetType.DOUBLE),
        _leaf("sh32", ParquetType.INT32),
        _leaf("sh64", ParquetType.INT64),
        _leaf("ii", ParquetType.INT64),
    ]
    var rg0: List[ColumnChunk] = [
        _chunk("x8", ParquetType.INT32, _stats(_i32(-3), _i32(7))),
        _chunk("f32", ParquetType.FLOAT, _stats(_f32_bytes(0.5), _f32_bytes(4.5))),
        _chunk("dd", ParquetType.DOUBLE, _stats(_f64(1.0), _f64(9.0))),
        _chunk("sh32", ParquetType.INT32, _stats(_le(1, 2), _le(2, 2))),
        _chunk("sh64", ParquetType.INT64, _stats(_le(1, 4), _le(2, 4))),
        _chunk("ii", ParquetType.INT64, _stats(_i64(5), _i64(15))),
    ]
    var rg1: List[ColumnChunk] = [
        _chunk("x8", ParquetType.INT32, _stats(_i32(-1), _i32(3))),
        _chunk("f32", ParquetType.FLOAT, _stats(_f32_bytes(1.5), _f32_bytes(2.5))),
        _chunk("dd", ParquetType.DOUBLE, _stats(_f64(2.0), _f64(12.0))),
        _chunk("sh32", ParquetType.INT32, _stats(_le(1, 2), _le(2, 2))),
        _chunk("sh64", ParquetType.INT64, _stats(_le(1, 4), _le(2, 4))),
        _chunk("ii", ParquetType.INT64, _stats(_i64(10), _i64(20))),
    ]
    var md = _two_group_file(schema^, rg0^, rg1^)
    var sb = SchemaBuilder()
    sb.add_field(Field("x8", ArrowType.INT8, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("dd", ArrowType.FLOAT64, True))
    sb.add_field(Field("sh32", ArrowType.INT32, True))
    sb.add_field(Field("sh64", ArrowType.INT64, True))
    sb.add_field(Field("ii", ArrowType.INT64, True))
    var ts = collect_table_stats(md, sb.build())
    assert_equal(ts.row_count, 20)
    ref x8 = ts.column_stats[0]
    assert_equal(x8.min_value.value().int_val, -3)
    assert_equal(x8.max_value.value().int_val, 7)
    ref f32 = ts.column_stats[1]
    assert_equal(f32.min_value.value().float_val, 0.5)
    assert_equal(f32.max_value.value().float_val, 4.5)
    ref dd = ts.column_stats[2]
    assert_equal(dd.min_value.value().float_val, 1.0)
    assert_equal(dd.max_value.value().float_val, 12.0)
    # Statistics shorter than the type give no bound.
    assert_false(Bool(ts.column_stats[3].min_value))
    assert_false(Bool(ts.column_stats[3].max_value))
    assert_false(Bool(ts.column_stats[4].min_value))
    assert_false(Bool(ts.column_stats[4].max_value))
    # The later row group has the larger min: the earlier one stays.
    ref ii = ts.column_stats[5]
    assert_equal(ii.min_value.value().int_val, 5)
    assert_equal(ii.max_value.value().int_val, 20)


def test_provider_maps_every_physical_type() raises:
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=9),
        _leaf("b", ParquetType.BOOLEAN),
        _leaf("p32", ParquetType.INT32),
        _leaf("p64", ParquetType.INT64),
        _leaf("p96", ParquetType.INT96),
        _leaf("pf", ParquetType.FLOAT),
        _leaf("pd", ParquetType.DOUBLE),
        _leaf("ba", ParquetType.BYTE_ARRAY),
        _leaf("fl", ParquetType.FIXED_LEN_BYTE_ARRAY),
        _leaf("odd", ParquetType(99)),
    ]
    var md = FileMetaData(version=2, schema=schema^, num_rows=0, row_groups=List[RowGroup]())
    var p = ParquetStatsProvider(md^, Schema())
    assert_true(p.column_physical_type("b").value() == PhysicalType.BOOLEAN)
    assert_true(p.column_physical_type("p32").value() == PhysicalType.INT32)
    assert_true(p.column_physical_type("p64").value() == PhysicalType.INT64)
    assert_true(p.column_physical_type("p96").value() == PhysicalType.INT96)
    assert_true(p.column_physical_type("pf").value() == PhysicalType.FLOAT)
    assert_true(p.column_physical_type("pd").value() == PhysicalType.DOUBLE)
    assert_true(p.column_physical_type("ba").value() == PhysicalType.BYTE_ARRAY)
    assert_true(p.column_physical_type("fl").value() == PhysicalType.FIXED_LEN_BYTE_ARRAY)
    assert_false(Bool(p.column_physical_type("odd")))


def test_an_empty_schema_resolves_no_column() raises:
    var md = FileMetaData(version=2, schema=List[SchemaElement](), num_rows=0, row_groups=List[RowGroup]())
    var p = ParquetStatsProvider(md^, Schema())
    assert_false(Bool(p.column_physical_type("x")))


def test_a_footer_without_row_groups_answers_nothing() raises:
    var schema: List[SchemaElement] = [SchemaElement(name="schema", num_children=1), _leaf("h", ParquetType.INT64)]
    var md = FileMetaData(version=2, schema=schema^, num_rows=0, row_groups=List[RowGroup]())
    var p = ParquetStatsProvider(md^, Schema())
    assert_equal(p.num_row_groups(), 0)
    assert_false(Bool(p.column_min_max("h")))
    assert_false(Bool(p.column_distinct_count("h")))
    assert_false(Bool(p.column_null_count("h")))
    assert_false(Bool(p.column_merged_hll_registers("h")))
    assert_false(Bool(p.column_ndv_estimate("h")))
    assert_false(p.column_ndv_estimate_from_hll("h"))


def test_a_column_missing_from_one_row_group_declines_every_fold() raises:
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=2),
        _leaf("h", ParquetType.INT64),
        _leaf("k", ParquetType.INT64),
    ]
    var rg0: List[ColumnChunk] = [
        _chunk("h", ParquetType.INT64, _stats(_i64(0), _i64(9), 0, 10, _regs(0, 10))),
    ]
    var rg1: List[ColumnChunk] = [
        _chunk("k", ParquetType.INT64, _stats(_i64(0), _i64(9), 0, 10)),
    ]
    var p = ParquetStatsProvider(_two_group_file(schema^, rg0^, rg1^), Schema())
    # h exists in row group 0 only.
    assert_false(Bool(p.column_null_count("h")))
    assert_false(Bool(p.column_distinct_count("h")))
    assert_false(Bool(p.column_min_max("h")))
    assert_false(p.column_ndv_estimate_from_hll("h"))
    assert_false(Bool(p.column_merged_hll_registers("h")))
    assert_false(Bool(p.column_ndv_estimate("h")))
    # k exists in row group 1 only.
    assert_false(p.column_ndv_estimate_from_hll("k"))
    assert_false(Bool(p.column_null_count("k")))


def test_wrong_length_registers_fall_back_to_summed_distinct_counts() raises:
    var schema: List[SchemaElement] = [SchemaElement(name="schema", num_children=1), _leaf("h", ParquetType.INT64)]
    var rg0: List[ColumnChunk] = [
        _chunk("h", ParquetType.INT64, _stats(_i64(0), _i64(9), 0, 10, _regs(0, 10))),
    ]
    var short_regs = List[UInt8](length=7, fill=1)
    var rg1: List[ColumnChunk] = [
        _chunk("h", ParquetType.INT64, _stats(_i64(0), _i64(9), 0, 12, short_regs^)),
    ]
    var p = ParquetStatsProvider(_two_group_file(schema^, rg0^, rg1^), Schema())
    assert_false(p.column_ndv_estimate_from_hll("h"))
    assert_false(Bool(p.column_merged_hll_registers("h")))
    assert_equal(p.column_ndv_estimate("h").value(), 22)


def test_statistics_without_min_max_give_no_bounds() raises:
    var schema: List[SchemaElement] = [SchemaElement(name="schema", num_children=1), _leaf("c", ParquetType.INT64)]
    var counts_only = Statistics(null_count=2, distinct_count=3)
    var counts_only2 = counts_only.copy()
    var rg0: List[ColumnChunk] = [_chunk("c", ParquetType.INT64, Optional[Statistics](counts_only^))]
    var rg1: List[ColumnChunk] = [_chunk("c", ParquetType.INT64, Optional[Statistics](counts_only2^))]
    var p = ParquetStatsProvider(_two_group_file(schema^, rg0^, rg1^), Schema())
    assert_false(Bool(p.column_rg_min_max("c", 0)))
    assert_false(Bool(p.column_min_max("c")))
    assert_equal(p.column_null_count("c").value(), 4)
    assert_equal(p.column_distinct_count("c").value(), 6)


def test_float_column_bounds_are_decoded_as_floats() raises:
    var schema: List[SchemaElement] = [SchemaElement(name="schema", num_children=1), _leaf("f", ParquetType.FLOAT)]
    var rg0: List[ColumnChunk] = [_chunk("f", ParquetType.FLOAT, _stats(_f32_bytes(-2.5), _f32_bytes(1.5)))]
    var rg1: List[ColumnChunk] = [_chunk("f", ParquetType.FLOAT, _stats(_f32_bytes(0.5), _f32_bytes(8.0)))]
    var p = ParquetStatsProvider(_two_group_file(schema^, rg0^, rg1^), Schema())
    var b = p.column_rg_min_max("f", 0).value().copy()
    assert_equal(b[0].float_val, -2.5)
    assert_equal(b[1].float_val, 1.5)
    var all_rg = p.column_min_max("f").value().copy()
    assert_equal(all_rg[0].float_val, -2.5)
    assert_equal(all_rg[1].float_val, 8.0)


def test_numeric_order_compares_integers_with_floats_by_value() raises:
    var i = ScalarValue.from_int64(3)
    var f = ScalarValue.from_float(3.5)
    assert_true(_scalar_lt(i, f))
    assert_false(_scalar_lt(f, i))
    assert_true(_scalar_lt(ScalarValue.from_float(2.5), ScalarValue.from_int64(3)))
    assert_false(_scalar_lt(ScalarValue.from_int64(4), ScalarValue.from_float(3.5)))
    assert_true(_scalar_lt(ScalarValue.from_float(1.0), ScalarValue.from_float(2.0)))
    assert_false(_scalar_lt(ScalarValue.from_float(2.0), ScalarValue.from_float(2.0)))
    assert_true(_scalar_lt(ScalarValue.from_int64(-1), ScalarValue.from_int64(0)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
