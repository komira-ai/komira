# =============================================================================
# test_partition_predicate_split_ops.mojo
# =============================================================================
# `split_partition_predicate` over every comparison op on a partition column
# and over the literal kinds whose text form the fold matches:
#   * column-on-the-left: LT/LE/GT/GE/NE each map to their own fold op code
#     (2/3/4/5/6), EQ to the EQ factory;
#   * literal-on-the-left: LT<->GT and LE<->GE swap, EQ and NE stay;
#   * BOOL literals render as `true` / `false`;
#   * narrow and unsigned integer literals (int8 .. uint32, outside
#     `is_int`) render as their decimal value.
# Each case pins the column, the op code, the single value, the column's
# type (yr INT64, flag STRING: flag is the second partition column, so a
# lookup of the wrong index is caught) and that nothing is left on the
# residual (a clean comparison is consumed by Tier-1).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_fs.pruned_hive_discovery import (
    _OP_EQ,
    _OP_LT,
    _OP_LE,
    _OP_GT,
    _OP_GE,
    _OP_NE,
)
from komira_scan_planning.partition_predicate_split import (
    split_partition_predicate,
)


def _pcols() -> List[String]:
    var c = List[String]()
    c.append(String("yr"))
    c.append(String("flag"))
    return c^


def _ptypes() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.STRING)
    return t^


def _check_one(
    filter: Expr,
    col: String,
    op: Int,
    value: String,
    atype: ArrowType = ArrowType.INT64,
) raises:
    var split = split_partition_predicate(filter, _pcols(), _ptypes())
    assert_equal(split.partition_predicate.num_constraints(), 1)
    ref c = split.partition_predicate.constraints[0]
    assert_equal(c.col, col)
    assert_equal(c.op, op)
    assert_equal(len(c.values), 1)
    assert_equal(c.values[0], value)
    # The type is the column's own: a wrong type turns the fold's numeric
    # compare into a lexical one (`yr < 10` typed STRING would prune yr=9).
    assert_true(c.arrow_type == atype)
    assert_false(Bool(split.residual))


def _col_op_lit(op: UInt8, v: Int) -> Expr:
    return Expr.binary(
        op, Expr.col_ref(String("yr")), Expr.literal(ScalarValue.from_int(v))
    )


def _lit_op_col(op: UInt8, v: Int) -> Expr:
    return Expr.binary(
        op, Expr.literal(ScalarValue.from_int(v)), Expr.col_ref(String("yr"))
    )


def test_col_left_each_op_maps_to_its_code() raises:
    _check_one(_col_op_lit(BIN_EQ, 1), String("yr"), _OP_EQ, String("1"))
    _check_one(_col_op_lit(BIN_LT, 2), String("yr"), _OP_LT, String("2"))
    _check_one(_col_op_lit(BIN_LE, 3), String("yr"), _OP_LE, String("3"))
    _check_one(_col_op_lit(BIN_GT, 4), String("yr"), _OP_GT, String("4"))
    _check_one(_col_op_lit(BIN_GE, 5), String("yr"), _OP_GE, String("5"))
    _check_one(_col_op_lit(BIN_NE, 6), String("yr"), _OP_NE, String("6"))


def test_literal_left_flips_each_op() raises:
    # `v <op> yr` reads as `yr <flipped op> v`.
    _check_one(_lit_op_col(BIN_EQ, 1), String("yr"), _OP_EQ, String("1"))
    _check_one(_lit_op_col(BIN_LT, 2), String("yr"), _OP_GT, String("2"))
    _check_one(_lit_op_col(BIN_LE, 3), String("yr"), _OP_GE, String("3"))
    _check_one(_lit_op_col(BIN_GT, 4), String("yr"), _OP_LT, String("4"))
    _check_one(_lit_op_col(BIN_GE, 5), String("yr"), _OP_LE, String("5"))
    _check_one(_lit_op_col(BIN_NE, 6), String("yr"), _OP_NE, String("6"))


def test_bool_literals_render_true_false() raises:
    _check_one(
        Expr.binary(
            BIN_EQ,
            Expr.col_ref(String("flag")),
            Expr.literal(ScalarValue.from_bool(True)),
        ),
        String("flag"),
        _OP_EQ,
        String("true"),
        ArrowType.STRING,
    )
    _check_one(
        Expr.binary(
            BIN_NE,
            Expr.col_ref(String("flag")),
            Expr.literal(ScalarValue.from_bool(False)),
        ),
        String("flag"),
        _OP_NE,
        String("false"),
        ArrowType.STRING,
    )


def test_literal_left_on_second_col_takes_its_type() raises:
    # `'x' < flag` reads as `flag > 'x'` and carries flag's STRING type, not
    # the first column's INT64.
    _check_one(
        Expr.binary(
            BIN_LT,
            Expr.literal(ScalarValue.from_string(String("x"))),
            Expr.col_ref(String("flag")),
        ),
        String("flag"),
        _OP_GT,
        String("x"),
        ArrowType.STRING,
    )


def _yr_eq(var v: ScalarValue) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(String("yr")), Expr.literal(v^))


def test_narrow_and_unsigned_ints_render_decimal() raises:
    _check_one(
        _yr_eq(ScalarValue.from_int8(Int8(-5))), String("yr"), _OP_EQ, String("-5")
    )
    _check_one(
        _yr_eq(ScalarValue.from_int16(Int16(-300))),
        String("yr"),
        _OP_EQ,
        String("-300"),
    )
    _check_one(
        _yr_eq(ScalarValue.from_uint16(UInt16(65535))),
        String("yr"),
        _OP_EQ,
        String("65535"),
    )
    _check_one(
        _yr_eq(ScalarValue.from_uint32(UInt32(4000000000))),
        String("yr"),
        _OP_EQ,
        String("4000000000"),
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_col_left_each_op_maps_to_its_code]()
    suite.test[test_literal_left_flips_each_op]()
    suite.test[test_bool_literals_render_true_false]()
    suite.test[test_literal_left_on_second_col_takes_its_type]()
    suite.test[test_narrow_and_unsigned_ints_render_decimal]()
    suite^.run()
