# =============================================================================
# test_typed_col_median_kerneldirect.mojo
# =============================================================================
#
# MEDIAN in the typed-column hash-agg catalog: the `MedianOp[dt]` catalog
# conformer lets the typed-column scalar + grouped agg paths self-serve MEDIAN
# instead of falling through to the untyped-column executor.
#
# MEDIAN is the SECOND variable-size per-group state in the catalog (after
# COUNT_DISTINCT): state is a heap-owning `MedianState[dt]` (a `List[Scalar[dt]]`
# value buffer). The typed-COLUMN catalog hosts it cleanly (the per-group state
# lives in `AggSlot[A].states: List[A.StateTy]`, a typed Mojo `List` not a
# byte-slab — slab-safe), with a CONCAT cross-worker combine. COUNT_DISTINCT
# already proved the variable-size-buffer pattern; MEDIAN follows directly. (This
# is the OPPOSITE of the ROW substrate, whose fixed-extra-cell byte-slab cannot
# host a variable-size value buffer.)
#
# ALGORITHM = buffer + sort + interpolated percentile select at finalize: update
# appends; combine concatenates donor buffers (associative — finalize sorts);
# finalize sorts + picks the 50th percentile with LINEAR INTERPOLATION (DuckDB
# median == quantile_cont(0.5)): odd n -> middle element; even n -> mean of the
# two middle elements. Output is ALWAYS Float64. Empty -> NaN (DuckDB NULL).
#
# THIS TEST drives the agg KERNEL DIRECTLY (`MedianOp[dt]` init/update_scalar/
# finalize/combine) over hand-built value lists — without compiling the full
# ctx.materialize dispatch tree. It exercises BOTH the single-
# accumulator hot path AND the multi-partial CONCAT `combine` path (the
# multi-worker shape), and compares against a DuckDB median(x) oracle.
#
# DuckDB oracle (the duckdb CLI, median(x)):
#   float64 [1,3,2]            -> 2.0   (odd: middle of sorted [1,2,3])
#   float64 [1,2,3,4]          -> 2.5   (even: interpolate (2+3)/2)
#   int64   [10,30,20,50,40]   -> 30.0  (odd)
#   int64   [10,20,30,40]      -> 25.0  (even: (20+30)/2 — integer input, float out)
#   float64 [7]                -> 7.0   (single)
#   float64 [5,5,5,1]          -> 5.0   (even, sorted [1,5,5,5] -> (5+5)/2)
#
# COMPARE MODE = TIGHT RELATIVE EPSILON. MEDIAN's select + interpolation is exact
# for these inputs, but we use the float-aggregate relative-epsilon standard for
# consistency with the sibling stddev/corr pins (abs(a-b)/max(abs(b),1e-300) <
# 1e-12); an exact compare would also pass for these cases.
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test. Kernel surface only.
# =============================================================================

from std.testing import TestSuite, assert_true
from std.math import isnan

from komira_agg.hash_agg_op_dt import MedianOp, MedianState


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
# Single-accumulator drain: init -> update_scalar over the whole list -> finalize.
# -----------------------------------------------------------------------------
def _median_single[dt: DType](vals: List[Scalar[dt]]) -> Float64:
    var st = MedianOp[dt].init()
    for i in range(len(vals)):
        MedianOp[dt].update_scalar(st, vals[i])
    return MedianOp[dt].finalize(st)


# -----------------------------------------------------------------------------
# Multi-partial drain: split into two disjoint halves, accumulate each in its OWN
# MedianState (the per-worker partial), then CONCAT-merge via `combine` before
# finalize. The actual multi-worker shape — it MUST produce the same median as
# the single-accumulator path (and match DuckDB) since the per-worker halves are
# UNSORTED and only the merged-then-sorted buffer is correct.
# -----------------------------------------------------------------------------
def _median_two_partials[dt: DType](vals: List[Scalar[dt]]) -> Float64:
    var mid = len(vals) // 2
    var a = MedianOp[dt].init()
    for i in range(mid):
        MedianOp[dt].update_scalar(a, vals[i])
    var b = MedianOp[dt].init()
    for i in range(mid, len(vals)):
        MedianOp[dt].update_scalar(b, vals[i])
    MedianOp[dt].combine(a, b)
    return MedianOp[dt].finalize(a)


