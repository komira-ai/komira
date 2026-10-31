# =============================================================================
# WHERE texts over DECIMAL columns through run_sql, against DuckDB
# =============================================================================
#
# What this test proves, and the defect it catches:
#   * test_where_texts_match_duckdb: the rows each WHERE text of where.tsv keeps
#     (and the sum of their id) are DuckDB's: BETWEEN with folded bounds (the
#     inclusive 0.07), NOT BETWEEN, AND / OR / NOT of comparisons over one and
#     over several columns, IS NULL. Catches the defects of the per-column
#     tests when the comparison sits under a boolean connective or in a
#     rewrite of BETWEEN or NOT. (An IN list over a DECIMAL column is refused
#     by the evaluator today whatever its elements, so none is asked.)

from std.testing import TestSuite

from komira_decimal_compare_conformance.checks import check_where_texts


def test_where_texts_match_duckdb() raises:
    check_where_texts()


def main() raises:
    var suite = TestSuite()
    suite.test[test_where_texts_match_duckdb]()
    suite^.run()
