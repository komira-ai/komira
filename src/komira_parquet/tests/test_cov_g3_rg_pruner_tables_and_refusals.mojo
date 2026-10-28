# =============================================================================
# Row-group pruning and all-match: the operator tables of every comparison
# kind, the swapped literal-on-the-left forms, and every refusal path.
#
# What each test proves:
#   * UINT_64 columns answer all six operators in unsigned order, for a prune
#     and for an all-match, and a negative literal is below every value;
#   * a statistics block with short min/max bytes (INT32, FLOAT, DOUBLE,
#     UINT_64, INT64), or without min/max at all, never prunes and never
#     proves all-match;
#   * DOUBLE <=, BYTE_ARRAY != on a single-valued range and >= prune exactly
#     when the range rules the row out;
#   * `literal op column` is rewritten to `column op' literal` for every
#     operator, for prune and for all-match;
#   * an arithmetic operator, a comparison of two columns, a bare column, an
#     empty schema, a row group with fewer chunks than the schema has leaves,
#     a literal of the wrong kind and a missing null count all decline;
#   * all-match combines AND (every side) and OR (either side);
#   * the schema helpers answer "none" for an index outside the schema or a
#     leaf outside the row group.
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
    CONVERTED_TYPE_UINT_64,
    CompressionCodec,
    Encoding,
    ParquetType,
)
from komira_plan_expr.expr import (
    BIN_ADD,
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
from komira_parquet.rg_pruner import (
    _converted_type,
    _is_decimal,
    _stats_of,
    can_prune_row_group,
    rg_all_match_row_group,
)


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



def _uchunk(mn: UInt64, mx: UInt64) -> ColumnChunk:
    return _chunk(ParquetType.INT64, _le(mn, 8), _le(mx, 8))


# Leaves: ii INT64 [10, 20]; jj INT32 [-5, 5]; uu UINT_64 [10, 20];
# uv UINT_64 [7, 7]; ds DOUBLE [1.5, 2.5]; ff FLOAT [-1, 1];
# sb BYTE_ARRAY ["b", "b"]; sd BYTE_ARRAY ["b", "d"];
# short32 INT32, shortf FLOAT, shortd DOUBLE, shortu UINT_64 and short64 INT64
# each with 2-byte statistics; nominmax INT64 with only a null count;
# ww UINT_32 with 2-byte statistics.
def _file_all() -> FileMetaData:
    var schema: List[SchemaElement] = [
        _group("schema", 14),
        _leaf("ii", ParquetType.INT64),
        _leaf("jj", ParquetType.INT32),
        _leaf("uu", ParquetType.INT64, CONVERTED_TYPE_UINT_64),
        _leaf("uv", ParquetType.INT64, CONVERTED_TYPE_UINT_64),
        _leaf("ds", ParquetType.DOUBLE),
        _leaf("ff", ParquetType.FLOAT),
        _leaf("sb", ParquetType.BYTE_ARRAY),
        _leaf("sd", ParquetType.BYTE_ARRAY),
        _leaf("short32", ParquetType.INT32),
        _leaf("shortf", ParquetType.FLOAT),
        _leaf("shortd", ParquetType.DOUBLE),
        _leaf("shortu", ParquetType.INT64, CONVERTED_TYPE_UINT_64),
        _leaf("short64", ParquetType.INT64),
        _leaf("nominmax", ParquetType.INT64),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(ParquetType.INT64, _i64(10), _i64(20)),
        _chunk(ParquetType.INT32, _i32(-5), _i32(5)),
        _uchunk(10, 20),
        _uchunk(7, 7),
        _chunk(ParquetType.DOUBLE, _f64(1.5), _f64(2.5)),
        _chunk(ParquetType.FLOAT, _f32(-1.0), _f32(1.0)),
        _chunk(ParquetType.BYTE_ARRAY, _str("b"), _str("b")),
        _chunk(ParquetType.BYTE_ARRAY, _str("b"), _str("d")),
        _chunk(ParquetType.INT32, _le(1, 2), _le(2, 2)),
        _chunk(ParquetType.FLOAT, _le(1, 2), _le(2, 2)),
        _chunk(ParquetType.DOUBLE, _le(1, 2), _le(2, 2)),
        _chunk(ParquetType.INT64, _le(1, 4), _le(2, 4)),
        _chunk(ParquetType.INT64, _le(1, 2), _le(2, 2)),
        _chunk(ParquetType.INT64, None, None),
    ]
    return _file(schema^, columns^)


def _prunes(md: FileMetaData, e: Expr) -> Bool:
    return can_prune_row_group(md.row_groups[0], md, e)


def _all(md: FileMetaData, e: Expr) -> Bool:
    return rg_all_match_row_group(md.row_groups[0], md, e)


def test_unsigned_64_prune_table_for_every_operator() raises:
    var md = _file_all()
    # uu is [10, 20] read unsigned.
    assert_true(_prunes(md, _cmp(BIN_EQ, "uu", _int(9))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "uu", _int(15))))
    assert_true(_prunes(md, _cmp(BIN_LT, "uu", _int(10))))
    assert_false(_prunes(md, _cmp(BIN_LT, "uu", _int(11))))
    assert_true(_prunes(md, _cmp(BIN_LE, "uu", _int(9))))
    assert_false(_prunes(md, _cmp(BIN_LE, "uu", _int(10))))
    assert_true(_prunes(md, _cmp(BIN_GT, "uu", _int(20))))
    assert_false(_prunes(md, _cmp(BIN_GT, "uu", _int(19))))
    assert_true(_prunes(md, _cmp(BIN_GE, "uu", _int(21))))
    assert_false(_prunes(md, _cmp(BIN_GE, "uu", _int(20))))
    assert_false(_prunes(md, _cmp(BIN_NE, "uu", _int(15))))
    # uv is single-valued: only != its value prunes.
    assert_true(_prunes(md, _cmp(BIN_NE, "uv", _int(7))))
    assert_false(_prunes(md, _cmp(BIN_NE, "uv", _int(8))))
    # A negative literal is below every unsigned value.
    assert_true(_prunes(md, _cmp(BIN_EQ, "uu", _int(-1))))
    assert_true(_prunes(md, _cmp(BIN_LT, "uu", _int(-1))))
    assert_true(_prunes(md, _cmp(BIN_LE, "uu", _int(-1))))
    assert_false(_prunes(md, _cmp(BIN_NE, "uu", _int(-1))))
    assert_false(_prunes(md, _cmp(BIN_GT, "uu", _int(-1))))
    assert_false(_prunes(md, _cmp(BIN_GE, "uu", _int(-1))))


