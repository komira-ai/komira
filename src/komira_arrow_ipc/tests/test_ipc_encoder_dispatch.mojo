# =============================================================================
# test_ipc_encoder_dispatch.mojo — Arrow IPC encoder/decoder round-trips
# =============================================================================
#
# End-to-end tests for the Arrow IPC encoder pipeline:
#   Column → encode_record_batch_message → SharedAlignedBuffer[HeapRegion] frame
#          → parse_ipc_message + read_record_batch → verify structural
#                                                   metadata round-trips
#          → read body bytes at recorded Buffer offsets → verify values
#
# Covered: primitive, variable-length, temporal, decimal, nested, dictionary
# and view-type columns, plus the zero-copy decoder.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message,
    decode_record_batch_message_nested,
    decode_record_batch_message_nested_zerocopy,
    decode_record_batch_zerocopy,
    ColumnTypeSpec,
)
from komira_arrow_ipc.ipc_flatbuf import (
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_record_batch,
    MESSAGE_HEADER_RECORD_BATCH,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _build_int32_column(values: List[Int32]) raises -> Column[HeapRegion]:
    """Build an Int32 Column[HeapRegion] from a list of values, all non-null."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int32].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, Scalar[DType.int32](values[i]))
    return Column.from_primitive[DType.int32](arr^)


def _extract_fb_payload(
    ref frame: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Parse the IPC framing on `frame` and copy out the FB metadata
    slice into a fresh MmapAlignedBuffer so FlatbufReader anchors at byte 0.

    Takes `frame` by ref (borrowed) so the caller can continue reading
    body bytes from `frame` after this returns.
    """
    var f = parse_ipc_message(frame)
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(f.metadata_size)
    for i in range(f.metadata_size):
        fb.write_u8_at(i, frame.read_u8_at(f.metadata_pos + i))
    fb.set_length(f.metadata_size)

    return fb^


# ---------------------------------------------------------------------------
# Smoke tests
# ---------------------------------------------------------------------------


def test_int32_single_column_round_trip() raises:
    """Round-trip a 5-element non-null Int32 column through the full
    encoder pipeline. Verifies that:
      - Message header is RECORD_BATCH
      - RecordBatch.length == 5
      - FieldNode.length == 5, null_count == 0
      - 2 buffers (validity zero-length + values 20 bytes)
    """
    var vals = List[Int32]()
    vals.append(Int32(10))
    vals.append(Int32(20))
    vals.append(Int32(30))
    vals.append(Int32(40))
    vals.append(Int32(50))
    var col = _build_int32_column(vals)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)

    # Decode framing + verify Message header.
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_RECORD_BATCH)

    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(5))
    assert_equal(len(rb.nodes), 1)
    assert_equal(rb.nodes[0].length, Int64(5))
    assert_equal(rb.nodes[0].null_count, Int64(0))
    # 2 buffers per primitive column (validity + values).
    assert_equal(len(rb.buffers), 2)
    # Validity buffer length is 0 (all non-null).
    assert_equal(rb.buffers[0].length, Int64(0))
    # Values buffer length is 5 elements × 4 bytes = 20.
    assert_equal(rb.buffers[1].length, Int64(20))


def test_int32_values_round_trip_in_body() raises:
    """Same as above, plus read the body bytes at the recorded values
    Buffer offset and verify the actual values match.
    """
    var vals = List[Int32]()
    vals.append(Int32(100))
    vals.append(Int32(-7))
    vals.append(Int32(0))
    vals.append(Int32(2147483647))   # INT32_MAX
    vals.append(Int32(-2147483648))  # INT32_MIN
    var col = _build_int32_column(vals)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)

    # Parse framing to locate the body span.
    var f = parse_ipc_message(frame)

    # Decode FB metadata.
    var fb = SharedAlignedBuffer[HeapRegion].heap_owned(f.metadata_size)
    for i in range(f.metadata_size):
        fb.write_u8_at(i, frame.read_u8_at(f.metadata_pos + i))
    fb.set_length(f.metadata_size)

    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)

    # Read 5 i32 values starting at body[buffers[1].offset].
    var values_buf_off = Int(rb.buffers[1].offset)
    assert_equal(
        frame.read_i32_le_at(f.body_pos + values_buf_off + 0),
        Int32(100),
    )
    assert_equal(
        frame.read_i32_le_at(f.body_pos + values_buf_off + 4),
        Int32(-7),
    )
    assert_equal(
        frame.read_i32_le_at(f.body_pos + values_buf_off + 8),
        Int32(0),
    )
    assert_equal(
        frame.read_i32_le_at(f.body_pos + values_buf_off + 12),
        Int32(2147483647),
    )
    assert_equal(
        frame.read_i32_le_at(f.body_pos + values_buf_off + 16),
        Int32(-2147483648),
    )


def test_int32_two_column_row_count_validation() raises:
    """Two Int32 columns with different row counts must raise."""
    var a = List[Int32]()
    a.append(Int32(1))
    a.append(Int32(2))
    var b = List[Int32]()
    b.append(Int32(10))
    b.append(Int32(20))
    b.append(Int32(30))
    var col_a = _build_int32_column(a)
    var col_b = _build_int32_column(b)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col_a^)
    cols.append(col_b^)
    var threw = False
    try:
        var _frame = encode_record_batch_message(cols^)
    except _:
        threw = True
    assert_true(threw)


def test_int32_two_column_round_trip() raises:
    """Two same-length Int32 columns round-trip with correct buffer
    layout (4 buffers total: validity_0 + values_0 + validity_1 + values_1).
    """
    var a = List[Int32]()
    a.append(Int32(1))
    a.append(Int32(2))
    a.append(Int32(3))
    var b = List[Int32]()
    b.append(Int32(100))
    b.append(Int32(200))
    b.append(Int32(300))
    var col_a = _build_int32_column(a)
    var col_b = _build_int32_column(b)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col_a^)
    cols.append(col_b^)
    var frame = encode_record_batch_message(cols^)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(3))
    assert_equal(len(rb.nodes), 2)
    assert_equal(len(rb.buffers), 4)
    # Each values buffer is 3 × 4 = 12 bytes.
    assert_equal(rb.buffers[1].length, Int64(12))
    assert_equal(rb.buffers[3].length, Int64(12))


# ---------------------------------------------------------------------------
# Primitive arms (Int64 / UInt32 / Float64 / Bool)
# ---------------------------------------------------------------------------


def test_int64_round_trip() raises:
    """INT64 arm wired."""
    var arr = PrimitiveArray[DType.int64].allocate(3)
    var p = arr._typed_ptr_mut()
    p.store[width=1](0, Int64(1000000))
    p.store[width=1](1, Int64(-999999))
    p.store[width=1](2, Int64(0))
    var col = Column.from_primitive[DType.int64](arr^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var f = parse_ipc_message(frame)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(3))
    # 3 elements × 8 bytes = 24.
    assert_equal(rb.buffers[1].length, Int64(24))
    var off = Int(rb.buffers[1].offset)
    assert_equal(frame.read_i64_le_at(f.body_pos + off + 0), Int64(1000000))
    assert_equal(frame.read_i64_le_at(f.body_pos + off + 8), Int64(-999999))


