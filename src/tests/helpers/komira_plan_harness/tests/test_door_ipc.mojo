# door_ipc.mojo's decode_ipc_stream, on its claims (its header lists them),
# over streams built with komira_arrow_ipc's encoders, no library involved.
#
# What each test proves, and the defect it would catch:
#   test_every_claimed_type_round_trips
#       A batch of every type the header claims (int8..int64, uint8..uint64,
#       float32, float64, utf8, large utf8, binary, large binary, bool, date32,
#       date64), each column with a NULL, encoded as Schema + two RecordBatch
#       messages + EOS, decodes to two chunks whose canonical text equals the
#       source batch's, twice over. Catches: a type mapped to the wrong
#       ArrowType (signedness, width, offset width, date unit); a lost
#       nullability bit; a dropped chunk.
#   test_dictionary_and_unclaimed_types_are_refused
#       A dictionary-encoded field and a timestamp field: refused by name,
#       PLAN_DOOR_IPC_UNSUPPORTED_TYPE. Catches: a decoder that reads a
#       dictionary's indices as values, or guesses a type.
#   test_truncated_and_trailing_bytes_are_malformed
#       The stream without its EOS, cut inside its last record batch, with
#       eight bytes after its EOS, and starting at a record batch: each
#       PLAN_DOOR_IPC_MALFORMED with its reason. Catches: a decoder that
#       accepts a stream a producer did not finish, or ignores extra bytes.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, RecordBatch, SchemaBuilder
from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    encode_record_batch_message,
    encode_schema_message,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer

from komira_plan_harness import (
    CanonPolicy,
    check_table,
    decode_ipc_stream,
    render_batch,
)
from komira_plan_harness.fixtures import (
    BatchBuilder,
    bool_column,
    fixed_column,
    ints,
    utf8,
    varlen_column,
)


def _append(mut out: List[UInt8], frame: SharedAlignedBuffer[HeapRegion]):
    for i in range(frame.len()):
        out.append(frame.read_u8_at(i))


def _valid() -> List[Bool]:
    return [True, False, True]


def _fixed(mut b: BatchBuilder, name: String, t: ArrowType, width: Int, values: List[UInt64]):
    b.add(Field(name, t, nullable=True), fixed_column(t, width, values, _valid()))


def _varlen(mut b: BatchBuilder, name: String, t: ArrowType):
    var values: List[List[UInt8]] = [utf8("alpha"), utf8(""), utf8("gamma\tz")]
    b.add(Field(name, t, nullable=True), varlen_column(t, values, _valid()))


def _batch(shift: Int) raises -> RecordBatch:
    """Every claimed type, three rows, row 1 NULL; `shift` varies the values
    so the two chunks differ."""
    var b = BatchBuilder()
    _fixed(b, "i8", ArrowType.INT8, 1, ints([-128 + shift, 0, 127]))
    _fixed(b, "i16", ArrowType.INT16, 2, ints([-32768, shift, 32767]))
    _fixed(b, "i32", ArrowType.INT32, 4, ints([-2147483648, 0, 2147483647 - shift]))
    _fixed(b, "i64", ArrowType.INT64, 8, ints([-(1 << 62) + shift, 0, 1 << 62]))
    _fixed(b, "u8", ArrowType.UINT8, 1, ints([255 - shift, 0, 1]))
    _fixed(b, "u16", ArrowType.UINT16, 2, ints([65535, 0, shift]))
    _fixed(b, "u32", ArrowType.UINT32, 4, ints([4294967295 - shift, 0, 7]))
    _fixed(b, "u64", ArrowType.UINT64, 8, [UInt64(0xFFFFFFFFFFFFFFFF) - UInt64(shift), 0, 9])
    # 1.5 and -0.25 as IEEE bits (float32, float64).
    _fixed(b, "f32", ArrowType.FLOAT32, 4, [UInt64(0x3FC00000), 0, UInt64(0xBE800000)])
    _fixed(b, "f64", ArrowType.FLOAT64, 8, [UInt64(0x3FF8000000000000), 0, UInt64(0xBFD0000000000000)])
    _varlen(b, "s", ArrowType.STRING)
    _varlen(b, "ls", ArrowType.LARGE_STRING)
    _varlen(b, "bin", ArrowType.BINARY)
    _varlen(b, "lbin", ArrowType.LARGE_BINARY)
    b.add(Field("flag", ArrowType.BOOL, nullable=True), bool_column([True, False, shift == 0], _valid()))
    _fixed(b, "d32", ArrowType.DATE32, 4, ints([19000 + shift, 0, -1]))
    _fixed(b, "d64", ArrowType.DATE64, 8, ints([1641600000000, 0, -86400000 * (shift + 1)]))
    return b.build()


