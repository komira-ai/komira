# decode_parquet_file_from_bytes: a whole in-memory Parquet file to one batch,
# on files written by komira_test_parquet_file:
#   - every value and null of int64, int32, double, plain string and
#     dictionary-encoded string columns, nullable and not, over several row
#     groups of several pages: the row groups come back concatenated in file
#     order, and equal to the same rows written as one row group;
#   - a projection returns only the listed columns, in the listed order;
#   - refusals, each with its own sentence: an empty buffer, a buffer shorter
#     than the smallest file, a truncated file (at several cut points), a bad
#     leading magic, a bad trailing magic, a footer length past the start of
#     the file, a footer of 0xFF bytes, a file with no row group (a table of
#     no rows from this writer), and a column chunk that names bytes outside
#     the data region.
# komira_parquet_writer's tests cover the files that writer produces.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_parquet.file_decode import decode_parquet_file_from_bytes
from komira_parquet.morsel_reader import ColumnProjection
from komira_test_parquet_file import TestColumn, TestFileLayout, parquet_file_bytes

comptime _ROWS = 120

# id: INT64; score: DOUBLE OPTIONAL (null at r % 7 == 2); rank: INT32;
# name: UTF8 OPTIONAL (null at r % 11 == 3); tag: UTF8 dictionary.


def _score_null(r: Int) -> Bool:
    return r % 7 == 2


def _name_null(r: Int) -> Bool:
    return r % 11 == 3


def _columns(rows: Int) -> List[TestColumn]:
    var id = List[Int]()
    var score = List[Float64]()
    var sn = List[Bool]()
    var rank = List[Int]()
    var name = List[String]()
    var nn = List[Bool]()
    var tag = List[String]()
    for r in range(rows):
        id.append(r * 1000003 - 5)
        score.append(Float64(r) / 8.0)
        sn.append(_score_null(r))
        rank.append(r * 3 - 700)
        name.append(String("row-") + String(r))
        nn.append(_name_null(r))
        tag.append(String("t") + String(r % 5))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("id", id^))
    cols.append(TestColumn.float64("score", score^).with_nulls(sn^))
    cols.append(TestColumn.int32("rank", rank^))
    cols.append(TestColumn.string("name", name^).with_nulls(nn^))
    cols.append(TestColumn.string("tag", tag^).dict_encoded())
    return cols^


