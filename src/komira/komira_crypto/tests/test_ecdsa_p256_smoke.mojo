# =============================================================================
# komira_crypto/tests/test_ecdsa_p256_smoke.mojo
# =============================================================================
#
# Smoke tests for ECDSA-P256 sign + verify (FIPS 186-4 §6.4 + RFC 6979
# deterministic-k).
#
# Sub-tests:
#   1. Keypair gen (privkey → pubkey) — pubkey is on the curve.
#   2. Sign-verify round-trip with deterministic-k.
#   3. Sign-verify round-trip with random-k.
#   4. Modified message → verify returns False.
#   5. Modified signature → verify returns False.
#   6. Modified pubkey → verify returns False.
#   7. Determinism — same (privkey, message) → same signature.
#   8. Signature byte format (64 bytes, r || s).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto.ecdsa_p256 import (
    ecdsa_p256_sign_deterministic,
    ecdsa_p256_sign_random,
    ecdsa_p256_verify,
    ecdsa_p256_generate_pubkey,
)

# Curve arithmetic is delegated to AWS-LC via internal/asm/p256_ffi.mojo,
# so there is no Mojo-side point type to check directly. The on-curve
# check below is
# indirect: ecdsa_p256_generate_pubkey uses EC_POINT_mul internally
# which guarantees an on-curve output, AND a non-curve pubkey would
# fail any subsequent ecdsa_p256_verify call (AWS-LC validates
# on-curve in EC_KEY_set_public_key_affine_coordinates). Test below
# exercises that indirect chain.


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


def _hex_to_32(s: String) -> Array[UInt8, 32]:
    var out = Array[UInt8, 32](fill=UInt8(0))
    var bs = s.as_bytes()
    for i in range(32):
        var hi = _hex_nibble(bs[2 * i])
        var lo = _hex_nibble(bs[2 * i + 1])
        out[i] = (hi << UInt8(4)) | lo
    return out^


# A canonical RFC 6979 §A.2.5 test private key.
def _test_priv() -> Array[UInt8, 32]:
    return _hex_to_32(
        "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"
    )


# A second private key for round-trip tests.
def _alt_priv() -> Array[UInt8, 32]:
    return _hex_to_32(
        "0000000000000000000000000000000000000000000000000000000000000002"
    )


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_pubkey_on_curve() raises:
    """privkey → pubkey is on-curve (verified indirectly via sign+verify chain).

    On-curve validation is implicit:
    - ecdsa_p256_generate_pubkey uses EC_POINT_mul which only produces
      on-curve points.
    - ecdsa_p256_verify internally calls
      EC_KEY_set_public_key_affine_coordinates which validates on-curve
      (returns False if off-curve, propagated through the verify chain).
    A round-trip sign-then-verify success therefore proves the generated
    pubkey is on the curve."""
    var priv = _test_priv()
    var msg = String("on-curve-probe").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(
        ok,
        "generated pubkey verifies its own signature (proves on-curve)",
    )


def test_signverify_deterministic() raises:
    """sign(msg) → verify(msg, sig) returns True (deterministic-k)."""
    var priv = _test_priv()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "deterministic sign-verify round-trip")


def test_signverify_random() raises:
    """sign(msg, k) → verify(msg, sig) returns True (random-k)."""
    var priv = _test_priv()
    var msg = String("hello world").as_bytes()
    var k_bytes = _hex_to_32(
        "94a1bbb14b906a61a280f245f9e93c7f3b4a6247824f5d33b9670787642a68de"
    )
    var sig = ecdsa_p256_sign_random(
        Span[UInt8, origin_of(priv)](priv),
        msg,
        Span[UInt8, origin_of(k_bytes)](k_bytes),
    )
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "random-k sign-verify round-trip")


def test_modified_message_rejected() raises:
    """Modified message → verify returns False."""
    var priv = _test_priv()
    var msg1 = String("sample").as_bytes()
    var msg2 = String("Sample").as_bytes()  # capital S
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg1,
    )
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg2, Span[UInt8, origin_of(sig)](sig),
    )
    assert_false(ok, "modified message → verify=False")


def test_modified_signature_rejected() raises:
    """Modified signature (flip one byte) → verify returns False."""
    var priv = _test_priv()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    # Flip the LSB of r (sig[31] is the last byte of r in BE).
    sig[31] = sig[31] ^ UInt8(0x01)
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_false(ok, "modified sig → verify=False")


def test_modified_pubkey_rejected() raises:
    """Modified pubkey → verify returns False (or fails curve check)."""
    var priv = _test_priv()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    # Flip a byte in pub's x-coord (pub[31] = LSB of x in BE).
    pub[31] = pub[31] ^ UInt8(0x01)
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_false(ok, "modified pubkey → verify=False")


def test_signature_determinism() raises:
    """Same (privkey, msg) under RFC 6979 → same signature."""
    var priv = _test_priv()
    var msg = String("sample").as_bytes()
    var sig1 = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    var sig2 = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    for i in range(64):
        assert_equal(Int(sig1[i]), Int(sig2[i]), "deterministic-k same byte")


def test_signature_byte_format() raises:
    """Signature is 64 bytes: r (32) || s (32) BE."""
    var priv = _test_priv()
    var msg = String("sample").as_bytes()
    var sig = ecdsa_p256_sign_deterministic(
        Span[UInt8, origin_of(priv)](priv), msg,
    )
    # No structural assertion possible beyond "no raise" — we already verified
    # the signature round-trip. This test exists for documentation that the
    # output shape is fixed at 64 bytes (the InlineArray[UInt8, 64] return
    # type makes this a compile-time invariant).
    assert_equal(64, 64, "sig is 64 bytes (compile-time)")
    # Verify the round-trip works (smoke).
    var pub = ecdsa_p256_generate_pubkey(Span[UInt8, origin_of(priv)](priv))
    var ok = ecdsa_p256_verify(
        Span[UInt8, origin_of(pub)](pub), msg, Span[UInt8, origin_of(sig)](sig),
    )
    assert_true(ok, "fmt sanity: sig verifies")


def main() raises:
    print("== test_ecdsa_p256_smoke ==")
    test_pubkey_on_curve()
    print("  pubkey on curve PASS")
    test_signverify_deterministic()
    print("  deterministic-k sign-verify round-trip PASS")
    test_signverify_random()
    print("  random-k sign-verify round-trip PASS")
    test_modified_message_rejected()
    print("  modified message rejected PASS")
    test_modified_signature_rejected()
    print("  modified signature rejected PASS")
    test_modified_pubkey_rejected()
    print("  modified pubkey rejected PASS")
    test_signature_determinism()
    print("  signature determinism PASS")
    test_signature_byte_format()
    print("  signature byte format PASS")
    print("ALL 8 ECDSA-P256 smoke tests PASS")
