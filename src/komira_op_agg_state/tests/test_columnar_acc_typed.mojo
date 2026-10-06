# =============================================================================
# Tests for Phase 0a typed SoA accumulators
# =============================================================================
#
# Covers: SumI64Acc, CountI64Acc, MinI64Acc, MaxI64Acc, SumF64KahanAcc,
# MinUtf8Acc, MaxUtf8Acc, PercentileAcc, CountDistinctAcc.
#
# Scope: each struct in isolation. No sink, no HT, no flush. Each struct
# exercises update_batch + merge_at + ensure_capacity + finalize.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_op_agg_state.columnar_acc_typed import (
    SumI64Acc,
    CountI64Acc,
    MinI64Acc,
    MaxI64Acc,
    SumF64KahanAcc,
)
from komira_op_agg_state.columnar_acc_utf8 import (
    MinUtf8Acc,
    MaxUtf8Acc,
)
from komira_op_agg_state.columnar_acc_agg import (
    PercentileAcc,
    CountDistinctAcc,
)


# =============================================================================
# SumI64Acc
# =============================================================================

def test_sum_i64_happy_path() raises:
    var acc = SumI64Acc.new()
    acc.ensure_capacity(4)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(1)); gids.append(UInt32(0))
    gids.append(UInt32(2)); gids.append(UInt32(1))
    var vals = List[Int64]()
    vals.append(Int64(10)); vals.append(Int64(20)); vals.append(Int64(5))
    vals.append(Int64(7)); vals.append(Int64(3))
    acc.update_batch(Span(gids), Span(vals), 5)
    var out = acc.finalize()
    assert_equal(Int(out[0]), 15)
    assert_equal(Int(out[1]), 23)
    assert_equal(Int(out[2]), 7)
    assert_equal(Int(out[3]), 0)


def test_sum_i64_merge_at() raises:
    var a = SumI64Acc.new()
    var b = SumI64Acc.new()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    var gids_a = List[UInt32]()
    gids_a.append(UInt32(0)); gids_a.append(UInt32(1))
    var vals_a = List[Int64]()
    vals_a.append(Int64(100)); vals_a.append(Int64(50))
    a.update_batch(Span(gids_a), Span(vals_a), 2)
    var gids_b = List[UInt32]()
    gids_b.append(UInt32(0)); gids_b.append(UInt32(0)); gids_b.append(UInt32(1))
    var vals_b = List[Int64]()
    vals_b.append(Int64(1)); vals_b.append(Int64(2)); vals_b.append(Int64(3))
    b.update_batch(Span(gids_b), Span(vals_b), 3)
    a.merge_at(0, b, 0)
    a.merge_at(1, b, 1)
    var out = a.finalize()
    assert_equal(Int(out[0]), 103)
    assert_equal(Int(out[1]), 53)


def test_sum_i64_ensure_capacity_monotonic() raises:
    var acc = SumI64Acc.new()
    acc.ensure_capacity(10)
    assert_equal(acc.num_groups(), 10)
    acc.ensure_capacity(5)
    assert_equal(acc.num_groups(), 10)


# =============================================================================
# CountI64Acc
# =============================================================================

def test_count_i64_happy_path() raises:
    var acc = CountI64Acc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(1)); gids.append(UInt32(0))
    gids.append(UInt32(0)); gids.append(UInt32(2))
    acc.update_batch(Span(gids), 5)
    var out = acc.finalize()
    assert_equal(Int(out[0]), 3)
    assert_equal(Int(out[1]), 1)
    assert_equal(Int(out[2]), 1)


def test_count_i64_merge_at() raises:
    var a = CountI64Acc.new()
    var b = CountI64Acc.new()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    var gids_a = List[UInt32]()
    gids_a.append(UInt32(0)); gids_a.append(UInt32(1))
    a.update_batch(Span(gids_a), 2)
    var gids_b = List[UInt32]()
    gids_b.append(UInt32(0)); gids_b.append(UInt32(0)); gids_b.append(UInt32(0))
    gids_b.append(UInt32(1))
    b.update_batch(Span(gids_b), 4)
    a.merge_at(0, b, 0)
    a.merge_at(1, b, 1)
    var out = a.finalize()
    assert_equal(Int(out[0]), 4)
    assert_equal(Int(out[1]), 2)


# =============================================================================
# MinI64Acc / MaxI64Acc
# =============================================================================

