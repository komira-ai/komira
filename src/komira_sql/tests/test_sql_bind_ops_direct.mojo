# =============================================================================
# Direct tests of operator lowering (sql_bind_ops)
# =============================================================================
#
# Operands are parsed from `SELECT <expr> FROM t` (columns i INT64, f FLOAT64,
# s STRING, ib INT64) and bound against that schema.
#   1. `_map_unop` / `_map_binop` / `_map_aggfunc` map each SQL code to its IR
#      code and refuse an unknown code, and the three operators that are not
#      plain binary nodes (`/`, `//`, `^`, `||`, `^@`) are refused with a
#      message naming the router that owns them.
#   2. `/` over two integers casts the left operand (true division); over a
#      float operand it stays a plain division. `//` over integers is a plain
#      division and over a float is a CASE guarding a zero divisor.
#   3. `^` is the math node, `^@` a starts-with predicate over a string
#      literal (a column pattern is refused), `||` is refused, `+` is a plain
#      node.
#   4. LIKE keeps the pattern; ILIKE folds the pattern and lower-cases the
#      child; NOT LIKE wraps the predicate in NOT.
#   5. An integer literal past BIGINT binds as a UINT64 literal as a comparison
#      operand beside a column, is refused past UBIGINT, and is not served as
#      an arithmetic operand.
#   6. `CAST(<int column> AS <int type>) <cmp> <literal>` unwraps only when the
#      literal fits the target type, the column is a signed integer and the
#      comparison is not NOT IN; an IN list unwraps one cast level only; a
#      constant added to or subtracted from the cast moves to the other side
#      unless that overflows the cast's range, or the cast is on the right of
#      a subtraction.
#   7. NULL comparisons are recognised on either side and bind with a typed
#      NULL on the right.
#   8. The post-aggregate typing schema lists the aggregates first, so an
#      aggregate named like an input column hides it.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import (
    AGG_COUNT, AGG_MAX, AGG_MEAN, AGG_MIN, AGG_SUM, AggExpr,
)
from komira_plan_expr.expr import (
    BIN_ADD, BIN_AND, BIN_DIV, BIN_EQ, BIN_GE, BIN_GT, BIN_LE, BIN_LT, BIN_MOD,
    BIN_MUL, BIN_NE, BIN_OR, BIN_SUB, EXPR_BINARY_OP, EXPR_CAST, EXPR_COL_REF,
    EXPR_LITERAL, EXPR_MATH_FN2, EXPR_STRING_FN, EXPR_STRING_OP, EXPR_UNARY_OP,
    EXPR_WHEN, Expr, MATH2_POW, STR_LIKE, STR_STARTS_WITH, UN_ABS,
    UN_IS_NOT_NULL, UN_IS_NULL, UN_NEGATE, UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import AggExprArray

from komira_sql.sql_ast import (
    SXAGG_AVG, SXAGG_COUNT, SXAGG_MAX, SXAGG_MIN, SXAGG_SUM, SXOP_ADD, SXOP_AND,
    SXOP_CONCAT, SXOP_DIV, SXOP_EQ, SXOP_GE, SXOP_GT, SXOP_IDIV, SXOP_LE,
    SXOP_LT, SXOP_MOD, SXOP_MUL, SXOP_NE, SXOP_OR, SXOP_POW, SXOP_STARTS_WITH,
    SXOP_SUB, SXUN_ABS, SXUN_IS_NOT_NULL, SXUN_IS_NULL, SXUN_NEGATE, SXUN_NOT,
    SX_BINARY, SqlExpr,
)
from komira_sql.sql_bind_ops import (
    _big_int_cmp_serves,
    _big_int_literal_refusal,
    _bind_big_int_uint64,
    _bind_like,
    _bind_sql_operator,
    _int_cast_arith_cmp,
    _int_cast_base_column,
    _int_cast_cmp_side,
    _is_null_comparison,
    _map_aggfunc,
    _map_binop,
    _map_unop,
    _null_comparison,
    _post_agg_typing_schema,
    _signed_int_cast_bits,
    _sx_is_big_int,
    _sxop_is_comparison,
)
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import BindScope, CteScope, _build_bind_scope
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("i"), ArrowType.INT64, True))
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    sb.add_field(Field(String("ib"), ArrowType.INT64, True))
    return sb.build()


def _scope() raises -> BindScope:
    var cat = SqlCatalog()
    cat.add_parquet("t", "t.parquet", _schema())
    var st = parse_sql(tokenize("SELECT i FROM t"))
    return _build_bind_scope(
        st.query.from_tables, st.query.joins, cat, CteScope(ParquetFacts())
    )


