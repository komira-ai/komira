# =============================================================================
# Round-trip property test for FLBA decimal SIMD parity
# =============================================================================
#
# HARD GATE for `decode_plain_flba_decimal_to_float64`'s SIMD path
# (`plain_flba.mojo:_decode_flba16_simd_chunk` / `_decode_flba8_simd_chunk`) and
# the dict-resolve sibling
# (`dictionary.mojo:DictionaryDecoder.resolve_flba_decimal_to_float64`).
#
# Methodology:
#   1. Generate a deterministic stream of mixed-sign Int64 values covering
#      positive / negative / zero / Int64-near-extremes.
#   2. Encode each Int64 as `width`-byte BE two's-complement bytes with a
#      local `_encode_int_be` helper.
#   3. Decode the resulting buffer through the SIMD path AND through a
#      pure-scalar reference (a copy of the scalar loop body)
#      and compare lane-by-lane via Float64 byte-equivalence.
#   4. Repeat for FLBA(16) and FLBA(8) at scales 0, 2, 6.
#
# A failure here signals a bswap / sign-extension / load-misalignment bug.
#
# N is 200 distinct values per width × scale combination. The fixture
# generator is deterministic so failures reproduce.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from std.sys import size_of
from komira_parquet import (
    decode_plain_flba_decimal_to_float64,
    DictionaryDecoder,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


# =============================================================================
# Helpers — re-implemented locally so the file is self-contained and
# the scalar reference is decoupled from any future refactor of the
# production `_flba_value_to_int64_be` helper.
# =============================================================================


def _encode_int_be(value: Int64, width: Int) -> List[UInt8]:
    """Encode a signed Int64 as `width` big-endian two's-complement bytes.

    For width >= 8 the low
    8 bytes carry the Int64 bit pattern and the upper width-8 bytes are
    sign extension (0xFF for negatives, 0x00 for non-negatives). For
    width < 8 the low `width` bytes carry the bit pattern and there is no
    upper-byte sign extension (the decoder reconstructs sign from the
    MSB of byte 0).
    """
    var result: List[UInt8] = []
    result.resize(width, UInt8(0))
    var uv = UInt64(value)
    var is_negative = value < Int64(0)
    var sign_fill = UInt8(0xFF) if is_negative else UInt8(0x00)

    var low_bytes = width if width < 8 else 8
    for i in range(low_bytes):
        var byte_pos = width - 1 - i
        result[byte_pos] = UInt8(Int((uv >> UInt64(i * 8)) & UInt64(0xFF)))

    if width > 8:
        for i in range(width - 8):
            result[i] = sign_fill

    return result^


# Scalar reference: the scalar `_flba_value_to_int64_be`
# body, vendored here so the parity test compares against a body that
# CANNOT be silently changed by a future plain_flba.mojo edit. If this scalar
# reference disagrees with `decode_plain_flba_decimal_to_float64`'s SIMD
# output even on a single sample, the SIMD body is wrong.
def _scalar_flba_value_to_int64_be[
    mut: Bool, //, o: Origin[mut=mut]
](data: UnsafePointer[UInt8, o], type_length: Int) -> Int64:
    if type_length <= 0:
        return Int64(0)
    var sign_byte = Int(data[])
    var is_negative = (sign_byte & 0x80) != 0
    if type_length >= 8:
        var base = data + (type_length - 8)
        var result = UInt64(0)
        for i in range(8):
            result = (result << 8) | UInt64(Int((base + i)[]))
        return Int64(result)
    var result_u = UInt64(0)
    for i in range(type_length):
        result_u = (result_u << 8) | UInt64(Int((data + i)[]))
    if is_negative:
        var shift = UInt64(type_length * 8)
        var mask = UInt64(0xFFFFFFFFFFFFFFFF) << shift
        result_u = result_u | mask
    return Int64(result_u)


def _scalar_decode_reference(
    data_list: List[UInt8],
    num_values: Int,
    type_length: Int,
    scale: Int,
) -> List[Float64]:
    """Pure-scalar reference decode for FLBA decimal -> Float64.

    Implementation is byte-identical to the scalar (pre-SIMD) hot loop
    in `decode_plain_flba_decimal_to_float64`. Returns a List[Float64] of
    the decoded values for direct lane-vs-lane comparison.
    """
    var divisor = Float64(1.0)
    for _ in range(scale):
        divisor = divisor * Float64(10.0)
    var inv_divisor = Float64(1.0) / divisor

    var buf = data_list.unsafe_ptr()

    var out: List[Float64] = []
    out.resize(num_values, Float64(0.0))
    for i in range(num_values):
        var value_ptr = buf + i * type_length
        var as_int = _scalar_flba_value_to_int64_be(value_ptr, type_length)
        out[i] = Float64(as_int) * inv_divisor

    return out^


def _gen_value_set(n: Int, seed_offset: Int64) -> List[Int64]:
    """Generate a deterministic Int64 stream covering the full sign /
    magnitude space.

    Layout (mod-pattern keeps generation hot-spot-free):
      - 1/5 small positive (0..1000)
      - 1/5 small negative (-1000..0)
      - 1/5 large positive (10^15..2^62)
      - 1/5 large negative (-2^62..-10^15)
      - 1/5 special: 0, ±1, ±Int64-extremes, ±10^k

    All values fit in Int64 (precondition for the FLBA(16) low-8-byte
    fast path). `seed_offset` is added to mid-magnitude buckets so
    different test runs explore different exact bit patterns.
    """
    var out: List[Int64] = []
    out.resize(n, Int64(0))
    var specials: List[Int64] = [
        Int64(0),
        Int64(1),
        Int64(-1),
        Int64(9223372036854775807),       # Int64.MAX
        Int64(-9223372036854775807),      # Int64.MIN + 1
        Int64(1000000000000000),          # 10^15
        Int64(-1000000000000000),
        Int64(127),                       # MSB-of-byte-0 boundary
        Int64(-128),
        Int64(255),                       # 1-byte rollover
        Int64(-256),
        Int64(65535),                     # 2-byte rollover
        Int64(-65536),
        Int64(2147483647),                # Int32.MAX
        Int64(-2147483648),               # Int32.MIN
        Int64(4294967295),                # UInt32.MAX (sign-bit set in i32)
        Int64(-4294967295),
        Int64(8589934592),                # 2^33
        Int64(-8589934592),
        Int64(174532170),                 # a TPC-H revenue magnitude
    ]
    for i in range(n):
        var bucket = i % 5
        if bucket == 0:
            out[i] = Int64(i + 1) + seed_offset
        elif bucket == 1:
            out[i] = -(Int64(i + 1) + seed_offset)
        elif bucket == 2:
            out[i] = Int64(1000000000000000) + Int64(i) * Int64(7919) + seed_offset
        elif bucket == 3:
            out[i] = -(Int64(1000000000000000) + Int64(i) * Int64(7919) + seed_offset)
        else:
            out[i] = specials[i % len(specials)]
    return out^


def _f64_bits(v: Float64) -> UInt64:
    """Return the IEEE 754 bit pattern of a Float64 for byte-equivalence
    comparison. Two values that are identical at the bit level (incl.
    +0.0 vs -0.0) compare equal under `_f64_bits`."""
    return UInt64(from_bits=Scalar[DType.uint64](v.cast[DType.float64]().to_bits()))


def _assert_lane_equivalent(
    expected: List[Float64],
    got_arr: PrimitiveArray[DType.float64],
    label: String,
) raises:
    """Assert that the SIMD output matches the scalar reference lane-by-lane.

    For DECIMAL the expected exact-Float64 representation may differ from
    the scalar reference's by 0 ULP (since both paths produce
    `Float64(int_be) * inv_divisor` with the SAME `inv_divisor` Float64
    rounding). So byte-equivalence (`to_bits() == to_bits()`) is the
    correct gate, NOT an epsilon check. Any disagreement here means the
    SIMD path computed a different Int64 than the scalar -- a bswap / sign
    / endian bug.
    """
    assert_equal(got_arr.length, len(expected))
    for i in range(len(expected)):
        var got_v = Float64(got_arr.get(i))
        var got_bits = got_v.to_bits()
        var exp_bits = expected[i].to_bits()
        if got_bits != exp_bits:
            print(
                "MISMATCH ", label, " idx=", i,
                " expected_bits=", exp_bits, " got_bits=", got_bits,
                " expected_val=", expected[i], " got_val=", got_v,
            )
        assert_equal(got_bits, exp_bits)


# =============================================================================
# Test 1: FLBA(16) parity at scale 2 (the TPC-H lineitem hot case)
# =============================================================================


def test_flba16_simd_parity_scale_2() raises:
    """SIMD vs scalar reference, FLBA(16), scale=2, N=200.

    DuckDB writes DECIMAL(P>=19, S=2) as FLBA(16). l_extendedprice and
    other TPC-H DECIMAL columns hit this exact shape.
    """
    comptime N: Int = 200
    var values = _gen_value_set(N, Int64(101))
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 16)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 16, 2)

    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 16, 2)
    _assert_lane_equivalent(expected, got, "FLBA16/scale2")


