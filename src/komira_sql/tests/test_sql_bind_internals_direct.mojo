# =============================================================================
# Tests of expression-binder internals that SQL text cannot reach
# (sql_bind_fn_args, sql_bind_fn_nested, sql_bind_cast, sql_bind_expr)
# =============================================================================
#
# The parser never builds these shapes, so each is called directly with a
# hand-built node. These are the defensive arms: a desugar handed the wrong
# argument shape, a kind with no arity message, a node tag no lowering knows.
#   1. `_fn_arity_msg` has a message per lowering family and an internal one
#      for a kind with none.
#   2. The date folds refuse a wrong argument count, a unit other than `day`
#      and an operand that is not a DATE literal, and fold two DATE literals.
#   3. The DATE32 / float / string predicates see through an alias and answer
#      False for other shapes; a column lookup that misses answers NULL / the
#      absent-column type.
#   4. `_bind_scalar` refuses `*`, a CASE with no WHEN and an unknown node tag,
#      resolves a scalar-subquery node by its index into the bodies bound
#      first and refuses a dangling index; the CAST desugar refuses a wrong
#      argument shape; a DECIMAL type name with no closing parenthesis is
#      refused.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue

from komira_sql.sql_ast import SqlExpr
from komira_sql.sql_bind_cast import _bound_expr_is_string, _sql_decimal_type_ps
from komira_sql.sql_bind_expr import _bind_scalar, _bound_expr_is_float
from komira_sql.sql_bind_fn_args import _date_diff_days, _fn_arity_msg
from komira_sql.sql_bind_fn_nested import (
    _bound_expr_is_date32,
    _col_arrow_type_by_name,
    _date_sub_days,
)
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import BindScope, CteScope, _build_bind_scope
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    CAST_DESUGAR_NAME,
    FNK_EXTRACT_FIELD,
    FNK_NONE,
    FNK_STRING_PRED,
)
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    sb.add_field(Field(String("d"), ArrowType.DATE32, True))
    return sb.build()


def _catalog() -> SqlCatalog:
    var cat = SqlCatalog()
    cat.add_parquet(String("t"), String("t.parquet"), _schema())
    return cat^


def _raised(msg: String, want: String) raises:
    assert_equal(msg, want)


def _call(name: String, var args: Slab[SqlExpr]) -> SqlExpr:
    return SqlExpr.call(name, args^)


def test_arity_messages_per_family() raises:
    assert_equal(
        _fn_arity_msg("contains", FNK_STRING_PRED, 3),
        "SQL bind error: contains() expects exactly 2 arguments (string,"
        " pattern) — got 3",
    )
    assert_equal(
        _fn_arity_msg("year", FNK_EXTRACT_FIELD, 2),
        "SQL bind error: year() expects exactly 1 argument (a DATE or"
        " TIMESTAMP expression) — got 2",
    )
    assert_equal(
        _fn_arity_msg("x", FNK_NONE, 2),
        "SQL internal: no arity message for lowering kind "
        + String(Int(FNK_NONE)) + " (function 'x', 2 argument(s))",
    )