def test_unsigned_64_all_match_table_for_every_operator() raises:
    var md = _file_all()
    assert_true(_all(md, _cmp(BIN_EQ, "uv", _int(7))))
    assert_false(_all(md, _cmp(BIN_EQ, "uv", _int(8))))
    assert_false(_all(md, _cmp(BIN_EQ, "uu", _int(15))))
    assert_true(_all(md, _cmp(BIN_NE, "uu", _int(9))))
    assert_true(_all(md, _cmp(BIN_NE, "uu", _int(21))))
    assert_false(_all(md, _cmp(BIN_NE, "uu", _int(15))))
    assert_true(_all(md, _cmp(BIN_LT, "uu", _int(21))))
    assert_false(_all(md, _cmp(BIN_LT, "uu", _int(20))))
    assert_true(_all(md, _cmp(BIN_LE, "uu", _int(20))))
    assert_false(_all(md, _cmp(BIN_LE, "uu", _int(19))))
    assert_true(_all(md, _cmp(BIN_GT, "uu", _int(9))))
    assert_false(_all(md, _cmp(BIN_GT, "uu", _int(10))))
    assert_true(_all(md, _cmp(BIN_GE, "uu", _int(10))))
    assert_false(_all(md, _cmp(BIN_GE, "uu", _int(11))))
    # A negative literal is below every unsigned value.
    assert_true(_all(md, _cmp(BIN_NE, "uu", _int(-1))))
    assert_true(_all(md, _cmp(BIN_GT, "uu", _int(-1))))
    assert_true(_all(md, _cmp(BIN_GE, "uu", _int(-1))))
    assert_false(_all(md, _cmp(BIN_EQ, "uu", _int(-1))))
    assert_false(_all(md, _cmp(BIN_LT, "uu", _int(-1))))
    assert_false(_all(md, _cmp(BIN_LE, "uu", _int(-1))))


