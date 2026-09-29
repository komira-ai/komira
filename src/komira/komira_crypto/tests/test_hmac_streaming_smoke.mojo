# =============================================================================
# komira_crypto/tests/test_hmac_streaming_smoke.mojo — smoke gate
# =============================================================================
#
# Smoke test. Validates the streaming `Hmac[Sha256]` struct against
# known-answer RFC 4231 vectors. The fuller RFC 4231 KAT corpus (cases
# 1-7) plus dual-surface (streaming + wrapped) verification is in
# test_hmac_kat.mojo. This file is the fast gate that proves the
# streaming-state transitions (single-call update, multi-call update,
# fork-independence, key hashing for long keys, finalize-into
# idempotency) are correct.
#
# Test cases:
#   1. RFC 4231 §4.2 (case 1) — key=20*0x0b, data="Hi There"
#   2. RFC 4231 §4.3 (case 2) — key="Jefe", data="what do ya want for nothing?"
#   3. Long-key branch — key=131*0xaa hashes down to OUTPUT_SIZE then pads
#   4. fork() independence — A:fork, A.finalize == fork.finalize
#   5. Multi-call update — update("a")+update("bc") == update("abc")
#   6. finalize_into idempotency — call twice, same MAC
#   7. Verify same key + same message produces same MAC across new Hmac instances
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import Hmac, Sha256
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


def _hex_of_mac(d: Array[UInt8, 32]) -> String:
    return hex_lower_array_32(d)


# -----------------------------------------------------------------------------
# Cases 1-2 — RFC 4231 known-answer vectors against the STREAMING surface.
# test_hmac_kat.mojo asserts dual-surface (streaming + wrapper) byte-identity; here
# we lock the streaming-surface contract directly.
# -----------------------------------------------------------------------------


def test_hmac_streaming_rfc4231_case1() raises:
    """RFC 4231 §4.2 case 1: key=20*0x0b, data="Hi There".
    Expected: b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7."""
    var key = _rep(UInt8(0x0b), 20)
    var data = _bytes_of(String("Hi There"))
    var h = Hmac[Sha256](key)
    h.update(data)
    var mac = Array[UInt8, 32](fill=0)
    h.finalize_into(mac)
    assert_equal(
        _hex_of_mac(mac),
        String(
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
        ),
    )


def test_hmac_streaming_rfc4231_case2() raises:
    """RFC 4231 §4.3 case 2: key="Jefe", data="what do ya want for nothing?".
    Expected: 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843."""
    var key = _bytes_of(String("Jefe"))
    var data = _bytes_of(String("what do ya want for nothing?"))
    var h = Hmac[Sha256](key)
    h.update(data)
    var mac = Array[UInt8, 32](fill=0)
    h.finalize_into(mac)
    assert_equal(
        _hex_of_mac(mac),
        String(
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        ),
    )


# -----------------------------------------------------------------------------
# Case 3 — long-key branch: len(key) > BLOCK_SIZE triggers K' = H(key).
# RFC 4231 §4.7 case 6: key=131*0xaa, data="Test Using Larger Than Block-Size Key - Hash Key First"
# -----------------------------------------------------------------------------


def test_hmac_streaming_long_key_branch() raises:
    """Long-key branch: key=131*0xaa (>64 bytes) triggers SHA-256 hash-down.
    Expected: 60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54."""
    var key = _rep(UInt8(0xaa), 131)
    var data = _bytes_of(
        String("Test Using Larger Than Block-Size Key - Hash Key First")
    )
    var h = Hmac[Sha256](key)
    h.update(data)
    var mac = Array[UInt8, 32](fill=0)
    h.finalize_into(mac)
    assert_equal(
        _hex_of_mac(mac),
        String(
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
        ),
    )


# -----------------------------------------------------------------------------
# Streaming-state contract — fork, multi-call update, idempotency.
# -----------------------------------------------------------------------------