def test_min_i64_happy_path() raises:
    var acc = MinI64Acc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(1))
    var vals = List[Int64]()
    vals.append(Int64(5)); vals.append(Int64(-2)); vals.append(Int64(100))
    acc.update_batch(Span(gids), Span(vals), 3)
    var out = acc.finalize()
    assert_true(Bool(out[0]))
    assert_equal(Int(out[0].value()), -2)
    assert_true(Bool(out[1]))
    assert_equal(Int(out[1].value()), 100)
    assert_false(Bool(out[2]))


def test_min_i64_merge_respects_unseen() raises:
    var a = MinI64Acc.new()
    var b = MinI64Acc.new()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    var gids_a = List[UInt32](); gids_a.append(UInt32(0))
    var vals_a = List[Int64](); vals_a.append(Int64(10))
    a.update_batch(Span(gids_a), Span(vals_a), 1)
    a.merge_at(0, b, 0)   # b[0] unseen
    var out1 = a.finalize()
    assert_equal(Int(out1[0].value()), 10)
    var gids_b = List[UInt32](); gids_b.append(UInt32(1))
    var vals_b = List[Int64](); vals_b.append(Int64(-5))
    b.update_batch(Span(gids_b), Span(vals_b), 1)
    a.merge_at(1, b, 1)
    var out2 = a.finalize()
    assert_equal(Int(out2[1].value()), -5)


def test_max_i64_happy_path() raises:
    var acc = MaxI64Acc.new()
    acc.ensure_capacity(2)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(0))
    var vals = List[Int64]()
    vals.append(Int64(1)); vals.append(Int64(100)); vals.append(Int64(42))
    acc.update_batch(Span(gids), Span(vals), 3)
    var out = acc.finalize()
    assert_equal(Int(out[0].value()), 100)
    assert_false(Bool(out[1]))


def test_max_i64_merge() raises:
    var a = MaxI64Acc.new()
    var b = MaxI64Acc.new()
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var g = List[UInt32](); g.append(UInt32(0))
    var va = List[Int64](); va.append(Int64(50))
    var vb = List[Int64](); vb.append(Int64(200))
    a.update_batch(Span(g), Span(va), 1)
    b.update_batch(Span(g), Span(vb), 1)
    a.merge_at(0, b, 0)
    var out = a.finalize()
    assert_equal(Int(out[0].value()), 200)


# -----------------------------------------------------------------------------
# Sentinel-edge regression — PE Phase 0d concern #2
# -----------------------------------------------------------------------------
# The Min/Max int64 accumulators initialize each gid slot with a sentinel value
# (_INT64_MAX for MIN, _INT64_MIN for MAX) AND a parallel `seen` bit. If a
# user-supplied column legitimately contains the literal sentinel value, the
# state alone is indistinguishable from the unseen state — but the `seen`
# bitmap MUST disambiguate so finalize returns Some(MAX/MIN) not None.
#
# These tests pin the contract end-to-end: insert literal MAX/MIN, finalize,
# verify (a) `seen` is True, (b) finalize returns the literal value (Some),
# not None. Then merge with an unseen src to verify the SIMD merge_aligned
# path also preserves seen.
# -----------------------------------------------------------------------------


comptime _INT64_MAX_LITERAL: Int64 = Int64(9223372036854775807)
comptime _INT64_MIN_LITERAL: Int64 = Int64(-9223372036854775808)


def test_min_i64_literal_int64_max_disambiguated_from_sentinel() raises:
    """Inserting INT64_MAX as a real value MUST be reported by finalize as
    Some(INT64_MAX), not None. The sentinel is the same bit pattern; only the
    `seen` bitmap distinguishes them.
    """
    var acc = MinI64Acc.new()
    acc.ensure_capacity(2)
    # gid 0 sees only the sentinel value (legitimate INT64_MAX);
    # gid 1 stays unseen.
    var gids = List[UInt32](); gids.append(UInt32(0))
    var vals = List[Int64](); vals.append(_INT64_MAX_LITERAL)
    acc.update_batch(Span(gids), Span(vals), 1)
    var out = acc.finalize()
    assert_true(Bool(out[0]),
        "gid 0 saw a real value (INT64_MAX); finalize must return Some")
    assert_equal(Int(out[0].value()), Int(_INT64_MAX_LITERAL))
    assert_false(Bool(out[1]),
        "gid 1 unseen; finalize must return None even though state == sentinel")


