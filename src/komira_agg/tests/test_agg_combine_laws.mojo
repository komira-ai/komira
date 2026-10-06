# =============================================================================
# test_agg_combine_laws.mojo — seeded combine laws for every aggregate state
# =============================================================================
#
# WHAT THIS PINS. A grouped aggregate runs as N workers, each folding the rows
# it was handed into a partial state, and the partials are then joined with
# `combine` (the `HashAggOpDt` ops) or `merge` (the `AggFn` cells). The answer
# must not depend on how the rows were cut into morsels, how many workers there
# were, or (for an order-free aggregate) in which order the partials arrived.
# Written as laws, for a serial fold S over rows r[0..n):
#
#   L1 split, left fold:   combine(combine(fold(p0), fold(p1)), fold(p2)) == S
#   L2 split, right fold:  combine(fold(p0), combine(fold(p1), fold(p2))) == S
#   L3 split, reversed:    combine(fold(p2), ..., fold(p0))               == S
#   L4 identity:           combine(s, init()) == s == combine(init(), s)
#   L5 row permutation:    fold(shuffle(r))                               == S
#
# L1, L2 and L4 hold for every aggregate, FIRST and LAST included (associative,
# with an identity). L3 and L5 hold only for the order-free ones; FIRST and
# LAST are order-dependent by definition, so they are checked on L1, L2, L4.
#
# The inputs are seeded (splitmix64; the seed is in every failure message, so
# a red run replays exactly) and drawn from a pool that includes the values
# that break naive folds: NaN with both sign bits, +0.0 and -0.0, +inf and
# -inf, and the int64 extremes. Finite floats are multiples of 1/8 below 1000
# in magnitude, so every partial sum is exact in float64 and SUM / AVG must
# agree bit for bit across cuts, not only approximately. STDDEV_SAMP and
# VAR_SAMP (Welford update, Chan merge) are compared with a relative tolerance
# of 1e-9 on finite inputs and must be NaN in every cut when a NaN is present.
#
# Float equality is the DuckDB quotient order the MIN/MAX kernels use: every
# NaN is one value, +0.0 and -0.0 are one value, everything else is IEEE `==`.
#
# NULLs never reach these states: `AggFnAcc.update_record_batch` drops a NULL
# row before it calls the cell (PROPAGATE). The NULL laws are therefore tested
# where the filter lives, in
# `komira_op_agg_state/tests/test_agg_fn_acc_null_partition_laws.mojo`.
#
# Everything here drives the real kernels (`init` / `update_scalar` /
# `combine` / `merge` / `finalize`); nothing is transcribed.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_udf.agg_fn import AggFn
from komira_agg.hash_agg_op_dt import (
    HashAggOpDt,
    SumOp,
    CountOp,
    MinOp,
    MaxOp,
    AvgOp,
    StddevSampOp,
    VarSampOp,
    FirstOp,
    LastOp,
)
from komira_agg.builtin_agg_fns_sum import SumF64, SumI64
from komira_agg.builtin_agg_fns_count import CountF64
from komira_agg.builtin_agg_fns_avg import AvgF64
from komira_agg.builtin_agg_fns_minmax import MinF64, MaxF64, MinI64, MaxI64
from komira_agg.builtin_agg_fns_stddev import StddevSampF64, VarSampF64
from komira_agg.builtin_agg_fns_firstlast import FirstF64, LastF64


comptime N_CASES = 60
"""Seeded cases per aggregate. Each case is one input of 0..48 rows and five
random cuts of it, so one aggregate sees 300 partitions."""

comptime N_CUTS = 5


# =============================================================================
# splitmix64 — deterministic and seedable, so a failure replays exactly.
# =============================================================================


struct Rng(Movable, Deinitable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var z = self.state
        z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> UInt64(31))

    def next_int(mut self, n: Int) -> Int:
        """Uniform in [0, n)."""
        if n <= 1:
            return 0
        return Int(self.next_u64() % UInt64(n))


