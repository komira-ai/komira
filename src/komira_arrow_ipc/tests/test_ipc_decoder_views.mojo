# =============================================================================
# test_ipc_decoder_views.mojo: LIST_VIEW / LARGE_LIST_VIEW and
# BINARY_VIEW / UTF8_VIEW through decode_record_batch_message_nested, on
# hand-written frames
# =============================================================================
#
# The nested decoder expands a list view into LIST / LARGE_LIST cumulative
# offsets when its ranges are in order and packed, and a binary or utf8
# view into BINARY / STRING. Each case below is one frame:
#   * LARGE_LIST_VIEW<int64> with ranges [0,2) [2,2) [2,3): decoded to
#     LARGE_LIST offsets 0, 2, 2, 3 (the 8-byte arm, untested elsewhere);
#     a negative size and an out-of-order offset in it are refused naming
#     the range;
#   * LIST_VIEW: an offsets or sizes buffer shorter than length x 4, a
#     negative size, and a spec without exactly one child are refused;
#   * UTF8_VIEW: a view column with no variadic count entry, a negative
#     variadic count, a view buffer shorter than length x 16, a negative
#     view length, a long view naming a variadic buffer that does not
#     exist, a negative offset into it, and a range past its end are
#     refused; the long-view control decodes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_nested,
)
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_RECORD_BATCH,
    write_ipc_message,
    write_message,
    write_record_batch,
)


comptime BODY = 128


struct Body(Movable):
    """A zeroed BODY-byte message body the cases write words into."""

    var buf: SharedAlignedBuffer[HeapRegion]

    def __init__(out self) raises:
        self.buf = SharedAlignedBuffer[HeapRegion].heap_owned(BODY)
        self.buf.zero()
        self.buf.set_length(BODY)

    def i32(mut self, at: Int, v: Int):
        self.buf.write_i32_le_at(at, Int32(v))

    def i64(mut self, at: Int, v: Int):
        self.buf.write_i64_le_at(at, Int64(v))

    def text(mut self, at: Int, s: String):
        var b = s.as_bytes()
        for i in range(len(b)):
            self.buf.write_u8_at(at + i, b[i])


def _frame(
    rows: Int,
    var nodes: List[FieldNode],
    var bufs: List[BufferDescriptor],
    var body: Body,
    var variadic: List[Int64] = List[Int64](),
) raises -> SharedAlignedBuffer[HeapRegion]:
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(w, Int64(rows), nodes, bufs, variadic)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(BODY)
    )
    var fb = w^.finalize(msg_pos)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(
        w2, fb^, body.buf.view_range_ro(0, BODY).into_span(), True
    )


def _node(length: Int, nulls: Int = 0) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(nulls))


def _buf(off: Int, length: Int) -> BufferDescriptor:
    return BufferDescriptor(offset=Int64(off), length=Int64(length))


def _decode_error(
    var frame: SharedAlignedBuffer[HeapRegion], var spec: ColumnTypeSpec
) -> String:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(spec^)
    try:
        _ = decode_record_batch_message_nested(frame^, specs^)
    except e:
        return String(e)
    return String("no error")


# ---------------------------------------------------------------------------
# List views
# ---------------------------------------------------------------------------


def _list_view_spec(t: ArrowType) raises -> ColumnTypeSpec:
    var kids = Slab[ColumnTypeSpec]()
    kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    return ColumnTypeSpec(
        arrow_type=t,
        children=kids^,
        field_names=List[String](),
        type_ids=List[Int](),
        inner_size=0,
    )


