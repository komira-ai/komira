# Parquet field ids (SchemaElement field 9) through the writer and the reader.
#
#   * test_schema_element_roundtrips_with_and_without_a_field_id: a
#     SchemaElement serialized by `ThriftCompactWriter.write_schema_element` and
#     parsed by the reader keeps its field id, keeps every other field beside
#     it, and has none when it was given none.
#   * test_record_batch_field_ids_are_read_back_by_the_footer_parser: the ids
#     given to `write_record_batch_to_parquet_bytes` land on the leaves in
#     column order and not on the root.
#   * test_several_batches_carry_field_ids_on_both_write_paths: the same for
#     `write_record_batches_to_parquet_bytes`, concat-free and concatenated.
#   * test_no_field_ids_writes_the_bytes_of_a_call_without_the_argument: an
#     empty list writes no field 9 and the same bytes as omitting it.
#   * test_a_wrong_number_of_field_ids_is_refused: both entry points name the
#     id count and the column count.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from byte_buffer.byte_view import ByteView
from containers.slab import Slab
from parquet.metadata_parser import _parse_schema_element, parse_full_metadata
from parquet.thrift_compact import ThriftCompactReader
from parquet_api.metadata import FileMetaData, SchemaElement
from parquet_api.types import (
    CompressionCodec,
    FieldRepetitionType,
    ParquetType,
)
from parquet_writer.thrift_writer import ThriftCompactWriter
from parquet_writer import (
    write_record_batch_to_parquet_bytes,
    write_record_batches_to_parquet_bytes,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _batch(start: Int, n: Int) raises -> RecordBatch:
    """Rows start..start+n-1 of an INT32 column `a` and an INT64 column `b`."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT32, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    var a = PrimitiveArray[DType.int32].allocate(n)
    var b = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, Int32(start + i))
        b.set(i, Int64((start + i) * 10))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int32](a))
    rb.add_column(Column.from_primitive[DType.int64](b))
    return rb.build(sb.build())


def _ids(a: Int, b: Int) -> List[Int]:
    var ids = List[Int]()
    ids.append(a)
    ids.append(b)
    return ids^


def _ids_of(n: Int) -> List[Int]:
    var ids = List[Int]()
    for i in range(n):
        ids.append(i + 1)
    return ids^


def _check_ids(file: List[UInt8], a: Int, b: Int) raises:
    var md = _footer(file)
    assert_equal(len(md.schema), 3)
    assert_false(Bool(md.schema[0].field_id))
    assert_equal(md.schema[1].name, "a")
    assert_equal(md.schema[1].field_id.value(), a)
    assert_equal(md.schema[2].name, "b")
    assert_equal(md.schema[2].field_id.value(), b)


def test_schema_element_roundtrips_with_and_without_a_field_id() raises:
    var with_id = SchemaElement(
        name="price",
        type=ParquetType.INT64,
        repetition_type=FieldRepetitionType.OPTIONAL,
        converted_type=5,
        scale=2,
        precision=18,
        field_id=1234,
    )
    var w = ThriftCompactWriter()
    w.write_schema_element(with_id)
    var bytes = w.take_bytes()
    var r = ThriftCompactReader(_view(Span(bytes)))
    var e = _parse_schema_element(r)
    assert_equal(e.name, "price")
    assert_equal(Int(e.type.value().value), Int(ParquetType.INT64.value))
    assert_equal(e.converted_type.value(), 5)
    assert_equal(e.scale.value(), 2)
    assert_equal(e.precision.value(), 18)
    assert_equal(e.field_id.value(), 1234)

    var without = SchemaElement(name="plain", type=ParquetType.INT32)
    assert_false(Bool(without.field_id))
    var w2 = ThriftCompactWriter()
    w2.write_schema_element(without)
    var bytes2 = w2.take_bytes()
    var r2 = ThriftCompactReader(_view(Span(bytes2)))
    var e2 = _parse_schema_element(r2)
    assert_equal(e2.name, "plain")
    assert_false(Bool(e2.field_id))


def test_record_batch_field_ids_are_read_back_by_the_footer_parser() raises:
    var file = write_record_batch_to_parquet_bytes(
        _batch(0, 5), field_ids=_ids(7, 42)
    )
    _check_ids(file, 7, 42)


def test_several_batches_carry_field_ids_on_both_write_paths() raises:
    var fast = Slab[RecordBatch]()
    fast.append(_batch(0, 3))
    fast.append(_batch(3, 3))
    _check_ids(
        write_record_batches_to_parquet_bytes(fast^, field_ids=_ids(3, 9)),
        3,
        9,
    )
    var cut = Slab[RecordBatch]()
    cut.append(_batch(0, 3))
    cut.append(_batch(3, 3))
    _check_ids(
        write_record_batches_to_parquet_bytes(
            cut^, max_rows_per_rg=4, field_ids=_ids(11, 12)
        ),
        11,
        12,
    )


def test_no_field_ids_writes_the_bytes_of_a_call_without_the_argument() raises:
    var plain = write_record_batch_to_parquet_bytes(_batch(0, 5))
    var empty = write_record_batch_to_parquet_bytes(
        _batch(0, 5), field_ids=List[Int]()
    )
    assert_true(plain == empty)
    var md = _footer(plain)
    for i in range(len(md.schema)):
        assert_false(Bool(md.schema[i].field_id))
    var one = Slab[RecordBatch]()
    one.append(_batch(0, 5))
    var many_plain = write_record_batches_to_parquet_bytes(one^)
    var one2 = Slab[RecordBatch]()
    one2.append(_batch(0, 5))
    var many_empty = write_record_batches_to_parquet_bytes(
        one2^, field_ids=List[Int]()
    )
    assert_true(many_plain == many_empty)


def test_a_wrong_number_of_field_ids_is_refused() raises:
    var msg = String("")
    try:
        _ = write_record_batch_to_parquet_bytes(
            _batch(0, 2), field_ids=_ids_of(1)
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "write_record_batch_to_parquet_bytes: 1 field id(s) for 2 column(s)",
    )
    var batches = Slab[RecordBatch]()
    batches.append(_batch(0, 2))
    var msg2 = String("")
    try:
        _ = write_record_batches_to_parquet_bytes(
            batches^, field_ids=_ids_of(3)
        )
    except e:
        msg2 = String(e)
    assert_equal(
        msg2,
        "write_record_batches_to_parquet_bytes: 3 field id(s) for 2 column(s)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