# =============================================================================
# Input pools
# =============================================================================


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _inf() -> Float64:
    return Float64(1.0) / Float64(0.0)


def _f64_finite(mut rng: Rng) -> Float64:
    """A multiple of 1/8 in (-1000, 1000): sums of up to 48 of these are exact
    in float64, so a cut can never change a SUM by rounding."""
    return Float64(rng.next_int(16001) - 8000) / Float64(8.0)


def _f64_special(mut rng: Rng) -> Float64:
    var k = rng.next_int(6)
    if k == 0:
        return _nan()
    if k == 1:
        return -_nan()
    if k == 2:
        return Float64(0.0)
    if k == 3:
        return Float64(0.0) * Float64(-1.0)
    if k == 4:
        return _inf()
    return -_inf()


def _gen_f64(mut rng: Rng, with_specials: Bool, nan_only: Bool) -> List[Float64]:
    """0..48 rows. With `with_specials`, about one row in five is drawn from
    {NaN, -NaN, +0, -0, +inf, -inf}; with `nan_only`, the specials are NaN."""
    var n = rng.next_int(49)
    var out = List[Float64]()
    for _ in range(n):
        if with_specials and rng.next_int(5) == 0:
            if nan_only:
                out.append(_nan() if rng.next_int(2) == 0 else -_nan())
            else:
                out.append(_f64_special(rng))
        else:
            out.append(_f64_finite(rng))
    return out^


def _gen_i64(mut rng: Rng) -> List[Int64]:
    """0..48 rows; mostly within +-2^40, with the int64 extremes mixed in so a
    SUM total leaves the int64 range (the int128 state must keep it exact)."""
    var n = rng.next_int(49)
    var out = List[Int64]()
    for _ in range(n):
        var k = rng.next_int(12)
        if k == 0:
            out.append(Int64.MAX)
        elif k == 1:
            out.append(Int64.MIN)
        else:
            var mag = (rng.next_u64() >> UInt64(24)).cast[DType.int64]()  # < 2^40
            out.append(mag if rng.next_int(2) == 0 else -mag)
    return out^


def _to_f32(imm v: List[Float64]) -> List[Float32]:
    var out = List[Float32]()
    for i in range(len(v)):
        out.append(v[i].cast[DType.float32]())
    return out^


# =============================================================================
# Cuts and permutations
# =============================================================================


def _cuts(mut rng: Rng, n: Int) -> List[Int]:
    """Bounds [0 = b0 <= b1 <= ... <= bk = n] of k in 1..5 contiguous pieces.
    Pieces may be empty: an empty worker partial is the identity and must
    behave as one."""
    var k = 1 + rng.next_int(5)
    var inner = List[Int]()
    for _ in range(k - 1):
        inner.append(rng.next_int(n + 1))
    # Insertion sort: k is at most 5.
    for i in range(1, len(inner)):
        var j = i
        while j > 0 and inner[j - 1] > inner[j]:
            var t = inner[j]
            inner[j] = inner[j - 1]
            inner[j - 1] = t
            j -= 1
    var out = List[Int]()
    out.append(0)
    for i in range(len(inner)):
        out.append(inner[i])
    out.append(n)
    return out^


def _perm(mut rng: Rng, n: Int) -> List[Int]:
    """A Fisher-Yates permutation of [0, n)."""
    var p = List[Int]()
    for i in range(n):
        p.append(i)
    var i = n - 1
    while i > 0:
        var j = rng.next_int(i + 1)
        var t = p[i]
        p[i] = p[j]
        p[j] = t
        i -= 1
    return p^


def _cuts_str(imm b: List[Int]) -> String:
    var s = String("[")
    for i in range(len(b)):
        if i > 0:
            s += ","
        s += String(b[i])
    return s + "]"


# =============================================================================
# Equality: the quotient order for floats, exact for integers.
# =============================================================================