def test_uint32_round_trip() raises:
    """UINT32 arm wired."""
    var arr = PrimitiveArray[DType.uint32].allocate(4)
    var p = arr._typed_ptr_mut()
    p.store[width=1](0, UInt32(0))
    p.store[width=1](1, UInt32(100))
    p.store[width=1](2, UInt32(4294967295))  # UINT32_MAX
    p.store[width=1](3, UInt32(12345))
    var col = Column.from_primitive[DType.uint32](arr^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var f = parse_ipc_message(frame)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(4))
    # 4 × 4 = 16 bytes.
    assert_equal(rb.buffers[1].length, Int64(16))
    var off = Int(rb.buffers[1].offset)
    assert_equal(frame.read_u32_le_at(f.body_pos + off + 0), UInt32(0))
    assert_equal(
        frame.read_u32_le_at(f.body_pos + off + 8),
        UInt32(4294967295),
    )


def test_int8_round_trip_single_byte_elements() raises:
    """INT8 with 1-byte-per-element layout."""
    var arr = PrimitiveArray[DType.int8].allocate(6)
    var p = arr._typed_ptr_mut()
    p.store[width=1](0, Int8(-128))  # INT8_MIN
    p.store[width=1](1, Int8(0))
    p.store[width=1](2, Int8(127))  # INT8_MAX
    p.store[width=1](3, Int8(-1))
    p.store[width=1](4, Int8(1))
    p.store[width=1](5, Int8(42))
    var col = Column.from_primitive[DType.int8](arr^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var f = parse_ipc_message(frame)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(6))
    # 6 × 1 = 6 bytes for the values buffer.
    assert_equal(rb.buffers[1].length, Int64(6))


# ---------------------------------------------------------------------------
# Variable-length + temporal + decimal
# ---------------------------------------------------------------------------


def test_string_round_trip() raises:
    """STRING column round-trips with 3 buffers (validity + offsets + data)."""
    from komira_arrow.string_array import StringArray
    var strs: List[String] = [
        String("hello"),
        String(""),
        String("world!"),
    ]
    var sa = StringArray.from_strings(strs)
    var col = Column.from_string(sa^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(3))
    # 3 buffers: validity (zero-length all-non-null) + offsets + data.
    assert_equal(len(rb.buffers), 3)
    # Offsets buffer: (3+1) × 4 = 16 bytes.
    assert_equal(rb.buffers[1].length, Int64(16))
    # Data buffer: "hello" (5) + "" (0) + "world!" (6) = 11 bytes.
    assert_equal(rb.buffers[2].length, Int64(11))


def test_wide_binary_many_rows_body_size_estimate() raises:
    """REGRESSION: a multi-row variable-length column whose data bytes
    exceed `n * 8` must NOT under-size the body sink.

    Budgeting the value buffer as `n * 8` (worst-case Int64) is correct
    for fixed-width primitives but DRAMATICALLY undersizes a BINARY/STRING
    column whose data buffer is the actual byte count. With many rows of
    wide values the encoder would write past the pre-sized
    `AlignedBufferBodySink`; the release-elided bounds debug_assert lets
    that corrupt adjacent heap memory and HANG
    `encode_record_batch_message`. A message envelope's key/value/header
    columns (e.g. a Kafka record batch) have exactly this shape.

    Trigger: 64 rows × 64-byte values = 4096 data bytes, vs an `n * 8`
    estimate of 512. `_estimate_body_size` sizes from the actual
    `_data.len()`, so the sink is large enough and the encode completes +
    round-trips.
    """
    from komira_arrow.string_array import StringArray

    var n = 64
    var value_bytes = 64
    var strs = List[String]()
    var expected_data_bytes = 0
    for i in range(n):
        # Deterministic wide value, well over an n*8 per-row budget.
        var s = String("")
        for j in range(value_bytes):
            s += String(chr(Int(48 + ((i + j) % 10))))  # ASCII digits
        expected_data_bytes += s.byte_length()
        strs.append(s^)

    var sa = StringArray.from_strings(strs)
    var col = Column.from_string(sa^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)

    # With an under-sized body sink this call HANGS (heap corruption). It
    # must complete.
    var frame = encode_record_batch_message(cols^)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(n))
    # 3 buffers: validity (all-non-null → zero-length) + offsets + data.
    assert_equal(len(rb.buffers), 3)
    # Offsets buffer: (n+1) × 4.
    assert_equal(rb.buffers[1].length, Int64((n + 1) * 4))
    # Data buffer == the ACTUAL concatenated value bytes (n × 64),
    # which is the quantity an n*8 estimate under-budgets.
    assert_equal(rb.buffers[2].length, Int64(expected_data_bytes))
    assert_equal(Int(rb.buffers[2].length), n * value_bytes)


def test_date32_round_trip() raises:
    """DATE32 column (Int32 storage) round-trips via shared primitive body."""
    var arr = PrimitiveArray[DType.int32].allocate(3)
    var p = arr._typed_ptr_mut()
    p.store[width=1](0, Int32(19000))  # days since the epoch
    p.store[width=1](1, Int32(20000))
    p.store[width=1](2, Int32(0))     # epoch
    var col = Column.from_primitive_with_arrow_type[DType.int32](
        arr^, ArrowType.DATE32
    )
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var f = parse_ipc_message(frame)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(3))
    assert_equal(rb.buffers[1].length, Int64(12))  # 3 × 4
    var off = Int(rb.buffers[1].offset)
    assert_equal(frame.read_i32_le_at(f.body_pos + off + 0), Int32(19000))
    assert_equal(frame.read_i32_le_at(f.body_pos + off + 8), Int32(0))


def test_timestamp_us_round_trip() raises:
    """TIMESTAMP_US column (Int64 storage) round-trips."""
    var arr = PrimitiveArray[DType.int64].allocate(2)
    var p = arr._typed_ptr_mut()
    p.store[width=1](0, Int64(1700000000000000))
    p.store[width=1](1, Int64(0))
    var col = Column.from_primitive_with_arrow_type[DType.int64](
        arr^, ArrowType.TIMESTAMP_US
    )
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(2))
    assert_equal(rb.buffers[1].length, Int64(16))  # 2 × 8


# ---------------------------------------------------------------------------
# Nested (STRUCT pre-order traversal)
# ---------------------------------------------------------------------------


