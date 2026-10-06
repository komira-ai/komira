# =============================================================================
# test_ipc_field_node_check.mojo: the FieldNode / buffer-size helpers, and
# the Arrow-IPC morsel fill that sizes its reads with them.
# =============================================================================
#
# The helpers' arithmetic is pinned at its edges (a product one past
# Int.MAX, `count + 1` at Int.MAX, a bitmap of Int.MAX bits), including arms
# the decoders cannot reach because they validate the node first (a negative
# count reaching a size helper). The decoder-level tests are
# test_ipc_field_node_flat and test_ipc_field_node_nested.
#
# `IpcMorselFill` reads column values and validity straight out of the frame
# for `n_rows` = the RecordBatch length, so before these checks a node that
# disagreed with that length, a wrapping `rows * width`, a short bitmap, or a
# node declaring nulls without a bitmap (read as all-valid, dropping the
# nulls) all filled successfully.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow_ipc.ipc_field_node_check import (
    check_buffer_size,
    check_field_node,
    check_node_index,
    check_record_batch_length,
    check_top_level_node,
    checked_bitmap_bytes,
    checked_offsets_bytes,
    checked_size_mul,
    validity_present,
    varlen_offsets_bytes,
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
from komira_arrow_ipc.ipc_morsel_fill import IpcMorselFill


comptime CTX = "ctx"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def test_checked_size_mul_edges() raises:
    assert_equal(checked_size_mul(CTX, 0, "values buffer", 0, 8), 0)
    assert_equal(checked_size_mul(CTX, 0, "values buffer", 3, 8), 24)
    var top = Int.MAX // 8
    assert_equal(checked_size_mul(CTX, 0, "values buffer", top, 8), top * 8)
    var got = String("")
    try:
        _ = checked_size_mul(CTX, 2, "values buffer", top + 1, 8)
    except e:
        got = String(e)
    assert_equal(
        got,
        "ctx: field node #2 values buffer size overflows ("
        + String(top + 1) + " x 8)",
    )
    got = String("")
    try:
        _ = checked_size_mul(CTX, 2, "values buffer", -1, 8)
    except e:
        got = String(e)
    assert_equal(
        got, "ctx: field node #2 values buffer size from a negative count -1"
    )


def test_checked_bitmap_bytes_edges() raises:
    assert_equal(checked_bitmap_bytes(CTX, 0, "bitmap buffer", 0), 0)
    assert_equal(checked_bitmap_bytes(CTX, 0, "bitmap buffer", 1), 1)
    assert_equal(checked_bitmap_bytes(CTX, 0, "bitmap buffer", 8), 1)
    assert_equal(checked_bitmap_bytes(CTX, 0, "bitmap buffer", 9), 2)
    # (Int.MAX + 7) // 8 would wrap; ceil(Int.MAX / 8) does not.
    assert_equal(
        checked_bitmap_bytes(CTX, 0, "bitmap buffer", Int.MAX),
        Int.MAX // 8 + 1,
    )
    var got = String("")
    try:
        _ = checked_bitmap_bytes(CTX, 1, "bitmap buffer", -8)
    except e:
        got = String(e)
    assert_equal(
        got, "ctx: field node #1 bitmap buffer size from a negative count -8"
    )


