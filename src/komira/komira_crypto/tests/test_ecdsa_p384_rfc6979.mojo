# =============================================================================
# komira_crypto/tests/test_ecdsa_p384_rfc6979.mojo
# =============================================================================
#
# RFC 6979 Appendix A.2.6 P-384 + SHA-384 Known-Answer Tests for ECDSA
# deterministic-k.
#
# Private key x =
#   6B9D3DAD2E1B8C1C05B19875B6659F4DE23C3B667BF297BA9AA47740787137D8
#   96D5724E4C70A825F872C9EA60D2EDF5
#
# Public key (Ux, Uy):
#   Ux = EC3A4E415B4E19A4568618029F427FA5DA9A8BC4AE92E02E06AAE5286B300C64
#        DEF8F0EA9055866064A254515480BC13
#   Uy = 8015D9B72D7D57244EA8EF9AC0C621896708A59367F9DFB9F54CA84B3F1C9DB1
#        288B231C3AE0D4FE7344FD2533264720
#
# Test messages "sample" and "test" with expected (r, s) per RFC 6979 §A.2.6:
#
#   message=sample  → r = 94EDBB92A5ECB8AAD4736E56C691916B3F88140666CE9FA73D64C4EA95AD133C
#                         81A648152E44ACF96E36DD1E80FABE46
#                     s = 99EF4AEB15F178CEA1FE40DB2603138F130E740A19624526203B6351D0A3A94F
#                         A329C145786E679E7B82C71A38628AC8
#
#   message=test    → r = 8203B63D3C853E8D77227FB377BCF7B7B772E97892A80F36AB775D509D7A5FEB
#                         0542A7F0812998DA8F1DD3CA3CF023DB
#                     s = DDD0760448D42D8A43AF45AF836FCE4DE8BE06B485E9B61B827C2F13173923E0
#                         6A739F040649A667BF3B828246BAA5A5
#
# These vectors prove BYTE-IDENTICAL deterministic-k output, locking the
# RFC 6979 HMAC-DRBG implementation against the spec.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto.ecdsa_p384 import (
    ecdsa_p384_sign_deterministic,
    ecdsa_p384_verify,
    ecdsa_p384_generate_pubkey,
)


def _hex_nibble(c: UInt8) -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    if c >= UInt8(0x41) and c <= UInt8(0x46):
        return c - UInt8(0x41) + UInt8(10)
    return UInt8(0xFF)


