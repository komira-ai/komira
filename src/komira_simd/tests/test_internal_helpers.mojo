# =============================================================================
# test_internal_helpers.mojo -- the architecture-neutral helpers that only an
# architecture-specific path calls
# =============================================================================
#
# The bool-mask packers and the popcount are used by the AVX-512 compress, the cyclic
# index vector and the unaligned 16-byte load and store by the NEON pattern copy, and the
# non-temporal-store fence by the bulk copy. On a machine without those paths no test
# reaches them, and each is plain Mojo that runs anywhere: these tests call them directly,
# with values built at run time, and check what they return.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_simd.compress import _bool_mask_to_u16, _bool_mask_to_u8, _popcount_mask
from komira_simd.fast_copy import nt_release_fence
from komira_simd.pattern_copy import _cyclic_mask_16, _load_u8x16_unaligned, _store_u8x16_unaligned


def _lanes(n: Int, pattern: Int) -> List[Bool]:
    """`n` lanes, lane k set when bit k of `pattern` is."""
    var out = List[Bool]()
    for k in range(n):
        out.append(((pattern >> k) & 1) == 1)
    return out^


def _mask8(pattern: Int) -> SIMD[DType.bool, 8]:
    var m = SIMD[DType.bool, 8](fill=False)
    var l = _lanes(8, pattern)
    for k in range(8):
        m[k] = l[k]
    return m


def _mask16(pattern: Int) -> SIMD[DType.bool, 16]:
    var m = SIMD[DType.bool, 16](fill=False)
    var l = _lanes(16, pattern)
    for k in range(16):
        m[k] = l[k]
    return m


def test_a_bool_mask_packs_to_a_bitmask_with_lane_0_lowest() raises:
    for p in [0, 1, 0x80, 0xA5, 0xFF]:
        assert_equal(Int(_bool_mask_to_u8[8](_mask8(p))), p)
    for p in [0, 1, 0x8000, 0xA5A5, 0xFFFF, 0x0100]:
        assert_equal(Int(_bool_mask_to_u16[16](_mask16(p))), p)
    # Only the first up-to-8 lanes of a narrower mask are read.
    var m4 = SIMD[DType.bool, 4](fill=False)
    m4[1] = True
    m4[3] = True
    assert_equal(Int(_bool_mask_to_u8[4](m4)), 0b1010)


def test_the_popcount_of_a_mask_is_its_set_lanes() raises:
    for p in [0, 1, 0xA5, 0xFF]:
        var want = 0
        for k in range(8):
            want += (p >> k) & 1
        assert_equal(Int(_popcount_mask(_mask8(p))), want)
    assert_equal(Int(_popcount_mask(_mask16(0xFFFF))), 16)


def test_the_cyclic_index_vector_repeats_with_its_period() raises:
    var a = _cyclic_mask_16[3, 0]()
    var b = _cyclic_mask_16[3, 5]()
    var c = _cyclic_mask_16[15, 14]()
    for k in range(16):
        assert_equal(Int(a[k]), k % 3)
        assert_equal(Int(b[k]), (5 + k) % 3)
        assert_equal(Int(c[k]), (14 + k) % 15)


def test_an_unaligned_16_byte_store_is_read_back_by_the_load() raises:
    var buf = List[UInt8]()
    for _ in range(40):
        buf.append(0)
    var v = SIMD[DType.uint8, 16](0)
    for k in range(16):
        v[k] = UInt8(k * 3 + 1)
    # At an offset that is not 16-aligned.
    _store_u8x16_unaligned(buf.unsafe_ptr() + 5, v)
    var back = _load_u8x16_unaligned(buf.unsafe_ptr() + 5)
    for k in range(16):
        assert_equal(Int(back[k]), k * 3 + 1)
    assert_equal(Int(buf[4]), 0)
    assert_equal(Int(buf[21]), 0)


def test_the_nt_fence_returns_and_leaves_memory_as_written() raises:
    var buf = List[UInt8]()
    for _ in range(8):
        buf.append(7)
    nt_release_fence()
    assert_equal(Int(buf[3]), 7)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
