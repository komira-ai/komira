# =============================================================================
# tests/test_envelope_bridge.mojo
#
# The bridge between Kafka records and the Arrow envelope RecordBatch
# (envelope_bridge.mojo), offline.
#
# What each test proves, and the defect it catches:
#   * the schema is the five fixed columns in order, with the right types and
#     nullability.
#   * records go to the envelope and come back equal field by field: keys,
#     values, headers (with null and empty values), timestamps. Null and empty
#     are different on both sides: a null key must not come back empty and an
#     empty value must not come back null.
#   * the envelope columns hold what the convention says: the offset and
#     timestamp columns carry the record's own values, a record without headers
#     has the header block of count 0, a column with no null has none.
#   * a null or empty __headers cell (as a writer other than this one may
#     leave) reads as a record with no headers.
#   * bytes survive unchanged: zeros, 0xFF, values over 127 bytes (a
#     multi-byte varint length in the header block), many headers.
#   * fetch renumbers: the offsets of the records read back are
#     base_offset + position, not the envelope's own __offset column.
#   * zero records make an empty batch that reads back as no records.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_buffer.heap_region import HeapRegion
from komira_kafka_broker.envelope_bridge import (
    ENVELOPE_HEADERS,
    ENVELOPE_KEY,
    ENVELOPE_OFFSET,
    ENVELOPE_TIMESTAMP,
    ENVELOPE_VALUE,
    envelope_schema,
    envelope_to_kafka_records,
    kafka_records_to_envelope,
)
from komira_kafka_server.wire.record_batch_v2 import KafkaHeader, KafkaRecord


def _bytes(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _assert_bytes_eq(a: List[UInt8], b: List[UInt8], label: String) raises:
    assert_equal(len(a), len(b), label + ": length")
    for i in range(len(a)):
        if a[i] != b[i]:
            raise Error(label + ": byte " + String(i) + " differs")


def _assert_optional_eq(
    a: Optional[List[UInt8]], b: Optional[List[UInt8]], label: String
) raises:
    assert_equal(Bool(a), Bool(b), label + ": null vs present")
    if b:
        _assert_bytes_eq(a.value(), b.value(), label)


def _assert_record_eq(got: KafkaRecord, want: KafkaRecord, label: String) raises:
    _assert_optional_eq(got.key, want.key, label + " key")
    _assert_optional_eq(got.value, want.value, label + " value")
    assert_equal(len(got.headers), len(want.headers), label + " header count")
    for i in range(len(want.headers)):
        _assert_bytes_eq(got.headers[i].key, want.headers[i].key, label + " hk")
        _assert_optional_eq(got.headers[i].value, want.headers[i].value, label + " hv")
    assert_equal(got.timestamp, want.timestamp, label + " timestamp")


def _opt(s: String) -> Optional[List[UInt8]]:
    return Optional(_bytes(s))


def _none() -> Optional[List[UInt8]]:
    return Optional[List[UInt8]]()


def _zero_block() -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(0))
    return out^


def _binary_value() -> List[UInt8]:
    """Zeros, 0xFF and every other byte value, 300 bytes (the length needs a
    two-byte varint)."""
    var out = List[UInt8]()
    for i in range(300):
        out.append(UInt8(i % 256))
    out.append(UInt8(0))
    out.append(UInt8(0xFF))
    return out^


def _records() -> List[KafkaRecord]:
    var recs = List[KafkaRecord]()

    # 0: key, value, two headers (one with a null value, one empty value).
    var h0 = List[KafkaHeader]()
    h0.append(KafkaHeader(_bytes("trace"), _opt("abc123")))
    h0.append(KafkaHeader(_bytes("nullable"), _none()))
    h0.append(KafkaHeader(_bytes("empty"), _opt("")))
    recs.append(KafkaRecord(_opt("k0"), _opt("v0"), h0^, Int64(1000), Int64(10)))

    # 1: null key, no headers.
    recs.append(
        KafkaRecord(_none(), _opt("v1"), List[KafkaHeader](), Int64(1001), Int64(11))
    )

    # 2: null value (a tombstone), key present.
    recs.append(
        KafkaRecord(_opt("k2"), _none(), List[KafkaHeader](), Int64(1002), Int64(12))
    )

    # 3: null key and null value.
    recs.append(
        KafkaRecord(_none(), _none(), List[KafkaHeader](), Int64(1003), Int64(13))
    )

    # 4: empty (not null) key and value.
    recs.append(
        KafkaRecord(_opt(""), _opt(""), List[KafkaHeader](), Int64(-5), Int64(14))
    )

    # 5: binary key and value, a long header value, an empty header name.
    var h5 = List[KafkaHeader]()
    h5.append(KafkaHeader(_bytes(""), Optional(_binary_value())))
    h5.append(KafkaHeader(_binary_value(), _opt("x")))
    recs.append(
        KafkaRecord(
            Optional(_binary_value()),
            Optional(_binary_value()),
            h5^,
            Int64(4102444800000),
            Int64(15),
        )
    )
    return recs^


