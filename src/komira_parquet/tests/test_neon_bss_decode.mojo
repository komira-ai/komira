# =============================================================================
# test_neon_bss_decode.mojo — Correctness: SIMD BSS decode byte-matches scalar
# =============================================================================
#
# Verifies that the pure-Mojo SIMD decode path (byte_stream_split._simd_decode_f32/f64,
# reached through decode_byte_stream_split_float32/float64) produces bit-identical
# output to the scalar block-transpose path for:
#   - f32: small (8 values), block-aligned (64 values), large (128 values), tail (70 values)
#   - f64: small (4 values), block-aligned (16 values), large (32 values), tail (11 values)
#
# The tests build canonical encoded input with the test-local encoders below
# (the byte transpose the format defines), then compare SIMD decode (via
# decode_byte_stream_split_*) with the scalar block-transpose reference for
# byte-level correctness.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import bitcast
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet import (
    decode_byte_stream_split_float32,
    decode_byte_stream_split_float64,
)
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_parquet.byte_stream_split import _decode_byte_stream_split_impl


def _scalar_decode_f32[
    o: Origin[mut=True],
](data: UnsafePointer[UInt8, o], n: Int) -> PrimitiveArray[DType.float32]:
    """Scalar reference BSS decode for f32 — uses block transposition impl."""
    var byte_count = n * 4
    var buf = OwnedAlignedBuffer(byte_count)
    _decode_byte_stream_split_impl(data, n, 4, buf.view_typed_mut[DType.uint8]())
    buf.set_length(Int64(byte_count))
    return PrimitiveArray[DType.float32](buf^, n, None, 0, 0)


def _scalar_decode_f64[
    o: Origin[mut=True],
](data: UnsafePointer[UInt8, o], n: Int) -> PrimitiveArray[DType.float64]:
    """Scalar reference BSS decode for f64 — uses block transposition impl."""
    var byte_count = n * 8
    var buf = OwnedAlignedBuffer(byte_count)
    _decode_byte_stream_split_impl(data, n, 8, buf.view_typed_mut[DType.uint8]())
    buf.set_length(Int64(byte_count))
    return PrimitiveArray[DType.float64](buf^, n, None, 0, 0)


def _encode_f32(values: List[Scalar[DType.float32]]) -> List[UInt8]:
    """BYTE_STREAM_SPLIT encode: byte b of value i goes to stream b."""
    var n = len(values)
    var out = List[UInt8](capacity=n * 4)
    out.resize(n * 4, UInt8(0))
    for i in range(n):
        var u = bitcast[DType.uint32](values[i])
        for b in range(4):
            out[b * n + i] = UInt8((u >> UInt32(b * 8)) & 0xFF)
    return out^


def _encode_f64(values: List[Scalar[DType.float64]]) -> List[UInt8]:
    """BYTE_STREAM_SPLIT encode: byte b of value i goes to stream b."""
    var n = len(values)
    var out = List[UInt8](capacity=n * 8)
    out.resize(n * 8, UInt8(0))
    for i in range(n):
        var u = bitcast[DType.uint64](values[i])
        for b in range(8):
            out[b * n + i] = UInt8((u >> UInt64(b * 8)) & 0xFF)
    return out^


def _make_f32_values(n: Int) -> List[Scalar[DType.float32]]:
    var vals: List[Scalar[DType.float32]] = []
    for i in range(n):
        vals.append(Scalar[DType.float32](Float32(i) * 1.23456789 + 0.001))
    return vals^


def _make_f64_values(n: Int) -> List[Scalar[DType.float64]]:
    var vals: List[Scalar[DType.float64]] = []
    for i in range(n):
        vals.append(Scalar[DType.float64](Float64(i) * 1.23456789012345678 + 0.001))
    return vals^


def _f32_arrays_equal(a: PrimitiveArray[DType.float32], b: PrimitiveArray[DType.float32]) raises -> Bool:
    if a.length != b.length:
        return False
    for i in range(a.length):
        if a.get(i) != b.get(i):
            return False
    return True