# =============================================================================
# Test 2: FLBA(16) parity at scale 0 (integer-valued DECIMAL)
# =============================================================================


def test_flba16_simd_parity_scale_0() raises:
    comptime N: Int = 200
    var values = _gen_value_set(N, Int64(7))
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 16)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 16, 0)

    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 16, 0)
    _assert_lane_equivalent(expected, got, "FLBA16/scale0")


# =============================================================================
# Test 3: FLBA(16) parity at scale 6 (high-precision fractional)
# =============================================================================


def test_flba16_simd_parity_scale_6() raises:
    comptime N: Int = 200
    var values = _gen_value_set(N, Int64(31337))
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 16)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 16, 6)

    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 16, 6)
    _assert_lane_equivalent(expected, got, "FLBA16/scale6")


# =============================================================================
# Test 4: FLBA(8) parity at scale 2 (DECIMAL(P<=18) FLBA-form)
# =============================================================================


def test_flba8_simd_parity_scale_2() raises:
    comptime N: Int = 200
    var values = _gen_value_set(N, Int64(2026))
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 8)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 8, 2)

    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 8, 2)
    _assert_lane_equivalent(expected, got, "FLBA8/scale2")


# =============================================================================
# Test 5: FLBA(8) parity at scale 0
# =============================================================================