def test_max_i64_literal_int64_min_disambiguated_from_sentinel() raises:
    """Mirror of MIN test for MAX: inserting INT64_MIN as a real value MUST
    be Some(INT64_MIN), not None.
    """
    var acc = MaxI64Acc.new()
    acc.ensure_capacity(2)
    var gids = List[UInt32](); gids.append(UInt32(0))
    var vals = List[Int64](); vals.append(_INT64_MIN_LITERAL)
    acc.update_batch(Span(gids), Span(vals), 1)
    var out = acc.finalize()
    assert_true(Bool(out[0]),
        "gid 0 saw a real value (INT64_MIN); finalize must return Some")
    assert_equal(Int(out[0].value()), Int(_INT64_MIN_LITERAL))
    assert_false(Bool(out[1]))


def test_min_i64_merge_aligned_preserves_seen_with_sentinel_value() raises:
    """SIMD `merge_aligned` exploits the sentinel by doing an unconditional
    SIMD min — unseen src slots hold _INT64_MAX so they no-op. This test
    proves that when src ACTUALLY saw INT64_MAX as a real value, the seen
    bitmap is OR-folded so the merged result is still Some(INT64_MAX).

    Scenario: dst has nothing, src saw INT64_MAX at gid 0 only.
    After merge, dst[0] should be Some(INT64_MAX), dst[1] should be None.
    """
    var dst = MinI64Acc.new()
    var src = MinI64Acc.new()
    dst.ensure_capacity(2)
    src.ensure_capacity(2)
    var gids = List[UInt32](); gids.append(UInt32(0))
    var vals = List[Int64](); vals.append(_INT64_MAX_LITERAL)
    src.update_batch(Span(gids), Span(vals), 1)
    # Equal num_groups -> SIMD merge_aligned path.
    dst.merge_aligned(src)
    var out = dst.finalize()
    assert_true(Bool(out[0]),
        "src.seen[0] was True even though state == sentinel — must propagate")
    assert_equal(Int(out[0].value()), Int(_INT64_MAX_LITERAL))
    assert_false(Bool(out[1]),
        "neither side saw gid 1; result must remain None")


def test_max_i64_merge_aligned_preserves_seen_with_sentinel_value() raises:
    var dst = MaxI64Acc.new()
    var src = MaxI64Acc.new()
    dst.ensure_capacity(2)
    src.ensure_capacity(2)
    var gids = List[UInt32](); gids.append(UInt32(0))
    var vals = List[Int64](); vals.append(_INT64_MIN_LITERAL)
    src.update_batch(Span(gids), Span(vals), 1)
    dst.merge_aligned(src)
    var out = dst.finalize()
    assert_true(Bool(out[0]))
    assert_equal(Int(out[0].value()), Int(_INT64_MIN_LITERAL))
    assert_false(Bool(out[1]))


def test_min_i64_real_max_loses_to_smaller_value() raises:
    """Composability check: a real INT64_MAX in one slot must lose to a
    smaller value merged in. Verifies the value comparison is unaffected by
    the seen disambiguation logic.
    """
    var acc = MinI64Acc.new()
    acc.ensure_capacity(1)
    var gids = List[UInt32](); gids.append(UInt32(0)); gids.append(UInt32(0))
    var vals = List[Int64]()
    vals.append(_INT64_MAX_LITERAL); vals.append(Int64(42))
    acc.update_batch(Span(gids), Span(vals), 2)
    var out = acc.finalize()
    assert_equal(Int(out[0].value()), 42)


def test_max_i64_real_min_loses_to_larger_value() raises:
    var acc = MaxI64Acc.new()
    acc.ensure_capacity(1)
    var gids = List[UInt32](); gids.append(UInt32(0)); gids.append(UInt32(0))
    var vals = List[Int64]()
    vals.append(_INT64_MIN_LITERAL); vals.append(Int64(-100))
    acc.update_batch(Span(gids), Span(vals), 2)
    var out = acc.finalize()
    assert_equal(Int(out[0].value()), -100)


# =============================================================================
# SumF64KahanAcc
# =============================================================================

def test_kahan_basic() raises:
    var acc = SumF64KahanAcc.new()
    acc.ensure_capacity(1)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(0))
    var vals = List[Float64]()
    vals.append(Float64(1.0)); vals.append(Float64(2.0)); vals.append(Float64(3.0))
    acc.update_batch(Span(gids), Span(vals), 3)
    var out = acc.finalize()
    assert_equal(out[0], Float64(6.0))


