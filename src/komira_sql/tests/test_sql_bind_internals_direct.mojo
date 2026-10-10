# =============================================================================
# Direct tests of binder internals that SQL text cannot reach
# (sql_bind_ops, sql_bind_fn_args, sql_bind_fn_nested, sql_bind_cast,
#  sql_bind_expr, sql_bind_scope, sql_bind_subquery, sql_bind_join,
#  sql_bind_window_order, sql_bind_names)
# =============================================================================
#
# The parser never builds these shapes, so each is called directly with a
# hand-built node. These are the defensive arms: an operator or kind code no
# lowering knows, a desugar handed the wrong argument shape, a scope lookup
# that misses. What each test proves, and the defect (mutant) it would catch:
#   1. The code maps (`_map_unop`, `_map_binop`, `_map_aggfunc`,
#      `_outer_join_type`, `_map_win_func`) raise by name on a code they do
#      not know, and `_map_binop` refuses the operators it must never see.
#      (mutant: `_map_unop` returns UN_NOT for an unknown code)
#   2. `_fn_arity_msg` has a message per lowering family and an internal one
#      for a kind with none.
#   3. The date folds refuse a wrong argument count, a unit other than
#      `day` and a non-DATE operand; the DATE32 / float / string predicates
#      see through an alias and answer False for other shapes.
#      (mutant: `_bound_expr_is_date32` drops its alias arm)
#   4. `_bind_scalar` refuses `*`, a CASE with no WHEN and an unknown node
#      tag; the CAST desugar refuses a wrong argument shape; a DECIMAL type
#      name with no closing parenthesis is refused.
#   5. `BindScope` lookups that miss answer "" / the name itself;
#      `_result_rename_exprs` answers None when the names do not line up.
#   6. `_rel_col_null_free` answers False for a CSV relation without reading
#      it; `_body_has_equi_correlation` answers False for a body with no
#      WHERE; `_bind_corr_scalar` refuses a dangling subquery index.
#   7. The deparse helpers name every SX_AGG code, and the constant arms.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_sql.sql_ast import (
    FromRelation,
    JK_CROSS,
    SX_BOOL,
    SXAGG_AVG,
    SXAGG_COUNT,
    SXAGG_MAX,
    SXAGG_MIN,
    SXAGG_SUM,
    SXOP_CONCAT,
    SXOP_DIV,
    SXOP_IDIV,
    SXOP_POW,
    SXOP_STARTS_WITH,
    SqlExpr,
    TVF_CSV,
    TvfOptions,
)
from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_fn_table import (
    CAST_DESUGAR_NAME,
    FNK_EXTRACT_FIELD,
    FNK_NONE,
    FNK_STRING_PRED,
)
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import (
    BindScope,
    CteScope,
    _build_bind_scope,
    _result_rename_exprs,
)
from komira_sql.sql_bind_ops import _map_aggfunc, _map_binop, _map_unop
from komira_sql.sql_bind_fn_args import _date_diff_days, _fn_arity_msg
from komira_sql.sql_bind_fn_nested import (
    _bound_expr_is_date32,
    _col_arrow_type_by_name,
    _date_sub_days,
)
from komira_sql.sql_bind_cast import _bound_expr_is_string, _sql_decimal_type_ps
from komira_sql.sql_bind_expr import _bind_scalar, _bound_expr_is_float
from komira_sql.sql_bind_subquery import (
    _bind_corr_scalar,
    _body_has_equi_correlation,
    _rel_col_null_free,
)
from komira_sql.sql_bind_join import _outer_join_type
from komira_sql.sql_bind_window_order import _map_win_func, _win_value_default
from komira_sql.sql_bind_names import _duckdb_const_text, _duckdb_expr_text, _sxagg_text


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


