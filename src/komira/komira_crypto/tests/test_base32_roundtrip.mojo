# =============================================================================
# test_base32_roundtrip.mojo — RFC 4648 base32 encode/decode gate.
# =============================================================================
#
# The falsifying gate for `komira_crypto.base32`:
#   1. Pinned RFC 4648 §10 test vectors (the canonical "" / "f" / "fo" / "foo"
#      / "foob" / "fooba" / "foobar" -> base32 strings, WITHOUT padding).
#   2. Exhaustive round-trip: for every length 0..64, encode a deterministic
#      byte pattern then decode -> must equal the original bytes. FAILS if any
#      bit is lost/mangled in the 8<->5-bit repacking (the classic base32 bug).
#   3. Lowercase + whitespace tolerance on decode.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto import base32_encode_nopad, base32_decode


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _eq_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def test_rfc4648_vectors() raises:
    """RFC 4648 §10 base32 test vectors (no-pad form). FAILS if
    the 5-bit slicing / alphabet mapping is wrong."""
    assert_equal(base32_encode_nopad(String("").as_bytes()), String(""))
    assert_equal(base32_encode_nopad(String("f").as_bytes()), String("MY"))
    assert_equal(base32_encode_nopad(String("fo").as_bytes()), String("MZXQ"))
    assert_equal(base32_encode_nopad(String("foo").as_bytes()), String("MZXW6"))
    assert_equal(
        base32_encode_nopad(String("foob").as_bytes()), String("MZXW6YQ")
    )
    assert_equal(
        base32_encode_nopad(String("fooba").as_bytes()), String("MZXW6YTB")
    )
    assert_equal(
        base32_encode_nopad(String("foobar").as_bytes()), String("MZXW6YTBOI")
    )


def test_decode_vectors() raises:
    """Decode the RFC 4648 vectors back to the original ASCII bytes."""
    assert_true(_eq_bytes(base32_decode(String("MY")), _bytes_of(String("f"))))
    assert_true(
        _eq_bytes(base32_decode(String("MZXQ")), _bytes_of(String("fo")))
    )
    assert_true(
        _eq_bytes(base32_decode(String("MZXW6")), _bytes_of(String("foo")))
    )
    assert_true(
        _eq_bytes(
            base32_decode(String("MZXW6YTBOI")), _bytes_of(String("foobar"))
        )
    )


def test_exhaustive_roundtrip() raises:
    """For every length 0..64: encode a deterministic pattern then decode ->
    the decoded bytes MUST equal the input. FAILS if any bit is
    lost in the 8<->5-bit repacking."""
    for n in range(0, 65):
        var src = List[UInt8]()
        for i in range(n):
            # A spread pattern so every byte value class is exercised.
            src.append(UInt8((i * 37 + 11) & 0xFF))
        var enc = base32_encode_nopad(src)
        var dec = base32_decode(enc)
        assert_true(
            _eq_bytes(src, dec),
            String("base32 round-trip lost data at length ") + String(n),
        )


def test_lowercase_and_whitespace_tolerance() raises:
    """Decode accepts lowercase + embedded whitespace (a copy-paste artifact)."""
    var a = base32_decode(String("mzxw6ytboi"))  # lowercase
    var b = base32_decode(String("MZXW 6YTB OI"))  # spaced
    assert_true(_eq_bytes(a, _bytes_of(String("foobar"))))
    assert_true(_eq_bytes(b, _bytes_of(String("foobar"))))


def main() raises:
    test_rfc4648_vectors()
    test_decode_vectors()
    test_exhaustive_roundtrip()
    test_lowercase_and_whitespace_tolerance()
    print("test_base32_roundtrip: OK")