def test_schema_is_the_five_fixed_columns() raises:
    var s = envelope_schema()
    assert_equal(s.num_columns(), 5)
    var names = List[String]()
    names.append(ENVELOPE_KEY)
    names.append(ENVELOPE_VALUE)
    names.append(ENVELOPE_TIMESTAMP)
    names.append(ENVELOPE_OFFSET)
    names.append(ENVELOPE_HEADERS)
    assert_true(s.names_are(names), "column names and order")
    assert_equal(ENVELOPE_KEY, "__key")
    assert_equal(ENVELOPE_VALUE, "__value")
    assert_equal(ENVELOPE_TIMESTAMP, "__timestamp")
    assert_equal(ENVELOPE_OFFSET, "__offset")
    assert_equal(ENVELOPE_HEADERS, "__headers")

    var f0 = s.field_at(0)
    var f1 = s.field_at(1)
    var f2 = s.field_at(2)
    var f3 = s.field_at(3)
    var f4 = s.field_at(4)
    assert_true(f0.arrow_type == ArrowType.BINARY and f0.nullable, "__key")
    assert_true(f1.arrow_type == ArrowType.BINARY and f1.nullable, "__value")
    assert_true(f2.arrow_type == ArrowType.INT64 and not f2.nullable, "__timestamp")
    assert_true(f3.arrow_type == ArrowType.INT64 and not f3.nullable, "__offset")
    assert_true(f4.arrow_type == ArrowType.BINARY and f4.nullable, "__headers")


def test_batch_has_the_envelope_schema_and_row_count() raises:
    var batch = kafka_records_to_envelope(_records())
    assert_equal(batch.num_rows(), 6)
    assert_equal(batch.num_columns(), 5)
    assert_true(batch.schema.field_name(0) == "__key")
    assert_true(batch.schema.field_name(4) == "__headers")


def test_records_roundtrip_exactly() raises:
    var recs = _records()
    var batch = kafka_records_to_envelope(recs)
    var back = envelope_to_kafka_records(batch, Int64(100))
    assert_equal(len(back), len(recs))
    for i in range(len(recs)):
        _assert_record_eq(back[i], recs[i], "record " + String(i))


def test_null_and_empty_are_different() raises:
    var recs = _records()
    var back = envelope_to_kafka_records(kafka_records_to_envelope(recs), Int64(0))
    assert_false(Bool(back[1].key), "null key stays null")
    assert_false(Bool(back[2].value), "tombstone stays null")
    assert_false(Bool(back[3].key) or Bool(back[3].value), "both null")
    assert_true(Bool(back[4].key) and Bool(back[4].value), "empty is present")
    assert_equal(len(back[4].key.value()), 0)
    assert_equal(len(back[4].value.value()), 0)
    assert_false(Bool(back[0].headers[1].value), "null header value stays null")
    assert_true(Bool(back[0].headers[2].value), "empty header value is present")
    assert_equal(len(back[0].headers[2].value.value()), 0)


def test_columns_hold_the_convention() raises:
    var recs = _records()
    var batch = kafka_records_to_envelope(recs)
    var keys = batch.column_at(0).as_binary()
    var values = batch.column_at(1).as_binary()
    var ts = batch.column_as_primitive_int64(2)
    var offs = batch.column_as_primitive_int64(3)
    var hdrs = batch.column_at(4).as_binary()
    for i in range(len(recs)):
        assert_equal(keys.is_null(i), not Bool(recs[i].key), "key null " + String(i))
        assert_equal(values.is_null(i), not Bool(recs[i].value), "value null " + String(i))
        assert_equal(Int64(ts.get(i)), recs[i].timestamp, "timestamp " + String(i))
        assert_equal(Int64(offs.get(i)), recs[i].offset, "offset " + String(i))
        assert_false(hdrs.is_null(i), "headers cell " + String(i))
        # A record without headers carries the block of count 0: one zero byte.
        if len(recs[i].headers) == 0:
            _assert_bytes_eq(hdrs.get(i), _zero_block(), "empty header block")
    _assert_bytes_eq(keys.get(0), _bytes("k0"), "key 0 bytes")
    assert_equal(len(keys.get(4)), 0, "empty key is a zero-length cell")
    _assert_bytes_eq(values.get(5), _binary_value(), "binary value bytes")


