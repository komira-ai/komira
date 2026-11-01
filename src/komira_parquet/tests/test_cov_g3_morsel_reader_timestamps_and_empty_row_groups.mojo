# =============================================================================
# ParquetMorselReader: a row group of no rows between two others, and an INT64
# column whose footer carries a LogicalType TIMESTAMP unit.
#
# What each test proves:
#   * morsels skip a row group that holds no rows and continue with the next:
#     the row counts and values read are those of the other row groups, in
#     order, and the reader ends exhausted;
#   * an INT64 column whose schema element names a TIMESTAMP unit is decoded
#     with the unit-correct Arrow timestamp type, through the whole-chunk
#     decode and through the one-pass selection decode, with the stored
#     values unchanged.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection, ParquetMorselReader
from komira_parquet.selection_vector import SelectionInterval
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file


def _v(r: Int) -> Int:
    return r * 3 + 11


def _file(name: String, var rows_per_group: List[Int], total: Int) raises -> String:
    var vals = List[Int]()
    for r in range(total):
        vals.append(_v(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("v", vals^))
    var path = test_tmpdir() + "/" + name
    write_parquet_file(path, cols, TestFileLayout(rows_per_group^, 16, False))
    return path^


def test_morsels_skip_a_row_group_with_no_rows() raises:
    var path = _file("empty_middle.parquet", [30, 0, 20], 50)
    var r = ParquetMorselReader.open(path, 100)
    var sizes = List[Int]()
    var first = 0
    while True:
        var m = r.next_morsel()
        if not m:
            break
        var b = m.take()
        var p = b.column_at(0).as_primitive[DType.int64]()
        for i in range(b.num_rows()):
            assert_equal(Int(p.get(i)), _v(first + i))
        first += b.num_rows()
        sizes.append(b.num_rows())
    assert_equal(len(sizes), 2)
    assert_equal(sizes[0], 30)
    assert_equal(sizes[1], 20)
    assert_equal(first, 50)
    assert_true(r.is_exhausted())


def _timestamp_reader(name: String, unit: Int) raises -> ParquetMorselReader:
    var path = _file(name, [40, 40], 80)
    var reader = ParquetFileReader[LocalFs[NoopSink]].open(path)
    var md = parse_full_metadata(reader.metadata_bytes.view_range_ro(0, reader.metadata_length))
    md.schema[1].logical_timestamp_unit = Optional[Int](unit)
    return ParquetMorselReader(reader^, md^, 50, ColumnProjection.all())


def test_a_timestamp_unit_types_the_decoded_chunk() raises:
    var r = _timestamp_reader("ts_whole.parquet", 2)
    var b = r.decode_columns_for_rg(1, [0])
    ref c = b.column_at(0)
    assert_true(c.arrow_type == ArrowType.TIMESTAMP_US)
    assert_equal(c.length(), 40)
    for i in range(40):
        assert_equal(Int(c._data.view_ro().get_typed[Int64](i)), _v(40 + i))


def test_a_timestamp_unit_types_the_selection_decode() raises:
    var r = _timestamp_reader("ts_sel.parquet", 3)
    var ivls = List[SelectionInterval]()
    ivls.append(SelectionInterval(UInt32(2), UInt32(4)))
    ivls.append(SelectionInterval(UInt32(14), UInt32(3)))
    var sel: List[Int] = [2, 3, 4, 5, 20, 21, 22]
    var got = r.try_decode_column_with_selection(1, 0, Span(ivls), len(sel))
    assert_true(got.__bool__(), "the gather takes a PLAIN chunk")
    var c = got.take()
    assert_true(c.arrow_type == ArrowType.TIMESTAMP_NS)
    assert_equal(c.length(), len(sel))
    for k in range(len(sel)):
        assert_equal(Int(c._data.view_ro().get_typed[Int64](k)), _v(40 + sel[k]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
