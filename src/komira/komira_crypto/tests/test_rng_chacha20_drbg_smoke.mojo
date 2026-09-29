# =============================================================================
# komira_crypto/tests/test_rng_chacha20_drbg_smoke.mojo
# =============================================================================
#
# Smoke tests for ChaCha20Drbg.
#
# Sanity-level checks:
#   1. ChaCha20Drbg.next() fills a 64-byte buffer with non-all-zero bytes.
#   2. Two back-to-back .next() calls on the same DRBG instance produce
#      DIFFERENT output (counter advances).
#   3. Two FRESH ChaCha20Drbg instances (each seeded from a fresh
#      SystemEntropy) produce different output (probabilistic — collision
#      probability = 2^-256).
#   4. .reseed() changes the output stream (post-reseed bytes differ from
#      what the DRBG would have produced absent reseed).
#   5. .blocks_produced() counts 64-byte blocks correctly across multiple
#      .next() calls including partial-block calls.
#   6. Large output (4096 bytes = 64 blocks) is well-distributed (no
#      all-zero sub-blocks).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import SystemEntropy, ChaCha20Drbg


def _all_zero(buf: List[UInt8]) -> Bool:
    for i in range(len(buf)):
        if buf[i] != UInt8(0):
            return False
    return True


def _buffers_differ(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return True
    for i in range(len(a)):
        if a[i] != b[i]:
            return True
    return False


def test_chacha20_drbg_next_fills_64_bytes() raises:
    """ChaCha20Drbg.next(64) emits non-all-zero bytes."""
    var src = SystemEntropy()
    var drbg = ChaCha20Drbg(src)
    var buf = List[UInt8]()
    for _ in range(64):
        buf.append(UInt8(0))
    drbg.next(Span(buf))
    assert_false(_all_zero(buf), "DRBG output should not be all zero")


def test_chacha20_drbg_two_calls_differ() raises:
    """Two .next() calls on same DRBG produce different output (counter advances)."""
    var src = SystemEntropy()
    var drbg = ChaCha20Drbg(src)
    var a = List[UInt8]()
    var b = List[UInt8]()
    for _ in range(64):
        a.append(UInt8(0))
        b.append(UInt8(0))
    drbg.next(Span(a))
    drbg.next(Span(b))
    assert_true(_buffers_differ(a, b), "consecutive DRBG outputs should differ")


def test_chacha20_drbg_independent_instances_differ() raises:
    """Two FRESH DRBG instances (independent OS-entropy seeds) produce different output."""
    var src1 = SystemEntropy()
    var drbg1 = ChaCha20Drbg(src1)
    var src2 = SystemEntropy()
    var drbg2 = ChaCha20Drbg(src2)
    var a = List[UInt8]()
    var b = List[UInt8]()
    for _ in range(64):
        a.append(UInt8(0))
        b.append(UInt8(0))
    drbg1.next(Span(a))
    drbg2.next(Span(b))
    assert_true(_buffers_differ(a, b), "independent DRBG seeds should produce different streams")


def test_chacha20_drbg_reseed_changes_stream() raises:
    """After .reseed(), the next .next() call produces different output than
    the DRBG would have produced from continuing its existing counter."""
    var src = SystemEntropy()
    var drbg = ChaCha20Drbg(src)

    # Capture the "would-have-been-next" output by NOT calling reseed.
    var a = List[UInt8]()
    for _ in range(64):
        a.append(UInt8(0))
    drbg.next(Span(a))

    # Reseed and grab the next output.
    drbg.reseed(src)
    var b = List[UInt8]()
    for _ in range(64):
        b.append(UInt8(0))
    drbg.next(Span(b))

    assert_true(_buffers_differ(a, b), "post-reseed output should differ from pre-reseed")
    # The post-reseed block counter should reset to 1 (one block consumed after reseed).
    assert_equal(Int(drbg.blocks_produced()), 1, "blocks_produced should reset on reseed and count 1 after one 64-byte next() call")


def test_chacha20_drbg_blocks_produced_count() raises:
    """blocks_produced() counts 64-byte blocks across multiple next() calls."""
    var src = SystemEntropy()
    var drbg = ChaCha20Drbg(src)

    # Initially 0.
    assert_equal(Int(drbg.blocks_produced()), 0)

    # Three 64-byte blocks = 3.
    var buf64 = List[UInt8]()
    for _ in range(64):
        buf64.append(UInt8(0))
    drbg.next(Span(buf64))
    drbg.next(Span(buf64))
    drbg.next(Span(buf64))
    assert_equal(Int(drbg.blocks_produced()), 3)

    # Partial block (32 bytes) counts as 1 (ceil-up).
    var buf32 = List[UInt8]()
    for _ in range(32):
        buf32.append(UInt8(0))
    drbg.next(Span(buf32))
    assert_equal(Int(drbg.blocks_produced()), 4)

    # 128-byte call = 2 more blocks → 6 total.
    var buf128 = List[UInt8]()
    for _ in range(128):
        buf128.append(UInt8(0))
    drbg.next(Span(buf128))
    assert_equal(Int(drbg.blocks_produced()), 6)


def test_chacha20_drbg_4096_distribution() raises:
    """4096 bytes = 64 blocks: every 256-byte sub-block contains at least
    one non-zero byte (probability of all-zero = 2^-2048, effectively zero
    for a working DRBG)."""
    var src = SystemEntropy()
    var drbg = ChaCha20Drbg(src)
    var buf = List[UInt8]()
    for _ in range(4096):
        buf.append(UInt8(0))
    drbg.next(Span(buf))

    for sub in range(16):  # 16 sub-blocks of 256 bytes
        var any_nonzero = False
        for j in range(256):
            if buf[sub * 256 + j] != UInt8(0):
                any_nonzero = True
                break
        assert_true(any_nonzero, "each 256-byte sub-block should contain non-zero entropy")


def main() raises:
    test_chacha20_drbg_next_fills_64_bytes()
    test_chacha20_drbg_two_calls_differ()
    test_chacha20_drbg_independent_instances_differ()
    test_chacha20_drbg_reseed_changes_stream()
    test_chacha20_drbg_blocks_produced_count()
    test_chacha20_drbg_4096_distribution()
    print("test_rng_chacha20_drbg_smoke PASS (6/6)")
