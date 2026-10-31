# =============================================================================
# DECIMAL column `ff` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column ff is DECIMAL(18, 0) against DOUBLE literals: a scale-0 column is converted as one double.
#
# What this test proves, and the defect it catches:
#   * test_column_ff_matches_duckdb: for every literal of
#     compare_ff.tsv and each of = <> < <= > >=, `select count(*), sum(id)
#     from tf where ff <op> <literal>` keeps the rows DuckDB keeps, and
#     so does each reversed spelling `<literal> <flipped op> ff` (the table,
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


def test_column_ff_matches_duckdb() raises:
    check_compare_column("tf", "ff", 0, 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_ff_matches_duckdb]()
    suite^.run()
