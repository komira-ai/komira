# =============================================================================
# test_orc_bloom_golden_vector.mojo — the ORC classic-bloom GOLDEN VECTOR.
# =============================================================================
#
# ⚠ WHY THIS FILE EXISTS.
#
# Every other bloom test in this package is a WRITE -> READ ROUND TRIP. A
# round trip is self-referential: `_add_hash` and `_test_hash` share every
# line of the hash/combine path, so ANY combiner defect is invisible to all of
# them. A `sext(trunc(zext(x)))` miscompilation, for example, makes the
# negative-flip branch UNREACHABLE and places different bits than orc-cpp for
# about half of all hashes, while every round-trip test passes.
#
# The contract a bloom filter has is CROSS-TOOL: a filter written by orc-cpp /
# orc-java / Hive must be probed to the SAME bit positions here, or a probe
# returns a FALSE NEGATIVE — and a false negative in a bloom filter is a
# SILENTLY DROPPED ROW during predicate pushdown. Only a golden vector can
# check that.
#
# WHERE THE GOLDEN NUMBERS COME FROM. They are produced by an INDEPENDENT
# reimplementation of orc-cpp's algorithm (`BloomFilter.cc` /
# `BloomFilter.hh`), written from the published source semantics rather than
# from this codebase:
#
#     int32_t hash1 = static_cast<int32_t>(hash64);
#     int32_t hash2 = static_cast<int32_t>(hash64 >> 32);
#     for (int32_t i = 1; i <= numHashFunctions; ++i) {
#       int32_t combinedHash = hash1 + i * hash2;   // INT32 -> WRAPS
#       if (combinedHash < 0) combinedHash = ~combinedHash;
#       uint64_t pos = combinedHash % numBits;
#       bitSet->set(pos);
#     }
#
# WHAT IT CHECKS BEYOND THE SIGN. Getting the SIGN of hash1/hash2 right is not
# enough; the combiner's ARITHMETIC WIDTH must match too. `hash1 + Int64(i) *
# hash2` in Int64 does NOT wrap, while orc-cpp and orc-java both accumulate in
# a 32-bit signed int, which does. `hash2` is a full-range signed 32-bit value,
# so `i * hash2` leaves int32 range for most hashes even at i = 1. With an
# Int64 accumulator:
#
#   * bit positions DIFFER for most probed keys (k = 7, numBits = 1024)
#   * many of those diverge at i = 1 ALONE — the term
#     `test_orc_bloom_sext_combiner` probes, which is why that test alone
#     cannot catch it
#   * key 0 diverges
#
# FALSIFIER. With `orc_wrap_to_i32` removed from `_add_hash`/`_test_hash`,
# this target FAILS with three independent assertions:
#     utf8bitset byte 1 diverges from orc-cpp
#     bit 72 is set but orc-cpp does not set it
#     a key present in a FOREIGN-written bloom probed ABSENT (key 0)
# while `test_orc_bloom_filter` and `test_orc_bloom_sext_combiner` BOTH STAY
# GREEN. That is the point of this file: the two round-trip bloom tests are
# structurally incapable of seeing a combiner divergence, because a round trip
# cannot disagree with itself.
#
# SCOPE — HONEST LABELLING. These vectors cover the LONG path: Thomas Wang's
# 64-bit integer hash plus the Kirsch-Mitzenmacher combiner plus the flat
# bitset layout. They do NOT cover `murmur3_hash64` (the string/binary path):
# a reimplementation of orc-cpp's custom Murmur3 variant transcribed from this
# module's own comments would mirror any mistake in it rather than
# independently check it, so claiming it as a golden vector would be false
# coverage. A murmur3 golden needs bytes emitted by a real ORC writer.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_orc.bloom_filter import (
    OrcBloomFilter,
    orc_wrap_to_i32,
    wang64_hash,
)


# -----------------------------------------------------------------------------
# GOLDEN GEOMETRY: numHashFunctions = 4, numWords = 2 (numBits = 128).
# GOLDEN KEYS: 0, 1, 2, 42, 1000.
# -----------------------------------------------------------------------------
#
# Reference bit positions, per key (i = 1..4):
#      0 -> [126, 19, 90, 55]
#      1 -> [ 55, 32, 118, 114]
#      2 -> [ 51, 13, 78, 112]
#     42 -> [ 41, 88,  7, 54]
#   1000 -> [ 47, 83, 86, 38]


def _golden_bitset() -> List[UInt8]:
    """The 16-byte `utf8bitset` orc-cpp produces for the golden key set."""
    var b = List[UInt8]()
    b.append(0x80)
    b.append(0x20)
    b.append(0x08)
    b.append(0x00)
    b.append(0x41)
    b.append(0x82)
    b.append(0xC8)
    b.append(0x00)
    b.append(0x00)
    b.append(0x40)
    b.append(0x48)
    b.append(0x05)
    b.append(0x00)
    b.append(0x00)
    b.append(0x45)
    b.append(0x40)
    return b^


def _golden_keys() -> List[Int64]:
    var k = List[Int64]()
    k.append(Int64(0))
    k.append(Int64(1))
    k.append(Int64(2))
    k.append(Int64(42))
    k.append(Int64(1000))
    return k^


