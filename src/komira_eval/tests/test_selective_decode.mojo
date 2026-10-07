# =============================================================================
# Tests for Selective Decode — decode only rows that passed filter
# =============================================================================
#
# Test strategy:
#   1. Create PLAIN-encoded data buffers (simulating raw Parquet page data).
#   2. Build SelectionVectors with known indices.
#   3. Run selective_decode and verify only selected values appear.
#   4. Test all decode modes: fixed-width, string, boolean.
#   5. Test gather_strings for post-decode selective copy.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from std.memory import alloc, unsafe_memcpy, unsafe_memset
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.byte_view import ByteView
from komira_arrow.selection_vector import SelectionVector
from komira_column_kernels.selective_decode import (
    selective_decode_fixed,
    selective_decode_string,
    selective_decode_boolean,
    gather_strings,
)


def _make_selection(var indices: List[Int]) -> SelectionVector:
    """Build a SelectionVector from a list of indices."""
    var n = len(indices)
    var arr = PrimitiveArray[DType.int32].allocate(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        (ptr + i)[] = Scalar[DType.int32](indices[i])
    return SelectionVector(arr^)


def test_selective_decode_int64() raises:
    """Selective decode of INT64: only selected rows are returned."""
    # Create a buffer of 10 INT64 values: [0, 10, 20, ..., 90].
    var num_rows = 10
    comptime elem_size = size_of[Scalar[DType.int64]]()
    var buf_size = num_rows * elem_size
    # SAFETY: Allocating raw buffer to simulate PLAIN-encoded Parquet page data.
    var buf = alloc[UInt8](buf_size)
    var typed_ptr = buf.bitcast[Scalar[DType.int64]]()
    for i in range(num_rows):
        (typed_ptr + i)[] = Scalar[DType.int64](i * 10)

    # Select rows 2, 5, 8 -> values 20, 50, 80.
    var sel_indices: List[Int] = [2, 5, 8]
    var sel = _make_selection(sel_indices^)

    # Wrap raw alloc buffer in a ByteView. The
    # buffer outlives the decode call (freed below), so the view's lifetime
    # is valid for the duration of the call.
    var buf_view = ByteView[MutUntrackedOrigin](buf, buf_size)
    var result = selective_decode_fixed[DType.int64](buf_view, num_rows, sel)

    assert_equal(result.length, 3)
    var res_ptr = result._typed_ptr_ro()
    assert_equal(Int((res_ptr + 0)[]), 20)
    assert_equal(Int((res_ptr + 1)[]), 50)
    assert_equal(Int((res_ptr + 2)[]), 80)

    buf.free()


def test_selective_decode_int32() raises:
    """Selective decode of INT32."""
    var num_rows = 8
    comptime elem_size = size_of[Scalar[DType.int32]]()
    var buf_size = num_rows * elem_size
    # SAFETY: Raw buffer for simulated page data.
    var buf = alloc[UInt8](buf_size)
    var typed_ptr = buf.bitcast[Scalar[DType.int32]]()
    for i in range(num_rows):
        (typed_ptr + i)[] = Scalar[DType.int32](100 + i)

    # Select rows 0, 3, 7 -> values 100, 103, 107.
    var sel_indices: List[Int] = [0, 3, 7]
    var sel = _make_selection(sel_indices^)

    # Wrap raw alloc buffer in ByteView.
    var buf_view = ByteView[MutUntrackedOrigin](buf, buf_size)
    var result = selective_decode_fixed[DType.int32](buf_view, num_rows, sel)

    assert_equal(result.length, 3)
    var res_ptr = result._typed_ptr_ro()
    assert_equal(Int((res_ptr + 0)[]), 100)
    assert_equal(Int((res_ptr + 1)[]), 103)
    assert_equal(Int((res_ptr + 2)[]), 107)

    buf.free()


def test_selective_decode_float64() raises:
    """Selective decode of FLOAT64."""
    var num_rows = 5
    comptime elem_size = size_of[Scalar[DType.float64]]()
    var buf_size = num_rows * elem_size
    # SAFETY: Raw buffer for simulated page data.
    var buf = alloc[UInt8](buf_size)
    var typed_ptr = buf.bitcast[Scalar[DType.float64]]()
    for i in range(num_rows):
        (typed_ptr + i)[] = Scalar[DType.float64](i) * 1.5

    # Select rows 1, 4 -> values 1.5, 6.0.
    var sel_indices: List[Int] = [1, 4]
    var sel = _make_selection(sel_indices^)

    # Wrap raw alloc buffer in ByteView.
    var buf_view = ByteView[MutUntrackedOrigin](buf, buf_size)
    var result = selective_decode_fixed[DType.float64](buf_view, num_rows, sel)

    assert_equal(result.length, 2)
    var res_ptr = result._typed_ptr_ro()
    # Float comparison — use Int cast for exact match with these specific values.
    assert_true(Float64((res_ptr + 0)[]) > 1.4)
    assert_true(Float64((res_ptr + 0)[]) < 1.6)
    assert_true(Float64((res_ptr + 1)[]) > 5.9)
    assert_true(Float64((res_ptr + 1)[]) < 6.1)

    buf.free()


def test_selective_decode_empty_selection() raises:
    """Selective decode with empty selection returns empty array."""
    var num_rows = 10
    comptime elem_size = size_of[Scalar[DType.int64]]()
    var buf_size = num_rows * elem_size
    # SAFETY: Raw buffer for simulated page data.
    var buf = alloc[UInt8](buf_size)

    var sel = SelectionVector(PrimitiveArray[DType.int32].allocate(0))
    # Wrap raw alloc buffer in ByteView.
    var buf_view = ByteView[MutUntrackedOrigin](buf, buf_size)
    var result = selective_decode_fixed[DType.int64](buf_view, num_rows, sel)

    assert_equal(result.length, 0)

    buf.free()


def test_selective_decode_boolean() raises:
    """Selective decode of boolean: extract selected bits."""
    # Create a bitmap: 10 bits = [T, F, T, T, F, F, T, F, T, T]
    # Byte 0: 0b00001101 = 0x0D (bits 0,2,3 set)
    # Byte 1: 0b00000111 = 0x07 (bits 6,8,9 -> mapped to bits 0,2 in second byte... wait)
    # Actually: row 0=bit0=T, row 1=bit1=F, row 2=bit2=T, row 3=bit3=T,
    #           row 4=bit4=F, row 5=bit5=F, row 6=bit6=T, row 7=bit7=F
    # Byte 0 = 0b01001101 = 0x4D (bits 0,2,3,6)
    # Byte 1: row 8=bit0=T, row 9=bit1=T -> 0b00000011 = 0x03
    var bm_bytes = 2
    # SAFETY: Raw buffer for simulated boolean page data.
    var buf = alloc[UInt8](bm_bytes)
    (buf + 0)[] = UInt8(0x4D)  # rows 0,2,3,6 = True
    (buf + 1)[] = UInt8(0x03)  # rows 8,9 = True

    # Select rows 0, 3, 6, 9 -> True, True, True, True
    var sel_indices: List[Int] = [0, 3, 6, 9]
    var sel = _make_selection(sel_indices^)

    # Wrap raw alloc buffer in ByteView.
    var buf_view = ByteView[MutUntrackedOrigin](buf, bm_bytes)
    var result = selective_decode_boolean(buf_view, 10, sel)

    assert_equal(result.length, 4)
    assert_true(result.get(0))   # row 0 was True
    assert_true(result.get(1))   # row 3 was True
    assert_true(result.get(2))   # row 6 was True
    assert_true(result.get(3))   # row 9 was True

    buf.free()


def test_selective_decode_boolean_mixed() raises:
    """Boolean selective decode with mixed True/False results."""
    # Same bitmap as above, select rows 1, 4, 8
    # row 1=F, row 4=F, row 8=T
    var bm_bytes = 2
    # SAFETY: Raw buffer for simulated boolean page data.
    var buf = alloc[UInt8](bm_bytes)
    (buf + 0)[] = UInt8(0x4D)
    (buf + 1)[] = UInt8(0x03)

    var sel_indices: List[Int] = [1, 4, 8]
    var sel = _make_selection(sel_indices^)

    # Wrap raw alloc buffer in ByteView.
    var buf_view = ByteView[MutUntrackedOrigin](buf, bm_bytes)
    var result = selective_decode_boolean(buf_view, 10, sel)

    assert_equal(result.length, 3)
    assert_false(result.get(0))  # row 1 was False
    assert_false(result.get(1))  # row 4 was False
    assert_true(result.get(2))   # row 8 was True

    buf.free()


def test_selective_decode_string() raises:
    """Selective decode of PLAIN BYTE_ARRAY strings."""
    # Build a PLAIN BYTE_ARRAY buffer for 4 strings: "aa", "bb", "cc", "dd"
    # Format: [4-byte LE len][data] for each.
    # "aa" = len=2, "bb" = len=2, "cc" = len=2, "dd" = len=2
    # Total: 4 * (4 + 2) = 24 bytes
    var buf_size = 24
    # SAFETY: Raw buffer for simulated BYTE_ARRAY page data.
    var buf = alloc[UInt8](buf_size)
    var offset = 0
    var strings: List[String] = ["aa", "bb", "cc", "dd"]
    for i in range(4):
        var s = strings[i]
        var s_len = s.byte_length()
        # Write 4-byte LE length.
        (buf + offset)[] = UInt8(s_len & 0xFF)
        (buf + offset + 1)[] = UInt8(0)
        (buf + offset + 2)[] = UInt8(0)
        (buf + offset + 3)[] = UInt8(0)
        offset += 4
        # Write string bytes.
        var s_ptr = s.as_c_string_slice().unsafe_ptr()
        unsafe_memcpy(
            dest=buf + offset,
            src=UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(s_ptr)),
            count=s_len,
        )
        offset += s_len

    # Select rows 0 and 3 -> "aa" and "dd".
    var sel_indices: List[Int] = [0, 3]
    var sel = _make_selection(sel_indices^)

    # Wrap raw alloc buffer in ByteView.
    var buf_view = ByteView[MutUntrackedOrigin](buf, buf_size)
    var result = selective_decode_string(buf_view, 4, sel)

    assert_equal(result.length, 2)
    assert_equal(result.get(0), "aa")
    assert_equal(result.get(1), "dd")

    buf.free()


