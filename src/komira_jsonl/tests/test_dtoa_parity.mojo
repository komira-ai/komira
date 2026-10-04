# =============================================================================
# test_dtoa_parity — parity gate for the two-tier write_f64_dtoa fast path.
# =============================================================================
#
# `write_f64_dtoa` has a fast path that bypasses stdlib `String(Float64)`
# for values in the dyadic-rational-on-10^-4-grid domain (e.g. every
# Float64 in the TPC-H lineitem table). The fast path MUST produce byte-identical output
# to stdlib OR fall back to stdlib — any silent divergence would break
# the `test_byte_identity_fused_vs_legacy` gate and customer-visible
# round-trip identity.
#
# This test sweeps:
#   1. T1 — special values (NaN, ±Inf, 0.0, -0.0) emit per the JSONL spec.
#   2. T2 — edge values (denormals, near-zero, near-max).
#   3. T3 — ULP boundaries (values where Grisu/Ryu rounding might differ).
#   4. T4 — lineitem-fixture-domain sweep (TPC-H l_quantity / extendedprice
#      / discount / tax / disc_price ranges).
#   5. T5 — 1M deterministic-seed random Float64 — bytes MUST equal stdlib
#      whenever the fast path emits; mismatch is a HARD FAIL.
# =============================================================================

from std.memory import bitcast
from std.testing import assert_equal, assert_true

from komira_jsonl.json_writer import write_f64_dtoa


