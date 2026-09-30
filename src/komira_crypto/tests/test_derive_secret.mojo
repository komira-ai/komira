# =============================================================================
# komira_crypto/tests/test_derive_secret.mojo — Derive-Secret (RFC 8446 §7.1)
# =============================================================================
#
# Validates Derive-Secret per RFC 8446 §7.1, with PARTICULAR ATTENTION to
# the double invocation:
#
#   "RFC 8446 §7.1 has TWO `Derive-Secret(_, 'derived', '')` calls:
#    one between Early/Handshake stages (FIRST) and one between
#    Handshake/Master stages (SECOND). Omitting either produces wrong
#    application-traffic secrets and universal interop failure."
#
# This test file pins down the contract that:
#   (1) Derive-Secret correctly handles empty Messages (the "derived"
#       transition between key-schedule stages).
#   (2) The SAME Derive-Secret API call works for both invocations
#       (FIRST = derive_handshake_secret salt; SECOND = derive_master_secret
#       salt). A TLS 1.3 key schedule calls Derive-Secret(_, "derived", "")
#       twice — once with Early Secret, once with Handshake Secret. This
#       test drives both call sites directly.
#   (3) The output is exactly H.OUTPUT_SIZE bytes regardless of dst size.
#
# Reference values from a Python reference implementation; the RFC 8448 §3
# Early Secret = HKDF-Extract(0^32, 0^32) = 33ad0a1c... is the canonical
# TLS 1.3 no-PSK Early Secret.
# =============================================================================

from std.testing import assert_equal, assert_false

from komira_crypto import Hkdf, Sha256
from komira_crypto import hex_lower


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _hex_to_bytes(hex_str: String) -> List[UInt8]:
    var out = List[UInt8]()
    var hex_bytes = hex_str.as_bytes()
    var n = len(hex_bytes)
    for i in range(0, n, 2):
        var hi = Int(hex_bytes[i])
        var lo = Int(hex_bytes[i + 1])
        var hi_v: Int
        if hi >= 0x30 and hi <= 0x39:
            hi_v = hi - 0x30
        else:
            hi_v = hi - 0x61 + 10
        var lo_v: Int
        if lo >= 0x30 and lo <= 0x39:
            lo_v = lo - 0x30
        else:
            lo_v = lo - 0x61 + 10
        out.append(UInt8((hi_v << 4) | lo_v))
    return out^


def _hex_of_list(l: List[UInt8]) -> String:
    return hex_lower(Span[UInt8](l))


