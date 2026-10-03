# =============================================================================
# The ORC bloom filter's Kirsch-Mitzenmacher combiner must reinterpret its
# 32-bit halves as SIGNED.
# =============================================================================
#
# `komira_orc/bloom_filter.mojo` is a VERBATIM port of orc-cpp
# `BloomFilter.cc:212-248`:
#
#       hash1 = (int) hash64;              // low 32 bits, SIGNED
#       hash2 = (int)(hash64 >>> 32);      // high 32 bits, SIGNED
#       for i in 1..k:
#           combinedHash = hash1 + i*hash2
#           if combinedHash < 0: combinedHash = ~combinedHash
#           pos = combinedHash % numBits
#
# The `combinedHash < 0` flip is load-bearing: it is what keeps `pos`
# non-negative, and it is reached for roughly half of all hashes. The natural
# spelling of the reinterpretation
#
#       Int64(Int32(bitcast[DType.uint32, 1](UInt32(hash64 & 0xFFFFFFFF))))
#
# is MISCOMPILED on Mojo 1.0.0b2: widening a value narrowed to the signed type
# of the SAME width as its unsigned source drops the sign extension
# (sext(trunc(zext(x))) folds to zext(x)), at every optimization level, JIT
# and AOT. `hash1`/`hash2` would then always be in [0, 2^32) and THE
# NEGATIVE-FLIP BRANCH WOULD BE UNREACHABLE.
#
# ⚠ WHY A ROUND-TRIP TEST CANNOT CATCH THIS.
# `_add_hash` and `_test_hash` would carry the IDENTICAL defect, so this
# package's own write->read round trip stays perfectly self-consistent.
# `test_bloom_no_false_negative`, `test_bloom_string_round_trip` and the
# eq-hit/eq-miss tests are all round-trip tests and all of them pass WITH the
# defect. The contract that breaks is CROSS-TOOL: a bloom filter written by
# orc-cpp / orc-java would be probed here at DIFFERENT bit positions, and a
# bloom-filter false negative is a SILENTLY DROPPED ROW during predicate
# pushdown.
#
# So this test asserts the SIGN SEMANTICS DIRECTLY, on values, at the seam
# (`orc_sext_u32_to_i64`) plus the reachability of the branch that depends on
# it. Those are checkable without an orc-cpp fixture and they go RED on the
# miscompiled expression. (`test_orc_bloom_golden_vector` covers the
# arithmetic width against orc-cpp's own bit positions.)
#
# Encapsulation: public surface only — no UnsafePointer, no wildcard origin.
# =============================================================================

from komira_orc.bloom_filter import orc_sext_u32_to_i64, wang64_hash

from std.testing import TestSuite, assert_equal, assert_true, assert_false


# -----------------------------------------------------------------------------
# The seam itself: `(int) u32` in orc-cpp terms.
# -----------------------------------------------------------------------------


def test_sext_u32_high_bit_set_is_negative() raises:
    """The single fact the fold destroyed: a u32 word with bit 31 set must
    reinterpret NEGATIVE. Pre-fix this returned 4294966295."""
    assert_equal(
        Int(orc_sext_u32_to_i64(UInt32(4294966295))),
        -1001,
        "u32 0xFFFFFC17 must reinterpret as -1001",
    )


def test_sext_u32_boundaries() raises:
    """Both sides of the sign boundary, plus the extremes."""
    assert_equal(Int(orc_sext_u32_to_i64(UInt32(0))), 0)
    assert_equal(
        Int(orc_sext_u32_to_i64(UInt32(2147483647))),
        2147483647,
        "largest positive int32 must be unchanged",
    )
    assert_equal(
        Int(orc_sext_u32_to_i64(UInt32(2147483648))),
        -2147483648,
        "0x8000_0000 must reinterpret as the most-negative int32",
    )
    assert_equal(
        Int(orc_sext_u32_to_i64(UInt32(4294967295))),
        -1,
        "0xFFFF_FFFF must reinterpret as -1",
    )


def test_sext_u32_is_not_the_identity() raises:
    """A guard against the whole class regressing to a zero-extend: at least one
    input must MOVE. Miscompiled, `orc_sext_u32_to_i64` would be the identity
    on every input, which is the entire defect stated as one assertion."""
    var moved = False
    var probes = List[UInt32]()
    probes.append(UInt32(2147483648))
    probes.append(UInt32(4000000000))
    probes.append(UInt32(4294967295))
    for i in range(len(probes)):
        if Int64(probes[i]) != orc_sext_u32_to_i64(probes[i]):
            moved = True
    assert_true(
        moved,
        "orc_sext_u32_to_i64 behaved as a ZERO-extend on every high-bit input"
        " — the sign extension has been folded away again",
    )


# -----------------------------------------------------------------------------
# The consequence: the negative-flip branch must be REACHABLE.
# -----------------------------------------------------------------------------


def _combined_first(hash64: UInt64) -> Int64:
    """Reproduce the combiner's i=1 term exactly as bloom_filter.mojo computes
    it, so the test observes the same quantity the branch tests."""
    var hash1 = orc_sext_u32_to_i64(UInt32(hash64 & 0xFFFFFFFF))
    var hash2 = orc_sext_u32_to_i64(UInt32((hash64 >> 32) & 0xFFFFFFFF))
    return hash1 + Int64(1) * hash2


def test_negative_flip_branch_is_reachable() raises:
    """`combinedHash < 0` must actually fire. Pre-fix, `hash1`/`hash2` were both
    non-negative for EVERY input, so `combined` was too and the `~combined`
    branch was dead code — a permanent silent divergence from orc-cpp."""
    # both halves have bit 31 set -> both reinterpret negative -> sum negative
    assert_true(
        _combined_first(UInt64(0xFFFFFC17_FFFFFC17)) < 0,
        "the combiner's negative-flip branch is UNREACHABLE — hash1/hash2 are"
        " not being sign-reinterpreted",
    )


def test_negative_flip_branch_stays_unreached_when_it_should() raises:
    """POSITIVE CONTROL: with both halves below 2^31 the combined value is
    non-negative and the flip must NOT fire. Passes with or without a correct
    sign extension, so a red above is the sign divergence and not the
    harness."""
    assert_false(
        _combined_first(UInt64(0x0000002A_0000002A)) < 0,
        "a small non-negative hash must not take the flip branch",
    )
    assert_equal(Int(_combined_first(UInt64(0x0000002A_0000002A))), 84)


def test_wang64_produces_high_bit_halves_in_practice() raises:
    """The defect only matters if real hashes actually land with bit 31 set.
    Drive the production kernel over a small key range and assert that at least
    one hash exercises the sign path — otherwise the tests above would be
    pinning a shape the corpus never reaches."""
    var negatives = 0
    for k in range(64):
        if _combined_first(wang64_hash(Int64(k))) < 0:
            negatives += 1
    assert_true(
        negatives > 0,
        "no wang64 hash over 64 keys reached the negative-flip path; the sign"
        " reinterpretation is not being applied",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
