# =============================================================================
# test_ipc_morsel_fill_arms.mojo: IpcMorselFill's type tables, its whole-batch
# declines, its frame refusals and the view it serves
# =============================================================================
#
# test_ipc_field_node_check.mojo drives the fill's node and size checks over
# one INT64 column. This file covers the rest:
#   * ipc_fixed_width_bytes and ipc_buffer_count for every type they name,
#     and the refusal of a type the fill does not support;
#   * the two whole-batch declines (more than 64 columns, a compressed body)
#     and the refusals of a frame that is not a RecordBatch, of a node or
#     buffer count that disagrees with the schema, of a negative buffer
#     length and of a buffer outside the body (past the end, straddling it,
#     at a negative offset);
#   * a three-column fill (INT32 with nulls, STRING, FLOAT64) read through
#     IpcMorselView: the STRING column is declined, the numeric ones serve
#     their values and validity, and a reset invalidates the view.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    write_body_compression,
    write_ipc_message,
    write_message,
    write_record_batch,
    write_record_batch_compressed,
)
from komira_arrow_ipc.ipc_morsel_fill import (
    IpcMorselFill,
    ipc_buffer_count,
    ipc_fixed_width_bytes,
    ipc_morsel_view_over,
)


comptime FILL = "IpcMorselFill.fill_from_frame"


# ---------------------------------------------------------------------------
# Type tables
# ---------------------------------------------------------------------------


def _check_table(fixed: Bool, rows: List[Tuple[ArrowType, Int]]) raises:
    """Each (type, expected) row of `rows` through ipc_fixed_width_bytes
    (`fixed`) or ipc_buffer_count. The types come out of a List, so each
    call is made at run time rather than folded at compile time."""
    for i in range(len(rows)):
        var t = rows[i][0]
        var got = ipc_fixed_width_bytes(t) if fixed else ipc_buffer_count(t)
        assert_equal(got, rows[i][1], String(t))


def test_fixed_width_bytes_of_every_type() raises:
    """Every fixed-width type's element size, and 0 for the types that are
    not a dense native run (bit-packed, variable-length, dictionary-coded,
    nested), and 0 for DECIMAL128: its values are a dense 16-byte run, but
    ipc_fixed_width_bytes does not size it."""
    var rows = List[Tuple[ArrowType, Int]]()
    rows.append((ArrowType.INT8, 1))
    rows.append((ArrowType.UINT8, 1))
    rows.append((ArrowType.INT16, 2))
    rows.append((ArrowType.UINT16, 2))
    rows.append((ArrowType.INT32, 4))
    rows.append((ArrowType.UINT32, 4))
    rows.append((ArrowType.INT64, 8))
    rows.append((ArrowType.UINT64, 8))
    rows.append((ArrowType.FLOAT16, 2))
    rows.append((ArrowType.FLOAT32, 4))
    rows.append((ArrowType.FLOAT64, 8))
    rows.append((ArrowType.DATE32, 4))
    rows.append((ArrowType.DATE64, 8))
    rows.append((ArrowType.TIME32_S, 4))
    rows.append((ArrowType.TIME32_MS, 4))
    rows.append((ArrowType.TIME64_US, 8))
    rows.append((ArrowType.TIME64_NS, 8))
    rows.append((ArrowType.TIMESTAMP, 8))
    rows.append((ArrowType.TIMESTAMP_S, 8))
    rows.append((ArrowType.TIMESTAMP_MS, 8))
    rows.append((ArrowType.TIMESTAMP_US, 8))
    rows.append((ArrowType.TIMESTAMP_NS, 8))
    rows.append((ArrowType.DURATION_S, 8))
    rows.append((ArrowType.DURATION_MS, 8))
    rows.append((ArrowType.DURATION_US, 8))
    rows.append((ArrowType.DURATION_NS, 8))
    rows.append((ArrowType.BOOL, 0))
    rows.append((ArrowType.STRING, 0))
    rows.append((ArrowType.DICTIONARY, 0))
    rows.append((ArrowType.DECIMAL128, 0))
    rows.append((ArrowType.LIST, 0))
    _check_table(True, rows)


def test_buffer_count_of_every_type() raises:
    var rows = List[Tuple[ArrowType, Int]]()
    rows.append((ArrowType.NULL, 0))
    rows.append((ArrowType.BOOL, 2))
    rows.append((ArrowType.STRING, 3))
    rows.append((ArrowType.BINARY, 3))
    rows.append((ArrowType.LARGE_STRING, 3))
    rows.append((ArrowType.LARGE_BINARY, 3))
    rows.append((ArrowType.DICTIONARY, 2))
    rows.append((ArrowType.DECIMAL128, 2))
    rows.append((ArrowType.DECIMAL256, 2))
    rows.append((ArrowType.INT16, 2))
    rows.append((ArrowType.DURATION_NS, 2))
    _check_table(False, rows)
    var msg = String("")
    try:
        _ = ipc_buffer_count(ArrowType.LIST)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "ipc_buffer_count: ArrowType 20 is not supported by the Arrow-IPC"
        " MorselView fill",
    )


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------


