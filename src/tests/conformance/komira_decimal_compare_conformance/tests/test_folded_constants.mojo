# =============================================================================
# Constants folded by a comparison over a DECIMAL column, and Q6's bounds
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * test_folded_constants_have_duckdbs_type: for every constant of types.tsv
#     (DuckDB's type and value for `SELECT typeof(<expr>), <expr>`), the plan
#     `select count(*) from t where a = <expr>` lowers to holds the literal
#     DuckDB computes, with DuckDB's precision and scale, as a DECIMAL literal.
#     Catches a constant folded to a float, a literal given the wrong width
#     (`0.060` is DECIMAL(4, 3); an integer is DECIMAL(10, 0) or DECIMAL(19, 0)),
#     and a result type that differs from DuckDB's.
#   * test_constants_duckdb_cannot_fold_are_refused: for every constant of
#     errors.tsv, a sum or product whose value does not fit the width DuckDB
#     gives it (18 digits for operands of 18 digits or fewer, 38 otherwise) or
#     whose scale is past 38, `select count(*) from t where a = <expr>` is
#     refused, and the constants DuckDB folds are not. Catches a fold that
#     keeps a value DuckDB raises on, and a refusal of a constant it folds.
#   * test_q6_bounds_are_decimal_literals: Q6's lowered plan holds the range
#     bounds as DECIMAL literals and no float literal. Catches the float fold
#     that gave 0.049999999999999996 and 0.06999999999999999.

from std.testing import TestSuite

from komira_decimal_compare_conformance.checks import (
    check_fold_refusals,
    check_folded_constants,
    check_q6_bounds,
)


def test_folded_constants_have_duckdbs_type() raises:
    check_folded_constants()


def test_constants_duckdb_cannot_fold_are_refused() raises:
    check_fold_refusals()


def test_q6_bounds_are_decimal_literals() raises:
    check_q6_bounds()


def main() raises:
    var suite = TestSuite()
    suite.test[test_folded_constants_have_duckdbs_type]()
    suite.test[test_constants_duckdb_cannot_fold_are_refused]()
    suite.test[test_q6_bounds_are_decimal_literals]()
    suite^.run()
