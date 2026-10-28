# =============================================================================
# test_ipc_encoder_refusals.mojo: the encoders' refusals of a Column whose
# buffers or children contradict its type, and the dictionary-batch and
# file-framing helpers' edges
# =============================================================================
#
# The komira_arrow constructors build consistent Columns; a Column built
# field by field (as a reader or a foreign import may) can contradict
# itself. encode_record_batch_message refuses, naming the arm:
#   * a null_count with no validity bitmap, and a bitmap shorter than the
#     rows; a NULL column whose null_count is not its length;
#   * a STRING, LIST, LARGE_LIST or MAP whose offsets buffer is short;
#   * a LIST / LARGE_LIST / MAP without exactly one child; a
#     FIXED_SIZE_LIST without one child or whose child is not
#     length x size rows long;
#   * a DICTIONARY whose index width is neither 4 nor 8.
# _copy_bytes_into_body refuses a copy past the sink or the source.
# The dictionary helpers refuse a non-DICTIONARY / non-STRING input and a
# dictionary without values or offsets; slice_string_values_column and
# string_values_prefix_matches are checked on a five-value dictionary.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_body_sink import AlignedBufferBodySink
from komira_arrow_ipc.ipc_encoder_dispatch import (
    _copy_bytes_into_body,
    arrow_ipc_file_magic_trailer,
    arrow_ipc_message_metadata_length,
    encode_dictionary_batch_message_from_string_column,
    encode_record_batch_message,
    make_string_dict_values_column_from_dictionary,
    slice_string_values_column,
    string_values_prefix_matches,
)


# ---------------------------------------------------------------------------
# Builders
# ---------------------------------------------------------------------------


def _buf(n: Int) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(n, 1))
    b.zero()
    b.set_length(Int64(n))
    return b^


def _raw(
    t: ArrowType,
    length: Int,
    data_len: Int,
    offsets_len: Int = -1,
    null_count: Int = 0,
    bitmap_bits: Int = -1,
) -> Column[HeapRegion]:
    """A Column of type `t` built field by field: `data_len` zero bytes,
    an offsets buffer of `offsets_len` zero bytes (none if -1), a bitmap of
    `bitmap_bits` bits (none if -1) holding a byte per 8 bits, rounded up."""
    var offs = Optional[OwnedAlignedBuffer](None)
    if offsets_len >= 0:
        offs = _buf(offsets_len)
    var validity = Optional[Bitmap[HeapRegion]](None)
    if bitmap_bits >= 0:
        var bm = Bitmap.create(bitmap_bits)
        bm.buffer.set_length((bitmap_bits + 7) // 8)
        validity = bm^
    return Column[HeapRegion](
        arrow_type=t,
        data=_buf(data_len),
        offsets=offs^,
        validity=validity^,
        length=length,
        null_count=null_count,
        offset=0,
    )


def _i64(n: Int) -> Column[HeapRegion]:
    var v = List[Int64]()
    for i in range(n):
        v.append(Int64(i))
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(v)
    )


def _with_children(
    var parent: Column[HeapRegion], n_children: Int, child_len: Int
) -> Column[HeapRegion]:
    var kids = Slab[Column[HeapRegion]]()
    for _ in range(n_children):
        kids.append(_i64(child_len))
    parent._children = kids^
    return parent^


def _encode_error(var col: Column[HeapRegion]) -> String:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(col^)
    try:
        _ = encode_record_batch_message(cols^)
    except e:
        return String(e)
    return String("no error")


# ---------------------------------------------------------------------------
# Validity and NULL
# ---------------------------------------------------------------------------


def test_refuses_nulls_without_a_bitmap_and_a_short_bitmap() raises:
    assert_equal(
        _encode_error(_raw(ArrowType.INT64, 3, 24, null_count=1)),
        "emit_validity_bitmap: null_count > 0 but no validity bitmap",
    )
    # 9 rows need 2 bitmap bytes; this bitmap holds 1 (8 bits).
    assert_equal(
        _encode_error(
            _raw(ArrowType.INT64, 9, 72, null_count=1, bitmap_bits=8)
        ),
        "emit_validity_bitmap: bitmap.buffer.length 1 < expected 2 for 9 rows",
    )
    # The control: 9 bits in 2 bytes encode.
    assert_equal(
        _encode_error(
            _raw(ArrowType.INT64, 9, 72, null_count=1, bitmap_bits=9)
        ),
        "no error",
    )


def test_refuses_a_null_column_with_a_valid_row() raises:
    assert_equal(
        _encode_error(_raw(ArrowType.NULL, 3, 0, null_count=2)),
        "encode_null: NULL column must have null_count == length"
        " (got null_count=2, length=3)",
    )


# ---------------------------------------------------------------------------
# Offsets
# ---------------------------------------------------------------------------