def test_date_folds_refuse_wrong_shapes() raises:
    var two = Slab[SqlExpr]()
    two.append(SqlExpr.string_lit("day"))
    two.append(SqlExpr.date_lit("2021-01-01"))
    try:
        _ = _date_diff_days(_call("date_diff", two^))
        raise Error("folded")
    except e:
        _raised(
            String(e),
            "SQL bind error: date_diff expects 3 arguments (unit, start, end)",
        )
    try:
        var two2 = Slab[SqlExpr]()
        two2.append(SqlExpr.string_lit("day"))
        two2.append(SqlExpr.date_lit("2021-01-01"))
        _ = _date_sub_days(_call("date_sub", two2^))
        raise Error("folded")
    except e:
        _raised(
            String(e),
            "SQL bind error: date_sub expects 3 arguments (unit, start, end)",
        )
    var month = Slab[SqlExpr]()
    month.append(SqlExpr.string_lit("month"))
    month.append(SqlExpr.date_lit("2021-01-01"))
    month.append(SqlExpr.date_lit("2021-02-01"))
    try:
        _ = _date_sub_days(_call("date_sub", month^))
        raise Error("folded")
    except e:
        assert_true(
            String(e).startswith(
                "SQL not supported: only date_sub('day', ...) is supported."
            ),
            String(e),
        )
    var col = Slab[SqlExpr]()
    col.append(SqlExpr.string_lit("day"))
    col.append(SqlExpr.column("d"))
    col.append(SqlExpr.date_lit("2021-02-01"))
    try:
        _ = _date_sub_days(_call("date_sub", col^))
        raise Error("folded")
    except e:
        _raised(
            String(e),
            "SQL not supported: date_sub('day', a, b) requires constant DATE"
            " literal operands at this call site. NOT A LIMIT OF date_sub:"
            " in an ordinary projection or filter it reads DATE columns"
            " (`_bind_date_delta`)",
        )
    var ok = Slab[SqlExpr]()
    ok.append(SqlExpr.string_lit("day"))
    ok.append(SqlExpr.date_lit("2021-01-01"))
    ok.append(SqlExpr.date_lit("2021-02-01"))
    assert_equal(_date_sub_days(_call("date_sub", ok^)), Int64(31))


def test_type_predicates_see_through_an_alias() raises:
    var sch = _schema()
    assert_true(_bound_expr_is_date32(Expr.alias(Expr.col_ref("d"), "x"), sch))
    assert_false(_bound_expr_is_date32(Expr.alias(Expr.col_ref("k"), "x"), sch))
    assert_false(
        _bound_expr_is_date32(
            Expr.binary(UInt8(0), Expr.col_ref("d"), Expr.col_ref("d")), sch
        )
    )
    assert_true(_col_arrow_type_by_name(sch, "zz") == ArrowType.NULL)
    assert_true(_col_arrow_type_by_name(sch, "D") == ArrowType.DATE32)
    assert_true(_bound_expr_is_float(Expr.alias(Expr.col_ref("v"), "x"), sch))
    assert_false(_bound_expr_is_float(Expr.col_ref("zz"), sch))
    assert_true(
        _bound_expr_is_float(
            Expr.binary(UInt8(0), Expr.col_ref("k"), Expr.col_ref("v")), sch
        )
    )
    assert_false(
        _bound_expr_is_float(
            Expr.binary(UInt8(0), Expr.col_ref("k"), Expr.col_ref("k")), sch
        )
    )
    assert_false(
        _bound_expr_is_float(Expr.unary(UInt8(0), Expr.col_ref("v")), sch)
    )
    assert_true(_bound_expr_is_string(Expr.alias(Expr.col_ref("s"), "x"), sch))
    assert_false(
        _bound_expr_is_string(Expr.unary(UInt8(0), Expr.col_ref("s")), sch)
    )
    assert_false(_bound_expr_is_string(Expr.col_ref("zz"), sch))


def _scope_over_t(cat: SqlCatalog, cte: CteScope) raises -> BindScope:
    var st = parse_sql(tokenize("SELECT k FROM t"))
    return _build_bind_scope(st.query.from_tables, st.query.joins, cat, cte)


