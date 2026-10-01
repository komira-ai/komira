# =============================================================================
# test_typed_col_count_distinct_nan_total_order.mojo
# =============================================================================
#
# THE DEFECT THIS PINS: `CountDistinctOp[dt].finalize` sorts the
# per-group value buffer with the plain `<` comparator and then counts ADJACENT
# value-runs with `buf[i] != buf[i - 1]`. Both halves break on a NaN-bearing
# float group, and they break INDEPENDENTLY:
#
#   (1) `!=` IS THE WRONG RUN TEST FOR NaN. IEEE says NaN != NaN is TRUE, so
#       every NaN in the buffer past the first element opens a NEW run — a
#       group holding k NaNs is counted as k distinct values where DuckDB
#       counts ONE. This one does not need the sort to misbehave at all; it
#       fires on a perfectly sorted buffer.
#
#   (2) `sort` WITH `<` IS OUTSIDE ITS OWN CONTRACT once a NaN is present.
#       Every comparison against NaN is false, so NaN is neither less than,
#       greater than, nor equivalent to anything, and `<` is therefore not a
#       strict weak ordering. The output is not "NaN somewhere" — it is an
#       arbitrary permutation determined by the INPUT order, which can leave
#       EQUAL NON-NaN VALUES NON-ADJACENT. An adjacent-run counter then counts
#       the same value twice. And the input order of this buffer is row-arrival
#       order per worker, concatenated in worker-merge order by `combine`, so
#       THREAD COUNT AND MORSEL PARTITIONING CHANGE THE ANSWER FOR THE SAME
#       TABLE.
#
# A raw-bits / IEEE-`==` kernel answers:
#
#   * defect (1): {NaN,NaN,NaN} -> 3 where DuckDB says 1. {NaN,1,1,2,NaN} -> 4
#     where DuckDB says 3. f32 identically.
#   * defect (2): the SEVEN rotations of the ONE multiset {NaN,1,1,2,2,3,3},
#     for which DuckDB answers 4 every time, returned
#         rot0=4 rot1=4 rot2=5 rot3=4 rot4=5 rot5=4 rot6=5
#     — and rot2 / rot4 / rot6 each hold a SINGLE NaN, so their over-count is
#     purely a scattered duplicate pair, not defect (1). That spread IS the
#     order-dependence: same multiset, different arrival order, different count.
#
# ⚠ THE MEDIAN-SHAPED PROBE DOES NOT FIND THIS ONE, AND THAT IS WHY BOTH
# ROTATION TESTS ARE HERE. The nine rotations of {NaN,1,2,3,4,5,6,7,8} — the
# multiset that returned nine distinct MEDIANs — returned 9 for all nine here,
# a clean PASS before the fix: with exactly one NaN and no duplicate values
# there is nothing for either defect to bite on. A duplicate-bearing multiset
# is the discriminating fixture, so `_m7_rotation` is not a variation on
# `_k9_rotation`, it is the one that does the work.
#
# NaN REACHABILITY IS NOT HYPOTHETICAL. `typed_agg_markers.mojo` stamps
# `CountDistinctOp` over float32 (`CountDistinctOfF32`) and float64
# (`CountDistinctOfF64`), and the f64/f32 arms of `HashAggOpAgg.update_scalar`
# forward the raw column scalar to `update_scalar` with NO NaN test and NO
# validity test. The float instantiations also CANNOT take the radix-parallel
# dedup shortcut — `IS_DISTINCT_BUFFER` is `_cd_dt_is_int_family[dt]()`, false
# for a float — so a float COUNT(DISTINCT) is served by exactly this `finalize`,
# on every path.
#
# -----------------------------------------------------------------------------
# THE CONTRACT — DuckDB v1.5.3. `count(DISTINCT x)` groups values under
# DuckDB's TOTAL order, in which `'nan' = 'nan'` is TRUE and `-nan` is the same
# value as `nan`; `0.0 = -0.0` is TRUE as well. So ALL NaNs in a group are ONE
# distinct value, and NaN is distinct from every non-NaN value (including
# +inf). SQL NULL is a different thing and is EXCLUDED from the aggregate; NaN
# is NOT NULL.
#
#   K  {NaN,1,2,3,4,5,6,7,8}     -> 9   (and identically for all 9 rotations)
#   A  {NaN,1,1,2,NaN}           -> 3
#   M  {NaN,1,1,2,2,3,3}         -> 4
#   N  {5,5,5,NaN,5,NaN,5}       -> 2
#   P  {NaN,NaN,NaN}             -> 1
#   Q  {1,2,NaN,NaN}             -> 3
#   R  {-inf,inf,NaN}            -> 3
#   S  {0.0,-0.0}                -> 1
#   T  {0.0,-0.0,NaN,-NaN}       -> 2
#   U  {1,1,2,2,3,3}             -> 3   (NaN-free control)
#   V  {}                        -> 0   (DuckDB returns 0, not NULL)
#   W  {NaN,1,NaN,2,NaN,3}       -> 4
#
# -----------------------------------------------------------------------------
# THIS TEST DRIVES THE REAL KERNEL — it imports `CountDistinctOp` /
# `CountDistinctState` from `komira_eval.hash_agg_op_dt` and calls `init` /
# `update_scalar` / `combine` / `take_distinct_buffer_into` / `finalize`.
# Nothing is transcribed; a fix that lives only in a copy of the algorithm
# cannot make this green.
#
# COMPARE MODE = EXACT. COUNT(DISTINCT) is an integer count; an epsilon would
# only hide a wrong answer.
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test. Kernel surface only.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_eval.hash_agg_op_dt import CountDistinctOp, CountDistinctState


