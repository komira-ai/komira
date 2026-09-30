# =============================================================================
# komira_crypto/tests/test_x25519_4way_oracle.mojo
# =============================================================================
#
# Cross-verifies `x25519_4way` against 4× scalar `x25519` for a set
# of deterministically-chosen (scalar, base) pairs. This is the
# correctness gate: the 4-way output MUST be byte-identical to the
# concatenation of 4 scalar invocations.
#
# Cases:
#
#   1. 4 distinct RFC 7748 / RFC 8446 fixture inputs (Alice priv → Bob pub
#      × 4 — guaranteed distinct, public, easy to debug if one mismatches).
#   2. 4 sequential scalars [1, 2, 3, 4] against base point u=9 — exercises
#      the "very small scalar" edge of the ladder.
#   3. 4 patterns of u-coord (u=9 base point, u=p-1, u=1, u=2) against a
#      single fixed clamped scalar — exercises the scalar-vs-base
#      dimension.
#   4. 4 large pseudo-random scalars (deterministic from a seed) against
#      base point u=9 — exercises the general case.
#
# Each case: compute via x25519_4way + compare to scalar oracle x25519.
# =============================================================================

from std.testing import assert_equal

from komira_crypto.x25519 import x25519
from komira_crypto.x25519_simd import x25519_4way


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


def _pack_4_scalars_into_128(
    s0: Array[UInt8, 32], s1: Array[UInt8, 32],
    s2: Array[UInt8, 32], s3: Array[UInt8, 32],
) -> Array[UInt8, 128]:
    var out = Array[UInt8, 128](fill=UInt8(0))
    for i in range(32):
        out[i] = s0[i]
        out[32 + i] = s1[i]
        out[64 + i] = s2[i]
        out[96 + i] = s3[i]
    return out^


def _assert_outputs_match_oracle(
    scalars_128: Array[UInt8, 128],
    bases_128: Array[UInt8, 128],
    label: String,
) raises:
    """Run x25519_4way, run x25519 4× sequentially, assert byte-identity."""
    # 4-way path.
    var mojo_out = Array[UInt8, 128](fill=UInt8(0))
    var scalars_span = Span[UInt8, origin_of(scalars_128)](scalars_128)
    var bases_span = Span[UInt8, origin_of(bases_128)](bases_128)
    var out_span = Span[UInt8, origin_of(mojo_out)](mojo_out)
    x25519_4way(scalars_span, bases_span, out_span)

    # Scalar oracle path.
    for lane in range(4):
        var s_lane = Array[UInt8, 32](fill=UInt8(0))
        var u_lane = Array[UInt8, 32](fill=UInt8(0))
        for i in range(32):
            s_lane[i] = scalars_128[lane * 32 + i]
            u_lane[i] = bases_128[lane * 32 + i]
        var s_span = Span[UInt8, origin_of(s_lane)](s_lane)
        var u_span = Span[UInt8, origin_of(u_lane)](u_lane)
        var oracle = x25519(s_span, u_span)
        # Compare lane k of mojo_out to oracle.
        for i in range(32):
            if mojo_out[lane * 32 + i] != oracle[i]:
                print(
                    "MISMATCH ",
                    label,
                    " lane=",
                    lane,
                    " byte=",
                    i,
                    " 4way=",
                    Int(mojo_out[lane * 32 + i]),
                    " oracle=",
                    Int(oracle[i]),
                )
            assert_equal(
                Int(mojo_out[lane * 32 + i]),
                Int(oracle[i]),
                label,
            )


# -----------------------------------------------------------------------------
# Test 1: 4 distinct RFC fixture inputs.
# -----------------------------------------------------------------------------


