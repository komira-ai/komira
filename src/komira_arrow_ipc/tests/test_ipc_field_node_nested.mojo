# =============================================================================
# test_ipc_field_node_nested.mojo: FieldNode lengths, null counts and the
# buffer sizes they imply, on the nested RecordBatch decoders.
# =============================================================================
#
# The nested decoders (copy-on-read and zero-copy) walk the FieldNode list by
# schema, recursing into children. Before these checks:
#
#   * no node was validated, so a negative or wrapping length reached every
#     arm, and a schema with more nodes than the RecordBatch indexed past the
#     node list;
#   * the zero-copy arms borrowed every buffer at its descriptor length with
#     no size check at all (values, offsets, type ids, validity);
#   * FIXED_SIZE_LIST compared its child against `length * list_size` with a
#     product that wraps (the zero-copy arm did not compare at all), so a
#     length of 2^62 + 1 with list_size 4 matched a 4-row child;
#   * a node declaring nulls with no validity buffer was accepted.
#
# Each case asserts the exact refusal on both decoders where the arm exists.
# A decoder without the check returns columns (the "" result) or raises a
# different message. Controls: valid leaf, LIST and FIXED_SIZE_LIST batches,
# a valid view batch, and zero rows.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
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


# Body layout: Int64 5, 6, 7 at 0..24; Int32 [0,1,2,3] at 64..80; a
# validity bitmap 0b101 at 248.
comptime BODY = 256
comptime VALIDITY_AT = 248
comptime WRAP_INT64 = 2305843009213693952  # 2^61
comptime WRAP_INT32 = 4611686018427387904  # 2^62
comptime WRAP_VIEW = 1152921504606846976  # 2^60: 2^60 * 16 == 2^64

comptime NESTED = 0
comptime NZC = 1

# Schema shapes.
comptime K_INT64 = 0
comptime K_STRING = 1
comptime K_LIST = 2
comptime K_LARGE_LIST = 3
comptime K_FSL4 = 4
comptime K_FSB4 = 5
comptime K_STRUCT = 6
comptime K_MAP = 7
comptime K_USPARSE = 8
comptime K_UDENSE = 9
comptime K_BVIEW = 10
comptime K_LVIEW = 11
comptime K_TWO_INT64 = 12


# ---------------------------------------------------------------------------
# Frames and schemas
# ---------------------------------------------------------------------------