def test_signed_all_match_table_for_every_operator() raises:
    var md = _file_all()
    # ii is [10, 20].
    assert_false(_all(md, _cmp(BIN_EQ, "ii", _int(15))))
    assert_true(_all(md, _cmp(BIN_LT, "ii", _int(21))))
    assert_false(_all(md, _cmp(BIN_LT, "ii", _int(20))))
    assert_true(_all(md, _cmp(BIN_LE, "ii", _int(20))))
    assert_true(_all(md, _cmp(BIN_GT, "ii", _int(9))))
    assert_false(_all(md, _cmp(BIN_GT, "ii", _int(10))))
    assert_true(_all(md, _cmp(BIN_NE, "ii", _int(21))))
    assert_true(_all(md, _cmp(BIN_NE, "ii", _int(9))))


def test_double_le_bytes_ge_and_bytes_ne_on_one_value() raises:
    var md = _file_all()
    assert_true(_prunes(md, _cmp(BIN_LE, "ds", ScalarValue.from_float(1.0))))
    assert_false(_prunes(md, _cmp(BIN_LE, "ds", ScalarValue.from_float(1.5))))
    # sb is ["b", "b"].
    assert_true(_prunes(md, _cmp(BIN_NE, "sb", ScalarValue.from_string("b"))))
    assert_false(_prunes(md, _cmp(BIN_NE, "sb", ScalarValue.from_string("c"))))
    assert_false(_prunes(md, _cmp(BIN_NE, "sd", ScalarValue.from_string("b"))))
    # sd is ["b", "d"].
    assert_true(_prunes(md, _cmp(BIN_GE, "sd", ScalarValue.from_string("e"))))
    assert_false(_prunes(md, _cmp(BIN_GE, "sd", ScalarValue.from_string("d"))))
    assert_false(_prunes(md, _cmp(BIN_GE, "sd", ScalarValue.from_string("a"))))


def test_literal_on_the_left_is_rewritten_for_every_operator() raises:
    var md = _file_all()
    # ii is [10, 20]. 25 < ii means ii > 25.
    assert_true(_prunes(md, _rcmp(BIN_LT, _int(25), "ii")))
    assert_false(_prunes(md, _rcmp(BIN_LT, _int(15), "ii")))
    # 9 >= ii means ii <= 9.
    assert_true(_prunes(md, _rcmp(BIN_GE, _int(9), "ii")))
    assert_false(_prunes(md, _rcmp(BIN_GE, _int(10), "ii")))
    # 99 = ii and 99 != ii are symmetric.
    assert_true(_prunes(md, _rcmp(BIN_EQ, _int(99), "ii")))
    assert_false(_prunes(md, _rcmp(BIN_EQ, _int(15), "ii")))
    assert_true(_prunes(md, _rcmp(BIN_NE, _int(7), "uv")))
    # All-match: 20 >= ii, 9 < ii, 21 > ii, 10 <= ii.
    assert_true(_all(md, _rcmp(BIN_GE, _int(20), "ii")))
    assert_false(_all(md, _rcmp(BIN_GE, _int(19), "ii")))
    assert_true(_all(md, _rcmp(BIN_LT, _int(9), "ii")))
    assert_false(_all(md, _rcmp(BIN_LT, _int(10), "ii")))
    assert_true(_all(md, _rcmp(BIN_GT, _int(21), "ii")))
    assert_true(_all(md, _rcmp(BIN_LE, _int(10), "ii")))
    assert_false(_all(md, _rcmp(BIN_LE, _int(11), "ii")))


def test_short_statistics_decline() raises:
    var md = _file_all()
    assert_false(_prunes(md, _cmp(BIN_EQ, "short32", _int(99))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "shortf", ScalarValue.from_float(99.0))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "shortd", ScalarValue.from_float(99.0))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "shortu", _int(99))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "short64", _int(99))))
    assert_false(_all(md, _cmp(BIN_GE, "short32", _int(0))))
    assert_false(_all(md, _cmp(BIN_GE, "shortu", _int(0))))
    assert_false(_all(md, _cmp(BIN_GE, "short64", _int(0))))


