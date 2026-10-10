# =============================================================================
# Parity test for `DictionaryDecoder.resolve_float64`.
#
# Validates the W=4 unrolled + prefetch-ahead implementation against a
# scalar reference for a battery of input shapes:
#   * exact multiples of W (4, 8, 16, 256) — main-loop-only
#   * non-multiples (1, 2, 3, 5, 7, 17, 1023) — exercises tail loop
#   * boundary indices (0 and dict_size-1) — covers prefetch edge cases
#   * randomized 100K-row case with mixed indices — broad coverage
#
# The SIMD path must produce bit-identical output
# vs the scalar reference for every input shape; a divergence here would
# silently corrupt the resolved column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet.dictionary import DictionaryDecoder


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _build_float64_dict_buf(values: List[Float64]) -> OwnedAlignedBuffer:
    """Build a PLAIN-encoded Float64 dictionary buffer (raw bytes, no Thrift)."""
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 8, 1))
    var ptr = buf.view_typed_mut[DType.float64]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(n * 8))
    return buf^


def _build_indices(values: List[Int32]) -> PrimitiveArray[DType.int32]:
    """Build a PrimitiveArray[DType.int32] of dictionary indices."""
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 4, 1))
    var ptr = buf.view_typed_mut[DType.int32]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(n * 4))
    return PrimitiveArray[DType.int32](buf^, n, None, 0, 0)


def _scalar_resolve_float64_reference(
    indices: PrimitiveArray[DType.int32], dict_values: List[Float64]
) -> List[Float64]:
    """Pure-scalar reference impl. The SIMD path must match this exactly."""
    var out = List[Float64]()
    var idx_ptr = indices._typed_ptr_ro()
    for i in range(indices.length):
        var idx = Int(idx_ptr[i])
        out.append(dict_values[idx])
    return out^


def _arr_to_list_float64(arr: PrimitiveArray[DType.float64]) -> List[Float64]:
    var out = List[Float64]()
    var ptr = arr._typed_ptr_ro()
    for i in range(arr.length):
        out.append(ptr[i])
    return out^


def _check_parity(
    indices_vals: List[Int32],
    dict_vals: List[Float64],
    label: String,
) raises:
    var dict_buf = _build_float64_dict_buf(dict_vals)
    var dict = DictionaryDecoder()
    dict.init_dict_float64(
        dict_buf.into_span_capacity()[: len(dict_vals) * 8],
        len(dict_vals),
    )
    _ = dict_buf^

    var indices = _build_indices(indices_vals)
    var got_arr = dict.resolve_float64(indices)
    var got = _arr_to_list_float64(got_arr)

    var expect = _scalar_resolve_float64_reference(indices, dict_vals)

    assert_equal(len(got), len(expect))
    for i in range(len(got)):
        # Bit-identity check via Float64 equality. Float64's repr is
        # IEEE 754 — a bit-mismatch produces a value-mismatch here.
        if Float64(got[i]) != Float64(expect[i]):
            print(label, "mismatch at i=", i, "got=", Float64(got[i]), "expect=", Float64(expect[i]))
        assert_true(Float64(got[i]) == Float64(expect[i]))


# ---------------------------------------------------------------------------
# Tests — each exercises a different num_values shape vs W=4 boundary
# ---------------------------------------------------------------------------


def test_resolve_float64_empty() raises:
    """num_values=0 — no main loop, no tail."""
    var idx_vals = List[Int32]()
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5)]
    _check_parity(idx_vals, dict_vals, String("empty"))


def test_resolve_float64_n1_tail_only() raises:
    """num_values=1 — main loop body skipped (simd_end=0); single tail iter."""
    var idx_vals: List[Int32] = [Int32(1)]
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n1_tail_only"))


def test_resolve_float64_n2_tail_only() raises:
    """num_values=2 — simd_end=0 still; 2 tail iters."""
    var idx_vals: List[Int32] = [Int32(0), Int32(2)]
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n2_tail_only"))


def test_resolve_float64_n3_tail_only() raises:
    """num_values=3 — simd_end=0; all 3 in tail."""
    var idx_vals: List[Int32] = [Int32(2), Int32(0), Int32(1)]
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n3_tail_only"))


