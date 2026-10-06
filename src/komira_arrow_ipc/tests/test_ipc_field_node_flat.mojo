# =============================================================================
# test_ipc_field_node_flat.mojo: FieldNode lengths, null counts and the
# buffer sizes they imply, on the flat RecordBatch decoders.
# =============================================================================
#
# Every decoder sizes a column's buffers from its FieldNode: `length * width`
# values bytes, `ceil(length / 8)` bitmap bytes, `(length + 1) * width`
# offsets bytes. Before these checks a node was trusted as written:
#
#   * INT64 with length 2^61 needs 2^64 values bytes, which is 0 in Int, so
#     "values buffer too small" passed and the decoder returned a column
#     claiming 2^61 rows over a 24-byte buffer;
#   * a negative length, a negative null_count, or null_count > length gave
#     a column with that count;
#   * a node declaring nulls with no validity buffer gave a column whose
#     nulls cannot be located (or, on the zero-copy paths, a bitmap view
#     over 0 bytes);
#   * the zero-copy decoder checked no size at all.
#
# Each case runs on the four flat decoders (copy-on-read, dictionary-aware
# copy-on-read, zero-copy, mmap) and asserts the exact refusal: a decoder
# without the check returns columns (the "" result) or raises a different,
# later message. Every malformed frame is otherwise valid (node and buffer
# counts match, every Buffer lies inside the body), so the node is the only
# thing wrong. Controls: a valid batch, a nullable valid batch, zero rows,
# and a zero-row STRING column with an empty offsets buffer.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message,
    decode_record_batch_message_mmap,
    decode_record_batch_message_with_dicts,
    decode_record_batch_zerocopy,
    expand_dict_indices_to_string,
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


# Body layout: Int64 5, 6, 7 at 0..24; STRING offsets [0,1,2,3] at 64..80
# and data "abc" at 96..99; a BOOL value bitmap 0b101 at 120; a validity
# bitmap 0b101 (rows 0 and 2 valid) at 248.
comptime BODY = 256
comptime VALIDITY_AT = 248
comptime TRAILING = 4096
comptime WRAP_INT64 = 2305843009213693952  # 2^61: 2^61 * 8 == 2^64
comptime WRAP_INT32 = 4611686018427387904  # 2^62: 2^62 * 4 == 2^64

comptime COPY = 0
comptime DICTS = 1
comptime ZC = 2
comptime MMAP = 3


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------


def _scratch(name: String) -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_ipc_field_node_flat_" + name


def _node(length: Int, nulls: Int) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(nulls))


def _nodes(n: FieldNode) -> List[FieldNode]:
    var out = List[FieldNode]()
    out.append(n.copy())
    return out^


def _bufs(o0: Int, l0: Int, o1: Int, l1: Int) -> List[BufferDescriptor]:
    var out = List[BufferDescriptor]()
    out.append(BufferDescriptor(offset=Int64(o0), length=Int64(l0)))
    out.append(BufferDescriptor(offset=Int64(o1), length=Int64(l1)))
    return out^


def _bufs3(
    o0: Int, l0: Int, o1: Int, l1: Int, o2: Int, l2: Int
) -> List[BufferDescriptor]:
    var out = _bufs(o0, l0, o1, l1)
    out.append(BufferDescriptor(offset=Int64(o2), length=Int64(l2)))
    return out^


def _frame(
    rb_len: Int, nodes: List[FieldNode], buffers: List[BufferDescriptor]
) raises -> SharedAlignedBuffer[HeapRegion]:
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(w, Int64(rb_len), nodes, buffers)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(BODY)
    )
    var fb = w^.finalize(msg_pos)
    var body = List[UInt8](capacity=BODY)
    for i in range(BODY):
        var b = 0
        if i < 24 and i % 8 == 0:
            b = 5 + i // 8
        elif i >= 64 and i < 80 and i % 4 == 0:
            b = (i - 64) // 4
        elif i >= 96 and i < 99:
            b = 97 + i - 96
        elif i == 120 or i == VALIDITY_AT:
            b = 5
        body.append(UInt8(b))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _map(
    frame: SharedAlignedBuffer[HeapRegion], name: String
) raises -> ArcPointer[MmapRegion]:
    var bytes = List[UInt8](capacity=frame.len() + TRAILING)
    for i in range(frame.len()):
        bytes.append(frame.read_u8_at(i))
    for _ in range(TRAILING):
        bytes.append(UInt8(0))
    var path = _scratch(name)
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^
    return ArcPointer[MmapRegion](MmapRegion.open_readonly(path))


def _types(t: ArrowType) -> List[ArrowType]:
    var out = List[ArrowType]()
    out.append(t)
    return out^