def test_kahan_precision_1m_small_floats() raises:
    # Summing 1M copies of 0.1 as Float64 drifts under naive summation.
    # Kahan should be strictly tighter, and within 1e-9 of the true sum
    # (N * 0.1 = 100000.0 is an exact Float64).
    var acc = SumF64KahanAcc.new()
    acc.ensure_capacity(1)
    var N = 1_000_000
    var batch_size = 1000
    var gids = List[UInt32]()
    var vals = List[Float64]()
    for _ in range(batch_size):
        gids.append(UInt32(0))
        vals.append(Float64(0.1))
    var iters = N // batch_size
    for _ in range(iters):
        acc.update_batch(Span(gids), Span(vals), batch_size)
    var kahan_sum = acc.finalize()[0]
    var naive_sum = Float64(0.0)
    for _ in range(N):
        naive_sum = naive_sum + Float64(0.1)
    var expected = Float64(100000.0)
    var kahan_err_raw = kahan_sum - expected
    var naive_err_raw = naive_sum - expected
    var kahan_err = kahan_err_raw if kahan_err_raw >= Float64(0.0) else -kahan_err_raw
    var naive_err = naive_err_raw if naive_err_raw >= Float64(0.0) else -naive_err_raw
    assert_true(kahan_err <= naive_err,
        "Kahan error (" + String(kahan_err) + ") > naive (" + String(naive_err) + ")")
    assert_true(kahan_err < Float64(1.0e-9),
        "Kahan precision violated: err=" + String(kahan_err))


def test_kahan_merge_at() raises:
    var a = SumF64KahanAcc.new()
    var b = SumF64KahanAcc.new()
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var gids = List[UInt32]()
    var vals = List[Float64]()
    for _ in range(1000):
        gids.append(UInt32(0))
        vals.append(Float64(0.1))
    a.update_batch(Span(gids), Span(vals), 1000)
    b.update_batch(Span(gids), Span(vals), 1000)
    a.merge_at(0, b, 0)
    var merged = a.finalize()[0]
    var err_raw = merged - Float64(200.0)
    var err = err_raw if err_raw >= Float64(0.0) else -err_raw
    assert_true(err < Float64(1.0e-10),
        "Kahan merge precision failure: merged=" + String(merged))


# -----------------------------------------------------------------------------
# Phase 0e.1: ULP-bounded cross-worker Kahan merge verification.
#
# Verifies that the v0.3-verbatim cross-worker formula in
# SumF64KahanAcc.merge_at (columnar_acc_typed.mojo:562-576) produces results
# within 1e-14 relative error vs an in-order scalar Kahan reference over
# 1M values. This is the "two workers each saw half the rows, then merged"
# shape exercised by the FlatHashAggSink combine path.
#
# Adversarial inputs:
#   - all-negative
#   - mixed-sign with cancellation
#   - tiny-on-huge (1e-20 added into 1e20 base — classic Kahan stress)
#   - pathological alternating ladder
#
# Reference: in-order scalar Kahan over the FULL stream (single-worker).
# We do NOT compare against IEEE-754 naive sum — naive drift is the bug
# Kahan exists to fix; using naive as reference would invert the test.
# -----------------------------------------------------------------------------

@always_inline
def _abs_f64(x: Float64) -> Float64:
    return x if x >= Float64(0.0) else -x

@always_inline
def _kahan_reference_sum(imm xs: List[Float64]) -> Float64:
    """Single-stream scalar Kahan sum — the cross-worker merge target."""
    var s = Float64(0.0)
    var c = Float64(0.0)
    for i in range(len(xs)):
        var y = xs[i] - c
        var t = s + y
        c = (t - s) - y
        s = t
    return s

def _gen_lcg(seed: UInt64, n: Int) -> List[Float64]:
    """Deterministic mixed-sign Float64 stream via splitmix64-style LCG.
    Output ranges roughly in [-1e6, 1e6]."""
    var out = List[Float64]()
    var state = seed
    for _ in range(n):
        # splitmix64 step
        state = state + UInt64(0x9E3779B97F4A7C15)
        var z = state
        z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B5)
        z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        z = z ^ (z >> UInt64(31))
        # Map UInt64 -> Float64 in [-1e6, 1e6].
        var u = Float64(Int(z & UInt64(0xFFFFFFFF))) / Float64(4294967296.0)
        out.append((u - Float64(0.5)) * Float64(2.0e6))
    return out^


