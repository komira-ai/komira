# =============================================================================
# test_typed_col_corr_kerneldirect.mojo
# =============================================================================
#
# CORR in the typed-column hash-agg catalog, so a typed-column corr(x, y) agg
# self-serves instead of falling through to the untyped-column executor. The `CorrF64Agg[dt_x, dt_y, col_x, col_y]` Aggregator
# conformer (the 2-input wrinkle: like `SumProductF64Agg`, CORR conforms DIRECTLY
# to the unified `Aggregator` trait and reads TWO columns per row).
#
# ALGORITHM = WELFORD CO-MOMENT (numerically stable, matches DuckDB to last ULP):
# a bivariate Welford state [n | mean_x | mean_y | M2_x | M2_y | C2]; update =
# online co-moment; combine = Chan parallel-merge (both variances + co-moment,
# associative); finalize = Pearson r = C2 / sqrt(M2_x * M2_y), NaN for n<2 or a
# constant column (zero variance => 0/0 => DuckDB NaN).
#
# THIS TEST drives the agg KERNEL DIRECTLY — it cannot go through update_scalar's
# BatchView column read off the ctx path (that needs a built batch and the full
# plan dispatch tree), so it exercises the moment-recurrence MATH directly via a
# small driver that mirrors `update_scalar`'s body (online co-moment update),
# PLUS the real `combine` and `finalize` kernel methods. This keeps the test
# fast (well under a second) while pinning the load-bearing logic:
#   - the co-moment update recurrence (matched against update_scalar's body),
#   - the real `CorrF64Agg.combine` Chan parallel-merge (the multi-worker shape),
#   - the real `CorrF64Agg.finalize` Pearson + NaN edges,
# all vs a DuckDB corr(x, y) oracle.
#
# DuckDB oracle (the duckdb CLI, corr(x, y)):
#   (1,2),(2,4),(3,6)                 -> 1.0   (perfect positive)
#   (1,6),(2,4),(3,2)                 -> -1.0  (perfect negative)
#   (1,3),(2,1),(3,5),(4,4)           -> 0.529150262212918
#   (5,9)                             -> NaN   (n=1)
#   (2,1),(2,5),(2,9)                 -> NaN   (constant x => zero variance)
#
# COMPARE MODE = TIGHT RELATIVE EPSILON (CORR is a float reduction — a sqrt + a
# division over a Welford/Chan accumulation; the accumulation order/algorithm
# differs from DuckDB's internal aggregate, so a last-ULP divergence is expected).
# We assert abs(a-b)/max(abs(b),1e-300) < 1e-12, the float-aggregate standard.
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test. Kernel surface only.
# =============================================================================

from std.testing import TestSuite, assert_true
from std.math import isnan, sqrt

from komira_eval.builtin_agg_fns_corr import CorrF64Agg, CoMomentRunningState


comptime REL_EPS: Float64 = 1e-12


def _assert_rel_close(got: Float64, want: Float64, what: String) raises:
    var denom = abs(want)
    if denom < 1e-300:
        denom = 1e-300
    var rel = abs(got - want) / denom
    assert_true(
        rel < REL_EPS,
        what + ": got=" + String(got) + " want=" + String(want)
        + " rel=" + String(rel) + " (tol=" + String(REL_EPS) + ")",
    )


# -----------------------------------------------------------------------------
# Co-moment online update — mirrors `CorrF64Agg.update_scalar`'s body EXACTLY
# (dx/dy use the OLD means; m2/c2 use the NEW means). Folds (x, y) into `state`.
# This is the one shared driver the single + 2-partial paths both feed.
# -----------------------------------------------------------------------------
def _feed(mut state: CoMomentRunningState, x: Float64, y: Float64):
    state.n = state.n + 1
    var nf = state.n.cast[DType.float64]()
    var dx = x - state.mean_x
    var dy = y - state.mean_y
    state.mean_x = state.mean_x + dx / nf
    state.mean_y = state.mean_y + dy / nf
    state.m2_x = state.m2_x + dx * (x - state.mean_x)
    state.m2_y = state.m2_y + dy * (y - state.mean_y)
    state.c2 = state.c2 + dx * (y - state.mean_y)


def _fresh() -> CoMomentRunningState:
    return CorrF64Agg[
        DType.float64, DType.float64, 0, 1
    ].init()


