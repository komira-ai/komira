# =============================================================================
# Tests for Correlation/Covariance accumulators
# =============================================================================
#
# Covariance / Correlation tests:
#   1. Known covariance: x=[1,2,3], y=[2,4,6] -> covar_pop=2.0
#   2. Perfect positive correlation: r=1.0
#   3. No correlation: orthogonal data -> r=0
#   4. Negative correlation: r=-1.0
#   5. Single value: covar=0
#   6. Sample covariance (Bessel's correction)
#
# NB: this file historically also covered the NDJSON reader
# (`komira_parquet.ndjson_reader.read_ndjson`). JSON-PHASE-2-M5
# retired the legacy untyped NDJSON reader in favor of
# the typed `ctx.read_json_batch(path, schema)` SDK entry (M4) +
# Stage 2 columnar materializer (M1/M2/M3). The 5 NDJSON tests
# previously in this file are NOT migrated — the legacy Bool->Int64
# wide mapping is intentionally incompatible with the RFC v3.1
# typed schema contract. Typed coverage lives at
# `tests/json/test_read_json_batch_e2e.mojo` (M4 integration) +
# inline test cases in `an internal module*.mojo` and
# an internal module (M1/M2/M3).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.aggregate import CovarianceAccumulator, CorrelationAccumulator


# =============================================================================
# Helpers
# =============================================================================


def _assert_float_close(actual: Float64, expected: Float64, tol: Float64 = 1e-9) raises:
    """Assert that two Float64 values are approximately equal."""
    var diff = actual - expected
    if diff < 0:
        diff = -diff
    assert_true(
        diff < tol,
        "Expected " + String(expected) + " but got " + String(actual)
        + " (diff=" + String(diff) + ", tol=" + String(tol) + ")",
    )


# =============================================================================
# Covariance Tests
# =============================================================================


def test_covariance_known_values() raises:
    """Known covariance: x=[1,2,3], y=[2,4,6] -> covar_pop = 2.0."""
    var cov = CovarianceAccumulator.create()
    cov.update(1.0, 2.0)
    cov.update(2.0, 4.0)
    cov.update(3.0, 6.0)

    # Population covariance = sum((xi - mean_x)(yi - mean_y)) / n
    # mean_x = 2, mean_y = 4
    # (1-2)(2-4) + (2-2)(4-4) + (3-2)(6-4) = 2 + 0 + 2 = 4
    # covar_pop = 4/3 = 1.333...
    # Wait: y = 2*x, so covar_pop = 2 * var_pop(x) = 2 * 2/3 = 4/3
    _assert_float_close(cov.covar_pop(), 4.0 / 3.0)

    # Sample covariance = 4 / (3-1) = 2.0
    _assert_float_close(cov.covar_sample(), 2.0)


def test_covariance_perfect_positive() raises:
    """Perfect positive linear relationship: y = x."""
    var cov = CovarianceAccumulator.create()
    cov.update(1.0, 1.0)
    cov.update(2.0, 2.0)
    cov.update(3.0, 3.0)
    cov.update(4.0, 4.0)
    cov.update(5.0, 5.0)

    # When y = x, covar_pop = var_pop(x) = 2.0
    _assert_float_close(cov.covar_pop(), 2.0)
    # sample covariance = 2.5
    _assert_float_close(cov.covar_sample(), 2.5)


def test_covariance_single_value() raises:
    """Single value: covariance should be 0."""
    var cov = CovarianceAccumulator.create()
    cov.update(5.0, 10.0)

    _assert_float_close(cov.covar_pop(), 0.0)
    _assert_float_close(cov.covar_sample(), 0.0)


# =============================================================================
# Correlation Tests
# =============================================================================


def test_correlation_perfect_positive() raises:
    """Perfect positive correlation: y = 2x + 1 -> r = 1.0."""
    var corr = CorrelationAccumulator.create()
    corr.update(1.0, 3.0)   # 2*1 + 1
    corr.update(2.0, 5.0)   # 2*2 + 1
    corr.update(3.0, 7.0)   # 2*3 + 1
    corr.update(4.0, 9.0)   # 2*4 + 1
    corr.update(5.0, 11.0)  # 2*5 + 1

    _assert_float_close(corr.correlation(), 1.0)


def test_correlation_perfect_negative() raises:
    """Perfect negative correlation: y = -x + 10 -> r = -1.0."""
    var corr = CorrelationAccumulator.create()
    corr.update(1.0, 9.0)   # -1 + 10
    corr.update(2.0, 8.0)   # -2 + 10
    corr.update(3.0, 7.0)   # -3 + 10
    corr.update(4.0, 6.0)   # -4 + 10
    corr.update(5.0, 5.0)   # -5 + 10

    _assert_float_close(corr.correlation(), -1.0)


def test_correlation_no_correlation() raises:
    """Orthogonal data has zero correlation.

    Use symmetric data that guarantees zero covariance:
    (1,1), (1,-1), (-1,1), (-1,-1) -> r = 0.
    """
    var corr = CorrelationAccumulator.create()
    corr.update(1.0, 1.0)
    corr.update(1.0, -1.0)
    corr.update(-1.0, 1.0)
    corr.update(-1.0, -1.0)

    _assert_float_close(corr.correlation(), 0.0)


def test_correlation_single_value() raises:
    """Single value: correlation returns 0.0 (insufficient data)."""
    var corr = CorrelationAccumulator.create()
    corr.update(5.0, 10.0)

    _assert_float_close(corr.correlation(), 0.0)


def test_correlation_constant_variable() raises:
    """Constant x or y means stddev=0, so correlation returns 0.0."""
    var corr = CorrelationAccumulator.create()
    corr.update(5.0, 1.0)
    corr.update(5.0, 2.0)
    corr.update(5.0, 3.0)

    # x is constant -> stddev(x) = 0 -> correlation = 0.0
    _assert_float_close(corr.correlation(), 0.0)


# =============================================================================
# Main entry point
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
