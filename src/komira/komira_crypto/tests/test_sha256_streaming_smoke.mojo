# =============================================================================
# komira_crypto/tests/test_sha256_streaming_smoke.mojo — smoke gate
# =============================================================================
#
# Smoke test. Validates the streaming `Sha256` struct against
# hand-computed FIPS 180-4 vectors. The bigger NIST CAVP corpus is in the
# test_cavp_sha256_* tests — this is the fast gate that proves the
# streaming-state transitions (single-call update, multi-call update,
# block-boundary alignment, large-input chunking, fork-independence) are
# correct.
#
# Test cases:
#   1. SHA-256("") — well-known e3b0c4...7852b855 (empty-input gate)
#   2. SHA-256("abc") — FIPS 180-4 Appendix A — ba7816bf...20015ad
#   3. SHA-256("abcdbcde...nopq") — FIPS 180-4 Appendix B — 248d6a61...db06c1
#   4. SHA-256(1M 'a') — FIPS 180-4 NIST stress — cdc76e5c...7112cd0
#   5. fork() independence — A:fork, A.finalize == fork.finalize
#   6. Multi-call update — update("a")+update("bc") == update("abc")
#   7. Reset round-trip — reset() restores to empty-input state
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import Sha256
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


def _hex_of_digest(d: Array[UInt8, 32]) -> String:
    return hex_lower_array_32(d)


# -----------------------------------------------------------------------------
# Cases 1-4 — FIPS 180-4 KATs against the STREAMING surface (not the one-shot
# wrapper). test_sha256_kat.mojo asserts that the wrapper produces byte-identical output;
# here we lock the streaming-surface contract directly.
# -----------------------------------------------------------------------------


def test_sha256_streaming_empty() raises:
    """SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855."""
    var h = Sha256()
    var data = List[UInt8]()
    h.update(data)
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ),
    )


def test_sha256_streaming_abc() raises:
    """SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad."""
    var h = Sha256()
    var data = _bytes_of(String("abc"))
    h.update(data)
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ),
    )


def test_sha256_streaming_long_message() raises:
    """SHA-256 over the FIPS 180-4 Appendix B 56-byte string. Spans a
    block boundary; exercises the message-schedule extension at t=16+."""
    var h = Sha256()
    var data = _bytes_of(
        String("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    )
    h.update(data)
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        ),
    )


def test_sha256_streaming_one_million_a() raises:
    """SHA-256 of 1M repetitions of 'a' — NIST stress test. Forces
    ~15625 block compressions; locks the streaming padding contract."""
    var h = Sha256()
    var data = _rep(UInt8(0x61), 1_000_000)
    h.update(data)
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        ),
    )


# -----------------------------------------------------------------------------
# Streaming-state contract — multi-call update, fork independence, reset.
# -----------------------------------------------------------------------------


def test_sha256_streaming_multi_call_update_equivalent() raises:
    """Splitting input across multiple `update` calls produces the same
    digest as a single `update` call. Locks the buffer-fill + block-flush
    branch in `update`."""
    var h_single = Sha256()
    h_single.update(_bytes_of(String("abc")))
    var dig_single = Array[UInt8, 32](fill=0)
    h_single.finalize_into(dig_single)

    var h_split = Sha256()
    h_split.update(_bytes_of(String("a")))
    h_split.update(_bytes_of(String("bc")))
    var dig_split = Array[UInt8, 32](fill=0)
    h_split.finalize_into(dig_split)

    assert_equal(_hex_of_digest(dig_single), _hex_of_digest(dig_split))


def test_sha256_streaming_multi_call_block_boundary() raises:
    """Split a 200-byte input across three update calls at byte
    boundaries that span block ends (64, 128). Locks the buffer-vs-span
    dispatch logic in `update`."""
    var data = _rep(UInt8(0x5A), 200)

    # Single-call baseline.
    var h_baseline = Sha256()
    h_baseline.update(data)
    var dig_baseline = Array[UInt8, 32](fill=0)
    h_baseline.finalize_into(dig_baseline)

    # Multi-call: split at non-block-aligned offsets 30 + 80 + 90 = 200.
    var part1 = List[UInt8]()
    var part2 = List[UInt8]()
    var part3 = List[UInt8]()
    for i in range(200):
        if i < 30:
            part1.append(data[i])
        elif i < 110:
            part2.append(data[i])
        else:
            part3.append(data[i])

    var h_split = Sha256()
    h_split.update(part1)
    h_split.update(part2)
    h_split.update(part3)
    var dig_split = Array[UInt8, 32](fill=0)
    h_split.finalize_into(dig_split)

    assert_equal(_hex_of_digest(dig_baseline), _hex_of_digest(dig_split))


def test_sha256_streaming_fork_idempotent() raises:
    """`fork()` clones midstate; finalize_into is idempotent (self is
    read-only). Calling finalize twice on the same
    Sha256 produces the same digest; finalizing a fork produces the
    same digest as finalizing the original.

    This is the transcript-hash contract (TLS 1.3, RFC 8446 §4.4.1): clone
    the state at every transcript point WITHOUT consuming the running
    hash.
    """
    var h = Sha256()
    h.update(_bytes_of(String("transcript-prefix-")))

    # Snapshot 1: finalize_into the original (does NOT consume).
    var dig_original_first = Array[UInt8, 32](fill=0)
    h.finalize_into(dig_original_first)

    # Snapshot 2: finalize_into AGAIN — idempotent, same digest.
    var dig_original_second = Array[UInt8, 32](fill=0)
    h.finalize_into(dig_original_second)
    assert_equal(
        _hex_of_digest(dig_original_first),
        _hex_of_digest(dig_original_second),
    )

    # Snapshot 3: fork + finalize — same digest as original.
    var fork_a = h.fork()
    var dig_fork = Array[UInt8, 32](fill=0)
    fork_a.finalize_into(dig_fork)
    assert_equal(
        _hex_of_digest(dig_original_first),
        _hex_of_digest(dig_fork),
    )

    # Snapshot 4: continue with more bytes on the ORIGINAL — original
    # digest changes, fork's digest unchanged.
    h.update(_bytes_of(String("more-bytes")))
    var dig_extended = Array[UInt8, 32](fill=0)
    h.finalize_into(dig_extended)

    var dig_fork_again = Array[UInt8, 32](fill=0)
    fork_a.finalize_into(dig_fork_again)

    assert_equal(_hex_of_digest(dig_fork), _hex_of_digest(dig_fork_again))
    # Extended should NOT equal fork.
    assert_false(_hex_of_digest(dig_extended) == _hex_of_digest(dig_fork))


def test_sha256_streaming_reset_to_empty() raises:
    """After absorbing input then `reset()`-ing, the digest matches
    the empty-input digest. Locks the reset contract."""
    var h = Sha256()
    h.update(_bytes_of(String("anything-goes")))
    h.reset()
    var dig = Array[UInt8, 32](fill=0)
    h.finalize_into(dig)
    assert_equal(
        _hex_of_digest(dig),
        String(
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ),
    )


# -----------------------------------------------------------------------------
# main — invoke every test
# -----------------------------------------------------------------------------


def main() raises:
    test_sha256_streaming_empty()
    test_sha256_streaming_abc()
    test_sha256_streaming_long_message()
    test_sha256_streaming_one_million_a()
    test_sha256_streaming_multi_call_update_equivalent()
    test_sha256_streaming_multi_call_block_boundary()
    test_sha256_streaming_fork_idempotent()
    test_sha256_streaming_reset_to_empty()
    print("OK")