def _same[dt: DType](a: Scalar[dt], b: Scalar[dt], rel_tol: Float64) -> Bool:
    comptime if dt.is_floating_point():
        var x = a.cast[DType.float64]()
        var y = b.cast[DType.float64]()
        if x != x:
            return y != y
        if y != y:
            return False
        if x == y:
            return True
        if rel_tol == 0.0:
            return False
        var scale = max(max(abs(x), abs(y)), Float64(1.0))
        return abs(x - y) <= rel_tol * scale
    else:
        return a == b


# =============================================================================
# The HashAggOpDt driver (static init / update_scalar / combine / finalize)
# =============================================================================


def _op_fold[
    dt: DType, Op: HashAggOpDt
](imm vals: List[Scalar[dt]], lo: Int, hi: Int) -> Op.StateTy:
    var s = Op.init()
    for i in range(lo, hi):
        Op.update_scalar(s, vals[i].cast[Op.DT]())
    return s^


def _op_check[
    dt: DType, Op: HashAggOpDt, order_free: Bool
](
    name: String,
    imm vals: List[Scalar[dt]],
    mut rng: Rng,
    seed: UInt64,
    rel_tol: Float64,
) raises:
    var n = len(vals)
    var serial = _op_fold[dt, Op](vals, 0, n)
    var want = Op.finalize(serial)
    var ctx = name + " seed=" + String(seed) + " n=" + String(n)

    # L4 — identity on both sides.
    var right_id = serial.copy()
    Op.combine(right_id, Op.init())
    var left_id = Op.init()
    Op.combine(left_id, serial)
    assert_true(
        _same[Op.OUT_DT](Op.finalize(right_id), want, 0.0)
        and _same[Op.OUT_DT](Op.finalize(left_id), want, 0.0),
        ctx + ": combine with init() must be the identity; serial="
        + String(want) + " s+init=" + String(Op.finalize(right_id))
        + " init+s=" + String(Op.finalize(left_id)),
    )

    for _ in range(N_CUTS):
        var b = _cuts(rng, n)
        var k = len(b) - 1
        var parts = List[Op.StateTy]()
        for j in range(k):
            parts.append(_op_fold[dt, Op](vals, b[j], b[j + 1]))

        # L1 — left fold, in row order.
        var left = parts[0].copy()
        for j in range(1, k):
            Op.combine(left, parts[j])
        var got_left = Op.finalize(left)
        assert_true(
            _same[Op.OUT_DT](got_left, want, rel_tol),
            ctx + " cuts=" + _cuts_str(b) + ": left-fold combine="
            + String(got_left) + " but serial=" + String(want),
        )

        # L2 — right fold, in row order (a different association).
        var right = parts[k - 1].copy()
        var j2 = k - 2
        while j2 >= 0:
            var t = parts[j2].copy()
            Op.combine(t, right)
            right = t^
            j2 -= 1
        var got_right = Op.finalize(right)
        assert_true(
            _same[Op.OUT_DT](got_right, want, rel_tol),
            ctx + " cuts=" + _cuts_str(b) + ": right-fold combine="
            + String(got_right) + " but serial=" + String(want),
        )

        comptime if order_free:
            # L3 — partials arriving in reverse order.
            var rev = parts[k - 1].copy()
            var j3 = k - 2
            while j3 >= 0:
                Op.combine(rev, parts[j3])
                j3 -= 1
            var got_rev = Op.finalize(rev)
            assert_true(
                _same[Op.OUT_DT](got_rev, want, rel_tol),
                ctx + " cuts=" + _cuts_str(b) + ": reversed combine="
                + String(got_rev) + " but serial=" + String(want),
            )

    comptime if order_free:
        # L5 — the same multiset of rows in another arrival order.
        var p = _perm(rng, n)
        var shuffled = List[Scalar[dt]]()
        for i in range(n):
            shuffled.append(vals[p[i]])
        var got_perm = Op.finalize(_op_fold[dt, Op](shuffled, 0, n))
        assert_true(
            _same[Op.OUT_DT](got_perm, want, rel_tol),
            ctx + ": a permutation of the rows gave " + String(got_perm)
            + " but serial=" + String(want),
        )