def _file(layout: TestFileLayout, rows: Int = _ROWS) raises -> List[UInt8]:
    return parquet_file_bytes(_columns(rows), layout.copy())


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`; the list
    # it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _decode(file: List[UInt8]) raises -> RecordBatch:
    return decode_parquet_file_from_bytes(_view(Span(file)))


def _check_rows(b: RecordBatch) raises:
    assert_equal(b.num_rows(), _ROWS)
    assert_equal(b.num_columns(), 5)
    assert_equal(b.schema.field_name(0), "id")
    assert_equal(b.schema.field_name(4), "tag")
    for r in range(_ROWS):
        var w = "row " + String(r)
        assert_equal(
            Int(b.column_at(0).as_primitive[DType.int64]().get(r)),
            r * 1000003 - 5,
            w,
        )
        assert_equal(b.column_at(1).is_null_at(r), _score_null(r), w)
        if not _score_null(r):
            assert_equal(
                b.column_at(1).as_primitive[DType.float64]().get(r),
                Float64(r) / 8.0,
                w,
            )
        assert_equal(
            Int(b.column_at(2).as_primitive[DType.int32]().get(r)),
            r * 3 - 700,
            w,
        )
        assert_equal(b.column_at(3).is_null_at(r), _name_null(r), w)
        if not _name_null(r):
            assert_equal(
                b.column_at(3).as_string().get(r), String("row-") + String(r), w
            )
        assert_equal(
            b.column_at(4).as_string().get(r), String("t") + String(r % 5), w
        )


def _footer_len(file: List[UInt8]) -> Int:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return flen


def test_one_row_group_round_trips() raises:
    _check_rows(_decode(_file(TestFileLayout.single())))


def test_row_groups_and_pages_concatenate_in_file_order() raises:
    _check_rows(_decode(_file(TestFileLayout([50, 40, 30], 12, False))))
    _check_rows(_decode(_file(TestFileLayout([1, 119], 0, True))))


def test_a_projection_returns_the_listed_columns_in_order() raises:
    var file = _file(TestFileLayout([70, 50], 16, False))
    var picked = decode_parquet_file_from_bytes(
        _view(Span(file)), ColumnProjection.columns([3, 0])
    )
    assert_equal(picked.num_columns(), 2)
    assert_equal(picked.num_rows(), _ROWS)
    assert_equal(picked.schema.field_name(0), "name")
    assert_equal(picked.schema.field_name(1), "id")
    for r in range(_ROWS):
        assert_equal(picked.column_at(0).is_null_at(r), _name_null(r))
        assert_equal(
            Int(picked.column_at(1).as_primitive[DType.int64]().get(r)),
            r * 1000003 - 5,
        )


def test_an_empty_buffer_is_refused() raises:
    var empty = List[UInt8]()
    with assert_raises(contains="0 bytes is too short to be a Parquet file"):
        _ = _decode(empty)


def test_a_buffer_shorter_than_the_smallest_file_is_refused() raises:
    var file = _file(TestFileLayout.single())
    var short = List[UInt8]()
    for i in range(11):
        short.append(file[i])
    with assert_raises(contains="11 bytes is too short"):
        _ = _decode(short)


def test_a_truncated_file_is_refused_at_every_cut() raises:
    var file = _file(TestFileLayout([60, 60], 0, False))
    var n = len(file)
    var cuts = [12, n // 4, n // 2, n - 200, n - 20, n - 9, n - 8, n - 1]
    for cut in cuts:
        var part = List[UInt8]()
        for i in range(cut):
            part.append(file[i])
        var raised = False
        try:
            _ = _decode(part)
        except e:
            raised = String(e).byte_length() > 0
        assert_true(raised, "cut at " + String(cut) + " was not refused")


def test_a_bad_leading_magic_is_refused() raises:
    var file = _file(TestFileLayout.single())
    file[0] = UInt8(ord("X"))
    with assert_raises(contains="missing PAR1 magic"):
        _ = _decode(file)


def test_a_bad_trailing_magic_is_refused() raises:
    var file = _file(TestFileLayout.single())
    file[len(file) - 1] = UInt8(ord("X"))
    with assert_raises(contains="missing PAR1 magic"):
        _ = _decode(file)


def test_a_footer_length_past_the_start_of_the_file_is_refused() raises:
    var file = _file(TestFileLayout.single())
    file[len(file) - 5] = UInt8(0x7F)
    with assert_raises(contains="does not fit in a file of"):
        _ = _decode(file)


def test_a_footer_length_of_zero_is_refused() raises:
    var file = _file(TestFileLayout.single())
    var n = len(file)
    for k in range(4):
        file[n - 8 + k] = UInt8(0)
    with assert_raises(contains="footer length 0"):
        _ = _decode(file)


def test_a_footer_that_is_not_thrift_is_refused() raises:
    var file = _file(TestFileLayout.single())
    var n = len(file)
    for i in range(n - 8 - _footer_len(file), n - 8):
        file[i] = UInt8(0xFF)
    var raised = False
    try:
        _ = _decode(file)
    except e:
        raised = String(e).byte_length() > 0
    assert_true(raised, "a footer of 0xFF bytes was not refused")


def test_a_table_of_no_rows_has_no_row_group_and_is_refused() raises:
    var file = _file(TestFileLayout.single(), 0)
    with assert_raises(contains="the file has no row group"):
        _ = _decode(file)


def test_a_chunk_outside_the_data_region_is_refused() raises:
    # Drop 16 bytes from the end of the data region: the last chunk now ends
    # past where the footer starts.
    var file = _file(TestFileLayout.single())
    var n = len(file)
    var footer_start = n - 8 - _footer_len(file)
    var cut = List[UInt8]()
    for i in range(footer_start - 16):
        cut.append(file[i])
    for i in range(footer_start, n):
        cut.append(file[i])
    with assert_raises(contains="outside the data region"):
        _ = _decode(cut)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