def test_struct_round_trip_pre_order_field_nodes() raises:
    """STRUCT<a: Int32, b: Int32> with 3 rows.

    Validates pre-order traversal:
      FieldNode[0] = STRUCT     (length=3, null_count=0)
      FieldNode[1] = a (Int32)
      FieldNode[2] = b (Int32)
      Buffers[0]  = STRUCT validity (zero-length all-non-null)
      Buffers[1]  = a validity
      Buffers[2]  = a values
      Buffers[3]  = b validity
      Buffers[4]  = b values
    """
    from komira_arrow.struct_array import StructArray
    # Build two Int32 child columns.
    var a_arr = PrimitiveArray[DType.int32].allocate(3)
    var ap = a_arr._typed_ptr_mut()
    ap.store[width=1](0, Int32(10))
    ap.store[width=1](1, Int32(20))
    ap.store[width=1](2, Int32(30))
    var b_arr = PrimitiveArray[DType.int32].allocate(3)
    var bp = b_arr._typed_ptr_mut()
    bp.store[width=1](0, Int32(100))
    bp.store[width=1](1, Int32(200))
    bp.store[width=1](2, Int32(300))
    var a_col = Column.from_primitive[DType.int32](a_arr^)
    var b_col = Column.from_primitive[DType.int32](b_arr^)

    var fields = List[String]()
    fields.append(String("a"))
    fields.append(String("b"))
    var s = StructArray.from_columns_2(fields, a_col^, b_col^)
    var col = Column.from_struct(s^)

    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var fb = _extract_fb_payload(frame)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)

    assert_equal(rb.length, Int64(3))
    # 3 FieldNodes in pre-order: STRUCT, a, b
    assert_equal(len(rb.nodes), 3)
    assert_equal(rb.nodes[0].length, Int64(3))
    assert_equal(rb.nodes[1].length, Int64(3))
    assert_equal(rb.nodes[2].length, Int64(3))
    # 5 Buffers in pre-order: STRUCT validity + a {validity, values} +
    # b {validity, values}
    assert_equal(len(rb.buffers), 5)
    assert_equal(rb.buffers[2].length, Int64(12))  # a values: 3 × 4
    assert_equal(rb.buffers[4].length, Int64(12))  # b values: 3 × 4


# ---------------------------------------------------------------------------
# Error paths (unwired types)
# ---------------------------------------------------------------------------


def test_view_type_encoders_raise_v05() raises:
    """4 view-type arms (BINARY_VIEW / UTF8_VIEW / LIST_VIEW /
    LARGE_LIST_VIEW) raise with a clear message: view types are
    decode-only."""
    for view_type in [
        ArrowType.BINARY_VIEW,
        ArrowType.UTF8_VIEW,
        ArrowType.LIST_VIEW,
        ArrowType.LARGE_LIST_VIEW,
    ]:
        var col = Column[HeapRegion]()
        col.arrow_type = view_type
        var cols = Slab[Column[HeapRegion]]()
        cols.append(col^)
        var threw = False
        try:
            var _frame = encode_record_batch_message(cols^)
        except _:
            threw = True
        assert_true(threw)


def test_dictionary_empty_indices_smoke() raises:
    """DICTIONARY encoder accepts a 0-row column (smoke that the
    dispatch arm is wired). Full DICTIONARY round-trip (2-message
    pattern: DictionaryBatch + RecordBatch) is exercised by
    test_dictionary_two_message_round_trip below.
    """
    var col = Column[HeapRegion]()
    col.arrow_type = ArrowType.DICTIONARY
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var fb = _extract_fb_payload(frame^)
    var reader = flatbuf_reader_over(fb)
    var msg = read_message(reader, reader.read_root_offset())
    var rb = read_record_batch(reader, msg.header_table_pos)
    assert_equal(rb.length, Int64(0))
    # DICTIONARY = 2 buffers (validity zero-len + indices zero-len).
    assert_equal(len(rb.buffers), 2)


# ---------------------------------------------------------------------------
# Symmetric encode↔decode round-trips
# ---------------------------------------------------------------------------


def test_round_trip_int32_encode_decode() raises:
    """Encode 5 Int32 values, then decode them back via the new
    decoder. Verifies symmetric encode↔decode shape."""
    var vals = List[Int32]()
    vals.append(Int32(11))
    vals.append(Int32(22))
    vals.append(Int32(33))
    vals.append(Int32(44))
    vals.append(Int32(55))
    var col = _build_int32_column(vals)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.INT32)
    var decoded = decode_record_batch_message(frame^, schema_types^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.INT32)
    assert_equal(decoded[0]._length, 5)
    assert_equal(decoded[0]._null_count, 0)
    # Spot-check round-tripped values via the Column's _data buffer.
    for i in range(5):
        assert_equal(
            decoded[0]._data.read_i32_le_at(i * 4),
            vals[i],
        )


def test_round_trip_string_encode_decode() raises:
    """Encode 3 strings, decode back. Verifies var-len round-trip path."""
    from komira_arrow.string_array import StringArray
    var strs: List[String] = [
        String("alpha"),
        String("beta"),
        String("gamma"),
    ]
    var sa = StringArray.from_strings(strs)
    var col = Column.from_string(sa^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.STRING)
    var decoded = decode_record_batch_message(frame^, schema_types^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.STRING)
    assert_equal(decoded[0]._length, 3)
    # 3 strings of lengths 5+4+5 = 14 bytes.
    assert_equal(decoded[0]._data.len(), 14)
    # Offsets buffer: 4 × Int32 = 16 bytes.
    assert_true(decoded[0]._offsets)
    assert_equal(decoded[0]._offsets.value().len(), 16)


def test_round_trip_multi_column() raises:
    """Encode 2 columns of different types, decode back. Verifies
    multi-column buffer/node cursor tracking in the decoder."""
    # Column 0: Int64 [10, 20, 30]
    var iarr = PrimitiveArray[DType.int64].allocate(3)
    var ip = iarr._typed_ptr_mut()
    ip.store[width=1](0, Int64(10))
    ip.store[width=1](1, Int64(20))
    ip.store[width=1](2, Int64(30))
    var c0 = Column.from_primitive[DType.int64](iarr^)
    # Column 1: Float64 [1.5, 2.5, 3.5]
    var farr = PrimitiveArray[DType.float64].allocate(3)
    var fp = farr._typed_ptr_mut()
    fp.store[width=1](0, Float64(1.5))
    fp.store[width=1](1, Float64(2.5))
    fp.store[width=1](2, Float64(3.5))
    var c1 = Column.from_primitive[DType.float64](farr^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(c0^)
    cols.append(c1^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.INT64)
    schema_types.append(ArrowType.FLOAT64)
    var decoded = decode_record_batch_message(frame^, schema_types^)
    assert_equal(len(decoded), 2)
    assert_equal(decoded[0].arrow_type, ArrowType.INT64)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0]._data.read_i64_le_at(0), Int64(10))
    assert_equal(decoded[0]._data.read_i64_le_at(16), Int64(30))
    assert_equal(decoded[1].arrow_type, ArrowType.FLOAT64)
    assert_equal(decoded[1]._length, 3)
    # Float64 values; just check the bit pattern at offsets matches
    # Float64(1.5) etc. To avoid bitcast complexity, just check the
    # buffer length.
    assert_equal(decoded[1]._data.len(), 24)  # 3 × 8