def _op_laws_f64[
    Op: HashAggOpDt, order_free: Bool
](name: String, base_seed: UInt64, specials: Bool, nan_only: Bool, rel_tol: Float64) raises:
    for c in range(N_CASES):
        var seed = base_seed + UInt64(c)
        var rng = Rng(seed)
        var v = _gen_f64(rng, specials, nan_only)
        _op_check[DType.float64, Op, order_free](name, v, rng, seed, rel_tol)


def _op_laws_f32[Op: HashAggOpDt, order_free: Bool](name: String, base_seed: UInt64) raises:
    for c in range(N_CASES):
        var seed = base_seed + UInt64(c)
        var rng = Rng(seed)
        var v = _to_f32(_gen_f64(rng, True, False))
        _op_check[DType.float32, Op, order_free](name, v, rng, seed, 0.0)


def _op_laws_i64[Op: HashAggOpDt, order_free: Bool](name: String, base_seed: UInt64) raises:
    for c in range(N_CASES):
        var seed = base_seed + UInt64(c)
        var rng = Rng(seed)
        var v = _gen_i64(rng)
        _op_check[DType.int64, Op, order_free](name, v, rng, seed, 0.0)


# =============================================================================
# The AggFn cell driver (instance init / update_scalar / merge / finalize)
# =============================================================================


def _cell_fold[
    dt: DType, F: AggFn
](f: F, imm vals: List[Scalar[dt]], lo: Int, hi: Int) -> F.State:
    var s = f.init()
    for i in range(lo, hi):
        var v = vals[i]
        f.update_scalar(s, v)
    return s^


def _cell_check[
    dt: DType, F: AggFn, order_free: Bool
](
    f: F,
    name: String,
    imm vals: List[Scalar[dt]],
    mut rng: Rng,
    seed: UInt64,
    rel_tol: Float64,
) raises:
    var n = len(vals)
    var serial = _cell_fold[dt, F](f, vals, 0, n)
    var want = f.finalize(serial)
    var ctx = name + " seed=" + String(seed) + " n=" + String(n)

    # L4 — identity on both sides.
    var r_id = f.merge(serial, f.init())
    var l_id = f.merge(f.init(), serial)
    assert_true(
        _same[F.OutType](f.finalize(r_id), want, 0.0)
        and _same[F.OutType](f.finalize(l_id), want, 0.0),
        ctx + ": merge with init() must be the identity; serial="
        + String(want) + " s+init=" + String(f.finalize(r_id))
        + " init+s=" + String(f.finalize(l_id)),
    )

    for _ in range(N_CUTS):
        var b = _cuts(rng, n)
        var k = len(b) - 1
        var parts = List[F.State]()
        for j in range(k):
            parts.append(_cell_fold[dt, F](f, vals, b[j], b[j + 1]))

        # L1 — left fold, in row order.
        var left = parts[0].copy()
        for j in range(1, k):
            left = f.merge(left, parts[j])
        var got_left = f.finalize(left)
        assert_true(
            _same[F.OutType](got_left, want, rel_tol),
            ctx + " cuts=" + _cuts_str(b) + ": left-fold merge="
            + String(got_left) + " but serial=" + String(want),
        )

        # L2 — right fold, in row order.
        var right = parts[k - 1].copy()
        var j2 = k - 2
        while j2 >= 0:
            right = f.merge(parts[j2], right)
            j2 -= 1
        var got_right = f.finalize(right)
        assert_true(
            _same[F.OutType](got_right, want, rel_tol),
            ctx + " cuts=" + _cuts_str(b) + ": right-fold merge="
            + String(got_right) + " but serial=" + String(want),
        )

        comptime if order_free:
            # L3 — partials arriving in reverse order.
            var rev = parts[k - 1].copy()
            var j3 = k - 2
            while j3 >= 0:
                rev = f.merge(rev, parts[j3])
                j3 -= 1
            var got_rev = f.finalize(rev)
            assert_true(
                _same[F.OutType](got_rev, want, rel_tol),
                ctx + " cuts=" + _cuts_str(b) + ": reversed merge="
                + String(got_rev) + " but serial=" + String(want),
            )

    comptime if order_free:
        # L5 — another arrival order of the same rows.
        var p = _perm(rng, n)
        var shuffled = List[Scalar[dt]]()
        for i in range(n):
            shuffled.append(vals[p[i]])
        var got_perm = f.finalize(_cell_fold[dt, F](f, shuffled, 0, n))
        assert_true(
            _same[F.OutType](got_perm, want, rel_tol),
            ctx + ": a permutation of the rows gave " + String(got_perm)
            + " but serial=" + String(want),
        )


