# =============================================================================
# DECIMAL column `a` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column a is DECIMAL(15, 2). Its literals are the bounds Q6 folds (`0.06 - 0.01`), literals with more scale than the column (`0.065`, `23.995`, `0.0000001`), integers (`24`, `0`, `-1`), integers past the column's precision and past int64 (`99999999999999999999`, `10^35`), the literal shapes `- -0.5`, `5.`, `.5`, `00.5`, `1e-2`, `1e-1` and `2.5e1`, negatives, and the column's extremes. `10^36` is an integer DuckDB cannot cast to DECIMAL(38, 2): it raises, and so must the query.
#
# Part 3 of 3: the literals of compare_a.tsv whose row number is 2 modulo 3.
#
# What this test proves, and the defect it catches:
#   * test_column_a_3_matches_duckdb: for every literal of
#     compare_a.tsv and each of = <> < <= > >=, `select count(*), sum(id)
#     from t where a <op> <literal>` keeps the rows DuckDB keeps, and
#     so does each reversed spelling `<literal> <flipped op> a` (the table,
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


def test_column_a_3_matches_duckdb() raises:
    check_compare_column("t", "a", 2, 3)


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_a_3_matches_duckdb]()
    suite^.run()
