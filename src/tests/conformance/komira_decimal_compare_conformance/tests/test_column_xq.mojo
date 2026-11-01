# =============================================================================
# DECIMAL column `xq` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column xq is DECIMAL(38, 2) and holds +-10^20, which is 10^22 hundredths. DuckDB widens it to DECIMAL(38, scale of the literal) to compare it with an over-scale literal, which overflows from scale 18 on (`0.000000000000000001`): that query raises, and so must this one. At scale 17 and below, and for any literal of scale 2 or less, it answers.
#
# What this test proves, and the defect it catches:
#   * test_column_xq_matches_duckdb: for every literal of
#     compare_xq.tsv and each of = <> < <= > >=, `select count(*), sum(id)
#     from tx where xq <op> <literal>` keeps the rows DuckDB keeps, and
#     so does each reversed spelling `<literal> <flipped op> xq` (the table,
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


def test_column_xq_matches_duckdb() raises:
    check_compare_column("tx", "xq", 0, 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_xq_matches_duckdb]()
    suite^.run()
