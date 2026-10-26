# =============================================================================
# test_delta_codec.mojo -- the delta object: framed for a few rows, Parquet for
#   more, and both decode.
# =============================================================================
#
#   framed        a small int64 and string batch encodes to a framed object
#                 (tag 1) and decodes to the same values; cells holding zero
#                 bytes, bytes that are not UTF-8 and packed embeddings come back
#                 byte for byte; non-ASCII text is faithful; a batch of zero rows
#                 round-trips; a LARGE_STRING column decodes to STRING; a STRING
#                 column under a LARGE_STRING schema (the way a builder emits it)
#                 is framed too.
#   threshold     FRAMED_MAX_ROWS - 1 rows are framed, FRAMED_MAX_ROWS rows are
#                 Parquet.
#   fallback      a batch with a null, with a column that is neither int64 nor a
#                 string, or with more rows than the threshold is written as
#                 Parquet (tag 0) and the lossless values survive the Parquet
#                 round trip; a batch with no column is refused.
#   same values   the framed object and the Parquet object of the same rows
#                 decode to the same values, so a reader that merges deltas does
#                 not care which framing a delta used.
#   size          a one-row delta is a small fraction of the Parquet file of the
#                 same row.
#   tag           delta_object_is_framed reads the tag and refuses an empty body
#                 and an unknown tag; delta_object_parquet_bytes strips the tag
#                 of a Parquet object (a file that starts with PAR1) and refuses
#                 a framed one.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_kg_format import (
    FRAME_TAG_FRAMED,
    FRAME_TAG_PARQUET,
    FRAMED_MAX_ROWS,
    decode_framed_delta_to_batch,
    delta_object_is_framed,
    delta_object_parquet_bytes,
    encode_delta_table_object,
    pack_embedding_f32,
)
from komira_parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`, so the
    # list it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _read_parquet(file: List[UInt8]) raises -> RecordBatch:
    """TEST SUPPORT: decode a whole in-memory Parquet file with the reader
    (a separate implementation from the writer under test)."""
    var n = len(file)
    assert_true(n >= 12)
    var par1 = String("PAR1")
    var magic = par1.as_bytes()
    for k in range(4):
        assert_equal(file[k], magic[k])
        assert_equal(file[n - 4 + k], magic[k])
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    var md = parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))
    var groups = Slab[RecordBatch](capacity=len(md.row_groups))
    for g in range(len(md.row_groups)):
        ref rg = md.row_groups[g]
        var br = row_group_byte_range(rg)
        groups.append(
            decode_row_group_from_bytes(
                _view(Span(file)[br.start : br.end]),
                br,
                rg,
                md.schema,
                ColumnProjection.all(),
            )
        )
    if len(groups) == 1:
        var only = groups.pop()
        return only.take()
    return concat_record_batches_nway(groups^)


def _ids(n: Int) -> List[Int64]:
    var v = List[Int64](capacity=n)
    for i in range(n):
        v.append(Int64(1000 + i) * 1000003)
    return v^


def _names(n: Int) -> List[String]:
    var v = List[String](capacity=n)
    for i in range(n):
        v.append("name-" + String(i))
    return v^


def _schema(string_type: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", string_type, False))
    return sb.build()


def _batch(n: Int, string_type: ArrowType = ArrowType.STRING) raises -> RecordBatch:
    """n rows of (id: INT64, name: string) with the schema's string type given.
    The cells are stored in a STRING column whatever the schema says."""
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(_ids(n))
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(_names(n))))
    return rb.build(_schema(string_type))


def _span_equal(a: Span[UInt8, _], b: Span[UInt8, _]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _assert_same_values(a: RecordBatch, b: RecordBatch) raises:
    """Every column of `a` equals the column at the same position of `b`."""
    assert_equal(a.num_columns(), b.num_columns())
    assert_equal(a.num_rows(), b.num_rows())
    for c in range(a.num_columns()):
        var t = a.column_at(c).arrow_type
        if t == ArrowType.INT64:
            var x = a.column_as_primitive_int64(c)
            var y = b.column_as_primitive_int64(c)
            for r in range(a.num_rows()):
                assert_equal(x.get(r), y.get(r))
        else:
            var x = a.column_as_string(c)
            var y = b.column_as_string(c)
            for r in range(a.num_rows()):
                assert_true(
                    _span_equal(x.get_span(r), y.get_span(r)),
                    "column " + String(c) + " row " + String(r) + " differs",
                )


def test_small_batch_is_framed_and_decodes_to_the_same_values() raises:
    var obj = encode_delta_table_object(_batch(5))
    assert_equal(obj[0], FRAME_TAG_FRAMED)
    assert_true(delta_object_is_framed(obj))
    var back = decode_framed_delta_to_batch(obj)
    _assert_same_values(_batch(5), back)
    assert_equal(back.schema.field_name(0), "c0")
    assert_true(back.column_at(0).arrow_type == ArrowType.INT64)
    assert_true(back.column_at(1).arrow_type == ArrowType.STRING)


def test_cells_with_zero_bytes_and_non_utf8_bytes_survive() raises:
    var cells = List[List[UInt8]]()
    cells.append([0, 1, 2, 0, 255, 254])
    cells.append([])
    cells.append([0xC3, 0x28, 0, 0])
    var e: List[Float32] = [1.5, -0.0, 3.0e-39, 0.0]  # includes zero bytes
    var packed = pack_embedding_f32(e)
    var pb = List[UInt8]()
    for x in packed.as_bytes():
        pb.append(x)
    cells.append(pb^)
    var ids: List[Int64] = [1, 2, 3, 4]
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids^)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_byte_lists(cells.copy())))
    var batch = rb.build(_schema(ArrowType.STRING))
    var obj = encode_delta_table_object(batch^)
    assert_true(delta_object_is_framed(obj))
    var back = decode_framed_delta_to_batch(obj)
    var col = back.column_as_string(1)
    assert_equal(len(col), 4)
    for r in range(4):
        assert_true(
            _span_equal(col.get_span(r), Span(cells[r])),
            "cell " + String(r) + " changed",
        )


def test_non_ascii_text_is_faithful() raises:
    var names: List[String] = ["zoë", "日本語", "ключ", ""]
    var ids: List[Int64] = [1, 2, 3, 4]
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids^)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(names.copy())))
    var back = decode_framed_delta_to_batch(
        encode_delta_table_object(rb.build(_schema(ArrowType.STRING)))
    )
    var col = back.column_as_string(1)
    for r in range(4):
        assert_equal(col.get(r), names[r])


def test_zero_rows_round_trip() raises:
    var obj = encode_delta_table_object(_batch(0))
    assert_true(delta_object_is_framed(obj))
    var back = decode_framed_delta_to_batch(obj)
    assert_equal(back.num_rows(), 0)
    assert_equal(back.num_columns(), 2)


def test_string_column_under_a_large_string_schema_is_framed() raises:
    var obj = encode_delta_table_object(_batch(3, ArrowType.LARGE_STRING))
    assert_true(delta_object_is_framed(obj))
    _assert_same_values(_batch(3), decode_framed_delta_to_batch(obj))


def test_large_string_column_decodes_to_string() raises:
    var ids: List[Int64] = [10, 20]
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids^)
        )
    )
    var vals: List[String] = ["wide-a", "wide-b"]
    rb.add_column(
        Column.from_large_string(LargeStringArray.from_strings(vals.copy()))
    )
    var obj = encode_delta_table_object(rb.build(_schema(ArrowType.LARGE_STRING)))
    assert_true(delta_object_is_framed(obj))
    var back = decode_framed_delta_to_batch(obj)
    assert_true(back.column_at(1).arrow_type == ArrowType.STRING)
    assert_equal(back.column_as_string(1).get(1), "wide-b")


def test_threshold_is_the_row_count() raises:
    assert_true(delta_object_is_framed(encode_delta_table_object(_batch(FRAMED_MAX_ROWS - 1))))
    assert_false(delta_object_is_framed(encode_delta_table_object(_batch(FRAMED_MAX_ROWS))))


def test_a_batch_over_the_threshold_is_parquet_and_reads_back() raises:
    var n = FRAMED_MAX_ROWS + 36
    var obj = encode_delta_table_object(_batch(n))
    assert_equal(obj[0], FRAME_TAG_PARQUET)
    assert_false(delta_object_is_framed(obj))
    var back = _read_parquet(delta_object_parquet_bytes(obj))
    _assert_same_values(_batch(n), back)


def test_framed_and_parquet_objects_of_the_same_rows_decode_the_same() raises:
    var framed = encode_delta_table_object(_batch(10))
    var small_as_parquet = encode_delta_table_object(_batch(FRAMED_MAX_ROWS))
    assert_true(delta_object_is_framed(framed))
    assert_false(delta_object_is_framed(small_as_parquet))
    var from_framed = decode_framed_delta_to_batch(framed)
    var from_parquet = _read_parquet(delta_object_parquet_bytes(small_as_parquet))
    # The first ten rows of the 64-row Parquet delta are the framed delta's rows.
    var x = from_framed.column_as_primitive_int64(0)
    var y = from_parquet.column_as_primitive_int64(0)
    var xs = from_framed.column_as_string(1)
    var ys = from_parquet.column_as_string(1)
    for r in range(10):
        assert_equal(x.get(r), y.get(r))
        assert_equal(xs.get(r), ys.get(r))


def test_embedding_cells_survive_the_parquet_path() raises:
    var n = FRAMED_MAX_ROWS + 6
    var cells = List[List[UInt8]]()
    for i in range(n):
        var v: List[Float32] = [Float32(i) + 0.5, 0.0, -1.25, 2.0e-5]
        var packed = pack_embedding_f32(v)
        var pb = List[UInt8]()
        for x in packed.as_bytes():
            pb.append(x)
        cells.append(pb^)
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(_ids(n))
        )
    )
    rb.add_column(Column.from_string(StringArray.from_byte_lists(cells.copy())))
    var obj = encode_delta_table_object(rb.build(_schema(ArrowType.STRING)))
    assert_false(delta_object_is_framed(obj))
    var back = _read_parquet(delta_object_parquet_bytes(obj))
    var col = back.column_as_string(1)
    assert_equal(len(col), n)
    for r in range(n):
        assert_true(
            _span_equal(col.get_span(r), Span(cells[r])),
            "embedding cell " + String(r) + " changed on the Parquet path",
        )


def test_a_batch_with_a_null_is_parquet() raises:
    var ids: List[Int64] = [1, 2, 3]
    var vals: List[String] = ["a", "", "c"]
    var valid: List[Bool] = [True, False, True]
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids^)
        )
    )
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(vals, valid))
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, True))
    var obj = encode_delta_table_object(rb.build(sb.build()))
    assert_false(delta_object_is_framed(obj))
    var back = _read_parquet(delta_object_parquet_bytes(obj))
    assert_equal(back.num_rows(), 3)
    assert_true(back.column_as_string(1).is_null(1))
    assert_false(back.column_as_string(1).is_null(0))


def test_a_column_that_is_not_int64_or_string_makes_it_parquet() raises:
    var f: List[Float64] = [0.5, 1.5]
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(f^)
        )
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("score", ArrowType.FLOAT64, False))
    var obj = encode_delta_table_object(rb.build(sb.build()))
    assert_false(delta_object_is_framed(obj))
    var back = _read_parquet(delta_object_parquet_bytes(obj))
    assert_equal(back.column_as_primitive_float64(0).get(1), 1.5)


def test_a_batch_with_no_column_is_refused() raises:
    var rb = RecordBatchBuilder()
    var sb = SchemaBuilder()
    with assert_raises(contains="batch has no columns"):
        _ = encode_delta_table_object(rb.build(sb.build()))


def test_a_one_row_framed_delta_is_far_smaller_than_the_parquet_file() raises:
    var framed = encode_delta_table_object(_batch(1))
    var parquet = write_record_batch_to_parquet_bytes(_batch(1))
    assert_true(delta_object_is_framed(framed))
    assert_true(
        len(framed) * 4 < len(parquet),
        "framed " + String(len(framed)) + " bytes, Parquet " + String(len(parquet)),
    )


def test_tag_reader_refuses_empty_and_unknown() raises:
    with assert_raises(contains="empty delta object body"):
        _ = delta_object_is_framed(List[UInt8]())
    var bad: List[UInt8] = [7, 0, 0]
    with assert_raises(contains="unknown framing tag 7"):
        _ = delta_object_is_framed(bad)
    with assert_raises(contains="unknown framing tag 7"):
        _ = delta_object_parquet_bytes(bad)


def test_parquet_bytes_are_the_object_without_its_tag() raises:
    var obj = encode_delta_table_object(_batch(FRAMED_MAX_ROWS + 1))
    var file = delta_object_parquet_bytes(obj)
    assert_equal(len(file), len(obj) - 1)
    assert_equal(file[0], UInt8(ord("P")))
    assert_equal(file[3], UInt8(ord("1")))
    with assert_raises(contains="is framed, not Parquet"):
        _ = delta_object_parquet_bytes(encode_delta_table_object(_batch(2)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
