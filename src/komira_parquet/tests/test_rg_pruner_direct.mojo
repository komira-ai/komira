# =============================================================================
# can_prune_row_group, rg_all_match_row_group, all_match_row_count.
#
# Footers are built as structs: a root group, leaves (and in one schema a
# group), one row group, min/max statistics as the plain little-endian bytes.
#
# What each test proves:
#   * signed INT64 and INT32 ranges: each operator prunes exactly when the
#     range rules it out, with the literal on either side;
#   * UINT_64 and UINT_32 columns compare unsigned: a max of 2**64 - 1 (or
#     2**32 - 1) does not read as -1, which pruned row groups holding
#     matching rows and made all-match count rows that do not match; a
#     negative literal is below every unsigned value;
#   * DOUBLE and FLOAT ranges prune ordered comparisons; != never prunes (a
#     NaN row matches it and min/max exclude NaN);
#   * BYTE_ARRAY ranges compare bytes unsigned and lexicographically;
#   * AND prunes if either side does, OR only if both do;
#   * a column resolves among the top-level leaves only. The pruner used the
#     schema position as the chunk index, so after a group the name of a
#     leaf read ANOTHER leaf's statistics and pruned a row group holding
#     the value; a group's name or a nested leaf's name resolved too;
#   * a DECIMAL column never prunes: its statistics are unscaled;
#   * everything else is conservative: no statistics, short statistic
#     bytes, the wrong literal type, an unknown column, other shapes;
#   * all-match needs null_count present and 0, and all_match_row_count
#     answers only when every row group is decided.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_true

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
from komira_plan_expr.expr import (
    BIN_AND,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_NE,
    BIN_OR,
    Expr,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_parquet.rg_pruner import all_match_row_count, can_prune_row_group, rg_all_match_row_group


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


def _f32(v: Float32) -> List[UInt8]:
    return _le(UInt64(bitcast[DType.uint32](v)), 4)


def _str(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _chunk(
    t: ParquetType,
    var mn: Optional[List[UInt8]],
    var mx: Optional[List[UInt8]],
    nulls: Optional[Int] = 0,
) -> ColumnChunk:
    var stats = Statistics(null_count=nulls, min_value=mn^, max_value=mx^)
    var meta = ColumnMetaData(
        type=t,
        encodings=List[Encoding](),
        path_in_schema=List[String](),
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=10,
        total_uncompressed_size=0,
        total_compressed_size=0,
        data_page_offset=4,
        statistics=stats^,
    )
    return ColumnChunk(file_offset=0, meta_data=meta^)


def _bare(t: ParquetType) -> ColumnChunk:
    var meta = ColumnMetaData(
        type=t,
        encodings=List[Encoding](),
        path_in_schema=List[String](),
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=10,
        total_uncompressed_size=0,
        total_compressed_size=0,
        data_page_offset=4,
    )
    return ColumnChunk(file_offset=0, meta_data=meta^)


def _leaf(name: String, t: ParquetType, conv: Optional[Int] = None, scale: Optional[Int] = None) -> SchemaElement:
    return SchemaElement(name=name, type=t, converted_type=conv, scale=scale)


def _group(name: String, children: Int) -> SchemaElement:
    return SchemaElement(name=name, num_children=children)


def _file(var schema: List[SchemaElement], var columns: List[ColumnChunk], rows: Int = 10) -> FileMetaData:
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=columns^, total_byte_size=0, num_rows=rows))
    return FileMetaData(version=2, schema=schema^, num_rows=rows, row_groups=groups^)


def _cmp(op: UInt8, col: String, var lit: ScalarValue) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), Expr.literal(lit^))


def _rcmp(op: UInt8, var lit: ScalarValue, col: String) -> Expr:
    return Expr.binary(op, Expr.literal(lit^), Expr.col_ref(col))


def _int(v: Int64) -> ScalarValue:
    return ScalarValue.from_int64(v)