def test_flba8_simd_parity_scale_0() raises:
    comptime N: Int = 200
    var values = _gen_value_set(N, Int64(1))
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 8)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 8, 0)

    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 8, 0)
    _assert_lane_equivalent(expected, got, "FLBA8/scale0")


# =============================================================================
# Test 6: Tail handling — N not a multiple of SIMD width
# =============================================================================
#
# SIMD width on Float64: NEON 2 / AVX2 4 / AVX-512 8. Pick N values where
# every plausible W leaves a non-zero tail: N = 11 covers the W=2/4/8
# cases (tails 1/3/3 respectively).


def test_flba16_simd_parity_tail_handling() raises:
    """N=11 stresses the scalar-tail path on every common SIMD width."""
    var values: List[Int64] = [
        Int64(0), Int64(1), Int64(-1),
        Int64(127), Int64(-128),
        Int64(2147483647), Int64(-2147483648),
        Int64(4294967295), Int64(-4294967295),
        Int64(174532170), Int64(-9223372036854775807),
    ]
    var N = len(values)
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 16)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 16, 2)
    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 16, 2)
    _assert_lane_equivalent(expected, got, "FLBA16/tail-N=11")


# =============================================================================
# Test 7: Dict-resolve SIMD parity (FLBA(16))
# =============================================================================
#
# Same shape as the PLAIN path but the per-row load is gathered through
# `idx[i]`. Verifies that `DictionaryDecoder.resolve_flba_decimal_to_float64`
# produces the byte-identical Float64 output to the scalar reference under
# a non-trivial index sequence.


