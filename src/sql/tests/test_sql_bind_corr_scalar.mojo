# =============================================================================
# Direct tests of a correlated scalar subquery body (sql_bind_corr_scalar)
# =============================================================================
#
# What each test proves:
#   test_a_correlated_scalar_binds_grouped_by_its_keys
#       `(SELECT max(w) FROM u WHERE u.k = t.k)` in a WHERE binds to a SCALAR
#       subquery (kind=2) with one outer reference whose body is
#       `Project(__corr0_a0 AS __corr0_v, Filter(__corr0_k0 = <outer k>,
#       <u grouped by k: k AS __corr0_k0, max(w) AS __corr0_a0>))`.
#   test_a_count_is_coalesced_and_aggregates_are_numbered_in_order
#       `count(*) * 2 + max(w)` reads `coalesce(__corr0_a0, 0) * 2 +
#       __corr0_a1`: the count is the first aggregate and the only one
#       wrapped; count(column) is a count too.
#   test_keys_are_read_on_either_side_and_inner_conjuncts_stay
#       `t.k = u.k` and `u.k = t.k` give the same key; two keys keep their
#       order; a conjunct naming only inner columns stays in the grouped
#       body's WHERE; an unqualified outer column binds by its name in the
#       outer FROM, a qualified one through it (`_right` on a collision).
#   test_the_inner_scope_shadows_the_outer_one
#       an unqualified column both FROMs have is the inner one (so the body
#       is uncorrelated); a qualifier that names an inner relation and no
#       outer one is an unknown column; a column of no FROM is an unknown
#       column whether or not an outer FROM is known.
#   test_correlated_scalars_bind_in_select_lists_and_subquery_bodies
#       in the SELECT list of the top statement and of a derived table, and
#       in the WHERE of an IN body (the outer scope is that body's FROM); in
#       a grouped SELECT list and a HAVING it is refused, while an
#       uncorrelated one there still binds.
#   test_unserved_bodies_are_refused_by_name
#       GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT, OFFSET, a LEFT JOIN, a
#       NATURAL join, no aggregate, two items, `*`, a statistical aggregate,
#       a window, an outer column in the SELECT list (also under a CASE, a
#       call and an aggregate), a non-equi correlation, an equality of two
#       outer columns and of an expression.
#   test_a_decimal_compared_with_a_float_is_cast_to_the_float
#       DuckDB's rule (sql_bind_ops): a DECIMAL compared with a DOUBLE or a
#       FLOAT, on either side, is cast to the float's type; a scalar
#       subquery operand (also under a minus or a CAST) is typed by its body;
#       a DECIMAL against an integer or a DECIMAL, and two non-DECIMALs, are
#       not cast.
#   test_comma_joins_and_nested_subqueries_bind_inside_the_body
#       a comma and a CROSS join in the body bind into the grouped body; an
#       uncorrelated scalar inside the body stays its own subquery there.
#   test_substring_from_for_is_the_call
#       `substring(s FROM a FOR b)` and `substring(s FROM a)` bind as
#       `substring(s, a, b)` and `substring(s, a)`; a FROM nested in
#       parentheses is not the grammar form; a second FOR is a syntax error.
#   test_names_outer_and_extract_aggs_descend_every_node_kind
#       an outer column under a LIKE, a NOT, a CASE (WHEN, THEN and ELSE) and a
#       call argument makes the body correlated; aggregates under a CASE and a
#       call are extracted in pre-order.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement
from plan_ir.corr_subquery import corr_data_inner_plan_ref
from plan_ir.logical_plan import LogicalPlan
from plan_expr.expr import EXPR_CORRELATED_SUBQUERY, Expr


def _table(mut cat: SqlCatalog, name: String, var cols: List[String]):
    var sb = SchemaBuilder()
    for i in range(len(cols)):
        sb.add_field(Field(cols[i], ArrowType.INT64, True))
    cat.add_parquet(name, name + ".parquet", sb.build())


def _catalog() raises -> SqlCatalog:
    """t(k, g, v), u(k, g, w), r(k, x): INT64 parquet tables; m(dc
    DECIMAL(12,2), f DOUBLE, f32 FLOAT, k): no file is opened."""
    var cat = SqlCatalog()
    _table(cat, "t", ["k", "g", "v"])
    _table(cat, "u", ["k", "g", "w"])
    _table(cat, "r", ["k", "x"])
    var m = SchemaBuilder()
    m.add_field(Field.decimal128(String("dc"), 12, 2, True))
    m.add_field(Field(String("f"), ArrowType.FLOAT64, True))
    m.add_field(Field(String("f32"), ArrowType.FLOAT32, True))
    m.add_field(Field(String("k"), ArrowType.INT64, True))
    cat.add_parquet(String("m"), String("m.parquet"), m.build())
    return cat^


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message. A
    correlated subquery's inner plan is not in the plan's text; `_inner`
    renders it."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _has(sql: String, var fragments: List[String]) raises:
    var text = _got(sql)
    for i in range(len(fragments)):
        assert_true(text.find(fragments[i]) >= 0, fragments[i] + " in " + text)


