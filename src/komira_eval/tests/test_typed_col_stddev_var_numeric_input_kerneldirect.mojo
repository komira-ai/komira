# =============================================================================
# test_typed_col_stddev_var_numeric_input_kerneldirect.mojo
# =============================================================================
#
# The typed-column STDDEV_SAMP / VAR_SAMP dispatch gate admits ALL numeric
# input DTypes (int64/int32/float64/float32), not only FLOAT64.
#
# WHY THAT IS CORRECT: the typed COLUMN
# op `StddevSampOp[dt]` / `VarSampOp[dt]` (hash_agg_op_dt.mojo) is DType-GENERIC
# by construction — a SINGLE Welford conformer serves every numeric input. The
# `HashAggOpAgg[Op, col]` adapter reads the input column in its NATIVE DType off
# the BatchView, then `Op.update_scalar` does `value.cast[float64]()` BEFORE the
# Welford recurrence. So the driver already computes the correct sample stddev /
# variance for ANY numeric input; an F64 restriction would be a pure dispatch
# gate.
#
# Moreover the typed driver is the SOLE CORRECT path for a non-F64 STDDEV: the
# UNTYPED column STDDEV runtime feed reads its value column with `gather_f64xW`
# (RUNTIME_AGG_STDDEV_SAMP_F64), which reinterprets
# raw int/float32 bytes as Float64 — the untyped path has NO correct non-F64
# STDDEV oracle.
#
# THIS TEST drives the agg KERNEL DIRECTLY (`StddevSampOp[dt]` / `VarSampOp[dt]`
# init/update_scalar/finalize) over hand-built columns — without compiling
# the full ctx.materialize dispatch tree — so it runs in well under a
# second. It exercises BOTH the single-accumulator hot path AND the multi-partial
# Chan parallel-merge `combine` path (the multi-worker shape the typed Stage
# uses), and compares the finalized result against a DuckDB STDDEV_SAMP /
# VAR_SAMP oracle.
#
# ENGINE SEMANTICS = SAMPLE (n-1 denominator): `StddevSampOp.finalize` returns
# sqrt(m2/(count-1)) for count>1, NaN otherwise; `VarSampOp.finalize` returns
# m2/(count-1). The matching DuckDB oracle functions are therefore STDDEV_SAMP /
# VAR_SAMP (n-1), NOT the _POP (n) variants. DuckDB returns NULL for n=1; this engine
# returns NaN (the documented "DuckDB NULL convention" in the finalize body) — §3
# pins that count<=1 -> NaN.
#
# COMPARE MODE = TIGHT RELATIVE EPSILON (NOT a raw-bits compare): STDDEV/VAR are
# FLOAT reductions (a sqrt + a division over a Welford/Chan accumulation). The
# accumulation order/algorithm differs between this engine's Welford-then-Chan-merge
# and DuckDB's internal aggregate, so the two can legitimately differ in the LAST
# ULP. We assert `abs(a-b)/max(abs(b),1e-300) < 1e-12` — the float-aggregate
# standard (consistent with the 4-path harness's non-bitwise-predicate note for
# float vectors; an exact assert_equal would spuriously FAIL by ~1 part in 1e13).
#
# DuckDB oracle (the duckdb CLI, STDDEV_SAMP/VAR_SAMP):
#   int64 grouped: g=1 [10,20,30] -> sd=10.0,            vr=100.0
#                  g=2 [5,7]       -> sd=1.4142135623730951, vr=2.0
#                  g=3 [100]       -> sd=NULL,            vr=NULL  (n=1)
#   int64 scalar  [10,20,30,5,7,100] -> sd=36.175498153676706, vr=1308.6666666666667
#   float32 grp:   g=1 [1.5,2.5,3.5] -> sd=1.0,           vr=1.0
#                  g=2 [10.0]      -> sd=NULL,            vr=NULL  (n=1)
#   float32 scalar [1.5,2.5,3.5,10.0] -> sd=3.8378596465564847, vr=14.729166666666666
#
# Encapsulation invariants: NO UnsafePointer / wildcard
# origins / unsafe_from_address / take_pointee in THIS test. Kernel surface only.
# =============================================================================

