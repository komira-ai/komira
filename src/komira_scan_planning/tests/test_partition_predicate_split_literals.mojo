# =============================================================================
# test_partition_predicate_split_literals.mojo
# =============================================================================
# `split_partition_predicate` followed by the file fold
# (`_file_matches_predicate`) must give the SQL answer for every literal
# kind, not only the kinds whose text form the fold compares against.
#
# The split renders a literal to partition text and, for a clean
# constraint, drops the conjunct from the residual. A literal whose text is
# not the column's canonical partition text (a DATE32 day count against
# `YYYY-MM-DD`, TIMESTAMP micros against `YYYY-MM-DD HH:MM:SS`, NULL, a
# float against an INT64 column, binary, decimal, a uint64 above 2^63)
# would then prune files holding matching rows, or keep files whose rows
# SQL rejects with nothing left to reject them.
#
# Each case is one file and one filter, and asserts the query result:
#   * SQL keeps the file's rows -> the fold must keep the file;
#   * SQL rejects them -> the fold prunes the file or the conjunct stays on
#     the residual (the row filter still rejects the rows).
# The cases cover the comparison shape (literal on either side), the
# `EXPR_IN_LIST` node and the OR-of-EQ chain `Expr.in_list` folds to, since
# all three render literals.
# =============================================================================

from std.testing import TestSuite, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_EQ, BIN_GT, BIN_LT
from komira_plan_expr.scalar_value import ScalarValue
from komira_fs.pruned_hive_discovery import _file_matches_predicate
from komira_scan_planning.partition_predicate_split import (
    split_partition_predicate,
)


def _check(
    var filter: Expr,
    col: String,
    atype: ArrowType,
    file_value: String,
    sql_keeps: Bool,
    label: String,
) raises:
    var cols = List[String]()
    cols.append(col)
    var types = List[ArrowType]()
    types.append(atype)
    var split = split_partition_predicate(filter, cols, types)
    var vals = List[String]()
    vals.append(file_value)
    var fold_keeps = _file_matches_predicate(
        cols, vals, split.partition_predicate
    )
    if sql_keeps:
        assert_true(fold_keeps, label + String(": file pruned"))
    else:
        assert_true(
            (not fold_keeps) or Bool(split.residual),
            label + String(": file kept with no residual"),
        )


def _eq(col: String, var v: ScalarValue) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(col), Expr.literal(v^))


def test_date32_literal_keeps_matching_date_file() raises:
    # 19000 days after 1970-01-01 is 2022-01-08.
    _check(
        _eq(String("dt"), ScalarValue.date32(Int32(19000))),
        String("dt"),
        ArrowType.DATE32,
        String("2022-01-08"),
        True,
        String("date32"),
    )


def test_date32_range_keeps_earlier_date_file() raises:
    # dt < 2022-01-08 holds for 2021-06-01.
    _check(
        Expr.binary(
            BIN_LT,
            Expr.col_ref(String("dt")),
            Expr.literal(ScalarValue.date32(Int32(19000))),
        ),
        String("dt"),
        ArrowType.DATE32,
        String("2021-06-01"),
        True,
        String("date32 range"),
    )


def test_date32_literal_on_the_left_keeps_earlier_date_file() raises:
    # 2022-01-08 > dt holds for 2021-06-01.
    _check(
        Expr.binary(
            BIN_GT,
            Expr.literal(ScalarValue.date32(Int32(19000))),
            Expr.col_ref(String("dt")),
        ),
        String("dt"),
        ArrowType.DATE32,
        String("2021-06-01"),
        True,
        String("date32 on the left"),
    )


def test_timestamp_literal_keeps_matching_file() raises:
    # 1641600000 s after the epoch is 2022-01-08 00:00:00.
    _check(
        _eq(String("ts"), ScalarValue.timestamp_micros(Int64(1641600000000000))),
        String("ts"),
        ArrowType.TIMESTAMP,
        String("2022-01-08 00:00:00"),
        True,
        String("timestamp"),
    )


def test_eq_null_rejects_the_null_partition() raises:
    # `dt = NULL` is never true; the null partition decodes to ``.
    _check(
        _eq(String("dt"), ScalarValue.null(DType.int64)),
        String("dt"),
        ArrowType.STRING,
        String(""),
        False,
        String("eq null"),
    )


def test_float_literal_keeps_equal_int_file() raises:
    _check(
        _eq(String("yr"), ScalarValue.from_float(2020.0)),
        String("yr"),
        ArrowType.INT64,
        String("2020"),
        True,
        String("yr=2020 by 2020.0"),
    )


def test_float_literal_rejects_zero_int_file() raises:
    _check(
        _eq(String("yr"), ScalarValue.from_float(2020.0)),
        String("yr"),
        ArrowType.INT64,
        String("0"),
        False,
        String("yr=0 by 2020.0"),
    )


def test_binary_literal_keeps_matching_string_file() raises:
    _check(
        _eq(String("region"), ScalarValue.from_binary(String("eu"))),
        String("region"),
        ArrowType.STRING,
        String("eu"),
        True,
        String("binary eu"),
    )


def test_decimal_literal_keeps_matching_int_file() raises:
    # decimal128 2020 (scale 0) equals the INT64 partition value 2020.
    _check(
        _eq(String("yr"), ScalarValue.decimal128(Int64(0), Int64(2020), 4, 0)),
        String("yr"),
        ArrowType.INT64,
        String("2020"),
        True,
        String("decimal 2020"),
    )


def test_uint64_above_int64_rejects_int64_min_file() raises:
    # 2^63 as uint64 is not -2^63; its int_val bit pattern is.
    _check(
        _eq(String("yr"), ScalarValue.from_uint64(UInt64(9223372036854775808))),
        String("yr"),
        ArrowType.INT64,
        String("-9223372036854775808"),
        False,
        String("uint64 2^63"),
    )


def _dates() -> List[ScalarValue]:
    var vs = List[ScalarValue]()
    vs.append(ScalarValue.date32(Int32(1)))
    vs.append(ScalarValue.date32(Int32(19000)))
    return vs^


def test_date32_in_list_node_keeps_matching_file() raises:
    _check(
        Expr.in_list_node(Expr.col_ref(String("dt")), _dates()),
        String("dt"),
        ArrowType.DATE32,
        String("2022-01-08"),
        True,
        String("date32 IN node"),
    )


def test_date32_or_chain_keeps_matching_file() raises:
    # `Expr.in_list` folds to `(dt == d1) OR (dt == d2)`.
    _check(
        Expr.in_list(Expr.col_ref(String("dt")), _dates()),
        String("dt"),
        ArrowType.DATE32,
        String("2022-01-08"),
        True,
        String("date32 OR chain"),
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_date32_literal_keeps_matching_date_file]()
    suite.test[test_date32_range_keeps_earlier_date_file]()
    suite.test[test_date32_literal_on_the_left_keeps_earlier_date_file]()
    suite.test[test_timestamp_literal_keeps_matching_file]()
    suite.test[test_eq_null_rejects_the_null_partition]()
    suite.test[test_float_literal_keeps_equal_int_file]()
    suite.test[test_float_literal_rejects_zero_int_file]()
    suite.test[test_binary_literal_keeps_matching_string_file]()
    suite.test[test_decimal_literal_keeps_matching_int_file]()
    suite.test[test_uint64_above_int64_rejects_int64_min_file]()
    suite.test[test_date32_in_list_node_keeps_matching_file]()
    suite.test[test_date32_or_chain_keeps_matching_file]()
    suite^.run()