comptime BODY = 64


def _frame_full(
    header: UInt8,
    rb_len: Int,
    var nodes: List[FieldNode],
    var bufs: List[BufferDescriptor],
    codec: Int,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A frame of a Message with header `header` over a RecordBatch of
    `nodes` and `bufs` (a BodyCompression of `codec` unless it is -1) and a
    64-byte body: INT32 10, 11, 12 at 0, the bitmap 0b101 at 16, the STRING
    offsets 0, 1, 2, 3 at 24, its data "xyz" at 40 and FLOAT64 2.5 at 48."""
    var w = FlatbufWriter(2048)
    var rb_pos: Int
    if codec < 0:
        rb_pos = write_record_batch(w, Int64(rb_len), nodes, bufs)
    else:
        var bc = write_body_compression(w, Int8(codec))
        rb_pos = write_record_batch_compressed(w, Int64(rb_len), nodes, bufs, bc)
    var msg_pos = write_message(w, Int16(4), header, rb_pos, Int64(BODY))
    var fb = w^.finalize(msg_pos)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(BODY)
    body.zero()
    body.write_i32_le_at(0, Int32(10))
    body.write_i32_le_at(4, Int32(11))
    body.write_i32_le_at(8, Int32(12))
    body.write_u8_at(16, UInt8(0b101))
    for i in range(4):
        body.write_i32_le_at(24 + i * 4, Int32(i))
    body.write_u8_at(40, UInt8(ord("x")))
    body.write_u8_at(41, UInt8(ord("y")))
    body.write_u8_at(42, UInt8(ord("z")))
    body.write_f64_le_at(48, Float64(2.5))
    body.set_length(BODY)
    var w2 = FlatbufWriter(64)
    var span = body.view_range_ro(0, BODY).into_span()
    return write_ipc_message(w2, fb^, span, True)


def _node(length: Int, nulls: Int) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(nulls))


def _buf(off: Int, length: Int) -> BufferDescriptor:
    return BufferDescriptor(offset=Int64(off), length=Int64(length))


def _int32_frame(
    header: UInt8, v_off: Int, v_len: Int, codec: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """One INT32 column of 3 rows, no nulls; values buffer (v_off, v_len)."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(v_off, v_len))
    return _frame_full(header, 3, nodes^, bufs^, codec)


def _int32() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT32)
    return t^


def _fill_err(
    var frame: SharedAlignedBuffer[HeapRegion], types: List[ArrowType]
) -> String:
    var fill = IpcMorselFill()
    try:
        _ = fill.fill_from_frame(frame^, types)
    except e:
        return String(e)
    return String("no error")


# ---------------------------------------------------------------------------
# Whole-batch declines
# ---------------------------------------------------------------------------


def test_declines_more_than_64_columns() raises:
    """65 columns decline before the frame is read; 64 are read (and here
    refused for disagreeing with the one-column frame, which shows they were
    not declined)."""
    var t65 = List[ArrowType]()
    for _ in range(65):
        t65.append(ArrowType.INT32)
    var fill = IpcMorselFill()
    assert_false(
        fill.fill_from_frame(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, -1), t65
        )
    )
    assert_false(fill.filled)
    _ = t65.pop()
    var msg = _fill_err(_int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, -1), t65)
    assert_equal(
        msg, String(FILL) + ": FieldNode count mismatch (got 1, expected 64)"
    )


def test_declines_a_compressed_body() raises:
    var fill = IpcMorselFill()
    # LZ4_FRAME (0) and ZSTD (1) both decline; the uncompressed control fills.
    assert_false(
        fill.fill_from_frame(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, 0), _int32()
        )
    )
    assert_false(
        fill.fill_from_frame(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, 1), _int32()
        )
    )
    assert_false(fill.filled)
    assert_true(
        fill.fill_from_frame(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, -1), _int32()
        )
    )
    assert_true(fill.filled)


# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------


def test_refuses_a_message_that_is_not_a_record_batch() raises:
    var msg = _fill_err(
        _int32_frame(MESSAGE_HEADER_DICTIONARY_BATCH, 0, 12, -1), _int32()
    )
    assert_equal(
        msg, "IpcMorselFill: expected RECORD_BATCH header (tag 3), got 2"
    )


def test_refuses_node_and_buffer_count_mismatches() raises:
    var two = List[ArrowType]()
    two.append(ArrowType.INT32)
    two.append(ArrowType.INT32)
    assert_equal(
        _fill_err(_int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, -1), two),
        String(FILL) + ": FieldNode count mismatch (got 1, expected 2)",
    )
    # One node, three buffers, for one INT32 column (two buffers).
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 12))
    bufs.append(_buf(0, 0))
    assert_equal(
        _fill_err(
            _frame_full(MESSAGE_HEADER_RECORD_BATCH, 3, nodes^, bufs^, -1),
            _int32(),
        ),
        String(FILL) + ": Buffer count mismatch (got 3, expected 2)",
    )


def test_refuses_a_negative_buffer_length() raises:
    assert_equal(
        _fill_err(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, -4, -1), _int32()
        ),
        String(FILL) + ": Buffer[1] has negative length",
    )