# -----------------------------------------------------------------------------
# assertion helper — EXACT integer compare with the got/want in the message.
# -----------------------------------------------------------------------------
def _assert_cd(got: Int64, want: Int64, what: String) raises:
    assert_true(
        got == want,
        what + ": got=" + String(got) + " want=" + String(want),
    )


# -----------------------------------------------------------------------------
# kernel drivers — the REAL `CountDistinctOp` surface. Three shapes, because the
# shipping path has three: one accumulator (single worker), the CONCAT `combine`
# (the legacy serial cross-worker merge), and `take_distinct_buffer_into` (the
# concat-free move-combine that leaves the donor buffers as separate `runs`).
# -----------------------------------------------------------------------------
def _cd_single[dt: DType](imm vals: List[Scalar[dt]]) raises -> Int64:
    var st = CountDistinctOp[dt].init()
    for i in range(len(vals)):
        CountDistinctOp[dt].update_scalar(st, vals[i])
    return CountDistinctOp[dt].finalize(st)


def _cd_split[
    dt: DType
](imm vals: List[Scalar[dt]], imm cuts: List[Int]) raises -> Int64:
    """Feed `vals` to SEVERAL independent per-worker `CountDistinctState`s split
    at `cuts`, then CONCAT-merge them through the real `CountDistinctOp.combine`
    before `finalize`. `cuts` are ascending interior boundaries; the final
    segment runs to the end."""
    var acc = CountDistinctOp[dt].init()
    var start = 0
    for c in range(len(cuts) + 1):
        var end = len(vals) if c == len(cuts) else cuts[c]
        var part = CountDistinctOp[dt].init()
        for i in range(start, end):
            CountDistinctOp[dt].update_scalar(part, vals[i])
        CountDistinctOp[dt].combine(acc, part)
        start = end
    return CountDistinctOp[dt].finalize(acc)


def _cd_split_move[
    dt: DType
](imm vals: List[Scalar[dt]], imm cuts: List[Int]) raises -> Int64:
    """Same split, merged through the CONCAT-FREE `take_distinct_buffer_into` —
    each worker's buffer becomes its OWN `runs` entry, so `finalize` sees the
    values in a different physical layout than the concat path. A correct
    distinct count is identical across all three drivers."""
    var acc = CountDistinctOp[dt].init()
    var start = 0
    for c in range(len(cuts) + 1):
        var end = len(vals) if c == len(cuts) else cuts[c]
        var part = CountDistinctOp[dt].init()
        for i in range(start, end):
            CountDistinctOp[dt].update_scalar(part, vals[i])
        CountDistinctOp[dt].take_distinct_buffer_into(acc, part)
        start = end
    return CountDistinctOp[dt].finalize(acc)


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
    is the SAME multiset, so a correct COUNT(DISTINCT) returns 9 for all nine."""
    var base = List[Scalar[DType.float64]]()
    base.append(Scalar[DType.float64](_nan_f64()))
    for v in range(1, 9):
        base.append(Scalar[DType.float64](Float64(v)))
    var out = List[Scalar[DType.float64]]()
    for i in range(9):
        out.append(base[(i + k) % 9])
    return out^


def _m7_rotation(k: Int) -> List[Scalar[DType.float64]]:
    """Rotation `k` of the DUPLICATE-BEARING multiset {NaN,1,1,2,2,3,3} (n=7,
    DuckDB 4). This is the shape that exposes the SECOND half of the defect:
    a sort outside its contract can leave the two 1s (or the two 2s, or the two
    3s) non-adjacent, and the adjacent-run counter then counts one of them
    twice — an over-count that has nothing to do with the NaN's own run."""
    var base = List[Scalar[DType.float64]]()
    base.append(Scalar[DType.float64](_nan_f64()))
    base.append(Scalar[DType.float64](Float64(1.0)))
    base.append(Scalar[DType.float64](Float64(1.0)))
    base.append(Scalar[DType.float64](Float64(2.0)))
    base.append(Scalar[DType.float64](Float64(2.0)))
    base.append(Scalar[DType.float64](Float64(3.0)))
    base.append(Scalar[DType.float64](Float64(3.0)))
    var out = List[Scalar[DType.float64]]()
    for i in range(7):
        out.append(base[(i + k) % 7])
    return out^