def test_round_trip_decoder_buffer_count_mismatch_raises() raises:
    """If caller passes wrong schema_types (wrong count), decoder
    raises a clear FieldNode/Buffer mismatch error."""
    var vals = List[Int32]()
    vals.append(Int32(1))
    var col = _build_int32_column(vals)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    # Pass 2 types but the frame has only 1 column.
    var wrong_schema = List[ArrowType]()
    wrong_schema.append(ArrowType.INT32)
    wrong_schema.append(ArrowType.INT32)
    var threw = False
    try:
        var _decoded = decode_record_batch_message(frame^, wrong_schema^)
    except _:
        threw = True
    assert_true(threw)


# ---------------------------------------------------------------------------
# True zero-copy decoder — borrow-into-frame tests
# ---------------------------------------------------------------------------


def test_zerocopy_int32_decode_borrows_into_frame() raises:
    """Zero-copy decode of an Int32 column. The returned Column[HeapRegion]'s
    _data buffer should point into the source frame's bytes — verified
    by reading values out of decoded._data after frame is held alive.

    The SAFETY contract is that `frame` must outlive the returned
    Columns; here we test by keeping `frame` alive in the test scope.
    """
    var vals = List[Int32]()
    vals.append(Int32(111))
    vals.append(Int32(222))
    vals.append(Int32(333))
    var col = _build_int32_column(vals)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.INT32)
    var decoded = decode_record_batch_zerocopy(frame, schema_types^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.INT32)
    assert_equal(decoded[0]._length, 3)
    # The borrowed _data points into frame; reading values asserts
    # the borrow is correctly anchored.
    assert_equal(decoded[0]._data.read_i32_le_at(0), Int32(111))
    assert_equal(decoded[0]._data.read_i32_le_at(4), Int32(222))
    assert_equal(decoded[0]._data.read_i32_le_at(8), Int32(333))


def test_zerocopy_string_decode_borrows_into_frame() raises:
    """Zero-copy decode of a STRING column. Both offsets + data buffers
    are borrowed from frame.
    """
    from komira_arrow.string_array import StringArray
    var strs: List[String] = [
        String("foo"),
        String("barbar"),
        String("baz"),
    ]
    var sa = StringArray.from_strings(strs)
    var col = Column.from_string(sa^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.STRING)
    var decoded = decode_record_batch_zerocopy(frame, schema_types^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.STRING)
    assert_equal(decoded[0]._length, 3)
    # Data buffer total = 3 + 6 + 3 = 12 bytes.
    assert_equal(decoded[0]._data.len(), 12)
    # Offsets buffer = 4 × Int32 = 16 bytes.
    assert_true(decoded[0]._offsets)
    assert_equal(decoded[0]._offsets.value().len(), 16)


def test_zerocopy_multi_column_decode() raises:
    """2-column zero-copy decode (Int64 + Float64). Verifies multi-
    column cursor advance + multiple borrowed buffers anchored in
    the same frame.
    """
    var iarr = PrimitiveArray[DType.int64].allocate(3)
    var ip = iarr._typed_ptr_mut()
    ip.store[width=1](0, Int64(100))
    ip.store[width=1](1, Int64(200))
    ip.store[width=1](2, Int64(300))
    var c0 = Column.from_primitive[DType.int64](iarr^)

    var farr = PrimitiveArray[DType.float64].allocate(3)
    var fp = farr._typed_ptr_mut()
    fp.store[width=1](0, Float64(1.5))
    fp.store[width=1](1, Float64(2.5))
    fp.store[width=1](2, Float64(3.5))
    var c1 = Column.from_primitive[DType.float64](farr^)

    var cols = Slab[Column[HeapRegion]]()
    cols.append(c0^)
    cols.append(c1^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.INT64)
    schema_types.append(ArrowType.FLOAT64)
    var decoded = decode_record_batch_zerocopy(frame, schema_types^)
    assert_equal(len(decoded), 2)
    assert_equal(decoded[0].arrow_type, ArrowType.INT64)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0]._data.read_i64_le_at(0), Int64(100))
    assert_equal(decoded[0]._data.read_i64_le_at(16), Int64(300))
    assert_equal(decoded[1].arrow_type, ArrowType.FLOAT64)
    assert_equal(decoded[1]._length, 3)
    assert_equal(decoded[1]._data.len(), 24)


def test_dictionary_two_message_round_trip() raises:
    """Dictionary-encoded STRING column round-trip via the 2-message
    pattern:

      Frame 1: DictionaryBatch (dict_id=42, RecordBatch carrying dict
               VALUES — a 1-column STRING table with 3 unique strings).
      Frame 2: RecordBatch (1 DICTIONARY column carrying INDICES Int32
               buffer pointing into the dict).

    Validates that:
      - The DictionaryBatch FB metadata + body bytes round-trip via
        read_dictionary_batch + read_record_batch.
      - The RecordBatch FB metadata + body for the index column
        round-trips via decode_record_batch_message-style walking.
    """
    from komira_arrow.string_array import StringArray
    from komira_arrow.dictionary_array import StringDictionaryArray
    from komira_arrow_ipc.ipc_encoder_dispatch import (
        encode_dictionary_batch_message_from_string_column,
        make_string_dict_values_column_from_dictionary,
    )
    from komira_arrow_ipc.ipc_flatbuf import (
        read_dictionary_batch,
        MESSAGE_HEADER_DICTIONARY_BATCH,
    )

    # Build a 5-row dictionary-encoded column: indices [0, 1, 2, 0, 1]
    # into dict ["alpha", "beta", "gamma"].
    var indices = PrimitiveArray[DType.int32].allocate(5)
    var ip = indices._typed_ptr_mut()
    ip.store[width=1](0, Int32(0))
    ip.store[width=1](1, Int32(1))
    ip.store[width=1](2, Int32(2))
    ip.store[width=1](3, Int32(0))
    ip.store[width=1](4, Int32(1))
    var dict_strings: List[String] = [
        String("alpha"),
        String("beta"),
        String("gamma"),
    ]
    var dict_sa = StringArray.from_strings(dict_strings)
    var dict_arr = StringDictionaryArray.from_parts(indices^, dict_sa^)
    var dict_col = Column.from_dictionary(dict_arr^)
    assert_equal(dict_col.arrow_type, ArrowType.DICTIONARY)
    assert_equal(dict_col._length, 5)
    assert_equal(dict_col._dict_size, 3)

    # Frame 1: emit the DictionaryBatch. Build a separate deep_copy of
    # dict_col so we can also encode the RecordBatch below.
    var dict_col_for_dict = dict_col.deep_copy()
    var values_col = make_string_dict_values_column_from_dictionary(
        dict_col_for_dict^
    )
    var dict_frame = encode_dictionary_batch_message_from_string_column(
        Int64(42), values_col^, is_delta=False
    )

    # Decode Frame 1: confirm header_tag = DICTIONARY_BATCH + id = 42 +
    # dict RecordBatch length = 3.
    var f1 = parse_ipc_message(dict_frame)
    var fb1 = SharedAlignedBuffer[HeapRegion].heap_owned(f1.metadata_size)
    for i in range(f1.metadata_size):
        fb1.write_u8_at(i, dict_frame.read_u8_at(f1.metadata_pos + i))
    fb1.set_length(f1.metadata_size)

    var reader1 = flatbuf_reader_over(fb1)
    var msg1 = read_message(reader1, reader1.read_root_offset())
    assert_equal(msg1.header_tag, MESSAGE_HEADER_DICTIONARY_BATCH)
    var db = read_dictionary_batch(reader1, msg1.header_table_pos)
    assert_equal(db.id, Int64(42))
    assert_true(not db.is_delta)
    var dict_rb = read_record_batch(reader1, db.data_table_pos)
    assert_equal(dict_rb.length, Int64(3))  # 3 unique dict entries
    # STRING column = 3 buffers (validity + offsets + data).
    assert_equal(len(dict_rb.buffers), 3)

    # Frame 2: emit the RecordBatch containing the indices column.
    var cols = Slab[Column[HeapRegion]]()
    cols.append(dict_col^)
    var rb_frame = encode_record_batch_message(cols^)
    var fb2 = _extract_fb_payload(rb_frame^)
    var reader2 = flatbuf_reader_over(fb2)
    var msg2 = read_message(reader2, reader2.read_root_offset())
    assert_equal(msg2.header_tag, MESSAGE_HEADER_RECORD_BATCH)
    var rb = read_record_batch(reader2, msg2.header_table_pos)
    assert_equal(rb.length, Int64(5))
    # DICTIONARY column = 2 buffers (validity + Int32 indices).
    assert_equal(len(rb.buffers), 2)
    assert_equal(rb.buffers[1].length, Int64(20))  # 5 × 4


