# =============================================================================
# test_ipc_nested_buffer_count.mojo: Buffer-descriptor counts, FieldNode
# counts and STRUCT child lengths on the nested RecordBatch decoders.
# =============================================================================
#
# The nested decoders (copy-on-read and zero-copy) read
# `buffers[buffer_idx + k]` for each node of the schema walk. A message with
# fewer Buffer descriptors than the walk reads made them index past the list,
# which aborts the process on the List bounds check; a STRUCT child whose
# length differed from the STRUCT's was accepted.
#
# Each case asserts the exact refusal on both decoders. Without the buffer
# check the too-few-buffers cases abort the test process; without the STRUCT
# check the length cases return columns (the "" result). The field-node cases
# pin the existing per-node refusal for a STRUCT and a LIST. The
# FIXED_SIZE_BINARY, FIXED_SIZE_LIST and LIST_VIEW cases pin the byte width,
# list size and child count the call sites pass to the count; FIXED_SIZE_BINARY
# runs at byte widths 4 and 1. The two-BINARY_VIEW case pins the view column
# index the copy-on-read call site passes. Controls: well-formed STRUCT, LIST,
# FIXED_SIZE_BINARY and FIXED_SIZE_LIST batches decode on both paths, and
# LIST_VIEW and two-BINARY_VIEW batches on the copy-on-read path.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow.column import Column
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
    _write_buffer_vector,
    _write_field_node_vector,
    _write_i64_vector,
    add_field_i64,
    add_field_offset,
    end_table,
    start_table,
    write_ipc_message,
    write_message,
)


# Body layout: Int64 5, 6, 7 at 0..24; Int32 [0, 1, 2, 3] at 64..80.
comptime BODY = 128

comptime NESTED = 0
comptime NZC = 1

# Schema shapes.
comptime K_STRUCT1 = 0  # struct<a: int64>
comptime K_STRUCT2 = 1  # struct<a: int64, b: int64>
comptime K_LIST = 2  # list<int64>
comptime K_BVIEW = 3  # binary_view
comptime K_I64_STRUCT1 = 4  # int64, struct<a: int64>
comptime K_FSB4 = 5  # fixed_size_binary(4)
comptime K_FSL1 = 6  # fixed_size_list<int64>(1)
comptime K_LVIEW = 7  # list_view<int64>
comptime K_BVIEW2 = 8  # binary_view, binary_view
comptime K_FSB1 = 9  # fixed_size_binary(1)


def _node(length: Int, nulls: Int = 0) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(nulls))


def _b(offset: Int, length: Int) -> BufferDescriptor:
    return BufferDescriptor(offset=Int64(offset), length=Int64(length))