def _refused(sql: String, reason: String) raises:
    assert_equal(_got(sql), "ERR: " + reason, sql)


comptime _CORR = "SQL not supported: a correlated scalar subquery "


def _first_corr(e: Expr) raises -> String:
    """The rendered inner plan of the first correlated subquery in `e`
    (pre-order over binary and alias nodes), or "" when it holds none."""
    if e.tag == EXPR_CORRELATED_SUBQUERY:
        return String(corr_data_inner_plan_ref(e._corr_subq.value()[]))
    if e._binary:
        var l = _first_corr(e.binary_left_ref())
        if l != "":
            return l
        return _first_corr(e.binary_right_ref())
    if e._alias:
        return _first_corr(e.alias_child_ref())
    return String("")


def _inner_of(plan: LogicalPlan) raises -> String:
    """The rendered inner plan of the first correlated subquery in the first
    Filter predicate or Project expression of `plan`, top down."""
    if plan._filter:
        var f = _first_corr(plan.filter_data_ref().predicate)
        if f != "":
            return f
        return _inner_of(plan.filter_data_ref().child[])
    if plan._project:
        ref pj = plan.project_data_ref()
        for i in range(len(pj.exprs)):
            var p = _first_corr(pj.exprs[i])
            if p != "":
                return p
        return _inner_of(pj.child[])
    return String("")


def _inner(sql: String) raises -> String:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    return _inner_of(bound.take_plan())


def _inner_has(sql: String, var fragments: List[String]) raises:
    var text = _inner(sql)
    for i in range(len(fragments)):
        assert_true(text.find(fragments[i]) >= 0, fragments[i] + " in " + text)


def test_a_correlated_scalar_binds_grouped_by_its_keys() raises:
    var sql = "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k)"
    assert_equal(
        _got(sql),
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(v), CorrelatedSubquery(kind=2, outer_refs=#1, inner_tag=2)))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    var inner = _inner(sql)
    assert_true(inner.startswith("Project(exprs=[Alias(ColRef(__corr0_a0), \"__corr0_v\")])"), inner)
    _inner_has(sql, [
        "Filter(predicate=BinaryOp(EQ, ColRef(__corr0_k0), ColRef(left.k)))",
        "Alias(ColRef(k), \"__corr0_k0\")",
        "Aggregate(group_by=[ColRef(k)]",
        "MAX(ColRef(w))",
        "u.parquet",
    ])


def test_a_count_is_coalesced_and_aggregates_are_numbered_in_order() raises:
    var sql = "SELECT k FROM t WHERE v > (SELECT count(*) * 2 + max(w) FROM u WHERE u.k = t.k)"
    var inner = _inner(sql)
    var a0 = inner.find("__corr0_a0")
    var a1 = inner.find("__corr0_a1")
    assert_true(a0 >= 0 and a1 > a0, inner)
    assert_true(inner.find("COUNT(*)") >= 0, inner)
    assert_true(inner.find("MAX(ColRef(w))") >= 0, inner)
    # The value reads the count through coalesce and the max as it is.
    var value_end = inner.find("\n")
    var value = String(inner[byte=0:value_end])
    assert_true(value.find("ColRef(__corr0_a1)") >= 0, value)
    assert_true(value.find("Literal(ScalarValue(int64, 0))") >= 0, value)
    var plain = _inner("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k)")
    assert_equal(plain.find("Literal(ScalarValue(int64, 0))"), -1, plain)
    var col = _inner("SELECT k FROM t WHERE v > (SELECT count(w) FROM u WHERE u.k = t.k)")
    var col_value = String(col[byte=0:col.find("\n")])
    assert_true(col_value.find("Literal(ScalarValue(int64, 0))") >= 0, col_value)


def test_keys_are_read_on_either_side_and_inner_conjuncts_stay() raises:
    assert_equal(
        _inner("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE t.k = u.k)"),
        _inner("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k)"),
    )
    var two = "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND u.w > 3 AND t.g = u.g)"
    _has(two, ["CorrelatedSubquery(kind=2, outer_refs=#2"])
    _inner_has(two, [
        "BinaryOp(AND, BinaryOp(EQ, ColRef(__corr0_k0), ColRef(left.k)), BinaryOp(EQ, ColRef(__corr0_k1), ColRef(left.g)))",
        "Aggregate(group_by=[ColRef(k), ColRef(g)]",
        "Filter(predicate=BinaryOp(GT, ColRef(w), Literal(ScalarValue(int64, 3))))",
    ])
    _has(
        "SELECT k FROM t WHERE (SELECT max(w) FROM u WHERE u.k = v) > 1",
        ["CorrelatedSubquery(kind=2, outer_refs=#1"],
    )
    _inner_has(
        "SELECT t.k FROM t, r WHERE t.v > (SELECT max(w) FROM u WHERE u.k = r.k)",
        ["BinaryOp(EQ, ColRef(__corr0_k0), ColRef(left.k_right))"],
    )


def test_the_inner_scope_shadows_the_outer_one() raises:
    _has(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE g = 1 AND k = k)",
        ["CorrelatedSubquery(kind=2, outer_refs=#0"],
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.zz = t.k)",
        "SQL bind error: unknown column 'u.zz'",
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = nosuch)",
        "SQL bind error: unknown column 'nosuch'",
    )
    # Under a CASE no outer scope is known: the body binds uncorrelated.
    _refused(
        "SELECT k FROM t WHERE CASE WHEN v > 0 THEN (SELECT max(w) FROM u WHERE u.k = t.k) ELSE 0 END > 1",
        "SQL bind error: unknown column 't.k'",
    )


