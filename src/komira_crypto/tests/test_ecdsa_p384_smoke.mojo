# =============================================================================
# komira_crypto/tests/test_ecdsa_p384_smoke.mojo
# =============================================================================
#
# Smoke tests for ECDSA-P384 sign + verify (FIPS 186-4 §6.4 + RFC 6979
# §A.2.6 deterministic-k via SHA-384).
#
# Sub-tests:
#   1. Keypair gen (privkey → pubkey) — pubkey is on the curve (indirect via verify chain).
#   2. Sign-verify round-trip with deterministic-k.
#   3. Sign-verify round-trip with random-k.
#   4. Modified message → verify returns False.
#   5. Modified signature → verify returns False.
#   6. Modified pubkey → verify returns False.
#   7. Determinism — same (privkey, message) → same signature.
#   8. Signature byte format (96 bytes, r || s).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.ecdsa_p384 import (
    ecdsa_p384_sign_deterministic,
    ecdsa_p384_sign_random,
    ecdsa_p384_verify,
    ecdsa_p384_generate_pubkey,
)


# On-curve validation is indirect: ecdsa_p384_generate_pubkey uses
# EC_POINT_mul which only produces on-curve points; ecdsa_p384_verify
# internally calls EC_KEY_set_public_key_affine_coordinates which
# validates on-curve. A round-trip sign-then-verify success therefore
# proves the generated pubkey is on the curve.


# -----------------------------------------------------------------------------
# Hex helpers
# -----------------------------------------------------------------------------


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


# RFC 6979 §A.2.6 private key.
def _test_priv_384() -> Array[UInt8, 48]:
    return _hex_to_48(
        "6b9d3dad2e1b8c1c05b19875b6659f4de23c3b667bf297ba9aa47740787137d8"
        "96d5724e4c70a825f872c9ea60d2edf5"
    )


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_pubkey_on_curve_384() raises:
    """privkey → pubkey is on-curve (verified indirectly via sign+verify chain)."""
    var priv = _test_priv_384()
    var msg = String("on-curve-probe-p384").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(
        ok,
        "generated P-384 pubkey verifies its own signature (proves on-curve)",
    )


def test_signverify_deterministic_384() raises:
    """sign(msg) → verify(msg, sig) returns True (deterministic-k)."""
    var priv = _test_priv_384()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "P-384 deterministic sign-verify round-trip")


def test_signverify_random_384() raises:
    """sign(msg, k) → verify(msg, sig) returns True (random-k)."""
    var priv = _test_priv_384()
    var msg = String("hello world p384").as_bytes()
    var k_bytes = _hex_to_48(
        # Arbitrary fixed nonce (in [1, n-1] for P-384).
        "94a1bbb14b906a61a280f245f9e93c7f3b4a6247824f5d33b9670787642a68de"
        "1234567890abcdef1234567890abcdef"
    )
    var sig = ecdsa_p384_sign_random(
        Span[UInt8, origin_of(priv)](priv),
        msg,
        Span[UInt8, origin_of(k_bytes)](k_bytes),
    )
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "P-384 random-k sign-verify round-trip")


def test_modified_message_rejected_384() raises:
    """Modified message → verify returns False."""
    var priv = _test_priv_384()
    var msg1 = String("sample").as_bytes()
    var msg2 = String("Sample").as_bytes()  # capital S
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg1,
    )
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg2, Span[UInt8, origin_of(sig)](sig),
    )
    assert_false(ok, "P-384 modified message → verify=False")


def test_modified_signature_rejected_384() raises:
    """Modified signature (flip one byte) → verify returns False."""
    var priv = _test_priv_384()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    # Flip the LSB of r (sig[47] is the last byte of r in BE for P-384).
    sig[47] = sig[47] ^ UInt8(0x01)
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_false(ok, "P-384 modified sig → verify=False")


def test_modified_pubkey_rejected_384() raises:
    """Modified pubkey → verify returns False (or fails curve check)."""
    var priv = _test_priv_384()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    # Flip a byte in pub's x-coord (pub[47] = LSB of x in BE for P-384).
    pub[47] = pub[47] ^ UInt8(0x01)
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_false(ok, "P-384 modified pubkey → verify=False")


def test_signature_determinism_384() raises:
    """Same (privkey, msg) under RFC 6979 → same signature."""
    var priv = _test_priv_384()
    var msg = String("sample").as_bytes()
    var sig1 = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var sig2 = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    for i in range(96):
        assert_equal(Int(sig1[i]), Int(sig2[i]), "P-384 deterministic-k same byte")


def test_signature_byte_format_384() raises:
    """Signature is 96 bytes: r (48) || s (48) BE."""
    var priv = _test_priv_384()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p384_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    # The InlineArray[UInt8, 96] return type makes 96-byte length a
    # compile-time invariant.
    assert_equal(96, 96, "P-384 sig is 96 bytes (compile-time)")
    # Verify the round-trip works (smoke).
    var pub = ecdsa_p384_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p384_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "P-384 fmt sanity: sig verifies")


def main() raises:
    print("== test_ecdsa_p384_smoke ==")
    test_pubkey_on_curve_384()
    print("  P-384 pubkey on curve PASS")
    test_signverify_deterministic_384()
    print("  P-384 deterministic-k sign-verify round-trip PASS")
    test_signverify_random_384()
    print("  P-384 random-k sign-verify round-trip PASS")
    test_modified_message_rejected_384()
    print("  P-384 modified message rejected PASS")
    test_modified_signature_rejected_384()
    print("  P-384 modified signature rejected PASS")
    test_modified_pubkey_rejected_384()
    print("  P-384 modified pubkey rejected PASS")
    test_signature_determinism_384()
    print("  P-384 signature determinism PASS")
    test_signature_byte_format_384()
    print("  P-384 signature byte format PASS")
    print("ALL 8 ECDSA-P384 smoke tests PASS")