def test_hmac_streaming_fork_independence() raises:
    """`fork()` clones inner+outer state; the fork can be finalized
    independently of the original, AND further updates on either branch
    don't disturb the other.

    This is the TLS 1.3 transcript-MAC contract — verify_data snapshots
    the running MAC at the server-Finished commit point without
    consuming it."""
    var key = _rep(UInt8(0x0b), 20)
    var h = Hmac[Sha256](key)
    h.update(_bytes_of(String("transcript-prefix-")))

    # Branch 1: finalize the original.
    var mac_original_first = Array[UInt8, 32](fill=0)
    h.finalize_into(mac_original_first)

    # Branch 2: fork + finalize. Should match the original.
    var fork_a = h.fork()
    var mac_fork = Array[UInt8, 32](fill=0)
    fork_a.finalize_into(mac_fork)
    assert_equal(_hex_of_mac(mac_original_first), _hex_of_mac(mac_fork))

    # Branch 3: extend the ORIGINAL with more bytes; finalize. Should
    # differ from fork.
    h.update(_bytes_of(String("more-bytes")))
    var mac_extended = Array[UInt8, 32](fill=0)
    h.finalize_into(mac_extended)
    assert_false(_hex_of_mac(mac_extended) == _hex_of_mac(mac_fork))

    # Branch 4: re-finalize the fork — should NOT have been disturbed
    # by the original's extension.
    var mac_fork_again = Array[UInt8, 32](fill=0)
    fork_a.finalize_into(mac_fork_again)
    assert_equal(_hex_of_mac(mac_fork), _hex_of_mac(mac_fork_again))


def test_hmac_streaming_multi_call_update_equivalent() raises:
    """Splitting input across multiple `update` calls produces the same
    MAC as a single `update` call. Locks the streaming-buffer-fill +
    block-flush logic inside H.update."""
    var key = _rep(UInt8(0x0b), 20)

    var h_single = Hmac[Sha256](key)
    h_single.update(_bytes_of(String("Hi There")))
    var mac_single = Array[UInt8, 32](fill=0)
    h_single.finalize_into(mac_single)

    var h_split = Hmac[Sha256](key)
    h_split.update(_bytes_of(String("Hi ")))
    h_split.update(_bytes_of(String("There")))
    var mac_split = Array[UInt8, 32](fill=0)
    h_split.finalize_into(mac_split)

    assert_equal(_hex_of_mac(mac_single), _hex_of_mac(mac_split))


def test_hmac_streaming_finalize_idempotent() raises:
    """finalize_into is idempotent (self is read-only).
    Calling finalize twice on the same Hmac produces the same MAC.

    This is the load-bearing contract for TLS 1.3 server `verify_data`
    / client `verify_data` / KeyUpdate / exporters — they snapshot the
    running MAC at multiple commit points WITHOUT consuming it.
    """
    var key = _rep(UInt8(0x0b), 20)
    var data = _bytes_of(String("Hi There"))
    var h = Hmac[Sha256](key)
    h.update(data)

    var mac1 = Array[UInt8, 32](fill=0)
    h.finalize_into(mac1)

    var mac2 = Array[UInt8, 32](fill=0)
    h.finalize_into(mac2)

    assert_equal(_hex_of_mac(mac1), _hex_of_mac(mac2))


def test_hmac_streaming_same_key_same_message_same_mac() raises:
    """Two independent Hmac instances built from the same key + same
    message produce identical MACs. Locks the __init__ key-pad reproducibility."""
    var key = _rep(UInt8(0x42), 16)
    var data = _bytes_of(String("any payload"))

    var h_a = Hmac[Sha256](key)
    h_a.update(data)
    var mac_a = Array[UInt8, 32](fill=0)
    h_a.finalize_into(mac_a)

    var h_b = Hmac[Sha256](key)
    h_b.update(data)
    var mac_b = Array[UInt8, 32](fill=0)
    h_b.finalize_into(mac_b)

    assert_equal(_hex_of_mac(mac_a), _hex_of_mac(mac_b))


# -----------------------------------------------------------------------------
# main — invoke every test
# -----------------------------------------------------------------------------


def main() raises:
    test_hmac_streaming_rfc4231_case1()
    test_hmac_streaming_rfc4231_case2()
    test_hmac_streaming_long_key_branch()
    test_hmac_streaming_fork_independence()
    test_hmac_streaming_multi_call_update_equivalent()
    test_hmac_streaming_finalize_idempotent()
    test_hmac_streaming_same_key_same_message_same_mac()
    print("OK")
