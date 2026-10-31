# =============================================================================
# The AVG of an integer column beside a COUNT(DISTINCT) is DuckDB's: the exact
# 128-bit total divided in 80-bit long double, rounded once to a double
#
# `cd_fixed_column` finishes the grouped driver's fixed aggregates. Worked by
# hand: a group whose INT64 total is -(2^64 + 2049) over 3 rows has the average
# -6148914691236517888 exactly (the total rounds to -(2^64 + 2048) in a 64-bit
# mantissa, a tie kept even); a total of 2473 over 2051 rows is 2^-53/2051 above
# a midpoint of two doubles, where the 64-bit rounding lands on the midpoint and
# the tie goes to the even double below.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_op_agg_distinct.cd_parallel_emit import (
    CDFixedCell,
    cd_fixed_column,
)
from komira_plan_expr.agg_expr import AGG_MEAN


def _mean(total: Scalar[DType.int128], n: Int64) raises -> Float64:
    var cells = List[CDFixedCell]()
    cells.append(CDFixedCell(total, Float64(0.0), n))
    var any_null = True
    var col = cd_fixed_column(
        cells, AGG_MEAN, ArrowType.FLOAT64, True, "v", any_null
    )
    assert_false(any_null)
    return col.as_primitive[DType.float64]().get(0)


def test_a_total_past_2_64_divides_as_duckdb_does() raises:
    var total = -((Scalar[DType.int128](1) << 64) + 2049)
    assert_equal(_mean(total, 3), Float64(-6148914691236517888.0))


def test_a_count_past_2048_rounds_twice_as_duckdb_does() raises:
    var plain = Float64(2473.0) / Float64(2051.0)
    assert_equal(
        _mean(Scalar[DType.int128](2473), 2051),
        plain - Float64(2.220446049250313e-16),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