# Columns: i INT64 [10, 20]; j INT32 [-5, 5]; u UINT_64 [0, 2**64-1];
# w UINT_32 [1, 2**32-1]; d DOUBLE [1.5, 2.5]; f FLOAT [-1, 1];
# s BYTE_ARRAY ["b", "d"]; one DOUBLE e with min == max == 3.0;
# n INT64 without statistics; t INT64 with 2-byte statistics;
# dec INT32 DECIMAL(9, 2) unscaled [100, 12345].
def _flat() -> FileMetaData:
    var schema: List[SchemaElement] = [
        _group("schema", 11),
        _leaf("i", ParquetType.INT64),
        _leaf("j", ParquetType.INT32),
        _leaf("u", ParquetType.INT64, CONVERTED_TYPE_UINT_64),
        _leaf("w", ParquetType.INT32, CONVERTED_TYPE_UINT_32),
        _leaf("d", ParquetType.DOUBLE),
        _leaf("f", ParquetType.FLOAT),
        _leaf("s", ParquetType.BYTE_ARRAY),
        _leaf("e", ParquetType.DOUBLE),
        _leaf("n", ParquetType.INT64),
        _leaf("t", ParquetType.INT64),
        _leaf("dec", ParquetType.INT32, CONVERTED_TYPE_DECIMAL, 2),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, _i64(10), _i64(20)),
        _chunk(ParquetType.INT32, _i32(-5), _i32(5)),
        _chunk(ParquetType.INT64, _le(0, 8), _le(~UInt64(0), 8)),
        _chunk(ParquetType.INT32, _le(1, 4), _le(0xFFFFFFFF, 4)),
        _chunk(ParquetType.DOUBLE, _f64(1.5), _f64(2.5)),
        _chunk(ParquetType.FLOAT, _f32(-1.0), _f32(1.0)),
        _chunk(ParquetType.BYTE_ARRAY, _str("b"), _str("d")),
        _chunk(ParquetType.DOUBLE, _f64(3.0), _f64(3.0)),
        _bare(ParquetType.INT64),
        _chunk(ParquetType.INT64, _le(1, 2), _le(2, 2)),
        _chunk(ParquetType.INT32, _i32(100), _i32(12345)),
    ]
    return _file(schema^, columns^)


def _prunes(md: FileMetaData, e: Expr) -> Bool:
    return can_prune_row_group(md.row_groups[0], md, e)


def _all(md: FileMetaData, e: Expr) -> Bool:
    return rg_all_match_row_group(md.row_groups[0], md, e)


def test_signed_integer_ranges() raises:
    var md = _flat()
    assert_true(_prunes(md, _cmp(BIN_EQ, "i", _int(9))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "i", _int(10))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "i", _int(20))))
    assert_true(_prunes(md, _cmp(BIN_EQ, "i", _int(21))))
    assert_true(_prunes(md, _cmp(BIN_LT, "i", _int(10))))
    assert_false(_prunes(md, _cmp(BIN_LE, "i", _int(10))))
    assert_true(_prunes(md, _cmp(BIN_GT, "i", _int(20))))
    assert_false(_prunes(md, _cmp(BIN_GE, "i", _int(20))))
    assert_false(_prunes(md, _cmp(BIN_NE, "i", _int(15))))
    # Literal on the left: 9 > i is i < 9.
    assert_true(_prunes(md, _rcmp(BIN_GT, _int(9), "i")))
    assert_false(_prunes(md, _rcmp(BIN_GT, _int(11), "i")))
    assert_true(_prunes(md, _rcmp(BIN_LE, _int(21), "i")))
    assert_true(_prunes(md, _cmp(BIN_GT, "j", _int(5))))
    assert_false(_prunes(md, _cmp(BIN_LT, "j", _int(-4))))
    assert_true(_prunes(md, _cmp(BIN_LT, "j", _int(-5))))


def test_ne_prunes_only_a_single_valued_range() raises:
    var schema: List[SchemaElement] = [_group("schema", 1), _leaf("k", ParquetType.INT64)]
    var columns: List[ColumnChunk] = [_chunk(ParquetType.INT64, _i64(7), _i64(7))]
    var md = _file(schema^, columns^)
    assert_true(_prunes(md, _cmp(BIN_NE, "k", _int(7))))
    assert_false(_prunes(md, _cmp(BIN_NE, "k", _int(8))))


