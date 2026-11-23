# =============================================================================
# The C consumer reads what the stream holds, and refuses what it cannot read
# =============================================================================
#
# Every expected text below is written out by hand from the values the test
# put in the batch, never computed by the code under test.
#
# What each test proves, and the defect it would catch:
#   * test_every_format_the_consumer_renders: one batch of eleven columns
#     (int8, uint16, nullable int32, uint64, float64, nullable bool, nullable
#     utf8 with a two-byte character and an empty string, large utf8,
#     nullable decimal128(10, 2) with a negative value below one, date32 with
#     a negative day, a utf8 dictionary) reads back value for value, NULLs
#     where the validity says so, with each field's format and nullability.
#     Catches a reader that misreads a width, a sign, an offset, a validity
#     bit or a decimal scale, which would make the sdk_exec test's oracle
#     wrong.
#   * test_two_chunks_are_read_in_order: chunk 0 then chunk 1.
#   * test_every_buffer_is_released_in_each_mode: after a drain, after a
#     release with nothing read, and after one chunk of two, the column
#     buffers of every batch are held by the test's probe alone (strong
#     count 1). Catches a stream, chunk or schema the consumer or the producer
#     leaves unreleased, and a second release that frees twice (a crash).
#   * test_a_format_it_does_not_read_is_refused: a float32 column is refused
#     naming the format.
#   * test_a_failed_get_schema_is_refused_with_its_error: an empty stream with
#     a nested column fails get_schema; the consumer reports get_last_error's
#     text and releases the stream.
#   * test_a_failed_get_next_is_refused_and_the_stream_released: a sliced
#     string column fails get_next; the text names it and nothing is held
#     afterwards (read_in_c releases the stream the consumer left live).

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.dictionary_array import StringDictionaryArray
from arrow.large_string_array import LargeStringArray
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from containers.slab import Slab
from komira_test_arrow_c_consumer.c_consumer import (
    DRAIN,
    FIRST_CHUNK,
    UNREAD,
    read_in_c,
)


def _every_format_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i8", ArrowType.INT8, nullable=False))
    sb.add_field(Field("u16", ArrowType.UINT16, nullable=False))
    sb.add_field(Field("i32", ArrowType.INT32, nullable=True))
    sb.add_field(Field("u64", ArrowType.UINT64, nullable=False))
    sb.add_field(Field("f", ArrowType.FLOAT64, nullable=False))
    sb.add_field(Field("b", ArrowType.BOOL, nullable=True))
    sb.add_field(Field("s", ArrowType.STRING, nullable=True))
    sb.add_field(Field("ls", ArrowType.LARGE_STRING, nullable=False))
    sb.add_field(Field.decimal128("m", 10, 2, nullable=True))
    sb.add_field(Field("dt", ArrowType.DATE32, nullable=False))
    sb.add_field(Field.dictionary("d", ArrowType.INT32, nullable=False))
    return sb.build()


def _every_format_batch() raises -> RecordBatch:
    var i32 = PrimitiveArray[DType.int32].allocate_nullable(3)
    i32.set(0, Int32(1))
    i32.set(2, Int32(-3))
    i32._set_null(1)
    var b = BooleanArray.allocate_nullable(3)
    b.set(0, True)
    b.set(2, False)
    b._set_null(1)
    var m = Decimal128Array.allocate_nullable(3, 10, 2)
    m.set_i128(0, SIMD[DType.int128, 1](12345))
    m.set_null(1)
    m.set_i128(2, SIMD[DType.int128, 1](-5))
    var rbb = RecordBatchBuilder.with_capacity(11)
    rbb.add_column(
        Column.from_primitive[DType.int8](
            PrimitiveArray[DType.int8].from_list([Int8(-128), Int8(0), Int8(127)])
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.uint16](
            PrimitiveArray[DType.uint16].from_list(
                [UInt16(0), UInt16(1), UInt16(65535)]
            )
        )
    )
    rbb.add_column(Column.from_primitive[DType.int32](i32))
    rbb.add_column(
        Column.from_primitive[DType.uint64](
            PrimitiveArray[DType.uint64].from_list(
                [UInt64(0), UInt64(18446744073709551615), UInt64(7)]
            )
        )
    )
    rbb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(
                [Float64(1.5), Float64(-0.25), Float64(0.1)]
            )
        )
    )
    rbb.add_column(Column.from_boolean(b))
    rbb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(
                [String("héllo"), String("ignored"), String("")],
                [True, False, True],
            )
        )
    )
    rbb.add_column(
        Column.from_large_string(
            LargeStringArray.from_strings(
                [String("one"), String(""), String("three")]
            )
        )
    )
    rbb.add_column(Column.from_decimal128(m))
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            PrimitiveArray[DType.int32].from_list(
                [Int32(0), Int32(19000), Int32(-1)]
            ),
            ArrowType.DATE32,
        )
    )
    rbb.add_column(
        Column.from_dictionary(
            StringDictionaryArray(
                PrimitiveArray[DType.int32].from_list(
                    [Int32(2), Int32(0), Int32(1)]
                ),
                StringArray.from_strings(
                    [String("AIR"), String("RAIL"), String("SHIP")]
                ),
                3,
            )
        )
    )
    return rbb.build(_every_format_schema())


