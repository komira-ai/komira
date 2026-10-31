# =============================================================================
# DECIMAL to DOUBLE through SQL: every place the engine converts one, bit for bit
# against the pinned DuckDB
# =============================================================================
#
# double_sites.tsv holds DuckDB's DOUBLE, per group, for queries over pj (BIGINT
# rows in 13 groups whose sums run past 2^64 and 2^70 on both sides of zero), pd
# (the same rows as DECIMAL(38, 0 / 2 / 10)) and pg (the stored per-group sums).
# Each test below drives one of the engine's DECIMAL-to-DOUBLE conversions, so a
# conversion that is not DuckDB's turns exactly its own test red:
#   * test_reviewer_group_sums_are_duckdbs: `sum(v) * 1e0` for the groups that
#     sum to -(2^64) - 2^11 - 1 and -(2^70) - 2^17 - 1, against DuckDB's two
#     printed numbers. Catches an integer sum converted with one rounding.
#   * test_a_sum_cast_to_double_is_duckdbs: `sum(v)` of an integer column
#     (DECIMAL(38, 0)) times, over, plus a DOUBLE or over an integer or a
#     count. Catches the same defect in the cast the binder builds around the
#     sum and in the promotion beside a DOUBLE operand.
#   * test_a_math_function_over_a_sum_is_duckdbs: `cbrt(sum(v))`.
#   * test_cast_of_a_stored_decimal_is_duckdbs: `cast(<DECIMAL(38, s)> as
#     double)` for s = 0, 2 and 10.
#   * test_a_stored_decimal_beside_a_double_is_duckdbs: `col * 1e0` and
#     `col + 0.5e0` over a stored DECIMAL(38, s).
#   * test_a_math_function_over_a_stored_decimal_is_duckdbs: `cbrt(col)`.
#   * test_avg_of_a_decimal_is_duckdbs: `avg(<DECIMAL(38, s)>)` for s = 0, 2
#     and 10.

from std.testing import TestSuite

from komira_decimal_compare_conformance.site_checks import (
    check_double_site,
    check_reviewer_group_sums,
)


def test_reviewer_group_sums_are_duckdbs() raises:
    check_reviewer_group_sums()


def test_a_sum_cast_to_double_is_duckdbs() raises:
    check_double_site("sum_times_double")
    check_double_site("sum_over_double")
    check_double_site("sum_plus_double")
    check_double_site("sum_over_int")
    check_double_site("sum_over_count")


def test_a_math_function_over_a_sum_is_duckdbs() raises:
    check_double_site("sum_math")


def test_cast_of_a_stored_decimal_is_duckdbs() raises:
    check_double_site("cast_s0")
    check_double_site("cast_s2")
    check_double_site("cast_s10")


def test_a_stored_decimal_beside_a_double_is_duckdbs() raises:
    check_double_site("column_times_double")
    check_double_site("column_plus_double")


def test_a_math_function_over_a_stored_decimal_is_duckdbs() raises:
    check_double_site("column_math")


def test_avg_of_a_decimal_is_duckdbs() raises:
    check_double_site("avg_d0")
    check_double_site("avg_d2")
    check_double_site("avg_d10")


def main() raises:
    var suite = TestSuite()
    suite.test[test_reviewer_group_sums_are_duckdbs]()
    suite.test[test_a_sum_cast_to_double_is_duckdbs]()
    suite.test[test_a_math_function_over_a_sum_is_duckdbs]()
    suite.test[test_cast_of_a_stored_decimal_is_duckdbs]()
    suite.test[test_a_stored_decimal_beside_a_double_is_duckdbs]()
    suite.test[test_a_math_function_over_a_stored_decimal_is_duckdbs]()
    suite.test[test_avg_of_a_decimal_is_duckdbs]()
    suite^.run()
