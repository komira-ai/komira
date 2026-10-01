# =============================================================================
# test_typed_col_median_nan_total_order.mojo
# =============================================================================
#
# THE DEFECT THIS PINS: `MedianOp[dt].finalize` sorted the per-group
# value buffer with the plain `<` comparator. On IEEE floats `<` is NOT a strict
# weak ordering in the presence of NaN (every comparison against NaN is false, so
# NaN is neither less than, greater than, nor equivalent to anything) — which
# puts `sort` OUTSIDE ITS OWN CONTRACT. The observable consequence is not "an odd
# answer for NaN": it is that the answer depends on the INPUT ORDER of a buffer
# whose order is row-arrival order per worker, concatenated in worker-merge order
# by `combine`. THREAD COUNT, MORSEL PARTITIONING AND MERGE ORDER CHANGED THE
# ANSWER FOR THE SAME TABLE.
#
# A kernel sorting with the plain `<` comparator returns, for the
# NINE rotations of the single multiset {NaN,1,2,3,4,5,6,7,8}, NINE
# DISTINCT answers —
#     rot0=4.0 rot1=5.0 rot2=6.0 rot3=7.0 rot4=8.0 rot5=nan rot6=1.0 rot7=2.0
#     rot8=3.0
# — where DuckDB returns 5.0 for every one of them. Through the real `combine`,
# one multiset split four ways finalized to 4.0 / 8.0 / nan / 4.0.
#
# NaN REACHABILITY IS NOT HYPOTHETICAL: `typed_agg_markers.mojo` stamps `MedianOp`
# over float32 and float64, and the f64/f32 arms of `HashAggOpAgg.update_scalar`
# forward the raw column scalar to `update_scalar` with NO NaN test and NO
# validity test. This is the SHIPPING typed grouped-MEDIAN path,
# and `MedianOp` is the only op with `SORT_FINALIZE = True`, so it is the sole op
# the parallel median drain ever instantiates — both its parallel and its serial
# arm go through this one `finalize`.
#
# -----------------------------------------------------------------------------
# THE CONTRACT — DuckDB v1.5.3. `median(x)` on DOUBLE == `quantile_cont(x,0.5)`
# == the order statistic under a TOTAL ORDER IN WHICH NaN IS THE LARGEST VALUE,
# mean-interpolated for even n. (`'nan' > 'inf'` is TRUE in DuckDB; `'nan' =
# 'nan'` is TRUE; ORDER BY puts NaN last. SQL NULL is a different thing and is
# EXCLUDED from the aggregate; NaN is NOT NULL.)
#
#   D  {1,2,3,NaN}            n=4  -> 2.5
#   E  {1,2,NaN,NaN}          n=4  -> NaN
#   F  {1,2,NaN,NaN,NaN}      n=5  -> NaN
#   G  {NaN,NaN,NaN}          n=3  -> NaN
#   H  {-inf,inf,NaN}         n=3  -> inf
#   J  {-inf,inf}             n=2  -> NaN
#   K  {NaN,1,2,3,4,5,6,7,8}  n=9  -> 5.0   (and identically for all 9 rotations)
#   L  {NaN,5,1,9,3,7,2}      n=7  -> 5.0
#
# THE EVEN-CASE ARITHMETIC IS A SECOND, INDEPENDENT DIVERGENCE. DuckDB does NOT
# compute `(lo + hi) / 2`; that formula OVERFLOWS to +/-inf when the two middle
# order statistics are same-signed and large. MEASURED (ours-before / DuckDB):
#   {1e308, 1e308}       inf  / 1e+308      {8.99e307, 8.99e307}  inf / 8.99e+307
#   {-1e308,-1e308}     -inf  / -1e+308     {1e308, 1.5e308}      inf / 1.25e+308
#   {5e307, 1.5e308}     inf  / 1e+308
# The formula that reproduces DuckDB is `lo*0.5 + hi*0.5`. It is discriminated
# from the other plausible spelling `lo + (hi-lo)*0.5` by {-inf,-inf}, where the
# lerp form gives NaN and DuckDB gives -inf; both agree on {-inf,inf} -> NaN.
# KNOWN, DELIBERATELY ADOPTED CONSEQUENCE: {5e-324, 5e-324} returns 0.0 (each
# half underflows) where the naive mean returns 5e-324. DuckDB also returns 0.0.
# The contract is DuckDB parity, so we match DuckDB and say so here rather than
# leaving a reader to discover it.
#
# -----------------------------------------------------------------------------
# THIS TEST DRIVES THE REAL KERNEL — it imports `MedianOp` / `MedianState` from
# `komira_eval.hash_agg_op_dt` and calls `init` / `update_scalar` / `combine` /
# `finalize`. Nothing is transcribed; a fix that lives only in a copy of the
# algorithm cannot make this green.
#
# COMPARE MODE = EXACT (`==`), not a relative epsilon. Every expected value here
# is an order statistic or an exactly-representable half-sum of two doubles, so
# an epsilon would only hide a wrong answer. NaN expectations use `isnan`.
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test. Kernel surface only.
# =============================================================================

