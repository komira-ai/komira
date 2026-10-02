# Hex (base16): RFC 4648 section 10 vectors, case-insensitive decoding, the
# whole byte range, and round trips over lengths 0..64.

from komira_encoding import hex_encode, hex_decode

from std.testing import assert_equal, assert_true


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _all_bytes() -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(256):
        out.append(UInt8(i))
    return out^


def _pattern(n: Int) -> List[UInt8]:
    """Return n bytes in a spread pattern that differs per length."""
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i * 37 + n * 101 + 11) & 0xFF))
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


comptime _ALL = (
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
        "404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"
        "606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f"
        "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"
        "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
        "c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedf"
        "e0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
)


def test_rfc4648_section10() raises:
    var plain: List[String] = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    var upper: List[String] = [
        "", "66", "666F", "666F6F", "666F6F62", "666F6F6261", "666F6F626172"
    ]
    for i in range(len(plain)):
        var p = _bytes(plain[i])
        # The RFC prints upper case; this library encodes lower case.
        assert_equal(hex_encode(p), upper[i].lower())
        assert_true(_same(hex_decode(upper[i]), p), upper[i])
        assert_true(_same(hex_decode(upper[i].lower()), p), upper[i])


def test_mixed_case() raises:
    var expected: List[UInt8] = [0xAB, 0xCD, 0xEF]
    assert_true(_same(hex_decode(String("aBcDeF")), expected))


def test_every_byte_value() raises:
    var all = _all_bytes()
    assert_equal(hex_encode(all), String(_ALL))
    assert_true(_same(hex_decode(String(_ALL)), all))
    assert_true(_same(hex_decode(String(_ALL).upper()), all))


def test_round_trip_lengths_0_to_64() raises:
    for n in range(65):
        var p = _pattern(n)
        var e = hex_encode(p)
        assert_equal(e.byte_length(), 2 * n)
        assert_true(_same(hex_decode(e), p), String(n))



def test_round_trip_every_byte_value_at_every_length() raises:
    # Windows of the 256 byte values at four offsets: at length 64 the four
    # windows together hold every value.
    var all = _all_bytes()
    for n in range(65):
        for off in range(0, 256, 64):
            var p = List[UInt8]()
            for i in range(n):
                p.append(all[(off + i) & 0xFF])
            assert_true(_same(hex_decode(hex_encode(p)), p), String(n))

def main() raises:
    test_rfc4648_section10()
    test_mixed_case()
    test_every_byte_value()
    test_round_trip_lengths_0_to_64()
    test_round_trip_every_byte_value_at_every_length()
    print("test_hex: OK")
