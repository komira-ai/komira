# =============================================================================
# Unit tests for ByteView[mut, origin] + ByteViewPair
# =============================================================================
# The origin-carrying byte view that replaces raw pointer + length pairs.
#
# Coverage:
#   ByteView:
#     1. Construct empty + len() == 0
#     2. Construct over a List[UInt8] slice + read back values
#     3. sub(start, len) preserves origin + mut; content matches
#     4. split_first, split_last on a non-empty view
#     5. load_simd[UInt8, 16] against a 16-byte slice
#     6. Write + read roundtrip on a mutable view
#     7. write_bytes_at copies across a mutable view
#     8. fill zeros a mutable view
#   ByteViewPair:
#     1. Empty construction
#     2. split_at mid=0 / mid=len / mid=N/2 non-overlapping halves
#     3. Both halves writable when mut=True
#
# Negative tests:
#   `write_*_at` on `mut=False` views must not compile. There is no
#   compile-fail harness here; the guarantee is the TYPE-LEVEL receiver
#   refinement (identical pattern to stdlib Span's write methods), and the
#   positive tests above assert it compiles for `mut=True`. See the
#   compile-fail block at the bottom for the calls that must be rejected.

from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_buffer.byte_view import ByteView, ByteViewPair


# =============================================================================
# Helpers
# =============================================================================


def _make_list(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8(i))
    return out^


# =============================================================================
# ByteView tests
# =============================================================================


def test_empty_view() raises:
    """Default-constructed view has length 0."""
    var v = ByteView[ImmutAnyOrigin]()
    assert_equal(v.len(), 0)


def test_view_from_list_read() raises:
    """Construct over a List[UInt8] slice; read back values."""
    var data = _make_list(8)
    # SAFETY: test-scope list outlives the view. Immutable wildcard here
    # is used ONLY in the test harness, not in production code -- the
    # harness is analogous to the FFI-BOUNDARY carve-out.
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 8)
    assert_equal(v.len(), 8)
    assert_equal(Int(v.read_u8_at(0)), 0)
    assert_equal(Int(v.read_u8_at(7)), 7)
    # u16_le over bytes [2, 3] = (0x02, 0x03) => 0x0302
    assert_equal(Int(v.read_u16_le_at(2)), 0x0302)
    # u32_le over bytes [0..4] = (0, 1, 2, 3) => 0x03020100
    assert_equal(Int(v.read_u32_le_at(0)), 0x03020100)
    _ = data^  # keepalive


def test_sub_preserves_content() raises:
    """sub(start, length) returns a correctly-sized subview."""
    var data = _make_list(10)
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 10)
    var mid = v.sub(3, 4)
    assert_equal(mid.len(), 4)
    # mid starts at byte 3, so mid[0] == 3, mid[3] == 6
    assert_equal(Int(mid.read_u8_at(0)), 3)
    assert_equal(Int(mid.read_u8_at(3)), 6)
    _ = data^


def test_split_first_and_last() raises:
    """split_first / split_last on a non-empty view."""
    var data = _make_list(5)  # [0, 1, 2, 3, 4]
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 5)

    var first, tail = v.split_first()
    assert_equal(Int(first), 0)
    assert_equal(tail.len(), 4)
    assert_equal(Int(tail.read_u8_at(0)), 1)

    var last, prefix = v.split_last()
    assert_equal(Int(last), 4)
    assert_equal(prefix.len(), 4)
    assert_equal(Int(prefix.read_u8_at(3)), 3)
    _ = data^


def test_load_simd_16() raises:
    """load_simd[DType.uint8, 16] reads 16 contiguous bytes."""
    var data = _make_list(16)
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 16)
    var simd = v.load_simd[DType.uint8, 16](0)
    for i in range(16):
        assert_equal(Int(simd[i]), i)
    _ = data^


def test_write_and_read_roundtrip() raises:
    """Write via a mut view, read via the same view."""
    var buf = List[UInt8]()
    for _ in range(16):
        buf.append(0)
    # SAFETY: test-scope list outlives the view.
    var ptr = buf.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var v = ByteView[MutAnyOrigin](ptr, 16)
    v.write_u8_at(0, UInt8(0xAB))
    v.write_u16_le_at(2, UInt16(0xBEEF))
    v.write_u32_le_at(8, UInt32(0xDEADBEEF))
    assert_equal(Int(v.read_u8_at(0)), 0xAB)
    assert_equal(Int(v.read_u16_le_at(2)), 0xBEEF)
    assert_equal(Int(v.read_u32_le_at(8)), 0xDEADBEEF)
    _ = buf^