def _frame(
    rb_len: Int,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    variadic: List[Int64],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A RecordBatch frame; `variadic` non-empty adds variadicBufferCounts
    (field 4)."""
    var w = FlatbufWriter(2048)
    var nodes_pos = _write_field_node_vector(w, nodes)
    var buffers_pos = _write_buffer_vector(w, buffers)
    var variadic_pos = -1
    if len(variadic) > 0:
        variadic_pos = _write_i64_vector(w, variadic)
    var tb = start_table()
    add_field_i64(tb, 0, Int64(rb_len))
    add_field_offset(tb, 1, nodes_pos)
    add_field_offset(tb, 2, buffers_pos)
    if variadic_pos >= 0:
        add_field_offset(tb, 4, variadic_pos)
    var rb_pos = end_table(w, tb^)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(BODY)
    )
    var fb = w^.finalize(msg_pos)
    var body = List[UInt8](capacity=BODY)
    for i in range(BODY):
        var v = 0
        if i < 24 and i % 8 == 0:
            v = 5 + i // 8
        elif i >= 64 and i < 80 and i % 4 == 0:
            v = (i - 64) // 4
        body.append(UInt8(v))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _specs(kind: Int) raises -> Slab[ColumnTypeSpec]:
    var s = Slab[ColumnTypeSpec]()
    if kind == K_I64_STRUCT1:
        s.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    if kind == K_STRUCT1 or kind == K_STRUCT2 or kind == K_I64_STRUCT1:
        var kids = Slab[ColumnTypeSpec]()
        var names = List[String]()
        kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
        names.append(String("a"))
        if kind == K_STRUCT2:
            kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
            names.append(String("b"))
        s.append(ColumnTypeSpec.struct_of(kids^, names^))
    elif kind == K_LIST:
        s.append(ColumnTypeSpec.list_of(ColumnTypeSpec.leaf(ArrowType.INT64)))
    elif kind == K_FSB4:
        s.append(ColumnTypeSpec.fixed_size_binary(4))
    elif kind == K_FSB1:
        s.append(ColumnTypeSpec.fixed_size_binary(1))
    elif kind == K_FSL1:
        s.append(
            ColumnTypeSpec.fixed_size_list_of(
                ColumnTypeSpec.leaf(ArrowType.INT64), 1
            )
        )
    elif kind == K_LVIEW:
        var kids = Slab[ColumnTypeSpec]()
        kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
        s.append(
            ColumnTypeSpec(
                arrow_type=ArrowType.LIST_VIEW,
                children=kids^,
                field_names=List[String](),
                type_ids=List[Int](),
                inner_size=0,
            )
        )
    elif kind == K_BVIEW2:
        s.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
        s.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
    else:
        s.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
    return s^


def _err(
    path: Int,
    kind: Int,
    rb_len: Int,
    nodes: List[FieldNode],
    buffers: List[BufferDescriptor],
    variadic: List[Int64] = List[Int64](),
) raises -> String:
    """Decode through `path`; the refusal text, or "" on success."""
    try:
        if path == NESTED:
            _ = decode_record_batch_message_nested(
                _frame(rb_len, nodes, buffers, variadic), _specs(kind)
            )
        else:
            var frame = _frame(rb_len, nodes, buffers, variadic)
            _ = decode_record_batch_message_nested_zerocopy(
                frame, _specs(kind)
            )
            _ = frame.len()
    except e:
        return String(e)
    return String("")


def _nodes(*lengths: Int) -> List[FieldNode]:
    var out = List[FieldNode]()
    for i in range(len(lengths)):
        out.append(_node(lengths[i]))
    return out^


def _struct1_buffers() -> List[BufferDescriptor]:
    """STRUCT validity, child validity, child values (Int64 5, 6, 7)."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(0, 0))
    out.append(_b(0, 24))
    return out^


def _struct2_buffers() -> List[BufferDescriptor]:
    var out = _struct1_buffers()
    out.append(_b(0, 0))
    out.append(_b(0, 24))
    return out^


def _i64_struct1_buffers() -> List[BufferDescriptor]:
    """INT64 validity and values, then the K_STRUCT1 buffers."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(0, 24))
    out.extend(_struct1_buffers())
    return out^


def _list_buffers() -> List[BufferDescriptor]:
    """LIST validity, offsets [0, 1], child validity, child values (5)."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(64, 8))
    out.append(_b(0, 0))
    out.append(_b(0, 8))
    return out^


def _fsb4_buffers() -> List[BufferDescriptor]:
    """FIXED_SIZE_BINARY(4) validity, values (one 4-byte value)."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(0, 4))
    return out^


def _fsb1_buffers() -> List[BufferDescriptor]:
    """FIXED_SIZE_BINARY(1) validity, values (one 1-byte value)."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(0, 1))
    return out^


def _fsl1_buffers() -> List[BufferDescriptor]:
    """FIXED_SIZE_LIST validity, child validity, child values (5)."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(0, 0))
    out.append(_b(0, 8))
    return out^


def _lview_buffers() -> List[BufferDescriptor]:
    """LIST_VIEW validity, offsets [0], sizes [1], child validity, child
    values (5)."""
    var out = List[BufferDescriptor]()
    out.append(_b(0, 0))
    out.append(_b(64, 4))
    out.append(_b(68, 4))
    out.append(_b(0, 0))
    out.append(_b(0, 8))
    return out^


def _first(var bufs: List[BufferDescriptor], n: Int) -> List[BufferDescriptor]:
    var out = List[BufferDescriptor]()
    for i in range(n):
        out.append(bufs[i].copy())
    return out^


def _per_node(path: Int) -> String:
    if path == NESTED:
        return "_decode_column_nested"
    return "_decode_column_nested_zerocopy"


def _reads(path: Int, node: Int, need: Int, at: Int, have: Int) -> String:
    return (
        _per_node(path) + ": field node #" + String(node) + " reads "
        + String(need) + " buffers from buffer #" + String(at)
        + " but the RecordBatch has " + String(have) + " buffers"
    )


def _missing(path: Int, node: Int, have: Int) -> String:
    return (
        _per_node(path) + ": field node #" + String(node)
        + " is missing (the RecordBatch has " + String(have)
        + " field nodes)"
    )


def _child_len(
    path: Int, struct_node: Int, child: Int, node: Int, got: Int, want: Int
) -> String:
    return (
        _per_node(path) + ": field node #" + String(node) + " (child "
        + String(child) + " of the STRUCT at field node #"
        + String(struct_node) + ") has length "
        + String(got) + " but the STRUCT has length " + String(want)
    )


# ---------------------------------------------------------------------------
# Checks, one per path
# ---------------------------------------------------------------------------


def _check_struct_child_length(path: Int) raises:
    # A child shorter than its STRUCT.
    assert_equal(
        _err(path, K_STRUCT1, 3, _nodes(3, 2), _struct1_buffers()),
        _child_len(path, 0, 0, 1, 2, 3),
    )
    # A child longer than its STRUCT.
    assert_equal(
        _err(path, K_STRUCT1, 2, _nodes(2, 3), _struct1_buffers()),
        _child_len(path, 0, 0, 1, 3, 2),
    )
    # The second child: the refusal names child 1 at field node #2.
    assert_equal(
        _err(path, K_STRUCT2, 3, _nodes(3, 3, 2), _struct2_buffers()),
        _child_len(path, 0, 1, 2, 2, 3),
    )
    # A STRUCT that is the second column, at field node #1: the refusal
    # names its node, not #0.
    assert_equal(
        _err(path, K_I64_STRUCT1, 3, _nodes(3, 3, 2), _i64_struct1_buffers()),
        _child_len(path, 1, 0, 2, 2, 3),
    )


def _check_struct_buffers(path: Int) raises:
    # No buffer for the STRUCT's own validity.
    assert_equal(
        _err(path, K_STRUCT1, 3, _nodes(3, 3), List[BufferDescriptor]()),
        _reads(path, 0, 1, 0, 0),
    )
    # The Int64 child has its validity but not its values.
    assert_equal(
        _err(path, K_STRUCT1, 3, _nodes(3, 3), _first(_struct1_buffers(), 2)),
        _reads(path, 1, 2, 1, 2),
    )
    # The second child's buffers are missing entirely.
    assert_equal(
        _err(
            path, K_STRUCT2, 3, _nodes(3, 3, 3), _first(_struct2_buffers(), 3)
        ),
        _reads(path, 2, 2, 3, 3),
    )


def _check_list_buffers(path: Int) raises:
    # The LIST has its validity but not its offsets.
    assert_equal(
        _err(path, K_LIST, 1, _nodes(1, 1), _first(_list_buffers(), 1)),
        _reads(path, 0, 2, 0, 1),
    )
    # The child has its validity but not its values.
    assert_equal(
        _err(path, K_LIST, 1, _nodes(1, 1), _first(_list_buffers(), 3)),
        _reads(path, 1, 2, 2, 3),
    )


def _check_fixed_size_buffers(path: Int) raises:
    """The FIXED_SIZE_BINARY count depends on the spec's byte width and the
    FIXED_SIZE_LIST count on its list size and child count, which the call
    site passes in: these cases fail if it passes 0 for either."""
    assert_equal(
        _err(path, K_FSB4, 1, _nodes(1), List[BufferDescriptor]()),
        _reads(path, 0, 2, 0, 0),
    )
    assert_equal(
        _err(path, K_FSB4, 1, _nodes(1), _first(_fsb4_buffers(), 1)),
        _reads(path, 0, 2, 0, 1),
    )
    assert_equal(
        _err(path, K_FSL1, 1, _nodes(1, 1), List[BufferDescriptor]()),
        _reads(path, 0, 1, 0, 0),
    )
    # Byte width 1, the smallest that has a values buffer: these fail if
    # the count treats width 1 as no buffers.
    assert_equal(
        _err(path, K_FSB1, 1, _nodes(1), List[BufferDescriptor]()),
        _reads(path, 0, 2, 0, 0),
    )
    assert_equal(
        _err(path, K_FSB1, 1, _nodes(1), _first(_fsb1_buffers(), 1)),
        _reads(path, 0, 2, 0, 1),
    )


def _check_node_counts(path: Int) raises:
    assert_equal(
        _err(path, K_STRUCT1, 3, _nodes(3), _struct1_buffers()),
        _missing(path, 1, 1),
    )
    assert_equal(
        _err(path, K_STRUCT2, 3, _nodes(3, 3), _struct2_buffers()),
        _missing(path, 2, 2),
    )
    assert_equal(
        _err(path, K_LIST, 1, _nodes(1), _list_buffers()),
        _missing(path, 1, 1),
    )


def _check_controls(path: Int) raises:
    assert_equal(
        _err(path, K_STRUCT1, 3, _nodes(3, 3), _struct1_buffers()), ""
    )
    assert_equal(
        _err(path, K_STRUCT2, 3, _nodes(3, 3, 3), _struct2_buffers()), ""
    )
    assert_equal(_err(path, K_LIST, 1, _nodes(1, 1), _list_buffers()), "")
    assert_equal(
        _err(path, K_I64_STRUCT1, 3, _nodes(3, 3, 3), _i64_struct1_buffers()),
        "",
    )
    assert_equal(_err(path, K_FSB4, 1, _nodes(1), _fsb4_buffers()), "")
    assert_equal(_err(path, K_FSB1, 1, _nodes(1), _fsb1_buffers()), "")
    assert_equal(_err(path, K_FSL1, 1, _nodes(1, 1), _fsl1_buffers()), "")


def _check_struct_values(var cols: Slab[Column[HeapRegion]]) raises:
    assert_equal(len(cols), 1)
    ref s = cols[0]
    assert_equal(s._length, 3)
    assert_equal(len(s._children), 2)
    for c in range(2):
        ref child = s._children[c]
        assert_equal(child._length, 3)
        assert_equal(Int(child._data.read_u8_at(0)), 5)
        assert_equal(Int(child._data.read_u8_at(8)), 6)
        assert_equal(Int(child._data.read_u8_at(16)), 7)


# ---------------------------------------------------------------------------
# Tests (the STRUCT length cases first: without their check they fail on an
# assertion, while the buffer cases abort the process without theirs)
# ---------------------------------------------------------------------------


def test_nested_refuses_struct_child_length_mismatch() raises:
    _check_struct_child_length(NESTED)


def test_nested_zerocopy_refuses_struct_child_length_mismatch() raises:
    _check_struct_child_length(NZC)


def test_nested_refuses_too_few_buffers_struct() raises:
    _check_struct_buffers(NESTED)


def test_nested_zerocopy_refuses_too_few_buffers_struct() raises:
    _check_struct_buffers(NZC)


def test_nested_refuses_too_few_buffers_list() raises:
    _check_list_buffers(NESTED)


def test_nested_zerocopy_refuses_too_few_buffers_list() raises:
    _check_list_buffers(NZC)


def test_nested_refuses_too_few_buffers_fixed_size() raises:
    _check_fixed_size_buffers(NESTED)


def test_nested_zerocopy_refuses_too_few_buffers_fixed_size() raises:
    _check_fixed_size_buffers(NZC)


def test_nested_refuses_too_few_buffers_list_view() raises:
    """LIST_VIEW (copy-on-read only) reads validity, offsets and sizes; its
    count depends on the child count the call site passes in. The control
    pins that a well-formed LIST_VIEW still decodes."""
    assert_equal(
        _err(NESTED, K_LVIEW, 1, _nodes(1, 1), _first(_lview_buffers(), 2)),
        _reads(NESTED, 0, 3, 0, 2),
    )
    assert_equal(
        _err(NESTED, K_LVIEW, 1, _nodes(1, 1), _first(_lview_buffers(), 4)),
        _reads(NESTED, 1, 2, 3, 4),
    )
    assert_equal(_err(NESTED, K_LVIEW, 1, _nodes(1, 1), _lview_buffers()), "")


def test_nested_refuses_too_few_buffers_view_variadic() raises:
    """A BINARY_VIEW reads 2 + variadicBufferCounts[i] buffers: one variadic
    buffer the message lacks, and a count so large that `2 + count` would
    wrap if it were added unchecked (the check reads it as 2^62)."""
    var two = List[BufferDescriptor]()
    two.append(_b(0, 0))
    two.append(_b(0, 16))
    var one = List[Int64]()
    one.append(Int64(1))
    assert_equal(
        _err(NESTED, K_BVIEW, 1, _nodes(1), two.copy(), one^),
        _reads(NESTED, 0, 3, 0, 2),
    )
    var huge = List[Int64]()
    huge.append(Int64(9223372036854775807))
    assert_equal(
        _err(NESTED, K_BVIEW, 1, _nodes(1), two^, huge^),
        _reads(NESTED, 0, 4611686018427387904, 0, 2),
    )


def test_nested_refuses_too_few_buffers_second_view_column() raises:
    """Two BINARY_VIEW columns: the second column's count reads
    variadicBufferCounts[1], not [0]. With counts [0, 1] the second column
    lacks its variadic buffer, and the refusal fails if the call site reads
    the first column's count. With counts [1, 0] and only the first
    column's validity and views buffers, the first column lacks its
    variadic buffer, and the refusal fails if the call site gives the first
    column another column's count. The control, counts [1, 0] with the
    buffers they name, decodes, and fails if the second column takes the
    first column's count (it would read one buffer too many)."""
    var short = List[BufferDescriptor]()
    short.append(_b(0, 0))
    short.append(_b(0, 16))
    short.append(_b(0, 0))
    short.append(_b(0, 16))
    var v01 = List[Int64]()
    v01.append(Int64(0))
    v01.append(Int64(1))
    assert_equal(
        _err(NESTED, K_BVIEW2, 1, _nodes(1, 1), short^, v01^),
        _reads(NESTED, 1, 3, 2, 4),
    )
    var first_short = List[BufferDescriptor]()
    first_short.append(_b(0, 0))
    first_short.append(_b(0, 16))
    var v10_short = List[Int64]()
    v10_short.append(Int64(1))
    v10_short.append(Int64(0))
    assert_equal(
        _err(NESTED, K_BVIEW2, 1, _nodes(1, 1), first_short^, v10_short^),
        _reads(NESTED, 0, 3, 0, 2),
    )
    var full = List[BufferDescriptor]()
    full.append(_b(0, 0))
    full.append(_b(0, 16))
    full.append(_b(0, 0))
    full.append(_b(0, 0))
    full.append(_b(0, 16))
    var v10 = List[Int64]()
    v10.append(Int64(1))
    v10.append(Int64(0))
    assert_equal(_err(NESTED, K_BVIEW2, 1, _nodes(1, 1), full^, v10^), "")


def test_nested_refuses_too_few_field_nodes() raises:
    _check_node_counts(NESTED)


def test_nested_zerocopy_refuses_too_few_field_nodes() raises:
    _check_node_counts(NZC)


def test_nested_controls() raises:
    _check_controls(NESTED)
    _check_struct_values(
        decode_record_batch_message_nested(
            _frame(3, _nodes(3, 3, 3), _struct2_buffers(), List[Int64]()),
            _specs(K_STRUCT2),
        )
    )


def test_nested_zerocopy_controls() raises:
    _check_controls(NZC)
    var frame = _frame(3, _nodes(3, 3, 3), _struct2_buffers(), List[Int64]())
    _check_struct_values(
        decode_record_batch_message_nested_zerocopy(frame, _specs(K_STRUCT2))
    )
    _ = frame.len()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