from std.testing import TestSuite, assert_true
from std.math import isnan

from komira_eval.hash_agg_op_dt import MedianOp, MedianState


# -----------------------------------------------------------------------------
# assertion helpers — EXACT compare, and a NaN-aware sibling.
# -----------------------------------------------------------------------------
def _assert_exact(got: Float64, want: Float64, what: String) raises:
    assert_true(
        got == want,
        what + ": got=" + String(got) + " want=" + String(want) + " (EXACT)",
    )


def _assert_nan(got: Float64, what: String) raises:
    assert_true(
        isnan(got), what + ": got=" + String(got) + " want=nan"
    )


# -----------------------------------------------------------------------------
# kernel drivers — the REAL `MedianOp` surface, single-accumulator and the
# multi-partial CONCAT-`combine` shape the multi-worker drain actually produces.
# -----------------------------------------------------------------------------
def _median_single[dt: DType](imm vals: List[Scalar[dt]]) raises -> Float64:
    var st = MedianOp[dt].init()
    for i in range(len(vals)):
        MedianOp[dt].update_scalar(st, vals[i])
    return MedianOp[dt].finalize(st)


def _median_split[
    dt: DType
](imm vals: List[Scalar[dt]], imm cuts: List[Int]) raises -> Float64:
    """Feed `vals` to SEVERAL independent per-worker `MedianState`s split at
    `cuts`, then CONCAT-merge them through the real `MedianOp.combine` before
    `finalize`. `cuts` are ascending interior boundaries; the final segment runs
    to the end. This is the cross-worker shape: each partial sees an arbitrary
    contiguous slice of row-arrival order and the merge order is the worker
    order."""
    var acc = MedianOp[dt].init()
    var start = 0
    for c in range(len(cuts) + 1):
        var end = len(vals) if c == len(cuts) else cuts[c]
        var part = MedianOp[dt].init()
        for i in range(start, end):
            MedianOp[dt].update_scalar(part, vals[i])
        MedianOp[dt].combine(acc, part)
        start = end
    return MedianOp[dt].finalize(acc)


# -----------------------------------------------------------------------------
# fixture builders
# -----------------------------------------------------------------------------
def _nan_f64() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _f64(imm xs: List[Float64]) -> List[Scalar[DType.float64]]:
    var out = List[Scalar[DType.float64]]()
    for i in range(len(xs)):
        out.append(Scalar[DType.float64](xs[i]))
    return out^


def _k9_rotation(k: Int) -> List[Scalar[DType.float64]]:
    """Rotation `k` of the multiset {NaN,1,2,3,4,5,6,7,8} (n=9). Every rotation
    is the SAME multiset, so a correct MEDIAN returns the same value for all
    nine. Before the fix these returned nine DISTINCT values."""
    var base = List[Scalar[DType.float64]]()
    base.append(Scalar[DType.float64](_nan_f64()))
    for v in range(1, 9):
        base.append(Scalar[DType.float64](Float64(v)))
    var out = List[Scalar[DType.float64]]()
    for i in range(9):
        out.append(base[(i + k) % 9])
    return out^