def test_unsigned_columns_compare_unsigned() raises:
    var md = _flat()
    # u's max is 2**64 - 1: rows above 5 can exist.
    assert_false(_prunes(md, _cmp(BIN_GT, "u", _int(5))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "u", _int(Int64.MAX))))
    assert_true(_prunes(md, _cmp(BIN_LT, "u", _int(-1))))
    assert_true(_prunes(md, _cmp(BIN_EQ, "u", _int(-1))))
    assert_false(_prunes(md, _cmp(BIN_GT, "u", _int(-1))))
    # w's max is 2**32 - 1.
    assert_false(_prunes(md, _cmp(BIN_GT, "w", _int(5))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "w", _int(4000000000))))
    assert_true(_prunes(md, _cmp(BIN_LT, "w", _int(1))))


def test_float_ranges_and_ne() raises:
    var md = _flat()
    assert_true(_prunes(md, _cmp(BIN_EQ, "d", ScalarValue.from_float(3.0))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "d", ScalarValue.from_float(2.0))))
    assert_true(_prunes(md, _cmp(BIN_LT, "d", ScalarValue.from_float(1.5))))
    assert_true(_prunes(md, _cmp(BIN_GT, "f", ScalarValue.from_float(1.0))))
    assert_false(_prunes(md, _cmp(BIN_GE, "f", ScalarValue.from_float(1.0))))
    # min == max == 3.0, but a NaN row (outside min/max) satisfies != 3.0.
    assert_false(_prunes(md, _cmp(BIN_NE, "e", ScalarValue.from_float(3.0))))


def test_byte_array_ranges() raises:
    var md = _flat()
    assert_true(_prunes(md, _cmp(BIN_EQ, "s", ScalarValue.from_string("a"))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "s", ScalarValue.from_string("c"))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "s", ScalarValue.from_string("cz"))))
    assert_true(_prunes(md, _cmp(BIN_EQ, "s", ScalarValue.from_string("da"))))
    assert_true(_prunes(md, _cmp(BIN_LT, "s", ScalarValue.from_string("b"))))
    assert_false(_prunes(md, _cmp(BIN_LE, "s", ScalarValue.from_string("b"))))
    assert_true(_prunes(md, _cmp(BIN_GT, "s", ScalarValue.from_string("d"))))
    assert_true(_prunes(md, _cmp(BIN_EQ, "s", ScalarValue.from_string(""))))


def test_and_or() raises:
    var md = _flat()
    var miss = _cmp(BIN_EQ, "i", _int(99))
    var hit = _cmp(BIN_EQ, "i", _int(15))
    assert_true(_prunes(md, Expr.binary(BIN_AND, hit.copy(), miss.copy())))
    assert_true(_prunes(md, Expr.binary(BIN_AND, miss.copy(), hit.copy())))
    assert_false(_prunes(md, Expr.binary(BIN_OR, hit.copy(), miss.copy())))
    assert_false(_prunes(md, Expr.binary(BIN_OR, miss.copy(), hit.copy())))
    assert_true(_prunes(md, Expr.binary(BIN_OR, miss.copy(), _cmp(BIN_GT, "j", _int(9)))))


def _grouped() -> FileMetaData:
    # schema: g { x }, a, b. Leaves (chunks): x, a, b.
    var schema: List[SchemaElement] = [
        _group("schema", 3),
        _group("g", 1),
        _leaf("x", ParquetType.INT64),
        _leaf("a", ParquetType.INT64),
        _leaf("b", ParquetType.INT64),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, _i64(0), _i64(0)),
        _chunk(ParquetType.INT64, _i64(100), _i64(200)),
        _chunk(ParquetType.INT64, _i64(0), _i64(0)),
    ]
    return _file(schema^, columns^)


