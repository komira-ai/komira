# =============================================================================
# BloomFilter hash families: byte and Int64 hashing, byte-key insert/probe,
# and the join-key methods on a non-Fibonacci filter
# =============================================================================
#
# Oracles live in the test, never in the module under test:
#   - xxHash64 (seed 0): expected values computed by an independent
#     implementation of the published xxHash64 spec, which reproduces the
#     spec's own vectors ("", "a", "abc" are pinned below as well). The
#     byte lengths sweep every path of `xxhash64`: no tail, the 1-byte tail
#     only, the 4-byte lane only, the 8-byte lane, all three, and one, two
#     and partial 32-byte stripes, over bytes that include values >= 0x80.
#   - FNV-1a 64: an in-test loop plus published vectors.
#   - Bit placement: `_expected_words` re-derives the SBBF block index (upper
#     32 bits * blocks >> 32) and the eight salted mask bits, so a filter's
#     bytes are compared word for word with what the spec says it must hold.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily, xxhash64


def _salts() -> List[UInt32]:
    return [
        0x47B6137B, 0x44974D91, 0x8824AD5B, 0xA2B7289D,
        0x705495C7, 0x2DF1424B, 0x9EFC4947, 0x5C6BFB31,
    ]


def _pattern(n: Int) -> List[UInt8]:
    """`n` bytes `(i * 37 + 11) & 0xFF`: every byte value class, high bytes too."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8((i * 37 + 11) & 0xFF))
    return out^


def _text(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _fnv1a_oracle(data: List[UInt8]) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(data)):
        h = (h ^ UInt64(data[i])) * UInt64(0x100000001B3)
    return h


def _le_bytes(v: Int64) -> List[UInt8]:
    var out = List[UInt8](capacity=8)
    var u = UInt64(v)
    for _ in range(8):
        out.append(UInt8(u & 0xFF))
        u = u >> 8
    return out^


def _fib(key: Int64) -> UInt64:
    var h = UInt64(key) * UInt64(0x9E3779B97F4A7C15)
    return h ^ (h >> 32)


def _expected_words(num_bytes: Int, hashes: List[UInt64]) -> List[UInt32]:
    """The 32-bit words a zeroed filter of `num_bytes` holds after inserting
    `hashes`, derived from the SBBF spec."""
    var nblocks = num_bytes // 32
    var words = List[UInt32](length=num_bytes // 4, fill=0)
    var salts = _salts()
    for i in range(len(hashes)):
        var h = hashes[i]
        var blk = Int(((h >> 32) * UInt64(nblocks)) >> 32)
        var x = UInt32(h & 0xFFFFFFFF)
        for w in range(8):
            words[blk * 8 + w] |= UInt32(1) << ((x * salts[w]) >> 27)
    return words^


def _assert_words(bf: BloomFilter, expected: List[UInt32], ctx: String) raises:
    assert_equal(bf.num_bytes // 4, len(expected), ctx + ": size")
    for i in range(len(expected)):
        assert_equal(
            bf.data.get_typed[UInt32](i),
            expected[i],
            ctx + ": word " + String(i),
        )


def _lens() -> List[Int]:
    return [0, 1, 3, 4, 7, 8, 12, 15, 31, 32, 33, 36, 40, 47, 63, 64, 79]


def _xxh_of_pattern() -> List[UInt64]:
    return [
        0xEF46DB3751D8E999,  # 0
        0xF592C0C7639C4CB6,  # 1
        0x22C08528601D4F27,  # 3
        0xFB1E5CF2F1AE4D95,  # 4
        0x5613AC510496C04E,  # 7
        0x57CB2B7521F3E21A,  # 8
        0x2F53B00266039E64,  # 12
        0x90A9714EB00E8D29,  # 15
        0xE4A0E629E519A4AE,  # 31
        0xCC6B8AAADA790B2D,  # 32
        0x35EC49850475A832,  # 33
        0xBEBB6D8C24FB3CFA,  # 36
        0x3B21ED23EEA85C2D,  # 40
        0x16FDD9CA22942DDA,  # 47
        0xBF9F0BA3CF95B28A,  # 63
        0x155CCCE4BF32BEFC,  # 64
        0x87A81E99C6449ABD,  # 79
    ]


def _fnv_of_pattern() -> List[UInt64]:
    return [
        0xCBF29CE484222325,  # 0
        0xAF63C64C8601C72A,  # 1
        0x270C521898097401,  # 3
        0x6363FACA5810ED01,  # 4
        0xFCF25E868166B7A9,  # 7
        0x368E458DE18A10C5,  # 8
        0x94CC21F7F94E6ED1,  # 12
        0x80B6147D06F684A1,  # 15
        0xDFC36F0F555EEA21,  # 31
        0x98005E0E1048B9C5,  # 32
        0x91593FE5AB9315EA,  # 33
        0x612C12B2996E09E1,  # 36
        0xBB1DD1DF04A190E5,  # 40
        0x85CAA53E5137DAE1,  # 47
        0x2CE10C732A266921,  # 63
        0x68D12EB09F4476E5,  # 64
        0x79D31FAAF55002A1,  # 79
    ]


def _int_keys() -> List[Int64]:
    return [
        0, 1, -1, 0x0123456789ABCDEF, Int64.MIN, Int64.MAX,
    ]


def _xxh_of_int() -> List[UInt64]:
    return [
        0x34C96ACDCADB1BBB,
        0x9F29CB17A2A49995,
        0x85D136ADB773C6C9,
        0xEA3C52081E9843EC,
        0x3F425EACF01544E0,
        0xFF70CC60366E770C,
    ]


def _fnv_of_int() -> List[UInt64]:
    return [
        0xA8C7F832281A39C5,
        0x89CD31291D2AEFA4,
        0x8CF51A8BFCA3883D,
        0x37EB3F3347761C55,
        0xA8C7783228196045,
        0x8CF59A8BFCA461BD,
    ]


def test_xxhash64_published_vectors() raises:
    """The xxHash64 spec's seed-0 vectors, through the free function and
    through an xxHash64 filter's `hash_bytes`."""
    var bf = BloomFilter.create(64)
    var words: List[String] = ["", "a", "abc"]
    var want: List[UInt64] = [0xEF46DB3751D8E999, 0xD24EC4F1A98C6E5B, 0x44BC2CF5AD770999]
    for i in range(len(words)):
        var b = _text(words[i])
        assert_equal(xxhash64(b.unsafe_ptr(), len(b)), want[i], "xxhash64 '" + words[i] + "'")
        assert_equal(bf.hash_bytes(b.unsafe_ptr(), len(b)), want[i], "hash_bytes '" + words[i] + "'")