def test_gather_strings_basic() raises:
    """Gather extracts selected rows from a StringArray."""
    # Build a StringArray with 5 strings: ["alpha", "beta", "gamma", "delta", "epsilon"]
    var strings: List[String] = ["alpha", "beta", "gamma", "delta", "epsilon"]
    var total_data = 0
    for i in range(len(strings)):
        total_data += strings[i].byte_length()

    comptime int32_size = size_of[Int32]()
    var off_bytes = (len(strings) + 1) * int32_size
    var offsets = OwnedAlignedBuffer(off_bytes)
    var data = OwnedAlignedBuffer(total_data)
    var off_ptr = offsets.view_typed_mut[DType.int32]()
    var write_pos = 0
    (off_ptr + 0)[] = Int32(0)
    for i in range(len(strings)):
        var s = strings[i]
        var s_len = s.byte_length()
        if s_len > 0:
            var s_ptr = s.as_c_string_slice().unsafe_ptr()
            unsafe_memcpy(
                dest=data.view_typed_mut[DType.uint8]() + write_pos,
                src=UnsafePointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(s_ptr)),
                count=s_len,
            )
        write_pos += s_len
        (off_ptr + i + 1)[] = Int32(write_pos)
    offsets.set_length(Int64(off_bytes))

    data.set_length(Int64(total_data))


    var src = StringArray(offsets^, data^, None, len(strings), 0, 0)

    # Select rows 1, 3 -> "beta", "delta".
    var sel_indices: List[Int] = [1, 3]
    var sel = _make_selection(sel_indices^)

    var result = gather_strings(src, sel)

    assert_equal(result.length, 2)
    assert_equal(result.get(0), "beta")
    assert_equal(result.get(1), "delta")


def test_gather_strings_empty() raises:
    """Gather with empty selection returns empty StringArray."""
    comptime int32_size = size_of[Int32]()
    var offsets = OwnedAlignedBuffer(int32_size)
    offsets.view_typed_mut[DType.int32]().unsafe_write(Int32(0))
    offsets.set_length(Int64(int32_size))

    var data = OwnedAlignedBuffer(1)
    data.set_length(0)

    var src = StringArray(offsets^, data^, None, 0, 0, 0)

    var sel = SelectionVector(PrimitiveArray[DType.int32].allocate(0))
    var result = gather_strings(src, sel)
    assert_equal(result.length, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
