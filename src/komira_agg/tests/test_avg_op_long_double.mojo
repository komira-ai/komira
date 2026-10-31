# =============================================================================
# AvgOp over an integer column finalizes as DuckDB's avg() does
#
# DuckDB's avg() of an INTEGER or a BIGINT divides the exact total in 80-bit long
# double and rounds once to a double; of a SMALLINT it divides in double. Worked
# by hand: a total of -(2^64 + 2049) over 3 rows has the average
# -6148914691236517888 exactly (the total rounds to -(2^64 + 2048) in a 64-bit
# mantissa, a tie kept even); a total of 2473 over 2051 rows is 2^-53/2051 above
# a midpoint of two doubles, where the 64-bit rounding lands on the midpoint and
# the tie goes to the even double below (a double division takes the one above).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_agg.hash_agg_op_dt import AvgOp


def _state(total: Scalar[DType.int128], n: Int) -> SIMD[DType.int128, 2]:
    var s = SIMD[DType.int128, 2](0)
    s[0] = total
    s[1] = Scalar[DType.int128](n)
    return s


def test_a_bigint_total_past_2_64_divides_as_duckdb_does() raises:
    var total = -((Scalar[DType.int128](1) << 64) + 2049)
    assert_equal(
        AvgOp[DType.int64].finalize(_state(total, 3)),
        Float64(-6148914691236517888.0),
    )


def test_an_integer_count_past_2048_rounds_twice() raises:
    var plain = Float64(2473.0) / Float64(2051.0)
    var lower = plain - Float64(2.220446049250313e-16)
    assert_equal(AvgOp[DType.int64].finalize(_state(Scalar[DType.int128](2473), 2051)), lower)
    assert_equal(AvgOp[DType.int32].finalize(_state(Scalar[DType.int128](2473), 2051)), lower)


def test_a_smallint_divides_in_double() raises:
    var plain = Float64(2473.0) / Float64(2051.0)
    assert_equal(AvgOp[DType.int16].finalize(_state(Scalar[DType.int128](2473), 2051)), plain)
    assert_equal(AvgOp[DType.int8].finalize(_state(Scalar[DType.int128](2473), 2051)), plain)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
