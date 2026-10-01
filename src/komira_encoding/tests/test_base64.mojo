# Base64 and base64url: RFC 4648 section 10 vectors, RFC 7515 examples,
# the whole alphabet, and round trips over lengths 0..64.

from komira_encoding import (
    base64_encode,
    base64_decode,
    base64_url_encode,
    base64_url_encode_nopad,
    base64_url_decode,
    base64_url_decode_nopad,
)

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


comptime _ALL_STD = (
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v"
        "MDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f"
        "YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6P"
        "kJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/"
        "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v"
        "8PHy8/T19vf4+fr7/P3+/w=="
)
comptime _ALL_URL = (
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v"
        "MDEyMzQ1Njc4OTo7PD0-P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f"
        "YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn-AgYKDhIWGh4iJiouMjY6P"
        "kJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq-wsbKztLW2t7i5uru8vb6_"
        "wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t_g4eLj5OXm5-jp6uvs7e7v"
        "8PHy8_T19vf4-fr7_P3-_w=="
)


def test_rfc4648_section10() raises:
    var plain: List[String] = ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
    var enc: List[String] = [
        "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"
    ]
    var nopad: List[String] = ["", "Zg", "Zm8", "Zm9v", "Zm9vYg", "Zm9vYmE", "Zm9vYmFy"]
    for i in range(len(plain)):
        var p = _bytes(plain[i])
        assert_equal(base64_encode(p), enc[i])
        assert_equal(base64_url_encode(p), enc[i])
        assert_equal(base64_url_encode_nopad(p), nopad[i])
        assert_true(_same(base64_decode(enc[i]), p), enc[i])
        assert_true(_same(base64_url_decode(enc[i]), p), enc[i])
        assert_true(_same(base64_url_decode(nopad[i]), p), nopad[i])
        assert_true(_same(base64_url_decode_nopad(nopad[i]), p), nopad[i])


def test_rfc7515_examples() raises:
    # RFC 7515 section 3.3: the JWS Protected Header of the example.
    var header = _bytes(String('{"typ":"JWT",\r\n "alg":"HS256"}'))
    comptime h = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9"
    assert_equal(base64_url_encode_nopad(header), String(h))
    assert_true(_same(base64_url_decode_nopad(String(h)), header))
    # RFC 7515 appendix C: the octets 3, 236, 255, 224, 193.
    var c: List[UInt8] = [3, 236, 255, 224, 193]
    assert_equal(base64_url_encode_nopad(c), String("A-z_4ME"))
    assert_equal(base64_url_encode(c), String("A-z_4ME="))
    assert_true(_same(base64_url_decode_nopad(String("A-z_4ME")), c))
    assert_true(_same(base64_url_decode(String("A-z_4ME=")), c))
    # RFC 7515 appendix A.1: the HMAC key decodes to 64 octets and re-encodes.
    comptime k = (
        "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4h"
        "cgUuTwjAzZr1Z9CAow"
    )
    var key = base64_url_decode_nopad(String(k))
    assert_equal(len(key), 64)
    assert_equal(base64_url_encode_nopad(key), String(k))


def test_every_byte_value() raises:
    var all = _all_bytes()
    assert_equal(base64_encode(all), String(_ALL_STD))
    assert_equal(base64_url_encode(all), String(_ALL_URL))
    assert_true(_same(base64_decode(String(_ALL_STD)), all))
    assert_true(_same(base64_url_decode(String(_ALL_URL)), all))


def test_round_trip_lengths_0_to_64() raises:
    for n in range(65):
        var p = _pattern(n)
        assert_true(_same(base64_decode(base64_encode(p)), p), String(n))
        assert_true(_same(base64_url_decode(base64_url_encode(p)), p), String(n))
        var np = base64_url_encode_nopad(p)
        assert_true(_same(base64_url_decode(np), p), String(n))
        assert_true(_same(base64_url_decode_nopad(np), p), String(n))
        assert_equal(base64_encode(p).byte_length(), (n + 2) // 3 * 4)
        assert_equal(np.byte_length(), (n * 8 + 5) // 6)


def test_span_and_string_inputs_agree() raises:
    var s = String("Zm9vYmE=")
    assert_true(_same(base64_decode(s.as_bytes()), base64_decode(s)))



def test_round_trip_every_byte_value_at_every_length() raises:
    # Windows of the 256 byte values at four offsets: at length 64 the four
    # windows together hold every value, and each length starts each window
    # at a different alignment against the 3-byte groups.
    var all = _all_bytes()
    for n in range(65):
        for off in range(0, 256, 64):
            var p = List[UInt8]()
            for i in range(n):
                p.append(all[(off + i) & 0xFF])
            assert_true(_same(base64_decode(base64_encode(p)), p), String(n))
            assert_true(_same(base64_url_decode(base64_url_encode(p)), p), String(n))
            assert_true(
                _same(base64_url_decode_nopad(base64_url_encode_nopad(p)), p),
                String(n),
            )

def main() raises:
    test_rfc4648_section10()
    test_rfc7515_examples()
    test_every_byte_value()
    test_round_trip_lengths_0_to_64()
    test_round_trip_every_byte_value_at_every_length()
    test_span_and_string_inputs_agree()
    print("test_base64: OK")
