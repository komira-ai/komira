# =============================================================================
# komira_crypto/tests/test_hmac_kat.mojo
# =============================================================================
#
# RFC 4231 §4 known-answer test corpus for HMAC-SHA-256 against BOTH
# the streaming `Hmac[Sha256]` surface AND the wrapped `hmac_sha256(...)`
# free function. Locks the acceptance gates:
#
#   (a) RFC 4231 §4 HMAC-SHA-256 KAT (cases 1-7) GREEN on BOTH surfaces.
#       Every vector asserts byte-identity between both surfaces —
#       proves the wrapped one-shot is correct at the
#       free-function surface.
#   (e) Hmac[Sha256].finalize_into is idempotent (verified via multi-
#       finalize across the case-1 driver).
#
# RFC 4231 cases tested:
#   * Case 1 (§4.2): key=20*0x0b, data="Hi There"  (KEY < BLOCK_SIZE)
#   * Case 2 (§4.3): key="Jefe", data="what do ya want for nothing?"
#                                                  (SHORT KEY)
#   * Case 3 (§4.4): key=20*0xaa, data=50*0xdd     (REPEATED-BYTE KEY+DATA)
#   * Case 4 (§4.5): key=0x01..0x19 (25 bytes), data=50*0xcd
#                                                  (SEQUENCED KEY)
#   * Case 5 (§4.6): key=20*0x0c, data="Test With Truncation"
#                    RFC says expected MAC is TRUNCATED to 16 bytes —
#                    we test the full 32-byte MAC (Hmac[Sha256] is
#                    fixed-OUTPUT_SIZE; the truncation is the caller's
#                    responsibility) AND the truncation-prefix.
#   * Case 6 (§4.7): key=131*0xaa, data="Test Using Larger Than Block-Size Key - Hash Key First"
#                                                  (LONG KEY -> hash-down)
#   * Case 7 (§4.8): key=131*0xaa, data="This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
#                                                  (LONG KEY + LONG DATA)
#
# RFC 4231 published HMAC-SHA-256 MACs are the source of truth here.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import Hmac, Sha256
from komira_crypto import hmac_sha256, hmac_sha256_string
from komira_crypto import hex_lower_array_32


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _rep(c: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(c)
    return out^


def _hex(d: Array[UInt8, 32]) -> String:
    return hex_lower_array_32(d)


# -----------------------------------------------------------------------------
# Dual-surface helper — asserts BOTH the streaming Hmac[Sha256] AND the
# wrapped hmac_sha256() free function produce the same MAC, AND that
# MAC matches the expected hex.
# -----------------------------------------------------------------------------


def _assert_hmac_kat(
    name: String,
    key: List[UInt8],
    data: List[UInt8],
    expected_hex: String,
) raises:
    """Run (key, data) through both surfaces; assert both match expected_hex."""
    # Streaming.
    var h = Hmac[Sha256](key)
    h.update(data)
    var mac_streaming = Array[UInt8, 32](fill=0)
    h.finalize_into(mac_streaming)
    assert_equal(
        _hex(mac_streaming),
        expected_hex,
        "streaming Hmac[Sha256] MAC mismatch for " + name,
    )

    # Wrapped one-shot.
    var mac_wrapped = hmac_sha256(key, data)
    assert_equal(
        _hex(mac_wrapped),
        expected_hex,
        "wrapped hmac_sha256() MAC mismatch for " + name,
    )

    # The two surfaces MUST produce byte-identical output.
    assert_equal(
        _hex(mac_streaming),
        _hex(mac_wrapped),
        "dual-surface MAC mismatch for " + name,
    )


# -----------------------------------------------------------------------------
# RFC 4231 §4 — HMAC-SHA-256 test vectors
# -----------------------------------------------------------------------------


def test_hmac_kat_rfc4231_case1() raises:
    """RFC 4231 §4.2 (case 1): key=20*0x0b, data="Hi There"."""
    _assert_hmac_kat(
        String("case1"),
        _rep(UInt8(0x0b), 20),
        _bytes_of(String("Hi There")),
        String(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        ),
    )


def test_hmac_kat_rfc4231_case2() raises:
    """RFC 4231 §4.3 (case 2): key="Jefe", data="what do ya want for nothing?"."""
    _assert_hmac_kat(
        String("case2"),
        _bytes_of(String("Jefe")),
        _bytes_of(String("what do ya want for nothing?")),
        String(
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        ),
    )


def test_hmac_kat_rfc4231_case3() raises:
    """RFC 4231 §4.4 (case 3): key=20*0xaa, data=50*0xdd."""
    _assert_hmac_kat(
        String("case3"),
        _rep(UInt8(0xaa), 20),
        _rep(UInt8(0xdd), 50),
        String(
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
        ),
    )


def test_hmac_kat_rfc4231_case4() raises:
    """RFC 4231 §4.5 (case 4): key=0x01..0x19 (25 bytes), data=50*0xcd.

    Exercises a non-uniform key (each byte differs)."""
    var key = List[UInt8]()
    for i in range(25):
        key.append(UInt8(i + 1))
    _assert_hmac_kat(
        String("case4"),
        key,
        _rep(UInt8(0xcd), 50),
        String(
            "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
        ),
    )


def test_hmac_kat_rfc4231_case5_truncation() raises:
    """RFC 4231 §4.6 (case 5): key=20*0x0c, data="Test With Truncation".

    RFC's expected MAC is TRUNCATED to 16 bytes: a3b6167473100ee06e0c796c2955552b.
    Our Hmac[Sha256] produces the FULL 32-byte MAC; the truncation
    is the caller's responsibility (TLS 1.3 / SigV4 callers all use
    the full 32 bytes).

    Full HMAC-SHA-256("Test With Truncation", 20*0x0c) =
        a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5
    (verified via `python3 -c "import hmac, hashlib;
    print(hmac.new(b'\\x0c'*20, b'Test With Truncation', hashlib.sha256).hexdigest())"`)
    """
    _assert_hmac_kat(
        String("case5_full"),
        _rep(UInt8(0x0c), 20),
        _bytes_of(String("Test With Truncation")),
        String(
            "a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5"
        ),
    )

    # Verify the RFC 4231 truncated 16-byte prefix matches.
    var mac = hmac_sha256(
        _rep(UInt8(0x0c), 20),
        _bytes_of(String("Test With Truncation")),
    )
    var first_16_hex = String("")
    for i in range(16):
        var b = Int(mac[i])
        var hi = b // 16
        var lo = b % 16
        # ASCII hex lower
        var hi_c = chr(hi + Int(ord("0"))) if hi < 10 else chr(hi - 10 + Int(ord("a")))
        var lo_c = chr(lo + Int(ord("0"))) if lo < 10 else chr(lo - 10 + Int(ord("a")))
        first_16_hex += hi_c
        first_16_hex += lo_c
    assert_equal(
        first_16_hex,
        String("a3b6167473100ee06e0c796c2955552b"),
        "RFC 4231 case 5 16-byte truncation prefix mismatch",
    )


def test_hmac_kat_rfc4231_case6_long_key() raises:
    """RFC 4231 §4.7 (case 6): key=131*0xaa (TRIGGERS HASH-DOWN BRANCH),
    data="Test Using Larger Than Block-Size Key - Hash Key First"."""
    _assert_hmac_kat(
        String("case6"),
        _rep(UInt8(0xaa), 131),
        _bytes_of(
            String("Test Using Larger Than Block-Size Key - Hash Key First")
        ),
        String(
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        ),
    )


def test_hmac_kat_rfc4231_case7_long_key_long_data() raises:
    """RFC 4231 §4.8 (case 7): key=131*0xaa (HASH-DOWN), long data."""
    _assert_hmac_kat(
        String("case7"),
        _rep(UInt8(0xaa), 131),
        _bytes_of(
            String(
                "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
            )
        ),
        String(
            "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
        ),
    )


# -----------------------------------------------------------------------------
# Acceptance gate (e): finalize_into idempotency — already exercised in
# the smoke test; here we re-confirm it via the wrapped surface too.
# -----------------------------------------------------------------------------


def test_hmac_finalize_idempotent_dual_surface() raises:
    """Both the streaming and the wrapped surfaces are idempotent at
    the level of 'same input -> same MAC'. The streaming surface goes
    further (finalize_into without consuming self), but the wrapped
    surface is naturally idempotent (free function).
    """
    var key = _rep(UInt8(0x42), 16)
    var data = _bytes_of(String("payload"))

    # Streaming: finalize twice on same Hmac, same MAC.
    var h = Hmac[Sha256](key)
    h.update(data)
    var mac1 = Array[UInt8, 32](fill=0)
    h.finalize_into(mac1)
    var mac2 = Array[UInt8, 32](fill=0)
    h.finalize_into(mac2)
    assert_equal(_hex(mac1), _hex(mac2))

    # Wrapped: two independent calls, same MAC.
    var mac_a = hmac_sha256(key, data)
    var mac_b = hmac_sha256(key, data)
    assert_equal(_hex(mac_a), _hex(mac_b))

    # Streaming and wrapped agree.
    assert_equal(_hex(mac1), _hex(mac_a))


# -----------------------------------------------------------------------------
# hmac_sha256_string wrapper round-trip — proves the string-data overload
# is itself byte-identical with the Span-data overload.
# -----------------------------------------------------------------------------


def test_hmac_sha256_string_matches_bytes() raises:
    """hmac_sha256_string(key, s) == hmac_sha256(key, s.as_bytes())."""
    var key = _rep(UInt8(0x0b), 20)
    var s = String("Hi There")
    var mac_string = hmac_sha256_string(key, s)
    var mac_bytes = hmac_sha256(key, _bytes_of(s))
    assert_equal(_hex(mac_string), _hex(mac_bytes))


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


def main() raises:
    test_hmac_kat_rfc4231_case1()
    test_hmac_kat_rfc4231_case2()
    test_hmac_kat_rfc4231_case3()
    test_hmac_kat_rfc4231_case4()
    test_hmac_kat_rfc4231_case5_truncation()
    test_hmac_kat_rfc4231_case6_long_key()
    test_hmac_kat_rfc4231_case7_long_key_long_data()
    test_hmac_finalize_idempotent_dual_surface()
    test_hmac_sha256_string_matches_bytes()
    print("OK")