def _f64_arrays_equal(a: PrimitiveArray[DType.float64], b: PrimitiveArray[DType.float64]) raises -> Bool:
    if a.length != b.length:
        return False
    for i in range(a.length):
        if a.get(i) != b.get(i):
            return False
    return True


# =============================================================================
# Float32 NEON vs scalar byte-match tests
# =============================================================================


def test_bss_f32_neon_vs_scalar_small() raises:
    """8 f32 values: NEON decode byte-matches scalar (sub-SIMD-chunk size)."""
    var values = _make_f32_values(8)
    var encoded = _encode_f32(values)

    var neon_result = decode_byte_stream_split_float32(Span(encoded), 8)
    var scalar_result = _scalar_decode_f32(encoded.unsafe_ptr(), 8)
    assert_true(_f32_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 8)


def test_bss_f32_neon_vs_scalar_64_values() raises:
    """64 f32 values: exactly 4 NEON iterations (16 values each), no tail."""
    var values = _make_f32_values(64)
    var encoded = _encode_f32(values)

    var neon_result = decode_byte_stream_split_float32(Span(encoded), 64)
    var scalar_result = _scalar_decode_f32(encoded.unsafe_ptr(), 64)
    assert_true(_f32_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 64)


def test_bss_f32_neon_vs_scalar_70_values() raises:
    """70 f32 values: 4 NEON iterations + 6-value scalar tail."""
    var values = _make_f32_values(70)
    var encoded = _encode_f32(values)

    var neon_result = decode_byte_stream_split_float32(Span(encoded), 70)
    var scalar_result = _scalar_decode_f32(encoded.unsafe_ptr(), 70)
    assert_true(_f32_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 70)


def test_bss_f32_neon_vs_scalar_128_values() raises:
    """128 f32 values: 8 NEON iterations, no tail."""
    var values = _make_f32_values(128)
    var encoded = _encode_f32(values)

    var neon_result = decode_byte_stream_split_float32(Span(encoded), 128)
    var scalar_result = _scalar_decode_f32(encoded.unsafe_ptr(), 128)
    assert_true(_f32_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 128)


# =============================================================================
# Float64 NEON vs scalar byte-match tests
# =============================================================================


def test_bss_f64_neon_vs_scalar_small() raises:
    """4 f64 values: NEON decode byte-matches scalar (sub-SIMD-chunk)."""
    var values = _make_f64_values(4)
    var encoded = _encode_f64(values)

    var neon_result = decode_byte_stream_split_float64(Span(encoded), 4)
    var scalar_result = _scalar_decode_f64(encoded.unsafe_ptr(), 4)
    assert_true(_f64_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 4)


def test_bss_f64_neon_vs_scalar_16_values() raises:
    """16 f64 values: 2 NEON iterations (8 values each), no tail."""
    var values = _make_f64_values(16)
    var encoded = _encode_f64(values)

    var neon_result = decode_byte_stream_split_float64(Span(encoded), 16)
    var scalar_result = _scalar_decode_f64(encoded.unsafe_ptr(), 16)
    assert_true(_f64_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 16)


def test_bss_f64_neon_vs_scalar_11_values() raises:
    """11 f64 values: 1 NEON iteration + 3-value scalar tail."""
    var values = _make_f64_values(11)
    var encoded = _encode_f64(values)

    var neon_result = decode_byte_stream_split_float64(Span(encoded), 11)
    var scalar_result = _scalar_decode_f64(encoded.unsafe_ptr(), 11)
    assert_true(_f64_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 11)


def test_bss_f64_neon_vs_scalar_32_values() raises:
    """32 f64 values: 4 NEON iterations, no tail."""
    var values = _make_f64_values(32)
    var encoded = _encode_f64(values)

    var neon_result = decode_byte_stream_split_float64(Span(encoded), 32)
    var scalar_result = _scalar_decode_f64(encoded.unsafe_ptr(), 32)
    assert_true(_f64_arrays_equal(neon_result, scalar_result))
    assert_equal(neon_result.length, 32)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