def test_checked_offsets_bytes_edges() raises:
    assert_equal(checked_offsets_bytes(CTX, 0, "offsets buffer", 0, 4), 4)
    assert_equal(checked_offsets_bytes(CTX, 0, "offsets buffer", 3, 4), 16)
    var got = String("")
    try:
        _ = checked_offsets_bytes(CTX, 0, "offsets buffer", Int.MAX, 1)
    except e:
        got = String(e)
    assert_equal(
        got,
        "ctx: field node #0 offsets buffer size overflows ("
        + String(Int.MAX) + " + 1 entries)",
    )
    got = String("")
    try:
        _ = checked_offsets_bytes(CTX, 0, "offsets buffer", Int.MAX // 4, 4)
    except e:
        got = String(e)
    assert_equal(
        got,
        "ctx: field node #0 offsets buffer size overflows ("
        + String(Int.MAX // 4 + 1) + " x 4)",
    )
    # A count of -1 must not become (-1 + 1) * 4 == 0.
    got = String("")
    try:
        _ = checked_offsets_bytes(CTX, 0, "offsets buffer", -1, 4)
    except e:
        got = String(e)
    assert_equal(
        got, "ctx: field node #0 offsets buffer size from a negative count -1"
    )


def test_varlen_offsets_bytes() raises:
    """Zero rows may carry an empty offsets buffer; otherwise (n + 1) x w."""
    assert_equal(varlen_offsets_bytes(CTX, 0, 0, 4), 0)
    assert_equal(varlen_offsets_bytes(CTX, 0, 1, 4), 8)
    assert_equal(varlen_offsets_bytes(CTX, 0, 3, 8), 32)


def test_check_buffer_size_boundary() raises:
    check_buffer_size(CTX, 0, "values", 24, 24, 3)
    var got = String("")
    try:
        check_buffer_size(CTX, 4, "values", 23, 24, 3)
    except e:
        got = String(e)
    assert_equal(
        got,
        "ctx: values buffer too small (have 23, expected 24) for field node"
        " #4 (3 rows)",
    )


def test_validity_present_arms() raises:
    assert_false(validity_present(CTX, 0, 0, 3, 0))
    assert_true(validity_present(CTX, 0, 1, 8, 1))
    var got = String("")
    try:
        _ = validity_present(CTX, 0, 0, 3, 2)
    except e:
        got = String(e)
    assert_equal(
        got, "ctx: field node #0 declares 2 nulls but has no validity bitmap"
    )
    got = String("")
    try:
        _ = validity_present(CTX, 0, 1, 9, 0)
    except e:
        got = String(e)
    assert_equal(
        got,
        "ctx: bitmap buffer too small (have 1, expected 2) for field node #0"
        " (9 rows)",
    )


def test_node_checks_accept_boundaries() raises:
    """null_count == length and length == 0 are valid; index n - 1 exists."""
    check_field_node(CTX, 0, 0, 0)
    check_field_node(CTX, 0, 5, 5)
    check_top_level_node(CTX, 0, 0, 5, 0, 5)
    check_record_batch_length(CTX, 0)
    check_node_index(CTX, 2, 3)
    var got = String("")
    try:
        check_node_index(CTX, -1, 3)
    except e:
        got = String(e)
    assert_equal(
        got,
        "ctx: field node #-1 is missing (the RecordBatch has 3 field"
        " nodes)",
    )


# ---------------------------------------------------------------------------
# IpcMorselFill
# ---------------------------------------------------------------------------


comptime BODY = 256
comptime VALIDITY_AT = 248
comptime FILL = "IpcMorselFill.fill_from_frame"
comptime WRAP_INT64 = 2305843009213693952  # 2^61


def _frame(
    rb_len: Int,
    length: Int,
    nulls: Int,
    v_off: Int,
    v_len: Int,
    values_len: Int,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """One INT64 column: validity at (v_off, v_len), values at (0,
    values_len). Body: Int64 5, 6, 7 then zeros; bitmap 0b101 at 248."""
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(length), null_count=Int64(nulls)))
    var bufs = List[BufferDescriptor]()
    bufs.append(BufferDescriptor(offset=Int64(v_off), length=Int64(v_len)))
    bufs.append(BufferDescriptor(offset=0, length=Int64(values_len)))
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(w, Int64(rb_len), nodes, bufs)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(BODY)
    )
    var fb = w^.finalize(msg_pos)
    var body = List[UInt8](capacity=BODY)
    for i in range(BODY):
        var b = 0
        if i < 24 and i % 8 == 0:
            b = 5 + i // 8
        elif i == VALIDITY_AT:
            b = 5
        body.append(UInt8(b))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    return t^


def _fill_err(
    rb_len: Int,
    length: Int,
    nulls: Int,
    v_off: Int,
    v_len: Int,
    values_len: Int,
) raises -> String:
    var fill = IpcMorselFill()
    try:
        _ = fill.fill_from_frame(
            _frame(rb_len, length, nulls, v_off, v_len, values_len), _types()
        )
    except e:
        return String(e)
    return String("")


def test_fill_refuses_bad_nodes() raises:
    var at = String(FILL) + ": field node #0"
    assert_equal(_fill_err(3, -1, 0, 0, 0, 24), at + " has negative length -1")
    assert_equal(
        _fill_err(3, 3, -1, 0, 0, 24), at + " has negative null_count -1"
    )
    assert_equal(
        _fill_err(3, 3, 4, 0, 0, 24), at + " null_count 4 exceeds its length 3"
    )
    assert_equal(
        _fill_err(4, 3, 0, 0, 0, 32),
        String(FILL) + ": column 0 (field node #0) has length 3 but the"
        + " RecordBatch length is 4",
    )
    assert_equal(
        _fill_err(-1, 3, 0, 0, 0, 24),
        String(FILL) + ": RecordBatch length -1 is negative",
    )


def test_fill_refuses_wrapping_length() raises:
    """2^61 INT64 rows need 2^64 bytes, 0 in Int: the old values-run check
    passed and the fill served 2^61 rows over a 24-byte run."""
    assert_equal(
        _fill_err(WRAP_INT64, WRAP_INT64, 0, 0, 0, 24),
        String(FILL) + ": field node #0 values buffer size overflows ("
        + String(WRAP_INT64) + " x 8)",
    )


def test_fill_refuses_bad_validity_and_short_values() raises:
    assert_equal(
        _fill_err(20, 20, 1, VALIDITY_AT, 2, 160),
        String(FILL) + ": bitmap buffer too small (have 2, expected 3) for"
        + " field node #0 (20 rows)",
    )
    assert_equal(
        _fill_err(3, 3, 1, 0, 0, 24),
        String(FILL)
        + ": field node #0 declares 1 nulls but has no validity bitmap",
    )
    assert_equal(
        _fill_err(4, 4, 0, 0, 0, 24),
        String(FILL) + ": values buffer too small (have 24, expected 32) for"
        + " field node #0 (4 rows)",
    )


def test_fill_controls() raises:
    var fill = IpcMorselFill()
    assert_true(fill.fill_from_frame(_frame(3, 3, 0, 0, 0, 24), _types()))
    assert_equal(fill.num_rows(), 3)
    assert_false(fill.col_has_validity(0))
    assert_true(
        fill.fill_from_frame(_frame(3, 3, 1, VALIDITY_AT, 1, 24), _types())
    )
    assert_true(fill.col_has_validity(0))
    # null_count == 0 with a bitmap present: served as all-valid.
    assert_true(
        fill.fill_from_frame(_frame(3, 3, 0, VALIDITY_AT, 1, 24), _types())
    )
    assert_false(fill.col_has_validity(0))
    assert_true(fill.fill_from_frame(_frame(0, 0, 0, 0, 0, 0), _types()))
    assert_equal(fill.num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