def _sx(expr: String) raises -> SqlExpr:
    var st = parse_sql(tokenize("SELECT " + expr + " FROM t"))
    return st.query.select_items[0].expr.copy()




def _unop_msg(op: UInt8) -> String:
    try:
        _ = _map_unop(op)
    except e:
        return String(e)
    return String("")


def _binop_msg(op: UInt8) -> String:
    try:
        _ = _map_binop(op)
    except e:
        return String(e)
    return String("")


def test_code_maps_and_their_refusals() raises:
    assert_equal(_map_unop(SXUN_NOT), UN_NOT)
    assert_equal(_map_unop(SXUN_IS_NULL), UN_IS_NULL)
    assert_equal(_map_unop(SXUN_IS_NOT_NULL), UN_IS_NOT_NULL)
    assert_equal(_map_unop(SXUN_NEGATE), UN_NEGATE)
    assert_equal(_map_unop(SXUN_ABS), UN_ABS)
    assert_true(_unop_msg(UInt8(200)).find("unknown unary operator code 200") >= 0)

    assert_equal(_map_binop(SXOP_EQ), BIN_EQ)
    assert_equal(_map_binop(SXOP_NE), BIN_NE)
    assert_equal(_map_binop(SXOP_LT), BIN_LT)
    assert_equal(_map_binop(SXOP_LE), BIN_LE)
    assert_equal(_map_binop(SXOP_GT), BIN_GT)
    assert_equal(_map_binop(SXOP_GE), BIN_GE)
    assert_equal(_map_binop(SXOP_AND), BIN_AND)
    assert_equal(_map_binop(SXOP_OR), BIN_OR)
    assert_equal(_map_binop(SXOP_ADD), BIN_ADD)
    assert_equal(_map_binop(SXOP_SUB), BIN_SUB)
    assert_equal(_map_binop(SXOP_MUL), BIN_MUL)
    assert_equal(_map_binop(SXOP_MOD), BIN_MOD)
    assert_true(_binop_msg(SXOP_DIV).find("must be bound by `_bind_sql_division`") >= 0)
    assert_true(_binop_msg(SXOP_IDIV).find("must be bound by `_bind_sql_division`") >= 0)
    assert_true(_binop_msg(SXOP_POW).find("must be bound by `_bind_sql_operator`") >= 0)
    assert_true(_binop_msg(SXOP_CONCAT).find("must be bound by `_bind_sql_operator`") >= 0)
    assert_true(_binop_msg(SXOP_STARTS_WITH).find("must be bound by `_bind_sql_operator`") >= 0)
    assert_true(_binop_msg(UInt8(250)).find("unsupported binary operator") >= 0)

    assert_equal(_map_aggfunc(SXAGG_SUM), AGG_SUM)
    assert_equal(_map_aggfunc(SXAGG_COUNT), AGG_COUNT)
    assert_equal(_map_aggfunc(SXAGG_MIN), AGG_MIN)
    assert_equal(_map_aggfunc(SXAGG_MAX), AGG_MAX)
    assert_equal(_map_aggfunc(SXAGG_AVG), AGG_MEAN)
    var raised = False
    try:
        _ = _map_aggfunc(UInt8(99))
    except e:
        raised = String(e).find("unsupported aggregate function") >= 0
    assert_true(raised)


def test_division_follows_the_operand_types() raises:
    var sch = _schema()
    var i = Expr.col_ref("i")
    var f = Expr.col_ref("f")
    var d = _bind_sql_operator(SXOP_DIV, i.copy(), i.copy(), sch)
    assert_equal(d.tag, EXPR_BINARY_OP)
    assert_equal(d.binary_op(), BIN_DIV)
    assert_equal(d.binary_left().tag, EXPR_CAST)
    var fd = _bind_sql_operator(SXOP_DIV, f.copy(), i.copy(), sch)
    assert_equal(fd.binary_op(), BIN_DIV)
    assert_equal(fd.binary_left().tag, EXPR_COL_REF)
    var idiv = _bind_sql_operator(SXOP_IDIV, i.copy(), i.copy(), sch)
    assert_equal(idiv.tag, EXPR_BINARY_OP)
    assert_equal(idiv.binary_op(), BIN_DIV)
    assert_equal(idiv.binary_left().tag, EXPR_COL_REF)
    var fidiv = _bind_sql_operator(SXOP_IDIV, f.copy(), i.copy(), sch)
    assert_equal(fidiv.tag, EXPR_WHEN)


