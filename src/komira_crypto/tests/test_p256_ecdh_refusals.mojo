# =============================================================================
# komira_crypto/tests/test_p256_ecdh_refusals.mojo
# =============================================================================
#
# What `p256_ecdh` refuses, each with its exact error message, and the two
# private-key boundaries it accepts:
#
#   * peer points off the curve, including a point whose y differs from a
#     valid one by one bit (it lies on another curve with the same `a`: the
#     invalid-curve attack input) and the all-zero (0, 0) encoding;
#   * the point at infinity (SEC1 single byte 0x00);
#   * wrong peer encodings: compressed (33 bytes), bare x || y (64 bytes), a
#     65-byte buffer with a leading byte other than 0x04, including the
#     hybrid encoding (0x06) of a valid point;
#   * private keys that are 31 or 33 bytes, are zero, or equal the order n;
#   * accepted boundaries: priv = 1 gives x(Q), and priv = n - 1 gives
#     x(-Q) = x(Q), so both must return Q's x-coordinate.
#
# The peer point Q used throughout is QCAVS of NIST CAVP KAS ECC CDH P-256
# COUNT 0.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import hex_lower_array_32, p256_ecdh


comptime _QX = "700c48f77f56584c5cc632ca65640db91b6bacce3a4df6b42ce7cc838833d287"
comptime _QY = "db71e509e3fd9b060ddb20ba5c51dcc5948d46fbf640dfe0441782cab85fa4ac"
# A valid private key (dIUT of the same CAVP vector).
comptime _D = "7d7dc5f71eb29ddaf80d6214632eeae03d9058af1fb6d22ed80badb62bc1a534"
# The P-256 group order n.
comptime _N = "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"
comptime _N_MINUS_1 = (
    "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550"
)


def _nibble(c: UInt8) raises -> UInt8:
    if c >= UInt8(0x30) and c <= UInt8(0x39):
        return c - UInt8(0x30)
    if c >= UInt8(0x61) and c <= UInt8(0x66):
        return c - UInt8(0x61) + UInt8(10)
    raise Error("bad hex digit in a test input")


def _hex(s: String) raises -> List[UInt8]:
    var bs = s.as_bytes()
    if len(bs) % 2 != 0:
        raise Error("odd-length hex in a test input")
    var out = List[UInt8](capacity=len(bs) // 2)
    for i in range(len(bs) // 2):
        out.append((_nibble(bs[2 * i]) << UInt8(4)) | _nibble(bs[2 * i + 1]))
    return out^


def _outcome(priv: List[UInt8], peer: List[UInt8]) -> String:
    """`OK <hex Z>`, or the message p256_ecdh raised."""
    try:
        var z = p256_ecdh(Span(priv), Span(peer))
        return String("OK ") + hex_lower_array_32(z)
    except e:
        return String(e)


def _expect(
    label: String, priv: List[UInt8], peer: List[UInt8], want: String
) raises:
    assert_equal(_outcome(priv, peer), want, label)


def _valid_peer() raises -> List[UInt8]:
    return _hex("04" + _QX + _QY)


def test_off_curve_points_refused() raises:
    var d = _hex(_D)
    # y with its lowest bit flipped: (x, y') satisfies y'^2 = x^3 - 3x + b'
    # for some b' != b, a point on a different curve.
    var flipped = _valid_peer()
    flipped[64] = flipped[64] ^ UInt8(0x01)
    _expect(
        "y off by one bit",
        d,
        flipped,
        "p256_ecdh: peer public key is not a point on P-256",
    )
    var zeros = List[UInt8](length=65, fill=UInt8(0))
    zeros[0] = UInt8(0x04)
    _expect(
        "(0, 0)",
        d,
        zeros,
        "p256_ecdh: peer public key is not a point on P-256",
    )


def test_point_at_infinity_refused() raises:
    _expect(
        "SEC1 infinity",
        _hex(_D),
        _hex("00"),
        "p256_ecdh: peer public key is the point at infinity",
    )


def test_wrong_peer_encodings_refused() raises:
    var d = _hex(_D)
    _expect(
        "compressed",
        d,
        _hex("02" + _QX),
        "p256_ecdh: peer public key must be 65 bytes, got 33",
    )
    _expect(
        "bare x || y",
        d,
        _hex(_QX + _QY),
        "p256_ecdh: peer public key must be 65 bytes, got 64",
    )
    # The hybrid SEC1 form of Q (0x06: y is even). AWS-LC's oct2point
    # accepts it, so only p256_ecdh's own 0x04 check refuses it.
    _expect(
        "65-byte hybrid encoding of a valid point",
        d,
        _hex("06" + _QX + _QY),
        "p256_ecdh: peer public key must start with 0x04 (uncompressed)",
    )
    _expect(
        "65 bytes with a compressed-form leading byte",
        d,
        _hex("02" + _QX + _QY),
        "p256_ecdh: peer public key must start with 0x04 (uncompressed)",
    )


def test_bad_private_keys_refused() raises:
    var peer = _valid_peer()
    _expect(
        "31-byte key",
        _hex(String(String(_D)[byte=2:])),
        peer,
        "p256_ecdh: private key must be 32 bytes, got 31",
    )
    _expect(
        "33-byte key (a leading 0x00, same value)",
        _hex("00" + _D),
        peer,
        "p256_ecdh: private key must be 32 bytes, got 33",
    )
    _expect(
        "zero",
        List[UInt8](length=32, fill=UInt8(0)),
        peer,
        "p256_ecdh: private key is not in [1, n-1]",
    )
    _expect(
        "n",
        _hex(_N),
        peer,
        "p256_ecdh: private key is not in [1, n-1]",
    )


def test_private_key_boundaries_accepted() raises:
    var peer = _valid_peer()
    var one = List[UInt8](length=32, fill=UInt8(0))
    one[31] = UInt8(1)
    _expect("priv = 1", one, peer, "OK " + _QX)
    _expect("priv = n - 1", _hex(_N_MINUS_1), peer, "OK " + _QX)


def main() raises:
    test_off_curve_points_refused()
    print("PASS off-curve points refused")
    test_point_at_infinity_refused()
    print("PASS point at infinity refused")
    test_wrong_peer_encodings_refused()
    print("PASS wrong peer encodings refused")
    test_bad_private_keys_refused()
    print("PASS bad private keys refused")
    test_private_key_boundaries_accepted()
    print("PASS private-key boundaries accepted")