# =============================================================================
# §1 — ROTATION INVARIANCE. The headline: N orderings of ONE multiset must give
# ONE answer. The failure message carries ALL of them, because the interesting
# fact is the SPREAD, not the first mismatch.
# =============================================================================
def test_nan_count_distinct_is_rotation_invariant() raises:
    var got = List[Int64]()
    for k in range(9):
        got.append(_cd_single[DType.float64](_k9_rotation(k)))
    var all = String("")
    for k in range(9):
        all = all + "rot" + String(k) + "=" + String(got[k]) + " "
    for k in range(9):
        assert_true(
            got[k] == Int64(9),
            "K rot" + String(k) + " {NaN,1..8}: got=" + String(got[k])
            + " want=9  [all nine: " + all + "]",
        )


def test_nan_count_distinct_rotation_invariant_with_duplicates() raises:
    var got = List[Int64]()
    for k in range(7):
        got.append(_cd_single[DType.float64](_m7_rotation(k)))
    var all = String("")
    for k in range(7):
        all = all + "rot" + String(k) + "=" + String(got[k]) + " "
    for k in range(7):
        assert_true(
            got[k] == Int64(4),
            "M rot" + String(k) + " {NaN,1,1,2,2,3,3}: got=" + String(got[k])
            + " want=4  [all seven: " + all + "]",
        )


# =============================================================================
# §2 — THE DuckDB CONSTANTS. Each row was measured with the DuckDB CLI.
# =============================================================================
def test_duckdb_nan_count_distinct_constants() raises:
    var nan = _nan_f64()

    # A {NaN,1,1,2,NaN} -> 3
    var a = List[Float64]()
    a.append(nan); a.append(1.0); a.append(1.0); a.append(2.0); a.append(nan)
    _assert_cd(_cd_single[DType.float64](_f64(a)), 3, "A {NaN,1,1,2,NaN}")

    # P {NaN,NaN,NaN} -> 1. All NaNs are ONE distinct value.
    var p = List[Float64]()
    p.append(nan); p.append(nan); p.append(nan)
    _assert_cd(_cd_single[DType.float64](_f64(p)), 1, "P {NaN*3}")

    # A single NaN -> 1.
    var p1 = List[Float64]()
    p1.append(nan)
    _assert_cd(_cd_single[DType.float64](_f64(p1)), 1, "{NaN} -> 1")

    # Two NaNs -> 1. The minimal case of defect (1): `NaN != NaN` is TRUE.
    var p2 = List[Float64]()
    p2.append(nan); p2.append(nan)
    _assert_cd(_cd_single[DType.float64](_f64(p2)), 1, "{NaN,NaN} -> 1")

    # Q {1,2,NaN,NaN} -> 3
    var q = List[Float64]()
    q.append(1.0); q.append(2.0); q.append(nan); q.append(nan)
    _assert_cd(_cd_single[DType.float64](_f64(q)), 3, "Q {1,2,NaN,NaN}")

    # R {-inf,inf,NaN} -> 3. NaN is its own value, distinct from +inf.
    var r = List[Float64]()
    r.append(Float64(-1.0) / Float64(0.0))
    r.append(Float64(1.0) / Float64(0.0))
    r.append(nan)
    _assert_cd(_cd_single[DType.float64](_f64(r)), 3, "R {-inf,inf,NaN}")

    # S {0.0,-0.0} -> 1 (NaN-free; `<` is a strict weak ordering here and the
    # two zeros compare equivalent, so this already passed — it is the control
    # that keeps the fix from "solving" the zeros too).
    var s = List[Float64]()
    s.append(0.0); s.append(-0.0)
    _assert_cd(_cd_single[DType.float64](_f64(s)), 1, "S {0.0,-0.0}")

    # T {0.0,-0.0,NaN,-NaN} -> 2. -NaN is the SAME distinct value as NaN.
    var t = List[Float64]()
    t.append(0.0); t.append(-0.0); t.append(nan); t.append(-nan)
    _assert_cd(_cd_single[DType.float64](_f64(t)), 2, "T {0.0,-0.0,NaN,-NaN}")

    # W {NaN,1,NaN,2,NaN,3} -> 4. NaNs interleaved with the values.
    var w = List[Float64]()
    w.append(nan); w.append(1.0); w.append(nan)
    w.append(2.0); w.append(nan); w.append(3.0)
    _assert_cd(_cd_single[DType.float64](_f64(w)), 4, "W {NaN,1,NaN,2,NaN,3}")

    # N {5,5,5,NaN,5,NaN,5} -> 2. Duplicate-heavy with NaN in the middle.
    var n = List[Float64]()
    n.append(5.0); n.append(5.0); n.append(5.0); n.append(nan)
    n.append(5.0); n.append(nan); n.append(5.0)
    _assert_cd(_cd_single[DType.float64](_f64(n)), 2, "N {5,5,5,NaN,5,NaN,5}")


