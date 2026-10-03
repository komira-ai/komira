# =============================================================================
# Parity test for the STRING gather pass-1 SIMD in
# `compiler_join_assembly.emit_gather_column_projected`.
#
# Validates the W=4 unrolled + prefetch-ahead pass-1 (compute-total-bytes)
# against a scalar reference for a battery of input shapes:
#   * exact multiples of W (4, 8, 16, 256) — main-loop-only
#   * non-multiples (1, 2, 3, 5, 7, 17, 1023) — exercises tail loop
#   * boundary indices (0 and length-1) — covers prefetch edge cases
#   * randomized 100K-row case with mixed indices — broad coverage
#   * string-length coverage: ≤8 / 9-16 / 17-32 / >32 byte distributions
#     (also a regression guard for any length-tier bucketing of pass 2)
#   * nullable=True path with -1 sentinels (outer-join shape)
#
# The "tier" tests exercise the pass-2 view-based copy across the length
# distributions a length-tier bucketing implementation would need to
# validate.
#
# The SIMD pass-1 must produce bit-identical (offsets, data, validity) vs the
# scalar reference for every input shape; a divergence here would silently
# corrupt every join output STRING column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_join_assembly.compiler_join_assembly import (
    emit_gather_column_projected,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_string_batch(values: List[String]) raises -> RecordBatch:
    """Build a one-column RecordBatch holding the given STRING values."""
    var sa = StringArray.from_strings(values)

    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, False))
    var schema = sb.build()

    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_string(sa^))
    return rb.build(schema^)


def _gather_via_simd(
    batch: RecordBatch, indices: List[Int], is_nullable: Bool
) raises -> RecordBatch:
    """Drive `emit_gather_column_projected` over indices and return the
    one-column RecordBatch result."""
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    # `gather_parallel_min_rows` is left at its default
    # (GATHER_PARALLEL_MIN_ROWS, 64K): the parallel gather needs a worker pool
    # and at least that many rows, so this suite exercises the SERIAL SIMD
    # pass-1 path it verifies.
    emit_gather_column_projected(
        batch,
        0,
        String("s"),
        is_nullable,
        indices,
        len(indices),
        builder,
        sb,
    )
    var schema = sb.build()
    return builder.build(schema^)


def _scalar_reference(
    values: List[String], indices: List[Int], is_nullable: Bool
) -> Tuple[List[String], List[Bool]]:
    """Pure-scalar reference: for each idx, emit values[idx] (or "" + invalid
    when idx == -1 and is_nullable). Returns (out_strings, validity)."""
    var out_strs = List[String]()
    var out_valid = List[Bool]()
    for k in range(len(indices)):
        var idx = indices[k]
        if idx == -1 and is_nullable:
            out_strs.append(String(""))
            out_valid.append(False)
        else:
            out_strs.append(values[idx])
            out_valid.append(True)
    return (out_strs^, out_valid^)


def _assert_string_batch_matches(
    got: RecordBatch,
    expect_strs: List[String],
    expect_valid: List[Bool],
    label: String,
) raises:
    """Verify the SIMD output one-column STRING batch matches the scalar
    reference, both byte-for-byte AND validity-bit-for-bit."""
    assert_equal(got.num_rows(), len(expect_strs))
    assert_equal(got.num_columns(), 1)
    ref col = got.column_at(0)
    assert_true(col.arrow_type == ArrowType.STRING)
    var sa = col.as_string()
    assert_equal(sa.length, len(expect_strs))
    for i in range(sa.length):
        # Validity check
        var is_valid_got = True
        if sa.validity:
            is_valid_got = sa.validity.value().test(i)
        if is_valid_got != expect_valid[i]:
            print(
                label,
                "validity mismatch at i=",
                i,
                "got=",
                is_valid_got,
                "expect=",
                expect_valid[i],
            )
        assert_equal(is_valid_got, expect_valid[i])
        # String content check (only meaningful for valid rows)
        if expect_valid[i]:
            var got_str = sa.get(i)
            if got_str != expect_strs[i]:
                print(
                    label,
                    "data mismatch at i=",
                    i,
                    "got='",
                    got_str,
                    "' expect='",
                    expect_strs[i],
                    "'",
                )
            assert_true(got_str == expect_strs[i])


def _check_parity(
    values: List[String],
    indices: List[Int],
    is_nullable: Bool,
    label: String,
) raises:
    var batch = _make_string_batch(values)
    var got = _gather_via_simd(batch, indices, is_nullable)
    var ref_pair = _scalar_reference(values, indices, is_nullable)
    var ref_strs = ref_pair[0].copy()
    var ref_valid = ref_pair[1].copy()
    _assert_string_batch_matches(got, ref_strs, ref_valid, label)