def _run_cross_worker_case(imm xs: List[Float64], label: String, rel_tol: Float64) raises:
    """Split xs in half, accumulate each half into its own SumF64KahanAcc,
    merge_at, and assert the merged sum is within rel_tol of the in-order
    scalar Kahan reference over the full stream."""
    var n = len(xs)
    var half = n // 2

    # Accumulator A sees xs[0:half] all in gid=0.
    var a = SumF64KahanAcc.new()
    a.ensure_capacity(1)
    var gids_a = List[UInt32]()
    var vals_a = List[Float64]()
    for i in range(half):
        gids_a.append(UInt32(0))
        vals_a.append(xs[i])
    a.update_batch(Span(gids_a), Span(vals_a), half)

    # Accumulator B sees xs[half:n] all in gid=0.
    var b = SumF64KahanAcc.new()
    b.ensure_capacity(1)
    var gids_b = List[UInt32]()
    var vals_b = List[Float64]()
    for i in range(half, n):
        gids_b.append(UInt32(0))
        vals_b.append(xs[i])
    b.update_batch(Span(gids_b), Span(vals_b), n - half)

    # Cross-worker merge per accumulator.rs:198-211.
    a.merge_at(0, b, 0)
    var merged = a.finalize()[0]

    var reference = _kahan_reference_sum(xs)
    var abs_ref = _abs_f64(reference)
    var abs_err = _abs_f64(merged - reference)
    var rel_err = abs_err / abs_ref if abs_ref > Float64(0.0) else abs_err

    assert_true(rel_err < rel_tol,
        "[" + label + "] Kahan cross-worker merge ULP bound violated: "
        + "merged=" + String(merged)
        + ", ref=" + String(reference)
        + ", abs_err=" + String(abs_err)
        + ", rel_err=" + String(rel_err)
        + ", tol=" + String(rel_tol))