# =============================================================================
# §1 — ROTATION INVARIANCE. The headline defect: nine orderings of ONE multiset.
# =============================================================================
def test_nan_median_is_rotation_invariant() raises:
    for k in range(9):
        _assert_exact(
            _median_single[DType.float64](_k9_rotation(k)),
            5.0,
            "K rot" + String(k) + " {NaN,1..8}",
        )


# =============================================================================
# §2 — THE DuckDB-MEASURED CONSTANTS D / E / F / G / H / J / K / L.
# =============================================================================
def test_duckdb_nan_constants() raises:
    # D {1,2,3,NaN} -> 2.5 . Also the reordering {NaN,1,2,3}, which before the
    # fix gave 1.5 while {1,2,3,NaN} gave 2.5 — one multiset, two answers.
    var d1 = List[Float64](); d1.append(1.0); d1.append(2.0); d1.append(3.0)
    d1.append(_nan_f64())
    _assert_exact(_median_single[DType.float64](_f64(d1)), 2.5, "D {1,2,3,NaN}")
    var d2 = List[Float64](); d2.append(_nan_f64()); d2.append(1.0)
    d2.append(2.0); d2.append(3.0)
    _assert_exact(_median_single[DType.float64](_f64(d2)), 2.5, "D' {NaN,1,2,3}")

    # E {1,2,NaN,NaN} -> NaN (mid lands inside the NaN tail).
    var e = List[Float64](); e.append(1.0); e.append(2.0)
    e.append(_nan_f64()); e.append(_nan_f64())
    _assert_nan(_median_single[DType.float64](_f64(e)), "E {1,2,NaN,NaN}")

    # F {1,2,NaN,NaN,NaN} -> NaN (odd n, mid inside the NaN tail).
    var f = List[Float64](); f.append(1.0); f.append(2.0)
    f.append(_nan_f64()); f.append(_nan_f64()); f.append(_nan_f64())
    _assert_nan(_median_single[DType.float64](_f64(f)), "F {1,2,NaN*3}")

    # G {NaN,NaN,NaN} -> NaN (all-NaN group; k == 0).
    var g = List[Float64]()
    g.append(_nan_f64()); g.append(_nan_f64()); g.append(_nan_f64())
    _assert_nan(_median_single[DType.float64](_f64(g)), "G {NaN*3}")

    # H {-inf,inf,NaN} -> inf. NaN sorts ABOVE +inf, so the middle of the
    # 3-element total order is +inf, NOT NaN and NOT -inf.
    var h = List[Float64]()
    h.append(Float64(-1.0) / Float64(0.0))
    h.append(Float64(1.0) / Float64(0.0))
    h.append(_nan_f64())
    _assert_exact(
        _median_single[DType.float64](_f64(h)),
        Float64(1.0) / Float64(0.0),
        "H {-inf,inf,NaN}",
    )

    # J {-inf,inf} -> NaN. No NaN in the INPUT: this is the even-case ARITHMETIC
    # (-inf*0.5 + inf*0.5), and it is the case that discriminates the half-sum
    # spelling from `lo + (hi-lo)*0.5` (which also gives NaN here but gives NaN
    # for {-inf,-inf} where DuckDB gives -inf — pinned in §4).
    var j = List[Float64]()
    j.append(Float64(-1.0) / Float64(0.0))
    j.append(Float64(1.0) / Float64(0.0))
    _assert_nan(_median_single[DType.float64](_f64(j)), "J {-inf,inf}")

    # K {NaN,1..8} -> 5.0.
    _assert_exact(
        _median_single[DType.float64](_k9_rotation(0)), 5.0, "K {NaN,1..8}"
    )

    # L {NaN,5,1,9,3,7,2} -> 5.0 (before the fix: 3.0).
    var l = List[Float64]()
    l.append(_nan_f64()); l.append(5.0); l.append(1.0); l.append(9.0)
    l.append(3.0); l.append(7.0); l.append(2.0)
    _assert_exact(
        _median_single[DType.float64](_f64(l)), 5.0, "L {NaN,5,1,9,3,7,2}"
    )


