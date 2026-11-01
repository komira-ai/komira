# `decode_column_chunk_from_bytes` and `_nullable` (bytes_decode) on schema
# annotations: an INT64 chunk whose schema element carries a LogicalType
# TIMESTAMP unit decodes to the unit's Arrow timestamp type with the stored
# values unchanged, and a schema element with no repetition type is read as
# nullable (only REQUIRED has no definition levels).

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_buffer.byte_view import ByteView
from komira_parquet.bytes_decode import (
    ByteRange,
    _nullable,
    decode_column_chunk_from_bytes,
)
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData, SchemaElement
from komira_parquet_api.types import FieldRepetitionType, ParquetType
from komira_test_parquet_file import TestColumn, TestFileLayout, parquet_file_bytes

comptime _ROWS = 90


# a: INT64 REQUIRED; b: INT32 OPTIONAL; d: UTF8 dictionary; n: INT64
# dictionary; m: INT32 dictionary OPTIONAL.
def _a(r: Int) -> Int:
    return 1000 - r * 3


def _b_null(r: Int) -> Bool:
    return r % 6 == 1


def _b(r: Int) -> Int:
    return r * 7


def _d(r: Int) -> String:
    return "d" + String(r % 5)


def _n(r: Int) -> Int:
    return (r % 3) * 1_000_000_007


def _m_null(r: Int) -> Bool:
    return r % 4 == 0


def _m(r: Int) -> Int:
    return -(r % 6)


def _file() raises -> List[UInt8]:
    var a = List[Int]()
    var b = List[Int]()
    var bn = List[Bool]()
    var d = List[String]()
    var n = List[Int]()
    var m = List[Int]()
    var mn = List[Bool]()
    for r in range(_ROWS):
        a.append(_a(r))
        b.append(_b(r))
        bn.append(_b_null(r))
        d.append(_d(r))
        n.append(_n(r))
        m.append(_m(r))
        mn.append(_m_null(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int32("b", b^).with_nulls(bn^))
    cols.append(TestColumn.string("d", d^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).dict_encoded())
    cols.append(TestColumn.int32("m", m^).with_nulls(mn^).dict_encoded())
    return parquet_file_bytes(cols, TestFileLayout([50, 40], 12, False))


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    var start = n - 8 - flen
    return parse_full_metadata(_view(Span(file)[start : n - 8]))



def test_a_timestamp_unit_on_the_schema_element_retypes_an_int64_chunk() raises:
    var file = _file()
    var md = _footer(file)
    var whole = ByteRange(0, len(file))
    var units: List[Int] = [1, 2, 3]
    var want: List[ArrowType] = [ArrowType.TIMESTAMP_MS, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_NS]
    for k in range(3):
        var elem = md.schema[1].copy()
        elem.logical_timestamp_unit = Optional[Int](units[k])
        var ctx = ColumnDecodeContext()
        var c = decode_column_chunk_from_bytes(
            _view(Span(file)), whole, md.row_groups[0].columns[0], elem, False, ctx
        )
        assert_true(c.arrow_type == want[k], "unit " + String(units[k]))
        assert_equal(c.length(), 50)
        for r in range(50):
            assert_equal(Int(c.as_primitive[DType.int64]().get(r)), _a(r), "row " + String(r))


def test_a_schema_element_without_a_repetition_type_is_nullable() raises:
    var bare = SchemaElement(String("x"), Optional[ParquetType](ParquetType.INT32))
    assert_true(_nullable(bare))
    var required = SchemaElement(
        String("x"), Optional[ParquetType](ParquetType.INT32),
        repetition_type=Optional[FieldRepetitionType](FieldRepetitionType.REQUIRED),
    )
    assert_false(_nullable(required))
    var optional = SchemaElement(
        String("x"), Optional[ParquetType](ParquetType.INT32),
        repetition_type=Optional[FieldRepetitionType](FieldRepetitionType.OPTIONAL),
    )
    assert_true(_nullable(optional))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
