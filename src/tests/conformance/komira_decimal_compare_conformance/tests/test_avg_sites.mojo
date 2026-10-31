# =============================================================================
# AVG through SQL: every place the engine finalizes an avg() of an integer or a
# DECIMAL, bit for bit against the pinned DuckDB's own avg()
# =============================================================================
#
# avg_sites.tsv holds DuckDB's avg(), per group, over pj (BIGINT rows in 13
# groups whose sums run past 2^64 and 2^70 on both sides of zero), pd (the
# same rows as DECIMAL(38, 0 / 2 / 10)) and pa (BIGINT rows in 23 groups, most
# of whose sums run past 2^53 and 2^64). DuckDB divides the exact total in 80-bit
# long double and rounds once to a double, so a total past 2^53 (or a count past
# 2^11) answers a double that one conversion and a double division do not. Each
# test below drives one of the engine's AVG finalizers; a finalizer that is not
# DuckDB's turns exactly its own test red:
#   * test_avg_of_a_decimal_is_duckdbs: `avg(<DECIMAL(38, s)>)` for s = 0, 2
#     and 10, grouped.
#   * test_avg_of_a_bigint_is_duckdbs: `avg(<BIGINT>)` grouped, over 13 and 23
#     groups.
#   * test_an_ungrouped_avg_is_duckdbs: `avg(<BIGINT>)` of one group, beside
#     min(k).
#   * test_avg_over_a_window_is_duckdbs: `avg(<BIGINT>) OVER (PARTITION BY k)`.
#   * test_avg_beside_a_count_distinct_is_duckdbs: `avg(<BIGINT>)` with
#     `count(DISTINCT <BIGINT>)` in the same grouped aggregate.

from std.testing import TestSuite

from komira_decimal_compare_conformance.avg_checks import check_avg_query


def test_avg_of_a_decimal_is_duckdbs() raises:
    check_avg_query("avg_decimal_scale0")
    check_avg_query("avg_decimal_scale2")
    check_avg_query("avg_decimal_scale10")


def test_avg_of_a_bigint_is_duckdbs() raises:
    check_avg_query("avg_bigint_13_groups")
    check_avg_query("avg_bigint_23_groups")


def test_an_ungrouped_avg_is_duckdbs() raises:
    check_avg_query("avg_bigint_one_row")
    check_avg_query("avg_bigint_one_row_10")


def test_avg_over_a_window_is_duckdbs() raises:
    check_avg_query("avg_bigint_window")


def test_avg_beside_a_count_distinct_is_duckdbs() raises:
    check_avg_query("avg_bigint_beside_count_distinct")


def main() raises:
    var suite = TestSuite()
    suite.test[test_avg_of_a_decimal_is_duckdbs]()
    suite.test[test_avg_of_a_bigint_is_duckdbs]()
    suite.test[test_an_ungrouped_avg_is_duckdbs]()
    suite.test[test_avg_over_a_window_is_duckdbs]()
    suite.test[test_avg_beside_a_count_distinct_is_duckdbs]()
    suite^.run()