from std.testing import TestSuite, assert_true
from std.math import isnan

from komira_eval.hash_agg_op_dt import (
    StddevSampOp, VarSampOp, WelfordRunningState,
)


# -----------------------------------------------------------------------------
# Relative-epsilon float compare (the float-reduction standard). For a stddev /
# variance result we tolerate a last-ULP divergence between this engine's Welford/
# Chan accumulation and DuckDB's internal aggregate; an exact compare would
# spuriously fail by ~1 part in 1e13.
# -----------------------------------------------------------------------------
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
# Single-accumulator drain: init -> update_scalar over the whole column -> finalize.
# This is the one-worker hot path of the typed Stage (no cross-worker combine).
# -----------------------------------------------------------------------------
def _stddev_single[dt: DType](vals: List[Scalar[dt]]) -> Float64:
    var st = StddevSampOp[dt].init()
    for i in range(len(vals)):
        StddevSampOp[dt].update_scalar(st, vals[i])
    return StddevSampOp[dt].finalize(st)


def _var_single[dt: DType](vals: List[Scalar[dt]]) -> Float64:
    var st = VarSampOp[dt].init()
    for i in range(len(vals)):
        VarSampOp[dt].update_scalar(st, vals[i])
    return VarSampOp[dt].finalize(st)


# -----------------------------------------------------------------------------
# Multi-partial drain: split the column into two disjoint halves, accumulate each
# in its OWN WelfordRunningState (the per-worker partial), then Chan-merge them
# via `combine` before finalize. This is the actual multi-worker shape the typed
# Stage drives — it MUST produce the same value as the single-accumulator path
# (and match DuckDB) to prove the parallel-merge is correct over non-F64 input.
# -----------------------------------------------------------------------------
def _stddev_two_partials[dt: DType](vals: List[Scalar[dt]]) -> Float64:
    var mid = len(vals) // 2
    var a = StddevSampOp[dt].init()
    for i in range(mid):
        StddevSampOp[dt].update_scalar(a, vals[i])
    var b = StddevSampOp[dt].init()
    for i in range(mid, len(vals)):
        StddevSampOp[dt].update_scalar(b, vals[i])
    StddevSampOp[dt].combine(a, b)
    return StddevSampOp[dt].finalize(a)


# -----------------------------------------------------------------------------
# §1 — INT64 input STDDEV_SAMP / VAR_SAMP, grouped + scalar, vs DuckDB.
# The driver casts each native Int64 value to f64 inside update_scalar.
# -----------------------------------------------------------------------------
def test_int64_stddev_var_matches_duckdb() raises:
    # g=1: [10,20,30] -> sd=10.0, vr=100.0
    var g1 = List[Scalar[DType.int64]]()
    g1.append(Int64(10)); g1.append(Int64(20)); g1.append(Int64(30))
    _assert_rel_close(
        _stddev_single[DType.int64](g1), 10.0, "int64 g1 STDDEV_SAMP"
    )
    _assert_rel_close(_var_single[DType.int64](g1), 100.0, "int64 g1 VAR_SAMP")
    # multi-partial Chan-merge must agree with DuckDB too.
    _assert_rel_close(
        _stddev_two_partials[DType.int64](g1), 10.0,
        "int64 g1 STDDEV_SAMP (2-partial Chan-merge)",
    )

    # g=2: [5,7] -> sd=1.4142135623730951, vr=2.0
    var g2 = List[Scalar[DType.int64]]()
    g2.append(Int64(5)); g2.append(Int64(7))
    _assert_rel_close(
        _stddev_single[DType.int64](g2), 1.4142135623730951,
        "int64 g2 STDDEV_SAMP",
    )
    _assert_rel_close(_var_single[DType.int64](g2), 2.0, "int64 g2 VAR_SAMP")

    # scalar over [10,20,30,5,7,100] -> sd=36.175498153676706, vr=1308.6666666666667
    var sc = List[Scalar[DType.int64]]()
    sc.append(Int64(10)); sc.append(Int64(20)); sc.append(Int64(30))
    sc.append(Int64(5)); sc.append(Int64(7)); sc.append(Int64(100))
    _assert_rel_close(
        _stddev_single[DType.int64](sc), 36.175498153676706,
        "int64 scalar STDDEV_SAMP",
    )
    _assert_rel_close(
        _var_single[DType.int64](sc), 1308.6666666666667,
        "int64 scalar VAR_SAMP",
    )
    _assert_rel_close(
        _stddev_two_partials[DType.int64](sc), 36.175498153676706,
        "int64 scalar STDDEV_SAMP (2-partial Chan-merge)",
    )


