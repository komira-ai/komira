# =============================================================================
# komira_crypto/tests/test_x25519_kat.mojo
# =============================================================================
#
# Known-Answer Tests for X25519 per RFC 7748 Appendix A. Validates:
#
#   1. RFC 7748 §5.2 test vector 1 — raw scalar mult (`scalar=a546e36b...`,
#      `u=e6db6867...`, expected=`c3da55379de9c690...`).
#   2. RFC 7748 §5.2 test vector 2 — raw scalar mult (`scalar=4b66e951...`,
#      `u=e5210f12...`, expected=`95cbde9476e8907d...`).
#   3. RFC 7748 §6.1 — Alice's keypair derivation: `Alice_privkey
#      77076d0a... → Alice_pubkey 8520f0098930a754...`.
#   4. RFC 7748 §6.1 — Bob's keypair derivation: `Bob_privkey 5dab087e...
#      → Bob_pubkey de9edb7d7b7dc1b4...`.
#   5. RFC 7748 §6.1 — ECDH shared-secret agreement: `Alice_priv ×
#      Bob_pub == Bob_priv × Alice_pub == 4a5d9d5ba4ce2de1...`. This is
#      the cornerstone TLS 1.3 ECDH key-exchange correctness gate.
#
# All vectors are byte-for-byte from the RFC. Each assertion's expected
# bytes are hex-decoded inline so the test is self-contained.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_crypto.x25519 import x25519, x25519_base_mult


# -----------------------------------------------------------------------------
# Hex helpers.
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


def _assert_bytes_eq(
    got: Array[UInt8, 32],
    expected: Array[UInt8, 32],
    label: String,
) raises:
    for i in range(32):
        if got[i] != expected[i]:
            print("MISMATCH at byte", i, "for", label)
            print("  got: ", Int(got[i]), "  expected: ", Int(expected[i]))
            assert_equal(Int(got[i]), Int(expected[i]), label)


# -----------------------------------------------------------------------------
# Test 1: RFC 7748 §5.2 test vector 1 — raw scalar mult.
# -----------------------------------------------------------------------------


def test_rfc7748_5_2_vector_1() raises:
    """RFC 7748 §5.2 first test vector."""
    var scalar = _hex_to_32(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
    )
    var u = _hex_to_32(
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"
    )
    var expected = _hex_to_32(
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
    )
    var sc_span = Span[UInt8, origin_of(scalar)](scalar)
    var u_span = Span[UInt8, origin_of(u)](u)
    var result = x25519(sc_span, u_span)
    _assert_bytes_eq(result, expected, "RFC 7748 §5.2 vector 1")


# -----------------------------------------------------------------------------
# Test 2: RFC 7748 §5.2 test vector 2 — raw scalar mult.
# -----------------------------------------------------------------------------


def test_rfc7748_5_2_vector_2() raises:
    """RFC 7748 §5.2 second test vector."""
    var scalar = _hex_to_32(
        "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"
    )
    var u = _hex_to_32(
        "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"
    )
    var expected = _hex_to_32(
        "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"
    )
    var sc_span = Span[UInt8, origin_of(scalar)](scalar)
    var u_span = Span[UInt8, origin_of(u)](u)
    var result = x25519(sc_span, u_span)
    _assert_bytes_eq(result, expected, "RFC 7748 §5.2 vector 2")


# -----------------------------------------------------------------------------
# Test 3: RFC 7748 §6.1 — Alice's keypair derivation.
# -----------------------------------------------------------------------------


def test_rfc7748_6_1_alice_keypair() raises:
    """RFC 7748 §6.1 Alice's keypair: privkey 77076d0a... -> pubkey 8520f009...

    Verifies x25519_base_mult against the canonical keypair-gen vector.
    """
    var alice_priv = _hex_to_32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    )
    var alice_pub_expected = _hex_to_32(
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    )
    var sc_span = Span[UInt8, origin_of(alice_priv)](alice_priv)
    var alice_pub = x25519_base_mult(sc_span)
    _assert_bytes_eq(alice_pub, alice_pub_expected, "Alice pubkey")


# -----------------------------------------------------------------------------
# Test 4: RFC 7748 §6.1 — Bob's keypair derivation.
# -----------------------------------------------------------------------------


def test_rfc7748_6_1_bob_keypair() raises:
    """RFC 7748 §6.1 Bob's keypair: privkey 5dab087e... -> pubkey de9edb7d..."""
    var bob_priv = _hex_to_32(
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    )
    var bob_pub_expected = _hex_to_32(
        "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    )
    var sc_span = Span[UInt8, origin_of(bob_priv)](bob_priv)
    var bob_pub = x25519_base_mult(sc_span)
    _assert_bytes_eq(bob_pub, bob_pub_expected, "Bob pubkey")


# -----------------------------------------------------------------------------
# Test 5: RFC 7748 §6.1 — ECDH shared-secret agreement.
#
# This is the TLS 1.3 ECDH key-exchange correctness gate:
#   Alice_priv × Bob_pub == Bob_priv × Alice_pub == 4a5d9d5b...
# -----------------------------------------------------------------------------


def test_rfc7748_6_1_ecdh_agreement() raises:
    """RFC 7748 §6.1 ECDH shared-secret agreement.

    Both directions of the ECDH exchange must produce the same shared
    secret. This is THE TLS 1.3 key-exchange correctness gate.
    """
    var alice_priv = _hex_to_32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    )
    var alice_pub = _hex_to_32(
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    )
    var bob_priv = _hex_to_32(
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    )
    var bob_pub = _hex_to_32(
        "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    )
    var shared_expected = _hex_to_32(
        "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    )

    # Direction 1: Alice computes shared = Alice_priv × Bob_pub
    var ap_span = Span[UInt8, origin_of(alice_priv)](alice_priv)
    var bpub_span = Span[UInt8, origin_of(bob_pub)](bob_pub)
    var shared_alice = x25519(ap_span, bpub_span)
    _assert_bytes_eq(shared_alice, shared_expected, "Alice shared")

    # Direction 2: Bob computes shared = Bob_priv × Alice_pub
    var bp_span = Span[UInt8, origin_of(bob_priv)](bob_priv)
    var apub_span = Span[UInt8, origin_of(alice_pub)](alice_pub)
    var shared_bob = x25519(bp_span, apub_span)
    _assert_bytes_eq(shared_bob, shared_expected, "Bob shared")

    # Direction 3: assert byte-by-byte equality of Alice and Bob's results.
    for i in range(32):
        assert_equal(
            Int(shared_alice[i]),
            Int(shared_bob[i]),
            "Alice/Bob shared-secret byte agreement",
        )


def main() raises:
    print("== test_x25519_kat ==")
    test_rfc7748_5_2_vector_1()
    print("  RFC 7748 §5.2 vector 1 PASS")
    test_rfc7748_5_2_vector_2()
    print("  RFC 7748 §5.2 vector 2 PASS")
    test_rfc7748_6_1_alice_keypair()
    print("  Alice keypair PASS")
    test_rfc7748_6_1_bob_keypair()
    print("  Bob keypair PASS")
    test_rfc7748_6_1_ecdh_agreement()
    print("  ECDH shared-secret agreement PASS")
    print("ALL 5 X25519 KAT tests PASS")