# ---------------------------------------------------------------------------
# Tests — each exercises a different shape vs the W=4 boundary or a
# different length tier of pass-2.
# ---------------------------------------------------------------------------


def test_str_gather_n1_tail_only() raises:
    """count=1 — main loop body skipped (simd_end=0); single tail iter."""
    var vals: List[String] = ["hello", "world", "foo"]
    var idxs: List[Int] = [1]
    _check_parity(vals, idxs, False, String("n1_tail_only"))


def test_str_gather_n2_tail_only() raises:
    """count=2 — simd_end=0 still; 2 tail iters."""
    var vals: List[String] = ["hello", "world", "foo"]
    var idxs: List[Int] = [0, 2]
    _check_parity(vals, idxs, False, String("n2_tail_only"))


def test_str_gather_n3_tail_only() raises:
    """count=3 — simd_end=0; all 3 in tail."""
    var vals: List[String] = ["hello", "world", "foo"]
    var idxs: List[Int] = [2, 0, 1]
    _check_parity(vals, idxs, False, String("n3_tail_only"))


def test_str_gather_n4_main_only() raises:
    """count=4 — exactly W=4; main loop only, no tail."""
    var vals: List[String] = ["aaa", "bb", "cc", "dddd"]
    var idxs: List[Int] = [0, 1, 2, 3]
    _check_parity(vals, idxs, False, String("n4_main_only"))


def test_str_gather_n5_main_plus_1tail() raises:
    """count=5 — 1 main iter (4 rows) + 1 tail iter."""
    var vals: List[String] = ["a", "bb", "ccc", "dddd", "eeeee"]
    var idxs: List[Int] = [0, 4, 1, 3, 2]
    _check_parity(vals, idxs, False, String("n5_main_plus_1tail"))


def test_str_gather_n7_main_plus_3tail() raises:
    """count=7 — 1 main iter (4 rows) + 3 tail iters."""
    var vals: List[String] = ["a", "bb", "ccc"]
    var idxs: List[Int] = [0, 1, 2, 0, 1, 2, 0]
    _check_parity(vals, idxs, False, String("n7_main_plus_3tail"))


def test_str_gather_n16_pf_under_distance() raises:
    """count=16 — PF check `i + 16 < 16` is False on every iter; main loop
    runs without ever firing prefetch."""
    var vals: List[String] = ["aa", "bb", "cc", "dd"]
    var idxs = List[Int]()
    for i in range(16):
        idxs.append(i % 4)
    _check_parity(vals, idxs, False, String("n16_pf_under_distance"))


def test_str_gather_n17_pf_fires_once() raises:
    """count=17 — prefetch fires exactly once (i=0, i+16=16<17 True)."""
    var vals: List[String] = ["aa", "bb", "cc", "dd"]
    var idxs = List[Int]()
    for i in range(17):
        idxs.append(i % 4)
    _check_parity(vals, idxs, False, String("n17_pf_fires_once"))


def test_str_gather_tier1_le8_short_strings() raises:
    """All strings ≤8 bytes — n_name/p_phone shape coverage (also a
    regression guard for any future Pass-2 Tier-1 byte-loop bucketing)."""
    var vals: List[String] = ["a", "bb", "ccc", "dddd", "eeeee", "ffffff", "ggggggg", "hhhhhhhh"]
    var idxs = List[Int]()
    for i in range(64):
        idxs.append(i % 8)
    _check_parity(vals, idxs, False, String("tier1_le8"))


def test_str_gather_tier2_9_to_16() raises:
    """All strings 9-16 bytes — s_name/p_mfgr shape coverage (also a
    regression guard for any future Pass-2 Tier-2 dual 8-byte bucketing).
    """
    var vals: List[String] = [
        "abcdefghi",      # 9
        "abcdefghij",     # 10
        "abcdefghijkl",   # 12
        "abcdefghijklmno",  # 15
        "abcdefghijklmnop",  # 16
    ]
    var idxs = List[Int]()
    for i in range(64):
        idxs.append(i % 5)
    _check_parity(vals, idxs, False, String("tier2_9_to_16"))


def test_str_gather_tier3_17_to_32() raises:
    """All strings 17-32 bytes — s_address shape coverage (also a
    regression guard for any future Pass-2 Tier-3 dual 16-byte bucketing).
    """
    var vals: List[String] = [
        "abcdefghijklmnopq",                # 17
        "abcdefghijklmnopqrstuvwxyz",       # 26
        "abcdefghijklmnopqrstuvwxyz012345", # 32
    ]
    var idxs = List[Int]()
    for i in range(64):
        idxs.append(i % 3)
    _check_parity(vals, idxs, False, String("tier3_17_to_32"))


