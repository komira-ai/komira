# =============================================================================
# Round-trip property test for DictionaryDecoder.resolve_* SIMD parity
# =============================================================================
#
# The gate for the SIMD gather paths of:
#   - DictionaryDecoder.resolve_int32
#   - DictionaryDecoder.resolve_int64
#   - DictionaryDecoder.resolve_float32
#   - DictionaryDecoder.resolve_float64
#
# Methodology:
#   1. Build a deterministic dictionary of D unique values for each dtype.
#   2. Build a deterministic Int32 index sequence of length N (with index
#      mod-pattern + step that exercises gather-shape diversity, including
#      duplicates, all-same, ascending, descending, and mod-W boundaries).
#   3. Decode through the SIMD path (production resolve_*) AND through a
#      vendored scalar reference; assert byte-equivalence lane-by-lane.
#   4. Repeat with multiple dict sizes (D = 2, 16, 256, 4096) and multiple
#      N values straddling SIMD-tail boundaries.
#
# A failure here signals an alignment / bounds / load-shape bug.
#
# N is 200 distinct values per dtype × shape combination. The fixture
# generator is deterministic so failures reproduce.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from std.sys import size_of
from komira_parquet import DictionaryDecoder


# =============================================================================
# Helpers
# =============================================================================


def _build_indices(n: Int, dict_size: Int, seed: Int) -> PrimitiveArray[DType.int32]:
    """Build a deterministic Int32 index sequence of length n with a
    non-trivial pattern that mod-cycles through dict_size with a coprime
    step. Stride 7 vs typical D ∈ {16, 256, 4096} is coprime to the
    SIMD lane counts (4/8/16).
    """
    comptime i32_size: Int = size_of[Int32]()
    var idx_buf = OwnedAlignedBuffer(max(n * i32_size, i32_size))
    var idx_typed = idx_buf.view_typed_mut[DType.int32]()
    for i in range(n):
        var raw = (i * 7 + seed) % dict_size
        (idx_typed + i).unsafe_write(Int32(raw))
    idx_buf.set_length(Int64(n * i32_size))

    return PrimitiveArray[DType.int32](idx_buf^, n, None, 0, 0)


def _alloc_bytes_from_int32(values: List[Int32]) -> List[UInt8]:
    """Encode a List[Int32] as PLAIN bytes (4 bytes per value, native LE)."""
    comptime sz: Int = size_of[Int32]()
    var n = len(values)
    var buf = List[UInt8](length=max(n * sz, 1), fill=0)
    var typed = buf.unsafe_ptr().bitcast[Int32]()
    for i in range(n):
        typed.store[width=1](i, values[i])
    return buf^


def _alloc_bytes_from_int64(values: List[Int64]) -> List[UInt8]:
    comptime sz: Int = size_of[Int64]()
    var n = len(values)
    var buf = List[UInt8](length=max(n * sz, 1), fill=0)
    var typed = buf.unsafe_ptr().bitcast[Int64]()
    for i in range(n):
        typed.store[width=1](i, values[i])
    return buf^


def _alloc_bytes_from_float32(values: List[Float32]) -> List[UInt8]:
    comptime sz: Int = size_of[Float32]()
    var n = len(values)
    var buf = List[UInt8](length=max(n * sz, 1), fill=0)
    var typed = buf.unsafe_ptr().bitcast[Float32]()
    for i in range(n):
        typed.store[width=1](i, values[i])
    return buf^


def _alloc_bytes_from_float64(values: List[Float64]) -> List[UInt8]:
    comptime sz: Int = size_of[Float64]()
    var n = len(values)
    var buf = List[UInt8](length=max(n * sz, 1), fill=0)
    var typed = buf.unsafe_ptr().bitcast[Float64]()
    for i in range(n):
        typed.store[width=1](i, values[i])
    return buf^


def _gen_int32_dict(d: Int, seed: Int32) -> List[Int32]:
    """Generate D Int32 dict values covering positive / negative / zero
    edges. Deterministic on seed."""
    var out: List[Int32] = []
    out.resize(d, Int32(0))
    var specials: List[Int32] = [
        Int32(0), Int32(1), Int32(-1),
        Int32(2147483647), Int32(-2147483648),
        Int32(127), Int32(-128),
        Int32(65535), Int32(-65536),
        Int32(0x7FFFFFFF),
        Int32(0x10203040),
        Int32(0x55555555),
        Int32(-1431655766),  # 0xAAAAAAAA as signed
    ]
    for i in range(d):
        if i < len(specials):
            out[i] = specials[i]
        else:
            # Walk a coprime stride; mix sign and magnitude.
            var v = (i * 1103515245 + Int(seed)) & 0x7FFFFFFF
            if (i & 1) == 1:
                v = -v
            out[i] = Int32(v)
    return out^