def test_refuses_short_offsets() raises:
    """3 rows need 4 offsets: 16 bytes at Int32, 32 at Int64."""
    assert_equal(
        _encode_error(_raw(ArrowType.STRING, 3, 0, offsets_len=12)),
        "_encode_varlen: offsets buffer too small (have 12 bytes, need 16)",
    )
    assert_equal(
        _encode_error(
            _with_children(_raw(ArrowType.LIST, 3, 0, offsets_len=12), 1, 0)
        ),
        "_emit_offsets_buffer: offsets buffer too small (have 12 bytes, need"
        " 16)",
    )
    assert_equal(
        _encode_error(
            _with_children(
                _raw(ArrowType.LARGE_LIST, 3, 0, offsets_len=24), 1, 0
            )
        ),
        "_emit_offsets_buffer: offsets buffer too small (have 24 bytes, need"
        " 32)",
    )


# ---------------------------------------------------------------------------
# Children
# ---------------------------------------------------------------------------


def test_refuses_a_list_map_without_exactly_one_child() raises:
    assert_equal(
        _encode_error(
            _with_children(_raw(ArrowType.LIST, 3, 0, offsets_len=16), 2, 0)
        ),
        "encode_list: expected exactly 1 child, got 2",
    )
    assert_equal(
        _encode_error(
            _with_children(
                _raw(ArrowType.LARGE_LIST, 3, 0, offsets_len=32), 0, 0
            )
        ),
        "encode_large_list: expected exactly 1 child, got 0",
    )
    assert_equal(
        _encode_error(
            _with_children(_raw(ArrowType.MAP, 3, 0, offsets_len=16), 2, 0)
        ),
        "encode_map: expected exactly 1 child (entries STRUCT), got 2",
    )


def test_refuses_a_fixed_size_list_of_the_wrong_shape() raises:
    var no_child = _raw(ArrowType.FIXED_SIZE_LIST, 3, 0)
    no_child._inner_size = 2
    assert_equal(
        _encode_error(no_child^),
        "encode_fixed_size_list: expected exactly 1 child, got 0",
    )
    var short = _with_children(_raw(ArrowType.FIXED_SIZE_LIST, 3, 0), 1, 5)
    short._inner_size = 2
    assert_equal(
        _encode_error(short^),
        "encode_fixed_size_list: child length 5 != parent_length * _inner_size"
        " = 6",
    )
    var exact = _with_children(_raw(ArrowType.FIXED_SIZE_LIST, 3, 0), 1, 6)
    exact._inner_size = 2
    assert_equal(_encode_error(exact^), "no error")


def test_refuses_a_dictionary_index_width_of_two() raises:
    var d = _raw(ArrowType.DICTIONARY, 3, 12)
    d._dict_index_byte_width = 2
    assert_true(
        _encode_error(d^).startswith(
            "encode_dictionary: Column._dict_index_byte_width must be 4"
        )
    )


# ---------------------------------------------------------------------------
# _copy_bytes_into_body
# ---------------------------------------------------------------------------


def test_copy_bytes_refuses_past_the_sink_or_the_source() raises:
    var sink = AlignedBufferBodySink(16)
    var src = _buf(8)
    var msg = String("")
    try:
        _ = _copy_bytes_into_body(sink, sink.capacity() - 4, src, 0, 8)
    except e:
        msg = String(e)
    assert_true(msg.startswith("_copy_bytes_into_body: cursor "), msg)
    assert_true(" + count 8 > body.capacity " in msg, msg)
    msg = String("")
    try:
        _ = _copy_bytes_into_body(sink, 0, src, 4, 8)
    except e:
        msg = String(e)
    assert_equal(
        msg, "_copy_bytes_into_body: src_offset 4 + count 8 out of src.length 8"
    )
    msg = String("")
    try:
        _ = _copy_bytes_into_body(sink, 0, src, -1, 1)
    except e:
        msg = String(e)
    assert_equal(
        msg, "_copy_bytes_into_body: src_offset -1 + count 1 out of src.length 8"
    )


# ---------------------------------------------------------------------------
# Dictionary helpers
# ---------------------------------------------------------------------------


def _five() raises -> Column[HeapRegion]:
    var v = List[String]()
    v.append(String("a"))
    v.append(String("bb"))
    v.append(String("ccc"))
    v.append(String("dd"))
    v.append(String("e"))
    return Column.from_string(StringArray.from_strings(v))


def test_dictionary_helpers_refuse_the_wrong_input() raises:
    var msg = String("")
    try:
        _ = encode_dictionary_batch_message_from_string_column(
            Int64(1), _i64(2), False
        )
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "encode_dictionary_batch_message_from_string_column:"
            " dict_col.arrow_type must be STRING; got 5"
        ),
        msg,
    )
    msg = String("")
    try:
        _ = make_string_dict_values_column_from_dictionary(_i64(2))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "make_string_dict_values_column_from_dictionary: input must have"
        " arrow_type=DICTIONARY; got 5",
    )
    msg = String("")
    try:
        _ = make_string_dict_values_column_from_dictionary(
            _raw(ArrowType.DICTIONARY, 2, 8, offsets_len=12)
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "make_string_dict_values_column_from_dictionary: dict_col has no"
        " _dict_data (dictionary values missing)",
    )
    var no_offsets = _raw(ArrowType.DICTIONARY, 2, 8)
    no_offsets._dict_data = SharedAlignedBuffer.from_owned(_buf(3))
    msg = String("")
    try:
        _ = make_string_dict_values_column_from_dictionary(no_offsets^)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "make_string_dict_values_column_from_dictionary: dict_col has no"
        " _offsets (dictionary string offsets missing)",
    )