def test_operator_router() raises:
    var sch = _schema()
    var pw = _bind_sql_operator(SXOP_POW, Expr.col_ref("i"), Expr.col_ref("i"), sch)
    assert_equal(pw.tag, EXPR_MATH_FN2)
    assert_equal(pw.math_fn2_op(), MATH2_POW)
    var sw = _bind_sql_operator(
        SXOP_STARTS_WITH, Expr.col_ref("s"), Expr.literal(ScalarValue.from_string("ab")), sch
    )
    assert_equal(sw.tag, EXPR_STRING_OP)
    assert_equal(sw.string_op_type(), STR_STARTS_WITH)
    assert_equal(sw.string_op_pattern(), "ab")
    var col_pattern = String("")
    try:
        _ = _bind_sql_operator(SXOP_STARTS_WITH, Expr.col_ref("s"), Expr.col_ref("s"), sch)
    except e:
        col_pattern = String(e)
    assert_true(col_pattern.find("right operand must be a string literal") >= 0)
    var concat = String("")
    try:
        _ = _bind_sql_operator(SXOP_CONCAT, Expr.col_ref("s"), Expr.col_ref("s"), sch)
    except e:
        concat = String(e)
    assert_true(concat.find("the `||` string-concatenation operator") >= 0)
    var add = _bind_sql_operator(SXOP_ADD, Expr.col_ref("i"), Expr.col_ref("i"), sch)
    assert_equal(add.binary_op(), BIN_ADD)
    assert_true(_sxop_is_comparison(SXOP_GE))
    assert_false(_sxop_is_comparison(SXOP_ADD))


def test_like_and_ilike() raises:
    var like = _bind_like(_sx("s LIKE 'Ab%'"), Expr.col_ref("s"))
    assert_equal(like.tag, EXPR_STRING_OP)
    assert_equal(like.string_op_type(), STR_LIKE)
    assert_equal(like.string_op_pattern(), "Ab%")
    assert_equal(like.string_op_child_ref().tag, EXPR_COL_REF)
    var ilike = _bind_like(_sx("s ILIKE 'ÄB%'"), Expr.col_ref("s"))
    assert_equal(ilike.string_op_pattern(), "äb%")
    assert_equal(ilike.string_op_child_ref().tag, EXPR_STRING_FN)
    var nlike = _bind_like(_sx("s NOT LIKE 'x'"), Expr.col_ref("s"))
    assert_equal(nlike.tag, EXPR_UNARY_OP)
    assert_equal(nlike.unary_op(), UN_NOT)
    assert_equal(nlike.unary_child_ref().string_op_pattern(), "x")


def test_big_integer_literals() raises:
    var eq = _sx("i = 18446744073709551615")
    assert_true(_big_int_cmp_serves(eq))
    ref r = eq._binary.value().right[]
    assert_true(_sx_is_big_int(r))
    var lit = _bind_big_int_uint64(r)
    assert_equal(lit.tag, EXPR_LITERAL)
    assert_true(lit.literal_value() == ScalarValue.from_uint64(UInt64.MAX))
    assert_true(_big_int_cmp_serves(_sx("18446744073709551615 < i")))
    assert_false(_big_int_cmp_serves(_sx("i + 18446744073709551615")))
    assert_false(_big_int_cmp_serves(_sx("i = 5")))
    assert_false(_big_int_cmp_serves(_sx("f + 1 = 18446744073709551615")))
    assert_false(_sx_is_big_int(_sx("5")))
    var past = _sx("i = 18446744073709551616")
    var refused = String("")
    try:
        _ = _bind_big_int_uint64(past._binary.value().right[])
    except e:
        refused = String(e)
    assert_true(refused.find("18446744073709551616 is past BIGINT") >= 0)
    assert_true(_big_int_literal_refusal(past._binary.value().right[]).find("<= 18446744073709551615") >= 0)


def test_cast_target_widths() raises:
    assert_equal(_signed_int_cast_bits("tinyint"), 8)
    assert_equal(_signed_int_cast_bits("int2"), 16)
    assert_equal(_signed_int_cast_bits("integer"), 32)
    assert_equal(_signed_int_cast_bits("long"), 64)
    assert_equal(_signed_int_cast_bits("double"), 0)
    assert_equal(_signed_int_cast_bits("utinyint"), 0)