def test_no_nulls_makes_columns_without_nulls() raises:
    var recs = List[KafkaRecord]()
    for i in range(4):
        recs.append(
            KafkaRecord(
                _opt("k" + String(i)),
                _opt("v" + String(i)),
                List[KafkaHeader](),
                Int64(i),
                Int64(i),
            )
        )
    var batch = kafka_records_to_envelope(recs)
    assert_equal(batch.column_at(0).null_count(), 0)
    assert_equal(batch.column_at(1).null_count(), 0)
    assert_equal(batch.column_at(4).null_count(), 0)
    var back = envelope_to_kafka_records(batch, Int64(0))
    for i in range(4):
        _assert_record_eq(back[i], recs[i], "record " + String(i))


def test_fetch_renumbers_from_the_base_offset() raises:
    var recs = _records()
    var batch = kafka_records_to_envelope(recs)
    var back = envelope_to_kafka_records(batch, Int64(5000))
    for i in range(len(back)):
        assert_equal(back[i].offset, Int64(5000 + i), "offset " + String(i))
    # The envelope's own offsets are untouched by reading it.
    var offs = batch.column_as_primitive_int64(3)
    assert_equal(Int64(offs.get(0)), Int64(10))
    assert_equal(Int64(offs.get(5)), Int64(15))


def test_zero_records_make_an_empty_batch() raises:
    var batch = kafka_records_to_envelope(List[KafkaRecord]())
    assert_equal(batch.num_rows(), 0)
    assert_equal(batch.num_columns(), 5)
    assert_equal(len(envelope_to_kafka_records(batch, Int64(0))), 0)


def _binary_column(cells: List[Optional[List[UInt8]]]) raises -> Column[HeapRegion]:
    var offsets = List[Int32]()
    offsets.append(Int32(0))
    var data = List[UInt8]()
    var validity = Bitmap.create(len(cells))
    var null_count = 0
    for i in range(len(cells)):
        if cells[i]:
            data.extend(Span(cells[i].value()))
            validity.set(i)
        else:
            null_count += 1
        offsets.append(Int32(len(data)))
    return Column.from_binary(
        BinaryArray.from_buffers(offsets, data, Optional(validity^), null_count)
    )


def test_null_or_empty_headers_cell_reads_as_no_headers() raises:
    # A batch from another writer: __headers is null in row 0 and zero bytes
    # long in row 1.
    var keys = List[Optional[List[UInt8]]]()
    var values = List[Optional[List[UInt8]]]()
    var hdrs = List[Optional[List[UInt8]]]()
    var ts = List[Scalar[DType.int64]]()
    var offs = List[Scalar[DType.int64]]()
    for i in range(2):
        keys.append(_opt("k"))
        values.append(_opt("v"))
        ts.append(Scalar[DType.int64](100 + i))
        offs.append(Scalar[DType.int64](i))
    hdrs.append(_none())
    hdrs.append(Optional(List[UInt8]()))
    var builder = RecordBatchBuilder()
    builder.add_column(_binary_column(keys))
    builder.add_column(_binary_column(values))
    builder.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(ts)))
    builder.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(offs)))
    builder.add_column(_binary_column(hdrs))
    var batch = builder.build(envelope_schema())
    var back = envelope_to_kafka_records(batch, Int64(0))
    assert_equal(len(back), 2)
    assert_equal(len(back[0].headers), 0)
    assert_equal(len(back[1].headers), 0)
    assert_equal(back[1].timestamp, Int64(101))
    _assert_bytes_eq(back[1].key.value(), _bytes("k"), "key")


def test_many_headers_roundtrip() raises:
    var hs = List[KafkaHeader]()
    for i in range(200):
        hs.append(KafkaHeader(_bytes("h" + String(i)), _opt("value-" + String(i))))
    var recs = List[KafkaRecord]()
    recs.append(KafkaRecord(_opt("k"), _opt("v"), hs^, Int64(7), Int64(0)))
    var back = envelope_to_kafka_records(kafka_records_to_envelope(recs), Int64(0))
    assert_equal(len(back[0].headers), 200)
    _assert_record_eq(back[0], recs[0], "200 headers")


def main() raises:
    test_schema_is_the_five_fixed_columns()
    test_batch_has_the_envelope_schema_and_row_count()
    test_records_roundtrip_exactly()
    test_null_and_empty_are_different()
    test_columns_hold_the_convention()
    test_no_nulls_makes_columns_without_nulls()
    test_fetch_renumbers_from_the_base_offset()
    test_zero_records_make_an_empty_batch()
    test_null_or_empty_headers_cell_reads_as_no_headers()
    test_many_headers_roundtrip()
    print("test_envelope_bridge: ALL PASS")
