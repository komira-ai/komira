# =============================================================================
# test_partition_predicate_split_cross_type.mojo
# =============================================================================
# `split_partition_predicate` must give a clean (residual-free) constraint
# only when the literal kind matches the partition column's type: a STRING
# literal on a STRING / DATE32 / TIMESTAMP column, an integer literal on an
# INT64 column, a BOOL literal on a BOOL column. Every other pair is a
# cross-type comparison whose SQL answer depends on how the query converts
# across types (cast the literal, cast the column, or raise), and the plan
# takes no implicit casts. The fold cannot decide such a pair: it reads
# non-integer text on an INT64 column as 0 and compares an integer's
# decimal text with a STRING / DATE32 / TIMESTAMP value lexically.
#
# So a cross-type pair must be routed conservatively: the fold keeps the
# file (pruning never changes the result) and the conjunct stays on the
# residual (the row filter, not the fold, gives the answer). Each case is
# one file and one filter, and asserts both halves.
#
# Each case fails if the split turns the pair into a clean constraint:
#   * `yr = 'abc'`, `yr = '2020.0'`, `yr = true` on the INT64 file `yr=0`
#     keep the file with no residual (the fold parses the text as 0);
#   * `region = 5` on the STRING file `region=05` and `region < 10` on
#     `region=9` prune the file (exact / lexical text compare);
#   * `dt = 19000` on the DATE32 file `2022-01-08`, an integer on a
#     TIMESTAMP file, `on = 1` on a BOOL file prune the file;
#   * the literal-on-the-left, `EXPR_IN_LIST` node and OR-of-EQ chain shapes
#     render literals on their own paths, so each has a case.
# The matching-kind controls fail if the fix routes every pair
# conservatively (they must stay clean, with no residual).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_EQ, BIN_LT, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_fs.pruned_hive_discovery import _file_matches_predicate, _OP_OTHER
from komira_scan_planning.partition_predicate_split import (
    split_partition_predicate,
)


def _split_one(
    filter: Expr, col: String, atype: ArrowType, file_value: String
) raises -> Tuple[Bool, Bool, Int]:
    """Split `filter` over the one partition column `col` and fold the file
    `col=file_value`. Returns (fold keeps the file, residual present, op of
    the single constraint or -1)."""
    var cols = List[String]()
    cols.append(col)
    var types = List[ArrowType]()
    types.append(atype)
    var split = split_partition_predicate(filter, cols, types)
    var vals = List[String]()
    vals.append(file_value)
    var keeps = _file_matches_predicate(cols, vals, split.partition_predicate)
    var op = -1
    if split.partition_predicate.num_constraints() == 1:
        op = split.partition_predicate.constraints[0].op
    return (keeps, Bool(split.residual), op)


def _check_conservative(
    var filter: Expr,
    col: String,
    atype: ArrowType,
    file_value: String,
    label: String,
) raises:
    var r = _split_one(filter, col, atype, file_value)
    assert_true(r[0], label + String(": file pruned"))
    assert_true(r[1], label + String(": conjunct dropped from the residual"))
    assert_equal(r[2], _OP_OTHER, label + String(": not an OTHER constraint"))


def _check_clean(
    var filter: Expr,
    col: String,
    atype: ArrowType,
    file_value: String,
    label: String,
) raises:
    var r = _split_one(filter, col, atype, file_value)
    assert_true(r[0], label + String(": matching file pruned"))
    assert_false(r[1], label + String(": clean constraint left on the residual"))


def _eq(col: String, var v: ScalarValue) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(col), Expr.literal(v^))


# --- STRING / BOOL literal on an INT64 column -------------------------------


def test_string_literal_on_int64_col_is_conservative() raises:
    _check_conservative(
        _eq(String("yr"), ScalarValue.from_string(String("abc"))),
        String("yr"),
        ArrowType.INT64,
        String("0"),
        String("yr = 'abc'"),
    )


def test_decimal_text_literal_on_int64_col_is_conservative() raises:
    _check_conservative(
        _eq(String("yr"), ScalarValue.from_string(String("2020.0"))),
        String("yr"),
        ArrowType.INT64,
        String("0"),
        String("yr = '2020.0'"),
    )


def test_bool_literal_on_int64_col_is_conservative() raises:
    _check_conservative(
        _eq(String("yr"), ScalarValue.from_bool(True)),
        String("yr"),
        ArrowType.INT64,
        String("0"),
        String("yr = true"),
    )


# --- integer literal on a STRING / DATE32 / TIMESTAMP / BOOL column ----------


def test_int_literal_on_string_col_is_conservative() raises:
    _check_conservative(
        _eq(String("region"), ScalarValue.from_int(5)),
        String("region"),
        ArrowType.STRING,
        String("05"),
        String("region = 5"),
    )


def test_int_range_on_string_col_is_conservative() raises:
    _check_conservative(
        Expr.binary(
            BIN_LT,
            Expr.col_ref(String("region")),
            Expr.literal(ScalarValue.from_int(10)),
        ),
        String("region"),
        ArrowType.STRING,
        String("9"),
        String("region < 10"),
    )