def _cell_laws_f64[
    F: AggFn, order_free: Bool
](f: F, name: String, base_seed: UInt64, specials: Bool, nan_only: Bool, rel_tol: Float64) raises:
    for c in range(N_CASES):
        var seed = base_seed + UInt64(c)
        var rng = Rng(seed)
        var v = _gen_f64(rng, specials, nan_only)
        _cell_check[DType.float64, F, order_free](f, name, v, rng, seed, rel_tol)


def _cell_laws_i64[F: AggFn, order_free: Bool](f: F, name: String, base_seed: UInt64) raises:
    for c in range(N_CASES):
        var seed = base_seed + UInt64(c)
        var rng = Rng(seed)
        var v = _gen_i64(rng)
        _cell_check[DType.int64, F, order_free](f, name, v, rng, seed, 0.0)


# =============================================================================
# §1 — HashAggOpDt ops over Float64 with NaN, -NaN, +-0, +-inf
# =============================================================================


def test_op_sum_f64_laws() raises:
    _op_laws_f64[SumOp[DType.float64], True]("SumOp[f64]", 1000, True, False, 0.0)


def test_op_count_f64_laws() raises:
    _op_laws_f64[CountOp[DType.float64], True]("CountOp[f64]", 2000, True, False, 0.0)


def test_op_min_f64_laws() raises:
    _op_laws_f64[MinOp[DType.float64], True]("MinOp[f64]", 3000, True, False, 0.0)


def test_op_max_f64_laws() raises:
    _op_laws_f64[MaxOp[DType.float64], True]("MaxOp[f64]", 4000, True, False, 0.0)


def test_op_avg_f64_laws() raises:
    _op_laws_f64[AvgOp[DType.float64], True]("AvgOp[f64]", 5000, True, False, 0.0)


def test_op_first_f64_laws() raises:
    _op_laws_f64[FirstOp[DType.float64], False]("FirstOp[f64]", 6000, True, False, 0.0)


def test_op_last_f64_laws() raises:
    _op_laws_f64[LastOp[DType.float64], False]("LastOp[f64]", 7000, True, False, 0.0)


def test_op_stddev_var_f64_laws_finite() raises:
    """Welford update + Chan merge: equal to 1e-9 relative on finite rows."""
    _op_laws_f64[StddevSampOp[DType.float64], True](
        "StddevSampOp[f64]", 8000, False, False, 1e-9
    )
    _op_laws_f64[VarSampOp[DType.float64], True](
        "VarSampOp[f64]", 8500, False, False, 1e-9
    )


def test_op_stddev_var_f64_laws_nan() raises:
    """A NaN row makes the moment NaN in every cut (no tolerance needed)."""
    _op_laws_f64[StddevSampOp[DType.float64], True](
        "StddevSampOp[f64]+NaN", 9000, True, True, 1e-9
    )
    _op_laws_f64[VarSampOp[DType.float64], True](
        "VarSampOp[f64]+NaN", 9500, True, True, 1e-9
    )


# =============================================================================
# §2 — Float32 input (widened to a Float64 state) and Int64 input (int128 or
# int64 state, compared exactly)
# =============================================================================


