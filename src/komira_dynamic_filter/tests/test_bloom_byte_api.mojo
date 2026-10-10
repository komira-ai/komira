# =============================================================================
# Byte-input API of komira_dynamic_filter.bloom_filter
# =============================================================================
#
# The byte-input functions take a `Span[UInt8, _]` and read its length from
# the Span. These tests pin what they compute:
#   1. xxhash64 equals the reference xxHash64 (seed 0) on published vectors
#      covering the short path, the 32-byte stripe loop and every tail lane.
#   2. xxhash64 of a sub-Span hashes exactly that window.
#   3. xxhash64 of 8 little-endian bytes equals xxhash64_int64, and so does
#      hash_bytes on an xxHash64 filter equal hash_int64.
#   4. hash_bytes dispatches on the family (xxHash64 vs FNV-1a vectors).
#   5. from_bytes copies len(raw) bytes, pads to the 32-byte block size with
#      zeros, and an empty Span gives one zero block.
#   6. insert_bytes then might_contain_bytes finds the value, per family.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_dynamic_filter.bloom_filter import (
    BloomFilter,
    HashFamily,
    xxhash64,
    xxhash64_int64,
)


def _le8(v: Int64) -> List[UInt8]:
    var out = List[UInt8](capacity=8)
    for i in range(8):
        out.append(UInt8((UInt64(v) >> UInt64(8 * i)) & 0xFF))
    return out^


def _bf_bytes(bf: BloomFilter) -> List[UInt8]:
    var out = List[UInt8](capacity=bf.num_bytes)
    var view = bf.data.view_range_ro(0, bf.num_bytes)
    for i in range(bf.num_bytes):
        out.append(view.get_typed[UInt8](i))
    return out^


def test_xxhash64_reference_vectors() raises:
    # Reference xxHash64, seed 0 (xxhash.h / python-xxhash).
    assert_equal(xxhash64(String("").as_bytes()), UInt64(0xEF46DB3751D8E999))
    assert_equal(xxhash64(String("a").as_bytes()), UInt64(0xD24EC4F1A98C6E5B))
    assert_equal(xxhash64(String("abc").as_bytes()), UInt64(0x44BC2CF5AD770999))
    # 39 bytes: one 32-byte stripe, then the 4-byte lane and three 1-byte lanes.
    var long = String("Nobody inspects the spammish repetition")
    assert_equal(long.byte_length(), 39)
    assert_equal(xxhash64(long.as_bytes()), UInt64(0xFBCEA83C8A378BF1))


def test_xxhash64_hashes_only_the_window() raises:
    var s = String("xabcx")
    assert_equal(xxhash64(s.as_bytes()[1:4]), UInt64(0x44BC2CF5AD770999))


def test_eight_bytes_match_int64_paths() raises:
    var values: List[Int64] = [0, 1, -1, 0x0102030405060708, Int64.MIN]
    var bf = BloomFilter.create(1024, HashFamily.xxhash64())
    for i in range(len(values)):
        var le = _le8(values[i])
        assert_equal(xxhash64(Span(le)), xxhash64_int64(values[i]))
        assert_equal(bf.hash_bytes(Span(le)), bf.hash_int64(values[i]))


def test_hash_bytes_dispatches_on_family() raises:
    var a = String("a")
    var xx = BloomFilter.create(1024, HashFamily.xxhash64())
    var fnv = BloomFilter.create(1024, HashFamily.fnv1a())
    assert_equal(xx.hash_bytes(a.as_bytes()), UInt64(0xD24EC4F1A98C6E5B))
    # FNV-1a 64 reference values: "" is the offset basis.
    assert_equal(fnv.hash_bytes(a.as_bytes()), UInt64(0xAF63DC4C8601EC8C))
    assert_equal(
        fnv.hash_bytes(String("").as_bytes()), UInt64(0xCBF29CE484222325)
    )
    # A multi-byte vector: every byte of the input must feed the hash, so a
    # loop that reads one fixed byte (or stops early) gives another value.
    assert_equal(
        fnv.hash_bytes(String("foobar").as_bytes()), UInt64(0x85944171F73967E8)
    )


def test_from_bytes_copies_span_and_pads() raises:
    var raw = List[UInt8](capacity=40)
    for i in range(40):
        raw.append(UInt8(i + 1))
    # 7 bytes -> one 32-byte block: bytes 1..7 then zeros.
    var short = BloomFilter.from_bytes(Span(raw)[0:7])
    assert_equal(short.num_bytes, 32)
    assert_equal(short.num_blocks, 1)
    var got = _bf_bytes(short)
    for i in range(32):
        assert_equal(got[i], UInt8(i + 1) if i < 7 else UInt8(0))
    # 40 bytes -> two blocks: all 40 copied, 24 zero bytes of padding.
    var two = BloomFilter.from_bytes(Span(raw), HashFamily.fnv1a())
    assert_equal(two.num_bytes, 64)
    assert_true(two.hash_family.is_fnv1a())
    var got2 = _bf_bytes(two)
    for i in range(64):
        assert_equal(got2[i], UInt8(i + 1) if i < 40 else UInt8(0))
    # Empty Span -> one zero block.
    var empty = List[UInt8]()
    var z = BloomFilter.from_bytes(Span(empty))
    assert_equal(z.num_bytes, 32)
    var got3 = _bf_bytes(z)
    for i in range(32):
        assert_equal(got3[i], UInt8(0))


def test_insert_then_might_contain_bytes() raises:
    var families: List[HashFamily] = [HashFamily.xxhash64(), HashFamily.fnv1a()]
    for f in range(len(families)):
        var bf = BloomFilter.create(1024, families[f])
        var keys: List[String] = ["", "alpha", "Nobody inspects the spammish repetition"]
        for i in range(len(keys)):
            bf.insert_bytes(keys[i].as_bytes())
        for i in range(len(keys)):
            assert_true(bf.might_contain_bytes(keys[i].as_bytes()))
        # The filter holds the hash of the bytes, nothing else.
        var fresh = BloomFilter.create(1024, families[f])
        fresh.insert_hash(fresh.hash_bytes(keys[1].as_bytes()))
        var one = BloomFilter.create(1024, families[f])
        one.insert_bytes(keys[1].as_bytes())
        assert_true(_bf_bytes(fresh) == _bf_bytes(one))


def main() raises:
    var suite = TestSuite()
    suite.test[test_xxhash64_reference_vectors]()
    suite.test[test_xxhash64_hashes_only_the_window]()
    suite.test[test_eight_bytes_match_int64_paths]()
    suite.test[test_hash_bytes_dispatches_on_family]()
    suite.test[test_from_bytes_copies_span_and_pads]()
    suite.test[test_insert_then_might_contain_bytes]()
    suite^.run()
