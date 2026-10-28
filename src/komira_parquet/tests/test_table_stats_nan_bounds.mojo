# =============================================================================
# NaN min/max statistics in collect_table_stats and ParquetStatsProvider.
#
# A NaN bound is no bound. Folded as a number it corrupts the column's min
# and max (every comparison with it is false, so it either sticks as the
# running minimum or is silently passed over), and a consumer such as a
# Top-N or range planner then trusts a range that does not cover the rows.
#
# What each test proves:
#   * a NaN min or max in any row group of a FLOAT64 or FLOAT32 column
#     leaves the column's overall min AND max unknown in the eager fold,
#     whichever row group holds it; the other row groups' bounds are not
#     reported as covering the column;
#   * the provider answers None for column_min_max, and for
#     column_rg_min_max of the NaN row group, while a finite row group of
#     the same column still has its bounds;
#   * a column with finite bounds in every row group still folds (so the
#     None answers above are the NaN rule), and a neighbouring column is
#     unaffected by another column's NaN.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    RowGroup,
    SchemaElement,
    Statistics,
)
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet.table_stats import ParquetStatsProvider, collect_table_stats


def _le(v: UInt64, width: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(width):
        out.append(UInt8((v >> UInt64(8 * i)) & 0xFF))
    return out^


def _f64(v: Float64) -> List[UInt8]:
    return _le(bitcast[DType.uint64](v), 8)


def _f32(v: Float32) -> List[UInt8]:
    return _le(UInt64(bitcast[DType.uint32](v)), 4)


def _chunk(name: String, t: ParquetType, var mn: List[UInt8], var mx: List[UInt8]) -> ColumnChunk:
    var path: List[String] = [name]
    var meta = ColumnMetaData(
        type=t,
        encodings=List[Encoding](),
        path_in_schema=path^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=10,
        total_uncompressed_size=0,
        total_compressed_size=0,
        data_page_offset=4,
        statistics=Statistics(min_value=mn^, max_value=mx^),
    )
    return ColumnChunk(file_offset=0, meta_data=meta^)


def _nan() -> Float64:
    return bitcast[DType.float64](UInt64(0x7FF8000000000000))


# Columns: d DOUBLE, f FLOAT, g DOUBLE (always finite). Row group 0 is
# finite everywhere; row group 1 carries the given d and f bounds.
def _md(d1_mn: Float64, d1_mx: Float64, f1_mn: Float32, f1_mx: Float32, nan_group_first: Bool = False) -> FileMetaData:
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=3),
        SchemaElement(name="d", type=ParquetType.DOUBLE),
        SchemaElement(name="f", type=ParquetType.FLOAT),
        SchemaElement(name="g", type=ParquetType.DOUBLE),
    ]
    var fin: List[ColumnChunk] = [
        _chunk("d", ParquetType.DOUBLE, _f64(-1.5), _f64(2.5)),
        _chunk("f", ParquetType.FLOAT, _f32(-1.5), _f32(2.5)),
        _chunk("g", ParquetType.DOUBLE, _f64(0.0), _f64(9.0)),
    ]
    var odd: List[ColumnChunk] = [
        _chunk("d", ParquetType.DOUBLE, _f64(d1_mn), _f64(d1_mx)),
        _chunk("f", ParquetType.FLOAT, _f32(f1_mn), _f32(f1_mx)),
        _chunk("g", ParquetType.DOUBLE, _f64(-3.0), _f64(4.0)),
    ]
    var groups = List[RowGroup]()
    if nan_group_first:
        groups.append(RowGroup(columns=odd^, total_byte_size=0, num_rows=10))
        groups.append(RowGroup(columns=fin^, total_byte_size=0, num_rows=10))
    else:
        groups.append(RowGroup(columns=fin^, total_byte_size=0, num_rows=10))
        groups.append(RowGroup(columns=odd^, total_byte_size=0, num_rows=10))
    return FileMetaData(version=2, schema=schema^, num_rows=20, row_groups=groups^)


def _arrow_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    sb.add_field(Field("g", ArrowType.FLOAT64, True))
    return sb.build()


def _assert_float_columns_unknown(md: FileMetaData) raises:
    var ts = collect_table_stats(md, _arrow_schema())
    for c in range(2):
        assert_false(Bool(ts.column_stats[c].min_value))
        assert_false(Bool(ts.column_stats[c].max_value))
    # g is finite in both row groups: still folded.
    assert_equal(ts.column_stats[2].min_value.value().float_val, -3.0)
    assert_equal(ts.column_stats[2].max_value.value().float_val, 9.0)


def test_eager_fold_nan_min() raises:
    var n = _nan()
    _assert_float_columns_unknown(_md(n, 3.0, Float32(n), 3.0))


def test_eager_fold_nan_max() raises:
    var n = _nan()
    _assert_float_columns_unknown(_md(-2.0, n, -2.0, Float32(n)))


def test_eager_fold_both_nan() raises:
    var n = _nan()
    _assert_float_columns_unknown(_md(n, n, Float32(n), Float32(n)))


def test_eager_fold_nan_group_first() raises:
    var n = _nan()
    _assert_float_columns_unknown(_md(n, 3.0, Float32(n), 3.0, True))
    _assert_float_columns_unknown(_md(-2.0, n, -2.0, Float32(n), True))


def test_eager_fold_finite_control() raises:
    var ts = collect_table_stats(_md(-2.0, 3.0, -2.0, 3.0), _arrow_schema())
    assert_equal(ts.column_stats[0].min_value.value().float_val, -2.0)
    assert_equal(ts.column_stats[0].max_value.value().float_val, 3.0)
    assert_equal(ts.column_stats[1].min_value.value().float_val, -2.0)
    assert_equal(ts.column_stats[1].max_value.value().float_val, 3.0)
    # Signed zeros fold as the numbers they are.
    var z = collect_table_stats(_md(-0.0, 0.0, -0.0, 0.0), _arrow_schema())
    assert_equal(z.column_stats[0].min_value.value().float_val, -1.5)
    assert_equal(z.column_stats[0].max_value.value().float_val, 2.5)


def test_provider_nan_bounds() raises:
    var n = _nan()
    var p = ParquetStatsProvider(_md(n, 3.0, -2.0, Float32(n)), Schema())
    # Row group 0 is finite, row group 1 holds the NaN.
    assert_equal(p.column_rg_min_max("d", 0).value()[0].float_val, -1.5)
    assert_equal(p.column_rg_min_max("f", 0).value()[1].float_val, 2.5)
    assert_false(Bool(p.column_rg_min_max("d", 1)))
    assert_false(Bool(p.column_rg_min_max("f", 1)))
    assert_false(Bool(p.column_min_max("d")))
    assert_false(Bool(p.column_min_max("f")))
    var g = p.column_min_max("g").value().copy()
    assert_equal(g[0].float_val, -3.0)
    assert_equal(g[1].float_val, 9.0)


def test_provider_both_nan_and_finite_control() raises:
    var n = _nan()
    var p = ParquetStatsProvider(_md(n, n, Float32(n), Float32(n), True), Schema())
    assert_false(Bool(p.column_rg_min_max("d", 0)))
    assert_false(Bool(p.column_min_max("d")))
    assert_false(Bool(p.column_min_max("f")))
    var q = ParquetStatsProvider(_md(-2.0, 3.0, -2.0, 3.0), Schema())
    var d = q.column_min_max("d").value().copy()
    assert_equal(d[0].float_val, -2.0)
    assert_equal(d[1].float_val, 3.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