# -----------------------------------------------------------------------------
# §2 — FLOAT32 input STDDEV_SAMP / VAR_SAMP, grouped + scalar, vs DuckDB.
# The driver casts each native Float32 value to f64 inside update_scalar.
# -----------------------------------------------------------------------------
def test_float32_stddev_var_matches_duckdb() raises:
    # g=1: [1.5,2.5,3.5] -> sd=1.0, vr=1.0
    var g1 = List[Scalar[DType.float32]]()
    g1.append(Float32(1.5)); g1.append(Float32(2.5)); g1.append(Float32(3.5))
    _assert_rel_close(
        _stddev_single[DType.float32](g1), 1.0, "float32 g1 STDDEV_SAMP"
    )
    _assert_rel_close(_var_single[DType.float32](g1), 1.0, "float32 g1 VAR_SAMP")
    _assert_rel_close(
        _stddev_two_partials[DType.float32](g1), 1.0,
        "float32 g1 STDDEV_SAMP (2-partial Chan-merge)",
    )

    # scalar over [1.5,2.5,3.5,10.0] -> sd=3.8378596465564847, vr=14.729166666666666
    var sc = List[Scalar[DType.float32]]()
    sc.append(Float32(1.5)); sc.append(Float32(2.5))
    sc.append(Float32(3.5)); sc.append(Float32(10.0))
    _assert_rel_close(
        _stddev_single[DType.float32](sc), 3.8378596465564847,
        "float32 scalar STDDEV_SAMP",
    )
    _assert_rel_close(
        _var_single[DType.float32](sc), 14.729166666666666,
        "float32 scalar VAR_SAMP",
    )
    _assert_rel_close(
        _stddev_two_partials[DType.float32](sc), 3.8378596465564847,
        "float32 scalar STDDEV_SAMP (2-partial Chan-merge)",
    )


# -----------------------------------------------------------------------------
# §3 — n=1 edge: DuckDB returns NULL for STDDEV_SAMP/VAR_SAMP of a single row;
# this engine's finalize returns NaN for count<=1 (the documented "DuckDB NULL
# convention" — the drain emits NaN which the column layer renders as NULL).
# Pin that count<=1 -> NaN for a non-F64 (int64) input column.
# -----------------------------------------------------------------------------
def test_n1_returns_nan() raises:
    var one = List[Scalar[DType.int64]]()
    one.append(Int64(100))
    assert_true(
        isnan(_stddev_single[DType.int64](one)),
        "STDDEV_SAMP(int64) of 1 row -> NaN (DuckDB NULL)",
    )
    assert_true(
        isnan(_var_single[DType.int64](one)),
        "VAR_SAMP(int64) of 1 row -> NaN (DuckDB NULL)",
    )
    # empty group -> count 0 -> also NaN
    var empty = List[Scalar[DType.int64]]()
    assert_true(
        isnan(_stddev_single[DType.int64](empty)),
        "STDDEV_SAMP(int64) of 0 rows -> NaN",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