# =============================================================================
# §3 — CROSS-WORKER ORDER INDEPENDENCE. Through the REAL `combine` and the REAL
# `take_distinct_buffer_into`, at EVERY interior split boundary. A distinct
# count is a property of the multiset; it may not be a function of the worker
# count.
# =============================================================================
def test_combine_is_order_independent_with_nan() raises:
    var k9 = _k9_rotation(0)
    for cut in range(1, 9):
        var cuts = List[Int](); cuts.append(cut)
        _assert_cd(
            _cd_split[DType.float64](k9, cuts), 9,
            "K rot0 2-way concat-split@" + String(cut),
        )
        _assert_cd(
            _cd_split_move[DType.float64](k9, cuts), 9,
            "K rot0 2-way move-split@" + String(cut),
        )

    # 3-way splits over the duplicate-bearing multiset — the shape where a
    # value straddles two workers AND a NaN is present in one of them.
    var m7 = _m7_rotation(0)
    for c0 in range(1, 6):
        for c1 in range(c0 + 1, 7):
            var cuts3 = List[Int](); cuts3.append(c0); cuts3.append(c1)
            _assert_cd(
                _cd_split[DType.float64](m7, cuts3), 4,
                "M rot0 3-way concat-split@" + String(c0) + "," + String(c1),
            )
            _assert_cd(
                _cd_split_move[DType.float64](m7, cuts3), 4,
                "M rot0 3-way move-split@" + String(c0) + "," + String(c1),
            )

    # An EMPTY partial must be the combine identity on both merge shapes.
    var cuts0 = List[Int](); cuts0.append(0)
    _assert_cd(
        _cd_split[DType.float64](k9, cuts0), 9, "K rot0 empty-first concat"
    )
    _assert_cd(
        _cd_split_move[DType.float64](k9, cuts0), 9, "K rot0 empty-first move"
    )

    # All-NaN across workers: three workers, one NaN each -> ONE distinct value.
    var allnan = List[Float64]()
    allnan.append(_nan_f64()); allnan.append(_nan_f64()); allnan.append(_nan_f64())
    var cutsn = List[Int](); cutsn.append(1); cutsn.append(2)
    _assert_cd(
        _cd_split[DType.float64](_f64(allnan), cutsn), 1,
        "{NaN,NaN,NaN} 3-way concat",
    )
    _assert_cd(
        _cd_split_move[DType.float64](_f64(allnan), cutsn), 1,
        "{NaN,NaN,NaN} 3-way move",
    )


# =============================================================================
# §4 — FLOAT32. The other stamped float instantiation (`CountDistinctOfF32`).
# =============================================================================
def test_float32_nan_count_distinct() raises:
    var nan32 = Float32(0.0) / Float32(0.0)

    var k = List[Scalar[DType.float32]]()
    k.append(nan32)
    for v in range(1, 9):
        k.append(Float32(v))
    _assert_cd(_cd_single[DType.float32](k), 9, "f32 K {NaN,1..8}")

    var m = List[Scalar[DType.float32]]()
    m.append(nan32)
    m.append(Float32(1.0)); m.append(Float32(1.0))
    m.append(Float32(2.0)); m.append(Float32(2.0))
    m.append(Float32(3.0)); m.append(Float32(3.0))
    _assert_cd(_cd_single[DType.float32](m), 4, "f32 M {NaN,1,1,2,2,3,3}")

    var p = List[Scalar[DType.float32]]()
    p.append(nan32); p.append(nan32); p.append(nan32)
    _assert_cd(_cd_single[DType.float32](p), 1, "f32 P {NaN*3}")

    for cut in range(1, 9):
        var cuts = List[Int](); cuts.append(cut)
        _assert_cd(
            _cd_split[DType.float32](k, cuts), 9,
            "f32 K 2-way concat-split@" + String(cut),
        )
        _assert_cd(
            _cd_split_move[DType.float32](k, cuts), 9,
            "f32 K 2-way move-split@" + String(cut),
        )

    # f32 NaN-free control.
    var ctl = List[Scalar[DType.float32]]()
    ctl.append(Float32(1.5)); ctl.append(Float32(2.5)); ctl.append(Float32(1.5))
    ctl.append(Float32(3.5)); ctl.append(Float32(2.5))
    _assert_cd(_cd_single[DType.float32](ctl), 3, "f32 ctl [1.5,2.5,1.5,3.5,2.5]")