def test_xxhash64_every_tail_and_stripe_length() raises:
    var data = _pattern(80)
    var bf = BloomFilter.create(64)
    for i in range(len(_lens())):
        var n = _lens()[i]
        assert_equal(xxhash64(data.unsafe_ptr(), n), _xxh_of_pattern()[i], "xxhash64 length " + String(n))
        assert_equal(bf.hash_bytes(data.unsafe_ptr(), n), _xxh_of_pattern()[i], "hash_bytes length " + String(n))


def test_fnv1a_hash_bytes() raises:
    """An FNV-1a filter hashes bytes with FNV-1a: published vectors, then the
    pattern sweep against the in-test loop and the precomputed table."""
    var bf = BloomFilter.create(64, HashFamily.fnv1a())
    var words: List[String] = ["", "a", "foobar"]
    var want: List[UInt64] = [0xCBF29CE484222325, 0xAF63DC4C8601EC8C, 0x85944171F73967E8]
    for i in range(len(words)):
        var b = _text(words[i])
        assert_equal(bf.hash_bytes(b.unsafe_ptr(), len(b)), want[i], "fnv1a '" + words[i] + "'")
    var data = _pattern(80)
    for i in range(len(_lens())):
        var n = _lens()[i]
        var prefix = List[UInt8](capacity=n)
        for j in range(n):
            prefix.append(data[j])
        assert_equal(_fnv1a_oracle(prefix), _fnv_of_pattern()[i], "oracle length " + String(n))
        assert_equal(bf.hash_bytes(data.unsafe_ptr(), n), _fnv_of_pattern()[i], "fnv1a length " + String(n))


def test_hash_int64_per_family() raises:
    """`hash_int64` hashes the key's eight little-endian bytes with the
    filter's family: xxHash64, FNV-1a, or the Fibonacci join hash."""
    var x = BloomFilter.create(64)
    var f = BloomFilter.create(64, HashFamily.fnv1a())
    var j = BloomFilter.create(64, HashFamily.fibonacci_join())
    for i in range(len(_int_keys())):
        var k = _int_keys()[i]
        var le = _le_bytes(k)
        assert_equal(x.hash_int64(k), _xxh_of_int()[i], "xxhash64 key " + String(k))
        assert_equal(xxhash64(le.unsafe_ptr(), 8), _xxh_of_int()[i], "xxhash64 bytes of key " + String(k))
        assert_equal(f.hash_int64(k), _fnv_of_int()[i], "fnv1a key " + String(k))
        assert_equal(_fnv1a_oracle(le), _fnv_of_int()[i], "fnv1a oracle key " + String(k))
        assert_equal(j.hash_int64(k), _fib(k), "fibonacci key " + String(k))