def test_write_bytes_at_copy() raises:
    """write_bytes_at copies source bytes into the dest view."""
    var dst = List[UInt8]()
    for _ in range(8):
        dst.append(0)
    var src = _make_list(4)  # [0, 1, 2, 3]

    var dst_ptr = dst.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var src_ptr = (
        src.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var dst_v = ByteView[MutAnyOrigin](dst_ptr, 8)
    var src_v = ByteView[ImmutAnyOrigin](src_ptr, 4)

    dst_v.write_bytes_at(2, src_v)
    # dst now: [0, 0, 0, 1, 2, 3, 0, 0]
    assert_equal(Int(dst_v.read_u8_at(1)), 0)
    assert_equal(Int(dst_v.read_u8_at(2)), 0)
    assert_equal(Int(dst_v.read_u8_at(3)), 1)
    assert_equal(Int(dst_v.read_u8_at(5)), 3)
    assert_equal(Int(dst_v.read_u8_at(6)), 0)
    _ = dst^
    _ = src^


def test_copy_from_view_at_happy_path() raises:
    """copy_from_view_at bulk-copies 1000 bytes via memcpy; content matches.

    Exercises the path snappy/zlib/zstd literal emitters take -- long
    runs where per-byte scalar loops lose to memcpy by 10-100x.
    """
    var dst = List[UInt8]()
    for _ in range(1000):
        dst.append(UInt8(0xFF))
    var src = _make_list(1000)  # [0, 1, 2, ..., 231, 232, ..., 255, 0, 1, ...]

    var dst_ptr = dst.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var src_ptr = (
        src.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var dst_v = ByteView[MutAnyOrigin](dst_ptr, 1000)
    var src_v = ByteView[ImmutAnyOrigin](src_ptr, 1000)

    dst_v.copy_from_view_at(0, src_v)
    # dst now equals src byte-for-byte across all 1000 slots.
    for i in range(1000):
        # UInt8 wraps naturally at 256; _make_list appends UInt8(i) which
        # truncates, so position i holds UInt8(i % 256).
        assert_equal(Int(dst_v.read_u8_at(i)), i % 256)
    _ = dst^
    _ = src^


def test_copy_from_view_at_zero_length() raises:
    """Zero-length copy is a no-op: destination bytes are untouched, no crash."""
    var dst = List[UInt8]()
    for _ in range(8):
        dst.append(UInt8(0xAA))
    # 4-byte empty slice out of an 8-byte source.
    var src = _make_list(4)

    var dst_ptr = dst.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var src_ptr = (
        src.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var dst_v = ByteView[MutAnyOrigin](dst_ptr, 8)
    var src_v = ByteView[ImmutAnyOrigin](src_ptr, 4)
    # Take a zero-length subview of src -- memcpy(count=0) is a legal no-op.
    var empty = src_v.sub(2, 0)
    assert_equal(empty.len(), 0)

    dst_v.copy_from_view_at(3, empty)

    # Every dst byte still 0xAA; no out-of-bounds side effects.
    for i in range(8):
        assert_equal(Int(dst_v.read_u8_at(i)), 0xAA)
    _ = dst^
    _ = src^


def test_copy_from_view_at_boundaries() raises:
    """copy_from_view_at works at offset=0 and at offset=dst.len()-src.len()."""
    # Case A: offset = 0 (copy to the very start).
    var dst_a = List[UInt8]()
    for _ in range(16):
        dst_a.append(UInt8(0))
    var src_a = _make_list(4)  # [0, 1, 2, 3]
    var dst_a_ptr = dst_a.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var src_a_ptr = (
        src_a.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var dst_a_v = ByteView[MutAnyOrigin](dst_a_ptr, 16)
    var src_a_v = ByteView[ImmutAnyOrigin](src_a_ptr, 4)
    dst_a_v.copy_from_view_at(0, src_a_v)
    # [0,1,2,3, 0,0,...,0]
    assert_equal(Int(dst_a_v.read_u8_at(0)), 0)
    assert_equal(Int(dst_a_v.read_u8_at(3)), 3)
    assert_equal(Int(dst_a_v.read_u8_at(4)), 0)
    assert_equal(Int(dst_a_v.read_u8_at(15)), 0)
    _ = dst_a^
    _ = src_a^

    # Case B: offset = dst.len() - src.len() (copy to the very end).
    var dst_b = List[UInt8]()
    for _ in range(16):
        dst_b.append(UInt8(0))
    var src_b = _make_list(4)  # [0, 1, 2, 3]
    var dst_b_ptr = dst_b.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var src_b_ptr = (
        src_b.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var dst_b_v = ByteView[MutAnyOrigin](dst_b_ptr, 16)
    var src_b_v = ByteView[ImmutAnyOrigin](src_b_ptr, 4)
    dst_b_v.copy_from_view_at(12, src_b_v)
    # [0,0,...,0, 0,1,2,3]
    assert_equal(Int(dst_b_v.read_u8_at(0)), 0)
    assert_equal(Int(dst_b_v.read_u8_at(11)), 0)
    assert_equal(Int(dst_b_v.read_u8_at(12)), 0)
    assert_equal(Int(dst_b_v.read_u8_at(13)), 1)
    assert_equal(Int(dst_b_v.read_u8_at(14)), 2)
    assert_equal(Int(dst_b_v.read_u8_at(15)), 3)
    _ = dst_b^
    _ = src_b^


def test_fill_zeros() raises:
    """fill(byte) sets every byte in the view."""
    var buf = List[UInt8]()
    for _ in range(8):
        buf.append(UInt8(0xFF))
    var ptr = buf.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var v = ByteView[MutAnyOrigin](ptr, 8)
    v.fill(UInt8(0))
    for i in range(8):
        assert_equal(Int(v.read_u8_at(i)), 0)
    _ = buf^


# =============================================================================
# ByteViewPair tests
# =============================================================================


def test_pair_empty_construction() raises:
    """ByteViewPair default-constructs with two empty halves."""
    var pair = ByteViewPair[ImmutAnyOrigin]()
    assert_equal(pair.lhs.len(), 0)
    assert_equal(pair.rhs.len(), 0)


def test_split_at_mid() raises:
    """split_at(mid) splits into two non-overlapping halves."""
    var data = _make_list(10)
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 10)
    var pair = v.split_at(4)
    assert_equal(pair.lhs.len(), 4)
    assert_equal(pair.rhs.len(), 6)
    # lhs[0..4] == [0, 1, 2, 3]
    for i in range(4):
        assert_equal(Int(pair.lhs.read_u8_at(i)), i)
    # rhs[0..6] == [4, 5, 6, 7, 8, 9]
    for i in range(6):
        assert_equal(Int(pair.rhs.read_u8_at(i)), i + 4)
    _ = data^


def test_split_at_edges() raises:
    """split_at(0) and split_at(len) yield empty halves correctly."""
    var data = _make_list(5)
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 5)

    var at_zero = v.split_at(0)
    assert_equal(at_zero.lhs.len(), 0)
    assert_equal(at_zero.rhs.len(), 5)

    var at_end = v.split_at(5)
    assert_equal(at_end.lhs.len(), 5)
    assert_equal(at_end.rhs.len(), 0)
    _ = data^


def test_split_at_mutable_halves() raises:
    """Both halves of a mut split are writable; writes don't overlap."""
    var buf = List[UInt8]()
    for _ in range(10):
        buf.append(0)
    var ptr = buf.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
    var v = ByteView[MutAnyOrigin](ptr, 10)

    var pair = v.split_at(5)
    # lhs writes 0xAA everywhere, rhs writes 0xBB everywhere.
    pair.lhs.fill(UInt8(0xAA))
    pair.rhs.fill(UInt8(0xBB))

    # Reassemble a fresh view and verify no overlap.
    var read_ptr = (
        buf.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var rv = ByteView[ImmutAnyOrigin](read_ptr, 10)
    for i in range(5):
        assert_equal(Int(rv.read_u8_at(i)), 0xAA)
    for i in range(5, 10):
        assert_equal(Int(rv.read_u8_at(i)), 0xBB)
    _ = buf^


# =============================================================================
# into_span()
# =============================================================================


def test_into_span_round_trip_immut() raises:
    """into_span returns a Span over the same bytes; reads round-trip.

    Bridge to stdlib Span APIs while keeping the origin tied to the
    backing storage.
    """
    var data = _make_list(8)
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 8)
    var span = v.into_span()
    # Span len matches the view len.
    assert_equal(len(span), 8)
    # Round-trip via Span indexing.
    for i in range(8):
        assert_equal(Int(span[i]), i)
    _ = data^


def test_into_span_zero_length() raises:
    """into_span on an empty view yields an empty span."""
    var v = ByteView[ImmutAnyOrigin]()
    var span = v.into_span()
    assert_equal(len(span), 0)


def test_into_span_string_roundtrip() raises:
    """into_span composes with String(unsafe_from_utf8=...).

    This is the canonical spill/IO pattern: take an origin-tied byte
    view and bridge it into String for FileHandle.write.
    """
    # ASCII payload "ABCDE" via List[UInt8].
    var data = List[UInt8]()
    data.append(UInt8(65))  # A
    data.append(UInt8(66))  # B
    data.append(UInt8(67))  # C
    data.append(UInt8(68))  # D
    data.append(UInt8(69))  # E
    var ptr = (
        data.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var v = ByteView[ImmutAnyOrigin](ptr, 5)
    var span = v.into_span()
    var s = String(unsafe_from_utf8=span)
    assert_equal(s.byte_length(), 5)
    _ = data^


# =============================================================================
# Compile-fail documentation (in-tree proof)
# =============================================================================
# If you uncomment any of the following lines, the compiler emits
# "no matching method" at the call site -- exactly the negative-test
# contract of the receiver refinement. The positive tests above exercise the
# mut=True path; the receiver-refinement itself is covered by stdlib Span's
# own tests.
#
#   var immut_view = ByteView[ImmutAnyOrigin](ptr, 8)
#   immut_view.write_u8_at(0, UInt8(1))       # no matching method
#   immut_view.write_u16_le_at(0, UInt16(1))  # no matching method
#   immut_view.fill(UInt8(0))                 # no matching method


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