def _int_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, nullable=False))
    return sb.build()


def _int_batch(var values: List[Int64]) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(values^)
        )
    )
    return rbb.build(_int_schema())


def _two_int_batches() raises -> Slab[RecordBatch]:
    var batches = Slab[RecordBatch].with_capacity(2)
    batches.append(_int_batch([Int64(1), Int64(2)]))
    batches.append(_int_batch([Int64(-3)]))
    return batches^


def _probes(ref batches: Slab[RecordBatch]) raises -> List[SharedAlignedBuffer[HeapRegion]]:
    var out = List[SharedAlignedBuffer[HeapRegion]]()
    for b in range(len(batches)):
        for c in range(batches[b].num_columns()):
            out.append(batches[b].column_at(c)._data.share())
    return out^


def _assert_held_by_probes_alone(
    label: String, imm probes: List[SharedAlignedBuffer[HeapRegion]]
) raises:
    for i in range(len(probes)):
        assert_equal(
            Int(probes[i]._region.count()),
            1,
            label + ": buffer " + String(i) + " is still held after every release",
        )


def _refusal(var batches: Slab[RecordBatch], var schema: Schema) raises -> String:
    try:
        _ = read_in_c(batches^, schema^)
    except e:
        return String(e)
    raise Error("the C consumer read a stream it must refuse")


def test_every_format_the_consumer_renders() raises:
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(_every_format_batch())
    var text = read_in_c(batches^, _every_format_schema())
    assert_equal(
        text,
        "field i8 c required\n"
        "field u16 S required\n"
        "field i32 i nullable\n"
        "field u64 L required\n"
        "field f g required\n"
        "field b b nullable\n"
        "field s u nullable\n"
        "field ls U required\n"
        "field m d:10,2 nullable\n"
        "field dt tdD required\n"
        "field d i required\n"
        "chunk 0 rows 3\n"
        "i8: -128, 0, 127\n"
        "u16: 0, 1, 65535\n"
        "i32: 1, null, -3\n"
        "u64: 0, 18446744073709551615, 7\n"
        "f: 1.5, -0.25, 0.10000000000000001\n"
        "b: true, null, false\n"
        's: "héllo", null, ""\n'
        'ls: "one", "", "three"\n'
        "m: 123.45, null, -0.05\n"
        "dt: 0, 19000, -1\n"
        'd: "SHIP", "AIR", "RAIL"\n',
    )


def test_two_chunks_are_read_in_order() raises:
    var text = read_in_c(_two_int_batches(), _int_schema())
    assert_equal(
        text,
        "field n l required\nchunk 0 rows 2\nn: 1, 2\nchunk 1 rows 1\nn: -3\n",
    )


def test_every_buffer_is_released_in_each_mode() raises:
    var drained = _two_int_batches()
    var drained_probes = _probes(drained)
    _ = read_in_c(drained^, _int_schema(), DRAIN)
    _assert_held_by_probes_alone("drain", drained_probes)

    var unread = _two_int_batches()
    var unread_probes = _probes(unread)
    assert_equal(read_in_c(unread^, _int_schema(), UNREAD), "")
    _assert_held_by_probes_alone("unread", unread_probes)

    var first = _two_int_batches()
    var first_probes = _probes(first)
    assert_equal(
        read_in_c(first^, _int_schema(), FIRST_CHUNK),
        "field n l required\nchunk 0 rows 2\nn: 1, 2\n",
    )
    _assert_held_by_probes_alone("first chunk", first_probes)


def test_a_format_it_does_not_read_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.FLOAT32, nullable=False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].from_list([Float32(0.5)])
        )
    )
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(rbb.build(sb.build()))
    var probes = _probes(batches)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("x", ArrowType.FLOAT32, nullable=False))
    assert_equal(
        _refusal(batches^, sb2.build()),
        "the C consumer refused the stream: a format this consumer does not"
        " read: f",
    )
    _assert_held_by_probes_alone("unread format", probes)


def test_a_failed_get_schema_is_refused_with_its_error() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.list_of("l", ArrowType.INT64, nullable=True))
    var msg = _refusal(Slab[RecordBatch](), sb.build())
    assert_true(
        msg.startswith(
            "the C consumer refused the stream: get_schema failed: ArrowCStream:"
            " empty stream with nested column 'l'"
        ),
        msg,
    )


def test_a_failed_get_next_is_refused_and_the_stream_released() raises:
    var s = Column.from_string(
        StringArray.from_strings([String("x"), String("y"), String("z")])
    )
    s._offset = 1
    s._length = 2
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, nullable=False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(s^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(rbb.build(sb.build()))
    var probes = _probes(batches)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("s", ArrowType.STRING, nullable=False))
    var msg = _refusal(batches^, sb2.build())
    assert_true(
        msg.startswith(
            "the C consumer refused the stream: get_next failed:"
            " UnsupportedArrowCABIType: variable-length"
        ),
        msg,
    )
    _assert_held_by_probes_alone("failed get_next", probes)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