def test_refuses_a_buffer_outside_the_body() raises:
    # Past the end: starts beyond the 64-byte body.
    assert_equal(
        _fill_err(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 65, 12, -1), _int32()
        ),
        String(FILL) + ": Buffer[1] range [65, 77) escapes the 64-byte"
        " message body",
    )
    # Straddling the end: starts inside, ends one byte past it.
    assert_equal(
        _fill_err(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 53, 12, -1), _int32()
        ),
        String(FILL) + ": Buffer[1] range [53, 65) escapes the 64-byte"
        " message body",
    )
    # Longer than the whole body.
    assert_equal(
        _fill_err(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 65, -1), _int32()
        ),
        String(FILL) + ": Buffer[1] range [0, 65) escapes the 64-byte"
        " message body",
    )
    # A negative offset.
    assert_equal(
        _fill_err(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, -8, 12, -1), _int32()
        ),
        String(FILL) + ": Buffer[1] range [-8, 4) escapes the 64-byte"
        " message body",
    )
    # Ending exactly at the body's end is inside it.
    var fill = IpcMorselFill()
    assert_true(
        fill.fill_from_frame(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 52, 12, -1), _int32()
        )
    )


# ---------------------------------------------------------------------------
# A mixed batch through the view
# ---------------------------------------------------------------------------


def _mixed() raises -> SharedAlignedBuffer[HeapRegion]:
    """INT32 (3 rows, row 1 null: bitmap 0b101 at 16; values at 0), STRING
    (offsets at 24, data at 40), FLOAT64 (values: the 24 bytes at 40, so
    row 1 is the 2.5 at 48)."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 1))
    nodes.append(_node(3, 0))
    nodes.append(_node(3, 0))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(16, 1))
    bufs.append(_buf(0, 12))
    bufs.append(_buf(0, 0))
    bufs.append(_buf(24, 16))
    bufs.append(_buf(40, 3))
    bufs.append(_buf(0, 0))
    bufs.append(_buf(40, 24))
    return _frame_full(MESSAGE_HEADER_RECORD_BATCH, 3, nodes^, bufs^, -1)


def _mixed_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT32)
    t.append(ArrowType.STRING)
    t.append(ArrowType.FLOAT64)
    return t^


def test_mixed_batch_through_the_view() raises:
    var fill = IpcMorselFill()
    assert_true(fill.fill_from_frame(_mixed(), _mixed_types()))
    assert_equal(fill.num_cols(), 3)
    var v = ipc_morsel_view_over(fill)
    assert_true(v.is_valid())
    assert_equal(v.n_rows(), 3)
    assert_equal(v.num_columns(), 3)
    assert_false(v.has_selection_mask())
    assert_true(v.selection_mask_get(2))
    # The STRING column is declined; the numeric ones are not.
    assert_false(v.col_is_declined(0))
    assert_true(v.col_is_declined(1))
    assert_false(v.col_is_declined(2))
    # INT32 values and validity straight from the frame.
    assert_equal(v.col_scalar[DType.int32](0, 0), Int32(10))
    assert_equal(v.col_scalar_nonraising[DType.int32](0, 2), Int32(12))
    var simd = v.col_scalar_simd[DType.int32, 2](0, 1)
    assert_equal(simd[0], Int32(11))
    assert_equal(simd[1], Int32(12))
    assert_false(v.col_is_null(0, 0))
    assert_true(v.col_is_null(0, 1))
    assert_false(v.col_is_null(0, 2))
    var c0 = v.col_numeric[DType.int32](0)
    assert_true(c0.has_validity())
    assert_equal(c0.length(), 3)
    assert_equal(c0.load[1](2)[0], Int32(12))
    var valid = c0.validity_load[4](0)
    assert_true(valid[0])
    assert_false(valid[1])
    assert_true(valid[2])
    # FLOAT64 has no nulls: no bitmap, every lane valid.
    var c2 = v.col_numeric[DType.float64](2)
    assert_false(c2.has_validity())
    var all_valid = c2.validity_load[2](1)
    assert_true(all_valid[0] and all_valid[1])
    assert_false(v.col_is_null(2, 1))
    assert_equal(v.col_scalar[DType.float64](2, 1), Float64(2.5))
    # A reset invalidates the view.
    var gen = v.generation()
    fill.reset()
    assert_equal(fill.gen(), gen + 1)
    assert_equal(fill.num_rows(), 0)


def test_reset_makes_an_earlier_view_stale() raises:
    var fill = IpcMorselFill()
    assert_true(fill.fill_from_frame(_mixed(), _mixed_types()))
    var before = ipc_morsel_view_over(fill).generation()
    assert_true(
        fill.fill_from_frame(
            _int32_frame(MESSAGE_HEADER_RECORD_BATCH, 0, 12, -1), _int32()
        )
    )
    var v = ipc_morsel_view_over(fill)
    assert_equal(v.generation(), before + 1)
    assert_true(v.is_valid())
    assert_equal(v.num_columns(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