def _stream(var batches: List[Int]) raises -> List[UInt8]:
    var out = List[UInt8]()
    var first = _batch(0)
    _append(out, encode_schema_message(first.schema))
    for k in batches:
        var rb = _batch(k)
        _append(out, encode_record_batch_message(rb.take_columns()))
    _append(out, arrow_ipc_eos_bytes())
    return out^


def test_every_claimed_type_round_trips() raises:
    var t0 = render_batch(_batch(0), CanonPolicy())
    var t1 = render_batch(_batch(1), CanonPolicy())
    # The expected text: chunk 0's rows, then chunk 1's, under one header.
    var expected = t0.to_text()
    var lines = t1.to_text().split("\n")
    # Header (3 policy lines) and schema line come from t0; append t1's rows.
    for i in range(4, len(lines)):
        if lines[i].byte_length() > 0:
            expected += String(lines[i]) + "\n"
    var table = decode_ipc_stream(_stream([0, 1]))
    assert_equal(table.num_chunks(), 2)
    var report = check_table(expected, table)
    assert_true(report.ok(), String(report))


def _schema_only(f: Field) raises -> List[UInt8]:
    var sb = SchemaBuilder()
    sb.add_field(f.copy())
    var out = List[UInt8]()
    _append(out, encode_schema_message(sb.build()))
    _append(out, arrow_ipc_eos_bytes())
    return out^


def _decode_error(bytes: List[UInt8]) -> String:
    try:
        _ = decode_ipc_stream(bytes)
    except e:
        return String(e)
    return String("")


def _assert_starts(text: String, prefix: String) raises:
    assert_true(text.startswith(prefix), String("expected `") + prefix + "...`, got `" + text + "`")


def test_dictionary_and_unclaimed_types_are_refused() raises:
    _assert_starts(
        _decode_error(_schema_only(Field.dictionary("d", ArrowType.INT32, nullable=True))),
        "PLAN_DOOR_IPC_UNSUPPORTED_TYPE: field `d`: dictionary-encoded",
    )
    _assert_starts(
        _decode_error(_schema_only(Field.timestamp("t", ArrowType.TIMESTAMP_US, "", nullable=True))),
        "PLAN_DOOR_IPC_UNSUPPORTED_TYPE: field `t`: type tag 10",
    )


def test_truncated_and_trailing_bytes_are_malformed() raises:
    var full = _stream([0])
    # The whole stream decodes: the cuts below are what make it malformed.
    assert_equal(decode_ipc_stream(full).num_chunks(), 1)
    var no_eos = full.copy()
    no_eos.resize(len(full) - 8, 0)
    var msg = _decode_error(no_eos)
    _assert_starts(msg, "PLAN_DOOR_IPC_MALFORMED: ")
    assert_true(msg.endswith("the stream ends without the end-of-stream marker"), msg)
    var cut = full.copy()
    cut.resize(len(full) - 16, 0)
    msg = _decode_error(cut)
    _assert_starts(msg, "PLAN_DOOR_IPC_MALFORMED: ")
    assert_true(msg.endswith("message body runs past the end"), msg)
    var trailing = full.copy()
    for _ in range(8):
        trailing.append(0)
    msg = _decode_error(trailing)
    _assert_starts(msg, "PLAN_DOOR_IPC_MALFORMED: ")
    assert_true(msg.endswith("8 bytes after the end-of-stream marker"), msg)
    var rb = _batch(0)
    var headless = List[UInt8]()
    _append(headless, encode_record_batch_message(rb.take_columns()))
    _append(headless, arrow_ipc_eos_bytes())
    msg = _decode_error(headless)
    _assert_starts(msg, "PLAN_DOOR_IPC_MALFORMED: at byte 0: the stream does not start with a Schema message")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