def test_flba16_dict_simd_parity_scale_2() raises:
    """Dict-resolve parity test: 16 unique dict values, 200-row index seq."""
    # Build dict: 16 unique values from the generator stream.
    var dict_values = _gen_value_set(16, Int64(42))
    var dict_bytes: List[UInt8] = []
    for v in dict_values:
        var bytes = _encode_int_be(v, 16)
        for b in bytes:
            dict_bytes.append(b)
    var decoder = DictionaryDecoder()
    decoder.init_dict_fixed_len_byte_array(Span(dict_bytes), 16, 16)

    # Build an index sequence -- 200 rows, mod 16 with a +3 step to avoid
    # trivial pattern-of-1.
    comptime N: Int = 200
    comptime i32_size: Int = size_of[Int32]()
    var idx_buf = OwnedAlignedBuffer(N * i32_size)
    var idx_typed = idx_buf.view_typed_mut[DType.int32]()
    for i in range(N):
        (idx_typed + i).unsafe_write(Int32((i * 3 + 5) % 16))
    idx_buf.set_length(Int64(N * i32_size))

    var indices = PrimitiveArray[DType.int32](idx_buf^, N, None, 0, 0)

    # Build the expected output by gathering through the same index seq
    # and running the scalar reference per-row.
    var expected: List[Float64] = []
    expected.resize(N, Float64(0.0))
    var inv_div = Float64(1.0) / Float64(100.0)  # scale=2
    for i in range(N):
        var idx = (i * 3 + 5) % 16
        # Replicate the reference scalar gather through dict_bytes.
        var slice_start = idx * 16
        var as_int = _scalar_flba_value_to_int64_be(dict_bytes.unsafe_ptr() + slice_start, 16)
        expected[i] = Float64(as_int) * inv_div

    var got = decoder.resolve_flba_decimal_to_float64(indices, 2)
    _assert_lane_equivalent(expected, got, "FLBA16-DICT/scale2")


# =============================================================================
# Test 8: Bswap correctness on adversarial bit patterns
# =============================================================================
#
# Targets the bswap path with values that have asymmetric byte patterns
# (one 0xFF byte, one zero byte, one byte with the MSB set, etc.). If
# the SIMD bswap shifts/masks are wrong, these patterns will misdecode in
# specific bytes that all-ones / all-zeros patterns would hide.


def test_flba16_simd_bswap_adversarial() raises:
    """Adversarial byte patterns -- forces every byte position to have a
    distinct sentinel so a wrong bswap mismatches at the offending byte."""
    var values: List[Int64] = [
        Int64(0x0102030405060708),
        Int64(0x1F2E3D4C5B6A7988),
        Int64(0x00FF00FF00FF00FF),
        Int64(0xFF00FF00FF00FF00),  # negative when interpreted as Int64
        Int64(0x7FFFFFFFFFFFFFFF),  # Int64.MAX
        Int64(0x8000000000000000),  # Int64.MIN
        Int64(0x123456789ABCDEF0),
        Int64(0x0FEDCBA987654321),
    ]
    var N = len(values)
    var encoded: List[UInt8] = []
    for v in values:
        var bytes = _encode_int_be(v, 16)
        for b in bytes:
            encoded.append(b)

    var expected = _scalar_decode_reference(encoded, N, 16, 0)
    var got = decode_plain_flba_decimal_to_float64(Span(encoded), N, 16, 0)
    _assert_lane_equivalent(expected, got, "FLBA16-adversarial-bytes")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