def test_bloom_golden_bitset_long() raises:
    """Byte-for-byte equality with the reference `utf8bitset`.

    This is the whole test: if this package places one bit differently from
    orc-cpp, a filter written by orc-cpp probes to the wrong position here and
    membership answers become false negatives.
    """
    var bf = OrcBloomFilter(4, 2)
    var keys = _golden_keys()
    for i in range(len(keys)):
        bf.add_long(keys[i])
    var golden = _golden_bitset()
    assert_equal(
        len(bf.bitset), len(golden), "bitset length must be numWords * 8"
    )
    for i in range(len(golden)):
        assert_equal(
            Int(bf.bitset[i]),
            Int(golden[i]),
            "utf8bitset byte "
            + String(i)
            + " diverges from orc-cpp — this reader is setting DIFFERENT bits than"
            " every other ORC implementation, so cross-tool probes return"
            " false negatives",
        )


def test_bloom_golden_positions_key_zero() raises:
    """Key 0 alone, so a failure names ONE hash rather than a merged bitset.

    Key 0's reference positions are [126, 19, 90, 55]. The pre-round-2 Int64
    combiner produced [126, 620 % 128, 90, 584 % 128] for the same key at
    numBits = 1024; at numBits = 128 the i = 2 and i = 4 terms likewise move.
    """
    var bf = OrcBloomFilter(4, 2)
    bf.add_long(Int64(0))
    var expect = List[Int]()
    expect.append(126)
    expect.append(19)
    expect.append(90)
    expect.append(55)
    var set_count = 0
    for pos in range(128):
        var byte_idx = pos >> 3
        var bit = pos & 7
        var is_set = (Int(bf.bitset[byte_idx]) >> bit) & 1 == 1
        if is_set:
            set_count += 1
            var found = False
            for e in range(len(expect)):
                if expect[e] == pos:
                    found = True
            assert_true(
                found,
                "bit " + String(pos) + " is set but orc-cpp does not set it",
            )
    assert_equal(
        set_count, 4, "orc-cpp sets exactly 4 distinct bits for key 0"
    )


def test_bloom_golden_membership_matches_reference() raises:
    """Present keys must probe True; reference-ABSENT keys must probe False.

    3..7 are absent from the reference bitset. A False here is a PROOF of
    absence in bloom semantics, so this is the direction that must not drift:
    if this package probed different positions, one of these would flip.
    """
    var bf = OrcBloomFilter(4, 2)
    var keys = _golden_keys()
    for i in range(len(keys)):
        bf.add_long(keys[i])
    for i in range(len(keys)):
        assert_true(
            bf.test_long(keys[i]),
            "an ADDED key must never probe absent (key "
            + String(Int(keys[i]))
            + ")",
        )
    for cand in range(3, 8):
        assert_false(
            bf.test_long(Int64(cand)),
            "key "
            + String(cand)
            + " is absent from the reference bitset but probed present —"
            " komira_orc's probe positions differ from orc-cpp's",
        )


def test_bloom_reader_side_golden_bitset_probes_correctly() raises:
    """THE ACTUAL CROSS-TOOL DIRECTION: construct from the reference BYTES.

    The other cases build the filter with our writer. This one takes the
    on-disk `utf8bitset` a foreign ORC writer would have produced and probes it
    with our reader — which is what a real read does, and the direction in
    which a combiner divergence becomes a dropped row.
    """
    var bf = OrcBloomFilter(4, _golden_bitset())
    assert_equal(bf.num_bits(), 128)
    var keys = _golden_keys()
    for i in range(len(keys)):
        assert_true(
            bf.test_long(keys[i]),
            "a key present in a FOREIGN-written bloom probed ABSENT (key "
            + String(Int(keys[i]))
            + ") — this is the false negative that silently drops rows in"
            " predicate pushdown",
        )
    for cand in range(3, 8):
        assert_false(
            bf.test_long(Int64(cand)),
            "key " + String(cand) + " must probe absent in the reference bitset",
        )


# -----------------------------------------------------------------------------
# The primitive the golden vector forced into existence.
# -----------------------------------------------------------------------------


def test_orc_wrap_to_i32_semantics() raises:
    """`orc_wrap_to_i32` must be C++ `static_cast<int32_t>` on an Int64."""
    assert_equal(Int(orc_wrap_to_i32(Int64(0))), 0)
    assert_equal(Int(orc_wrap_to_i32(Int64(2147483647))), 2147483647)
    # 2^31 wraps to INT32_MIN — the case the Int64 combiner got wrong.
    assert_equal(Int(orc_wrap_to_i32(Int64(2147483648))), -2147483648)
    assert_equal(Int(orc_wrap_to_i32(Int64(4294967296))), 0)
    assert_equal(Int(orc_wrap_to_i32(Int64(-1))), -1)
    assert_equal(Int(orc_wrap_to_i32(Int64(4294967295))), -1)


def test_wrap_actually_moves_a_real_combiner_term() raises:
    """The wrap must not be a no-op on hashes the corpus actually produces.

    If `orc_wrap_to_i32` were the identity on every real term, this file would
    be pinning a shape nothing reaches — the same trap the sext test fell into.
    """
    var moved = 0
    for k in range(64):
        var h = wang64_hash(Int64(k))
        var hash1 = Int64(h & 0xFFFFFFFF)
        if hash1 >= 0x8000_0000:
            hash1 -= 0x1_0000_0000
        var hash2 = Int64((h >> 32) & 0xFFFFFFFF)
        if hash2 >= 0x8000_0000:
            hash2 -= 0x1_0000_0000
        for i in range(1, 5):
            var raw = hash1 + Int64(i) * hash2
            if orc_wrap_to_i32(raw) != raw:
                moved += 1
    assert_true(
        moved > 0,
        "no wang64 combiner term over 64 keys x 4 hash functions left int32"
        " range — the wrap is pinning a shape the corpus never reaches",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