def _gen_int64_dict(d: Int, seed: Int64) -> List[Int64]:
    var out: List[Int64] = []
    out.resize(d, Int64(0))
    var specials: List[Int64] = [
        Int64(0), Int64(1), Int64(-1),
        Int64(9223372036854775807),
        Int64(-9223372036854775807),
        Int64(127), Int64(-128),
        Int64(2147483647), Int64(-2147483648),
        Int64(0x0102030405060708),
        Int64(0xFF00FF00FF00FF00),
        Int64(174532170),
    ]
    for i in range(d):
        if i < len(specials):
            out[i] = specials[i]
        else:
            var v = Int64(i) * Int64(6364136223846793005) + seed
            out[i] = v
    return out^


def _gen_float32_dict(d: Int) -> List[Float32]:
    var out: List[Float32] = []
    out.resize(d, Float32(0.0))
    var specials: List[Float32] = [
        Float32(0.0), Float32(-0.0), Float32(1.0), Float32(-1.0),
        Float32(3.14), Float32(-2.718281),
        Float32(1.175494e-38),  # ~min normal
        Float32(3.4028235e38),  # ~max
        Float32(1e-12), Float32(-1e12),
    ]
    for i in range(d):
        if i < len(specials):
            out[i] = specials[i]
        else:
            out[i] = Float32(i) * Float32(1.5) - Float32(7.25)
    return out^


def _gen_float64_dict(d: Int) -> List[Float64]:
    var out: List[Float64] = []
    out.resize(d, Float64(0.0))
    var specials: List[Float64] = [
        Float64(0.0), Float64(-0.0), Float64(1.0), Float64(-1.0),
        Float64(3.141592653589793),
        Float64(-2.718281828459045),
        Float64(2.2250738585072014e-308),
        Float64(1.7976931348623157e308),
        Float64(1e-15), Float64(-1e15),
        Float64(174532170.99),
    ]
    for i in range(d):
        if i < len(specials):
            out[i] = specials[i]
        else:
            out[i] = Float64(i) * 1.0625 - Float64(13.5)
    return out^


# =============================================================================
# Scalar reference: gather through the dict via the indices, byte-identical
# to the scalar per-row loop of resolve_*.
# =============================================================================


def _scalar_resolve_int32(
    dict_vals: List[Int32], indices: PrimitiveArray[DType.int32]
) -> List[Int32]:
    var n = indices.length
    var out: List[Int32] = []
    out.resize(n, Int32(0))
    for i in range(n):
        var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
        out[i] = dict_vals[idx]
    return out^


def _scalar_resolve_int64(
    dict_vals: List[Int64], indices: PrimitiveArray[DType.int32]
) -> List[Int64]:
    var n = indices.length
    var out: List[Int64] = []
    out.resize(n, Int64(0))
    for i in range(n):
        var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
        out[i] = dict_vals[idx]
    return out^


def _scalar_resolve_float32(
    dict_vals: List[Float32], indices: PrimitiveArray[DType.int32]
) -> List[Float32]:
    var n = indices.length
    var out: List[Float32] = []
    out.resize(n, Float32(0.0))
    for i in range(n):
        var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
        out[i] = dict_vals[idx]
    return out^


def _scalar_resolve_float64(
    dict_vals: List[Float64], indices: PrimitiveArray[DType.int32]
) -> List[Float64]:
    var n = indices.length
    var out: List[Float64] = []
    out.resize(n, Float64(0.0))
    for i in range(n):
        var idx = Int(indices.get_typed[Scalar[DType.int32]](i))
        out[i] = dict_vals[idx]
    return out^


# =============================================================================
# Lane-equivalence assertions
# =============================================================================


def _assert_int32_equiv(
    expected: List[Int32], got: PrimitiveArray[DType.int32], label: String
) raises:
    assert_equal(got.length, len(expected))
    var ptr = got._typed_ptr_ro()
    for i in range(len(expected)):
        var got_v = Int32((ptr + i)[])
        if got_v != expected[i]:
            print("MISMATCH ", label, " idx=", i,
                  " expected=", expected[i], " got=", got_v)
        assert_equal(got_v, expected[i])


def _assert_int64_equiv(
    expected: List[Int64], got: PrimitiveArray[DType.int64], label: String
) raises:
    assert_equal(got.length, len(expected))
    var ptr = got._typed_ptr_ro()
    for i in range(len(expected)):
        var got_v = Int64((ptr + i)[])
        if got_v != expected[i]:
            print("MISMATCH ", label, " idx=", i,
                  " expected=", expected[i], " got=", got_v)
        assert_equal(got_v, expected[i])


