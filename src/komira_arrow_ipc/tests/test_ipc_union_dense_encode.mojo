# =============================================================================
# test_ipc_union_dense_encode.mojo: a dense UNION column built by
# UnionArray.dense_from_children_2 round-trips through
# encode_record_batch_message and both nested decoders
# =============================================================================
#
# A dense union's offsets buffer holds one Int32 per slot, `length` entries
# and no trailing offset (Arrow columnar format, "Dense Union");
# UnionArray.dense_from_children_2 builds exactly that and the decoders
# read `length * 4` bytes. The encoder must write the same: an encoder that
# writes `length + 1` offsets (as for a LIST) refuses this column (the
# buffer is 4 bytes short) or, for an offsets buffer that happens to be
# longer, writes a BufferDescriptor 4 bytes too long. The test checks the
# offsets BufferDescriptor's length on the wire, then every buffer the two
# decoders rebuild, and an INT64 column after the union, whose values land
# only if the encoder and the decoder agree on every buffer of the union.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.union_array import UnionArray
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_encoder_dispatch import encode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    RecordBatchDescriptor,
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_record_batch,
)
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_nested,
    decode_record_batch_message_nested_zerocopy,
)


def _i64(var vals: List[Int64]) -> Column[HeapRegion]:
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )


def _type_ids() -> List[Int]:
    var t = List[Int]()
    t.append(5)
    t.append(9)
    return t^


def _dense_union_column() raises -> Column[HeapRegion]:
    """Three rows: child 0 row 0 (10), child 1 row 0 ("mid"), child 0 row 1
    (30); type ids 5, 9, 5 and offsets 0, 0, 1."""
    var types = List[Int8]()
    types.append(5)
    types.append(9)
    types.append(5)
    var offsets = List[Int32]()
    offsets.append(0)
    offsets.append(0)
    offsets.append(1)
    var ints = List[Int64]()
    ints.append(10)
    ints.append(30)
    var strs = List[String]()
    strs.append(String("mid"))
    return UnionArray.dense_from_children_2(
        _type_ids(),
        types,
        offsets,
        _i64(ints^),
        Column.from_string(StringArray.from_strings(strs)),
    ).to_column()


def _encode() raises -> SharedAlignedBuffer[HeapRegion]:
    var trailer = List[Int64]()
    trailer.append(-7)
    trailer.append(-8)
    trailer.append(-9)
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_dense_union_column())
    cols.append(_i64(trailer^))
    return encode_record_batch_message(cols^)


def _specs() raises -> Slab[ColumnTypeSpec]:
    var kids = Slab[ColumnTypeSpec]()
    kids.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    kids.append(ColumnTypeSpec.leaf(ArrowType.STRING))
    var names = List[String]()
    names.append(String("i"))
    names.append(String("s"))
    var s = Slab[ColumnTypeSpec]()
    s.append(
        ColumnTypeSpec(
            arrow_type=ArrowType.UNION_DENSE,
            children=kids^,
            field_names=names^,
            type_ids=_type_ids(),
            inner_size=0,
        )
    )
    s.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    return s^


def _rb_of(frame: SharedAlignedBuffer[HeapRegion]) raises -> RecordBatchDescriptor:
    var f = parse_ipc_message(frame)
    var md = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    for i in range(f.metadata_size):
        md.write_u8_at(i, frame.read_u8_at(f.metadata_pos + i))
    md.set_length(f.metadata_size)
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    return read_record_batch(r, msg.header_table_pos)


def _check(cols: Slab[Column[HeapRegion]]) raises:
    assert_equal(len(cols), 2)
    ref u = cols[0]
    assert_equal(u.arrow_type, ArrowType.UNION_DENSE)
    assert_equal(u._length, 3)
    assert_equal(Int(u._data.read_u8_at(0)), 5)
    assert_equal(Int(u._data.read_u8_at(1)), 9)
    assert_equal(Int(u._data.read_u8_at(2)), 5)
    assert_true(u._offsets)
    ref off = u._offsets.value()
    assert_equal(off.read_i32_le_at(0), Int32(0))
    assert_equal(off.read_i32_le_at(4), Int32(0))
    assert_equal(off.read_i32_le_at(8), Int32(1))
    assert_equal(u.num_children(), 2)
    ref ints = u._children[0]
    assert_equal(ints._length, 2)
    assert_equal(ints._data.read_i64_le_at(0), Int64(10))
    assert_equal(ints._data.read_i64_le_at(8), Int64(30))
    ref strs = u._children[1]
    assert_equal(strs._length, 1)
    assert_equal(strs.as_string().get(0), String("mid"))
    assert_equal(cols[1].arrow_type, ArrowType.INT64)
    assert_equal(cols[1]._data.read_i64_le_at(0), Int64(-7))
    assert_equal(cols[1]._data.read_i64_le_at(8), Int64(-8))
    assert_equal(cols[1]._data.read_i64_le_at(16), Int64(-9))


def test_dense_union_offsets_buffer_is_length_entries() raises:
    """Buffers on the wire: [0] type ids (3 bytes), [1] offsets: 3 Int32s,
    12 bytes, with no trailing offset."""
    var rb = _rb_of(_encode())
    assert_equal(rb.buffers[0].length, Int64(3))
    assert_equal(rb.buffers[1].length, Int64(12))


def test_dense_union_round_trips_copy_on_read() raises:
    _check(decode_record_batch_message_nested(_encode(), _specs()))


def test_dense_union_round_trips_zero_copy() raises:
    var frame = _encode()
    var cols = decode_record_batch_message_nested_zerocopy(frame, _specs())
    _check(cols)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