def _large_list_view_frame(
    off1: Int, size1: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """LARGE_LIST_VIEW of 3 rows over an int64 child of 3 rows: Int64
    offsets 0, off1, 2 at 0 and sizes 2, size1, 1 at 24; child values
    11, 22, 33 at 48."""
    var body = Body()
    body.i64(0, 0)
    body.i64(8, off1)
    body.i64(16, 2)
    body.i64(24, 2)
    body.i64(32, size1)
    body.i64(40, 1)
    body.i64(48, 11)
    body.i64(56, 22)
    body.i64(64, 33)
    var nodes = List[FieldNode]()
    nodes.append(_node(3))
    nodes.append(_node(3))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    bufs.append(_buf(24, 24))
    bufs.append(_buf(0, 0))
    bufs.append(_buf(48, 24))
    return _frame(3, nodes^, bufs^, body^)


def test_large_list_view_expands_to_large_list() raises:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(_list_view_spec(ArrowType.LARGE_LIST_VIEW))
    var cols = decode_record_batch_message_nested(
        _large_list_view_frame(2, 0), specs^
    )
    ref c = cols[0]
    assert_equal(c.arrow_type, ArrowType.LARGE_LIST)
    assert_equal(c._length, 3)
    ref off = c._offsets.value()
    assert_equal(off.read_i64_le_at(0), Int64(0))
    assert_equal(off.read_i64_le_at(8), Int64(2))
    assert_equal(off.read_i64_le_at(16), Int64(2))
    assert_equal(off.read_i64_le_at(24), Int64(3))
    assert_equal(c.num_children(), 1)
    assert_equal(c._children[0]._data.read_i64_le_at(16), Int64(33))


def test_large_list_view_refuses_a_negative_size() raises:
    var msg = _decode_error(
        _large_list_view_frame(2, -1), _list_view_spec(ArrowType.LARGE_LIST_VIEW)
    )
    assert_equal(
        msg,
        "_decode_list_view: field node #0 (LARGE_LIST_VIEW) range 1 declares a"
        " NEGATIVE size of -1; Arrow LargeListView sizes are unsigned element"
        " counts",
    )


def test_large_list_view_refuses_an_out_of_order_range() raises:
    var msg = _decode_error(
        _large_list_view_frame(1, 0), _list_view_spec(ArrowType.LARGE_LIST_VIEW)
    )
    assert_equal(
        msg,
        "_decode_list_view: range 1 offset 1 not in-order (expected 2);"
        " overlapping/out-of-order LargeListView is not supported",
    )


def _list_view_frame(
    off_len: Int, size_len: Int, size1: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """LIST_VIEW of 3 rows: Int32 offsets 0, 2, 2 at 0 (`off_len` bytes
    declared), sizes 2, size1, 1 at 16 (`size_len` bytes declared); child
    int64 11, 22, 33 at 32."""
    var body = Body()
    body.i32(0, 0)
    body.i32(4, 2)
    body.i32(8, 2)
    body.i32(16, 2)
    body.i32(20, size1)
    body.i32(24, 1)
    body.i64(32, 11)
    body.i64(40, 22)
    body.i64(48, 33)
    var nodes = List[FieldNode]()
    nodes.append(_node(3))
    nodes.append(_node(3))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, off_len))
    bufs.append(_buf(16, size_len))
    bufs.append(_buf(0, 0))
    bufs.append(_buf(32, 24))
    return _frame(3, nodes^, bufs^, body^)


def test_list_view_control_decodes() raises:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(_list_view_spec(ArrowType.LIST_VIEW))
    var cols = decode_record_batch_message_nested(
        _list_view_frame(12, 12, 0), specs^
    )
    assert_equal(cols[0].arrow_type, ArrowType.LIST)
    assert_equal(cols[0]._offsets.value().read_i32_le_at(12), Int32(3))


def test_list_view_refuses_short_offsets_and_sizes() raises:
    var spec = _list_view_spec(ArrowType.LIST_VIEW)
    assert_equal(
        _decode_error(_list_view_frame(11, 12, 0), spec^),
        "_decode_list_view: offsets buffer too small (got 11, expected 12)",
    )
    spec = _list_view_spec(ArrowType.LIST_VIEW)
    assert_equal(
        _decode_error(_list_view_frame(12, 11, 0), spec^),
        "_decode_list_view: sizes buffer too small (got 11, expected 12)",
    )


def test_list_view_refuses_a_negative_size() raises:
    assert_equal(
        _decode_error(
            _list_view_frame(12, 12, -1), _list_view_spec(ArrowType.LIST_VIEW)
        ),
        "_decode_list_view: field node #0 (LIST_VIEW) range 1 declares a"
        " NEGATIVE size of -1; Arrow ListView sizes are unsigned element"
        " counts",
    )


def test_list_view_spec_needs_one_child() raises:
    var spec = ColumnTypeSpec(
        arrow_type=ArrowType.LIST_VIEW,
        children=Slab[ColumnTypeSpec](),
        field_names=List[String](),
        type_ids=List[Int](),
        inner_size=0,
    )
    var msg = _decode_error(_list_view_frame(12, 12, 0), spec^)
    assert_equal(
        msg, "_decode_column_nested ListView: spec.children count 0 != 1"
    )


# ---------------------------------------------------------------------------
# Binary / utf8 views
# ---------------------------------------------------------------------------