def _buf_to_string(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def _dtoa_str(v: Float64) -> String:
    var buf = List[UInt8]()
    write_f64_dtoa(buf, v)
    return _buf_to_string(buf)


# =============================================================================
# T1: special values (NaN, ±Inf, 0.0, -0.0)
# =============================================================================


def test_dtoa_special_values() raises:
    print("T1: special values (NaN, ±Inf, 0.0, -0.0)")

    # NaN -> null
    var nan = Float64(0.0) / Float64(0.0)
    assert_equal(_dtoa_str(nan), String("null"))

    # +Inf -> null
    var pinf = Float64(1.0) / Float64(0.0)
    assert_equal(_dtoa_str(pinf), String("null"))

    # -Inf -> null
    var ninf = Float64(-1.0) / Float64(0.0)
    assert_equal(_dtoa_str(ninf), String("null"))

    # +0.0 -> "0.0" (stdlib output preserved by fast path)
    assert_equal(_dtoa_str(Float64(0.0)), String(Float64(0.0)))

    # -0.0 -> "-0.0" (slow-path fallback preserves sign)
    var nz = bitcast[DType.float64](UInt64(0x8000000000000000))
    assert_equal(_dtoa_str(nz), String(nz))

    print("  PASS")


# =============================================================================
# T2: edge values (denormals, near-zero, near-max)
# =============================================================================


def test_dtoa_edge_values() raises:
    print("T2: edge values")

    # Subnormal min (5e-324) — slow-path fallback
    var min_subnormal = bitcast[DType.float64](UInt64(1))
    assert_equal(_dtoa_str(min_subnormal), String(min_subnormal))

    # Smallest normal (2.2e-308) — slow-path
    var min_normal = bitcast[DType.float64](UInt64(0x0010000000000000))
    assert_equal(_dtoa_str(min_normal), String(min_normal))

    # Largest finite (1.79e+308) — slow-path
    var max_finite = bitcast[DType.float64](UInt64(0x7FEFFFFFFFFFFFFF))
    assert_equal(_dtoa_str(max_finite), String(max_finite))

    # Powers of ten — boundary between fast and slow
    assert_equal(_dtoa_str(Float64(1.0)), String(Float64(1.0)))
    assert_equal(_dtoa_str(Float64(0.1)), String(Float64(0.1)))
    assert_equal(_dtoa_str(Float64(0.01)), String(Float64(0.01)))
    assert_equal(_dtoa_str(Float64(0.001)), String(Float64(0.001)))
    assert_equal(_dtoa_str(Float64(0.0001)), String(Float64(0.0001)))

    # Sub-threshold — must take slow path (1e-5 is below the 1e-4 boundary).
    assert_equal(_dtoa_str(Float64(1.0e-5)), String(Float64(1.0e-5)))
    assert_equal(_dtoa_str(Float64(9.99e-5)), String(Float64(9.99e-5)))

    # 1e6 vs 1e9 vs 1e16 — fast path bound is 1e9.
    assert_equal(_dtoa_str(Float64(1.0e6)), String(Float64(1.0e6)))
    assert_equal(_dtoa_str(Float64(9.99e8)), String(Float64(9.99e8)))
    assert_equal(_dtoa_str(Float64(1.0e9)), String(Float64(1.0e9)))
    assert_equal(_dtoa_str(Float64(1.0e16)), String(Float64(1.0e16)))
    assert_equal(_dtoa_str(Float64(1.0e300)), String(Float64(1.0e300)))

    print("  PASS")


# =============================================================================
# T3: ULP boundaries — values near grid-snap thresholds
# =============================================================================


def test_dtoa_ulp_boundaries() raises:
    print("T3: ULP boundaries")

    # Pi — fast path REJECTS (round-trip fails); slow path emits stdlib bytes.
    var pi = Float64(3.14159265358979323846)
    assert_equal(_dtoa_str(pi), String(pi))

    # e
    var e = Float64(2.718281828459045)
    assert_equal(_dtoa_str(e), String(e))

    # Square root of 2
    var sqrt2 = Float64(1.4142135623730951)
    assert_equal(_dtoa_str(sqrt2), String(sqrt2))

    # ULP-spaced values from 1.0 (next-after 1.0)
    var next_one = bitcast[DType.float64](
        bitcast[DType.uint64](Float64(1.0)) + UInt64(1)
    )
    assert_equal(_dtoa_str(next_one), String(next_one))

    # 0.1 - one ULP (boundary near 0.1)
    var below_one_tenth = bitcast[DType.float64](
        bitcast[DType.uint64](Float64(0.1)) - UInt64(1)
    )
    assert_equal(_dtoa_str(below_one_tenth), String(below_one_tenth))

    # Values that need 17 sig digits (forced into slow path)
    assert_equal(_dtoa_str(Float64(0.1 + 0.2)), String(Float64(0.1 + 0.2)))

    print("  PASS")


# =============================================================================
# T4: lineitem fixture domain sweep
# =============================================================================


def test_dtoa_lineitem_domain() raises:
    print("T4: lineitem-fixture-domain sweep")

    # l_quantity: integer in [1, 50]
    for q in range(1, 51):
        var v = Float64(q)
        assert_equal(_dtoa_str(v), String(v))

    # l_discount: 0.00 - 0.10 with 0.01 step
    for d in range(11):
        var v = Float64(d) * Float64(0.01)
        assert_equal(_dtoa_str(v), String(v))

    # l_tax: 0.00 - 0.08 with 0.01 step
    for t in range(9):
        var v = Float64(t) * Float64(0.01)
        assert_equal(_dtoa_str(v), String(v))

    # l_extendedprice: 2-decimal monetary, spot-sample
    var ep_samples = List[Float64]()
    ep_samples.append(Float64(21168.23))
    ep_samples.append(Float64(45983.16))
    ep_samples.append(Float64(13309.6))
    ep_samples.append(Float64(67890.99))
    ep_samples.append(Float64(0.01))
    ep_samples.append(Float64(99999.99))
    for i in range(len(ep_samples)):
        var v = ep_samples[i]
        assert_equal(_dtoa_str(v), String(v))

    # l_disc_price: 4-decimal computed product, spot-sample
    var dp_samples = List[Float64]()
    dp_samples.append(Float64(20321.5008))
    dp_samples.append(Float64(41844.6756))
    dp_samples.append(Float64(11978.64))
    dp_samples.append(Float64(0.0001))
    dp_samples.append(Float64(0.9999))
    for i in range(len(dp_samples)):
        var v = dp_samples[i]
        assert_equal(_dtoa_str(v), String(v))

    # Negative variants (signed columns).
    for i in range(len(ep_samples)):
        var v = -ep_samples[i]
        assert_equal(_dtoa_str(v), String(v))

    print("  PASS (lineitem-fixture domain byte-identical)")


# =============================================================================
# T5: random 1M Float64 deterministic-seed sweep
# =============================================================================


def test_dtoa_random_1m() raises:
    print("T5: 1M random Float64 deterministic-seed sweep (byte-equal stdlib)")

    var N = 1000000
    var mismatch_count = 0
    var ok_count = 0
    # Linear-congruential generator (PCG-style multiplier + increment).
    var state: UInt64 = 0x1234567890ABCDEF

    for i in range(N):
        state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        # Project bits into a finite normal Float64. We keep:
        #   - sign bit from state[63]
        #   - mantissa from state[0..51]
        #   - exponent in [0x380..0x3FF] (covers ~1e-78 .. 1e-0 normalized)
        # then we mix in some larger-exponent values for breadth.
        var bits = state
        var sign = bits & UInt64(0x8000000000000000)
        var mantissa = bits & UInt64(0x000FFFFFFFFFFFFF)
        # Spread exponent across a wider range every 256 iterations
        var exp_low: UInt64 = UInt64(0x200) + ((bits >> 52) & UInt64(0x3FF))
        var exp_part: UInt64 = exp_low << 52
        var fbits = sign | exp_part | mantissa
        var v = bitcast[DType.float64](fbits)
        # Skip NaN/Inf for the bit-equal test (they short-circuit to "null"
        # which is correct behavior but NOT equal to String(v) = "nan" / "inf").
        if v != v:
            continue
        if v == Float64(1.0) / Float64(0.0):
            continue
        if v == Float64(-1.0) / Float64(0.0):
            continue
        var stdlib_out = String(v)
        var dtoa_out = _dtoa_str(v)
        if dtoa_out != stdlib_out:
            mismatch_count += 1
            if mismatch_count < 5:
                print(
                    "MISMATCH at i=",
                    i,
                    " bits=",
                    Int(fbits),
                    " stdlib=",
                    stdlib_out,
                    " dtoa=",
                    dtoa_out,
                )
        else:
            ok_count += 1

    print(
        "  ok=",
        ok_count,
        " mismatch=",
        mismatch_count,
        " (total non-NaN/Inf samples)",
    )
    assert_equal(mismatch_count, 0)
    print("  PASS")


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("=== test_dtoa_parity (dtoa fast-path byte-identity gate) ===")
    test_dtoa_special_values()
    test_dtoa_edge_values()
    test_dtoa_ulp_boundaries()
    test_dtoa_lineitem_domain()
    test_dtoa_random_1m()
    print("=== ALL PASSED ===")
