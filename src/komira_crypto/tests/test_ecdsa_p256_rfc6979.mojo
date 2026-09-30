# =============================================================================
# komira_crypto/tests/test_ecdsa_p256_rfc6979.mojo
# =============================================================================
#
# RFC 6979 Appendix A.2.5 P-256 + SHA-256 Known-Answer Tests for ECDSA
# deterministic-k.
#
# Private key x = C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721
# Public key (Ux, Uy):
#   Ux = 60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6
#   Uy = 7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299
#
# Test messages "sample" and "test" with expected (r, s) per RFC 6979 §A.2.5:
#
#   message=sample  → r = EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716
#                     s = F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8
#
#   message=test    → r = F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367
#                     s = 019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083
#
# These vectors prove BYTE-IDENTICAL deterministic-k output, locking the
# RFC 6979 HMAC-DRBG implementation against the spec.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto.ecdsa_p256 import (
    ecdsa_p256_sign_deterministic,
    ecdsa_p256_verify,
    ecdsa_p256_generate_pubkey,
)


def _hex_nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return c - UInt8(0x41) + UInt8(10)
    return UInt8(0xFF)


def _hex_to_32(s: String) -> Array[UInt8, 32]:
    var out = Array[UInt8, 32](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(32):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _hex_to_64(s: String) -> Array[UInt8, 64]:
    var out = Array[UInt8, 64](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(64):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _rfc6979_priv() -> Array[UInt8, 32]:
    return _hex_to_32(
        "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"
    )


def _rfc6979_pub() -> Array[UInt8, 64]:
    # Ux || Uy
    return _hex_to_64(
        "60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6"
        "7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299"
    )


def _assert_sig_eq(
    got: Array[UInt8, 64],
    expected: Array[UInt8, 64],
    label: String,
) raises:
    for i in range(64):
        if got[i] != expected[i]:
            print("byte mismatch at", i, "for", label)
            print("  got: ", Int(got[i]), "  expected: ", Int(expected[i]))
            assert_equal(Int(got[i]), Int(expected[i]), label)


def test_rfc6979_a2_5_sample() raises:
    """RFC 6979 §A.2.5 message="sample" expected (r, s)."""
    var priv = _rfc6979_priv()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    # Expected r || s per RFC 6979 §A.2.5
    var expected = _hex_to_64(
        "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716"
        "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8"
    )
    _assert_sig_eq(sig, expected, "RFC6979 §A.2.5 sample")


def test_rfc6979_a2_5_test() raises:
    """RFC 6979 §A.2.5 message="test" expected (r, s)."""
    var priv = _rfc6979_priv()
    var msg = String("test").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var expected = _hex_to_64(
        "f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367"
        "019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083"
    )
    _assert_sig_eq(sig, expected, "RFC6979 §A.2.5 test")


def test_rfc6979_a2_5_pubkey_derives() raises:
    """privkey from §A.2.5 derives expected pubkey (Ux, Uy)."""
    var priv = _rfc6979_priv()
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var expected_pub = _rfc6979_pub()
    for i in range(64):
        if pub[i] != expected_pub[i]:
            print("pubkey byte mismatch at", i)
            print("  got: ", Int(pub[i]), "  expected: ", Int(expected_pub[i]))
            assert_equal(Int(pub[i]), Int(expected_pub[i]), "pubkey byte")


def test_rfc6979_a2_5_sample_verify() raises:
    """The §A.2.5 "sample" signature verifies under the §A.2.5 pubkey."""
    var pub = _rfc6979_pub()
    var msg = String("sample").as_bytes()
    var sig = _hex_to_64(
        "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716"
        "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8"
    )
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "RFC6979 §A.2.5 sample signature verifies")


def test_rfc6979_a2_5_test_verify() raises:
    """The §A.2.5 "test" signature verifies under the §A.2.5 pubkey."""
    var pub = _rfc6979_pub()
    var msg = String("test").as_bytes()
    var sig = _hex_to_64(
        "f1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367"
        "019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083"
    )
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "RFC6979 §A.2.5 test signature verifies")


def main() raises:
    print("== test_ecdsa_p256_rfc6979 ==")
    test_rfc6979_a2_5_pubkey_derives()
    print("  RFC6979 §A.2.5 pubkey derivation PASS")
    test_rfc6979_a2_5_sample()
    print("  RFC6979 §A.2.5 sign(sample) byte-identical PASS")
    test_rfc6979_a2_5_test()
    print("  RFC6979 §A.2.5 sign(test) byte-identical PASS")
    test_rfc6979_a2_5_sample_verify()
    print("  RFC6979 §A.2.5 verify(sample) PASS")
    test_rfc6979_a2_5_test_verify()
    print("  RFC6979 §A.2.5 verify(test) PASS")
    print("ALL 5 RFC 6979 §A.2.5 P-256 tests PASS")
