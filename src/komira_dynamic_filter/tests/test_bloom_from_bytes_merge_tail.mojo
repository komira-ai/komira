# =============================================================================
# BloomFilter.from_bytes sizing and padding; merge_or_range's scalar u64
# tail and its byte tail
# =============================================================================
#
# from_bytes: a bitset shorter than its 32-byte block multiple is copied and
# the rest zeroed, across the block boundaries 0, 1, 31, 32, 33, 63, 64, 65.
# A recycled heap block filled with 0xFF is freed just before each call, so
# a missing zero fill shows up as 0xFF bytes in the padding.
#
# merge_or_range: windows whose u64 count is not a multiple of the SIMD
# width (the scalar tail) and whose byte length is not a multiple of 8 (the
# byte tail), each starting at a multiple of 8, checked byte for byte
# against an in-test OR over the window, with every byte outside the window
# held unchanged.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily


def _bytes(n: Int, seed: UInt64) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    var state = seed
    for _ in range(n):
        state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        out.append(UInt8((state >> 32) & 0xFF))
    return out^


def _data(bf: BloomFilter) -> List[UInt8]:
    var out = List[UInt8](capacity=bf.num_bytes)
    for i in range(bf.num_bytes):
        out.append(bf.data.get_typed[UInt8](i))
    return out^


def _dirty_heap(n: Int):
    """Allocate `n` bytes of 0xFF and free them, so the next allocation of
    that size class is likely to reuse non-zero memory."""
    var junk = List[UInt8](length=n, fill=0xFF)
    _ = junk^


def test_from_bytes_pads_and_rounds_to_blocks() raises:
    var sizes: List[Int] = [1, 31, 32, 33, 63, 64, 65]
    var want: List[Int] = [32, 32, 32, 64, 64, 64, 96]
    for i in range(len(sizes)):
        var n = sizes[i]
        var raw = _bytes(n, UInt64(n) + 7)
        # OwnedAlignedBuffer(actual) asks for the padded size plus 63 bytes.
        _dirty_heap(((want[i] + 63) // 64) * 64 + 63)
        var bf = BloomFilter.from_bytes(raw.unsafe_ptr(), n, HashFamily.fnv1a())
        assert_equal(bf.num_bytes, want[i], "num_bytes for " + String(n))
        assert_equal(bf.num_blocks, want[i] // 32, "num_blocks for " + String(n))
        assert_equal(Int(bf.data.length()), want[i], "buffer length for " + String(n))
        assert_equal(bf.hash_family.tag, HashFamily.fnv1a().tag, "family for " + String(n))
        var got = _data(bf)
        for j in range(want[i]):
            var expect = raw[j] if j < n else UInt8(0)
            assert_equal(got[j], expect, "byte " + String(j) + " of a " + String(n) + "-byte bitset")


def test_from_bytes_empty_is_one_zero_block() raises:
    var raw = List[UInt8]()
    _dirty_heap(127)
    var bf = BloomFilter.from_bytes(raw.unsafe_ptr(), 0)
    assert_equal(bf.num_bytes, 32)
    assert_equal(bf.num_blocks, 1)
    assert_equal(bf.hash_family.tag, HashFamily.xxhash64().tag)
    var got = _data(bf)
    for j in range(32):
        assert_equal(got[j], UInt8(0), "byte " + String(j))
    # An empty bitset holds no key.
    for k in range(64):
        assert_equal(bf.might_contain_int64(Int64(k)), False, "key " + String(k))


def _check_merge(num_bytes: Int, start: Int, length: Int) raises:
    var a = _bytes(num_bytes, UInt64(start * 131 + length))
    var b = _bytes(num_bytes, UInt64(start * 17 + length + 99))
    var dst = BloomFilter.from_bytes(a.unsafe_ptr(), num_bytes)
    var src = BloomFilter.from_bytes(b.unsafe_ptr(), num_bytes)
    dst.merge_or_range(src, start, length)
    var got = _data(dst)
    var ctx = "window [" + String(start) + ", " + String(start + length) + ")"
    for j in range(num_bytes):
        var expect = a[j] | b[j] if j >= start and j < start + length else a[j]
        assert_equal(got[j], expect, ctx + " byte " + String(j))
    # The source is read-only.
    var src_after = _data(src)
    for j in range(num_bytes):
        assert_equal(src_after[j], b[j], ctx + " source byte " + String(j))


def test_merge_scalar_u64_tail() raises:
    """u64 counts 1, 3, 5, 6, 7, 9, 11, 15: a scalar tail for SIMD widths
    2, 4 and 8, alone and after full SIMD strides, at aligned offsets."""
    var counts: List[Int] = [1, 3, 5, 6, 7, 9, 11, 15]
    for i in range(len(counts)):
        _check_merge(256, 0, counts[i] * 8)
        _check_merge(256, 8, counts[i] * 8)
        _check_merge(256, 96, counts[i] * 8)
    # The last u64 of the filter.
    _check_merge(256, 248, 8)


def test_merge_byte_tail() raises:
    """Byte lengths that are not a multiple of 8: the tail bytes after the
    u64 part, from 8-aligned starts, up to the filter's last byte."""
    var lens: List[Int] = [1, 3, 7, 9, 13, 31, 33, 45, 63]
    for i in range(len(lens)):
        _check_merge(128, 0, lens[i])
        _check_merge(128, 32, lens[i])
        _check_merge(128, 64, lens[i])
    _check_merge(128, 120, 8)
    _check_merge(128, 0, 127)
    _check_merge(128, 8, 120)


def test_merge_empty_window_changes_nothing() raises:
    _check_merge(64, 0, 0)
    _check_merge(64, 32, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