def _rep(c: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(c)
    return out^


# -----------------------------------------------------------------------------
# Canonical RFC 8448 §3 Early Secret (no PSK case).
# = HKDF-Extract(salt=0^32, IKM=0^32)
# = 33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a
# -----------------------------------------------------------------------------


def _early_secret() -> List[UInt8]:
    return _hex_to_bytes(
        String(
            "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"
        )
    )


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_derive_secret_first_invocation_early_to_handshake() raises:
    """FIRST `Derive-Secret(Early-Secret, "derived", "")` per RFC 8446
    §7.1 — between Early/Handshake stages. This is the salt for the
    Handshake-Secret HKDF-Extract.

    BOTH `Derive-Secret(_, "derived", "")` calls must
    work. This pins down call site #1.

    Reference (Python):
      derive_secret(early_secret, 'derived', b'') ==
      hkdf_expand_label(early_secret, 'derived', sha256(b''), 32) ==
      6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba
    """
    var early = _early_secret()
    var empty_messages = List[UInt8]()
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    Hkdf[Sha256].derive_secret(
        Span[UInt8](early),
        String("derived"),
        Span[UInt8](empty_messages),
        Span[UInt8](dst),
    )
    assert_equal(
        _hex_of_list(dst),
        String(
            "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba"
        ),
    )


def test_derive_secret_second_invocation_handshake_to_master() raises:
    """SECOND `Derive-Secret(Handshake-Secret, "derived", "")` per RFC
    8446 §7.1 — between Handshake/Master stages. This is the salt for
    the Master-Secret HKDF-Extract.

    This is the call a key schedule most easily OMITS. Pinning here verifies
    the SAME Derive-Secret API works for this call site (different
    secret bytes but same shape — empty Messages → H('')).

    Reference: handshake_secret = HKDF-Extract(early_derived, 0^32).
    For testing we use a synthetic 32-byte handshake_secret = 0xAA*32
    and compute the derive-secret reference via Python:

      hkdf_expand_label(0xAA*32, 'derived', sha256(b''), 32) =
      110856aa955cc4ce6dc79d7463306d7c4fa1efeff801711b98f7df26887b0d72
    """
    var handshake_secret = _rep(UInt8(0xAA), 32)
    var empty_messages = List[UInt8]()
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    Hkdf[Sha256].derive_secret(
        Span[UInt8](handshake_secret),
        String("derived"),
        Span[UInt8](empty_messages),
        Span[UInt8](dst),
    )
    # Synthetic-handshake-secret reference computed via Python.
    assert_equal(
        _hex_of_list(dst),
        String(
            "110856aa955cc4ce6dc79d7463306d7c4fa1efeff801711b98f7df26887b0d72"
        ),
    )


def test_derive_secret_both_invocations_differ() raises:
    """The TWO `Derive-Secret(_, 'derived', '')` calls produce DIFFERENT
    output (each is keyed on its own predecessor secret). The classic
    bug shape would have made the second invocation a no-op or reuse
    the first — this verifies they're independent."""
    var early = _early_secret()
    var handshake_secret = _rep(UInt8(0xAA), 32)
    var empty_messages = List[UInt8]()

    var first = List[UInt8](capacity=32)
    for _ in range(32):
        first.append(UInt8(0))
    Hkdf[Sha256].derive_secret(
        Span[UInt8](early),
        String("derived"),
        Span[UInt8](empty_messages),
        Span[UInt8](first),
    )

    var second = List[UInt8](capacity=32)
    for _ in range(32):
        second.append(UInt8(0))
    Hkdf[Sha256].derive_secret(
        Span[UInt8](handshake_secret),
        String("derived"),
        Span[UInt8](empty_messages),
        Span[UInt8](second),
    )

    assert_false(_hex_of_list(first) == _hex_of_list(second))


def test_derive_secret_with_transcript_messages() raises:
    """Derive-Secret with NON-empty Messages — the canonical TLS 1.3
    traffic-secret derivation shape (per the diagram in RFC 8446 §7.1,
    derive_client_hs_traffic_secret etc. all take a transcript_hash
    argument). Here Messages = "transcript-bytes" (raw bytes pre-hash;
    the method computes SHA-256 internally)."""
    var early = _early_secret()
    var messages = _bytes_of(String("transcript-bytes"))
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    Hkdf[Sha256].derive_secret(
        Span[UInt8](early),
        String("c hs traffic"),
        Span[UInt8](messages),
        Span[UInt8](dst),
    )
    # Cross-verified via Python — same as the test_hkdf_expand_label
    # case where the transcript_hash arg was passed PRE-hashed.
    # derive_secret COMPUTES SHA-256 internally; result must match.
    assert_equal(
        _hex_of_list(dst),
        String(
            "17f31908f6181e7c2d533d32418439adc47786d51859fafd3a5d155b57ccfa80"
        ),
    )


def test_derive_secret_dst_must_be_at_least_hash_length() raises:
    """`dst` smaller than H.OUTPUT_SIZE must raise."""
    var early = _early_secret()
    var empty_messages = List[UInt8]()
    var dst = List[UInt8](capacity=16)
    for _ in range(16):
        dst.append(UInt8(0))
    var raised = False
    try:
        Hkdf[Sha256].derive_secret(
            Span[UInt8](early),
            String("derived"),
            Span[UInt8](empty_messages),
            Span[UInt8](dst),
        )
    except _:
        raised = True
    assert_equal(raised, True)


def main() raises:
    test_derive_secret_first_invocation_early_to_handshake()
    test_derive_secret_second_invocation_handshake_to_master()
    test_derive_secret_both_invocations_differ()
    test_derive_secret_with_transcript_messages()
    test_derive_secret_dst_must_be_at_least_hash_length()
    print("OK")
