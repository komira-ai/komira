# =============================================================================
# DECIMAL column `c` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column c is DECIMAL(19, 2): the narrowest decimal whose unscaled value may not fit an int64, with rows at and past 2^63 - 1 hundredths.
#
# What this test proves, and the defect it catches:
#   * test_column_c_matches_duckdb: for every literal of compare_c.tsv and
#     each of = <> < <= > >=, `select count(*), sum(id) from t where c <op>
#     <literal>` keeps the rows DuckDB keeps (the table, the literals and the
#     answers are oracle/*.sql run by the pinned DuckDB; nothing is computed
#     here), and so does the reversed spelling `<literal> <flipped op> c` for
#     one operator per literal. The literals are the bounds Q6 folds
#     (`0.06 - 0.01`), literals with more scale than the column (`0.065`,
#     `23.995`, `0.0000001`) for every operator, integers (`24`, `0`, `-1`),
#     negative literals, and the column's extremes. Catches a bound folded in
#     floating point, a literal with more scale rounded to the column's scale
#     instead of compared exactly, a wrong floor or ceil for an operator, a
#     sign error on a negative literal, a compare that narrows to int64 for a
#     column that is wider, a NULL row kept, and an operand-order slip in the
#     reversed form.

from std.testing import TestSuite

from komira_decimal_compare_conformance.checks import check_compare_column


def test_column_c_matches_duckdb() raises:
    check_compare_column("c")


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_c_matches_duckdb]()
    suite^.run()