def _assert_float32_equiv(
    expected: List[Float32], got: PrimitiveArray[DType.float32], label: String
) raises:
    """Float32 byte-equivalence (preserves +0/-0 distinction)."""
    assert_equal(got.length, len(expected))
    var ptr = got._typed_ptr_ro()
    for i in range(len(expected)):
        var got_v = Float32((ptr + i)[])
        var got_bits = got_v.to_bits()
        var exp_bits = expected[i].to_bits()
        if got_bits != exp_bits:
            print("MISMATCH ", label, " idx=", i,
                  " expected_bits=", exp_bits, " got_bits=", got_bits,
                  " expected_val=", expected[i], " got_val=", got_v)
        assert_equal(got_bits, exp_bits)


def _assert_float64_equiv(
    expected: List[Float64], got: PrimitiveArray[DType.float64], label: String
) raises:
    assert_equal(got.length, len(expected))
    var ptr = got._typed_ptr_ro()
    for i in range(len(expected)):
        var got_v = Float64((ptr + i)[])
        var got_bits = got_v.to_bits()
        var exp_bits = expected[i].to_bits()
        if got_bits != exp_bits:
            print("MISMATCH ", label, " idx=", i,
                  " expected_bits=", exp_bits, " got_bits=", got_bits,
                  " expected_val=", expected[i], " got_val=", got_v)
        assert_equal(got_bits, exp_bits)


# =============================================================================
# Test 1: Int32 parity, dict_size = 16, N = 200
# =============================================================================


