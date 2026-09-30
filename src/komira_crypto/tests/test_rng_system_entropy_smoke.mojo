# =============================================================================
# komira_crypto/tests/test_rng_system_entropy_smoke.mojo
# =============================================================================
#
# Smoke tests for SystemEntropy + the
# system_entropy() free function.
#
# Sanity-level checks (NOT statistical entropy testing — AWS-LC's
# RAND_bytes runs the SP 800-90B health tests internally):
#   1. Free function: system_entropy(out) fills a 32-byte buffer with
#      non-all-zero bytes.
#   2. Free function: two back-to-back calls produce different output
#      (probability of collision = 2^-256, effectively zero).
#   3. Free function: large read (1024 bytes) handles the macOS 256-byte
#      getentropy cap by chunking.
#   4. Struct: SystemEntropy.read() works through the same FFI path.
#   5. Struct: zero-length read is a no-op (boundary case).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_crypto import SystemEntropy, system_entropy


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


def test_system_entropy_fills_32_bytes() raises:
    """system_entropy(out) fills a 32-byte buffer with non-all-zero bytes."""
    var buf = List[UInt8]()
    for _ in range(32):
        buf.append(UInt8(0))
    system_entropy(Span(buf))
    assert_false(_all_zero(buf), "32 bytes from getrandom/getentropy should not be all zero")


def test_system_entropy_two_calls_differ() raises:
    """Two back-to-back 32-byte calls produce different output."""
    var a = List[UInt8]()
    var b = List[UInt8]()
    for _ in range(32):
        a.append(UInt8(0))
        b.append(UInt8(0))
    system_entropy(Span(a))
    system_entropy(Span(b))
    assert_true(_buffers_differ(a, b), "two getrandom calls should produce different output")


def test_system_entropy_1024_bytes_chunked() raises:
    """1024-byte read crosses the macOS 256-byte getentropy cap; chunking must work."""
    var buf = List[UInt8]()
    for _ in range(1024):
        buf.append(UInt8(0))
    system_entropy(Span(buf))
    # At least one byte in each 256-byte chunk should be non-zero (probability of
    # an all-zero chunk = 2^-2048 effectively).
    for chunk in range(4):
        var any_nonzero = False
        for j in range(256):
            if buf[chunk * 256 + j] != UInt8(0):
                any_nonzero = True
                break
        assert_true(any_nonzero, "chunk should contain at least one non-zero byte")


def test_system_entropy_struct_read() raises:
    """SystemEntropy struct .read() method works via same FFI."""
    var src = SystemEntropy()
    var buf = List[UInt8]()
    for _ in range(64):
        buf.append(UInt8(0))
    src.read(Span(buf))
    assert_false(_all_zero(buf), "SystemEntropy.read(64) should fill with entropy")


def test_system_entropy_zero_length_no_op() raises:
    """Zero-length read is a no-op boundary case (no FFI call should happen)."""
    var src = SystemEntropy()
    var buf = List[UInt8]()
    # No append - empty buffer
    src.read(Span(buf))
    assert_equal(len(buf), 0, "zero-length read leaves buffer empty")


def main() raises:
    test_system_entropy_fills_32_bytes()
    test_system_entropy_two_calls_differ()
    test_system_entropy_1024_bytes_chunked()
    test_system_entropy_struct_read()
    test_system_entropy_zero_length_no_op()
    print("test_rng_system_entropy_smoke PASS (5/5)")
