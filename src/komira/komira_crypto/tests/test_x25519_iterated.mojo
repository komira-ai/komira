# =============================================================================
# komira_crypto/tests/test_x25519_iterated.mojo
# =============================================================================
#
# RFC 7748 §5.2 iterated test:
#
#   k = 0900...00     # u = 9 (base point)
#   u = 0900...00
#   for _ in range(N):
#       k', u' = x25519(k, u), k
#       k, u = k', u'
#
# The 1M-iteration vector is not run (at ~50µs/op it would take ~50s);
# passing at 1000 iterations is sufficient correctness assurance.
#
# RFC 7748 §5.2 vectors (k, little-endian hex) after iteration:
#   After 1 iter:    422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079
#   After 1000 iter: 684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51
#   After 1000000 iter: 7c3911e0ab2586fd864497297e575e6f3bc601c0883c30df5f4dd2d24f665424
# =============================================================================

from std.testing import assert_equal

from komira_crypto.x25519 import x25519


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


def _run_iterated(n_iters: Int) raises -> Array[UInt8, 32]:
    """Run the RFC 7748 §5.2 iterated procedure for n_iters iterations."""
    # Initial k = u = 0x0900...00 (i.e. byte 0 = 9, rest zero).
    var k = Array[UInt8, 32](fill=UInt8(0))
    k[0] = UInt8(9)
    var u = Array[UInt8, 32](fill=UInt8(0))
    u[0] = UInt8(9)

    for _ in range(n_iters):
        var k_span = Span[UInt8, origin_of(k)](k)
        var u_span = Span[UInt8, origin_of(u)](u)
        var k_next = x25519(k_span, u_span)
        # u_next = k (the OLD k, before this iteration's update)
        var u_next = Array[UInt8, 32](fill=UInt8(0))
        for i in range(32):
            u_next[i] = k[i]
        # k = k_next
        for i in range(32):
            k[i] = k_next[i]
        for i in range(32):
            u[i] = u_next[i]
    return k^


def test_iterated_1() raises:
    """RFC 7748 §5.2 — after 1 iteration."""
    var result = _run_iterated(1)
    var expected = _hex_to_32(
        "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"
    )
    for i in range(32):
        assert_equal(
            Int(result[i]),
            Int(expected[i]),
            "Iterated-1 byte " + String(i),
        )


def test_iterated_1000() raises:
    """RFC 7748 §5.2 — after 1000 iterations.

    This is the moderate-cost gate; the 1M-iteration vector is not run.
    """
    var result = _run_iterated(1000)
    var expected = _hex_to_32(
        "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"
    )
    for i in range(32):
        assert_equal(
            Int(result[i]),
            Int(expected[i]),
            "Iterated-1000 byte " + String(i),
        )


def main() raises:
    print("== test_x25519_iterated ==")
    test_iterated_1()
    print("  Iterated 1-iter PASS")
    test_iterated_1000()
    print("  Iterated 1000-iter PASS")
    print("ALL X25519 iterated tests PASS")