# -----------------------------------------------------------------------------
# Single-accumulator drain: feed every pair, then the REAL CorrF64Agg.finalize.
# -----------------------------------------------------------------------------
def _corr_single(xs: List[Float64], ys: List[Float64]) -> Float64:
    var st = _fresh()
    for i in range(len(xs)):
        _feed(st, xs[i], ys[i])
    return CorrF64Agg[DType.float64, DType.float64, 0, 1].finalize(st)


# -----------------------------------------------------------------------------
# Multi-partial drain: split the pairs into two disjoint halves, accumulate each
# in its OWN CoMomentRunningState (the per-worker partial), then merge them via
# the REAL CorrF64Agg.combine (Chan parallel-merge) before the REAL finalize.
# This is the actual multi-worker shape the typed Stage drives — it MUST produce
# the same correlation as the single-accumulator path (and match DuckDB).
# -----------------------------------------------------------------------------
def _corr_two_partials(xs: List[Float64], ys: List[Float64]) -> Float64:
    var mid = len(xs) // 2
    var a = _fresh()
    for i in range(mid):
        _feed(a, xs[i], ys[i])
    var b = _fresh()
    for i in range(mid, len(xs)):
        _feed(b, xs[i], ys[i])
    var agg = CorrF64Agg[DType.float64, DType.float64, 0, 1]()
    agg.combine(a, b)
    return CorrF64Agg[DType.float64, DType.float64, 0, 1].finalize(a)


# -----------------------------------------------------------------------------
# §1 — perfect positive / negative correlation, vs DuckDB. Single + Chan-merge.
# -----------------------------------------------------------------------------
def test_perfect_correlation_matches_duckdb() raises:
    # (1,2),(2,4),(3,6) -> 1.0
    var x1 = List[Float64](); x1.append(1.0); x1.append(2.0); x1.append(3.0)
    var y1 = List[Float64](); y1.append(2.0); y1.append(4.0); y1.append(6.0)
    _assert_rel_close(_corr_single(x1, y1), 1.0, "corr perfect-pos")
    _assert_rel_close(
        _corr_two_partials(x1, y1), 1.0, "corr perfect-pos (2-partial Chan-merge)"
    )

    # (1,6),(2,4),(3,2) -> -1.0
    var x2 = List[Float64](); x2.append(1.0); x2.append(2.0); x2.append(3.0)
    var y2 = List[Float64](); y2.append(6.0); y2.append(4.0); y2.append(2.0)
    _assert_rel_close(_corr_single(x2, y2), -1.0, "corr perfect-neg")
    _assert_rel_close(
        _corr_two_partials(x2, y2), -1.0, "corr perfect-neg (2-partial Chan-merge)"
    )


# -----------------------------------------------------------------------------
# §2 — partial correlation (the non-trivial value), vs DuckDB.
# -----------------------------------------------------------------------------
def test_partial_correlation_matches_duckdb() raises:
    # (1,3),(2,1),(3,5),(4,4) -> 0.529150262212918
    var xs = List[Float64]()
    xs.append(1.0); xs.append(2.0); xs.append(3.0); xs.append(4.0)
    var ys = List[Float64]()
    ys.append(3.0); ys.append(1.0); ys.append(5.0); ys.append(4.0)
    _assert_rel_close(
        _corr_single(xs, ys), 0.529150262212918, "corr partial"
    )
    _assert_rel_close(
        _corr_two_partials(xs, ys), 0.529150262212918,
        "corr partial (2-partial Chan-merge)",
    )


# -----------------------------------------------------------------------------
# §3 — NaN edges: n=1 (no covariance) and a constant column (zero variance).
# DuckDB returns NaN for both; finalize returns NaN (0/0).
# -----------------------------------------------------------------------------
def test_nan_edges_match_duckdb() raises:
    # n=1 -> NaN
    var x1 = List[Float64](); x1.append(5.0)
    var y1 = List[Float64](); y1.append(9.0)
    assert_true(isnan(_corr_single(x1, y1)), "corr n=1 -> NaN")

    # constant x (zero variance) -> NaN: (2,1),(2,5),(2,9)
    var xc = List[Float64](); xc.append(2.0); xc.append(2.0); xc.append(2.0)
    var yc = List[Float64](); yc.append(1.0); yc.append(5.0); yc.append(9.0)
    assert_true(isnan(_corr_single(xc, yc)), "corr constant-x -> NaN")

    # empty -> n=0 -> NaN
    var xe = List[Float64](); var ye = List[Float64]()
    assert_true(isnan(_corr_single(xe, ye)), "corr empty -> NaN")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