def _placeholders() -> Slab[Column[HeapRegion]]:
    var s = Slab[Column[HeapRegion]]()
    s.append(Column[HeapRegion]())
    return s^


def _err(
    path: Int,
    t: ArrowType,
    rb_len: Int,
    node: FieldNode,
    buffers: List[BufferDescriptor],
    name: String,
) raises -> String:
    """Decode one column through `path`; the refusal text, or "" when the
    decoder returned columns."""
    var nodes = _nodes(node)
    try:
        if path == COPY:
            _ = decode_record_batch_message(
                _frame(rb_len, nodes, buffers), _types(t)
            )
        elif path == DICTS:
            var no_dict: List[Bool] = [False]
            _ = decode_record_batch_message_with_dicts(
                _frame(rb_len, nodes, buffers), _types(t), no_dict,
                _placeholders(),
            )
        elif path == ZC:
            var frame = _frame(rb_len, nodes, buffers)
            _ = decode_record_batch_zerocopy(frame, _types(t))
            _ = frame.len()
        else:
            var frame = _frame(rb_len, nodes, buffers)
            var region = _map(frame, name + "_" + String(path) + ".bin")
            _ = decode_record_batch_message_mmap(
                frame^, _types(t), region, 0
            )
    except e:
        return String(e)
    return String("")


# ---------------------------------------------------------------------------
# Expected refusal texts
# ---------------------------------------------------------------------------


def _driver(path: Int) -> String:
    if path == COPY:
        return "decode_record_batch_message"
    if path == DICTS:
        return "decode_record_batch_message_with_dicts"
    if path == ZC:
        return "decode_record_batch_zerocopy"
    return "decode_record_batch_message_mmap"


def _values_ctx(path: Int) -> String:
    if path == ZC:
        return _driver(path)
    if path == MMAP:
        return "_build_fixed_width_column_mmap"
    return "_build_fixed_width_column"


def _validity_ctx(path: Int) -> String:
    if path == ZC:
        return _driver(path)
    if path == MMAP:
        return "_maybe_build_validity_bitmap_mmap"
    return "_maybe_decode_validity_bitmap"


def _varlen_ctx(path: Int) -> String:
    if path == ZC:
        return _driver(path)
    if path == MMAP:
        return "_build_varlen_column_mmap"
    return "_build_varlen_column"


def _at(ctx: String, i: Int) -> String:
    return ctx + ": field node #" + String(i)


def _too_small(
    ctx: String, buffer: String, have: Int, need: Int, rows: Int
) -> String:
    return (
        ctx + ": " + buffer + " buffer too small (have " + String(have)
        + ", expected " + String(need) + ") for field node #0 ("
        + String(rows) + " rows)"
    )


def _overflow(ctx: String, what: String, count: Int, width: Int) -> String:
    return (
        _at(ctx, 0) + " " + what + " size overflows (" + String(count)
        + " x " + String(width) + ")"
    )


# ---------------------------------------------------------------------------
# The cases, per path
# ---------------------------------------------------------------------------


def _check_bad_nodes(path: Int) raises:
    var d = _driver(path)
    var ok = _bufs(0, 0, 0, 24)
    assert_equal(
        _err(path, ArrowType.INT64, 3, _node(-1, 0), ok, "neg_len"),
        _at(d, 0) + " has negative length -1",
    )
    assert_equal(
        _err(path, ArrowType.INT64, 3, _node(3, -1), ok, "neg_nulls"),
        _at(d, 0) + " has negative null_count -1",
    )
    assert_equal(
        _err(path, ArrowType.INT64, 3, _node(3, 4), ok, "nulls_gt"),
        _at(d, 0) + " null_count 4 exceeds its length 3",
    )
    assert_equal(
        _err(path, ArrowType.INT64, 4, _node(3, 0), ok, "mismatch"),
        d + ": column 0 (field node #0) has length 3 but the RecordBatch"
        + " length is 4",
    )
    assert_equal(
        _err(path, ArrowType.INT64, -1, _node(3, 0), ok, "rb_neg"),
        d + ": RecordBatch length -1 is negative",
    )


def _check_wrapping_length(path: Int) raises:
    """INT64 with length 2^61: 2^61 * 8 wraps to 0 in Int."""
    assert_equal(
        _err(
            path, ArrowType.INT64, WRAP_INT64, _node(WRAP_INT64, 0),
            _bufs(0, 0, 0, 24), "wrap",
        ),
        _overflow(_values_ctx(path), "values buffer", WRAP_INT64, 8),
    )


