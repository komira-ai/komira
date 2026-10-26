# =============================================================================
# test_ipc_nested_map_union_round_trip.mojo: MAP, sparse UNION and dense
# UNION columns with real children through encode_record_batch_message and
# both nested decoders
# =============================================================================
#
# The other nested tests reach MAP and UNION only as refusals (a frame whose
# nodes or buffers are wrong) or as unions with no children. These encode
# a nullable MAP<utf8, int64> and a sparse UNION<int64, utf8> built with
# the komira_arrow constructors, decode each frame with
# decode_record_batch_message_nested (copy-on-read) and
# decode_record_batch_message_nested_zerocopy (borrowing the frame), and
# check every buffer the decoders rebuild: the parent's offsets, validity
# and type ids, and each child's values. A decoder that dropped a child,
# swapped the children, lost the type ids or misplaced the next column's
# buffers fails here.
#
# A dense UNION<int64, utf8> is decoded from a frame written by hand: the
# encoder writes length + 1 offsets for a dense union, whose offsets buffer
# holds length entries, so it refuses the dense union UnionArray builds
# (komira-ai/komira#1061). The decoders read the spec layout.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.map_array import MapArray
from komira_arrow.union_array import UnionArray
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_RECORD_BATCH,
    write_ipc_message,
    write_message,
    write_record_batch,
)
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_nested,
    decode_record_batch_message_nested_zerocopy,
)


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def _map_column() raises -> Column[HeapRegion]:
    """Three maps: {"a": 1, "b": 2}, null, {"c": 3}."""
    var maps = List[List[Tuple[String, Int]]]()
    var m0 = List[Tuple[String, Int]]()
    m0.append((String("a"), 1))
    m0.append((String("b"), 2))
    maps.append(m0^)
    maps.append(List[Tuple[String, Int]]())
    var m2 = List[Tuple[String, Int]]()
    m2.append((String("c"), 3))
    maps.append(m2^)
    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    valid.append(True)
    return MapArray.from_string_int_maps_nullable(maps, valid).to_column()


def _map_spec() raises -> ColumnTypeSpec:
    var kids = Slab[ColumnTypeSpec]()
    kids.append(ColumnTypeSpec.leaf(ArrowType.STRING))
    kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    var names = List[String]()
    names.append(String("key"))
    names.append(String("value"))
    return ColumnTypeSpec.map_of(ColumnTypeSpec.struct_of(kids^, names^))


def _i64(var vals: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )


def _strs(var vals: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(vals))


def _type_ids() -> List[Int]:
    var t = List[Int]()
    t.append(5)
    t.append(9)
    return t^


def _types() -> List[Int8]:
    """Rows 0 and 2 select child 0 (type id 5), row 1 child 1 (id 9)."""
    var t = List[Int8]()
    t.append(5)
    t.append(9)
    t.append(5)
    return t^


def _sparse_union_column() raises -> Column[HeapRegion]:
    """Sparse: both children have the parent's 3 rows."""
    var ints = List[Int64]()
    ints.append(10)
    ints.append(0)
    ints.append(30)
    var strs = List[String]()
    strs.append(String(""))
    strs.append(String("mid"))
    strs.append(String(""))
    return UnionArray.sparse_from_children_2(
        _type_ids(), _types(), _i64(ints^), _strs(strs^)
    ).to_column()


def _union_spec(mode: ArrowType) raises -> ColumnTypeSpec:
    var kids = Slab[ColumnTypeSpec]()
    kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    kids.append(ColumnTypeSpec.leaf(ArrowType.STRING))
    var names = List[String]()
    names.append(String("i"))
    names.append(String("s"))
    return ColumnTypeSpec(
        arrow_type=mode,
        children=kids^,
        field_names=names^,
        type_ids=_type_ids(),
        inner_size=0,
    )


def _trailer() -> Column[HeapRegion]:
    """An INT64 column after the nested one: its values land only if the
    decoder advanced past every node and buffer of the nested column."""
    var v = List[Int64]()
    v.append(-7)
    v.append(-8)
    v.append(-9)
    return _i64(v^)


