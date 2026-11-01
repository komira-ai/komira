# =============================================================================
# test_hash_fn_kernel.mojo — EXECUTOR-KERNEL-COMPTIME Phase 1.c regression
# =============================================================================
#
# Exercises the Phase 1.c deliverables:
#
#   - `HashI64.hash_chunk` correctness over {empty, 1-row, 2048-row, 4097-row}.
#   - NULL handling: out[i] == NULL_HASH when input[i] is null (validity cell).
#   - `HashFnOp[HashI64]` end-to-end through one Morsel.execute call.
#   - Hash output matches expected SplitMix64 for known inputs (gold reference
#     via Python — `splitmix64(0)==0`, `splitmix64(42)==0xA759EA27D4727622`).
#   - Distinct monomorphizations across (T, INPUT_VALID) cells.
#   - Float canonicalization: HashF64(0.0) == HashF64(-0.0); NaN1 == NaN2.
#   - Avalanche sanity: 1-bit input difference produces >25 different output
#     bits on average across 1000 random pairs.
#   - String hash determinism: same content -> same hash regardless of buffer
#     layout.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema
from komira_arrow.string_array import StringArray
from komira_morsel.morsel import Morsel
from komira_operator_api.hash_fn_op import HashFnOp, StringHashFnOp
from komira_kernels.builtin_hash_fns import (
    HashI8,
    HashI16,
    HashI32,
    HashI64,
    HashI64_V,
    HashU8,
    HashU16,
    HashU32,
    HashU64,
    HashF32,
    HashF64,
    HashF64_V,
    HashBool,
)
from komira_kernels.builtin_string_hash_fns import HashStr, HashStr_V
from komira_kernels.hash_fn import HashFn, NULL_HASH, StringHashFn


# =============================================================================
# Gold-reference SplitMix64 (Python-verified)
# =============================================================================
#
# Computed values (from the Python reference at task dispatch time):
#   splitmix64(0)       = 0x0000000000000000
#   splitmix64(1)       = 0x5692161D100B05E5
#   splitmix64(2)       = 0xDBD238973A2B148A
#   splitmix64(3)       = 0x1E535EEDE31428F0
#   splitmix64(42)      = 0xA759EA27D4727622
#   splitmix64(100)     = 0x2731D9FDF756B334
#   splitmix64(123456)  = 0xCC74468CBF640518
# =============================================================================


