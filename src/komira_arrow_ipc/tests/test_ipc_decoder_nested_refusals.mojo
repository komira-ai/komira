# =============================================================================
# test_ipc_decoder_nested_refusals.mojo: the nested decoders' refusals of an
# invalid ColumnTypeSpec, of DICTIONARY and of a short dense-union buffer,
# and the nested zero-copy decoder's NULL, BOOL and nullable var-len arms
# =============================================================================
#
# A ColumnTypeSpec built by hand (not through its checked constructors) can
# say FIXED_SIZE_BINARY or FIXED_SIZE_LIST of size 0, or a LIST, MAP or
# FIXED_SIZE_LIST without its one child. Each nested decoder refuses each
# of these with its own message, before reading a buffer. DICTIONARY is
# refused by both (its values are in a DictionaryBatch). A dense union whose
# type-id or offsets buffer is shorter than its length needs is refused.
# The zero-copy decoder decodes a NULL column (no buffers) and a STRING
# column with a null by borrowing, and refuses BOOL (bit-packed). The checked
# constructors refuse a list size of 0 and mismatched struct names.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_nested,
    decode_record_batch_message_nested_zerocopy,
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


comptime BODY = 64


def _frame(
    var nodes: List[FieldNode], var bufs: List[BufferDescriptor]
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A RecordBatch of 3 rows over `nodes` and `bufs`; body: Int64 5, 6, 7
    at 0, STRING offsets 0, 1, 1, 3 at 24 and data "abc" at 40, bitmap
    0b101 at 56."""
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(w, Int64(3), nodes, bufs)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(BODY)
    )
    var fb = w^.finalize(msg_pos)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(BODY)
    body.zero()
    body.write_i64_le_at(0, Int64(5))
    body.write_i64_le_at(8, Int64(6))
    body.write_i64_le_at(16, Int64(7))
    body.write_i32_le_at(28, Int32(1))
    body.write_i32_le_at(32, Int32(1))
    body.write_i32_le_at(36, Int32(3))
    body.write_u8_at(40, UInt8(ord("a")))
    body.write_u8_at(41, UInt8(ord("b")))
    body.write_u8_at(42, UInt8(ord("c")))
    body.write_u8_at(56, UInt8(0b101))
    body.set_length(BODY)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(
        w2, fb^, body.view_range_ro(0, BODY).into_span(), True
    )


def _node(length: Int, nulls: Int = 0) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(nulls))


def _buf(off: Int, length: Int) -> BufferDescriptor:
    return BufferDescriptor(offset=Int64(off), length=Int64(length))


def _plain_frame() raises -> SharedAlignedBuffer[HeapRegion]:
    """Two nodes of 3 rows and four buffers: enough for any arm below to
    get as far as its own refusal."""
    var nodes = List[FieldNode]()
    nodes.append(_node(3))
    nodes.append(_node(3))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    return _frame(nodes^, bufs^)


def _spec(
    t: ArrowType, inner_size: Int, n_children: Int
) raises -> ColumnTypeSpec:
    """A hand-built spec of `t` with `n_children` INT64 leaves."""
    var kids = Slab[ColumnTypeSpec]()
    var names = List[String]()
    for i in range(n_children):
        kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
        names.append(String("c") + String(i))
    return ColumnTypeSpec(
        arrow_type=t,
        children=kids^,
        field_names=names^,
        type_ids=List[Int](),
        inner_size=inner_size,
    )


def _copy_error(var spec: ColumnTypeSpec) -> String:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(spec^)
    try:
        _ = decode_record_batch_message_nested(_plain_frame(), specs^)
    except e:
        return String(e)
    return String("no error")


def _zc_error(
    var spec: ColumnTypeSpec, frame: SharedAlignedBuffer[HeapRegion]
) -> String:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(spec^)
    try:
        _ = decode_record_batch_message_nested_zerocopy(frame, specs^)
    except e:
        return String(e)
    return String("no error")


# ---------------------------------------------------------------------------
# Spec refusals, copy-on-read
# ---------------------------------------------------------------------------


def test_copy_on_read_refuses_size_zero_fixed_size_types() raises:
    assert_true(
        _copy_error(_spec(ArrowType.FIXED_SIZE_BINARY, 0, 0)).startswith(
            "_decode_column_nested FIXED_SIZE_BINARY: spec.inner_size must"
            " be > 0"
        )
    )
    assert_true(
        _copy_error(_spec(ArrowType.FIXED_SIZE_LIST, 0, 1)).startswith(
            "_decode_column_nested FIXED_SIZE_LIST: spec.inner_size"
            " (list_size) must be > 0"
        )
    )


def test_copy_on_read_refuses_a_missing_child() raises:
    assert_equal(
        _copy_error(_spec(ArrowType.FIXED_SIZE_LIST, 2, 0)),
        "_decode_column_nested FIXED_SIZE_LIST: expected 1 child",
    )
    assert_equal(
        _copy_error(_spec(ArrowType.LIST, 0, 0)),
        "_decode_column_nested LIST: spec.children count 0 != 1",
    )
    assert_equal(
        _copy_error(_spec(ArrowType.LIST, 0, 2)),
        "_decode_column_nested LIST: spec.children count 2 != 1",
    )
    assert_equal(
        _copy_error(_spec(ArrowType.MAP, 0, 0)),
        "_decode_column_nested MAP: expected 1 child",
    )


def test_copy_on_read_refuses_dictionary() raises:
    assert_equal(
        _copy_error(ColumnTypeSpec.leaf(ArrowType.DICTIONARY)),
        "_decode_column_nested: ArrowType 19 not supported (DICTIONARY needs"
        " the preceding DictionaryBatch)",
    )


def _dense_union_frame(
    type_ids_len: Int, offsets_len: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    var nodes = List[FieldNode]()
    nodes.append(_node(3))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, type_ids_len))
    bufs.append(_buf(8, offsets_len))
    return _frame(nodes^, bufs^)


def test_dense_union_refuses_short_type_ids_and_offsets() raises:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(_spec(ArrowType.UNION_DENSE, 0, 0))
    var msg = String("")
    try:
        _ = decode_record_batch_message_nested(_dense_union_frame(2, 12), specs^)
    except e:
        msg = String(e)
    assert_equal(msg, "_build_union_dense_column: type_ids buffer too small")
    specs = Slab[ColumnTypeSpec]()
    specs.append(_spec(ArrowType.UNION_DENSE, 0, 0))
    msg = String("")
    try:
        _ = decode_record_batch_message_nested(_dense_union_frame(3, 11), specs^)
    except e:
        msg = String(e)
    assert_equal(msg, "_build_union_dense_column: offsets buffer too small")
    # Exactly long enough: decodes (a union with no children).
    specs = Slab[ColumnTypeSpec]()
    specs.append(_spec(ArrowType.UNION_DENSE, 0, 0))
    var cols = decode_record_batch_message_nested(
        _dense_union_frame(3, 12), specs^
    )
    assert_equal(cols[0]._length, 3)


# ---------------------------------------------------------------------------
# Zero-copy
# ---------------------------------------------------------------------------


def test_zero_copy_refuses_invalid_specs() raises:
    var f = _plain_frame()
    assert_equal(
        _zc_error(_spec(ArrowType.FIXED_SIZE_BINARY, 0, 0), f),
        "_decode_column_nested_zerocopy FIXED_SIZE_BINARY: spec.inner_size"
        " must be > 0",
    )
    assert_equal(
        _zc_error(_spec(ArrowType.FIXED_SIZE_LIST, 0, 1), f),
        "_decode_column_nested_zerocopy FIXED_SIZE_LIST: spec.inner_size"
        " (list_size) must be > 0",
    )
    assert_equal(
        _zc_error(_spec(ArrowType.FIXED_SIZE_LIST, 2, 0), f),
        "_decode_column_nested_zerocopy FIXED_SIZE_LIST: expected 1 child",
    )
    assert_equal(
        _zc_error(_spec(ArrowType.LIST, 0, 0), f),
        "_decode_column_nested_zerocopy LIST: spec.children count != 1",
    )
    assert_equal(
        _zc_error(_spec(ArrowType.MAP, 0, 2), f),
        "_decode_column_nested_zerocopy MAP: expected 1 child",
    )
    assert_true(
        _zc_error(ColumnTypeSpec.leaf(ArrowType.DICTIONARY), f).startswith(
            "_decode_column_nested_zerocopy: ArrowType 19 not supported"
        )
    )
    assert_true(
        _zc_error(ColumnTypeSpec.leaf(ArrowType.BOOL), f).startswith(
            "_decode_column_nested_zerocopy: BOOL columns not zero-copy"
        )
    )


def test_zero_copy_null_column_then_int64() raises:
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 3))
    nodes.append(_node(3))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(0, 0))
    bufs.append(_buf(0, 24))
    var frame = _frame(nodes^, bufs^)
    var specs = Slab[ColumnTypeSpec]()
    specs.append(ColumnTypeSpec.leaf(ArrowType.NULL))
    specs.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    var cols = decode_record_batch_message_nested_zerocopy(frame, specs^)
    assert_equal(cols[0].arrow_type, ArrowType.NULL)
    assert_equal(cols[0]._length, 3)
    assert_equal(cols[0]._null_count, 3)
    assert_equal(cols[1]._data.read_i64_le_at(16), Int64(7))


def test_zero_copy_string_with_a_null() raises:
    var nodes = List[FieldNode]()
    nodes.append(_node(3, 1))
    var bufs = List[BufferDescriptor]()
    bufs.append(_buf(56, 1))
    bufs.append(_buf(24, 16))
    bufs.append(_buf(40, 3))
    var frame = _frame(nodes^, bufs^)
    var specs = Slab[ColumnTypeSpec]()
    specs.append(ColumnTypeSpec.leaf(ArrowType.STRING))
    var cols = decode_record_batch_message_nested_zerocopy(frame, specs^)
    ref c = cols[0]
    assert_equal(c._null_count, 1)
    assert_false(c.is_null_at(0))
    assert_true(c.is_null_at(1))
    var s = c.as_string()
    assert_equal(s.get(0), String("a"))
    assert_equal(s.get(2), String("bc"))


# ---------------------------------------------------------------------------
# Checked constructors
# ---------------------------------------------------------------------------


def test_checked_constructors_refuse_bad_shapes() raises:
    var msg = String("")
    try:
        _ = ColumnTypeSpec.fixed_size_list_of(
            ColumnTypeSpec.leaf(ArrowType.INT64), 0
        )
    except e:
        msg = String(e)
    assert_equal(
        msg, "ColumnTypeSpec.fixed_size_list_of: list_size must be > 0; got 0"
    )
    var kids = Slab[ColumnTypeSpec]()
    kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    msg = String("")
    try:
        _ = ColumnTypeSpec.struct_of(kids^, names^)
    except e:
        msg = String(e)
    assert_equal(
        msg, "ColumnTypeSpec.struct_of: children count 1 != field_names count 2"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
