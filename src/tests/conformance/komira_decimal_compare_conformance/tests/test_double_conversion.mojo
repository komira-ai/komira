# =============================================================================
# DECIMAL to DOUBLE: the conversion a comparison with a DOUBLE meets, bit for
# bit against the pinned DuckDB
# =============================================================================
#
# double_sweep.tsv holds 1000 DECIMAL(38, s) values (scale 0 to 37, 1 to 38
# digits, both signs, around 2^53, 2^63 and 2^64 and within 2^64 of zero, and
# seeded random ones) and the DOUBLE DuckDB casts each to. A DECIMAL column
# meets a DOUBLE literal through that cast, and a decimal literal of at most 38
# digits meets a DOUBLE operand through it too.
#
# What each test proves, and the defect it catches:
#   * test_the_column_conversion_is_duckdbs: `decimal_to_float64`, which the
#     compare of a column with a DOUBLE literal uses, gives DuckDB's double for
#     every value. Catches a 128-bit integer converted with one rounding where
#     DuckDB adds the double of its low word to the double of its high word
#     times 2^64 (they differ from 2^64 up).
#   * test_the_literal_conversion_is_duckdbs: the tokenizer's double for the
#     decimal text of each value of scale 1 and up (a literal of at most 38
#     digits) is DuckDB's. Catches the same defect in the literal.

from std.testing import TestSuite

from komira_decimal_compare_conformance.checks import (
    check_double_conversion_of_columns,
    check_double_conversion_of_literals,
)


def test_the_column_conversion_is_duckdbs() raises:
    check_double_conversion_of_columns()


def test_the_literal_conversion_is_duckdbs() raises:
    check_double_conversion_of_literals()


def main() raises:
    var suite = TestSuite()
    suite.test[test_the_column_conversion_is_duckdbs]()
    suite.test[test_the_literal_conversion_is_duckdbs]()
    suite^.run()