def test_names_resolve_among_top_level_leaves() raises:
    var md = _grouped()
    # a is chunk 1. Read as chunk 2 (b, [0, 0]) this row group was pruned.
    assert_false(_prunes(md, _cmp(BIN_EQ, "a", _int(150))))
    assert_true(_prunes(md, _cmp(BIN_EQ, "a", _int(250))))
    assert_true(_prunes(md, _cmp(BIN_GT, "b", _int(0))))
    # b is all 0 and has no nulls: every row matches b = 0. Read as a,
    # nothing would.
    assert_true(_all(md, _cmp(BIN_EQ, "b", _int(0))))
    assert_true(_all(md, _cmp(BIN_GE, "a", _int(100))))
    # The group and the nested leaf resolve to nothing: no prune.
    assert_false(_prunes(md, _cmp(BIN_EQ, "g", _int(5))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "x", _int(5))))
    assert_false(_all(md, _cmp(BIN_EQ, "x", _int(0))))


def test_decimal_columns_never_prune() raises:
    var md = _flat()
    # 50 is 50.00 = 5000 unscaled, inside [100, 12345]; as a raw integer it
    # is below the minimum.
    assert_false(_prunes(md, _cmp(BIN_EQ, "dec", _int(50))))
    assert_false(_all(md, _cmp(BIN_GE, "dec", _int(1))))


def test_decimal_columns_never_prune_on_a_decimal_literal() raises:
    var md = _flat()
    # dec holds 1.00 to 123.45 (100 to 12345 unscaled). The literal 1.5 is 15
    # at scale 1; compared as 15 against the unscaled statistics, `dec < 1.5`
    # would look impossible (the minimum 100 is above 15) and `dec > 1.5` would
    # look true of every row. Neither is: 1.00 < 1.5.
    var one_and_a_half = ScalarValue.decimal128(Int64(0), Int64(15), 2, 1)
    assert_false(_prunes(md, _cmp(BIN_LT, "dec", one_and_a_half.copy())))
    assert_false(_prunes(md, _cmp(BIN_LE, "dec", one_and_a_half.copy())))
    assert_false(_prunes(md, _cmp(BIN_EQ, "dec", one_and_a_half.copy())))
    assert_false(_all(md, _cmp(BIN_GT, "dec", one_and_a_half.copy())))
    assert_false(_all(md, _cmp(BIN_GE, "dec", one_and_a_half.copy())))
    assert_false(_all(md, _cmp(BIN_NE, "dec", one_and_a_half.copy())))
    # The literal on the left, and a literal with more scale than the column
    # (0.065 against scale 2).
    assert_false(_prunes(md, _rcmp(BIN_GT, one_and_a_half.copy(), "dec")))
    assert_false(_all(md, _rcmp(BIN_LT, one_and_a_half.copy(), "dec")))
    var over_scale = ScalarValue.decimal128(Int64(0), Int64(65), 4, 3)
    assert_false(_prunes(md, _cmp(BIN_LT, "dec", over_scale.copy())))
    assert_false(_all(md, _cmp(BIN_GT, "dec", over_scale.copy())))
    # And under an AND / OR of two such comparisons.
    assert_false(
        _prunes(
            md,
            Expr.binary(
                BIN_AND,
                _cmp(BIN_GE, "dec", ScalarValue.decimal128(Int64(0), Int64(5), 2, 1)),
                _cmp(BIN_LE, "dec", ScalarValue.decimal128(Int64(0), Int64(7), 2, 1)),
            ),
        )
    )


def test_conservative_cases() raises:
    var md = _flat()
    assert_false(_prunes(md, _cmp(BIN_EQ, "n", _int(99))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "t", _int(99))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "i", ScalarValue.from_string("x"))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "i", ScalarValue.from_float(99.0))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "d", _int(99))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "s", _int(99))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "missing", _int(99))))
    assert_false(_prunes(md, Expr.binary(BIN_EQ, Expr.col_ref("i"), Expr.col_ref("j"))))
    assert_false(_prunes(md, Expr.col_ref("i")))