def test_code_maps_refuse_unknown_codes() raises:
    try:
        _ = _map_unop(UInt8(99))
        raise Error("mapped")
    except e:
        _raised(String(e), "SQL internal error: unknown unary operator code 99")
    try:
        _ = _map_binop(SXOP_DIV)
        raise Error("mapped")
    except e:
        _raised(
            String(e),
            "SQL internal: a division operator reached the plain operator map;"
            " it must be bound by `_bind_sql_division` (DuckDB's `/` is TRUE"
            " division and its `//` is `divide()`)",
        )
    try:
        _ = _map_binop(SXOP_IDIV)
        raise Error("mapped")
    except e:
        assert_true(String(e).startswith("SQL internal: a division operator"))
    for op in [SXOP_POW, SXOP_CONCAT, SXOP_STARTS_WITH]:
        try:
            _ = _map_binop(op)
            raise Error("mapped")
        except e:
            _raised(
                String(e),
                "SQL internal: a `^` / `^@` / `||` operator reached the plain"
                " operator map; it must be bound by `_bind_sql_operator`",
            )
    try:
        _ = _map_binop(UInt8(99))
        raise Error("mapped")
    except e:
        _raised(String(e), "SQL bind error: unsupported binary operator")
    try:
        _ = _map_aggfunc(UInt8(99))
        raise Error("mapped")
    except e:
        _raised(String(e), "SQL bind error: unsupported aggregate function")
    try:
        _ = _outer_join_type(JK_CROSS)
        raise Error("mapped")
    except e:
        _raised(
            String(e),
            "SQL bind error: _outer_join_type was handed join kind "
            + String(Int(JK_CROSS)) + ", which is not LEFT / RIGHT / FULL",
        )
    try:
        _ = _map_win_func(UInt8(99))
        raise Error("mapped")
    except e:
        _raised(String(e), "SQL bind error: unsupported window function code 99")


def test_window_default_of_an_unknown_kind_is_refused() raises:
    var st = parse_sql(tokenize("SELECT lag(v, 1, 0) OVER (ORDER BY k) FROM t"))
    var w = st.query.select_items[0].expr._window.value().copy()
    w.default_kind = SX_BOOL
    try:
        _ = _win_value_default(w)
        raise Error("mapped")
    except e:
        _raised(
            String(e),
            "SQL bind error: unsupported DEFAULT literal kind "
            + String(Int(SX_BOOL)),
        )


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
            " literal operands at this call site. ⚠ NOT A LIMIT OF date_sub:"
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


def test_scope_lookups_that_miss() raises:
    var cat = _catalog()
    var cte = CteScope(ParquetFacts())
    var scope = _scope_over_t(cat, cte)
    assert_equal(scope.source_name_of("zz", "k"), "")
    assert_equal(scope.source_name_of("t", "zz"), "")
    assert_equal(scope.source_name_of("t", "K"), "k")
    assert_equal(scope.source_name_of_output("nope"), "nope")
    var display = List[String]()
    display.append(String("a"))
    assert_false(Bool(_result_rename_exprs(scope.out_schema, display, 2)))
    assert_false(Bool(_result_rename_exprs(scope.out_schema, display, 9)))
    var same = List[String]()
    same.append(String(""))
    assert_false(Bool(_result_rename_exprs(scope.out_schema, same, 1)))


def test_subquery_helpers_without_reading_files() raises:
    var cat = _catalog()
    var cte = CteScope(ParquetFacts())
    var csv = FromRelation.tvf_of("x.csv", TVF_CSV, TvfOptions())
    assert_false(_rel_col_null_free(csv, "k", cat, cte))
    var unknown = FromRelation.named("missing")
    assert_false(_rel_col_null_free(unknown, "k", cat, cte))
    var body = parse_sql(tokenize("SELECT k FROM t"))
    var pre = List[Expr]()
    assert_false(_body_has_equi_correlation(body.query, cat, cte, pre))
    var refs = List[String]()
    var aliases = List[String]()
    aliases.append(String("t"))
    try:
        _ = _bind_corr_scalar(
            SqlExpr.subquery(5), _schema(), aliases, refs, cat, cte, pre
        )
        raise Error("bound")
    except e:
        _raised(
            String(e),
            "SQL bind error: dangling subquery index in correlated subquery",
        )


def test_deparse_constants_and_aggregate_codes() raises:
    assert_equal(String(_sxagg_text(SXAGG_SUM)), "sum")
    assert_equal(String(_sxagg_text(SXAGG_COUNT)), "count")
    assert_equal(String(_sxagg_text(SXAGG_MIN)), "min")
    assert_equal(String(_sxagg_text(SXAGG_MAX)), "max")
    assert_equal(String(_sxagg_text(SXAGG_AVG)), "avg")
    assert_equal(String(_duckdb_const_text(UInt8(4))), "?column?")
    assert_equal(String(_duckdb_const_text(UInt8(3))), "(SELECT ...)")
    assert_equal(String(_duckdb_const_text(UInt8(0))), "*")
    # An aggregate node built with no source spelling is named by its code.
    assert_equal(_duckdb_expr_text(SqlExpr.agg(SXAGG_AVG, SqlExpr.column("v"))), "avg(v)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
