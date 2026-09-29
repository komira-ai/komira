# =============================================================================
# komira_crypto/tests/test_hkdf_expand_label.mojo — TLS 1.3 vectors
# =============================================================================
#
# Validates HKDF-Expand-Label per RFC 8446
# §7.1 against known TLS 1.3 reference values (cross-verified against a
# Python reference implementation). The companion test_derive_secret
# specifically validates the dual `Derive-Secret(_, "derived",
# "")` invocation contract.
#
# HKDFLabel struct serialization per RFC 8446 §7.1:
#   uint16 length;
#   opaque label<7..255> = "tls13 " + Label;
#   opaque context<0..255> = Context;
#
# Encoded as:
#   [len_hi][len_lo]                         // u16 BE
#   [tls13_label_len]                        // u8 = 6 + len(label)
#   "tls13 " || Label                        // label bytes
#   [context_len]                            // u8 = len(context)
#   Context                                  // context bytes
# =============================================================================

from std.testing import assert_equal

from komira_crypto import Hkdf, Sha256
from komira_crypto import hex_lower


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _hex_to_bytes(hex_str: String) -> List[UInt8]:
    """Decode a hex string to a byte list."""
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


# -----------------------------------------------------------------------------
# Reference secret used across multiple test cases — the RFC 8448 §3 Early
# Secret. This is HKDF-Extract(salt=0^32, IKM=0^32) for the no-PSK case.
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


def test_hkdf_expand_label_short_iv() raises:
    """HKDF-Expand-Label(secret, 'iv', context='', L=12) — the canonical
    TLS 1.3 record-layer IV derivation shape (per RFC 8446 §7.3 the IV
    is 12 bytes for AES-128-GCM)."""
    var secret = _early_secret()
    var dst = List[UInt8](capacity=12)
    for _ in range(12):
        dst.append(UInt8(0))
    var empty_context = List[UInt8]()
    Hkdf[Sha256].hkdf_expand_label(
        Span[UInt8](secret),
        String("iv"),
        Span[UInt8](empty_context),
        Span[UInt8](dst),
    )
    # Cross-verified via Python reference.
    assert_equal(
        _hex_of_list(dst),
        String("a7bf78a10cf9feb156a93f7a"),
    )


def test_hkdf_expand_label_derived_empty_context() raises:
    """HKDF-Expand-Label(secret, 'derived', context='', L=32) — the
    inner step of `Derive-Secret(_, 'derived', '')`. This is NOT the
    same as `Derive-Secret(_, 'derived', '')` directly; that uses
    H('') as context. Locks the empty-context serialization path."""
    var secret = _early_secret()
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    var empty_context = List[UInt8]()
    Hkdf[Sha256].hkdf_expand_label(
        Span[UInt8](secret),
        String("derived"),
        Span[UInt8](empty_context),
        Span[UInt8](dst),
    )
    assert_equal(
        _hex_of_list(dst),
        String(
            "d65dba9d40e954898205baa678a8c288ac6a51b094ba120dead316d3b247f663"
        ),
    )


def test_hkdf_expand_label_with_context() raises:
    """HKDF-Expand-Label(secret, 'c hs traffic', context=H('transcript-bytes'), L=32) —
    matches the TLS 1.3 client-handshake-traffic-secret derivation
    shape (RFC 8446 §7.1)."""
    var secret = _early_secret()
    # SHA-256("transcript-bytes") computed via Python:
    #   hashlib.sha256(b'transcript-bytes').hexdigest() =
    #   d75f50859432831df7bcf1112109dba18692204b6a051c94aed015ed537bb267
    var transcript_hash = _hex_to_bytes(
        String(
            "d75f50859432831df7bcf1112109dba18692204b6a051c94aed015ed537bb267"
        )
    )
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    Hkdf[Sha256].hkdf_expand_label(
        Span[UInt8](secret),
        String("c hs traffic"),
        Span[UInt8](transcript_hash),
        Span[UInt8](dst),
    )
    # Cross-verified via Python:
    # >>> import hmac, hashlib
    # >>> th = hashlib.sha256(b'transcript-bytes').digest()
    # >>> hkdf_expand_label(early_secret, 'c hs traffic', th, 32).hex()
    # = '17f31908f6181e7c2d533d32418439adc47786d51859fafd3a5d155b57ccfa80'
    assert_equal(
        _hex_of_list(dst),
        String(
            "17f31908f6181e7c2d533d32418439adc47786d51859fafd3a5d155b57ccfa80"
        ),
    )


def test_hkdf_expand_label_empty_label_rejected() raises:
    """Empty `label` argument must raise — RFC 8446 §7.1 sets minimum
    label length to 1 (after the 'tls13 ' prefix the total >= 7)."""
    var secret = _early_secret()
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    var empty_context = List[UInt8]()
    var raised = False
    try:
        Hkdf[Sha256].hkdf_expand_label(
            Span[UInt8](secret),
            String(""),
            Span[UInt8](empty_context),
            Span[UInt8](dst),
        )
    except _:
        raised = True
    assert_equal(raised, True)


def test_hkdf_expand_label_oversize_label_rejected() raises:
    """Label longer than 249 bytes must raise — RFC 8446 §7.1
    `opaque label<7..255>` allows up to 255 bytes total including the
    'tls13 ' prefix, so the suffix-only label is bounded at 249."""
    var secret = _early_secret()
    var dst = List[UInt8](capacity=32)
    for _ in range(32):
        dst.append(UInt8(0))
    var empty_context = List[UInt8]()
    # Build a 250-byte label.
    var oversize_label = String("a")
    for _ in range(249):
        oversize_label = oversize_label + String("a")
    var raised = False
    try:
        Hkdf[Sha256].hkdf_expand_label(
            Span[UInt8](secret),
            oversize_label,
            Span[UInt8](empty_context),
            Span[UInt8](dst),
        )
    except _:
        raised = True
    assert_equal(raised, True)


def main() raises:
    test_hkdf_expand_label_short_iv()
    test_hkdf_expand_label_derived_empty_context()
    test_hkdf_expand_label_with_context()
    test_hkdf_expand_label_empty_label_rejected()
    test_hkdf_expand_label_oversize_label_rejected()
    print("OK")