def test_int_cast_comparison_unwrap() raises:
    var sc = _scope()
    var sch = _schema()
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS INTEGER) > 0"), sch, sc), 1)
    assert_equal(_int_cast_cmp_side(_sx("0 < CAST(ib AS INTEGER)"), sch, sc), 2)
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS TINYINT) > 127"), sch, sc), 1)
    # The literal does not fit the target; the cast target is not a signed
    # integer; the column is not an integer; the operator is not a comparison.
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS TINYINT) > 128"), sch, sc), 0)
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS INTEGER) > 3000000000"), sch, sc), 0)
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS DOUBLE) > 0"), sch, sc), 0)
    assert_equal(_int_cast_cmp_side(_sx("CAST(f AS INTEGER) > 0"), sch, sc), 0)
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS INTEGER) + 1"), sch, sc), 0)
    assert_equal(_int_cast_cmp_side(_sx("CAST(ib AS INTEGER) > 0.5"), sch, sc), 0)
    # A nested cast unwraps, except under an IN list; NOT IN never unwraps.
    var nested = _sx("CAST(CAST(ib AS INTEGER) AS BIGINT) > 0")
    assert_equal(_int_cast_cmp_side(nested, sch, sc), 1)
    assert_equal(_int_cast_base_column(nested._binary.value().left[]).text, "ib")
    var in_nested = nested.copy()
    in_nested.text = "in"
    assert_equal(_int_cast_cmp_side(in_nested, sch, sc), 0)
    var in_flat = _sx("CAST(ib AS INTEGER) > 0")
    in_flat.text = "in"
    assert_equal(_int_cast_cmp_side(in_flat, sch, sc), 1)
    var not_in = _sx("CAST(ib AS INTEGER) > 0")
    not_in.text = "not in"
    assert_equal(_int_cast_cmp_side(not_in, sch, sc), 0)


def test_int_cast_constant_moves_across_the_comparison() raises:
    var sc = _scope()
    var sch = _schema()
    var add = _int_cast_arith_cmp(_sx("CAST(ib AS INTEGER) + 1 > 0"), sch, sc)
    assert_true(Bool(add))
    assert_equal(add.value().op, SXOP_GT)
    assert_equal(add.value()._binary.value().right[].int_val, -1)
    var sub = _int_cast_arith_cmp(_sx("CAST(ib AS INTEGER) - 1 > 0"), sch, sc)
    assert_equal(sub.value()._binary.value().right[].int_val, 1)
    var lead = _int_cast_arith_cmp(_sx("1 + CAST(ib AS INTEGER) <= 5"), sch, sc)
    assert_equal(lead.value().op, SXOP_LE)
    assert_equal(lead.value()._binary.value().right[].int_val, 4)
    var flipped = _int_cast_arith_cmp(_sx("0 < CAST(ib AS INTEGER) + 1"), sch, sc)
    assert_equal(flipped.value().op, SXOP_LT)
    assert_equal(flipped.value()._binary.value().left[].int_val, -1)
    # `1 - CAST(...)` would flip the comparison, the moved constant may leave
    # the cast's range, and an IN list moves no constant.
    assert_false(Bool(_int_cast_arith_cmp(_sx("1 - CAST(ib AS INTEGER) > 0"), sch, sc)))
    assert_false(Bool(_int_cast_arith_cmp(_sx("CAST(ib AS INTEGER) - 1 > 2147483647"), sch, sc)))
    assert_true(Bool(_int_cast_arith_cmp(_sx("CAST(ib AS INTEGER) + 1 > 2147483647"), sch, sc)))
    assert_false(Bool(_int_cast_arith_cmp(_sx("CAST(ib AS INTEGER) * 2 > 0"), sch, sc)))
    assert_false(Bool(_int_cast_arith_cmp(_sx("ib + 1 > 0"), sch, sc)))
    var in_list = _sx("CAST(ib AS INTEGER) + 1 > 0")
    in_list.text = "in"
    assert_false(Bool(_int_cast_arith_cmp(in_list, sch, sc)))
    assert_false(Bool(_int_cast_arith_cmp(_sx("CAST(ib AS INTEGER) + 1"), sch, sc)))


def test_null_comparisons() raises:
    assert_true(_is_null_comparison(_sx("i = NULL")))
    assert_true(_is_null_comparison(_sx("NULL < i")))
    assert_false(_is_null_comparison(_sx("i = 1")))
    assert_false(_is_null_comparison(_sx("i + NULL")))
    assert_false(_is_null_comparison(_sx("i")))
    var e = _null_comparison(SXOP_LT, Expr.col_ref("i"))
    assert_equal(e.binary_op(), BIN_LT)
    assert_equal(e.binary_left().tag, EXPR_COL_REF)
    assert_true(e.binary_right().literal_value().is_null())


def test_post_aggregate_typing_schema_puts_aggregates_first() raises:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](Expr.col_ref("i")), Optional[String](String("f"))))
    var t = _post_agg_typing_schema(_schema(), aggs)
    assert_equal(t.num_columns(), 5)
    assert_equal(t.field_name(0), "f")
    assert_true(t.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(t.field_name(1), "i")
    assert_equal(t.field_name(2), "f")
    assert_true(t.field_arrow_type(2) == ArrowType.FLOAT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
