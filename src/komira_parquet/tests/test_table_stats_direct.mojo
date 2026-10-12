# =============================================================================
# collect_table_stats, read_parquet_table_stats and ParquetStatsProvider.
#
# Footers are built as structs (one file is written, with a footer from a
# Thrift Compact writer, for the two path entry points). HLL registers come
# from komira_collections' HyperLogLog over known values.
#
# What each test proves:
#   * the eager fold: the smallest min and largest max across row groups,
#     the summed null count, the largest per-row-group distinct count, the
#     total row count; a column absent from the footer has no statistics;
#   * bounds are decoded by type: signed INT32 widened, UINT_32 zero-extended
#     (it read negative above 2**31 when decoded by the physical type), a
#     UINT_64 above Int64.MAX gives no bound (it read negative), FLOAT and
#     DOUBLE as floats, strings and DECIMAL (unscaled) give none;
#   * the provider resolves a column among the top-level leaves (a nested
#     leaf's name is not a column) and answers None for a fold when any row
#     group lacks the column or the statistic;
#   * the NDV estimate merges HLL registers: a value in both row groups
#     counts once, the estimate equals the estimate of one sketch over the
#     union, and the merged registers are that sketch's; without registers
#     in every row group it falls back to the summed distinct counts;
#   * the path entry points read a footer with a column chunk's statistics.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_runtime_paths import test_tmpdir
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
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CompressionCodec,
    Encoding,
    ParquetType,
)
from komira_plan_stats.physical_type import PhysicalType
from komira_plan_stats.table_stats import STATS_SOURCE_PARQUET_METADATA
from komira_parquet.table_stats import ParquetStatsProvider, collect_table_stats, read_parquet_table_stats


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


# Leaves: i INT64, u32 INT32 UINT_32, u64 INT64 UINT_64, d DOUBLE,
# s BYTE_ARRAY, dec INT32 DECIMAL(9, 2), g { i } (a nested leaf named i),
# h INT64 with HLL registers. Two row groups.
def _md() -> FileMetaData:
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=8),
        _leaf("i", ParquetType.INT64),
        _leaf("u32", ParquetType.INT32, CONVERTED_TYPE_UINT_32),
        _leaf("u64", ParquetType.INT64, CONVERTED_TYPE_UINT_64),
        _leaf("d", ParquetType.DOUBLE),
        _leaf("s", ParquetType.BYTE_ARRAY),
        _leaf("dec", ParquetType.INT32, CONVERTED_TYPE_DECIMAL, 2),
        SchemaElement(name="g", num_children=1),
        _leaf("i", ParquetType.INT32),
        _leaf("h", ParquetType.INT64),
    ]
    var big = _le(UInt64(1) << 63, 8)  # 2**63: above Int64.MAX
    var rg0: List[ColumnChunk] = [
        _chunk("i", ParquetType.INT64, _stats(_i64(10), _i64(20), 1, 4)),
        _chunk("u32", ParquetType.INT32, _stats(_le(5, 4), _le(0xFFFFFFF0, 4), 0, 2)),
        _chunk("u64", ParquetType.INT64, _stats(_le(7, 8), big.copy(), 0)),
        _chunk("d", ParquetType.DOUBLE, _stats(_f64(-1.5), _f64(2.5))),
        _chunk("s", ParquetType.BYTE_ARRAY, _stats([0x61], [0x7A])),
        _chunk("dec", ParquetType.INT32, _stats(_i32(100), _i32(900))),
        _chunk_at(["g", "i"], ParquetType.INT32, _stats(_i32(0), _i32(1))),
        _chunk("h", ParquetType.INT64, _stats(_i64(0), _i64(599), 0, 600, _regs(0, 600))),
    ]
    var rg1: List[ColumnChunk] = [
        _chunk("i", ParquetType.INT64, _stats(_i64(5), _i64(15), 2, 7)),
        _chunk("u32", ParquetType.INT32, _stats(_le(1, 4), _le(9, 4), 0, 3)),
        _chunk("u64", ParquetType.INT64, _stats(_le(3, 8), _le(8, 8), 0)),
        _chunk("d", ParquetType.DOUBLE, None),
        _chunk("s", ParquetType.BYTE_ARRAY, _stats([0x62], [0x63])),
        _chunk("dec", ParquetType.INT32, _stats(_i32(1), _i32(2))),
        _chunk_at(["g", "i"], ParquetType.INT32, _stats(_i32(0), _i32(1))),
        _chunk("h", ParquetType.INT64, _stats(_i64(300), _i64(899), 0, 600, _regs(300, 900))),
    ]
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=rg0^, total_byte_size=0, num_rows=600))
    groups.append(RowGroup(columns=rg1^, total_byte_size=0, num_rows=600))
    return FileMetaData(version=2, schema=schema^, num_rows=1200, row_groups=groups^)


