# =============================================================================
# DECIMAL column `c` vs literal comparisons through run_sql, against DuckDB
# =============================================================================
#
# Column c is DECIMAL(19, 2), the narrowest that does not fit an int64, with rows at and past 2^63 - 1 hundredths. Its literals are those of column a at its own extremes, the int64 limits as integers and as decimals, and integers past int64 (`9223372036854775808`, `18446744073709551615`, `18446744073709551616`).
#
# Part 3 of 3: the literals of compare_c.tsv whose row number is 2 modulo 3.
#
# What this test proves, and the defect it catches:
#   * test_column_c_3_matches_duckdb: for every literal of
#     compare_c.tsv and each of = <> < <= > >=, `select count(*), sum(id)
#     from t where c <op> <literal>` keeps the rows DuckDB keeps, and
#     so does each reversed spelling `<literal> <flipped op> c` (the table,
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


def test_column_c_3_matches_duckdb() raises:
    check_compare_column("t", "c", 2, 3)


def main() raises:
    var suite = TestSuite()
    suite.test[test_column_c_3_matches_duckdb]()
    suite^.run()