def test_fixed_size_list_int32_round_trip() raises:
    """FIXED_SIZE_LIST<Int32>(4) round-trip. 3 parent rows × 4 inner =
    12 inner Int32 values. Validates encoder emits validity-only (NO
    offsets); nested decoder reads spec.inner_size + reconstructs the
    child column via recursion.

    Realistic example: a 4-dim embedding column with 3 rows.
    """
    var inner_arr = PrimitiveArray[DType.int32].allocate(12)
    var ip = inner_arr._typed_ptr_mut()
    for i in range(12):
        ip.store[width=1](i, Int32(i + 1))
    var inner_col = Column.from_primitive[DType.int32](inner_arr^)
    var fsl_col = Column.from_fixed_size_list(
        inner_col^, list_size=4, length=3
    )
    var cols = Slab[Column[HeapRegion]]()
    cols.append(fsl_col^)
    var frame = encode_record_batch_message(cols^)

    var inner_spec = ColumnTypeSpec.leaf(ArrowType.INT32)
    var fsl_spec = ColumnTypeSpec.fixed_size_list_of(inner_spec^, 4)
    var schema_specs = Slab[ColumnTypeSpec]()
    schema_specs.append(fsl_spec^)

    var decoded = decode_record_batch_message_nested(frame^, schema_specs^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.FIXED_SIZE_LIST)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0]._inner_size, 4)
    assert_equal(decoded[0].num_children(), 1)
    assert_equal(decoded[0]._children[0].arrow_type, ArrowType.INT32)
    assert_equal(decoded[0]._children[0]._length, 12)
    # Spot-check inner values.
    assert_equal(decoded[0]._children[0]._data.read_i32_le_at(0), Int32(1))
    assert_equal(
        decoded[0]._children[0]._data.read_i32_le_at(11 * 4), Int32(12)
    )


def test_fixed_size_binary_round_trip() raises:
    """FIXED_SIZE_BINARY round-trip via Column.from_fixed_size_binary
    + nested decoder. byte_width=16 (covers Decimal128/IntervalMDN-shape
    payloads + pa.binary(16) interop). 3 rows × 16 bytes = 48 byte
    values buffer.
    """
    var data = OwnedAlignedBuffer(48)
    # Fill 3 rows of 16 bytes each with row-distinctive values.
    for row in range(3):
        for byte in range(16):
            data.write_u8_at(row * 16 + byte, UInt8(row * 32 + byte))
    data.set_length(48)

    var col = Column.from_fixed_size_binary(
        data^, byte_width=16, length=3
    )
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    # Decode via the nested decoder (the only path that knows about
    # byte_width via ColumnTypeSpec.inner_size).
    var schema_specs = Slab[ColumnTypeSpec]()
    schema_specs.append(ColumnTypeSpec.fixed_size_binary(16))
    var decoded = decode_record_batch_message_nested(frame^, schema_specs^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.FIXED_SIZE_BINARY)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0]._inner_size, 16)
    assert_equal(decoded[0]._data.len(), 48)
    # Spot-check row 0 first byte (0), row 1 first byte (32),
    # row 2 last byte (32*2 + 15 = 79).
    assert_equal(decoded[0]._data.read_u8_at(0), UInt8(0))
    assert_equal(decoded[0]._data.read_u8_at(16), UInt8(32))
    assert_equal(decoded[0]._data.read_u8_at(47), UInt8(79))


def test_nested_large_list_int32_round_trip() raises:
    """LARGE_LIST<Int32> round-trip via nested decoder. Validates the
    new ArrowType.LARGE_LIST + encode_large_list dispatch arm (Int64
    offsets) + nested decoder LARGE_LIST arm.

    Constructs synthetic LARGE_LIST Column directly via raw ctor since
    no Column.from_large_list_array factory exists yet.
    """
    from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
    # Build the inner Int32 child: [10, 20, 30, 40, 50] (5 elements).
    var inner_arr = PrimitiveArray[DType.int32].allocate(5)
    var ip = inner_arr._typed_ptr_mut()
    for i in range(5):
        ip.store[width=1](i, Int32((i + 1) * 10))
    var inner_col = Column.from_primitive[DType.int32](inner_arr^)

    # Build the outer LARGE_LIST: 3 lists of lengths 2 + 1 + 2 = 5 total.
    # Int64 offsets: [0, 2, 3, 5] = 4 × 8 = 32 bytes.
    var offsets = OwnedAlignedBuffer(32)
    offsets.write_i64_le_at(0, Int64(0))
    offsets.write_i64_le_at(8, Int64(2))
    offsets.write_i64_le_at(16, Int64(3))
    offsets.write_i64_le_at(24, Int64(5))
    offsets.set_length(32)


    var ll_col = Column[HeapRegion](
        arrow_type=ArrowType.LARGE_LIST,
        data=OwnedAlignedBuffer(0),
        offsets=offsets^,
        validity=None,
        length=3,
        null_count=0,
        offset=0,
    )
    ll_col._children.append(inner_col^)

    var cols = Slab[Column[HeapRegion]]()
    cols.append(ll_col^)
    var frame = encode_record_batch_message(cols^)

    # Build matching spec tree.
    var inner_spec = ColumnTypeSpec.leaf(ArrowType.INT32)
    var ll_spec = ColumnTypeSpec.large_list_of(inner_spec^)
    var schema_specs = Slab[ColumnTypeSpec]()
    schema_specs.append(ll_spec^)

    var decoded = decode_record_batch_message_nested(frame^, schema_specs^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.LARGE_LIST)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0].num_children(), 1)
    assert_equal(decoded[0]._children[0].arrow_type, ArrowType.INT32)
    assert_equal(decoded[0]._children[0]._length, 5)
    # Int64 offsets buffer = 32 bytes.
    assert_true(decoded[0]._offsets)
    assert_equal(decoded[0]._offsets.value().len(), 32)
    assert_equal(decoded[0]._offsets.value().read_i64_le_at(24), Int64(5))
    # Inner values: 10, 20, 30, 40, 50 = 5 × 4 = 20 bytes.
    assert_equal(decoded[0]._children[0]._data.len(), 20)
    assert_equal(decoded[0]._children[0]._data.read_i32_le_at(0), Int32(10))
    assert_equal(decoded[0]._children[0]._data.read_i32_le_at(16), Int32(50))


