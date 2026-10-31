# =============================================================================
# DECIMAL column `h` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column h is DECIMAL(15, 5): a literal of less scale than the column (`0.06`, `24`, `0.5`, `- -0.5`, folded constants), of its scale (`0.000005`), and of more (`0.0600001`). Integers run to 10^32, the largest that casts to DECIMAL(38, 5); 10^33 raises.
#
# Part 2 of 2: the literals of compare_h.tsv whose row number is 1 modulo 2.
#
# What this test proves, and the defect it catches:
#   * test_column_h_2_matches_duckdb: for every literal of
#     compare_h.tsv and each of = <> < <= > >=, `select count(*), sum(id)
#     from t where h <op> <literal>` keeps the rows DuckDB keeps, and
#     so does each reversed spelling `<literal> <flipped op> h` (the table,
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


def test_column_h_2_matches_duckdb() raises:
    check_compare_column("t", "h", 1, 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_h_2_matches_duckdb]()
    suite^.run()
