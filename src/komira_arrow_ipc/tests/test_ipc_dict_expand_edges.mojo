# =============================================================================
# test_ipc_dict_expand_edges.mojo: expand_dict_indices_to_string with Int64
# indices, and its refusals of a dictionary it cannot read
# =============================================================================
#
# test_ipc_field_node_flat.mojo drives the index-count and index-range
# refusals with Int32 indices. This file covers:
#   * Int64 indices (both the sizing and the copy pass read 8-byte
#     indices), with a null row whose index is never read;
#   * an index width other than 32 or 64, a dictionary that is not STRING,
#     a STRING dictionary without offsets, a negative value count, a value
#     count the offsets cannot hold, offsets that go backwards, and an
#     offset past the data buffer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow_ipc.ipc_decoder_dispatch import expand_dict_indices_to_string


def _dict(
    t: ArrowType, length: Int, var offsets: List[Int], data: String,
    with_offsets: Bool = True,
) raises -> Column[HeapRegion]:
    """A dictionary column of type `t` and `length` values over Int32
    `offsets` and the bytes of `data`."""
    var bytes = data.as_bytes()
    var d = OwnedAlignedBuffer(max(len(bytes), 1))
    d.set_length(Int64(len(bytes)))
    for i in range(len(bytes)):
        d.write_u8_at(i, bytes[i])
    var o = OwnedAlignedBuffer(max(len(offsets) * 4, 1))
    o.set_length(Int64(len(offsets) * 4))
    for i in range(len(offsets)):
        o.write_i32_le_at(i * 4, Int32(offsets[i]))
    var off_opt = Optional[OwnedAlignedBuffer](None)
    if with_offsets:
        off_opt = o^
    return Column[HeapRegion](
        arrow_type=t,
        data=d^,
        offsets=off_opt^,
        validity=None,
        length=length,
        null_count=0,
        offset=0,
    )


def _offs(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    var o = List[Int]()
    o.append(a)
    o.append(b)
    o.append(c)
    o.append(d)
    return o^


def _xyz() raises -> Column[HeapRegion]:
    """Values "x", "yy", "zzz"."""
    return _dict(ArrowType.STRING, 3, _offs(0, 1, 3, 6), "xyyzzz")


def _idx64(var idx: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(len(idx) * 8, 1))
    b.set_length(Int64(len(idx) * 8))
    for i in range(len(idx)):
        b.write_u64_le_at(i * 8, UInt64(idx[i]))
    return b^


def _idx32(var idx: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(len(idx) * 4, 1))
    b.set_length(Int64(len(idx) * 4))
    for i in range(len(idx)):
        b.write_u32_le_at(i * 4, UInt32(idx[i]))
    return b^


def _rows(a: Int, b: Int, c: Int) -> List[Int]:
    var r = List[Int]()
    r.append(a)
    r.append(b)
    r.append(c)
    return r^


def test_int64_indices_expand() raises:
    var col = expand_dict_indices_to_string(
        _idx64(_rows(2, 0, 1)), 3, None, _xyz(), 64
    )
    assert_equal(col.arrow_type, ArrowType.STRING)
    var s = col.as_string()
    assert_equal(s.get(0), String("zzz"))
    assert_equal(s.get(1), String("x"))
    assert_equal(s.get(2), String("yy"))


def test_int64_indices_skip_a_null_row() raises:
    """Row 1 is null and its index (99, out of range) is never read."""
    var bm = Bitmap.create(3)
    bm.set(0)
    bm.set(2)
    var col = expand_dict_indices_to_string(
        _idx64(_rows(1, 99, 2)), 3, bm^, _xyz(), 64
    )
    assert_equal(col._null_count, 1)
    assert_true(col.is_null_at(1))
    var s = col.as_string()
    assert_equal(s.get(0), String("yy"))
    assert_equal(s.get(2), String("zzz"))


def _err(
    var idx: OwnedAlignedBuffer, dict_col: Column[HeapRegion], width: Int = 32
) -> String:
    try:
        _ = expand_dict_indices_to_string(idx^, 3, None, dict_col, width)
    except e:
        return String(e)
    return String("no error")


def test_refuses_an_index_width_other_than_32_or_64() raises:
    assert_equal(
        _err(_idx32(_rows(0, 0, 0)), _xyz(), 16),
        "expand_dict_indices_to_string: index_bit_width must be 32 (Int32 v1"
        " default) or 64 (Int64 for >2G dict entries); got 16",
    )


def test_refuses_a_dictionary_that_is_not_string() raises:
    assert_equal(
        _err(
            _idx32(_rows(0, 0, 0)),
            _dict(ArrowType.BINARY, 3, _offs(0, 1, 3, 6), "xyyzzz"),
        ),
        "expand_dict_indices_to_string: dict_values_col must have"
        " arrow_type=STRING (v1 lossy-expand contract); got type_id 14",
    )


def test_refuses_a_string_dictionary_without_offsets() raises:
    var msg = _err(
        _idx32(_rows(0, 0, 0)),
        _dict(ArrowType.STRING, 3, _offs(0, 1, 3, 6), "xyyzzz", False),
    )
    assert_equal(
        msg,
        "expand_dict_indices_to_string: dict_values_col has no _offsets"
        " buffer (corrupt STRING dictionary)",
    )


def test_refuses_a_negative_value_count() raises:
    assert_equal(
        _err(
            _idx32(_rows(0, 0, 0)),
            _dict(ArrowType.STRING, -1, _offs(0, 1, 3, 6), "xyyzzz"),
        ),
        "expand_dict_indices_to_string: dictionary declares a negative value"
        " count (-1)",
    )


def test_refuses_a_value_count_the_offsets_cannot_hold() raises:
    """4 values need 5 offsets; the buffer holds 4."""
    assert_equal(
        _err(
            _idx32(_rows(0, 0, 0)),
            _dict(ArrowType.STRING, 4, _offs(0, 1, 3, 6), "xyyzzz"),
        ),
        "expand_dict_indices_to_string: dictionary declares 4 values, which"
        " needs 4+1 Int32 offset entries, but the offsets buffer holds only 4"
        " (16 bytes)",
    )


def test_refuses_backward_offsets() raises:
    assert_true(
        _err(
            _idx32(_rows(0, 0, 0)),
            _dict(ArrowType.STRING, 3, _offs(0, 3, 1, 6), "xyyzzz"),
        ).startswith(
            "expand_dict_indices_to_string: dictionary offsets are not"
            " monotonic — offsets[2]=1 < offsets[1]=3"
        )
    )


def test_refuses_an_offset_past_the_data() raises:
    """The last offset 7 is one past the 6 data bytes; 6 (the control
    dictionary) is the end itself and is accepted."""
    assert_equal(
        _err(
            _idx32(_rows(0, 0, 0)),
            _dict(ArrowType.STRING, 3, _offs(0, 1, 3, 7), "xyyzzz"),
        ),
        "expand_dict_indices_to_string: dictionary offsets[3]=7 exceeds the"
        " dictionary data buffer length 6",
    )
    assert_equal(_err(_idx32(_rows(0, 1, 2)), _xyz()), "no error")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