# =============================================================================
# §3 — CROSS-WORKER ORDER INDEPENDENCE through the real `combine`.
#
# One multiset, many splits into per-worker partial states. Every split must
# finalize to the same value. Before the fix, four splits of {NaN,1..8} gave
# 4.0 / 8.0 / nan / 4.0 — i.e. the answer was a function of the thread count.
# =============================================================================
def test_combine_is_order_independent_with_nan() raises:
    # Two-way splits at every interior boundary, over rot0 AND over rot4 (a
    # different arrival order feeding the same worker geometry).
    for r in range(0, 9, 4):
        var vals = _k9_rotation(r)
        for cut in range(1, 9):
            var cuts = List[Int](); cuts.append(cut)
            _assert_exact(
                _median_split[DType.float64](vals, cuts),
                5.0,
                "K rot" + String(r) + " 2-way split@" + String(cut),
            )

    # Three-way splits — the NaN lands in the first, middle and last partial.
    var v0 = _k9_rotation(0)
    var c_a = List[Int](); c_a.append(1); c_a.append(5)
    _assert_exact(
        _median_split[DType.float64](v0, c_a), 5.0, "K 3-way [1,5) NaN-first"
    )
    var v3 = _k9_rotation(3)
    var c_b = List[Int](); c_b.append(3); c_b.append(7)
    _assert_exact(
        _median_split[DType.float64](v3, c_b), 5.0, "K 3-way [3,7) NaN-middle"
    )
    var v1 = _k9_rotation(1)
    var c_c = List[Int](); c_c.append(2); c_c.append(4)
    _assert_exact(
        _median_split[DType.float64](v1, c_c), 5.0, "K 3-way [2,4) NaN-last"
    )

    # An EMPTY leading partial (a worker that saw no rows for this group) must
    # be an identity for `combine` even on the NaN path.
    var c_d = List[Int](); c_d.append(0); c_d.append(4)
    _assert_exact(
        _median_split[DType.float64](v0, c_d), 5.0, "K 3-way with empty partial"
    )

    # L split two ways at every boundary.
    var l = List[Float64]()
    l.append(_nan_f64()); l.append(5.0); l.append(1.0); l.append(9.0)
    l.append(3.0); l.append(7.0); l.append(2.0)
    var lv = _f64(l)
    for cut in range(1, 7):
        var cuts = List[Int](); cuts.append(cut)
        _assert_exact(
            _median_split[DType.float64](lv, cuts),
            5.0,
            "L 2-way split@" + String(cut),
        )


