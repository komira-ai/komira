# =============================================================================
# DECIMAL column `xw` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column xw is DECIMAL(38, 10) and holds +-10^27: widening it overflows from scale 11 on (scale 10 answers, even when it is written with trailing zeros as 13 digits: that is scale 13 and raises).
#
# What this test proves, and the defect it catches:
#   * test_column_xw_matches_duckdb: for every literal of
#     compare_xw.tsv and each of = <> < <= > >=, `select count(*), sum(id)
#     from tx where xw <op> <literal>` keeps the rows DuckDB keeps, and
#     so does each reversed spelling `<literal> <flipped op> xw` (the table,
#     the literals and the answers are oracle/*.sql run by the pinned DuckDB;
#     nothing is computed here). Where DuckDB raises a conversion error for the
#     comparison (the literal does not cast to the type DuckDB compares in, or
#     a stored value does not widen to it), the query is refused. Catches a
#     bound folded in floating point, a literal with more scale rounded to the
#     column's scale instead of compared exactly, a wrong floor or ceil for an
#     operator, a sign error on a negative literal, a compare that narrows to
#     int64 for a column that is wider, a NULL row kept, an operand-order slip
#     in the reversed form, an answer where DuckDB raises, and a refusal where
#     DuckDB answers.

from std.testing import TestSuite

from komira_decimal_compare_conformance.checks import check_compare_column


def test_column_xw_matches_duckdb() raises:
    check_compare_column("tx", "xw", 0, 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_xw_matches_duckdb]()
    suite^.run()