def test_nested_struct_round_trip() raises:
    """STRUCT<a: Int32, b: Int32> round-trip via the nested decoder.
    Verifies pre-order FieldNode + Buffer walk on the decode side
    matches the encode side; recursive child decode reconstructs
    Column._children correctly.
    """
    from komira_arrow.struct_array import StructArray
    # Build STRUCT<a, b> with 3 rows.
    var a_arr = PrimitiveArray[DType.int32].allocate(3)
    var ap = a_arr._typed_ptr_mut()
    ap.store[width=1](0, Int32(10))
    ap.store[width=1](1, Int32(20))
    ap.store[width=1](2, Int32(30))
    var b_arr = PrimitiveArray[DType.int32].allocate(3)
    var bp = b_arr._typed_ptr_mut()
    bp.store[width=1](0, Int32(100))
    bp.store[width=1](1, Int32(200))
    bp.store[width=1](2, Int32(300))
    var a_col = Column.from_primitive[DType.int32](a_arr^)
    var b_col = Column.from_primitive[DType.int32](b_arr^)
    var fields = List[String]()
    fields.append(String("a"))
    fields.append(String("b"))
    var s = StructArray.from_columns_2(fields, a_col^, b_col^)
    var col = Column.from_struct(s^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)

    # Build the matching ColumnTypeSpec tree.
    var child_specs = Slab[ColumnTypeSpec]()
    child_specs.append(ColumnTypeSpec.leaf(ArrowType.INT32))
    child_specs.append(ColumnTypeSpec.leaf(ArrowType.INT32))
    var field_names = List[String]()
    field_names.append(String("a"))
    field_names.append(String("b"))
    var struct_spec = ColumnTypeSpec.struct_of(child_specs^, field_names^)
    var schema_specs = Slab[ColumnTypeSpec]()
    schema_specs.append(struct_spec^)

    var decoded = decode_record_batch_message_nested(frame^, schema_specs^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.STRUCT)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0].num_children(), 2)
    assert_equal(decoded[0]._children[0].arrow_type, ArrowType.INT32)
    assert_equal(decoded[0]._children[1].arrow_type, ArrowType.INT32)
    # Spot-check child a's values.
    assert_equal(
        decoded[0]._children[0]._data.read_i32_le_at(0), Int32(10)
    )
    assert_equal(
        decoded[0]._children[0]._data.read_i32_le_at(8), Int32(30)
    )
    # Spot-check child b's values.
    assert_equal(
        decoded[0]._children[1]._data.read_i32_le_at(0), Int32(100)
    )
    assert_equal(
        decoded[0]._children[1]._data.read_i32_le_at(8), Int32(300)
    )
    # Field names preserved.
    assert_equal(len(decoded[0]._field_names), 2)
    assert_equal(String(decoded[0]._field_names[0]), String("a"))
    assert_equal(String(decoded[0]._field_names[1]), String("b"))


def test_zerocopy_int64_nullable_decode() raises:
    """Zero-copy decode of a nullable Int64 column (null_count > 0).
    Validity bitmap also borrows into frame's bytes.

    Constructs the test column via Column's raw ctor (NOT
    PrimitiveArray.allocate_nullable + _set_null, because the latter
    exercises a different path — this test is about the decoder).
    """
    from komira_arrow.bitmap import Bitmap
    var data_buf = OwnedAlignedBuffer(5 * 8)
    data_buf.write_i64_le_at(0, Int64(10))
    data_buf.write_i64_le_at(8, Int64(20))
    data_buf.write_i64_le_at(16, Int64(0))  # null slot
    data_buf.write_i64_le_at(24, Int64(40))
    data_buf.write_i64_le_at(32, Int64(0))  # null slot
    data_buf.set_length(40)

    # Validity bitmap: 1 1 0 1 0 = 0b01011 = 0x0b
    var validity = Bitmap.create(5)
    validity.buffer.write_u8_at(0, UInt8(0x0B))
    validity.buffer.set_length(1)

    var col = Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=data_buf^,
        offsets=None,
        validity=validity^,
        length=5,
        null_count=2,
        offset=0,
    )
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.INT64)
    var decoded = decode_record_batch_zerocopy(frame, schema_types^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.INT64)
    assert_equal(decoded[0]._length, 5)
    assert_equal(decoded[0]._null_count, 2)
    # Spot-check non-null values via borrowed data buffer.
    assert_equal(decoded[0]._data.read_i64_le_at(0), Int64(10))
    assert_equal(decoded[0]._data.read_i64_le_at(8), Int64(20))
    assert_equal(decoded[0]._data.read_i64_le_at(24), Int64(40))
    # Validity bitmap is borrowed; check it exists with the right length.
    assert_true(decoded[0]._validity)
    ref v = decoded[0]._validity.value()
    assert_equal(v.length, 5)
    # First byte = 0x0B (valid 0,1,3; null 2,4).
    assert_equal(v.buffer.read_u8_at(0), UInt8(0x0B))


def test_zerocopy_bool_column_raises() raises:
    """BOOL columns can't zero-copy (1-bit packed); decoder must raise."""
    # We need to encode a BOOL column first. Just use a synthetic empty
    # column with arrow_type = BOOL.
    from komira_arrow.boolean_array import BooleanArray
    from komira_arrow.bitmap import Bitmap
    var bits = Bitmap.create_all_valid(2)
    var ba = BooleanArray.from_bitmap(bits^)
    var col = Column.from_boolean(ba^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)
    var schema_types = List[ArrowType]()
    schema_types.append(ArrowType.BOOL)
    var threw = False
    try:
        var _decoded = decode_record_batch_zerocopy(frame, schema_types^)
    except _:
        threw = True
    assert_true(threw)


# ---------------------------------------------------------------------------
# Nested zero-copy decoder round-trip
# ---------------------------------------------------------------------------