def test_str_gather_tier4_gt32_long_strings() raises:
    """Strings > 32 bytes — s_comment/r_comment shape coverage (also a
    regression guard for any future Pass-2 long-string memcpy fallback).
    """
    var vals: List[String] = [
        "the quick brown fox jumps over the lazy dog",                        # 43
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do",    # 63
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?@#",  # 65
    ]
    var idxs = List[Int]()
    for i in range(32):
        idxs.append(i % 3)
    _check_parity(vals, idxs, False, String("tier4_gt32"))


def test_str_gather_mixed_tiers() raises:
    """Mix of all 4 length tiers — exercises a varied length distribution
    spanning the (8, 16, 32) boundaries that a future Pass-2 bucketing
    would dispatch on."""
    var vals: List[String] = [
        "a",                                                          # tier 1 (1)
        "abcdefgh",                                                   # tier 1 (8 — boundary)
        "abcdefghi",                                                  # tier 2 (9)
        "abcdefghijklmnop",                                           # tier 2 (16 — boundary)
        "abcdefghijklmnopq",                                          # tier 3 (17)
        "abcdefghijklmnopqrstuvwxyz012345",                           # tier 3 (32 — boundary)
        "abcdefghijklmnopqrstuvwxyz0123456",                          # tier 4 (33)
        "the quick brown fox jumps over the lazy dog plus extra text", # tier 4 (long)
    ]
    var idxs = List[Int]()
    for i in range(256):
        idxs.append(i % 8)
    _check_parity(vals, idxs, False, String("mixed_tiers"))


def test_str_gather_n1023_main_plus_3tail() raises:
    """count=1023 — 255 main iters (1020 rows) + 3 tail iters."""
    var vals: List[String] = ["alpha", "beta", "gamma", "delta", "epsilon"]
    var idxs = List[Int]()
    for i in range(1023):
        idxs.append((i * 31) % 5)
    _check_parity(vals, idxs, False, String("n1023_main_plus_3tail"))


def test_str_gather_nullable_with_neg1_sentinels() raises:
    """is_nullable=True path with -1 sentinels (outer-join shape).
    Pass-1 must skip -1 rows (zero contribution to total_bytes); pass-2
    must skip -1 rows (no copy, no offset bump)."""
    var vals: List[String] = ["aa", "bbbb", "cccccc", "dddddddd"]
    # Mix of valid and -1; mostly valid so total_bytes > 0.
    var idxs: List[Int] = [
        0, -1, 1, 2,  # main loop iter 1: 1 null in middle
        3, -1, -1, 0,  # main loop iter 2: 2 nulls
        1, 2,         # tail: 2 valid
    ]
    _check_parity(vals, idxs, True, String("nullable_neg1"))


def test_str_gather_n100k_random() raises:
    """count=100K — a post-filter join-probe scale. Mixed string
    lengths to exercise pass-2 tier dispatch + main-loop interaction."""
    var vals: List[String] = [
        "a", "bb", "ccc", "dddd", "eeeee",          # tier 1 (1-5)
        "ffffffff",                                  # tier 1 (8 — boundary)
        "ggggggggg",                                 # tier 2 (9)
        "hhhhhhhhhhhhhhhh",                          # tier 2 (16 — boundary)
        "iiiiiiiiiiiiiiiii",                         # tier 3 (17)
        "jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj",          # tier 3 (32 — boundary)
        "kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk",         # tier 4 (33)
        "the quick brown fox jumps over the lazy dog plus more text padding",  # tier 4 long
    ]
    var idxs = List[Int]()
    var seed: UInt64 = 0xCAFEBABEDEADBEEF
    for _ in range(100000):
        seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        idxs.append(Int(seed >> 33) % len(vals))
    _check_parity(vals, idxs, False, String("n100k_random"))


def test_str_gather_boundary_indices() raises:
    """Indices at extreme positions (0 and length-1) — ensures pass-1
    prefetch on the boundary doesn't lose data even though the prefetched
    address may be OOB."""
    var vals: List[String] = ["zero", "one", "two", "three", "four", "five", "six", "seven"]
    var idxs = List[Int]()
    for i in range(32):
        idxs.append(0 if i % 2 == 0 else len(vals) - 1)
    _check_parity(vals, idxs, False, String("boundary_indices"))


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