def _check_validity(path: Int) raises:
    # 20 rows need 3 bitmap bytes; the buffer holds 2.
    assert_equal(
        _err(
            path, ArrowType.INT64, 20, _node(20, 1),
            _bufs(VALIDITY_AT, 2, 0, 160), "short_validity",
        ),
        _too_small(_validity_ctx(path), "bitmap", 2, 3, 20),
    )
    # A node with nulls and no validity buffer.
    assert_equal(
        _err(
            path, ArrowType.INT64, 3, _node(3, 1), _bufs(0, 0, 0, 24),
            "no_validity",
        ),
        _at(_validity_ctx(path), 0)
        + " declares 1 nulls but has no validity bitmap",
    )


def _check_short_values(path: Int) raises:
    assert_equal(
        _err(
            path, ArrowType.INT64, 4, _node(4, 0), _bufs(0, 0, 0, 24),
            "short_values",
        ),
        _too_small(_values_ctx(path), "values", 24, 32, 4),
    )


def _check_string(path: Int) raises:
    """Offsets for 3 rows need 16 bytes; a huge length wraps the size."""
    assert_equal(
        _err(
            path, ArrowType.STRING, 3, _node(3, 0),
            _bufs3(0, 0, 64, 12, 96, 3), "short_offsets",
        ),
        _too_small(_varlen_ctx(path), "offsets", 12, 16, 3),
    )
    assert_equal(
        _err(
            path, ArrowType.LARGE_STRING, WRAP_INT64, _node(WRAP_INT64, 0),
            _bufs3(0, 0, 64, 16, 96, 3), "wrap_offsets",
        ),
        _overflow(_varlen_ctx(path), "offsets buffer", WRAP_INT64 + 1, 8),
    )
    # Zero rows: an empty offsets buffer is accepted (Arrow C++ writes one).
    assert_equal(
        _err(
            path, ArrowType.STRING, 0, _node(0, 0),
            _bufs3(0, 0, 0, 0, 0, 0), "empty_string",
        ),
        String(""),
    )
    assert_equal(
        _err(
            path, ArrowType.STRING, 3, _node(3, 0),
            _bufs3(0, 0, 64, 16, 96, 3), "ok_string",
        ),
        String(""),
    )


def _check_bool(path: Int) raises:
    """20 BOOL values need 3 bitmap bytes (copy-on-read and mmap only; the
    zero-copy decoders refuse BOOL outright)."""
    var ctx = String("_build_bool_column_mmap") if path == MMAP else String(
        "_build_bool_column"
    )
    assert_equal(
        _err(
            path, ArrowType.BOOL, 20, _node(20, 0), _bufs(0, 0, 120, 2),
            "short_bool",
        ),
        _too_small(ctx, "value bitmap", 2, 3, 20),
    )
    assert_equal(
        _err(
            path, ArrowType.BOOL, 3, _node(3, 1),
            _bufs(VALIDITY_AT, 1, 120, 1), "ok_bool",
        ),
        String(""),
    )