def test_scalar_binder_refuses_unparseable_shapes() raises:
    var cat = _catalog()
    var cte = CteScope(ParquetFacts())
    var scope = _scope_over_t(cat, cte)
    var pre = List[Expr]()
    try:
        _ = _bind_scalar(SqlExpr.star(), scope.out_schema, scope, cat, cte, pre)
        raise Error("bound")
    except e:
        _raised(String(e), "SQL bind error: '*' not allowed in this position")
    try:
        _ = _bind_scalar(SqlExpr(UInt8(200)), scope.out_schema, scope, cat, cte, pre)
        raise Error("bound")
    except e:
        _raised(String(e), "SQL bind error: unsupported expression")
    var empty_case = SqlExpr.case(Slab[SqlExpr](), Slab[SqlExpr](), Slab[SqlExpr]())
    try:
        _ = _bind_scalar(empty_case, scope.out_schema, scope, cat, cte, pre)
        raise Error("bound")
    except e:
        _raised(String(e), "SQL bind error: CASE requires at least one WHEN branch")
    var one = Slab[SqlExpr]()
    one.append(SqlExpr.column("k"))
    try:
        _ = _bind_scalar(
            _call(CAST_DESUGAR_NAME, one^), scope.out_schema, scope, cat, cte, pre
        )
        raise Error("bound")
    except e:
        _raised(
            String(e),
            "SQL bind error: the CAST desugar takes an expression and a type"
            " name; got 1 argument(s)",
        )
    var notype = Slab[SqlExpr]()
    notype.append(SqlExpr.column("k"))
    notype.append(SqlExpr.int_lit(5))
    try:
        _ = _bind_scalar(
            _call(CAST_DESUGAR_NAME, notype^), scope.out_schema, scope, cat, cte, pre
        )
        raise Error("bound")
    except e:
        _raised(
            String(e),
            "SQL bind error: the CAST desugar's second argument must be the"
            " target type name as a string literal",
        )
    try:
        _ = _sql_decimal_type_ps("decimal(5")
        raise Error("parsed")
    except e:
        _raised(
            String(e),
            "SQL bind error: malformed DECIMAL type 'DECIMAL(5'; want"
            " DECIMAL(<precision>) or DECIMAL(<precision>,<scale>)",
        )


def test_date_diff_fold_refuses_other_units_and_operands() raises:
    var month = Slab[SqlExpr]()
    month.append(SqlExpr.string_lit("month"))
    month.append(SqlExpr.date_lit("2021-01-01"))
    month.append(SqlExpr.date_lit("2021-02-01"))
    try:
        _ = _date_diff_days(_call("date_diff", month^))
        raise Error("folded")
    except e:
        _raised(
            String(e),
            "SQL not supported: only date_diff('day', ...) is supported (got"
            " unit that is not the constant 'day')",
        )
    var col = Slab[SqlExpr]()
    col.append(SqlExpr.string_lit("day"))
    col.append(SqlExpr.column("d"))
    col.append(SqlExpr.date_lit("2021-02-01"))
    try:
        _ = _date_diff_days(_call("date_diff", col^))
        raise Error("folded")
    except e:
        assert_true(
            String(e).startswith(
                "SQL not supported: date_diff('day', a, b) requires constant"
                " DATE literal operands here. This function only constant-folds two"
                " DATE literals and binds no column operand."
            ),
            String(e),
        )
    var ok = Slab[SqlExpr]()
    ok.append(SqlExpr.string_lit("day"))
    ok.append(SqlExpr.date_lit("2021-01-01"))
    ok.append(SqlExpr.date_lit("2021-02-01"))
    assert_equal(_date_diff_days(_call("date_diff", ok^)), Int64(31))


def test_scalar_subquery_node_resolves_by_index() raises:
    var cat = _catalog()
    var cte = CteScope(ParquetFacts())
    var scope = _scope_over_t(cat, cte)
    var pre = List[Expr]()
    pre.append(Expr.literal(ScalarValue.from_int64(Int64(7))))
    var got = _bind_scalar(SqlExpr.subquery(0), scope.out_schema, scope, cat, cte, pre)
    assert_equal(String(got), "Literal(ScalarValue(int64, 7))")
    try:
        _ = _bind_scalar(SqlExpr.subquery(1), scope.out_schema, scope, cat, cte, pre)
        raise Error("bound")
    except e:
        _raised(String(e), "SQL bind error: dangling scalar-subquery index")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