def _hex_to_48(s: String) -> Array[UInt8, 48]:
    var out = Array[UInt8, 48](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(48):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _hex_to_96(s: String) -> Array[UInt8, 96]:
    var out = Array[UInt8, 96](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(96):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


def _rfc6979_priv_384() -> Array[UInt8, 48]:
    return _hex_to_48(
        "6b9d3dad2e1b8c1c05b19875b6659f4de23c3b667bf297ba9aa47740787137d8"
        "96d5724e4c70a825f872c9ea60d2edf5"
    )


def _rfc6979_pub_384() -> Array[UInt8, 96]:
    # Ux || Uy
    return _hex_to_96(
        "ec3a4e415b4e19a4568618029f427fa5da9a8bc4ae92e02e06aae5286b300c64"
        "def8f0ea9055866064a254515480bc13"
        "8015d9b72d7d57244ea8ef9ac0c621896708a59367f9dfb9f54ca84b3f1c9db1"
        "288b231c3ae0d4fe7344fd2533264720"
    )


def _assert_sig_eq_96(
    got: Array[UInt8, 96],
    expected: Array[UInt8, 96],
    label: String,
) raises:
    for i in range(96):
        if got[i] != expected[i]:
            print("byte mismatch at", i, "for", label)
            print("  got: ", Int(got[i]), "  expected: ", Int(expected[i]))
            assert_equal(Int(got[i]), Int(expected[i]), label)


def test_rfc6979_a2_6_pubkey_derives() raises:
    """privkey from §A.2.6 derives expected pubkey (Ux, Uy)."""
    var priv = _rfc6979_priv_384()
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var expected_pub = _rfc6979_pub_384()
    for i in range(96):
        if pub[i] != expected_pub[i]:
            print("pubkey byte mismatch at", i)
            print("  got: ", Int(pub[i]), "  expected: ", Int(expected_pub[i]))
            assert_equal(Int(pub[i]), Int(expected_pub[i]), "pubkey byte")


def test_rfc6979_a2_6_sample() raises:
    """RFC 6979 §A.2.6 message='sample' expected (r, s)."""
    var priv = _rfc6979_priv_384()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    # Expected r || s per RFC 6979 §A.2.6 (P-384 + SHA-384, "sample")
    var expected = _hex_to_96(
        "94edbb92a5ecb8aad4736e56c691916b3f88140666ce9fa73d64c4ea95ad133c"
        "81a648152e44acf96e36dd1e80fabe46"
        "99ef4aeb15f178cea1fe40db2603138f130e740a19624526203b6351d0a3a94f"
        "a329c145786e679e7b82c71a38628ac8"
    )
    _assert_sig_eq_96(sig, expected, "RFC6979 §A.2.6 sample")


def test_rfc6979_a2_6_test() raises:
    """RFC 6979 §A.2.6 message='test' expected (r, s)."""
    var priv = _rfc6979_priv_384()
    var msg = String("test").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var expected = _hex_to_96(
        "8203b63d3c853e8d77227fb377bcf7b7b772e97892a80f36ab775d509d7a5feb"
        "0542a7f0812998da8f1dd3ca3cf023db"
        "ddd0760448d42d8a43af45af836fce4de8be06b485e9b61b827c2f13173923e0"
        "6a739f040649a667bf3b828246baa5a5"
    )
    _assert_sig_eq_96(sig, expected, "RFC6979 §A.2.6 test")


def test_rfc6979_a2_6_sample_verify() raises:
    """The §A.2.6 'sample' signature verifies under the §A.2.6 pubkey."""
    var pub = _rfc6979_pub_384()
    var msg = String("sample").as_bytes()
    var sig = _hex_to_96(
        "94edbb92a5ecb8aad4736e56c691916b3f88140666ce9fa73d64c4ea95ad133c"
        "81a648152e44acf96e36dd1e80fabe46"
        "99ef4aeb15f178cea1fe40db2603138f130e740a19624526203b6351d0a3a94f"
        "a329c145786e679e7b82c71a38628ac8"
    )
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "RFC6979 §A.2.6 sample signature verifies")


def test_rfc6979_a2_6_test_verify() raises:
    """The §A.2.6 'test' signature verifies under the §A.2.6 pubkey."""
    var pub = _rfc6979_pub_384()
    var msg = String("test").as_bytes()
    var sig = _hex_to_96(
        "8203b63d3c853e8d77227fb377bcf7b7b772e97892a80f36ab775d509d7a5feb"
        "0542a7f0812998da8f1dd3ca3cf023db"
        "ddd0760448d42d8a43af45af836fce4de8be06b485e9b61b827c2f13173923e0"
        "6a739f040649a667bf3b828246baa5a5"
    )
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "RFC6979 §A.2.6 test signature verifies")


def main() raises:
    print("== test_ecdsa_p384_rfc6979 ==")
    test_rfc6979_a2_6_pubkey_derives()
    print("  RFC6979 §A.2.6 pubkey derivation PASS")
    test_rfc6979_a2_6_sample()
    print("  RFC6979 §A.2.6 sign(sample) byte-identical PASS")
    test_rfc6979_a2_6_test()
    print("  RFC6979 §A.2.6 sign(test) byte-identical PASS")
    test_rfc6979_a2_6_sample_verify()
    print("  RFC6979 §A.2.6 verify(sample) PASS")
    test_rfc6979_a2_6_test_verify()
    print("  RFC6979 §A.2.6 verify(test) PASS")
    print("ALL 5 RFC 6979 §A.2.6 P-384 tests PASS")