def test_int_literal_on_the_left_of_string_col_is_conservative() raises:
    # 10 > region reads as region < 10.
    _check_conservative(
        Expr.binary(
            BIN_GT,
            Expr.literal(ScalarValue.from_int(10)),
            Expr.col_ref(String("region")),
        ),
        String("region"),
        ArrowType.STRING,
        String("9"),
        String("10 > region"),
    )


def test_int_literal_on_date32_col_is_conservative() raises:
    _check_conservative(
        _eq(String("dt"), ScalarValue.from_int(19000)),
        String("dt"),
        ArrowType.DATE32,
        String("2022-01-08"),
        String("dt = 19000"),
    )


def test_int_literal_on_timestamp_col_is_conservative() raises:
    _check_conservative(
        _eq(String("ts"), ScalarValue.from_int64(Int64(1641600000))),
        String("ts"),
        ArrowType.TIMESTAMP,
        String("2022-01-08 00:00:00"),
        String("ts = 1641600000"),
    )


def test_int_literal_on_bool_col_is_conservative() raises:
    _check_conservative(
        _eq(String("on"), ScalarValue.from_int(1)),
        String("on"),
        ArrowType.BOOL,
        String("true"),
        String("on = 1"),
    )


# --- the IN-list node and the OR-of-EQ chain --------------------------------


def _ints(a: Int, b: Int) -> List[ScalarValue]:
    var vs = List[ScalarValue]()
    vs.append(ScalarValue.from_int(a))
    vs.append(ScalarValue.from_int(b))
    return vs^


def test_int_in_list_node_on_string_col_is_conservative() raises:
    _check_conservative(
        Expr.in_list_node(Expr.col_ref(String("region")), _ints(5, 6)),
        String("region"),
        ArrowType.STRING,
        String("05"),
        String("region IN (5, 6) node"),
    )


def test_string_in_list_node_on_int64_col_is_conservative() raises:
    var vs = List[ScalarValue]()
    vs.append(ScalarValue.from_string(String("abc")))
    _check_conservative(
        Expr.in_list_node(Expr.col_ref(String("yr")), vs^),
        String("yr"),
        ArrowType.INT64,
        String("0"),
        String("yr IN ('abc') node"),
    )


def test_int_or_chain_on_string_col_is_conservative() raises:
    # `Expr.in_list` folds to `(region == 5) OR (region == 6)`.
    _check_conservative(
        Expr.in_list(Expr.col_ref(String("region")), _ints(5, 6)),
        String("region"),
        ArrowType.STRING,
        String("05"),
        String("region IN (5, 6) OR chain"),
    )


# --- matching kinds stay clean ----------------------------------------------


def test_matching_kinds_stay_clean() raises:
    _check_clean(
        _eq(String("yr"), ScalarValue.from_int(2020)),
        String("yr"),
        ArrowType.INT64,
        String("2020"),
        String("yr = 2020"),
    )
    _check_clean(
        _eq(String("region"), ScalarValue.from_string(String("05"))),
        String("region"),
        ArrowType.STRING,
        String("05"),
        String("region = '05'"),
    )
    _check_clean(
        _eq(String("dt"), ScalarValue.from_string(String("2022-01-08"))),
        String("dt"),
        ArrowType.DATE32,
        String("2022-01-08"),
        String("dt = '2022-01-08'"),
    )
    _check_clean(
        _eq(String("ts"), ScalarValue.from_string(String("2022-01-08 00:00:00"))),
        String("ts"),
        ArrowType.TIMESTAMP,
        String("2022-01-08 00:00:00"),
        String("ts = '2022-01-08 00:00:00'"),
    )
    _check_clean(
        _eq(String("on"), ScalarValue.from_bool(True)),
        String("on"),
        ArrowType.BOOL,
        String("true"),
        String("on = true"),
    )
    _check_clean(
        Expr.in_list(Expr.col_ref(String("yr")), _ints(2020, 2021)),
        String("yr"),
        ArrowType.INT64,
        String("2021"),
        String("yr IN (2020, 2021) OR chain"),
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_literal_on_int64_col_is_conservative]()
    suite.test[test_decimal_text_literal_on_int64_col_is_conservative]()
    suite.test[test_bool_literal_on_int64_col_is_conservative]()
    suite.test[test_int_literal_on_string_col_is_conservative]()
    suite.test[test_int_range_on_string_col_is_conservative]()
    suite.test[test_int_literal_on_the_left_of_string_col_is_conservative]()
    suite.test[test_int_literal_on_date32_col_is_conservative]()
    suite.test[test_int_literal_on_timestamp_col_is_conservative]()
    suite.test[test_int_literal_on_bool_col_is_conservative]()
    suite.test[test_int_in_list_node_on_string_col_is_conservative]()
    suite.test[test_string_in_list_node_on_int64_col_is_conservative]()
    suite.test[test_int_or_chain_on_string_col_is_conservative]()
    suite.test[test_matching_kinds_stay_clean]()
    suite^.run()
