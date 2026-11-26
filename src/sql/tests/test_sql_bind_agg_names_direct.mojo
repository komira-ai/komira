# =============================================================================
# Direct tests of aggregate binding: aggregate calls, the post-aggregate
# expressions, GROUP BY resolution and HAVING
# (sql_bind_agg_expr, sql_bind_aggregate)
# =============================================================================
#
# Each query is parsed and bound by a small local pipeline (scan, WHERE, the
# aggregate or projection binder, ORDER BY, LIMIT) over one table; the test
# compares the plan text or the binder's message.
#   1. Each arity refusal names the spelling written.
#   2. Unaliased aggregates are named by their deparse (`count_star()`,
#      `sum(v)`, `mean(v)`).
#   3. One accumulator per distinct aggregate (the alias is not identity, the
#      child slots are).
#   4. HAVING binds over the group keys and the aggregate outputs.
#
# Kept apart from test_sql_bind_agg_direct.mojo:
# Mojo 1.2.0 does not finish compiling the two as one file, while each
# compiles in minutes.

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray, JOIN_CROSS, LogicalPlan

from sql.sql_ast import JK_CROSS, SX_COLUMN, SelectStmt
from sql.sql_bind_aggregate import _bind_aggregate, _bind_projection
from sql.sql_bind_expr import _bind_scalar
from sql.sql_bind_parquet import ParquetFacts
from sql.sql_bind_scope import (
    CteScope, _build_bind_scope, _dedupe_join_right, _relation_scan,
)
from sql.sql_bind_window_order import (
    _OK_COLUMN, _OK_OUTPUT, _bind_order, _bind_window_projection,
    _classify_order_keys, _has_window, _order_key_name, _order_output_column,
)
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _two(
    mut cat: SqlCatalog,
    name: String,
    c0: String,
    t0: ArrowType,
    c1: String,
    t1: ArrowType,
):
    """Register parquet table `name`(c0 NOT NULL, c1 NULL)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(c0, t0, False))
    sb.add_field(Field(c1, t1, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """t(k, v, s, g, d, ts, i32, dc, b, f32, u64, j), u(k, w, s), kk(k, a),
    mm(k, b), up(K, B), kk2(k, k_right): parquet tables with given schemas
    (no file is opened)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    t.add_field(Field(String("g"), ArrowType.INT64, True))
    t.add_field(Field(String("d"), ArrowType.DATE32, True))
    t.add_field(Field.timestamp(String("ts"), ArrowType.TIMESTAMP_US, String(""), True))
    t.add_field(Field(String("i32"), ArrowType.INT32, True))
    t.add_field(Field.decimal128(String("dc"), 12, 2, True))
    t.add_field(Field(String("b"), ArrowType.BOOL, True))
    t.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    t.add_field(Field(String("u64"), ArrowType.UINT64, True))
    t.add_field(Field(String("j"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    u.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    _two(cat, "kk", "k", ArrowType.INT64, "a", ArrowType.INT64)
    _two(cat, "mm", "k", ArrowType.INT64, "b", ArrowType.INT64)
    _two(cat, "up", "K", ArrowType.INT64, "B", ArrowType.INT64)
    _two(cat, "kk2", "k", ArrowType.INT64, "k_right", ArrowType.INT64)
    return cat^


def _select(stmt: SelectStmt, cat: SqlCatalog) raises -> LogicalPlan:
    """Bind one single-table SELECT the way the statement binder will: scan,
    WHERE, then the window, aggregate or plain projection, DISTINCT, ORDER BY,
    LIMIT, and the final prune of the columns carried only for the sort. The
    pieces under test are the modules this file imports."""
    if len(stmt.from_tables) == 0:
        raise Error("SQL bind error: FROM clause has no tables")
    var cte = CteScope(ParquetFacts())
    var prebound = List[Expr]()
    var scope = _build_bind_scope(stmt.from_tables, stmt.joins, cat, cte)
    var plan = _relation_scan(stmt.from_tables[0], cat, cte)
    for i in range(1, len(stmt.from_tables)):
        if stmt.joins[i - 1].kind != JK_CROSS or stmt.joins[i - 1].is_keyed():
            raise Error("test harness: cross joins only")
        var right = _relation_scan(stmt.from_tables[i], cat, cte)
        right = _dedupe_join_right(plan.output_schema, right^, List[String]())
        plan = LogicalPlan.join(
            plan^, right^, List[String](), List[String](), JOIN_CROSS
        )
    var schema = scope.out_schema.copy()
    if stmt.where_pred:
        var pred = _bind_scalar(stmt.where_pred.value(), schema, scope, cat, cte, prebound)
        plan = LogicalPlan.filter(pred^, plan^)
    var has_agg = False
    for i in range(len(stmt.select_items)):
        if (not stmt.select_items[i].is_star) and stmt.select_items[i].expr.contains_aggregate():
            has_agg = True
    var grouped = len(stmt.group_by) > 0
    var has_window = _has_window(stmt)
    var order_names = List[String]()
    if not stmt.distinct:
        for i in range(len(stmt.order_by)):
            ref okx = stmt.order_by[i]
            if okx.expr.tag == SX_COLUMN:
                order_names.append(_order_key_name(okx.expr, scope))
    var order_carry = List[String]()
    var order_kind = List[Int]()
    var order_out_idx = List[Int]()
    var order_expr_idx = List[Int]()
    var order_expr_names = List[String]()
    _classify_order_keys(
        stmt, schema, has_window, order_kind, order_out_idx, order_expr_idx,
        order_expr_names,
    )
    if has_window:
        if has_agg or grouped:
            raise Error(
                "SQL not supported: a window function combined with GROUP BY /"
                " aggregation in the same SELECT"
            )
        plan = _bind_window_projection(stmt, schema, scope, plan^, cat, cte, prebound)
    elif has_agg or grouped:
        plan = _bind_aggregate(
            stmt, schema, scope, plan^, cat, cte, prebound, order_names,
            order_carry, order_expr_idx, order_expr_names,
        )
    else:
        plan = _bind_projection(
            stmt, schema, scope, plan^, cat, cte, prebound, order_names,
            order_carry, order_expr_idx, order_expr_names,
        )
    var n_result = plan.output_schema.num_columns() - len(order_carry)
    if stmt.distinct:
        var all_cols: Optional[List[String]] = None
        plan = LogicalPlan.distinct(all_cols^, plan^)
    if len(stmt.order_by) > 0:
        var sort_names = List[String]()
        for i in range(len(stmt.order_by)):
            if order_kind[i] == _OK_COLUMN:
                sort_names.append(_order_key_name(stmt.order_by[i].expr, scope))
            elif order_kind[i] == _OK_OUTPUT:
                sort_names.append(
                    _order_output_column(plan.output_schema, order_out_idx[i], n_result)
                )
            else:
                sort_names.append(String("__order_key_") + String(i))
        plan = _bind_order(stmt, plan^, scope, sort_names)
    var offset = 0
    if stmt.offset:
        offset = stmt.offset.value()
    if stmt.limit:
        plan = LogicalPlan.limit(stmt.limit.value(), plan^, offset=offset)
    elif offset > 0:
        raise Error(
            "SQL not supported: OFFSET without LIMIT — this dialect honours an"
            " OFFSET only as part of a row window, so write"
            " `LIMIT <n> OFFSET " + String(offset) + "` with an explicit"
            " row count. (Refused rather than ignored: silently dropping the"
            " OFFSET would return every row.)"
        )
    if len(order_carry) > 0:
        var keep = plan.output_schema.num_columns() - len(order_carry)
        var prune = ExprArray()
        for c in range(keep):
            prune.append(Expr.col_ref(plan.output_schema.field_name(c)))
        plan = LogicalPlan.project(prune^, plan^)
    return plan^


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var st = parse_sql(tokenize(sql))
        return String(_select(st.query, cat))
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def test_deparse_names_of_expressions() raises:
    _check(
        "SELECT count(*) + count(k), sum(v + 1), max(k IS NULL), max(s LIKE 'x%'), max(s NOT LIKE 'y%'), min(DATE '1995-03-15'), max(true), max(false), max(-k), max(@k), sum(abs(k)), count(CASE WHEN k > 1 THEN 1 ELSE 0 END), max(CAST(v AS DOUBLE)), max(TRY_CAST(k AS DOUBLE)), max(position('b' IN s)), max(k || 'x'), max(k ^ 2), max(s ^@ 'a'), max(1.5), max('x'), max(TIMESTAMP '2021-01-01 00:00:00'), max(TIMESTAMPTZ '2021-01-01 00:00:00+00'), max(NOT b), mean(v), MEAN(v), SUM(K) FROM t",
        "ERR: SQL not supported: TRY_CAST. Its contract is to answer NULL where the cast fails, so a gap in the underlying cast becomes an INVISIBLE wrong answer rather than an error. Two known ones: TRY_CAST('3.5' AS BIGINT) is 4 in DuckDB v1.5.3 and would be NULL here (`cast_string_to_int64` in kernels parses an integer spelling only), and TRY_CAST(<INT64_MIN> AS INTEGER) is NULL there and would not be here (`eval_cast`, the integer cast in column_kernels, has no null-on-overflow arm). Use CAST(x AS DOUBLE), which refuses loudly instead."
    )
    _check(
        "SELECT mean(v), MEAN(v), avg(v), SUM(K), max(t.k) FROM t",
        "Project(exprs=[ColRef(mean(v)), ColRef(mean(v)_1), ColRef(avg(v)), ColRef(sum(k)), ColRef(max(t.k))])\n"
        "  Aggregate(group_by=[], aggs=[MEAN(ColRef(v)).alias(\"mean(v)\"), MEAN(ColRef(v)).alias(\"mean(v)_1\"), MEAN(ColRef(v)).alias(\"avg(v)\"), SUM(Cast(ColRef(k), float8_e5m2, arrow=decimal128, p=38, s=0)).alias(\"sum(k)\"), MAX(ColRef(k)).alias(\"max(t.k)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT max(18446744073709551615 = u64) FROM t",
        "Project(exprs=[ColRef(max((18446744073709551615 = u64)))])\n"
        "  Aggregate(group_by=[], aggs=[MAX(BinaryOp(EQ, Literal(ScalarValue(uint64, -1)), ColRef(u64))).alias(\"max((18446744073709551615 = u64))\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_statistical_aggregate_arity_names_the_spelling() raises:
    _check(
        "SELECT var_pop(v, k) FROM t",
        "ERR: SQL bind error: var_pop() expects exactly 1 argument"
    )
    _check(
        "SELECT stddev_pop(v, k) FROM t",
        "ERR: SQL bind error: stddev_pop() expects exactly 1 argument"
    )
    _check(
        "SELECT sem(v, k) FROM t",
        "ERR: SQL bind error: sem() expects exactly 1 argument"
    )
    _check(
        "SELECT count_if(b, b) FROM t",
        "ERR: SQL bind error: count_if() expects exactly 1 argument"
    )
    _check(
        "SELECT bool_and(b, b) FROM t",
        "ERR: SQL bind error: bool_and() expects exactly 1 argument"
    )
    _check(
        "SELECT bool_or(b, b) FROM t",
        "ERR: SQL bind error: bool_or() expects exactly 1 argument"
    )
    _check(
        "SELECT product(v, k) FROM t",
        "ERR: SQL bind error: product() expects exactly 1 argument"
    )
    _check(
        "SELECT first(v, k) FROM t",
        "ERR: SQL bind error: first() expects exactly 1 argument"
    )
    _check(
        "SELECT last(v, k) FROM t",
        "ERR: SQL bind error: last() expects exactly 1 argument"
    )
    _check(
        "SELECT any_value(v, k) FROM t",
        "ERR: SQL bind error: any_value() expects exactly 1 argument"
    )
    _check(
        "SELECT fsum(v, k) FROM t",
        "ERR: SQL bind error: fsum() expects exactly 1 argument"
    )
    _check(
        "SELECT favg(v, k) FROM t",
        "ERR: SQL bind error: favg() expects exactly 1 argument"
    )
    _check(
        "SELECT skewness(v, k) FROM t",
        "ERR: SQL bind error: skewness() expects exactly 1 argument"
    )
    _check(
        "SELECT kurtosis(v, k) FROM t",
        "ERR: SQL bind error: kurtosis() expects exactly 1 argument"
    )
    _check(
        "SELECT kurtosis_pop(v, k) FROM t",
        "ERR: SQL bind error: kurtosis_pop() expects exactly 1 argument"
    )
    _check(
        "SELECT var_samp(v, k) FROM t",
        "ERR: SQL bind error: var_samp() expects exactly 1 argument"
    )
    _check(
        "SELECT sum(*) FROM t",
        "ERR: SQL bind error: aggregate requires an argument"
    )


def test_dedup_keys_cover_every_keyable_argument() raises:
    # Literal, binary, unary (`-v`, `abs(v)`), cast and column arguments are
    # keyable, so the HAVING aggregate reuses the SELECT one; a function call
    # argument (`sqrt(v)`) is not, so it gets its own hidden aggregate, in either
    # child slot.
    _check(
        "SELECT k, sum(v + 1) AS a FROM t GROUP BY k HAVING sum(v + 1) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(BinaryOp(ADD, ColRef(v), Literal(ScalarValue(int64, 1)))).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(-v) AS a FROM t GROUP BY k HAVING sum(-v) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(UnaryOp(NEGATE, ColRef(v))).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(CAST(v AS DOUBLE)) AS a FROM t GROUP BY k HAVING sum(CAST(v AS DOUBLE)) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(Cast(ColRef(v), float64)).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(1) AS a FROM t GROUP BY k HAVING sum(1) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(Cast(Literal(ScalarValue(int64, 1)), float8_e5m2, arrow=decimal128, p=38, s=0)).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, max('x') AS a, max(DATE '2021-01-01') AS b, max(TIMESTAMP '2021-01-01') AS c, max(true) AS e, sum(1.5) AS f FROM t GROUP BY k HAVING max('x') > 'a' AND max(DATE '2021-01-01') > DATE '2020-01-01' AND max(TIMESTAMP '2021-01-01') > TIMESTAMP '2020-01-01' AND max(true) AND sum(1.5) > 0",
        "Project(exprs=[ColRef(k), ColRef(a), ColRef(b), ColRef(c), ColRef(e), ColRef(f)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(AND, BinaryOp(AND, BinaryOp(AND, BinaryOp(GT, ColRef(a), Literal(ScalarValue(utf8, \"a\"))), BinaryOp(GT, ColRef(b), Literal(ScalarValue(date32, 18262)))), BinaryOp(GT, ColRef(c), Literal(ScalarValue(timestamp[us], 1577836800000000)))), ColRef(e)), BinaryOp(GT, ColRef(f), Literal(ScalarValue(int64, 0)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(Literal(ScalarValue(utf8, \"x\"))).alias(\"a\"), MAX(Literal(ScalarValue(date32, 18628))).alias(\"b\"), MAX(Literal(ScalarValue(timestamp[us], 1609459200000000))).alias(\"c\"), MAX(Literal(ScalarValue(bool, true))).alias(\"e\"), SUM(Literal(ScalarValue(float64, 1.5))).alias(\"f\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(abs(v)) AS a FROM t GROUP BY k HAVING sum(abs(v)) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(UnaryOp(ABS, ColRef(v))).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, corr(v, abs(k)) AS a FROM t GROUP BY k HAVING corr(v, abs(k)) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[CORR(ColRef(v), UnaryOp(ABS, ColRef(k))).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, corr(abs(v), k) AS a FROM t GROUP BY k HAVING corr(abs(v), k) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[CORR(UnaryOp(ABS, ColRef(v)), ColRef(k)).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) AS a FROM t GROUP BY k HAVING count(*) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"a\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(sqrt(v)) AS a FROM t GROUP BY k HAVING sum(sqrt(v)) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(MathFn(op=2, ColRef(v))).alias(\"a\"), SUM(MathFn(op=2, ColRef(v))).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, corr(v, sqrt(k)) AS a FROM t GROUP BY k HAVING corr(v, sqrt(k)) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[CORR(ColRef(v), MathFn(op=2, ColRef(k))).alias(\"a\"), CORR(ColRef(v), MathFn(op=2, ColRef(k))).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, corr(sqrt(v), k) AS a FROM t GROUP BY k HAVING corr(sqrt(v), k) > 0",
        "Project(exprs=[ColRef(k), ColRef(a)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[CORR(MathFn(op=2, ColRef(v)), ColRef(k)).alias(\"a\"), CORR(MathFn(op=2, ColRef(v)), ColRef(k)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_having_null_comparisons_and_literals() raises:
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(d) > DATE '2021-01-01'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(date32, 18628))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(d)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING NULL = max(v)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(_agg_x0), Literal(ScalarValue(null, int64))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(v)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(v) + NULL > 1",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(v) = NULL AND NULL = max(v)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(EQ, ColRef(_agg_x0), Literal(ScalarValue(null, int64))), BinaryOp(EQ, ColRef(_agg_x0), Literal(ScalarValue(null, int64)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(v)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING NULL = NULL",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT k, max(v) + NULL FROM t GROUP BY k",
        "ERR: SQL not supported: a NULL literal is served as a comparison operand (`x = NULL`, `x <> NULL`) and as an IN-list member (`x IN (1, NULL)`, `x NOT IN (1, NULL)`), as a CASE's `ELSE NULL`, as a CASE `THEN NULL` beside INT64 or FLOAT64 arms, and as a COALESCE / IFNULL argument beside a typed one; anywhere else (a projected NULL, `NOT NULL`, `NULL = NULL`, any other function argument, arithmetic, a CASE or COALESCE whose EVERY value is NULL) it needs a typed NULL value this engine's plan does not carry"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING upper(max(s), 1) = 'x'",
        "ERR: SQL not supported: scalar function 'upper' applied to an aggregate result. The aggregate itself is allowed in this position — `HAVING SUM(v) > 10` binds; what this engine cannot lower yet is a call WRAPPING one, outside the math families whose aggregate arguments it hoists"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING abs(sum(v), 1) > 0",
        "ERR: SQL bind error: abs() takes exactly 1 argument here — got 2. DuckDB also has a 2-argument round(x, digits) / trunc(x, digits); this engine lowers the 1-argument form onto a UNARY node that has no slot for a digit count, so the 2-argument form is REFUSED rather than rounded to zero digits."
    )


def _types(sql: String) raises -> String:
    """The bound plan's output columns as `name:type` pairs (a decimal with its
    precision and scale), or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var st = parse_sql(tokenize(sql))
        var plan = _select(st.query, cat)
        var out = String("")
        for c in range(plan.output_schema.num_columns()):
            if c > 0:
                out += ","
            out += plan.output_schema.field_name(c) + ":" + String(
                plan.output_schema.field_arrow_type(c)
            )
            if plan.output_schema.field_arrow_type(c) == ArrowType.DECIMAL128:
                out += (
                    "(" + String(plan.output_schema.field_decimal_precision(c))
                    + "," + String(plan.output_schema.field_decimal_scale(c)) + ")"
                )
        return out
    except e:
        return String("ERR: ") + String(e)


def test_aggregate_output_types() raises:
    """The bound output schema types each aggregate: the integer, decimal and
    float rows differ in what sum keeps, avg is always float64, min/max keep
    the argument type and count is int64."""
    assert_equal(
        _types("SELECT sum(k), avg(k), min(k), max(k), count(k) FROM t"),
        "sum(k):decimal128(38,0),avg(k):float64,min(k):int64,max(k):int64,count(k):int64",
    )
    assert_equal(
        _types("SELECT sum(dc), avg(dc), min(dc), max(dc), count(dc) FROM t"),
        "sum(dc):decimal128(38,2),avg(dc):float64,min(dc):decimal128(12,2),"
        "max(dc):decimal128(12,2),count(dc):int64",
    )
    assert_equal(
        _types("SELECT sum(v), avg(v), min(v), max(v), count(v) FROM t"),
        "sum(v):float64,avg(v):float64,min(v):float64,max(v):float64,count(v):int64",
    )
    assert_equal(
        _types("SELECT k, sum(dc) AS total FROM t GROUP BY k"),
        "k:int64,total:decimal128(38,2)",
    )


def test_nested_aggregates_are_refused() raises:
    """An aggregate inside an aggregate argument is refused, in the select list
    and in HAVING."""
    _check("SELECT sum(sum(v)) FROM t", "ERR: SQL bind error: aggregate function not allowed in this position")
    _check("SELECT count(max(v)) FROM t", "ERR: SQL bind error: aggregate function not allowed in this position")
    _check("SELECT k FROM t GROUP BY k HAVING sum(count(*)) > 1", "ERR: SQL bind error: aggregate function not allowed in this position")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