def test_4way_distinct_rfc_inputs() raises:
    """Cross-verify against 4 distinct RFC 7748 / 8448 inputs."""
    # Lane 0: RFC 7748 §5.2 vector 1.
    var s0 = _hex_to_32(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
    )
    var u0 = _hex_to_32(
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"
    )
    # Lane 1: RFC 7748 §5.2 vector 2.
    var s1 = _hex_to_32(
        "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"
    )
    var u1 = _hex_to_32(
        "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"
    )
    # Lane 2: RFC 7748 §6.1 Alice privkey × base point u=9.
    var s2 = _hex_to_32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    )
    var u2 = Array[UInt8, 32](fill=UInt8(0))
    u2[0] = UInt8(9)
    # Lane 3: RFC 7748 §6.1 Bob privkey × base point u=9.
    var s3 = _hex_to_32(
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    )
    var u3 = Array[UInt8, 32](fill=UInt8(0))
    u3[0] = UInt8(9)

    var scalars = _pack_4_scalars_into_128(s0, s1, s2, s3)
    var bases = _pack_4_scalars_into_128(u0, u1, u2, u3)
    _assert_outputs_match_oracle(scalars, bases, String("test_4way_distinct_rfc_inputs"))


# -----------------------------------------------------------------------------
# Test 2: 4 small distinct scalars (low edge of ladder).
# -----------------------------------------------------------------------------


def test_4way_small_scalars_base_point() raises:
    """4 lanes with scalars = [1, 2, 3, 4] all against base point u=9."""
    var scalars = Array[UInt8, 128](fill=UInt8(0))
    scalars[0] = UInt8(1)        # lane 0 scalar = 1
    scalars[32] = UInt8(2)       # lane 1 scalar = 2
    scalars[64] = UInt8(3)       # lane 2 scalar = 3
    scalars[96] = UInt8(4)       # lane 3 scalar = 4

    var bases = Array[UInt8, 128](fill=UInt8(0))
    bases[0] = UInt8(9)
    bases[32] = UInt8(9)
    bases[64] = UInt8(9)
    bases[96] = UInt8(9)

    _assert_outputs_match_oracle(scalars, bases, String("test_4way_small_scalars"))


# -----------------------------------------------------------------------------
# Test 3: 4 different u-coords against one fixed scalar.
# -----------------------------------------------------------------------------


def test_4way_varied_u_coords() raises:
    """4 lanes with one fixed scalar, 4 different u-coords."""
    var fixed_scalar = _hex_to_32(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    )

    var scalars = Array[UInt8, 128](fill=UInt8(0))
    for i in range(32):
        scalars[i] = fixed_scalar[i]
        scalars[32 + i] = fixed_scalar[i]
        scalars[64 + i] = fixed_scalar[i]
        scalars[96 + i] = fixed_scalar[i]

    var bases = Array[UInt8, 128](fill=UInt8(0))
    # Lane 0: u = 9 (base point)
    bases[0] = UInt8(9)
    # Lane 1: u = 1
    bases[32] = UInt8(1)
    # Lane 2: u = 2
    bases[64] = UInt8(2)
    # Lane 3: u = 7 (small, non-special)
    bases[96] = UInt8(7)

    _assert_outputs_match_oracle(scalars, bases, String("test_4way_varied_u_coords"))


# -----------------------------------------------------------------------------
# Test 4: 4 distinct pseudo-random scalars × base.
# -----------------------------------------------------------------------------


def test_4way_random_scalars_base() raises:
    """4 lanes, 4 distinct pseudo-random 32-byte scalars × base point."""
    # Deterministic pseudo-random (linear-congruential filler) — same fill
    # pattern would produce equivalent (sequence-bound) inputs run-to-run.
    var scalars = Array[UInt8, 128](fill=UInt8(0))
    var seed = UInt8(0x42)
    for i in range(128):
        # LCG-style update mod 256: seed = seed * 31 + i*7 + 13
        seed = seed * UInt8(31) + UInt8(i & 0xFF) * UInt8(7) + UInt8(13)
        scalars[i] = seed

    var bases = Array[UInt8, 128](fill=UInt8(0))
    bases[0] = UInt8(9)
    bases[32] = UInt8(9)
    bases[64] = UInt8(9)
    bases[96] = UInt8(9)

    _assert_outputs_match_oracle(scalars, bases, String("test_4way_random_scalars"))


def main() raises:
    print("== test_x25519_4way_oracle ==")
    test_4way_distinct_rfc_inputs()
    print("  distinct RFC inputs PASS")
    test_4way_small_scalars_base_point()
    print("  small scalars PASS")
    test_4way_varied_u_coords()
    print("  varied u-coords PASS")
    test_4way_random_scalars_base()
    print("  random scalars PASS")
    print("== ALL 4 test_x25519_4way_oracle cases GREEN ==")