def test_fnv1a_int64_insert_sets_spec_bits() raises:
    """`insert_int64` on an FNV-1a filter sets exactly the bits of the FNV-1a
    hash of the key, and `might_contain_int64` finds every key."""
    var bf = BloomFilter.create(256, HashFamily.fnv1a())
    var hashes = List[UInt64]()
    for i in range(len(_int_keys())):
        bf.insert_int64(_int_keys()[i])
        hashes.append(_fnv_of_int()[i])
    _assert_words(bf, _expected_words(256, hashes), "fnv1a insert_int64")
    for i in range(len(_int_keys())):
        assert_true(bf.might_contain_int64(_int_keys()[i]), "fnv1a key " + String(_int_keys()[i]))


def _bytes_round_trip(family: HashFamily, table: List[UInt64], ctx: String) raises:
    var data = _pattern(80)
    var bf = BloomFilter.create(1024, family)
    var hashes = List[UInt64]()
    # Every second length is inserted; the others are probed as absent.
    for i in range(0, len(_lens()), 2):
        bf.insert_bytes(data.unsafe_ptr(), _lens()[i])
        hashes.append(table[i])
    _assert_words(bf, _expected_words(1024, hashes), ctx + " insert_bytes")
    var expected = _expected_words(1024, hashes)
    var salts = _salts()
    for i in range(len(_lens())):
        var n = _lens()[i]
        # Whether the spec says this hash's eight bits are all set.
        var h = table[i]
        var blk = Int(((h >> 32) * UInt64(1024 // 32)) >> 32)
        var x = UInt32(h & 0xFFFFFFFF)
        var all_set = True
        for w in range(8):
            if (expected[blk * 8 + w] & (UInt32(1) << ((x * salts[w]) >> 27))) == 0:
                all_set = False
        if i % 2 == 0:
            assert_true(all_set, ctx + ": oracle must hold inserted length " + String(n))
        assert_equal(
            bf.might_contain_bytes(data.unsafe_ptr(), n),
            all_set,
            ctx + " might_contain_bytes length " + String(n),
        )
        assert_equal(bf.check_hash(h), all_set, ctx + " check_hash length " + String(n))


def test_bytes_round_trip_xxhash64() raises:
    _bytes_round_trip(HashFamily.xxhash64(), _xxh_of_pattern(), "xxhash64")


def test_bytes_round_trip_fnv1a() raises:
    _bytes_round_trip(HashFamily.fnv1a(), _fnv_of_pattern(), "fnv1a")


def test_bytes_absent_key_reported_absent() raises:
    """A key whose bits are not all set must be reported absent: one byte-string
    key in a 32-byte filter, probed with the other lengths."""
    var data = _pattern(80)
    var bf = BloomFilter.create(32)
    bf.insert_bytes(data.unsafe_ptr(), 47)
    var hashes: List[UInt64] = [_xxh_of_pattern()[13]]
    var expected = _expected_words(32, hashes)
    _assert_words(bf, expected, "single key")
    var absent = 0
    for i in range(len(_lens())):
        var hit = bf.might_contain_bytes(data.unsafe_ptr(), _lens()[i])
        if not hit:
            absent += 1
    assert_true(bf.might_contain_bytes(data.unsafe_ptr(), 47), "inserted key")
    assert_true(absent > 0, "a one-key filter must reject some other key")


def _first_absent_hash(bf: BloomFilter) -> UInt64:
    """A hash `check_hash` rejects (so a probe through it must say absent)."""
    var h = UInt64(0x0123456789ABCDEF)
    while bf.check_hash(h):
        h = h * UInt64(6364136223846793005) + UInt64(1442695040888963407)
    return h


def test_join_key_methods_on_non_fibonacci_filters_use_the_key() raises:
    """On a non-Fibonacci filter `insert_join_key` and
    `might_contain_join_key` ignore the caller's hash and hash the key with
    the filter's own family."""
    for fam_i in range(2):
        var family = HashFamily.xxhash64() if fam_i == 0 else HashFamily.fnv1a()
        var ints = _xxh_of_int() if fam_i == 0 else _fnv_of_int()
        var bf = BloomFilter.create(1024, family)
        var bogus = _first_absent_hash(bf)
        var hashes = List[UInt64]()
        for i in range(len(_int_keys())):
            bf.insert_join_key(_int_keys()[i], bogus)
            hashes.append(ints[i])
        _assert_words(bf, _expected_words(1024, hashes), "insert_join_key family " + String(fam_i))
        # An empty filter rejects every key; the probe must still hash the key.
        var empty = BloomFilter.create(1024, family)
        var bogus2 = _first_absent_hash(bf)
        for i in range(len(_int_keys())):
            assert_true(
                bf.might_contain_join_key(_int_keys()[i], bogus2),
                "might_contain_join_key family " + String(fam_i) + " key " + String(_int_keys()[i]),
            )
            assert_false(
                empty.might_contain_join_key(_int_keys()[i], hashes[i]),
                "empty filter family " + String(fam_i),
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