def test_collect_table_stats_folds_and_decodes_by_type() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("i", ArrowType.INT64, True))
    sb.add_field(Field("u32", ArrowType.UINT32, True))
    sb.add_field(Field("u64", ArrowType.UINT64, True))
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("absent", ArrowType.INT64, True))
    var schema = sb.build()
    var ts = collect_table_stats(_md(), schema)
    assert_equal(ts.row_count, 1200)
    assert_true(ts.source == STATS_SOURCE_PARQUET_METADATA)
    assert_equal(len(ts.column_stats), 6)
    ref i = ts.column_stats[0]
    assert_equal(i.min_value.value().int_val, 5)
    assert_equal(i.max_value.value().int_val, 20)
    assert_equal(i.null_count.value(), 3)
    assert_equal(i.distinct_count.value(), 7)
    ref u32 = ts.column_stats[1]
    assert_equal(u32.min_value.value().int_val, 1)
    assert_equal(u32.max_value.value().int_val, 0xFFFFFFF0)
    ref u64 = ts.column_stats[2]
    assert_equal(u64.min_value.value().int_val, 3)
    assert_equal(u64.max_value.value().int_val, 8)  # 2**63 has no Int64 bound
    ref d = ts.column_stats[3]
    assert_equal(d.min_value.value().float_val, -1.5)
    assert_equal(d.max_value.value().float_val, 2.5)
    assert_false(Bool(d.null_count))
    ref s = ts.column_stats[4]
    assert_false(Bool(s.min_value))
    ref absent = ts.column_stats[5]
    assert_false(Bool(absent.min_value))
    assert_false(Bool(absent.distinct_count))


def test_provider_bounds() raises:
    var schema = Schema()
    var p = ParquetStatsProvider(_md(), schema^)
    assert_equal(p.num_row_groups(), 2)
    assert_equal(p.total_row_count(), 1200)
    assert_true(p.column_physical_type("i").value() == PhysicalType.INT64)
    assert_true(p.column_physical_type("u32").value() == PhysicalType.INT32)
    assert_false(Bool(p.column_physical_type("g")))
    assert_false(Bool(p.column_physical_type("nope")))
    var r0 = p.column_rg_min_max("i", 0).value().copy()
    assert_equal(r0[0].int_val, 10)
    assert_equal(r0[1].int_val, 20)
    var mm = p.column_min_max("i").value().copy()
    assert_equal(mm[0].int_val, 5)
    assert_equal(mm[1].int_val, 20)
    # UINT_32: 0xFFFFFFF0 is 4294967280, not -16.
    assert_equal(p.column_rg_min_max("u32", 0).value()[1].int_val, 0xFFFFFFF0)
    assert_equal(p.column_min_max("u32").value()[0].int_val, 1)
    # UINT_64: 2**63 has no bound, so neither has the column.
    assert_false(Bool(p.column_rg_min_max("u64", 0)))
    assert_equal(p.column_rg_min_max("u64", 1).value()[1].int_val, 8)
    assert_false(Bool(p.column_min_max("u64")))
    # d lacks statistics in row group 1.
    assert_equal(p.column_rg_min_max("d", 0).value()[0].float_val, -1.5)
    assert_false(Bool(p.column_min_max("d")))
    assert_false(Bool(p.column_min_max("s")))
    assert_false(Bool(p.column_min_max("dec")))
    assert_false(Bool(p.column_rg_min_max("i", 2)))
    assert_false(Bool(p.column_rg_min_max("i", -1)))
    assert_false(Bool(p.column_min_max("nope")))


def test_provider_counts() raises:
    var p = ParquetStatsProvider(_md(), Schema())
    assert_equal(p.column_distinct_count("i").value(), 11)
    assert_equal(p.column_null_count("i").value(), 3)
    assert_false(Bool(p.column_null_count("d")))
    assert_false(Bool(p.column_distinct_count("u64")))
    assert_false(Bool(p.column_distinct_count("nope")))