def test_zerocopy_nested_struct_round_trip() raises:
    """STRUCT<a: Int32, b: Int32> via the nested zero-copy decoder.
    Verifies borrowed validity (None for all-non-null) + recursive
    children borrowing into the same frame.
    """
    from komira_arrow.struct_array import StructArray
    var a_arr = PrimitiveArray[DType.int32].allocate(3)
    var ap = a_arr._typed_ptr_mut()
    ap.store[width=1](0, Int32(7))
    ap.store[width=1](1, Int32(8))
    ap.store[width=1](2, Int32(9))
    var b_arr = PrimitiveArray[DType.int32].allocate(3)
    var bp = b_arr._typed_ptr_mut()
    bp.store[width=1](0, Int32(70))
    bp.store[width=1](1, Int32(80))
    bp.store[width=1](2, Int32(90))
    var a_col = Column.from_primitive[DType.int32](a_arr^)
    var b_col = Column.from_primitive[DType.int32](b_arr^)
    var fields = List[String]()
    fields.append(String("x"))
    fields.append(String("y"))
    var s = StructArray.from_columns_2(fields, a_col^, b_col^)
    var col = Column.from_struct(s^)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)

    var child_specs = Slab[ColumnTypeSpec]()
    child_specs.append(ColumnTypeSpec.leaf(ArrowType.INT32))
    child_specs.append(ColumnTypeSpec.leaf(ArrowType.INT32))
    var field_names = List[String]()
    field_names.append(String("x"))
    field_names.append(String("y"))
    var struct_spec = ColumnTypeSpec.struct_of(child_specs^, field_names^)
    var schema_specs = Slab[ColumnTypeSpec]()
    schema_specs.append(struct_spec^)

    var decoded = decode_record_batch_message_nested_zerocopy(
        frame, schema_specs^
    )
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.STRUCT)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0].num_children(), 2)
    assert_equal(decoded[0]._children[0].arrow_type, ArrowType.INT32)
    assert_equal(decoded[0]._children[1].arrow_type, ArrowType.INT32)
    # Borrowed children read directly from frame's bytes.
    assert_equal(
        decoded[0]._children[0]._data.read_i32_le_at(0), Int32(7)
    )
    assert_equal(
        decoded[0]._children[0]._data.read_i32_le_at(8), Int32(9)
    )
    assert_equal(
        decoded[0]._children[1]._data.read_i32_le_at(0), Int32(70)
    )
    assert_equal(
        decoded[0]._children[1]._data.read_i32_le_at(8), Int32(90)
    )
    # Field names preserved.
    assert_equal(String(decoded[0]._field_names[0]), String("x"))
    assert_equal(String(decoded[0]._field_names[1]), String("y"))


def test_zerocopy_nested_list_round_trip() raises:
    """LIST<Int64> zero-copy round-trip via ListArray.from_int_lists.
    Validity + Int32 offsets + 1 child all borrowed.
    """
    from komira_arrow.list_array import ListArray
    var lists = List[List[Int]]()
    var l0 = List[Int]()
    l0.append(1)
    l0.append(2)
    lists.append(l0^)
    lists.append(List[Int]())  # empty list at index 1
    var l2 = List[Int]()
    l2.append(3)
    l2.append(4)
    l2.append(5)
    lists.append(l2^)
    var la = ListArray.from_int_lists(lists)
    var col = la.to_column()
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    var frame = encode_record_batch_message(cols^)

    var inner = ColumnTypeSpec.leaf(ArrowType.INT64)
    var list_spec = ColumnTypeSpec.list_of(inner^)
    var schema_specs = Slab[ColumnTypeSpec]()
    schema_specs.append(list_spec^)

    var decoded = decode_record_batch_message_nested_zerocopy(
        frame, schema_specs^
    )
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.LIST)
    assert_equal(decoded[0]._length, 3)
    assert_equal(decoded[0].num_children(), 1)
    assert_equal(decoded[0]._children[0].arrow_type, ArrowType.INT64)
    # Borrowed offsets (4 × Int32 = 16 bytes).
    assert_true(decoded[0]._offsets)
    ref off = decoded[0]._offsets.value()
    assert_equal(off.read_i32_le_at(0), Int32(0))
    assert_equal(off.read_i32_le_at(4), Int32(2))
    assert_equal(off.read_i32_le_at(8), Int32(2))
    assert_equal(off.read_i32_le_at(12), Int32(5))
    # Borrowed child values (5 Int64s = 40 bytes).
    assert_equal(
        decoded[0]._children[0]._data.read_i64_le_at(0), Int64(1)
    )
    assert_equal(
        decoded[0]._children[0]._data.read_i64_le_at(32), Int64(5)
    )


def test_zerocopy_nested_view_type_raises() raises:
    """View types are fundamentally incompatible with zero-copy decode
    (lossy materialization required). Decoder must raise rather than
    silently produce wrong output.
    """
    var stream = _load_arrow_stream(
        "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/view_types_inline.arrow"
    )
    var rb_frame = _slice_after_schema(stream^)
    var specs = Slab[ColumnTypeSpec]()
    specs.append(ColumnTypeSpec.leaf(ArrowType.UTF8_VIEW))
    specs.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
    var threw = False
    try:
        var _d = decode_record_batch_message_nested_zerocopy(
            rb_frame, specs^
        )
    except _:
        threw = True
    assert_true(threw)


# ---------------------------------------------------------------------------
# View-type decoder round-trip
# ---------------------------------------------------------------------------


from std.io import FileHandle
from komira_buffer.heap_region import HeapRegion


def _load_arrow_stream(name: String) raises -> SharedAlignedBuffer[HeapRegion]:
    """Load a pyarrow IPC stream fixture (declared test data, opened by its
    repository path) into an 8-byte-aligned buffer."""
    var f = FileHandle(name, "r")
    _ = f.seek(0, 2)
    var file_size = Int(f.seek(0, 1))
    _ = f.seek(0, 0)
    var raw = f.read_bytes(file_size)
    f.close()
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(file_size)
    for i in range(file_size):
        out.write_u8_at(i, raw[i])
    out.set_length(file_size)

    return out^