# =============================================================================
# §4 — THE EVEN-CASE ARITHMETIC. `(lo+hi)/2` overflows; DuckDB's answer does not.
# =============================================================================
def test_even_case_does_not_overflow() raises:
    var big = 1.0e308
    var pair = List[Float64](); pair.append(big); pair.append(big)
    _assert_exact(_median_single[DType.float64](_f64(pair)), big, "{1e308,1e308}")

    var npair = List[Float64](); npair.append(-big); npair.append(-big)
    _assert_exact(
        _median_single[DType.float64](_f64(npair)), -big, "{-1e308,-1e308}"
    )

    var mix = List[Float64](); mix.append(5.0e307); mix.append(1.5e308)
    _assert_exact(
        _median_single[DType.float64](_f64(mix)), 1.0e308, "{5e307,1.5e308}"
    )

    var mix2 = List[Float64](); mix2.append(1.0e308); mix2.append(1.5e308)
    _assert_exact(
        _median_single[DType.float64](_f64(mix2)), 1.25e308, "{1e308,1.5e308}"
    )

    var same = List[Float64](); same.append(8.99e307); same.append(8.99e307)
    _assert_exact(
        _median_single[DType.float64](_f64(same)), 8.99e307, "{8.99e307,8.99e307}"
    )

    # DISCRIMINATOR against `lo + (hi-lo)*0.5`, which gives NaN here.
    var ninf = Float64(-1.0) / Float64(0.0)
    var ni = List[Float64](); ni.append(ninf); ni.append(ninf)
    _assert_exact(
        _median_single[DType.float64](_f64(ni)), ninf, "{-inf,-inf} -> -inf"
    )

    # The 4-element form: the overflowing pair is the MIDDLE pair, so the NaN
    # prescan is not what saves this one.
    var pinf = Float64(1.0) / Float64(0.0)
    var four = List[Float64]()
    four.append(1.0); four.append(big); four.append(big); four.append(pinf)
    _assert_exact(
        _median_single[DType.float64](_f64(four)), big, "{1,1e308,1e308,inf}"
    )

    # The same overflow reached through a NaN-bearing group, i.e. the NEW
    # branch's arithmetic, not the hot path's: {1e308,1e308,NaN} has n=3, k=2,
    # mid=1 -> odd select of buf[1] = 1e308. And {1e308,1e308,NaN,NaN} has n=4,
    # k=2, mid=2 >= k -> NaN.
    var nb = List[Float64]()
    nb.append(big); nb.append(_nan_f64()); nb.append(big)
    _assert_exact(
        _median_single[DType.float64](_f64(nb)), big, "{1e308,NaN,1e308}"
    )
    var nb4 = List[Float64]()
    nb4.append(big); nb4.append(_nan_f64()); nb4.append(big); nb4.append(_nan_f64())
    _assert_nan(
        _median_single[DType.float64](_f64(nb4)), "{1e308,NaN,1e308,NaN}"
    )


# =============================================================================
# §5 — NaN-FREE CONTROL. The shipped fast path must be UNCHANGED.
#
# These are the same expectations the pre-existing kerneldirect pin asserts; if
# the NaN prescan or the arithmetic respelling perturbed the ordinary path, this
# is where it shows.
# =============================================================================
def test_nan_free_control_unchanged() raises:
    var odd = List[Float64](); odd.append(1.0); odd.append(3.0); odd.append(2.0)
    _assert_exact(_median_single[DType.float64](_f64(odd)), 2.0, "ctl [1,3,2]")

    var even = List[Float64]()
    even.append(1.0); even.append(2.0); even.append(3.0); even.append(4.0)
    _assert_exact(
        _median_single[DType.float64](_f64(even)), 2.5, "ctl [1,2,3,4]"
    )

    var one = List[Float64](); one.append(7.0)
    _assert_exact(_median_single[DType.float64](_f64(one)), 7.0, "ctl [7]")

    var dup = List[Float64]()
    dup.append(5.0); dup.append(5.0); dup.append(5.0); dup.append(1.0)
    _assert_exact(_median_single[DType.float64](_f64(dup)), 5.0, "ctl [5,5,5,1]")

    var neg = List[Float64]()
    neg.append(-3.5); neg.append(2.0); neg.append(-1.0); neg.append(0.5)
    _assert_exact(
        _median_single[DType.float64](_f64(neg)), -0.25, "ctl [-3.5,2,-1,0.5]"
    )

    # Empty group -> NaN (DuckDB NULL convention). Unchanged by the fix.
    var empty = List[Scalar[DType.float64]]()
    _assert_nan(_median_single[DType.float64](empty), "ctl empty")

    # A 100-element NaN-free group, split every which way — the prescan must not
    # perturb the common multi-worker path.
    var big = List[Float64]()
    for i in range(100):
        big.append(Float64((i * 37) % 100))
    var bv = _f64(big)
    _assert_exact(_median_single[DType.float64](bv), 49.5, "ctl 100 perm")
    for cut in range(1, 100, 17):
        var cuts = List[Int](); cuts.append(cut)
        _assert_exact(
            _median_split[DType.float64](bv, cuts),
            49.5,
            "ctl 100 perm split@" + String(cut),
        )