def test_correlated_scalars_bind_in_select_lists_and_subquery_bodies() raises:
    _has(
        "SELECT k, (SELECT max(w) FROM u WHERE u.k = t.k) AS m FROM t",
        ["Alias(CorrelatedSubquery(kind=2, outer_refs=#1"],
    )
    _has(
        "SELECT d.m FROM (SELECT k, (SELECT max(w) FROM u WHERE u.k = t.k) AS m FROM t) d WHERE d.m > 1",
        ["Alias(CorrelatedSubquery(kind=2, outer_refs=#1"],
    )
    var in_body = _got(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u WHERE u.w > (SELECT max(x) FROM r WHERE r.k = u.k))"
    )
    assert_false(in_body.startswith("ERR"), in_body)
    var grouped = _CORR + "in a HAVING clause or in the SELECT list of a grouped query"
    _refused("SELECT g, (SELECT max(w) FROM u WHERE u.k = t.g) AS m FROM t GROUP BY g", grouped)
    _refused("SELECT g FROM t GROUP BY g HAVING count(*) > (SELECT max(w) FROM u WHERE u.k = t.g)", grouped)
    _refused(
        "SELECT d.g FROM (SELECT g, (SELECT max(w) FROM u WHERE u.k = t.g) AS m FROM t GROUP BY g) d",
        grouped,
    )
    var ok = _got("SELECT g FROM t GROUP BY g HAVING count(*) > (SELECT max(w) FROM u)")
    assert_false(ok.startswith("ERR"), ok)
    var ok2 = _got("SELECT g, (SELECT max(w) FROM u) AS m FROM t GROUP BY g")
    assert_false(ok2.startswith("ERR"), ok2)


def test_names_outer_and_extract_aggs_descend_every_node_kind() raises:
    var corr = _CORR + "whose WHERE names an outer column other than in an `inner_column = outer_column` conjunct"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND abs(t.v) > 0)", corr)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND NOT (t.v > 1))", corr)
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND CAST(t.v AS VARCHAR) LIKE '1%')",
        corr,
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND CASE WHEN t.v > 0 THEN 1 ELSE 0 END = 1)",
        corr,
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND CASE WHEN u.w > 0 THEN t.v ELSE 0 END = 1)",
        corr,
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND CASE WHEN u.w > 0 THEN 0 ELSE t.v END = 1)",
        corr,
    )
    var sel = _CORR + "with an outer column in its SELECT list"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w + t.v) FROM u WHERE u.k = t.k)", sel)
    _refused("SELECT k FROM t WHERE v > (SELECT abs(t.v) + max(w) FROM u WHERE u.k = t.k)", sel)
    _refused(
        "SELECT k FROM t WHERE v > (SELECT CASE WHEN max(w) > t.v THEN 1 ELSE 0 END FROM u WHERE u.k = t.k)",
        sel,
    )
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT CASE WHEN count(*) > 2 THEN max(w) ELSE min(w) END FROM u WHERE u.k = t.k)",
        ["COUNT(*)", "MAX(ColRef(w))", "MIN(ColRef(w))", "__corr0_a2"],
    )
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT abs(min(w)) FROM u WHERE u.k = t.k)",
        ["MIN(ColRef(w))", "__corr0_a0"],
    )
    _has(
        "SELECT k FROM t WHERE (SELECT max(w) IS NULL FROM u WHERE u.k = t.k)",
        ["CorrelatedSubquery(kind=2, outer_refs=#1"],
    )