def test_resolve_float64_n4_main_only() raises:
    """num_values=4 — exactly W=4; main loop only, no tail."""
    var idx_vals: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(0)]
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n4_main_only"))


def test_resolve_float64_n5_main_plus_1tail() raises:
    """num_values=5 — 1 main iter (4 rows) + 1 tail iter."""
    var idx_vals: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(0), Int32(1)]
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n5_main_plus_1tail"))


def test_resolve_float64_n7_main_plus_3tail() raises:
    """num_values=7 — 1 main iter (4 rows) + 3 tail iters."""
    var idx_vals: List[Int32] = [
        Int32(0), Int32(1), Int32(2), Int32(0),
        Int32(1), Int32(2), Int32(0),
    ]
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n7_main_plus_3tail"))


def test_resolve_float64_n16_main_only_under_pf_distance() raises:
    """num_values=16 — _DICT_PF_FLOAT64=16 so the PF check `i + 16 < 16`
    is False on every iteration; exercises the main loop without ever
    firing the prefetch."""
    var idx_vals = List[Int32]()
    for i in range(16):
        idx_vals.append(Int32(i % 3))
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n16_main_only_under_pf_distance"))


def test_resolve_float64_n17_main_plus_1tail_pf_fires_once() raises:
    """num_values=17 — prefetch fires exactly once (i=0, i+16=16<17 True);
    the rest of the main + 1 tail iter remain. Tightest PF-edge case."""
    var idx_vals = List[Int32]()
    for i in range(17):
        idx_vals.append(Int32(i % 3))
    var dict_vals: List[Float64] = [Float64(1.5), Float64(2.5), Float64(3.5)]
    _check_parity(idx_vals, dict_vals, String("n17_pf_fires_once"))


def test_resolve_float64_n256_main_only() raises:
    """num_values=256 — clean main loop, lots of prefetch firings."""
    var idx_vals = List[Int32]()
    var dict_vals = List[Float64]()
    for i in range(8):
        dict_vals.append(Float64(1000.5 + Float64(i)))
    for i in range(256):
        idx_vals.append(Int32(i % 8))
    _check_parity(idx_vals, dict_vals, String("n256_main_only"))


def test_resolve_float64_n1023_main_plus_3tail() raises:
    """num_values=1023 — 255 main iters (1020 rows) + 3 tail iters."""
    var idx_vals = List[Int32]()
    var dict_vals = List[Float64]()
    for i in range(64):
        dict_vals.append(Float64(10000.25 + Float64(i) * 7.5))
    for i in range(1023):
        idx_vals.append(Int32((i * 31) % 64))
    _check_parity(idx_vals, dict_vals, String("n1023_main_plus_3tail"))


def test_resolve_float64_n100k_random_pattern() raises:
    """num_values=100K. Mixed
    indices via a deterministic pseudo-random sequence; covers both
    cache-hot and cache-cold paths inside the dict."""
    var idx_vals = List[Int32]()
    var dict_vals = List[Float64]()
    for i in range(1024):
        dict_vals.append(Float64(i) * 3.14159 + 0.5)
    # Linear-congruential pseudo-random for deterministic test.
    var seed: UInt64 = 0xCAFEBABEDEADBEEF
    for _ in range(100000):
        seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        var idx = Int32(Int(seed >> 33) % 1024)
        idx_vals.append(idx)
    _check_parity(idx_vals, dict_vals, String("n100k_random"))


def test_resolve_float64_boundary_indices() raises:
    """Edge-of-dict indices (0 and dict_size-1) interleaved — ensures the
    prefetch address-gen on the boundary entries doesn't trip an OOB
    issue; prefetch is hint-only so even if pf_idx were OOB it would not
    trap, but this asserts the values are still correct."""
    var idx_vals = List[Int32]()
    var dict_vals = List[Float64]()
    for i in range(8):
        dict_vals.append(Float64(i) * 1000.0 + 0.25)
    # 32 rows: alternating 0 and 7 (dict_size-1).
    for i in range(32):
        idx_vals.append(Int32(0 if i % 2 == 0 else 7))
    _check_parity(idx_vals, dict_vals, String("boundary_indices"))


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