def _encode(var col: Column[HeapRegion]) raises -> SharedAlignedBuffer[HeapRegion]:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    cols.append(_trailer())
    return encode_record_batch_message(cols^)


def _specs(var first: ColumnTypeSpec) raises -> Slab[ColumnTypeSpec]:
    var s = Slab[ColumnTypeSpec]()
    s.append(first^)
    s.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    return s^


# ---------------------------------------------------------------------------
# Checks shared by the two decoders
# ---------------------------------------------------------------------------


def _check_trailer(cols: Slab[Column[HeapRegion]]) raises:
    assert_equal(len(cols), 2)
    assert_equal(cols[1].arrow_type, ArrowType.INT64)
    assert_equal(cols[1]._data.read_i64_le_at(0), Int64(-7))
    assert_equal(cols[1]._data.read_i64_le_at(16), Int64(-9))


def _check_map(cols: Slab[Column[HeapRegion]]) raises:
    ref m = cols[0]
    assert_equal(m.arrow_type, ArrowType.MAP)
    assert_equal(m._length, 3)
    assert_equal(m._null_count, 1)
    assert_true(m._offsets)
    ref off = m._offsets.value()
    assert_equal(off.read_i32_le_at(0), Int32(0))
    assert_equal(off.read_i32_le_at(4), Int32(2))
    assert_equal(off.read_i32_le_at(8), Int32(2))
    assert_equal(off.read_i32_le_at(12), Int32(3))
    assert_false(m.is_null_at(0))
    assert_true(m.is_null_at(1))
    assert_false(m.is_null_at(2))
    assert_equal(m.num_children(), 1)
    ref entries = m._children[0]
    assert_equal(entries.arrow_type, ArrowType.STRUCT)
    assert_equal(entries.num_children(), 2)
    var keys = entries._children[0].as_string()
    assert_equal(keys.get(0), String("a"))
    assert_equal(keys.get(1), String("b"))
    assert_equal(keys.get(2), String("c"))
    assert_equal(entries._children[1]._data.read_i64_le_at(0), Int64(1))
    assert_equal(entries._children[1]._data.read_i64_le_at(16), Int64(3))
    _check_trailer(cols)


def _check_union(
    cols: Slab[Column[HeapRegion]], mode: ArrowType, int_rows: Int
) raises:
    ref u = cols[0]
    assert_equal(u.arrow_type, mode)
    assert_equal(u._length, 3)
    assert_equal(len(u._type_ids), 2)
    assert_equal(u._type_ids[0], 5)
    assert_equal(u._type_ids[1], 9)
    assert_equal(Int(u._data.read_u8_at(0)), 5)
    assert_equal(Int(u._data.read_u8_at(1)), 9)
    assert_equal(Int(u._data.read_u8_at(2)), 5)
    assert_equal(u.num_children(), 2)
    ref ints = u._children[0]
    ref strs = u._children[1]
    assert_equal(ints.arrow_type, ArrowType.INT64)
    assert_equal(strs.arrow_type, ArrowType.STRING)
    assert_equal(ints._length, int_rows)
    assert_equal(ints._data.read_i64_le_at(0), Int64(10))
    assert_equal(ints._data.read_i64_le_at((int_rows - 1) * 8), Int64(30))
    var s = strs.as_string()
    if mode == ArrowType.UNION_DENSE:
        assert_equal(strs._length, 1)
        assert_equal(s.get(0), String("mid"))
        assert_true(u._offsets)
        ref off = u._offsets.value()
        assert_equal(off.read_i32_le_at(0), Int32(0))
        assert_equal(off.read_i32_le_at(4), Int32(0))
        assert_equal(off.read_i32_le_at(8), Int32(1))
    else:
        assert_equal(strs._length, 3)
        assert_equal(s.get(1), String("mid"))
    _check_trailer(cols)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_map_round_trips_copy_on_read() raises:
    var frame = _encode(_map_column())
    _check_map(decode_record_batch_message_nested(frame^, _specs(_map_spec())))