# -----------------------------------------------------------------------------
# §1 — FLOAT64 input MEDIAN, odd + even count, vs DuckDB. Single + CONCAT-merge.
# -----------------------------------------------------------------------------
def test_float64_median_matches_duckdb() raises:
    # [1,3,2] (unsorted) -> 2.0 (odd)
    var odd = List[Scalar[DType.float64]]()
    odd.append(1.0); odd.append(3.0); odd.append(2.0)
    _assert_rel_close(_median_single[DType.float64](odd), 2.0, "f64 odd [1,3,2]")
    _assert_rel_close(
        _median_two_partials[DType.float64](odd), 2.0,
        "f64 odd [1,3,2] (2-partial CONCAT)",
    )

    # [1,2,3,4] -> 2.5 (even: interpolate)
    var even = List[Scalar[DType.float64]]()
    even.append(1.0); even.append(2.0); even.append(3.0); even.append(4.0)
    _assert_rel_close(
        _median_single[DType.float64](even), 2.5, "f64 even [1,2,3,4]"
    )
    _assert_rel_close(
        _median_two_partials[DType.float64](even), 2.5,
        "f64 even [1,2,3,4] (2-partial CONCAT)",
    )

    # [7] -> 7.0 (single)
    var one = List[Scalar[DType.float64]](); one.append(7.0)
    _assert_rel_close(_median_single[DType.float64](one), 7.0, "f64 single [7]")

    # [5,5,5,1] -> 5.0 (even, sorted [1,5,5,5] -> (5+5)/2)
    var dup = List[Scalar[DType.float64]]()
    dup.append(5.0); dup.append(5.0); dup.append(5.0); dup.append(1.0)
    _assert_rel_close(
        _median_single[DType.float64](dup), 5.0, "f64 dup [5,5,5,1]"
    )
    _assert_rel_close(
        _median_two_partials[DType.float64](dup), 5.0,
        "f64 dup [5,5,5,1] (2-partial CONCAT)",
    )


# -----------------------------------------------------------------------------
# §2 — INT64 input MEDIAN (DType-generic; even-count integer median is float),
# odd + even, vs DuckDB. The half-integer even median is the load-bearing case:
# median([10,20,30,40]) = 25.0 (NOT 20 or 30) — proves the Float64 interpolation.
# -----------------------------------------------------------------------------
def test_int64_median_matches_duckdb() raises:
    # [10,30,20,50,40] -> 30.0 (odd)
    var odd = List[Scalar[DType.int64]]()
    odd.append(Int64(10)); odd.append(Int64(30)); odd.append(Int64(20))
    odd.append(Int64(50)); odd.append(Int64(40))
    _assert_rel_close(
        _median_single[DType.int64](odd), 30.0, "i64 odd [10,30,20,50,40]"
    )
    _assert_rel_close(
        _median_two_partials[DType.int64](odd), 30.0,
        "i64 odd [10,30,20,50,40] (2-partial CONCAT)",
    )

    # [10,20,30,40] -> 25.0 (even: integer input, FLOAT half-integer output)
    var even = List[Scalar[DType.int64]]()
    even.append(Int64(10)); even.append(Int64(20))
    even.append(Int64(30)); even.append(Int64(40))
    _assert_rel_close(
        _median_single[DType.int64](even), 25.0, "i64 even [10,20,30,40]"
    )
    _assert_rel_close(
        _median_two_partials[DType.int64](even), 25.0,
        "i64 even [10,20,30,40] (2-partial CONCAT, half-integer median)",
    )


# -----------------------------------------------------------------------------
# §3 — empty group -> NaN (DuckDB median of an empty group is NULL).
# -----------------------------------------------------------------------------
def test_empty_group_returns_nan() raises:
    var empty = List[Scalar[DType.float64]]()
    assert_true(
        isnan(_median_single[DType.float64](empty)),
        "f64 empty MEDIAN -> NaN (DuckDB NULL)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
