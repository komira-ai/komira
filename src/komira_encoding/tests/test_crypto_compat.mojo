# Compatibility with komira_crypto's codecs, for callers switching by import.
#
# A library test can only import the library's own deps, and this library
# has none, so komira_crypto's outputs are pinned here as literals (each is
# the standard encoding; komira_crypto's base64 is AWS-LC's EVP_EncodeBlock,
# its base32 and hex are Mojo). Name mapping, komira_crypto -> komira_encoding:
#
#   base64_encode, base64_decode, base64_url_encode,
#   base64_url_encode_nopad, base64_url_decode       same names
#   base32_encode_nopad, base32_decode               same names
#   hex_lower                                        hex_encode
#
# Deliberate differences, pinned below: komira_encoding rejects what
# komira_crypto tolerated -- in base32, whitespace anywhere, `=` anywhere
# (inside the input, or more of it than a block needs) and non-zero unused
# trailing bits (its base32 skipped the first two and dropped the third); in
# base64url, the standard symbols `+` and `/` (its decoder translated `-_`
# and passed `+/` through); in base64 and base64url, non-zero unused trailing
# bits (AWS-LC's EVP_DecodeBlock ignores them). Both libraries reject
# whitespace in base64.

from std.testing import assert_equal, assert_true

from komira_encoding import (
    base64_encode,
    base64_decode,
    base64_url_encode,
    base64_url_encode_nopad,
    base64_url_decode,
    base32_encode_nopad,
    base32_decode,
    hex_encode,
    error_kind,
)


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_base64_outputs_match() raises:
    var zeros = List[UInt8]()
    for _ in range(32):
        zeros.append(0)
    assert_equal(
        base64_encode(zeros),
        String("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
    )
    var high = List[UInt8]()
    for i in range(240, 256):
        high.append(UInt8(i))
    assert_equal(base64_encode(high), String("8PHy8/T19vf4+fr7/P3+/w=="))
    var fb: List[UInt8] = [0xFB, 0xFF]
    assert_equal(base64_encode(fb), String("+/8="))
    assert_equal(base64_url_encode(fb), String("-_8="))
    assert_equal(base64_url_encode_nopad(fb), String("-_8"))
    var fbfe: List[UInt8] = [0xFB, 0xFF, 0xFE]
    assert_equal(base64_url_encode(fbfe), String("-__-"))
    assert_equal(base64_encode(fbfe), String("+//+"))
    assert_true(_same(base64_decode(String("+//+")), fbfe))


def test_base64_decode_acceptance_matches() raises:
    # komira_crypto's base64_url_decode accepted padded and unpadded input.
    var fb: List[UInt8] = [0xFB, 0xFF]
    assert_true(_same(base64_url_decode(String("-_8=")), fb))
    assert_true(_same(base64_url_decode(String("-_8")), fb))
    assert_true(_same(base64_decode(String("+/8=")), fb))


def test_base32_outputs_match() raises:
    # komira_crypto's own test pattern: byte i = (i * 37 + 11) & 0xFF.
    var p = List[UInt8]()
    for i in range(20):
        p.append(UInt8((i * 37 + 11) & 0xFF))
    assert_equal(base32_encode_nopad(p), String("BMYFK6U7YTUQ4M2YPWRMP3ARGZNYBJOK"))
    assert_true(_same(base32_decode(String("BMYFK6U7YTUQ4M2YPWRMP3ARGZNYBJOK")), p))
    # Lower case, and a trailing `=` tail, were accepted and still are.
    assert_true(_same(base32_decode(String("bmyfk6u7ytuq4m2ypwrmp3argznybjok")), p))
    assert_true(_same(base32_decode(String("MZXW6YQ=")), base32_decode(String("MZXW6YQ"))))


def test_hex_outputs_match() raises:
    var b: List[UInt8] = [0x00, 0x0F, 0xA5, 0xFF]
    assert_equal(hex_encode(b), String("000fa5ff"))  # hex_lower's output


def _kind_of(which: Int, s: String) -> String:
    try:
        if which == 0:
            _ = base64_decode(s)
        elif which == 1:
            _ = base64_url_decode(s)
        else:
            _ = base32_decode(s)
    except e:
        return error_kind(e)
    return String("OK")


def test_deliberate_differences() raises:
    # base32: whitespace, `=` inside or beyond a block, trailing bits.
    assert_equal(_kind_of(2, "MZXW 6YTB OI"), String("InvalidCharacter"))
    assert_equal(_kind_of(2, "MZXW6YTBOI\n"), String("InvalidCharacter"))
    assert_equal(_kind_of(2, "MY==MY"), String("InvalidCharacter"))
    assert_equal(_kind_of(2, "MZXW6YQ=="), String("InvalidPadding"))
    assert_equal(_kind_of(2, "MZ"), String("NonCanonical"))
    # base64url: the standard alphabet's two symbols.
    assert_equal(_kind_of(1, "+/8="), String("InvalidCharacter"))
    assert_equal(_kind_of(1, "+/8"), String("InvalidCharacter"))
    # base64 and base64url: non-zero unused bits ("Zh==" is not canonical).
    assert_equal(_kind_of(0, "Zh=="), String("NonCanonical"))
    assert_equal(_kind_of(1, "Zh"), String("NonCanonical"))
    # Same in both: whitespace in base64 is rejected.
    assert_equal(_kind_of(0, "Zm9v\nYmFy"), String("InvalidCharacter"))


def main() raises:
    test_base64_outputs_match()
    test_base64_decode_acceptance_matches()
    test_base32_outputs_match()
    test_hex_outputs_match()
    test_deliberate_differences()
    print("test_crypto_compat: OK")
