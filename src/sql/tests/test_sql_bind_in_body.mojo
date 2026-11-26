# =============================================================================
# Direct tests of IN / NOT IN over a body bound whole, and of a scalar
# subquery above an aggregate (sql_bind_subquery, sql_bind_agg_expr,
# sql_bind_aggregate)
# =============================================================================
#
# What each test proves:
#   test_in_over_a_general_body_is_a_semi_subquery
#       an IN body with DISTINCT, GROUP BY / HAVING, a join, a comma FROM, an
#       expression, an aggregate or a LIMIT binds to one EXISTS-kind subquery
#       (kind=0) with the left column as its one outer reference, over
#       `Filter(__in_y = k, Project(<column> AS __in_y, <the whole body>))`;
#       OFFSET without LIMIT keeps the parser's refusal.
#   test_not_in_over_a_general_body_keeps_both_null_checks
#       NOT IN over such a body is the ANTI subquery (kind=1) AND "no NULL y"
#       AND "x IS NOT NULL or the body is empty": no footer describes a
#       whole-bound body, so the y check always stays.
#   test_not_in_over_a_general_body_drops_the_x_check_when_x_is_proved
#       with footers proving the left column NULL-free, only the y check stays.
#   test_a_general_in_body_is_uncorrelated_and_one_column
#       a general body naming an outer column is the binder's unknown-column
#       error, and one projecting two columns is refused; EXISTS keeps its
#       body-shape refusals.
#   test_a_scalar_subquery_above_an_aggregate_binds
#       a scalar subquery in HAVING, beside an aggregate in a SELECT item and
#       as a SELECT item of a grouped query binds to the uncorrelated scalar
#       (kind=2) in the post-aggregate expression.
#   test_a_predicate_subquery_above_an_aggregate_is_refused_by_name
#       EXISTS, IN and NOT IN in HAVING, and EXISTS as a SELECT item of a
#       grouped query, are refused naming the position; so is a scalar
#       subquery inside a grouped SELECT item that is not an aggregate.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.record_batch import RecordBatch
from arrow.schema import Field, Schema, SchemaBuilder

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from scan_source.parquet_source import ParquetSource
from sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
from sql.sql_binder import bind_statement
from plan_expr.expr import EXPR_BINARY_OP
from plan_ir.corr_subquery import corr_data_inner_plan_ref


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
    (no file is opened); mem(k, v): an empty in-memory table."""
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
    cat.add_in_memory(String("mem"), RecordBatch.empty_from_schema(_kv()))
    return cat^


def _kv() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    return sb.build()


@fieldwise_init
struct _Footers(SqlParquetFooters):
    """A footer reader with fixed answers: every path but `missing.parquet`
    has schema (k INT64, v FLOAT64); `k` holds no NULL and `v` holds 3; a
    path named `bad.parquet` raises for null counts."""

    def footer_schema(self, path: String) raises -> Schema:
        if path == "missing.parquet":
            raise Error("no such file: " + path)
        return _kv()

    def column_null_count(self, path: String, column: String) raises -> Optional[Int]:
        if path == "bad.parquet":
            raise Error("unreadable statistics")
        if column == "k":
            return 0
        if column == "v":
            return 3
        return None

    def parquet_relation(
        self, path: String, hive_partitioning: UInt8
    ) raises -> ParquetSource:
        return ParquetSource(String(path), self.footer_schema(path), None)


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _gotp(sql: String) raises -> String:
    """`_got` with the `_Footers` reader."""
    var cat = _catalog()
    try:
        var bound = bind_statement(parse_sql(tokenize(sql)), cat, _Footers())
        return String(bound.take_plan())
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


def _checkp(sql: String, want: String) raises:
    assert_equal(_gotp(sql), want, sql)


def _member_body(sql: String) raises -> String:
    """The rendered inner plan of the membership subquery of a bound
    `SELECT k FROM t WHERE k [NOT] IN (...)`: the predicate itself for IN,
    its first conjunct (the ANTI subquery) for NOT IN."""
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    ref pred = plan.project_data_ref().child[].filter_data_ref().predicate
    if pred.tag == EXPR_BINARY_OP:
        return String(corr_data_inner_plan_ref(pred.binary_left_ref()._corr_subq.value()[]))
    return String(corr_data_inner_plan_ref(pred._corr_subq.value()[]))


def _check_body(sql: String, fragments: List[String]) raises:
    """`sql` binds to the one EXISTS-kind subquery over `t`, and its body is
    `Filter(__in_y = k, Project(<column> AS __in_y, <the body>))` holding each
    of `fragments`."""
    _check(sql, "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n")
    var inner = _member_body(sql)
    assert_true(inner.startswith("Filter(predicate=BinaryOp(EQ, ColRef(__in_y), "), inner)
    assert_true(inner.find("\"__in_y\")") >= 0, inner)
    for i in range(len(fragments)):
        assert_true(inner.find(fragments[i]) >= 0, fragments[i] + " in " + inner)


def test_in_over_a_general_body_is_a_semi_subquery() raises:
    var distinct: List[String] = ["Distinct("]
    _check_body("SELECT k FROM t WHERE k IN (SELECT DISTINCT k FROM u)", distinct)
    var grouped: List[String] = ["Aggregate(group_by=[ColRef(k)]", "COUNT(*)"]
    _check_body(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u GROUP BY k HAVING count(*) > 1)",
        grouped,
    )
    var joined: List[String] = ["Join(type=", "kk.parquet"]
    _check_body("SELECT k FROM t WHERE k IN (SELECT u.k FROM u JOIN kk ON u.k = kk.k)", joined)
    var comma: List[String] = ["kk.parquet", "u.parquet"]
    _check_body("SELECT k FROM t WHERE k IN (SELECT u.k FROM u, kk WHERE u.k = kk.a)", comma)
    var expr: List[String] = ["BinaryOp(ADD, ColRef(k)"]
    _check_body("SELECT k FROM t WHERE k IN (SELECT k + 1 FROM u)", expr)
    var agg: List[String] = ["Aggregate(group_by=[]", "MAX(ColRef(w))"]
    _check_body("SELECT k FROM t WHERE k IN (SELECT max(w) FROM u)", agg)
    var limit: List[String] = ["Limit(n=3"]
    _check_body("SELECT k FROM t WHERE k IN (SELECT k FROM u LIMIT 3)", limit)
    # OFFSET without LIMIT keeps the parser's own refusal.
    _check(
        "SELECT k FROM t WHERE k IN (SELECT k FROM u OFFSET 3)",
        "ERR: SQL not supported: OFFSET without LIMIT — this dialect honours an"
        " OFFSET only as part of a row window, so write `LIMIT <n> OFFSET 3` with"
        " an explicit row count. (Refused rather than ignored: silently dropping"
        " the OFFSET would return every row.)"
    )


def test_not_in_over_a_general_body_keeps_both_null_checks() raises:
    _check("SELECT k FROM t WHERE k NOT IN (SELECT DISTINCT k FROM u)", "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n")
    var inner = _member_body("SELECT k FROM t WHERE k NOT IN (SELECT DISTINCT k FROM u)")
    assert_true(inner.startswith("Filter(predicate=BinaryOp(EQ, ColRef(__in_y), "), inner)
    assert_true(inner.find("Distinct(") >= 0, inner)
    _check(
        "SELECT k FROM t WHERE k NOT IN (SELECT k FROM u GROUP BY k HAVING count(*) > 1)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(AND, BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0))), BinaryOp(OR, UnaryOp(IS_NOT_NULL, ColRef(k)), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=3), Literal(ScalarValue(int64, 0)))))))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_not_in_over_a_general_body_drops_the_x_check_when_x_is_proved() raises:
    _checkp(
        "SELECT k FROM read_parquet('p.parquet') AS o WHERE k NOT IN (SELECT DISTINCT k FROM read_parquet('q.parquet') AS i)",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1), BinaryOp(EQ, CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), Literal(ScalarValue(int64, 0)))))\n"
        "    Scan(path=\"p.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_a_general_in_body_is_uncorrelated_and_one_column() raises:
    _check(
        "SELECT k FROM t WHERE k IN (SELECT u.k FROM u GROUP BY u.k HAVING max(u.w) > t.v)",
        "ERR: SQL bind error: unknown column 't.v'"
    )
    _check(
        "SELECT k FROM t WHERE k IN (SELECT DISTINCT k, w FROM u)",
        "ERR: SQL bind error: an IN subquery must project exactly one column"
    )
    _check(
        "SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k GROUP BY u.k)",
        "ERR: SQL not supported: GROUP BY / HAVING / ORDER BY / LIMIT / OFFSET / DISTINCT inside a predicate subquery"
    )


def test_a_scalar_subquery_above_an_aggregate_binds() raises:
    _check(
        "SELECT k, sum(w) AS sw FROM u GROUP BY k HAVING sum(w) > (SELECT max(v) FROM t)",
        "Project(exprs=[ColRef(k), ColRef(sw)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(sw), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2)))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(Cast(ColRef(w), float8_e5m2, arrow=decimal128, p=38, s=0)).alias(\"sw\")])\n"
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(w) + (SELECT max(k) FROM t) AS x FROM u",
        "Project(exprs=[Alias(BinaryOp(ADD, ColRef(_agg_x0), CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2)), \"x\")])\n"
        "  Aggregate(group_by=[], aggs=[SUM(Cast(ColRef(w), float8_e5m2, arrow=decimal128, p=38, s=0)).alias(\"_agg_x0\")])\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) AS n, (SELECT max(v) FROM t) AS m FROM u GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(n), Alias(CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), \"m\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"n\")])\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    # With no alias the item takes DuckDB's printed name of a subquery.
    _check(
        "SELECT k, count(*) AS n, (SELECT max(v) FROM t) FROM u GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(n), Alias(CorrelatedSubquery(kind=2, outer_refs=#0, inner_tag=2), \"(SELECT ...)\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"n\")])\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


comptime _POST_AGG_REFUSAL = (
    "ERR: SQL not supported: an EXISTS or IN subquery in a HAVING clause or in the"
    " SELECT list of a grouped query (a scalar subquery is served there; a"
    " predicate subquery is served as a WHERE conjunct)"
)


def test_a_predicate_subquery_above_an_aggregate_is_refused_by_name() raises:
    _check(
        "SELECT k FROM u GROUP BY k HAVING EXISTS (SELECT 1 FROM t)",
        _POST_AGG_REFUSAL,
    )
    _check(
        "SELECT k FROM u GROUP BY k HAVING k IN (SELECT k FROM t)",
        _POST_AGG_REFUSAL,
    )
    _check(
        "SELECT k, count(*) FROM u GROUP BY k HAVING count(*) > 0 AND k NOT IN (SELECT k FROM t)",
        _POST_AGG_REFUSAL,
    )
    _check(
        "SELECT k, EXISTS (SELECT 1 FROM t) AS e FROM u GROUP BY k",
        _POST_AGG_REFUSAL,
    )
    # A scalar subquery inside a grouped item that is not an aggregate.
    _check(
        "SELECT k + (SELECT max(k) FROM t) AS x, count(*) FROM u GROUP BY k",
        "ERR: SQL not supported: a subquery inside a non-aggregate SELECT item"
        " of a grouped query (a scalar subquery that is the whole item is"
        " served)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