def test_op_f32_laws() raises:
    _op_laws_f32[SumOp[DType.float32], True]("SumOp[f32]", 10000)
    _op_laws_f32[MinOp[DType.float32], True]("MinOp[f32]", 11000)
    _op_laws_f32[MaxOp[DType.float32], True]("MaxOp[f32]", 12000)


def test_op_i64_laws() raises:
    _op_laws_i64[SumOp[DType.int64], True]("SumOp[i64]", 13000)
    _op_laws_i64[CountOp[DType.int64], True]("CountOp[i64]", 14000)
    _op_laws_i64[MinOp[DType.int64], True]("MinOp[i64]", 15000)
    _op_laws_i64[MaxOp[DType.int64], True]("MaxOp[i64]", 16000)
    _op_laws_i64[AvgOp[DType.int64], True]("AvgOp[i64]", 17000)
    _op_laws_i64[FirstOp[DType.int64], False]("FirstOp[i64]", 18000)
    _op_laws_i64[LastOp[DType.int64], False]("LastOp[i64]", 19000)


# =============================================================================
# §3 — the AggFn cells (the user-facing aggregate surface `AggFnAcc` drives)
# =============================================================================


def test_cell_f64_laws() raises:
    _cell_laws_f64[SumF64, True](SumF64(), "SumF64", 20000, True, False, 0.0)
    _cell_laws_f64[CountF64, True](CountF64(), "CountF64", 21000, True, False, 0.0)
    _cell_laws_f64[AvgF64, True](AvgF64(), "AvgF64", 22000, True, False, 0.0)
    _cell_laws_f64[MinF64, True](MinF64(), "MinF64", 23000, True, False, 0.0)
    _cell_laws_f64[MaxF64, True](MaxF64(), "MaxF64", 24000, True, False, 0.0)
    _cell_laws_f64[FirstF64, False](FirstF64(), "FirstF64", 25000, True, False, 0.0)
    _cell_laws_f64[LastF64, False](LastF64(), "LastF64", 26000, True, False, 0.0)


def test_cell_stddev_var_f64_laws() raises:
    _cell_laws_f64[StddevSampF64, True](
        StddevSampF64(), "StddevSampF64", 27000, False, False, 1e-9
    )
    _cell_laws_f64[VarSampF64, True](
        VarSampF64(), "VarSampF64", 28000, False, False, 1e-9
    )
    _cell_laws_f64[StddevSampF64, True](
        StddevSampF64(), "StddevSampF64+NaN", 29000, True, True, 1e-9
    )


def test_cell_i64_laws() raises:
    _cell_laws_i64[MinI64, True](MinI64(), "MinI64", 30000)
    _cell_laws_i64[MaxI64, True](MaxI64(), "MaxI64", 31000)


# =============================================================================
# §4 — CONTROL ON THE HARNESS: the laws separate a known-bad fold.
# =============================================================================


def _bare_lt_min(imm v: List[Float64], lo: Int, hi: Int) -> Float64:
    """MIN folded with a bare IEEE `<`, the shape the quotient-order fix
    replaced. Once a NaN is held, nothing displaces it."""
    var seen = False
    var m = Float64(0.0)
    for i in range(lo, hi):
        if not seen or v[i] < m:
            m = v[i]
            seen = True
    return m


def test_harness_separates_a_bare_lt_min() raises:
    """Over {NaN, 5, 2} cut as [0,1) + [1,3), a bare-`<` MIN answers NaN
    serially and 2.0 when the partials are merged in reverse order (L3). If
    `_same` called those equal, L3 could not catch the defect it exists for."""
    var rows: List[Float64] = [_nan(), Float64(5.0), Float64(2.0)]
    var serial = _bare_lt_min(rows, 0, 3)
    var a = _bare_lt_min(rows, 0, 1)
    var b = _bare_lt_min(rows, 1, 3)
    var reverse = a if a < b else b
    assert_true(
        not _same[DType.float64](serial, reverse, 0.0),
        String("a bare-< MIN must break L3: serial=") + String(serial)
        + " reverse=" + String(reverse),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