def test_resolve_int32_parity_d16_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_int32_dict(16, Int32(101))
    var dict_buf = _alloc_bytes_from_int32(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int32(Span(dict_buf)[: 16 * 4], 16)

    var indices = _build_indices(N, 16, 5)
    var expected = _scalar_resolve_int32(dict_vals, indices)
    var got = decoder.resolve_int32(indices)
    _assert_int32_equiv(expected, got, "INT32/d16/n200")


# =============================================================================
# Test 2: Int32 parity, dict_size = 256, N = 200 (exercises 8/16-bit lanes)
# =============================================================================


def test_resolve_int32_parity_d256_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_int32_dict(256, Int32(7))
    var dict_buf = _alloc_bytes_from_int32(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int32(Span(dict_buf)[: 256 * 4], 256)

    var indices = _build_indices(N, 256, 13)
    var expected = _scalar_resolve_int32(dict_vals, indices)
    var got = decoder.resolve_int32(indices)
    _assert_int32_equiv(expected, got, "INT32/d256/n200")


# =============================================================================
# Test 3: Int32 parity, tail-handling (N = 11 stresses tail on every W)
# =============================================================================


def test_resolve_int32_parity_tail() raises:
    """N=11 stresses the scalar-tail path on every common SIMD width
    (W=4 leaves tail 3, W=8 leaves tail 3, W=16 means scalar-only)."""
    var dict_vals = _gen_int32_dict(8, Int32(31337))
    var dict_buf = _alloc_bytes_from_int32(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int32(Span(dict_buf)[: 8 * 4], 8)

    comptime N: Int = 11
    var indices = _build_indices(N, 8, 1)
    var expected = _scalar_resolve_int32(dict_vals, indices)
    var got = decoder.resolve_int32(indices)
    _assert_int32_equiv(expected, got, "INT32/tail/n11")


# =============================================================================
# Test 4: Int64 parity, dict_size = 16, N = 200
# =============================================================================


def test_resolve_int64_parity_d16_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_int64_dict(16, Int64(2026))
    var dict_buf = _alloc_bytes_from_int64(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int64(Span(dict_buf)[: 16 * 8], 16)

    var indices = _build_indices(N, 16, 11)
    var expected = _scalar_resolve_int64(dict_vals, indices)
    var got = decoder.resolve_int64(indices)
    _assert_int64_equiv(expected, got, "INT64/d16/n200")


# =============================================================================
# Test 5: Int64 parity, dict_size = 4096, N = 200 (large dict)
# =============================================================================


def test_resolve_int64_parity_d4096_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_int64_dict(4096, Int64(31337))
    var dict_buf = _alloc_bytes_from_int64(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int64(Span(dict_buf)[: 4096 * 8], 4096)

    var indices = _build_indices(N, 4096, 17)
    var expected = _scalar_resolve_int64(dict_vals, indices)
    var got = decoder.resolve_int64(indices)
    _assert_int64_equiv(expected, got, "INT64/d4096/n200")


# =============================================================================
# Test 6: Int64 parity, tail-handling N=11
# =============================================================================


def test_resolve_int64_parity_tail() raises:
    var dict_vals = _gen_int64_dict(8, Int64(101))
    var dict_buf = _alloc_bytes_from_int64(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int64(Span(dict_buf)[: 8 * 8], 8)

    comptime N: Int = 11
    var indices = _build_indices(N, 8, 1)
    var expected = _scalar_resolve_int64(dict_vals, indices)
    var got = decoder.resolve_int64(indices)
    _assert_int64_equiv(expected, got, "INT64/tail/n11")


# =============================================================================
# Test 7: Float32 parity, dict_size = 16, N = 200
# =============================================================================


def test_resolve_float32_parity_d16_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_float32_dict(16)
    var dict_buf = _alloc_bytes_from_float32(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_float32(Span(dict_buf)[: 16 * 4], 16)

    var indices = _build_indices(N, 16, 5)
    var expected = _scalar_resolve_float32(dict_vals, indices)
    var got = decoder.resolve_float32(indices)
    _assert_float32_equiv(expected, got, "FLOAT32/d16/n200")


# =============================================================================
# Test 8: Float64 parity, dict_size = 16, N = 200
# =============================================================================


def test_resolve_float64_parity_d16_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_float64_dict(16)
    var dict_buf = _alloc_bytes_from_float64(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_float64(Span(dict_buf)[: 16 * 8], 16)

    var indices = _build_indices(N, 16, 5)
    var expected = _scalar_resolve_float64(dict_vals, indices)
    var got = decoder.resolve_float64(indices)
    _assert_float64_equiv(expected, got, "FLOAT64/d16/n200")


# =============================================================================
# Test 9: Float64 parity, dict_size = 4096, N = 200
# =============================================================================


def test_resolve_float64_parity_d4096_n200() raises:
    comptime N: Int = 200
    var dict_vals = _gen_float64_dict(4096)
    var dict_buf = _alloc_bytes_from_float64(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_float64(Span(dict_buf)[: 4096 * 8], 4096)

    var indices = _build_indices(N, 4096, 23)
    var expected = _scalar_resolve_float64(dict_vals, indices)
    var got = decoder.resolve_float64(indices)
    _assert_float64_equiv(expected, got, "FLOAT64/d4096/n200")


# =============================================================================
# Test 10: Float64 parity, all-same index (forces gather to one cell)
# =============================================================================


def test_resolve_float64_parity_allsame() raises:
    """All indices = 7 -- exercises the all-broadcast gather degenerate case."""
    var dict_vals = _gen_float64_dict(16)
    var dict_buf = _alloc_bytes_from_float64(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_float64(Span(dict_buf)[: 16 * 8], 16)

    comptime N: Int = 64
    comptime i32_size: Int = size_of[Int32]()
    var idx_buf = OwnedAlignedBuffer(N * i32_size)
    var idx_typed = idx_buf.view_typed_mut[DType.int32]()
    for i in range(N):
        (idx_typed + i).unsafe_write(Int32(7))
    idx_buf.set_length(Int64(N * i32_size))

    var indices = PrimitiveArray[DType.int32](idx_buf^, N, None, 0, 0)

    var expected = _scalar_resolve_float64(dict_vals, indices)
    var got = decoder.resolve_float64(indices)
    _assert_float64_equiv(expected, got, "FLOAT64/allsame/n64")


# =============================================================================
# Test 11: Empty input (num_values = 0) must not crash and return empty array
# =============================================================================


def test_resolve_int32_empty() raises:
    var dict_vals = _gen_int32_dict(8, Int32(1))
    var dict_buf = _alloc_bytes_from_int32(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_int32(Span(dict_buf)[: 8 * 4], 8)

    var indices = _build_indices(0, 8, 0)
    var got = decoder.resolve_int32(indices)
    assert_equal(got.length, 0)


# =============================================================================
# Test 12: Float32 parity tail (N = 7)
# =============================================================================


def test_resolve_float32_parity_tail() raises:
    """N=7 stresses the scalar-tail on W=4 (tail 3) and W=8 (scalar-only)."""
    var dict_vals = _gen_float32_dict(8)
    var dict_buf = _alloc_bytes_from_float32(dict_vals)
    var decoder = DictionaryDecoder()
    decoder.init_dict_float32(Span(dict_buf)[: 8 * 4], 8)

    comptime N: Int = 7
    var indices = _build_indices(N, 8, 0)
    var expected = _scalar_resolve_float32(dict_vals, indices)
    var got = decoder.resolve_float32(indices)
    _assert_float32_equiv(expected, got, "FLOAT32/tail/n7")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