def test_statistics_without_min_max_decline() raises:
    var md = _file_all()
    assert_false(_prunes(md, _cmp(BIN_EQ, "nominmax", _int(99))))
    assert_false(_all(md, _cmp(BIN_GE, "nominmax", _int(0))))


def test_literal_of_the_wrong_kind_declines() raises:
    var md = _file_all()
    # INT32 with a float literal, FLOAT with an integer one.
    assert_false(_prunes(md, _cmp(BIN_EQ, "jj", ScalarValue.from_float(99.0))))
    assert_false(_prunes(md, _cmp(BIN_EQ, "ff", _int(99))))
    assert_false(_all(md, _cmp(BIN_EQ, "ii", ScalarValue.from_float(15.0))))


def test_unsupported_shapes_decline() raises:
    var md = _file_all()
    var arithmetic = Expr.binary(BIN_ADD, Expr.col_ref("ii"), Expr.literal(_int(1)))
    assert_false(_prunes(md, arithmetic))
    assert_false(_all(md, arithmetic))
    var two_columns = Expr.binary(BIN_EQ, Expr.col_ref("ii"), Expr.col_ref("jj"))
    assert_false(_all(md, two_columns))
    assert_false(_all(md, Expr.col_ref("ii")))
    assert_false(_all(md, _cmp(BIN_GE, "missing", _int(0))))
    assert_false(_all(md, _cmp(BIN_GE, "ii", ScalarValue.from_string("x"))))


def test_all_match_and_or_combine_both_sides() raises:
    var md = _file_all()
    var yes = _cmp(BIN_GE, "ii", _int(10))
    var no = _cmp(BIN_GT, "ii", _int(10))
    assert_false(_all(md, Expr.binary(BIN_AND, no.copy(), yes.copy())))
    assert_true(_all(md, Expr.binary(BIN_AND, yes.copy(), yes.copy())))
    assert_true(_all(md, Expr.binary(BIN_OR, yes.copy(), no.copy())))
    assert_true(_all(md, Expr.binary(BIN_OR, no.copy(), yes.copy())))
    assert_false(_all(md, Expr.binary(BIN_OR, no.copy(), no.copy())))


def test_empty_schema_resolves_nothing() raises:
    var schema = List[SchemaElement]()
    var columns = List[ColumnChunk]()
    var md = _file(schema^, columns^)
    assert_false(_prunes(md, _cmp(BIN_EQ, "ii", _int(1))))
    assert_false(_all(md, _cmp(BIN_EQ, "ii", _int(1))))


def test_row_group_with_fewer_chunks_than_leaves_declines() raises:
    var schema: List[SchemaElement] = [_group("schema", 2), _leaf("a", ParquetType.INT64), _leaf("b", ParquetType.INT64)]
    var columns: List[ColumnChunk] = [_chunk(ParquetType.INT64, _i64(0), _i64(0))]
    var md = _file(schema^, columns^)
    assert_false(_prunes(md, _cmp(BIN_EQ, "b", _int(5))))
    assert_false(_all(md, _cmp(BIN_EQ, "b", _int(0))))
    assert_true(_prunes(md, _cmp(BIN_EQ, "a", _int(5))))
    assert_false(Bool(_stats_of(md.row_groups[0], 1)))
    assert_false(Bool(_stats_of(md.row_groups[0], -1)))
    assert_true(Bool(_stats_of(md.row_groups[0], 0)))


def test_schema_helpers_decline_an_index_outside_the_schema() raises:
    var md = _file_all()
    assert_equal(_converted_type(md, -1), -1)
    assert_equal(_converted_type(md, 999), -1)
    assert_equal(_converted_type(md, 1), -1)
    assert_equal(_converted_type(md, 3), CONVERTED_TYPE_UINT_64)
    assert_false(_is_decimal(md, -1))
    assert_false(_is_decimal(md, 999))
    assert_false(_is_decimal(md, 1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