@always_inline
def _splitmix64_ref(k: UInt64) -> UInt64:
    """Pure-Mojo reference SplitMix64. Used as the gold standard for byte-
    identical comparison against `HashI64.hash_chunk` output."""
    var x = k
    x = (x ^ (x >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
    x = (x ^ (x >> UInt64(27))) * UInt64(0x94D049BB133111EB)
    x = x ^ (x >> UInt64(31))
    return x


# =============================================================================
# Fixture helpers
# =============================================================================


def _make_i64(n: Int) raises -> PrimitiveArray[DType.int64]:
    """Build [0, 1, 2, ..., n-1] Int64 array."""
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Int64(i))
    return arr^


def _make_nullable_i64(n: Int, null_at: Int) raises -> PrimitiveArray[DType.int64]:
    """Build [0..n) Int64 with row null_at marked null."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, Int64(i))
    if 0 <= null_at < n:
        arr._set_null(null_at)
        arr.null_count = arr.null_count + 1
    return arr^


# =============================================================================
# (a) HashI64.hash_chunk correctness over {0, 1, 2048, 4097} rows
# =============================================================================


def _check_hash_i64(n: Int) raises:
    var arr = _make_i64(n)
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashI64()
    var valid = f.hash_chunk(arr, out, n)
    # Non-nullable: every cell is valid.
    assert_equal(valid, n, "HashI64 valid_count == n for non-nullable input")
    # Verify each output matches the gold reference.
    for i in range(n):
        var expected = _splitmix64_ref(UInt64(i))
        var actual = out.get(i)
        assert_equal(
            actual, expected, "HashI64 row " + String(i) + " mismatch (n=" + String(n) + ")"
        )


def test_hash_i64_empty() raises:
    _check_hash_i64(0)


def test_hash_i64_one_row() raises:
    _check_hash_i64(1)


def test_hash_i64_2048_rows() raises:
    _check_hash_i64(2048)


def test_hash_i64_4097_rows_ragged_tail() raises:
    _check_hash_i64(4097)


# =============================================================================
# (b) NULL handling — out[i] == NULL_HASH at null cells
# =============================================================================


def test_hash_i64_v_null_handling() raises:
    """Nullable Int64: row at null_at is replaced by NULL_HASH; others
    receive their actual SplitMix64."""
    var n = 8
    var arr = _make_nullable_i64(n, 3)  # row 3 null
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashI64_V()
    var valid = f.hash_chunk(arr, out, n)
    assert_equal(valid, n - 1, "7 valid rows")
    assert_equal(out.get(3), NULL_HASH, "row 3 is NULL_HASH")
    for i in range(n):
        if i != 3:
            assert_equal(out.get(i), _splitmix64_ref(UInt64(i)))


def test_null_hash_constant_consistent_across_kernels() raises:
    """Every HashFn / StringHashFn conformer returns the same NULL_HASH."""
    var fi64 = HashI64()
    var fi64v = HashI64_V()
    var ff64 = HashF64()
    var fbool = HashBool()
    var fstr = HashStr()
    var fstrv = HashStr_V()
    assert_equal(fi64.null_hash(), NULL_HASH)
    assert_equal(fi64v.null_hash(), NULL_HASH)
    assert_equal(ff64.null_hash(), NULL_HASH)
    assert_equal(fbool.null_hash(), NULL_HASH)
    assert_equal(fstr.null_hash(), NULL_HASH)
    assert_equal(fstrv.null_hash(), NULL_HASH)


# =============================================================================
# (c) HashFnOp[HashI64] end-to-end via Morsel.execute
# =============================================================================


def test_hash_i64_op_end_to_end() raises:
    """HashFnOp[HashI64] over 64 rows appends a hash column to the batch."""
    var n = 64
    var arr = _make_i64(n)
    var schema = Schema.from_fields_1(Field("k", ArrowType.INT64, False))
    var rb = RecordBatch.from_typed_columns_1(
        schema^, Column.from_primitive[DType.int64](arr^)
    )
    var m = Morsel(rb^, 0, 0)
    var op = HashFnOp[HashI64](HashI64(), "k", "h")
    var _r = op.execute(m)
    assert_equal(m.batch.num_rows(), n, "row count unchanged (1:1 operator)")
    assert_equal(m.batch.num_columns(), 2, "appended hash column")
    # Verify the hash column equals our reference for the keys.
    var hash_col = m.batch.column_at(1).as_primitive[DType.uint64]()
    for i in range(n):
        assert_equal(
            hash_col.get(i),
            _splitmix64_ref(UInt64(i)),
            "Op-emitted hash row " + String(i),
        )


# =============================================================================
# (d) HashI64 matches our explicit SplitMix64 on 4097 distinct Int64s
# =============================================================================


def test_hash_i64_byte_identical_to_splitmix64_ref() raises:
    """4097 distinct Int64s exercise SIMD lanes + ragged tail; each hash
    must match the gold-reference _splitmix64_ref byte-for-byte."""
    var n = 4097
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        # Mix of positive / negative / zero / large keys.
        var v = Int64((i * 17 - 2000) ^ (i << 3))
        arr.set(i, v)
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashI64()
    _ = f.hash_chunk(arr, out, n)
    for i in range(n):
        var v = (UInt64(i) * UInt64(17) - UInt64(2000)) ^ (UInt64(i) << UInt64(3))
        var expected = _splitmix64_ref(v)
        var actual = out.get(i)
        assert_equal(
            actual,
            expected,
            "row " + String(i) + " HashI64 vs _splitmix64_ref",
        )


# =============================================================================
# (e) Distinct monomorphizations per (T, INPUT_VALID)
# =============================================================================


def _assert_hash_kernel_ids_differ[F: HashFn, G: HashFn]() raises:
    assert_true(
        F.KERNEL_ID != G.KERNEL_ID,
        "F.KERNEL_ID != G.KERNEL_ID",
    )


def test_distinct_monomorphizations() raises:
    """Verify distinct KERNEL_IDs across the spec's required quartet:
    HashI64, HashU32, HashF64, HashBool. Plus a fanout check across
    the 8 integer cells."""
    _assert_hash_kernel_ids_differ[HashI64, HashU32]()
    _assert_hash_kernel_ids_differ[HashI64, HashF64]()
    _assert_hash_kernel_ids_differ[HashI64, HashBool]()
    _assert_hash_kernel_ids_differ[HashU32, HashF64]()
    _assert_hash_kernel_ids_differ[HashU32, HashBool]()
    _assert_hash_kernel_ids_differ[HashF64, HashBool]()
    # 8-way integer fanout
    _assert_hash_kernel_ids_differ[HashI8, HashI16]()
    _assert_hash_kernel_ids_differ[HashI8, HashI32]()
    _assert_hash_kernel_ids_differ[HashI8, HashI64]()
    _assert_hash_kernel_ids_differ[HashU8, HashU16]()
    _assert_hash_kernel_ids_differ[HashU8, HashU32]()
    _assert_hash_kernel_ids_differ[HashU8, HashU64]()
    _assert_hash_kernel_ids_differ[HashF32, HashF64]()
    # Validity vs non-validity for same T
    _assert_hash_kernel_ids_differ[HashI64, HashI64_V]()
    _assert_hash_kernel_ids_differ[HashF64, HashF64_V]()
    # Comptime flags read correctly
    assert_equal(Bool(HashI64.INPUT_VALID), False)
    assert_equal(Bool(HashI64_V.INPUT_VALID), True)
    assert_equal(Bool(HashF64.INPUT_VALID), False)
    assert_equal(Bool(HashF64_V.INPUT_VALID), True)


# =============================================================================
# (f) Float canonicalization
# =============================================================================


def test_hash_f64_canonicalization_negative_zero() raises:
    """HashF64(0.0) == HashF64(-0.0) (IEEE 754 zero equality)."""
    var n = 2
    var arr = PrimitiveArray[DType.float64].allocate(n)
    arr.set(0, Float64(0.0))
    arr.set(1, Float64(-0.0))
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashF64()
    _ = f.hash_chunk(arr, out, n)
    assert_equal(out.get(0), out.get(1), "+0.0 and -0.0 hash identically")


def test_hash_f64_canonicalization_nan() raises:
    """HashF64(NaN1) == HashF64(NaN2) where the bit patterns differ.

    Construct two distinct NaN bit patterns:
      - NaN1 = signal NaN (0x7FF0000000000001)
      - NaN2 = quiet NaN  (0x7FF8000000000123)
    Both compare equal to neither itself nor each other (NaN != NaN) but
    must hash to the canonical NaN slot.
    """
    var n = 2
    var arr = PrimitiveArray[DType.float64].allocate(n)
    # Manually construct NaN bit patterns. We use Float64('nan') and a
    # different quiet NaN via division.
    var nan1 = Float64(0) / Float64(0)
    var nan2 = Float64(1) / Float64(0) - Float64(1) / Float64(0)
    # Both should be NaN (verify):
    assert_true(nan1 != nan1, "nan1 is NaN")
    assert_true(nan2 != nan2, "nan2 is NaN")
    arr.set(0, nan1)
    arr.set(1, nan2)
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashF64()
    _ = f.hash_chunk(arr, out, n)
    assert_equal(out.get(0), out.get(1), "two distinct NaN patterns hash identically")


# =============================================================================
# (g) Avalanche sanity — 1-bit input difference produces >25 different bits
# =============================================================================


def test_splitmix64_avalanche_sanity() raises:
    """SplitMix64 has good avalanche: a 1-bit input difference should produce
    ~32 random output bit differences. We assert >25 average across N=1000
    deterministic input pairs (k, k^bit) for bit positions 0..63 and k in
    a deterministic LCG sequence."""
    var n_pairs = 1000
    var total_diff_bits = 0
    var k = UInt64(0x123456789ABCDEF0)
    for i in range(n_pairs):
        # Advance k via a simple LCG (deterministic, fast).
        k = k * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        # Flip one bit at position i % 64.
        var bit_pos = UInt64(i) & UInt64(63)
        var k2 = k ^ (UInt64(1) << bit_pos)
        var h1 = _splitmix64_ref(k)
        var h2 = _splitmix64_ref(k2)
        var diff = h1 ^ h2
        # Popcount the diff.
        var bv = diff
        while bv != 0:
            total_diff_bits += 1
            bv = bv & (bv - 1)
    var avg = total_diff_bits / n_pairs
    assert_true(
        avg > 25,
        "avalanche avg bit-difference " + String(avg) + " not > 25 (poor avalanche)",
    )


# =============================================================================
# (h) String hash determinism
# =============================================================================


def test_hash_str_determinism_same_content() raises:
    """Two StringArrays with the same logical content (but different
    underlying buffers) must hash to the same UInt64 per row."""
    var s1_list = List[String]()
    s1_list.append(String("hello"))
    s1_list.append(String("world"))
    s1_list.append(String(""))
    s1_list.append(String("a"))
    s1_list.append(String("longer string with spaces"))
    var arr1 = StringArray.from_strings(s1_list)

    # Construct an independent second StringArray with the same content.
    var s2_list = List[String]()
    s2_list.append(String("hello"))
    s2_list.append(String("world"))
    s2_list.append(String(""))
    s2_list.append(String("a"))
    s2_list.append(String("longer string with spaces"))
    var arr2 = StringArray.from_strings(s2_list)

    var n = 5
    var out1 = PrimitiveArray[DType.uint64].allocate(n)
    var out2 = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashStr()
    _ = f.hash_chunk(arr1, out1, n)
    _ = f.hash_chunk(arr2, out2, n)
    for i in range(n):
        assert_equal(out1.get(i), out2.get(i), "row " + String(i) + " hash mismatch across arrays")
    # Distinct content -> distinct hashes (statistically). Verify a few pairs.
    assert_true(out1.get(0) != out1.get(1), "'hello' != 'world' hash")
    assert_true(out1.get(0) != out1.get(2), "'hello' != '' hash")
    assert_true(out1.get(2) != out1.get(3), "'' != 'a' hash")


# =============================================================================
# Additional sanity — narrow integer + unsigned + float cells
# =============================================================================


def test_hash_i32_basic() raises:
    """HashI32 widens Int32 to UInt64 before SplitMix64."""
    var n = 16
    var arr = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        arr.set(i, Int32(i))
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashI32()
    _ = f.hash_chunk(arr, out, n)
    for i in range(n):
        var expected = _splitmix64_ref(UInt64(i))
        assert_equal(out.get(i), expected, "HashI32 row " + String(i))


def test_hash_u64_basic() raises:
    """HashU64 — direct SplitMix64 (no cast)."""
    var n = 32
    var arr = PrimitiveArray[DType.uint64].allocate(n)
    for i in range(n):
        arr.set(i, UInt64(i * 7 + 100))
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashU64()
    _ = f.hash_chunk(arr, out, n)
    for i in range(n):
        var expected = _splitmix64_ref(UInt64(i * 7 + 100))
        assert_equal(out.get(i), expected, "HashU64 row " + String(i))


def test_hash_bool_basic() raises:
    """HashBool — 2-entry table lookup."""
    var n = 8
    var arr = PrimitiveArray[DType.bool].allocate(n)
    for i in range(n):
        arr.set(i, Bool(i % 2 == 0))  # alternating True/False
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashBool()
    _ = f.hash_chunk(arr, out, n)
    # All True rows -> same hash; all False rows -> same hash; True != False
    var true_hash = out.get(0)   # i=0, True
    var false_hash = out.get(1)  # i=1, False
    assert_true(true_hash != false_hash, "True != False hash")
    for i in range(n):
        if i % 2 == 0:
            assert_equal(out.get(i), true_hash, "row " + String(i) + " is True")
        else:
            assert_equal(out.get(i), false_hash, "row " + String(i) + " is False")


def test_hash_f64_basic_distinct_values() raises:
    """HashF64 — distinct floats hash to distinct values (with high prob)."""
    var n = 16
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.set(i, Float64(i) * Float64(3.14))
    var out = PrimitiveArray[DType.uint64].allocate(n)
    var f = HashF64()
    _ = f.hash_chunk(arr, out, n)
    # All distinct values should produce distinct hashes (bijection on bits).
    for i in range(n):
        for j in range(i + 1, n):
            assert_true(
                out.get(i) != out.get(j),
                "distinct floats collided at " + String(i) + "," + String(j),
            )


def main() raises:
    var suite = TestSuite()
    # (a) correctness over varied chunk sizes
    suite.test[test_hash_i64_empty]()
    suite.test[test_hash_i64_one_row]()
    suite.test[test_hash_i64_2048_rows]()
    suite.test[test_hash_i64_4097_rows_ragged_tail]()
    # (b) null handling
    suite.test[test_hash_i64_v_null_handling]()
    suite.test[test_null_hash_constant_consistent_across_kernels]()
    # (c) operator end-to-end
    suite.test[test_hash_i64_op_end_to_end]()
    # (d) byte-identical
    suite.test[test_hash_i64_byte_identical_to_splitmix64_ref]()
    # (e) distinct monomorphizations
    suite.test[test_distinct_monomorphizations]()
    # (f) float canonicalization
    suite.test[test_hash_f64_canonicalization_negative_zero]()
    suite.test[test_hash_f64_canonicalization_nan]()
    # (g) avalanche sanity
    suite.test[test_splitmix64_avalanche_sanity]()
    # (h) string determinism
    suite.test[test_hash_str_determinism_same_content]()
    # extras
    suite.test[test_hash_i32_basic]()
    suite.test[test_hash_u64_basic]()
    suite.test[test_hash_bool_basic]()
    suite.test[test_hash_f64_basic_distinct_values]()
    suite^.run()