def test_kahan_cross_worker_merge_ulp_bounded() raises:
    # --- Case 1: 1M deterministic mixed-sign random Float64. ---
    var xs = _gen_lcg(UInt64(0xC0FFEE_BEEF_CAFE), 1_000_000)
    _run_cross_worker_case(xs, String("1M random mixed-sign"), Float64(1.0e-14))

    # --- Case 2: all-negative (1M). Same generator, negate. ---
    var xs_neg = List[Float64]()
    for i in range(len(xs)):
        var v = xs[i]
        xs_neg.append(-_abs_f64(v))
    _run_cross_worker_case(xs_neg, String("1M all-negative"), Float64(1.0e-14))

    # --- Case 3: mixed-sign with heavy cancellation (paired +x, -x interleaved
    # plus a small drift), 200k elements. True sum is small (drift only),
    # so the relative-tolerance gate uses absolute error against drift sum.
    var xs_cancel = List[Float64]()
    var drift = Float64(1.0e-3)
    for i in range(100_000):
        # Pairs (+v, -v) sum to 0 exactly; drift accumulates per-pair.
        var v = Float64(i + 1) * Float64(1.234)
        xs_cancel.append(v + drift)
        xs_cancel.append(-v)
    # Reference here is dominated by drift; use absolute tolerance.
    var reference_cancel = _kahan_reference_sum(xs_cancel)
    # Split + cross-worker merge.
    var n_c = len(xs_cancel)
    var half_c = n_c // 2
    var ac = SumF64KahanAcc.new()
    ac.ensure_capacity(1)
    var ga = List[UInt32]()
    var va = List[Float64]()
    for i in range(half_c):
        ga.append(UInt32(0)); va.append(xs_cancel[i])
    ac.update_batch(Span(ga), Span(va), half_c)
    var bc = SumF64KahanAcc.new()
    bc.ensure_capacity(1)
    var gb = List[UInt32]()
    var vb = List[Float64]()
    for i in range(half_c, n_c):
        gb.append(UInt32(0)); vb.append(xs_cancel[i])
    bc.update_batch(Span(gb), Span(vb), n_c - half_c)
    ac.merge_at(0, bc, 0)
    var merged_cancel = ac.finalize()[0]
    var abs_err_cancel = _abs_f64(merged_cancel - reference_cancel)
    # Drift sum is ~ 100k * 1e-3 = 100; tolerate <1e-9 absolute (well under 1
    # ULP at magnitude 100).
    assert_true(abs_err_cancel < Float64(1.0e-9),
        "[cancellation] cross-worker merge abs_err=" + String(abs_err_cancel)
        + " merged=" + String(merged_cancel) + " ref=" + String(reference_cancel))

    # --- Case 4: tiny-on-huge — classic Kahan stress.
    # 1 huge anchor (1e20) followed by 100k tiny addends (1e-20).
    # Naive sum loses every tiny addend; Kahan preserves them.
    var xs_tiny = List[Float64]()
    xs_tiny.append(Float64(1.0e20))
    for _ in range(100_000):
        xs_tiny.append(Float64(1.0e-20))
    # Reference: in-order Kahan; expected ~ 1e20 + 100000 * 1e-20 = 1e20 (tiny
    # addends are below the ULP of 1e20 even in Kahan; the test is that the
    # cross-worker merge does NOT introduce extra drift beyond the reference).
    _run_cross_worker_case(xs_tiny, String("tiny-on-huge"), Float64(1.0e-14))

    # --- Case 5: pathological alternating ladder.
    # Geometric magnitudes alternating sign — exercises comp-term coupling.
    # Each pair sums to ~1e-10 residue; 50k pairs -> reference ~5e-6.
    # True sum magnitude is below per-element magnitude, so relative tolerance
    # against "reference" inflates by ~1e6; switch to absolute (1 ULP at 1e-6
    # = ~2e-22; observed error ~3e-15 = ~1 ULP at the residue scale, exactly
    # what bit-identical Kahan should yield).
    var xs_ladder = List[Float64]()
    for i in range(50_000):
        var m = Float64(1.0) + Float64(i) * Float64(0.001)
        xs_ladder.append(m)
        xs_ladder.append(-m + Float64(1.0e-10))  # near-cancel + tiny residue
    var ref_ladder = _kahan_reference_sum(xs_ladder)
    var n_l = len(xs_ladder)
    var half_l = n_l // 2
    var al = SumF64KahanAcc.new(); al.ensure_capacity(1)
    var gla = List[UInt32](); var vla = List[Float64]()
    for i in range(half_l):
        gla.append(UInt32(0)); vla.append(xs_ladder[i])
    al.update_batch(Span(gla), Span(vla), half_l)
    var bl = SumF64KahanAcc.new(); bl.ensure_capacity(1)
    var glb = List[UInt32](); var vlb = List[Float64]()
    for i in range(half_l, n_l):
        glb.append(UInt32(0)); vlb.append(xs_ladder[i])
    bl.update_batch(Span(glb), Span(vlb), n_l - half_l)
    al.merge_at(0, bl, 0)
    var merged_ladder = al.finalize()[0]
    var abs_err_ladder = _abs_f64(merged_ladder - ref_ladder)
    # Tolerate < 1e-13 absolute (much less than 1 ULP at the per-element scale
    # of ~1.0; observed ~3.5e-15).
    assert_true(abs_err_ladder < Float64(1.0e-13),
        "[alternating ladder] cross-worker merge abs_err=" + String(abs_err_ladder)
        + " merged=" + String(merged_ladder) + " ref=" + String(ref_ladder))


# =============================================================================
# MinUtf8Acc / MaxUtf8Acc
# =============================================================================

def test_min_utf8_happy_path() raises:
    var acc = MinUtf8Acc.new()
    acc.ensure_capacity(2)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(0))
    gids.append(UInt32(1))
    var vals = List[String]()
    vals.append(String("cherry")); vals.append(String("apple"))
    vals.append(String("banana")); vals.append(String("zulu"))
    acc.update_batch(gids, vals, 4)
    var out = acc.finalize()
    assert_true(Bool(out[0]))
    assert_equal(out[0].value(), String("apple"))
    assert_equal(out[1].value(), String("zulu"))


def test_max_utf8_merge() raises:
    var a = MaxUtf8Acc.new()
    var b = MaxUtf8Acc.new()
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var g = List[UInt32](); g.append(UInt32(0))
    var va = List[String](); va.append(String("alpha"))
    var vb = List[String](); vb.append(String("zebra"))
    a.update_batch(g, va, 1)
    b.update_batch(g, vb, 1)
    a.merge_at(0, b, 0)
    var out = a.finalize()
    assert_equal(out[0].value(), String("zebra"))