# =============================================================================
# §5 — NaN-FREE FLOAT CONTROL. This is the HOT PATH, and it must be untouched:
# no NaN in the group means the same sort + adjacent-run count as before.
# =============================================================================
def test_nan_free_float_control_unchanged() raises:
    # U {1,1,2,2,3,3} -> 3
    var u = List[Float64]()
    u.append(1.0); u.append(1.0); u.append(2.0)
    u.append(2.0); u.append(3.0); u.append(3.0)
    _assert_cd(_cd_single[DType.float64](_f64(u)), 3, "U ctl {1,1,2,2,3,3}")

    # V {} -> 0 (DuckDB returns 0 for an empty COUNT(DISTINCT), not NULL).
    var empty = List[Scalar[DType.float64]]()
    _assert_cd(_cd_single[DType.float64](empty), 0, "V ctl empty -> 0")

    # A 100-element NaN-free permutation with 20 distinct values, split every
    # 17 rows across workers on both merge shapes.
    var big = List[Float64]()
    for i in range(100):
        big.append(Float64((i * 37) % 20))
    var cuts = List[Int]()
    var c = 17
    while c < 100:
        cuts.append(c)
        c = c + 17
    _assert_cd(_cd_single[DType.float64](_f64(big)), 20, "ctl big single")
    _assert_cd(_cd_split[DType.float64](_f64(big), cuts), 20, "ctl big concat")
    _assert_cd(
        _cd_split_move[DType.float64](_f64(big), cuts), 20, "ctl big move"
    )


# =============================================================================
# §6 — INTEGER CONTROL. NaN is unreachable for an integer dt, so any NaN prescan
# must be gated OUT at comptime for these instantiations. This test is what
# proves the comptime gate actually COMPILES and that the integer answers — the
# ones the whole clickbench cb04/cb05/cb10/cb13 + tpch q16 corpus rides on — are
# unchanged, INCLUDING the radix-parallel `IS_DISTINCT_BUFFER` hooks.
# =============================================================================
def test_integer_dtypes_unchanged() raises:
    var v = List[Scalar[DType.int64]]()
    v.append(Int64(1)); v.append(Int64(2)); v.append(Int64(2))
    v.append(Int64(3)); v.append(Int64(3)); v.append(Int64(3))
    _assert_cd(_cd_single[DType.int64](v), 3, "i64 [1,2,2,3,3,3]")
    var cuts = List[Int](); cuts.append(3)
    _assert_cd(_cd_split[DType.int64](v, cuts), 3, "i64 2-way concat")
    _assert_cd(_cd_split_move[DType.int64](v, cuts), 3, "i64 2-way move")

    var neg = List[Scalar[DType.int64]]()
    neg.append(Int64(-1)); neg.append(Int64(-1)); neg.append(Int64(0))
    neg.append(Int64(2)); neg.append(Int64(-3))
    _assert_cd(_cd_single[DType.int64](neg), 4, "i64 [-1,-1,0,2,-3]")

    var i32 = List[Scalar[DType.int32]]()
    i32.append(Int32(10)); i32.append(Int32(20)); i32.append(Int32(10))
    i32.append(Int32(30)); i32.append(Int32(20)); i32.append(Int32(10))
    _assert_cd(_cd_single[DType.int32](i32), 3, "i32 [10,20,10,30,20,10]")

    var empty = List[Scalar[DType.int64]]()
    _assert_cd(_cd_single[DType.int64](empty), 0, "i64 empty -> 0")

    # The integer radix-parallel hooks stay reachable and stay correct.
    var st = CountDistinctOp[DType.int64].init()
    for i in range(len(v)):
        CountDistinctOp[DType.int64].update_scalar(st, v[i])
    var widened = CountDistinctOp[DType.int64].distinct_values_i64(st)
    assert_true(
        len(widened) == 6,
        "i64 distinct_values_i64 len: got=" + String(len(widened)) + " want=6",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