# =============================================================================
# §6 — FLOAT32. NaN is reachable on f32 too (`typed_agg_markers.mojo` stamps
# `MedianOp[DType.float32]`), and `MedianOp` is generic over dt, so the f32
# instantiation is a SEPARATE monomorphization that must carry the same fix.
# =============================================================================
def test_float32_nan_total_order() raises:
    var nan32 = Float32(0.0) / Float32(0.0)

    # Rotation invariance on f32, same multiset {NaN,1..8}.
    var base = List[Scalar[DType.float32]]()
    base.append(nan32)
    for v in range(1, 9):
        base.append(Scalar[DType.float32](Float32(v)))
    for k in range(9):
        var rot = List[Scalar[DType.float32]]()
        for i in range(9):
            rot.append(base[(i + k) % 9])
        _assert_exact(
            _median_single[DType.float32](rot),
            5.0,
            "f32 K rot" + String(k),
        )

    # D on f32: {1,2,3,NaN} -> 2.5
    var d = List[Scalar[DType.float32]]()
    d.append(Float32(1.0)); d.append(Float32(2.0)); d.append(Float32(3.0))
    d.append(nan32)
    _assert_exact(_median_single[DType.float32](d), 2.5, "f32 D {1,2,3,NaN}")

    # E on f32: {1,2,NaN,NaN} -> NaN
    var e = List[Scalar[DType.float32]]()
    e.append(Float32(1.0)); e.append(Float32(2.0)); e.append(nan32)
    e.append(nan32)
    _assert_nan(_median_single[DType.float32](e), "f32 E {1,2,NaN,NaN}")

    # Cross-worker split on f32.
    var v = List[Scalar[DType.float32]]()
    for i in range(9):
        v.append(base[i])
    for cut in range(1, 9):
        var cuts = List[Int](); cuts.append(cut)
        _assert_exact(
            _median_split[DType.float32](v, cuts),
            5.0,
            "f32 K 2-way split@" + String(cut),
        )

    # f32 NaN-free control.
    var ctl = List[Scalar[DType.float32]]()
    ctl.append(Float32(10.0)); ctl.append(Float32(20.0))
    ctl.append(Float32(30.0)); ctl.append(Float32(40.0))
    _assert_exact(_median_single[DType.float32](ctl), 25.0, "f32 ctl [10..40]")


# =============================================================================
# §7 — INTEGER CONTROL. NaN is unreachable for an integer dt, so the prescan is
# gated OUT at comptime for these instantiations. This test is what proves the
# comptime gate actually COMPILES and that the integer answers are unchanged.
# =============================================================================
def test_integer_dtypes_unchanged() raises:
    var odd = List[Scalar[DType.int64]]()
    odd.append(Int64(10)); odd.append(Int64(30)); odd.append(Int64(20))
    odd.append(Int64(50)); odd.append(Int64(40))
    _assert_exact(_median_single[DType.int64](odd), 30.0, "i64 odd")

    var even = List[Scalar[DType.int64]]()
    even.append(Int64(10)); even.append(Int64(20))
    even.append(Int64(30)); even.append(Int64(40))
    _assert_exact(_median_single[DType.int64](even), 25.0, "i64 even -> 25.0")
    var cuts = List[Int](); cuts.append(2)
    _assert_exact(
        _median_split[DType.int64](even, cuts), 25.0, "i64 even 2-way split"
    )

    var i32 = List[Scalar[DType.int32]]()
    i32.append(Int32(3)); i32.append(Int32(1)); i32.append(Int32(2))
    _assert_exact(_median_single[DType.int32](i32), 2.0, "i32 odd")

    var i32e = List[Scalar[DType.int32]]()
    i32e.append(Int32(7)); i32e.append(Int32(1))
    _assert_exact(_median_single[DType.int32](i32e), 4.0, "i32 even")

    var empty = List[Scalar[DType.int64]]()
    _assert_nan(_median_single[DType.int64](empty), "i64 empty -> NaN")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