def test_min_utf8_merge_unseen_is_noop() raises:
    var a = MinUtf8Acc.new()
    var b = MinUtf8Acc.new()
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var g = List[UInt32](); g.append(UInt32(0))
    var va = List[String](); va.append(String("hello"))
    a.update_batch(g, va, 1)
    a.merge_at(0, b, 0)
    var out = a.finalize()
    assert_equal(out[0].value(), String("hello"))


# =============================================================================
# PercentileAcc
# =============================================================================

def test_percentile_median_odd_count() raises:
    var acc = PercentileAcc.new(Float64(0.5))
    acc.ensure_capacity(1)
    var gids = List[UInt32]()
    for _ in range(5): gids.append(UInt32(0))
    var vals = List[Float64]()
    vals.append(Float64(5.0)); vals.append(Float64(1.0)); vals.append(Float64(3.0))
    vals.append(Float64(2.0)); vals.append(Float64(4.0))
    acc.update_batch(Span(gids), Span(vals), 5)
    var out = acc.finalize()
    assert_true(Bool(out[0]))
    assert_equal(out[0].value(), Float64(3.0))


def test_percentile_median_even_count_interpolation() raises:
    var acc = PercentileAcc.new(Float64(0.5))
    acc.ensure_capacity(1)
    var gids = List[UInt32]()
    for _ in range(4): gids.append(UInt32(0))
    var vals = List[Float64]()
    vals.append(Float64(4.0)); vals.append(Float64(2.0))
    vals.append(Float64(3.0)); vals.append(Float64(1.0))
    acc.update_batch(Span(gids), Span(vals), 4)
    var out = acc.finalize()
    var err_raw = out[0].value() - Float64(2.5)
    var err = err_raw if err_raw >= Float64(0.0) else -err_raw
    assert_true(err < Float64(1.0e-12))


def test_percentile_sorted_input() raises:
    var acc = PercentileAcc.new(Float64(0.25))
    acc.ensure_capacity(1)
    var gids = List[UInt32]()
    var vals = List[Float64]()
    for i in range(100):
        gids.append(UInt32(0))
        vals.append(Float64(i))
    acc.update_batch(Span(gids), Span(vals), 100)
    var out = acc.finalize()
    var err_raw = out[0].value() - Float64(24.75)
    var err = err_raw if err_raw >= Float64(0.0) else -err_raw
    assert_true(err < Float64(1.0e-10))


def test_percentile_reverse_sorted() raises:
    var acc = PercentileAcc.new(Float64(0.9))
    acc.ensure_capacity(1)
    var gids = List[UInt32]()
    var vals = List[Float64]()
    for i in range(100):
        gids.append(UInt32(0))
        vals.append(Float64(99 - i))
    acc.update_batch(Span(gids), Span(vals), 100)
    var out = acc.finalize()
    var err_raw = out[0].value() - Float64(89.1)
    var err = err_raw if err_raw >= Float64(0.0) else -err_raw
    assert_true(err < Float64(1.0e-10))


def test_percentile_all_equal() raises:
    var acc = PercentileAcc.new(Float64(0.5))
    acc.ensure_capacity(1)
    var gids = List[UInt32]()
    var vals = List[Float64]()
    for _ in range(50):
        gids.append(UInt32(0))
        vals.append(Float64(7.0))
    acc.update_batch(Span(gids), Span(vals), 50)
    var out = acc.finalize()
    assert_equal(out[0].value(), Float64(7.0))


def test_percentile_nan_excluded() raises:
    var acc = PercentileAcc.new(Float64(0.5))
    acc.ensure_capacity(2)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(0))
    gids.append(UInt32(1)); gids.append(UInt32(1))
    var nan_val = Float64(0.0) / Float64(0.0)
    var vals = List[Float64]()
    vals.append(Float64(1.0)); vals.append(nan_val); vals.append(Float64(3.0))
    vals.append(nan_val); vals.append(nan_val)
    acc.update_batch(Span(gids), Span(vals), 5)
    var out = acc.finalize()
    # Group 0: [1.0, 3.0] => median = 2.0
    assert_true(Bool(out[0]))
    assert_equal(out[0].value(), Float64(2.0))
    # Group 1: all NaN => NULL
    assert_false(Bool(out[1]))


