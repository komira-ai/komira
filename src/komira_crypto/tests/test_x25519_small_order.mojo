# =============================================================================
# komira_crypto/tests/test_x25519_small_order.mojo
# =============================================================================
#
# Small-order-point handling per RFC 7748 §6.1 + Wycheproof corpus.
#
# RFC 7748 §6.1 is explicit that implementations are NOT required to
# REJECT small-order u-coordinates; instead, the scalar clamping (`k &=
# ~7` clears the low 3 bits, ensuring k is divisible by 8 = cofactor)
# guarantees that any small-order point input produces a zero shared
# secret. The CORRECT behavior is to PRODUCE zero output for these
# inputs — a higher-layer protocol MAY then reject the all-zero result.
#
# We verify two classes:
#
#   1. **Trivial small-order inputs**: u = 0 and u = 1. Both have small
#      order; after cofactor clearing in the scalar, k*P = identity, so
#      the u-coordinate of the result is 0.
#
#   2. **Wycheproof small-order points** (from C2SP/wycheproof
#      `x25519_test.json` flagged ZeroSharedSecret cases): specific
#      u-coordinates with order divisible by 8 (the curve25519 cofactor).
#      All produce zero shared secret.
#
# The acceptance gate: "small-order point
# rejection per Wycheproof — outputs zero or correctly handled".
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


def _assert_all_zero(b: Array[UInt8, 32], label: String) raises:
    for i in range(32):
        assert_equal(Int(b[i]), 0, label + " byte " + String(i))


# Arbitrary 32-byte scalar; any valid clamped scalar yields zero output
# for these small-order u inputs. We use the RFC 7748 §5.2 vector 1
# scalar for reproducibility.
def _vector_scalar() -> Array[UInt8, 32]:
    return _hex_to_32(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
    )


# -----------------------------------------------------------------------------
# Test: u = 0 produces all-zero output.
# -----------------------------------------------------------------------------


def test_small_order_u_zero() raises:
    """u = 0 (the point at infinity in some representations) → zero output."""
    var scalar = _vector_scalar()
    var u = Array[UInt8, 32](fill=UInt8(0))
    var sc_span = Span[UInt8, origin_of(scalar)](scalar)
    var u_span = Span[UInt8, origin_of(u)](u)
    var result = x25519(sc_span, u_span)
    _assert_all_zero(result, "u=0 result")


# -----------------------------------------------------------------------------
# Test: u = 1 produces all-zero output (small order 4).
# -----------------------------------------------------------------------------


def test_small_order_u_one() raises:
    """u = 1 has order 4 on curve25519 → zero output after cofactor clearing."""
    var scalar = _vector_scalar()
    var u = Array[UInt8, 32](fill=UInt8(0))
    u[0] = UInt8(1)
    var sc_span = Span[UInt8, origin_of(scalar)](scalar)
    var u_span = Span[UInt8, origin_of(u)](u)
    var result = x25519(sc_span, u_span)
    _assert_all_zero(result, "u=1 result")


# -----------------------------------------------------------------------------
# Test: Wycheproof small-order point — u = 0x57119fd0dd4e22d8868e1c58c45c443
#                                          5078ff10d8f6fb98c1c8b6bba1f44f
#                                          93dba9 (specific 8-torsion point).
# -----------------------------------------------------------------------------


def test_small_order_wycheproof_8torsion() raises:
    """Wycheproof small-order vector — 8-torsion point.

    This u-coordinate corresponds to a point of order 8 on curve25519.
    After scalar clamping clears the low 3 bits (k = 8*k'), 8 * P_8 =
    identity, so the u-coordinate of the result is 0.
    """
    var scalar = _vector_scalar()
    # u = 0xe0... — one of the 8-torsion u-coordinates per RFC 7748 §6.1.
    # Specifically: u = (-1 - sqrt(-1)) / 2  encoded in 32 bytes little-endian.
    # We use the canonical Wycheproof small-order test case ZeroSharedSecret-
    # flag entry. The exact byte pattern comes from the Wycheproof corpus.
    # Use one of the documented small-order u values:
    #   u = 00...01  (which is fully 8-torsion; tested as u=1 above)
    #   u = 5f9c95bc... (order 2)
    # We use u = e0eb7a7c... a specific 8-torsion point.
    var u = _hex_to_32(
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"
    )
    var sc_span = Span[UInt8, origin_of(scalar)](scalar)
    var u_span = Span[UInt8, origin_of(u)](u)
    var result = x25519(sc_span, u_span)
    _assert_all_zero(result, "Wycheproof 8-torsion result")


# -----------------------------------------------------------------------------
# Test: u = p - 1 (= 2^255 - 20) — element of order 1 (the identity in
# Montgomery form) — should also produce zero.
# -----------------------------------------------------------------------------


def test_small_order_u_p_minus_one() raises:
    """u = p - 1 → small order → zero output.

    p - 1 in little-endian bytes: 0xec, 0xff, 0xff, ..., 0x7f.
    (p = 2^255 - 19; p-1 = 2^255 - 20 = 0xec || 0xff*30 || 0x7f.)
    """
    var scalar = _vector_scalar()
    var u = Array[UInt8, 32](fill=UInt8(0xFF))
    u[0] = UInt8(0xEC)
    u[31] = UInt8(0x7F)
    var sc_span = Span[UInt8, origin_of(scalar)](scalar)
    var u_span = Span[UInt8, origin_of(u)](u)
    var result = x25519(sc_span, u_span)
    _assert_all_zero(result, "u=p-1 result")


def main() raises:
    print("== test_x25519_small_order ==")
    test_small_order_u_zero()
    print("  u=0 → zero shared secret PASS")
    test_small_order_u_one()
    print("  u=1 (order 4) → zero shared secret PASS")
    test_small_order_wycheproof_8torsion()
    print("  Wycheproof 8-torsion → zero shared secret PASS")
    test_small_order_u_p_minus_one()
    print("  u=p-1 (order 1 in Montgomery form) → zero shared secret PASS")
    print("ALL X25519 small-order tests PASS")
