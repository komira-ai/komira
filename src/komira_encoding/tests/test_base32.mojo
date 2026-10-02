# Base32: RFC 4648 section 10 vectors (padded and unpadded), case-insensitive
# decoding, the whole byte range, and round trips over lengths 0..64.

from komira_encoding import base32_encode, base32_encode_nopad, base32_decode

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
        "AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPSAIJCEMSCKJRH"
        "FAUSUKZMFUXC6MBRGIZTINJWG44DSOR3HQ6T4P2AIFBEGRCFIZDUQSKKJNGE2TSP"
        "KBIVEU2UKVLFOWCZLJNVYXK6L5QGCYTDMRSWMZ3INFVGW3DNNZXXA4LSON2HK5TX"
        "PB4XU634PV7H7AEBQKBYJBMGQ6EITCULRSGY5D4QSGJJHFEVS2LZRGM2TOOJ3HU7"
        "UCQ2FI5EUWTKPKFJVKV2ZLNOV6YLDMVTWS23NN5YXG5LXPF5X274BQOCYPCMLRWH"
        "ZDE4VS6MZXHM7UGR2LJ5JVOW27MNTWW33TO55X7A4HROHZHF43T6R2PK5PWO33XP"
        "6DY7F47U6X3PP6HZ7L57Z7P674======"
)


def test_rfc4648_section10() raises:
    var plain: List[String] = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    var enc: List[String] = [
        "",
        "MY======",
        "MZXQ====",
        "MZXW6===",
        "MZXW6YQ=",
        "MZXW6YTB",
        "MZXW6YTBOI======",
    ]
    var nopad: List[String] = [
        "", "MY", "MZXQ", "MZXW6", "MZXW6YQ", "MZXW6YTB", "MZXW6YTBOI"
    ]
    for i in range(len(plain)):
        var p = _bytes(plain[i])
        assert_equal(base32_encode(p), enc[i])
        assert_equal(base32_encode_nopad(p), nopad[i])
        assert_true(_same(base32_decode(enc[i]), p), enc[i])
        assert_true(_same(base32_decode(nopad[i]), p), nopad[i])
        assert_true(_same(base32_decode(enc[i].lower()), p), enc[i])


def test_mixed_case() raises:
    assert_true(_same(base32_decode(String("mZxW6yTbOi")), _bytes(String("foobar"))))


def test_every_byte_value() raises:
    var all = _all_bytes()
    assert_equal(base32_encode(all), String(_ALL))
    assert_true(_same(base32_decode(String(_ALL)), all))


def test_round_trip_lengths_0_to_64() raises:
    for n in range(65):
        var p = _pattern(n)
        assert_true(_same(base32_decode(base32_encode(p)), p), String(n))
        assert_true(_same(base32_decode(base32_encode_nopad(p)), p), String(n))
        assert_equal(base32_encode(p).byte_length(), (n + 4) // 5 * 8)
        assert_equal(base32_encode_nopad(p).byte_length(), (n * 8 + 4) // 5)



def test_round_trip_every_byte_value_at_every_length() raises:
    # Windows of the 256 byte values at four offsets: at length 64 the four
    # windows together hold every value.
    var all = _all_bytes()
    for n in range(65):
        for off in range(0, 256, 64):
            var p = List[UInt8]()
            for i in range(n):
                p.append(all[(off + i) & 0xFF])
            assert_true(_same(base32_decode(base32_encode(p)), p), String(n))
            assert_true(_same(base32_decode(base32_encode_nopad(p)), p), String(n))

def main() raises:
    test_rfc4648_section10()
    test_mixed_case()
    test_every_byte_value()
    test_round_trip_lengths_0_to_64()
    test_round_trip_every_byte_value_at_every_length()
    print("test_base32: OK")