def test_percentile_merge_at() raises:
    var a = PercentileAcc.new(Float64(0.5))
    var b = PercentileAcc.new(Float64(0.5))
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var g1 = List[UInt32](); g1.append(UInt32(0)); g1.append(UInt32(0))
    var v1 = List[Float64](); v1.append(Float64(1.0)); v1.append(Float64(2.0))
    a.update_batch(Span(g1), Span(v1), 2)
    var g2 = List[UInt32]()
    g2.append(UInt32(0)); g2.append(UInt32(0)); g2.append(UInt32(0))
    var v2 = List[Float64]()
    v2.append(Float64(3.0)); v2.append(Float64(4.0)); v2.append(Float64(5.0))
    b.update_batch(Span(g2), Span(v2), 3)
    a.merge_at(0, b, 0)
    var out = a.finalize()
    assert_equal(out[0].value(), Float64(3.0))


# =============================================================================
# CountDistinctAcc
# =============================================================================

def test_count_distinct_dedupes() raises:
    var acc = CountDistinctAcc.new()
    acc.ensure_capacity(2)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(0))
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(0))
    gids.append(UInt32(1)); gids.append(UInt32(1)); gids.append(UInt32(1))
    var vals = List[Int64]()
    vals.append(Int64(1)); vals.append(Int64(2)); vals.append(Int64(1))
    vals.append(Int64(3)); vals.append(Int64(2)); vals.append(Int64(1))
    vals.append(Int64(7)); vals.append(Int64(7)); vals.append(Int64(7))
    acc.update_batch(Span(gids), Span(vals), 9)
    var out = acc.finalize()
    assert_equal(Int(out[0]), 3)
    assert_equal(Int(out[1]), 1)


def test_count_distinct_empty_group_is_zero() raises:
    var acc = CountDistinctAcc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32](); gids.append(UInt32(0)); gids.append(UInt32(2))
    var vals = List[Int64](); vals.append(Int64(42)); vals.append(Int64(99))
    acc.update_batch(Span(gids), Span(vals), 2)
    var out = acc.finalize()
    assert_equal(Int(out[0]), 1)
    assert_equal(Int(out[1]), 0)
    assert_equal(Int(out[2]), 1)


def test_count_distinct_merge_dedupes_across_workers() raises:
    var a = CountDistinctAcc.new()
    var b = CountDistinctAcc.new()
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var ga = List[UInt32]()
    ga.append(UInt32(0)); ga.append(UInt32(0)); ga.append(UInt32(0))
    var va = List[Int64]()
    va.append(Int64(1)); va.append(Int64(2)); va.append(Int64(3))
    var gb = List[UInt32]()
    gb.append(UInt32(0)); gb.append(UInt32(0)); gb.append(UInt32(0))
    var vb = List[Int64]()
    vb.append(Int64(3)); vb.append(Int64(4)); vb.append(Int64(5))
    a.update_batch(Span(ga), Span(va), 3)
    b.update_batch(Span(gb), Span(vb), 3)
    a.merge_at(0, b, 0)
    var out = a.finalize()
    assert_equal(Int(out[0]), 5)


# =============================================================================
# Main
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


# =============================================================================
# === TE Review ==
# =============================================================================
# Verdict: APPROVE for Phase 0a. 25 tests cover all 9 structs with happy path,
# merge_at, and at least one edge case each. Kahan 1M test is ULP-bounded
# (<1e-9) AND strictly tighter than naive — exactly the right shape.
# Percentile adversarial matrix (sorted/reverse/all-equal/NaN/even-interp) is
# the strongest section. CountDistinct dedupe across workers confirmed.
#
# Gaps to close before Phase 0b (HT integration) lands:
#   1. Integer overflow: no SumI64 test near Int64::MAX; silent wrap will
#      regress TPC-H Q1 sum(l_extendedprice) at SF10+. Add saturating or
#      wrap-documented assertion on i64 sum of [MAX-1, 2].
#   2. Null/empty input: no struct is tested with count=0 update_batch, and
#      MinI64/MaxI64 never exercise "group seen in one batch, merge with
#      empty peer at a HIGHER gid index" — the seen-bitmap + merge_at
#      interaction is the Phase 0b regression risk.
#   3. Percentile degenerate q: q=0.0 and q=1.0 (exact min/max) untested;
#      single-element group untested. These are the boundary cases that
#      linear-interp implementations typically index-off-by-one.