def test_slice_string_values() raises:
    var s = slice_string_values_column(_five(), 1, 4)
    assert_equal(s._length, 3)
    var a = s.as_string()
    assert_equal(a.get(0), String("bb"))
    assert_equal(a.get(1), String("ccc"))
    assert_equal(a.get(2), String("dd"))
    assert_equal(s._offsets.value().read_i32_le_at(0), Int32(0))
    var empty = slice_string_values_column(_five(), 5, 5)
    assert_equal(empty._length, 0)
    var msgs = List[String]()
    for r in range(3):
        var lo = -1 if r == 0 else (3 if r == 1 else 0)
        var hi = 2 if r == 0 else (2 if r == 1 else 6)
        try:
            _ = slice_string_values_column(_five(), lo, hi)
        except e:
            msgs.append(String(e))
    assert_equal(len(msgs), 3)
    assert_equal(
        msgs[0],
        "slice_string_values_column: range out of bounds: lo=-1, hi=2,"
        " total=5",
    )
    assert_equal(
        msgs[1],
        "slice_string_values_column: range out of bounds: lo=3, hi=2, total=5",
    )
    assert_equal(
        msgs[2],
        "slice_string_values_column: range out of bounds: lo=0, hi=6, total=5",
    )
    var msg = String("")
    try:
        _ = slice_string_values_column(_i64(3), 0, 1)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "slice_string_values_column: values_col.arrow_type must be STRING;"
        " got 5",
    )
    msg = String("")
    try:
        _ = slice_string_values_column(_raw(ArrowType.STRING, 2, 2), 0, 1)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith("slice_string_values_column: values_col missing offsets"),
        msg,
    )


def _strs(a: String, b: String, c: String) raises -> Column[HeapRegion]:
    var v = List[String]()
    v.append(a)
    v.append(b)
    v.append(c)
    return Column.from_string(StringArray.from_strings(v))


def test_string_values_prefix_matches() raises:
    var base = _five()
    assert_true(string_values_prefix_matches(base, _strs("a", "bb", "ccc"), 3))
    assert_true(string_values_prefix_matches(base, _strs("a", "bb", "x"), 2))
    # Same lengths, a byte differs.
    assert_false(string_values_prefix_matches(base, _strs("a", "bx", "ccc"), 3))
    # A length differs.
    assert_false(string_values_prefix_matches(base, _strs("a", "b", "ccc"), 3))
    # Either side shorter than the prefix.
    assert_false(string_values_prefix_matches(base, _strs("a", "bb", "ccc"), 4))
    assert_false(string_values_prefix_matches(_strs("a", "bb", "ccc"), base, 4))
    assert_true(string_values_prefix_matches(base, _strs("q", "r", "s"), 0))
    var msgs = List[String]()
    try:
        _ = string_values_prefix_matches(base, _i64(3), 1)
    except e:
        msgs.append(String(e))
    try:
        _ = string_values_prefix_matches(base, base, -1)
    except e:
        msgs.append(String(e))
    try:
        _ = string_values_prefix_matches(_raw(ArrowType.STRING, 3, 3), base, 1)
    except e:
        msgs.append(String(e))
    assert_equal(len(msgs), 3)
    assert_equal(
        msgs[0], "string_values_prefix_matches: both inputs must be STRING; got"
        " 13 and 5"
    )
    assert_equal(msgs[1], "string_values_prefix_matches: prefix_len < 0")
    assert_equal(
        msgs[2], "string_values_prefix_matches: missing offsets on inputs"
    )


# ---------------------------------------------------------------------------
# File framing helpers
# ---------------------------------------------------------------------------


def test_magic_trailer_and_metadata_length() raises:
    var t = arrow_ipc_file_magic_trailer()
    assert_equal(t.len(), 6)
    var want = String("ARROW1").as_bytes()
    for i in range(6):
        assert_equal(t.read_u8_at(i), want[i])
    var short = SharedAlignedBuffer[HeapRegion].heap_owned(7)
    short.set_length(7)
    var msg = String("")
    try:
        _ = arrow_ipc_message_metadata_length(short)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "arrow_ipc_message_metadata_length: frame too short (7 bytes, need"
        " >= 8)",
    )
    var eight = SharedAlignedBuffer[HeapRegion].heap_owned(8)
    eight.write_u32_le_at(0, UInt32(0xFFFFFFFF))
    eight.write_u32_le_at(4, UInt32(40))
    eight.set_length(8)
    assert_equal(arrow_ipc_message_metadata_length(eight), Int32(48))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