def _node(length: Int, nulls: Int) -> FieldNode:
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
    (field 4), which the view arms require."""
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
        var b = 0
        if i < 24 and i % 8 == 0:
            b = 5 + i // 8
        elif i >= 64 and i < 80 and i % 4 == 0:
            b = (i - 64) // 4
        elif i == VALIDITY_AT:
            b = 5
        body.append(UInt8(b))
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body), True)


def _leaf(t: ArrowType) raises -> ColumnTypeSpec:
    return ColumnTypeSpec.leaf(t)


def _bare(t: ArrowType, var children: Slab[ColumnTypeSpec]) -> ColumnTypeSpec:
    return ColumnTypeSpec(
        arrow_type=t,
        children=children^,
        field_names=List[String](),
        type_ids=List[Int](),
        inner_size=0,
    )


def _specs(kind: Int) raises -> Slab[ColumnTypeSpec]:
    var s = Slab[ColumnTypeSpec]()
    if kind == K_INT64:
        s.append(_leaf(ArrowType.INT64))
    elif kind == K_STRING:
        s.append(_leaf(ArrowType.STRING))
    elif kind == K_LIST:
        s.append(ColumnTypeSpec.list_of(_leaf(ArrowType.INT64)))
    elif kind == K_LARGE_LIST:
        s.append(ColumnTypeSpec.large_list_of(_leaf(ArrowType.INT64)))
    elif kind == K_FSL4:
        s.append(ColumnTypeSpec.fixed_size_list_of(_leaf(ArrowType.INT64), 4))
    elif kind == K_FSB4:
        s.append(ColumnTypeSpec.fixed_size_binary(4))
    elif kind == K_STRUCT:
        var kids = Slab[ColumnTypeSpec]()
        kids.append(_leaf(ArrowType.INT64))
        var names = List[String]()
        names.append(String("a"))
        s.append(ColumnTypeSpec.struct_of(kids^, names^))
    elif kind == K_MAP:
        var kids = Slab[ColumnTypeSpec]()
        kids.append(_leaf(ArrowType.INT64))
        kids.append(_leaf(ArrowType.INT64))
        var names = List[String]()
        names.append(String("key"))
        names.append(String("value"))
        s.append(
            ColumnTypeSpec.map_of(ColumnTypeSpec.struct_of(kids^, names^))
        )
    elif kind == K_USPARSE:
        s.append(_bare(ArrowType.UNION_SPARSE, Slab[ColumnTypeSpec]()))
    elif kind == K_UDENSE:
        s.append(_bare(ArrowType.UNION_DENSE, Slab[ColumnTypeSpec]()))
    elif kind == K_BVIEW:
        s.append(_leaf(ArrowType.BINARY_VIEW))
    elif kind == K_LVIEW:
        var kids = Slab[ColumnTypeSpec]()
        kids.append(_leaf(ArrowType.INT64))
        s.append(_bare(ArrowType.LIST_VIEW, kids^))
    else:
        s.append(_leaf(ArrowType.INT64))
        s.append(_leaf(ArrowType.INT64))
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


def _n1(a: FieldNode) -> List[FieldNode]:
    var out = List[FieldNode]()
    out.append(a.copy())
    return out^


def _n2(a: FieldNode, b: FieldNode) -> List[FieldNode]:
    var out = _n1(a)
    out.append(b.copy())
    return out^


def _bl(a: BufferDescriptor) -> List[BufferDescriptor]:
    var out = List[BufferDescriptor]()
    out.append(a.copy())
    return out^


def _bl2(a: BufferDescriptor, b: BufferDescriptor) -> List[BufferDescriptor]:
    var out = _bl(a)
    out.append(b.copy())
    return out^


def _bl3(
    a: BufferDescriptor, b: BufferDescriptor, c: BufferDescriptor
) -> List[BufferDescriptor]:
    var out = _bl2(a, b)
    out.append(c.copy())
    return out^


def _bl4(
    a: BufferDescriptor,
    b: BufferDescriptor,
    c: BufferDescriptor,
    d: BufferDescriptor,
) -> List[BufferDescriptor]:
    var out = _bl3(a, b, c)
    out.append(d.copy())
    return out^


def _variadic0() -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(0))
    return out^


# ---------------------------------------------------------------------------
# Expected texts
# ---------------------------------------------------------------------------


def _driver(path: Int) -> String:
    if path == NESTED:
        return "decode_record_batch_message_nested"
    return "decode_record_batch_message_nested_zerocopy"


def _per_node(path: Int) -> String:
    if path == NESTED:
        return "_decode_column_nested"
    return "_decode_column_nested_zerocopy"


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


def _no_validity(ctx: String, i: Int) -> String:
    return _at(ctx, i) + " declares 1 nulls but has no validity bitmap"


# ---------------------------------------------------------------------------
# Leaves and the node walk
# ---------------------------------------------------------------------------


def _check_top_level(path: Int) raises:
    var d = _driver(path)
    var ok = _bl2(_b(0, 0), _b(0, 24))
    assert_equal(
        _err(path, K_INT64, 3, _n1(_node(-1, 0)), ok),
        _at(d, 0) + " has negative length -1",
    )
    assert_equal(
        _err(path, K_INT64, 3, _n1(_node(3, -1)), ok),
        _at(d, 0) + " has negative null_count -1",
    )
    assert_equal(
        _err(path, K_INT64, 3, _n1(_node(3, 4)), ok),
        _at(d, 0) + " null_count 4 exceeds its length 3",
    )
    assert_equal(
        _err(path, K_INT64, 4, _n1(_node(3, 0)), ok),
        d + ": column 0 (field node #0) has length 3 but the RecordBatch"
        + " length is 4",
    )
    assert_equal(
        _err(path, K_INT64, -1, _n1(_node(3, 0)), ok),
        d + ": RecordBatch length -1 is negative",
    )
    # Two top-level columns, one node.
    assert_equal(
        _err(path, K_TWO_INT64, 3, _n1(_node(3, 0)), ok),
        _at(d, 1) + " is missing (the RecordBatch has 1 field nodes)",
    )


def _check_child_nodes(path: Int) raises:
    """A LIST's child node passes the per-node gate, and a child the
    RecordBatch does not carry is refused rather than indexed."""
    var p = _per_node(path)
    var bufs = _bl4(_b(0, 0), _b(64, 8), _b(0, 0), _b(0, 8))
    assert_equal(
        _err(path, K_LIST, 1, _n2(_node(1, 0), _node(-1, 0)), bufs),
        _at(p, 1) + " has negative length -1",
    )
    assert_equal(
        _err(path, K_LIST, 1, _n2(_node(1, 0), _node(1, 2)), bufs),
        _at(p, 1) + " null_count 2 exceeds its length 1",
    )
    assert_equal(
        _err(path, K_LIST, 1, _n1(_node(1, 0)), _bl2(_b(0, 0), _b(64, 8))),
        _at(p, 1) + " is missing (the RecordBatch has 1 field nodes)",
    )


def _check_leaf_sizes(path: Int) raises:
    var p = _per_node(path)
    var values_ctx = String(
        "_build_fixed_width_column"
    ) if path == NESTED else p
    var validity_ctx = String(
        "_maybe_decode_validity_bitmap"
    ) if path == NESTED else p
    var varlen_ctx = String("_build_varlen_column") if path == NESTED else p
    assert_equal(
        _err(
            path, K_INT64, WRAP_INT64, _n1(_node(WRAP_INT64, 0)),
            _bl2(_b(0, 0), _b(0, 24)),
        ),
        _overflow(values_ctx, "values buffer", WRAP_INT64, 8),
    )
    assert_equal(
        _err(path, K_INT64, 4, _n1(_node(4, 0)), _bl2(_b(0, 0), _b(0, 24))),
        _too_small(values_ctx, "values", 24, 32, 4),
    )
    assert_equal(
        _err(
            path, K_INT64, 20, _n1(_node(20, 1)),
            _bl2(_b(VALIDITY_AT, 2), _b(0, 160)),
        ),
        _too_small(validity_ctx, "bitmap", 2, 3, 20),
    )
    assert_equal(
        _err(path, K_INT64, 3, _n1(_node(3, 1)), _bl2(_b(0, 0), _b(0, 24))),
        _no_validity(validity_ctx, 0),
    )
    assert_equal(
        _err(
            path, K_STRING, 3, _n1(_node(3, 0)),
            _bl3(_b(0, 0), _b(64, 12), _b(0, 3)),
        ),
        _too_small(varlen_ctx, "offsets", 12, 16, 3),
    )


def _check_controls(path: Int) raises:
    assert_equal(
        _err(
            path, K_INT64, 3, _n1(_node(3, 1)),
            _bl2(_b(VALIDITY_AT, 1), _b(0, 24)),
        ),
        String(""),
    )
    assert_equal(
        _err(path, K_INT64, 0, _n1(_node(0, 0)), _bl2(_b(0, 0), _b(0, 0))),
        String(""),
    )
    # LIST<INT64> of one 1-element list: offsets [0, 1].
    assert_equal(
        _err(
            path, K_LIST, 1, _n2(_node(1, 0), _node(1, 0)),
            _bl4(_b(0, 0), _b(64, 8), _b(0, 0), _b(0, 8)),
        ),
        String(""),
    )
    # FIXED_SIZE_LIST<INT64>(4) of one row over a 4-row child.
    assert_equal(
        _err(
            path, K_FSL4, 1, _n2(_node(1, 0), _node(4, 0)),
            _bl3(_b(0, 0), _b(0, 0), _b(0, 32)),
        ),
        String(""),
    )


# ---------------------------------------------------------------------------
# Nested arms
# ---------------------------------------------------------------------------


def _check_list_offsets(path: Int) raises:
    var p = _per_node(path)
    var ctx = String("_build_list_column") if path == NESTED else p
    assert_equal(
        _err(
            path, K_LIST, WRAP_INT32, _n1(_node(WRAP_INT32, 0)),
            _bl2(_b(0, 0), _b(64, 16)),
        ),
        _overflow(ctx, "offsets buffer", WRAP_INT32 + 1, 4),
    )
    assert_equal(
        _err(path, K_LIST, 3, _n1(_node(3, 0)), _bl2(_b(0, 0), _b(64, 12))),
        _too_small(ctx, "offsets", 12, 16, 3),
    )
    assert_equal(
        _err(
            path, K_LARGE_LIST, 1, _n1(_node(1, 0)), _bl2(_b(0, 0), _b(64, 8))
        ),
        _too_small(ctx, "offsets", 8, 16, 1),
    )
    assert_equal(
        _err(path, K_MAP, 3, _n1(_node(3, 0)), _bl2(_b(0, 0), _b(64, 12))),
        _too_small(ctx, "offsets", 12, 16, 3),
    )


def _check_fixed_size(path: Int) raises:
    var p = _per_node(path)
    var validity_ctx = String(
        "_maybe_decode_validity_bitmap"
    ) if path == NESTED else p
    # FIXED_SIZE_LIST: 2^62 + 1 rows x 4 wraps to 4, the child's length.
    var fsl_ctx = String(
        "_decode_column_nested FIXED_SIZE_LIST"
    ) if path == NESTED else p
    var fsl_what = String(
        "child rows"
    ) if path == NESTED else String("FIXED_SIZE_LIST child rows")
    assert_equal(
        _err(
            path, K_FSL4, WRAP_INT32 + 1,
            _n2(_node(WRAP_INT32 + 1, 0), _node(4, 0)),
            _bl3(_b(0, 0), _b(0, 0), _b(0, 32)),
        ),
        _overflow(fsl_ctx, fsl_what, WRAP_INT32 + 1, 4),
    )
    var fsl_prefix = String(
        "_decode_column_nested FIXED_SIZE_LIST: decoded child length 4"
    ) if path == NESTED else String(
        "_decode_column_nested_zerocopy FIXED_SIZE_LIST: decoded child"
        " length 4"
    )
    assert_equal(
        _err(
            path, K_FSL4, 2, _n2(_node(2, 0), _node(4, 0)),
            _bl3(_b(0, 0), _b(0, 0), _b(0, 32)),
        ),
        fsl_prefix + " != length * list_size = 8",
    )
    assert_equal(
        _err(
            path, K_FSL4, 1, _n2(_node(1, 1), _node(4, 0)),
            _bl3(_b(0, 0), _b(0, 0), _b(0, 32)),
        ),
        _no_validity(validity_ctx, 0),
    )
    # FIXED_SIZE_BINARY(4).
    var fsb_ctx = String("_build_fixed_width_column") if path == NESTED else p
    assert_equal(
        _err(path, K_FSB4, 3, _n1(_node(3, 0)), _bl2(_b(0, 0), _b(0, 8))),
        _too_small(fsb_ctx, "values", 8, 12, 3),
    )
    assert_equal(
        _err(
            path, K_FSB4, WRAP_INT32, _n1(_node(WRAP_INT32, 0)),
            _bl2(_b(0, 0), _b(0, 8)),
        ),
        _overflow(fsb_ctx, "values buffer", WRAP_INT32, 4),
    )
    assert_equal(
        _err(path, K_FSB4, 2, _n1(_node(2, 1)), _bl2(_b(0, 0), _b(0, 8))),
        _no_validity(validity_ctx, 0),
    )


def _check_validity_arms(path: Int) raises:
    """A node declaring nulls with no validity buffer, on every arm that
    carries one; and a valid STRING control."""
    var validity_ctx = String(
        "_maybe_decode_validity_bitmap"
    ) if path == NESTED else _per_node(path)
    assert_equal(
        _err(
            path, K_STRUCT, 3, _n2(_node(3, 1), _node(3, 0)),
            _bl3(_b(0, 0), _b(0, 0), _b(0, 24)),
        ),
        _no_validity(validity_ctx, 0),
    )
    assert_equal(
        _err(
            path, K_STRING, 3, _n1(_node(3, 1)),
            _bl3(_b(0, 0), _b(64, 16), _b(0, 3)),
        ),
        _no_validity(validity_ctx, 0),
    )
    assert_equal(
        _err(path, K_LIST, 1, _n1(_node(1, 1)), _bl2(_b(0, 0), _b(64, 8))),
        _no_validity(validity_ctx, 0),
    )
    assert_equal(
        _err(path, K_MAP, 1, _n1(_node(1, 1)), _bl2(_b(0, 0), _b(64, 8))),
        _no_validity(validity_ctx, 0),
    )
    assert_equal(
        _err(
            path, K_STRING, 3, _n1(_node(3, 0)),
            _bl3(_b(0, 0), _b(64, 16), _b(0, 3)),
        ),
        String(""),
    )


def _check_unions(path: Int) raises:
    var p = _per_node(path)
    var dense_ctx = String("_build_union_dense_column") if path == NESTED else p
    assert_equal(
        _err(
            path, K_UDENSE, WRAP_INT32, _n1(_node(WRAP_INT32, 0)),
            _bl2(_b(0, 8), _b(0, 8)),
        ),
        _overflow(dense_ctx, "offsets buffer", WRAP_INT32, 4),
    )
    if path == NZC:
        assert_equal(
            _err(path, K_USPARSE, 3, _n1(_node(3, 0)), _bl(_b(0, 2))),
            _too_small(p, "type_ids", 2, 3, 3),
        )
        assert_equal(
            _err(
                path, K_UDENSE, 3, _n1(_node(3, 0)), _bl2(_b(0, 2), _b(0, 12))
            ),
            _too_small(p, "type_ids", 2, 3, 3),
        )
        assert_equal(
            _err(
                path, K_UDENSE, 3, _n1(_node(3, 0)), _bl2(_b(0, 3), _b(0, 8))
            ),
            _too_small(p, "offsets", 8, 12, 3),
        )
    assert_equal(
        _err(path, K_USPARSE, 3, _n1(_node(3, 0)), _bl(_b(0, 3))), String("")
    )
    assert_equal(
        _err(path, K_UDENSE, 3, _n1(_node(3, 0)), _bl2(_b(0, 3), _b(0, 12))),
        String(""),
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_nested_refuses_bad_top_level_nodes() raises:
    _check_top_level(NESTED)


def test_nested_refuses_bad_child_nodes() raises:
    _check_child_nodes(NESTED)


def test_nested_refuses_bad_leaf_sizes() raises:
    _check_leaf_sizes(NESTED)


def test_nested_refuses_bad_list_offsets() raises:
    _check_list_offsets(NESTED)


def test_nested_refuses_bad_fixed_size() raises:
    _check_fixed_size(NESTED)


def test_nested_refuses_nulls_without_validity() raises:
    _check_validity_arms(NESTED)


def test_nested_refuses_bad_unions() raises:
    _check_unions(NESTED)


def test_nested_controls() raises:
    _check_controls(NESTED)


def test_nested_zerocopy_refuses_bad_top_level_nodes() raises:
    _check_top_level(NZC)


def test_nested_zerocopy_refuses_bad_child_nodes() raises:
    _check_child_nodes(NZC)


def test_nested_zerocopy_refuses_bad_leaf_sizes() raises:
    _check_leaf_sizes(NZC)


def test_nested_zerocopy_refuses_bad_list_offsets() raises:
    _check_list_offsets(NZC)


def test_nested_zerocopy_refuses_bad_fixed_size() raises:
    _check_fixed_size(NZC)


def test_nested_zerocopy_refuses_nulls_without_validity() raises:
    _check_validity_arms(NZC)


def test_nested_zerocopy_refuses_bad_unions() raises:
    _check_unions(NZC)


def test_nested_zerocopy_controls() raises:
    _check_controls(NZC)


def test_view_arms_refuse_wrapping_length_and_missing_validity() raises:
    """BinaryView and ListView (copy-on-read only): 2^60 views x 16 bytes
    and 2^62 ListView offsets x 4 bytes both wrap to 0."""
    assert_equal(
        _err(
            NESTED, K_BVIEW, WRAP_VIEW, _n1(_node(WRAP_VIEW, 0)),
            _bl2(_b(0, 0), _b(0, 16)), _variadic0(),
        ),
        _overflow(
            "_decode_binary_or_utf8_view", "view buffer", WRAP_VIEW, 16
        ),
    )
    assert_equal(
        _err(
            NESTED, K_BVIEW, 1, _n1(_node(1, 1)), _bl2(_b(0, 0), _b(0, 16)),
            _variadic0(),
        ),
        _no_validity("_maybe_decode_validity_bitmap", 0),
    )
    assert_equal(
        _err(
            NESTED, K_BVIEW, 1, _n1(_node(1, 0)), _bl2(_b(0, 0), _b(0, 16)),
            _variadic0(),
        ),
        String(""),
    )
    assert_equal(
        _err(
            NESTED, K_LVIEW, WRAP_INT32, _n1(_node(WRAP_INT32, 0)),
            _bl3(_b(0, 0), _b(64, 16), _b(64, 16)),
        ),
        _overflow("_decode_list_view", "offsets buffer", WRAP_INT32, 4),
    )
    # Control: one ListView row, offset 0 (body Int32 at 64) and size 1
    # (body Int32 at 68), over a 1-row INT64 child.
    var lv_bufs = _bl4(_b(0, 0), _b(64, 4), _b(68, 4), _b(0, 0))
    lv_bufs.append(_b(0, 8))
    assert_equal(
        _err(NESTED, K_LVIEW, 1, _n2(_node(1, 0), _node(1, 0)), lv_bufs),
        String(""),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