def test_map_round_trips_zero_copy() raises:
    var frame = _encode(_map_column())
    var cols = decode_record_batch_message_nested_zerocopy(
        frame, _specs(_map_spec())
    )
    _check_map(cols)


def test_sparse_union_round_trips_copy_on_read() raises:
    var frame = _encode(_sparse_union_column())
    _check_union(
        decode_record_batch_message_nested(
            frame^, _specs(_union_spec(ArrowType.UNION_SPARSE))
        ),
        ArrowType.UNION_SPARSE,
        3,
    )


def test_sparse_union_round_trips_zero_copy() raises:
    var frame = _encode(_sparse_union_column())
    var cols = decode_record_batch_message_nested_zerocopy(
        frame, _specs(_union_spec(ArrowType.UNION_SPARSE))
    )
    _check_union(cols, ArrowType.UNION_SPARSE, 3)


def _dense_union_frame() raises -> SharedAlignedBuffer[HeapRegion]:
    """UNION_DENSE of 3 rows (type ids 5, 9, 5 at 0; offsets 0, 0, 1 at 8)
    over an INT64 child of 2 rows (10, 30 at 24) and a STRING child of 1
    row ("mid": offsets at 40, data at 48), then the INT64 trailer (-7,
    -8, -9 at 56)."""
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(80)
    body.zero()
    body.write_u8_at(0, UInt8(5))
    body.write_u8_at(1, UInt8(9))
    body.write_u8_at(2, UInt8(5))
    body.write_i32_le_at(8, Int32(0))
    body.write_i32_le_at(12, Int32(0))
    body.write_i32_le_at(16, Int32(1))
    body.write_i64_le_at(24, Int64(10))
    body.write_i64_le_at(32, Int64(30))
    body.write_i32_le_at(40, Int32(0))
    body.write_i32_le_at(44, Int32(3))
    body.write_u8_at(48, UInt8(ord("m")))
    body.write_u8_at(49, UInt8(ord("i")))
    body.write_u8_at(50, UInt8(ord("d")))
    body.write_i64_le_at(56, Int64(-7))
    body.write_i64_le_at(64, Int64(-8))
    body.write_i64_le_at(72, Int64(-9))
    body.set_length(80)
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(3), null_count=Int64(0)))
    nodes.append(FieldNode(length=Int64(2), null_count=Int64(0)))
    nodes.append(FieldNode(length=Int64(1), null_count=Int64(0)))
    nodes.append(FieldNode(length=Int64(3), null_count=Int64(0)))
    var bufs = List[BufferDescriptor]()
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(3)))
    bufs.append(BufferDescriptor(offset=Int64(8), length=Int64(12)))
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(0)))
    bufs.append(BufferDescriptor(offset=Int64(24), length=Int64(16)))
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(0)))
    bufs.append(BufferDescriptor(offset=Int64(40), length=Int64(8)))
    bufs.append(BufferDescriptor(offset=Int64(48), length=Int64(3)))
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(0)))
    bufs.append(BufferDescriptor(offset=Int64(56), length=Int64(24)))
    var w = FlatbufWriter(2048)
    var rb = write_record_batch(w, Int64(3), nodes, bufs)
    var msg = write_message(w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb, Int64(80))
    var fb = w^.finalize(msg)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(
        w2, fb^, body.view_range_ro(0, 80).into_span(), True
    )


def test_dense_union_decodes_copy_on_read() raises:
    _check_union(
        decode_record_batch_message_nested(
            _dense_union_frame(), _specs(_union_spec(ArrowType.UNION_DENSE))
        ),
        ArrowType.UNION_DENSE,
        2,
    )


def test_dense_union_decodes_zero_copy() raises:
    var frame = _dense_union_frame()
    var cols = decode_record_batch_message_nested_zerocopy(
        frame, _specs(_union_spec(ArrowType.UNION_DENSE))
    )
    _check_union(cols, ArrowType.UNION_DENSE, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