def _check_controls(path: Int) raises:
    assert_equal(
        _err(path, ArrowType.INT64, 3, _node(3, 0), _bufs(0, 0, 0, 24), "ok"),
        String(""),
    )
    assert_equal(
        _err(
            path, ArrowType.INT64, 3, _node(3, 1),
            _bufs(VALIDITY_AT, 1, 0, 24), "ok_nullable",
        ),
        String(""),
    )
    assert_equal(
        _err(path, ArrowType.INT64, 0, _node(0, 0), _bufs(0, 0, 0, 0), "zero"),
        String(""),
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_copy_refuses_bad_nodes() raises:
    _check_bad_nodes(COPY)


def test_copy_refuses_wrapping_length() raises:
    _check_wrapping_length(COPY)


def test_copy_refuses_bad_validity() raises:
    _check_validity(COPY)


def test_copy_refuses_short_values() raises:
    _check_short_values(COPY)
    _check_string(COPY)
    _check_bool(COPY)


def test_copy_controls() raises:
    _check_controls(COPY)
    var cols = decode_record_batch_message(
        _frame(3, _nodes(_node(3, 1)), _bufs(VALIDITY_AT, 1, 0, 24)),
        _types(ArrowType.INT64),
    )
    assert_equal(cols[0]._length, 3)
    assert_equal(cols[0]._null_count, 1)
    assert_true(cols[0]._validity.value().test(0))
    assert_false(cols[0]._validity.value().test(1))
    assert_equal(cols[0]._data.read_i64_le_at(16), Int64(7))


def test_dicts_refuses_bad_nodes() raises:
    _check_bad_nodes(DICTS)


def test_dicts_refuses_wrapping_length() raises:
    _check_wrapping_length(DICTS)


def test_dicts_refuses_bad_validity() raises:
    _check_validity(DICTS)


def test_dicts_refuses_short_values() raises:
    _check_short_values(DICTS)
    _check_string(DICTS)
    _check_bool(DICTS)


def test_dicts_controls() raises:
    _check_controls(DICTS)


def test_zerocopy_refuses_bad_nodes() raises:
    _check_bad_nodes(ZC)


def test_zerocopy_refuses_wrapping_length() raises:
    _check_wrapping_length(ZC)


def test_zerocopy_refuses_bad_validity() raises:
    _check_validity(ZC)


def test_zerocopy_refuses_short_values() raises:
    _check_short_values(ZC)
    _check_string(ZC)


def test_zerocopy_controls() raises:
    _check_controls(ZC)
    var frame = _frame(3, _nodes(_node(3, 0)), _bufs(0, 0, 0, 24))
    var cols = decode_record_batch_zerocopy(frame, _types(ArrowType.INT64))
    assert_equal(cols[0]._length, 3)
    assert_equal(cols[0]._data.read_i64_le_at(8), Int64(6))
    _ = frame.len()


def test_mmap_refuses_bad_nodes() raises:
    _check_bad_nodes(MMAP)


def test_mmap_refuses_wrapping_length() raises:
    _check_wrapping_length(MMAP)


def test_mmap_refuses_bad_validity() raises:
    _check_validity(MMAP)


def test_mmap_refuses_short_values() raises:
    _check_short_values(MMAP)
    _check_string(MMAP)
    _check_bool(MMAP)


def test_mmap_controls() raises:
    _check_controls(MMAP)


# ---------------------------------------------------------------------------
# The dictionary arm of the dictionary-aware decoder
# ---------------------------------------------------------------------------


def _empty_string_dictionary() -> Column[HeapRegion]:
    """A STRING dictionary with no values (offsets [0]): every index is out
    of range, so a decoder that reaches the index walk refuses at row 0."""
    var offsets = OwnedAlignedBuffer(4)
    offsets.write_u32_le_at(0, UInt32(0))
    return Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=OwnedAlignedBuffer(0),
        offsets=offsets^,
        validity=None,
        length=0,
        null_count=0,
        offset=0,
    )


def _dict_err(
    rb_len: Int, node: FieldNode, buffers: List[BufferDescriptor]
) raises -> String:
    var is_dict: List[Bool] = [True]
    var dicts = Slab[Column[HeapRegion]]()
    dicts.append(_empty_string_dictionary())
    try:
        _ = decode_record_batch_message_with_dicts(
            _frame(rb_len, _nodes(node), buffers), _types(ArrowType.STRING),
            is_dict, dicts^,
        )
    except e:
        return String(e)
    return String("")


def test_dict_arm_refuses_bad_nodes_and_sizes() raises:
    """The dictionary column's node passes the same gate, its validity the
    same check, and its index count is compared without forming
    `n_rows * width` (2^62 Int32 indices need 2^64 bytes, 0 in Int)."""
    var d = String("decode_record_batch_message_with_dicts")
    assert_equal(
        _dict_err(3, _node(-1, 0), _bufs(0, 0, 0, 12)),
        _at(d, 0) + " has negative length -1",
    )
    assert_equal(
        _dict_err(3, _node(3, 1), _bufs(0, 0, 0, 12)),
        _at("_maybe_decode_validity_bitmap", 0)
        + " declares 1 nulls but has no validity bitmap",
    )
    assert_equal(
        _dict_err(WRAP_INT32, _node(WRAP_INT32, 0), _bufs(0, 0, 0, 12)),
        "expand_dict_indices_to_string: indices_buf length 12 <"
        + " n_rows*idx_byte_width (" + String(WRAP_INT32) + " x 4)",
    )
    # Control: 3 in-range-sized indices reach the index walk, which refuses
    # index 5 against the empty dictionary (the walk, not the size check).
    assert_equal(
        _dict_err(3, _node(3, 0), _bufs(0, 0, 0, 12)),
        "expand_dict_indices_to_string: index 5 at row 0 out of range [0, 0)",
    )


def test_expand_refuses_negative_row_count() raises:
    """`expand_dict_indices_to_string` is public; a negative count is
    refused rather than producing a negative-length column."""
    var got = String("")
    try:
        _ = expand_dict_indices_to_string(
            OwnedAlignedBuffer(4), -1, None, _empty_string_dictionary()
        )
    except e:
        got = String(e)
    assert_equal(got, "expand_dict_indices_to_string: n_rows -1 is negative")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