def test_ndv_merges_hll_registers() raises:
    var p = ParquetStatsProvider(_md(), Schema())
    assert_true(p.column_ndv_estimate_from_hll("h"))
    var union = HyperLogLog()
    for v in range(0, 900):
        union.add_int64(Int64(v))
    assert_equal(p.column_ndv_estimate("h").value(), union.estimate())
    # 300 values are in both row groups: the merge counts them once, well
    # under the summed distinct counts (1200).
    assert_true(p.column_ndv_estimate("h").value() < 1000)
    var merged = p.column_merged_hll_registers("h").value().copy()
    assert_equal(len(merged), HLL_NUM_REGISTERS)
    for j in range(HLL_NUM_REGISTERS):
        assert_equal(merged[j], union.register(j))
    # i has no registers: the estimate is the summed distinct counts.
    assert_false(p.column_ndv_estimate_from_hll("i"))
    assert_equal(p.column_ndv_estimate("i").value(), 11)
    assert_false(Bool(p.column_merged_hll_registers("i")))
    assert_false(Bool(p.column_ndv_estimate("nope")))


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _bin(mut out: List[UInt8], header: UInt8, b: List[UInt8]):
    out.append(header)
    _uleb(out, len(b))
    for i in range(len(b)):
        out.append(b[i])


def _write_file(name: String) raises -> String:
    """A file whose footer has schema [root, x INT64], 9 rows, and one row
    group with x's chunk: statistics null_count 2, distinct 4, min -3,
    max 40."""
    var f: List[UInt8] = [0x15]
    _zz(f, 2)
    f.append(0x19)
    f.append(0x2C)
    _bin(f, 0x48, [0x73])  # root: 4 name "s"
    f.append(0x15)  # 5 num_children 1
    _zz(f, 1)
    f.append(0x00)
    f.append(0x15)  # leaf: 1 type INT64
    _zz(f, 2)
    _bin(f, 0x38, [0x78])  # 4 name "x"
    f.append(0x00)
    f.append(0x16)  # 3 num_rows
    _zz(f, 9)
    f.append(0x19)  # 4 row_groups: 1 struct
    f.append(0x1C)
    f.append(0x19)  # RowGroup 1 columns: 1 struct
    f.append(0x1C)
    f.append(0x26)  # ColumnChunk 2 file_offset
    _zz(f, 4)
    f.append(0x1C)  # 3 meta_data
    f.append(0x15)  # 1 type INT64
    _zz(f, 2)
    f.append(0x19)  # 2 encodings: 1 i32
    f.append(0x15)
    _zz(f, 0)
    f.append(0x19)  # 3 path_in_schema: 1 binary
    f.append(0x18)
    _uleb(f, 1)
    f.append(0x78)
    f.append(0x15)  # 4 codec
    _zz(f, 0)
    f.append(0x16)  # 5 num_values
    _zz(f, 9)
    f.append(0x16)  # 6 total_uncompressed_size
    _zz(f, 10)
    f.append(0x16)  # 7 total_compressed_size
    _zz(f, 10)
    f.append(0x26)  # 9 data_page_offset
    _zz(f, 4)
    f.append(0x3C)  # 12 statistics
    f.append(0x36)  # 3 null_count
    _zz(f, 2)
    f.append(0x16)  # 4 distinct_count
    _zz(f, 4)
    _bin(f, 0x18, _i64(40))  # 5 max_value
    _bin(f, 0x18, _i64(-3))  # 6 min_value
    f.append(0x00)  # end Statistics
    f.append(0x00)  # end ColumnMetaData
    f.append(0x00)  # end ColumnChunk
    f.append(0x16)  # RowGroup 2 total_byte_size
    _zz(f, 10)
    f.append(0x16)  # 3 num_rows
    _zz(f, 9)
    f.append(0x00)  # end RowGroup
    f.append(0x00)  # end FileMetaData
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for _ in range(10):
        out.append(0)
    for i in range(len(f)):
        out.append(f[i])
    for k in range(4):
        out.append(UInt8((len(f) >> (8 * k)) & 0xFF))
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()
    return path^


def test_the_path_entry_points_read_the_footer() raises:
    var path = _write_file("table_stats.parquet")
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, True))
    var schema = sb.build()
    var ts = read_parquet_table_stats(path, schema)
    assert_equal(ts.row_count, 9)
    assert_equal(ts.column_stats[0].min_value.value().int_val, -3)
    assert_equal(ts.column_stats[0].max_value.value().int_val, 40)
    assert_equal(ts.column_stats[0].null_count.value(), 2)
    var p = ParquetStatsProvider.from_path(path, Schema())
    assert_equal(p.total_row_count(), 9)
    assert_equal(p.column_distinct_count("x").value(), 4)
    assert_equal(len(p.cached_metadata().row_groups), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