def _slice_after_schema(
    var stream: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """Pyarrow stream layout: [Schema frame][RecordBatch frame][EOS].
    The Schema frame has body_length=0; this helper advances past it and
    returns a fresh buffer holding bytes starting at the RecordBatch's
    framing (continuation marker + size + metadata + body).
    """
    var schema_frame = parse_ipc_message(stream)
    # Schema body_length is 0; the RecordBatch frame starts at body_pos.
    var rb_start = schema_frame.body_pos
    var n = stream.len() - rb_start
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    for i in range(n):
        out.write_u8_at(i, stream.read_u8_at(rb_start + i))
    out.set_length(n)
    return out^


def test_view_types_inline_round_trip() raises:
    """pyarrow-emitted RecordBatch with Utf8View + BinaryView columns
    (all inline ≤12 bytes). Decoder lossy-expands to STRING + BINARY
    columns.

    Inline-branch coverage: length≤12 bytes are stored directly in
    bytes [4..16) of each 16-byte view; no variadic data buffer
    referenced.
    """
    var stream = _load_arrow_stream(
        "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/view_types_inline.arrow"
    )
    var rb_frame = _slice_after_schema(stream^)
    var specs = Slab[ColumnTypeSpec]()
    specs.append(ColumnTypeSpec.leaf(ArrowType.UTF8_VIEW))
    specs.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
    var decoded = decode_record_batch_message_nested(rb_frame^, specs^)
    assert_equal(len(decoded), 2)
    # Lossy expansion: UTF8_VIEW → STRING, BINARY_VIEW → BINARY.
    assert_equal(decoded[0].arrow_type, ArrowType.STRING)
    assert_equal(decoded[1].arrow_type, ArrowType.BINARY)
    assert_equal(decoded[0]._length, 5)
    assert_equal(decoded[1]._length, 5)
    # s_view values: "hi", "world", "foo", "", "abc"
    # Cumulative offsets: [0, 2, 7, 10, 10, 13]
    ref s_off = decoded[0]._offsets.value()
    assert_equal(s_off.read_i32_le_at(0), Int32(0))
    assert_equal(s_off.read_i32_le_at(4), Int32(2))
    assert_equal(s_off.read_i32_le_at(8), Int32(7))
    assert_equal(s_off.read_i32_le_at(12), Int32(10))
    assert_equal(s_off.read_i32_le_at(16), Int32(10))
    assert_equal(s_off.read_i32_le_at(20), Int32(13))
    # Spot-check a few bytes of the flat data.
    assert_equal(decoded[0]._data.read_u8_at(0), UInt8(ord("h")))
    assert_equal(decoded[0]._data.read_u8_at(1), UInt8(ord("i")))
    assert_equal(decoded[0]._data.read_u8_at(2), UInt8(ord("w")))
    assert_equal(decoded[0]._data.read_u8_at(10), UInt8(ord("a")))
    assert_equal(decoded[0]._data.read_u8_at(12), UInt8(ord("c")))
    # b_view values: \x01\x02, "", "abcdefg", "x", "\xff"
    # Cumulative offsets: [0, 2, 2, 9, 10, 11]
    ref b_off = decoded[1]._offsets.value()
    assert_equal(b_off.read_i32_le_at(0), Int32(0))
    assert_equal(b_off.read_i32_le_at(4), Int32(2))
    assert_equal(b_off.read_i32_le_at(8), Int32(2))
    assert_equal(b_off.read_i32_le_at(12), Int32(9))
    assert_equal(b_off.read_i32_le_at(16), Int32(10))
    assert_equal(b_off.read_i32_le_at(20), Int32(11))
    assert_equal(decoded[1]._data.read_u8_at(0), UInt8(0x01))
    assert_equal(decoded[1]._data.read_u8_at(1), UInt8(0x02))
    assert_equal(decoded[1]._data.read_u8_at(2), UInt8(ord("a")))
    assert_equal(decoded[1]._data.read_u8_at(8), UInt8(ord("g")))
    assert_equal(decoded[1]._data.read_u8_at(9), UInt8(ord("x")))
    assert_equal(decoded[1]._data.read_u8_at(10), UInt8(0xFF))


def test_view_types_indirect_round_trip() raises:
    """pyarrow-emitted Utf8View column with values > 12 bytes (indirect
    branch). pyarrow stores long values in a variadic data buffer
    pointed to by buffer_idx + offset within each 16-byte view.

    Exercises:
      - variadic_buffer_counts read from RecordBatch FB table (field 4)
      - view_col_idx threading through _decode_column_nested
      - indirect view resolution in _decode_binary_or_utf8_view
    """
    var stream = _load_arrow_stream(
        "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/view_types_indirect.arrow"
    )
    var rb_frame = _slice_after_schema(stream^)
    var specs = Slab[ColumnTypeSpec]()
    specs.append(ColumnTypeSpec.leaf(ArrowType.UTF8_VIEW))
    var decoded = decode_record_batch_message_nested(rb_frame^, specs^)
    assert_equal(len(decoded), 1)
    assert_equal(decoded[0].arrow_type, ArrowType.STRING)
    assert_equal(decoded[0]._length, 4)
    # Values: "short" (5), "this is a long string > 12 bytes" (32),
    #         "another moderately long string" (30), "short2" (6).
    # Cumulative offsets: [0, 5, 37, 67, 73]
    ref off = decoded[0]._offsets.value()
    assert_equal(off.read_i32_le_at(0), Int32(0))
    assert_equal(off.read_i32_le_at(4), Int32(5))
    assert_equal(off.read_i32_le_at(8), Int32(37))
    assert_equal(off.read_i32_le_at(12), Int32(67))
    assert_equal(off.read_i32_le_at(16), Int32(73))
    # First value: "short"
    assert_equal(decoded[0]._data.read_u8_at(0), UInt8(ord("s")))
    assert_equal(decoded[0]._data.read_u8_at(1), UInt8(ord("h")))
    assert_equal(decoded[0]._data.read_u8_at(4), UInt8(ord("t")))
    # Second value starts at offset 5: "this is a long string > 12 bytes"
    assert_equal(decoded[0]._data.read_u8_at(5), UInt8(ord("t")))
    assert_equal(decoded[0]._data.read_u8_at(6), UInt8(ord("h")))
    assert_equal(decoded[0]._data.read_u8_at(7), UInt8(ord("i")))
    assert_equal(decoded[0]._data.read_u8_at(8), UInt8(ord("s")))
    # End of last value: "short2"
    assert_equal(decoded[0]._data.read_u8_at(67), UInt8(ord("s")))
    assert_equal(decoded[0]._data.read_u8_at(72), UInt8(ord("2")))


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_int32_single_column_round_trip]()
    suite.test[test_int32_values_round_trip_in_body]()
    suite.test[test_int32_two_column_row_count_validation]()
    suite.test[test_int32_two_column_round_trip]()
    suite.test[test_int64_round_trip]()
    suite.test[test_uint32_round_trip]()
    suite.test[test_int8_round_trip_single_byte_elements]()
    suite.test[test_string_round_trip]()
    suite.test[test_wide_binary_many_rows_body_size_estimate]()
    suite.test[test_date32_round_trip]()
    suite.test[test_timestamp_us_round_trip]()
    suite.test[test_struct_round_trip_pre_order_field_nodes]()
    suite.test[test_view_type_encoders_raise_v05]()
    suite.test[test_dictionary_empty_indices_smoke]()
    suite.test[test_dictionary_two_message_round_trip]()
    suite.test[test_round_trip_int32_encode_decode]()
    suite.test[test_round_trip_string_encode_decode]()
    suite.test[test_round_trip_multi_column]()
    suite.test[test_round_trip_decoder_buffer_count_mismatch_raises]()
    suite.test[test_zerocopy_int32_decode_borrows_into_frame]()
    suite.test[test_zerocopy_string_decode_borrows_into_frame]()
    suite.test[test_zerocopy_multi_column_decode]()
    suite.test[test_zerocopy_int64_nullable_decode]()
    suite.test[test_zerocopy_bool_column_raises]()
    suite.test[test_nested_struct_round_trip]()
    suite.test[test_nested_large_list_int32_round_trip]()
    suite.test[test_fixed_size_binary_round_trip]()
    suite.test[test_fixed_size_list_int32_round_trip]()
    suite.test[test_view_types_inline_round_trip]()
    suite.test[test_view_types_indirect_round_trip]()
    suite.test[test_zerocopy_nested_struct_round_trip]()
    suite.test[test_zerocopy_nested_list_round_trip]()
    suite.test[test_zerocopy_nested_view_type_raises]()
    suite^.run()
