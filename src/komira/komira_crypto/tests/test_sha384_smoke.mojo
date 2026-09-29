# =============================================================================
# komira_crypto/tests/test_sha384_smoke.mojo — smoke gate
# =============================================================================
#
# Smoke test. Validates `Sha384` streaming
# struct against FIPS 180-4 hand vectors. Companion `test_sha384_kat`
# extends with CAVP corpus.
#
# Test cases:
#   1. SHA-384("") — 38b060a7...8b95b
#   2. SHA-384("abc") — cb00753f...25a7 (FIPS 180-2 Appendix C)
#   3. SHA-384(56-byte) — 3391fddd...8452b
#   4. SHA-384(112-byte / SHA-384 boundary stress) — 09330c33...46039
#   5. SHA-384(1M 'a') — 9d0e1809...d8985 (NIST stress)
#   6. Multi-call update — update("a")+update("bc") == update("abc")
#   7. fork() independence — same as Sha256 contract
#   8. reset() round-trip
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import Sha384
from komira_crypto import hex_lower


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


def _hex_of_digest(d: Array[UInt8, 48]) -> String:
    """Hex-encode a 48-byte digest (SHA-384). Uses the generic
    `hex_lower(Span[UInt8, _])` helper which doesn't care about length."""
    var bytes = List[UInt8](capacity=48)
    for i in range(48):
        bytes.append(d[i])
    return hex_lower(Span[UInt8](bytes))


def test_sha384_empty() raises:
    """SHA-384("") = 38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b."""
    var h = Sha384()
    var data = List[UInt8]()
    h.update(data)
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"
        ),
    )


def test_sha384_abc() raises:
    """SHA-384("abc") = cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7."""
    var h = Sha384()
    var data = _bytes_of(String("abc"))
    h.update(data)
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"
        ),
    )


def test_sha384_56byte_vector() raises:
    """SHA-384 of the 56-byte test vector — locks block-boundary
    behavior (input straddles the 128-byte block boundary's padding
    requirement)."""
    var h = Sha384()
    var data = _bytes_of(
        String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    )
    h.update(data)
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "3391fdddfc8dc7393707a65b1b4709397cf8b1d162af05abfe8f450de5f36bc6b0455a8520bc4e6f5fe95b1fe3c8452b"
        ),
    )


def test_sha384_112byte_vector() raises:
    """SHA-384 of the 112-byte SHA-384/512 boundary test vector — locks
    the "doesn't fit + 0x80 + 16-byte length in current block; flush
    and start new block" path of `_finalize_in_place`."""
    var h = Sha384()
    var data = _bytes_of(
        String(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        )
    )
    h.update(data)
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039"
        ),
    )


def test_sha384_one_million_a() raises:
    """SHA-384 of 1M repetitions of 'a'. Forces ~7813 block compressions;
    locks the streaming padding contract at scale."""
    var h = Sha384()
    var data = _rep(UInt8(0x61), 1_000_000)
    h.update(data)
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "9d0e1809716474cb086e834e310a4a1ced149e9c00f248527972cec5704c2a5b07b8b3dc38ecc4ebae97ddd87f3d8985"
        ),
    )


def test_sha384_multi_call_update_equivalent() raises:
    """Splitting input across multiple update calls matches single-call."""
    var h_single = Sha384()
    h_single.update(_bytes_of(String("abc")))
    var dig_single = Array[UInt8, 48](fill=0)
    h_single.finalize_into(dig_single)

    var h_split = Sha384()
    h_split.update(_bytes_of(String("a")))
    h_split.update(_bytes_of(String("bc")))
    var dig_split = Array[UInt8, 48](fill=0)
    h_split.finalize_into(dig_split)

    assert_equal(_hex_of_digest(dig_single), _hex_of_digest(dig_split))


def test_sha384_multi_call_block_boundary() raises:
    """Split a 300-byte input across three update calls at non-block-
    aligned offsets. SHA-384/512 block size is 128, so this spans
    multiple block compressions per the split-vs-baseline pattern."""
    var data = _rep(UInt8(0x5A), 300)

    var h_baseline = Sha384()
    h_baseline.update(data)
    var dig_baseline = Array[UInt8, 48](fill=0)
    h_baseline.finalize_into(dig_baseline)

    # Split at 50 + 100 + 150 = 300.
    var part1 = List[UInt8]()
    var part2 = List[UInt8]()
    var part3 = List[UInt8]()
    for i in range(300):
        if i < 50:
            part1.append(data[i])
        elif i < 150:
            part2.append(data[i])
        else:
            part3.append(data[i])

    var h_split = Sha384()
    h_split.update(part1)
    h_split.update(part2)
    h_split.update(part3)
    var dig_split = Array[UInt8, 48](fill=0)
    h_split.finalize_into(dig_split)

    assert_equal(_hex_of_digest(dig_baseline), _hex_of_digest(dig_split))


def test_sha384_fork_idempotent() raises:
    """fork() clones midstate; finalize_into is idempotent."""
    var h = Sha384()
    h.update(_bytes_of(String("transcript-prefix-")))

    var dig_first = Array[UInt8, 48](fill=0)
    h.finalize_into(dig_first)

    var dig_second = Array[UInt8, 48](fill=0)
    h.finalize_into(dig_second)
    assert_equal(_hex_of_digest(dig_first), _hex_of_digest(dig_second))

    var fork_a = h.fork()
    var dig_fork = Array[UInt8, 48](fill=0)
    fork_a.finalize_into(dig_fork)
    assert_equal(_hex_of_digest(dig_first), _hex_of_digest(dig_fork))

    h.update(_bytes_of(String("more-bytes")))
    var dig_extended = Array[UInt8, 48](fill=0)
    h.finalize_into(dig_extended)
    assert_false(_hex_of_digest(dig_extended) == _hex_of_digest(dig_fork))


def test_sha384_reset_to_empty() raises:
    """After absorbing input then reset(), digest matches empty-input."""
    var h = Sha384()
    h.update(_bytes_of(String("anything-goes")))
    h.reset()
    var dig = Array[UInt8, 48](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"
        ),
    )


def main() raises:
    test_sha384_empty()
    test_sha384_abc()
    test_sha384_56byte_vector()
    test_sha384_112byte_vector()
    test_sha384_one_million_a()
    test_sha384_multi_call_update_equivalent()
    test_sha384_multi_call_block_boundary()
    test_sha384_fork_idempotent()
    test_sha384_reset_to_empty()
    print("OK")