def _view_frame(
    view_len: Int,
    var variadic: List[Int64],
    view_buf_len: Int = 32,
    buf_idx: Int = 0,
    in_off: Int = 0,
    data_len: Int = 16,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """UTF8_VIEW of 2 rows. Row 0 is the inline view "hi" (length 2); row
    1 has length `view_len`, variadic buffer `buf_idx` and offset `in_off`
    (a long view when view_len > 12). Views at 0 (`view_buf_len` bytes
    declared); the one variadic buffer at 64 holds "abcdefghijklmnop"
    (`data_len` bytes declared)."""
    var body = Body()
    body.i32(0, 2)
    body.text(4, "hi")
    body.i32(16, view_len)
    body.text(20, "abcd")
    body.i32(24, buf_idx)
    body.i32(28, in_off)
    body.text(64, "abcdefghijklmnop")
    var nodes = List[FieldNode]()
    nodes.append(_node(2))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, view_buf_len))
    bufs.append(_buf(64, data_len))
    return _frame(2, nodes^, bufs^, body^, variadic^)


def _one(n: Int) -> List[Int64]:
    var v = List[Int64]()
    v.append(Int64(n))
    return v^


def _utf8_view() raises -> ColumnTypeSpec:
    return ColumnTypeSpec.leaf(ArrowType.UTF8_VIEW)


def test_utf8_view_control_decodes_inline_and_long_views() raises:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(_utf8_view())
    var cols = decode_record_batch_message_nested(
        _view_frame(14, _one(1), in_off=2), specs^
    )
    assert_equal(cols[0].arrow_type, ArrowType.STRING)
    var s = cols[0].as_string()
    assert_equal(s.get(0), String("hi"))
    assert_equal(s.get(1), String("cdefghijklmnop"))


def test_utf8_view_needs_a_variadic_count_entry() raises:
    """A view column with no count entry; the frame's one variadic buffer
    makes the buffer count agree, so the refusal is the count list's."""
    var msg = _decode_error(_view_frame(2, List[Int64]()), _utf8_view())
    assert_true(
        "view_col_idx 0 out of range; variadic_buffer_counts has 0 entries"
        in msg,
        msg,
    )


def test_utf8_view_refuses_a_negative_variadic_count() raises:
    var msg = _decode_error(_view_frame(2, _one(-1)), _utf8_view())
    assert_true(
        "variadic_buffer_counts entry must be non-negative" in msg
        or "variadic" in msg,
        msg,
    )


def test_utf8_view_refuses_a_short_view_buffer() raises:
    var msg = _decode_error(
        _view_frame(2, _one(1), view_buf_len=31), _utf8_view()
    )
    assert_equal(
        msg,
        "_decode_binary_or_utf8_view: view buffer too small (got 31, expected"
        " 32 = length × 16)",
    )


def test_utf8_view_refuses_a_negative_view_length() raises:
    var msg = _decode_error(_view_frame(-3, _one(1)), _utf8_view())
    assert_true(
        msg.startswith(
            "_decode_binary_or_utf8_view: field node #0 (UTF8_VIEW) view 1"
            " declares a NEGATIVE length of -3;"
        ),
        msg,
    )


def test_utf8_view_refuses_a_missing_variadic_buffer() raises:
    var msg = _decode_error(
        _view_frame(14, _one(1), buf_idx=1), _utf8_view()
    )
    assert_equal(
        msg, "_decode_binary_or_utf8_view: buffer_idx 1 out of range [0, 1)"
    )
    msg = _decode_error(_view_frame(14, _one(1), buf_idx=-1), _utf8_view())
    assert_equal(
        msg, "_decode_binary_or_utf8_view: buffer_idx -1 out of range [0, 1)"
    )


def test_utf8_view_refuses_a_negative_offset_and_a_range_past_the_end() raises:
    var msg = _decode_error(_view_frame(14, _one(1), in_off=-1), _utf8_view())
    assert_equal(
        msg,
        "_decode_binary_or_utf8_view: field node #0 (UTF8_VIEW) view 1"
        " declares a NEGATIVE variadic-buffer offset of -1",
    )
    # 3 + 14 = 17 > 16: one byte past the end; 2 + 14 = 16 fits (control).
    msg = _decode_error(_view_frame(14, _one(1), in_off=3), _utf8_view())
    assert_equal(
        msg,
        "_decode_binary_or_utf8_view: view extends past variadic buffer end",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