def test_all_match_needs_zero_nulls() raises:
    var schema: List[SchemaElement] = [
        _group("schema", 3),
        _leaf("p", ParquetType.INT64),
        _leaf("q", ParquetType.INT64),
        _leaf("r", ParquetType.INT64),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, _i64(10), _i64(20), 0),
        _chunk(ParquetType.INT64, _i64(10), _i64(20), 1),
        _chunk(ParquetType.INT64, _i64(10), _i64(20), None),
    ]
    var md = _file(schema^, columns^)
    assert_true(_all(md, _cmp(BIN_GE, "p", _int(10))))
    assert_false(_all(md, _cmp(BIN_GT, "p", _int(10))))
    assert_true(_all(md, _cmp(BIN_NE, "p", _int(9))))
    assert_false(_all(md, _cmp(BIN_NE, "p", _int(15))))
    assert_true(_all(md, _rcmp(BIN_GT, _int(21), "p")))
    assert_false(_all(md, _cmp(BIN_GE, "q", _int(10))))
    assert_false(_all(md, _cmp(BIN_GE, "r", _int(10))))
    assert_true(_all(md, Expr.binary(BIN_AND, _cmp(BIN_GE, "p", _int(10)), _cmp(BIN_LE, "p", _int(20)))))
    assert_false(_all(md, Expr.binary(BIN_AND, _cmp(BIN_GE, "p", _int(10)), _cmp(BIN_LE, "p", _int(19)))))
    assert_true(_all(md, Expr.binary(BIN_OR, _cmp(BIN_GE, "q", _int(10)), _cmp(BIN_LE, "p", _int(20)))))


def test_all_match_types() raises:
    var md = _flat()
    assert_true(_all(md, _cmp(BIN_LE, "j", _int(5))))
    assert_false(_all(md, _cmp(BIN_LE, "j", _int(4))))
    # u's max is 2**64 - 1: not every row is below 5. Read signed, the range
    # was [0, -1] and every row was.
    assert_false(_all(md, _cmp(BIN_LT, "u", _int(5))))
    assert_true(_all(md, _cmp(BIN_GT, "u", _int(-1))))
    assert_false(_all(md, _cmp(BIN_LT, "w", _int(5))))
    assert_true(_all(md, _cmp(BIN_GE, "w", _int(1))))
    # Floating point and strings are declined.
    assert_false(_all(md, _cmp(BIN_LT, "d", ScalarValue.from_float(9.0))))
    assert_false(_all(md, _cmp(BIN_GE, "s", ScalarValue.from_string("a"))))


def test_all_match_row_count() raises:
    var schema: List[SchemaElement] = [_group("schema", 1), _leaf("k", ParquetType.INT64)]
    var groups = List[RowGroup]()
    var c0: List[ColumnChunk] = [_chunk(ParquetType.INT64, _i64(0), _i64(9))]
    var c1: List[ColumnChunk] = [_chunk(ParquetType.INT64, _i64(50), _i64(60))]
    var c2: List[ColumnChunk] = [_chunk(ParquetType.INT64, _i64(5), _i64(8))]
    groups.append(RowGroup(columns=c0^, total_byte_size=0, num_rows=100))
    groups.append(RowGroup(columns=c1^, total_byte_size=0, num_rows=7))
    groups.append(RowGroup(columns=c2^, total_byte_size=0, num_rows=30))
    var md = FileMetaData(version=2, schema=schema^, num_rows=137, row_groups=groups^)
    # k < 10: groups 0 and 2 all match, group 1 is pruned.
    var n = all_match_row_count(md, _cmp(BIN_LT, "k", _int(10)))
    assert_true(Bool(n))
    assert_equal(n.value(), 130)
    # k < 8: groups 0 and 2 straddle.
    assert_false(Bool(all_match_row_count(md, _cmp(BIN_LT, "k", _int(8)))))
    # k > 100: every group pruned, the count is 0.
    var z = all_match_row_count(md, _cmp(BIN_GT, "k", _int(100)))
    assert_true(Bool(z))
    assert_equal(z.value(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