def test_inner_predicates_bind_null_safe_tests() raises:
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND u.w IS DISTINCT FROM u.g)",
        ["UnaryOp(NOT, BinaryOp(OR", "UnaryOp(IS_NULL, ColRef(w))", "BinaryOp(EQ, ColRef(w), ColRef(g))"],
    )
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND u.w > 1 IS NOT TRUE)",
        ["BinaryOp(OR, UnaryOp(IS_NULL, BinaryOp(GT, ColRef(w)", "UnaryOp(NOT, BinaryOp(GT, ColRef(w)"],
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND u.w IS TRUE)",
        "SQL not supported: `IS [NOT] TRUE` / `IS [NOT] FALSE` over an operand that"
        " is not a BOOLEAN. DuckDB casts the operand to BOOLEAN first (`1 IS TRUE`"
        " is true), and this engine has no cast to BOOLEAN, so only a BOOLEAN"
        " operand is served; a column of another type can be compared instead"
        " (`i <> 0`). An operand whose type is not known here, such as an"
        " outer-query column inside a subquery, is refused too.",
    )


def test_unserved_bodies_are_refused_by_name() raises:
    var shape = _CORR + "with GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT or OFFSET in its body"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k GROUP BY g)", shape)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k HAVING count(*) > 1)", shape)
    _refused("SELECT k FROM t WHERE v > (SELECT DISTINCT max(w) FROM u WHERE u.k = t.k)", shape)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k ORDER BY 1)", shape)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k LIMIT 1)", shape)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k LIMIT 1 OFFSET 1)", shape)
    var join = _CORR + "whose FROM has a JOIN other than a comma or CROSS join"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u LEFT JOIN r ON u.k = r.k WHERE u.g = t.g)", join)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u NATURAL JOIN r WHERE u.g = t.g)", join)
    _refused(
        "SELECT k FROM t WHERE v > (SELECT w FROM u WHERE u.k = t.k)",
        _CORR + "whose SELECT list holds no aggregate (its value could be several rows)",
    )
    var one = "SQL bind error: a scalar subquery must project exactly one column"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w), min(w) FROM u WHERE u.k = t.k)", one)
    _refused("SELECT k FROM t WHERE v > (SELECT * FROM u WHERE u.k = t.k)", one)
    var other = _CORR + "with an aggregate other than sum, count, min, max or avg, or a window"
    _refused("SELECT k FROM t WHERE v > (SELECT median(w) FROM u WHERE u.k = t.k)", other)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) + median(w) FROM u WHERE u.k = t.k)", other)
    _refused("SELECT k FROM t WHERE v > (SELECT median(w) IS NULL FROM u WHERE u.k = t.k)", other)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) + sum(w) OVER () FROM u WHERE u.k = t.k)", other)
    _refused("SELECT k FROM t WHERE v > (SELECT abs(median(w)) + max(w) FROM u WHERE u.k = t.k)", other)
    _refused(
        "SELECT k FROM t WHERE v > (SELECT CASE WHEN max(w) > 0 THEN median(w) ELSE 0 END FROM u WHERE u.k = t.k)",
        other,
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT CASE WHEN median(w) > 0 THEN 1 ELSE max(w) END FROM u WHERE u.k = t.k)",
        other,
    )
    _refused(
        "SELECT k FROM t WHERE v > (SELECT CASE WHEN max(w) > 0 THEN 1 ELSE median(w) END FROM u WHERE u.k = t.k)",
        other,
    )
    var sel = _CORR + "with an outer column in its SELECT list"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) + t.v FROM u WHERE u.k = t.k)", sel)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) + v FROM u WHERE u.k = t.k)", sel)
    var corr = _CORR + "whose WHERE names an outer column other than in an `inner_column = outer_column` conjunct"
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k < t.k)", corr)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE t.k = t.g)", corr)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k + 1 = t.k)", corr)
    _refused("SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k OR u.g = 1)", corr)


