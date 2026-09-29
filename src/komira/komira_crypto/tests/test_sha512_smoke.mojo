# =============================================================================
# komira_crypto/tests/test_sha512_smoke.mojo — smoke gate
# =============================================================================
#
# Smoke test. Validates `Sha512` streaming
# struct against FIPS 180-4 hand vectors. Companion `test_sha512_kat`
# extends with CAVP corpus.
#
# Test cases:
#   1. SHA-512("") — cf83e135...da3e
#   2. SHA-512("abc") — ddaf35a1...a49f
#   3. SHA-512(56-byte SHA-256 vector) — 204a8fc6...3445
#   4. SHA-512(112-byte boundary) — 8e959b75...e909
#   5. SHA-512(1M 'a') — e718483d...c09b
#   6. Multi-call update equivalence
#   7. fork() independence
#   8. reset() round-trip
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import Sha512
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


def _hex_of_digest(d: Array[UInt8, 64]) -> String:
    """Hex-encode a 64-byte SHA-512 digest via the generic hex_lower
    over a List[UInt8] span."""
    var bytes = List[UInt8](capacity=64)
    for i in range(64):
        bytes.append(d[i])
    return hex_lower(Span[UInt8](bytes))


def test_sha512_empty() raises:
    """SHA-512(""). Concatenated reference vector from di-mgt.com.au."""
    var h = Sha512()
    var data = List[UInt8]()
    h.update(data)
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        ),
    )


def test_sha512_abc() raises:
    """SHA-512("abc") — FIPS 180-2 Appendix C."""
    var h = Sha512()
    var data = _bytes_of(String("abc"))
    h.update(data)
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        ),
    )


def test_sha512_56byte_vector() raises:
    """SHA-512 of the SHA-256 56-byte test vector — locks intra-block
    behavior under SHA-512's 128-byte block size."""
    var h = Sha512()
    var data = _bytes_of(
        String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    )
    h.update(data)
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c33596fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445"
        ),
    )


def test_sha512_112byte_vector() raises:
    """SHA-512 of the 112-byte boundary vector — locks the "doesn't fit
    + 0x80 + 16-byte length in current block; flush and start new
    block" path of `_finalize_in_place`. 112 bytes is the SMALLEST
    input that triggers the two-block padding case (blen=112 + 0x80 =
    113; 113 > 112 (boundary); flush + zero-block + 0x00...||length)."""
    var h = Sha512()
    var data = _bytes_of(
        String(
            "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
        )
    )
    h.update(data)
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"
        ),
    )


def test_sha512_one_million_a() raises:
    """SHA-512 of 1M 'a' — NIST stress vector."""
    var h = Sha512()
    var data = _rep(UInt8(0x61), 1_000_000)
    h.update(data)
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b"
        ),
    )


def test_sha512_multi_call_update_equivalent() raises:
    """Splitting input across multiple update calls matches single-call."""
    var h_single = Sha512()
    h_single.update(_bytes_of(String("abc")))
    var dig_single = Array[UInt8, 64](fill=0)
    h_single.finalize_into(dig_single)

    var h_split = Sha512()
    h_split.update(_bytes_of(String("a")))
    h_split.update(_bytes_of(String("bc")))
    var dig_split = Array[UInt8, 64](fill=0)
    h_split.finalize_into(dig_split)

    assert_equal(_hex_of_digest(dig_single), _hex_of_digest(dig_split))


def test_sha512_multi_call_block_boundary() raises:
    """Multi-call with 300-byte input split at non-block-aligned offsets."""
    var data = _rep(UInt8(0x5A), 300)

    var h_baseline = Sha512()
    h_baseline.update(data)
    var dig_baseline = Array[UInt8, 64](fill=0)
    h_baseline.finalize_into(dig_baseline)

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

    var h_split = Sha512()
    h_split.update(part1)
    h_split.update(part2)
    h_split.update(part3)
    var dig_split = Array[UInt8, 64](fill=0)
    h_split.finalize_into(dig_split)

    assert_equal(_hex_of_digest(dig_baseline), _hex_of_digest(dig_split))


def test_sha512_fork_idempotent() raises:
    """fork() + finalize_into idempotency contract."""
    var h = Sha512()
    h.update(_bytes_of(String("transcript-prefix-")))

    var dig_first = Array[UInt8, 64](fill=0)
    h.finalize_into(dig_first)

    var dig_second = Array[UInt8, 64](fill=0)
    h.finalize_into(dig_second)
    assert_equal(_hex_of_digest(dig_first), _hex_of_digest(dig_second))

    var fork_a = h.fork()
    var dig_fork = Array[UInt8, 64](fill=0)
    fork_a.finalize_into(dig_fork)
    assert_equal(_hex_of_digest(dig_first), _hex_of_digest(dig_fork))

    h.update(_bytes_of(String("more-bytes")))
    var dig_extended = Array[UInt8, 64](fill=0)
    h.finalize_into(dig_extended)
    assert_false(_hex_of_digest(dig_extended) == _hex_of_digest(dig_fork))


def test_sha512_reset_to_empty() raises:
    """reset() restores empty-input state."""
    var h = Sha512()
    h.update(_bytes_of(String("anything-goes")))
    h.reset()
    var dig = Array[UInt8, 64](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
        ),
    )


def main() raises:
    test_sha512_empty()
    test_sha512_abc()
    test_sha512_56byte_vector()
    test_sha512_112byte_vector()
    test_sha512_one_million_a()
    test_sha512_multi_call_update_equivalent()
    test_sha512_multi_call_block_boundary()
    test_sha512_fork_idempotent()
    test_sha512_reset_to_empty()
    print("OK")
