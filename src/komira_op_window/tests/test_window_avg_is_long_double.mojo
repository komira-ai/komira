# =============================================================================
# The INT64 AVG of a window frame is DuckDB's: its total divided in 80-bit long
# double, rounded once to a double
#
# `i64_mean` finishes the running, the sliding and the whole-partition AVG of an
# INT64 column. Worked by hand:
#   * -(2^64 + 2049) over 3 rows: the total rounds to -(2^64 + 2048) in a
#     64-bit mantissa (a tie, kept even), the quotient is exactly
#     -6148914691236517888. One rounding of the total to a double (the
#     conversion `Scalar[int128].cast[float64]()`) gives -6.148914691236519e+18
#     instead; the DuckDB oracle of komira_decimal_compare_conformance answers
#     -6.14891469123651789e+18 for that total.
#   * 2473 over 2051 rows: the quotient is 2^-53/2051 above a midpoint of two
#     doubles; the 64-bit rounding lands on the midpoint and the tie goes to the
#     even double below, one double division takes the one above.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_op_window.partition_null_policy import i64_mean


def test_a_total_past_2_64_divides_as_duckdb_does() raises:
    var total = -((Scalar[DType.int128](1) << 64) + 2049)
    assert_equal(i64_mean(total, 3), Float64(-6148914691236517888.0))
    assert_equal(i64_mean(-total, 3), Float64(6148914691236517888.0))


def test_a_count_past_2048_rounds_twice_as_duckdb_does() raises:
    var plain = Float64(2473.0) / Float64(2051.0)
    assert_equal(
        i64_mean(Scalar[DType.int128](2473), 2051),
        plain - Float64(2.220446049250313e-16),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