def _filter_text(sql: String) raises -> String:
    """The bound plan from its Filter on, or the whole text (an `ERR: `)."""
    var text = _got(sql)
    var at = text.find("Filter(")
    if at < 0:
        return text^
    return String(text[byte=at:])


def test_a_decimal_compared_with_a_float_is_cast_to_the_float() raises:
    var cast64 = "Cast(ColRef(dc)"
    var lit = _filter_text("SELECT k FROM m WHERE dc < 1e-2")
    assert_equal(lit.find("Cast("), -1, lit)
    var konst = _filter_text("SELECT k FROM m WHERE dc < -CAST(1 AS DOUBLE) / 4.0")
    assert_equal(konst.find("Cast(ColRef(dc)"), -1, konst)
    var t1 = _filter_text("SELECT k FROM m WHERE dc < f")
    assert_true(t1.find(cast64) >= 0, t1)
    assert_true(t1.find("float64") >= 0, t1)
    var t2 = _filter_text("SELECT k FROM m WHERE f > dc")
    assert_true(t2.find(cast64) >= 0, t2)
    var t3 = _filter_text("SELECT k FROM m WHERE dc = f32")
    assert_true(t3.find(cast64) >= 0 and t3.find("float32") >= 0, t3)
    var t4 = _filter_text("SELECT k FROM m WHERE dc > (SELECT avg(f) FROM m)")
    assert_true(t4.find(cast64) >= 0, t4)
    var t5 = _filter_text("SELECT k FROM m WHERE dc > -(SELECT avg(f) FROM m)")
    assert_true(t5.find(cast64) >= 0, t5)
    var t6 = _filter_text("SELECT k FROM m WHERE dc > CAST((SELECT max(k) FROM m) AS DOUBLE) * 0.5")
    assert_true(t6.find(cast64) >= 0, t6)
    var t7 = _filter_text("SELECT k FROM m WHERE dc > CASE WHEN f > 0 THEN f ELSE 1.5 END")
    assert_true(t7.find(cast64) >= 0, t7)
    # Not a DECIMAL against a float: no cast.
    var t8 = _filter_text("SELECT k FROM m WHERE dc > 1 AND f > k AND dc <> (SELECT max(dc) FROM m)")
    assert_equal(t8.find("Cast("), -1, t8)
    # An operand the typing schema does not hold (an outer column of an
    # EXISTS body) is left as written.
    var t9 = _got("SELECT k FROM t WHERE EXISTS (SELECT * FROM m WHERE m.dc < t.v)")
    assert_false(t9.startswith("ERR"), t9)


def test_comma_joins_and_nested_subqueries_bind_inside_the_body() raises:
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT max(x) FROM u, r WHERE u.k = r.k AND u.g = t.g)",
        ["r.parquet", "u.parquet", "Aggregate(group_by=[ColRef(g)]"],
    )
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u CROSS JOIN r WHERE u.k = t.k AND r.x = 1)",
        ["r.parquet", "u.parquet"],
    )
    _inner_has(
        "SELECT k FROM t WHERE v > (SELECT max(w) FROM u WHERE u.k = t.k AND u.w > (SELECT min(x) FROM r))",
        ["CorrelatedSubquery(kind=2, outer_refs=#0"],
    )


def _parsed_where(sql: String) raises -> String:
    """The bound plan from its Filter on, or the whole text (an `ERR: `)."""
    var text = _got(sql)
    var at = text.find("Filter(")
    if at < 0:
        return text^
    return String(text[byte=at:])


def test_substring_from_for_is_the_call() raises:
    assert_equal(
        _parsed_where("SELECT k FROM t WHERE substring(CAST(k AS VARCHAR) FROM 1 FOR 2) = '1'"),
        _parsed_where("SELECT k FROM t WHERE substring(CAST(k AS VARCHAR), 1, 2) = '1'"),
    )
    assert_equal(
        _parsed_where("SELECT k FROM t WHERE substring(CAST(k AS VARCHAR) FROM 2) = '1'"),
        _parsed_where("SELECT k FROM t WHERE substring(CAST(k AS VARCHAR), 2) = '1'"),
    )
    # A FROM inside nested parentheses does not make the grammar form.
    var nested = _got("SELECT k FROM t WHERE substring((SELECT max(CAST(x AS VARCHAR)) FROM r), 1, 1) = '1'")
    assert_false(nested.startswith("ERR: SQL syntax error"), nested)
    assert_true(
        _got("SELECT k FROM t WHERE substring(CAST(k AS VARCHAR) FROM 1 FOR 2 FOR 3) = '1'").startswith("ERR: SQL syntax error"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
