# =============================================================================
# Direct tests of aggregate binding: aggregate calls, the post-aggregate
# expressions, GROUP BY resolution and HAVING
# (sql_bind_agg_expr, sql_bind_aggregate, sql_bind_names)
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. The five grammar aggregates and every statistical aggregate bind to
#      their own `AGG_*` tag (population vs sample, `first` vs `any_value`,
#      `fsum` vs `sum`), the bivariate family binds `(y, x)` with x in child
#      slot 0, and each arity refusal names the spelling written.
#      (mutants: `var_pop` bound to AGG_VAR_SAMP; the bivariate swap undone)
#   2. Unaliased aggregates are named by DuckDB's deparse (`count_star()`,
#      `sum(v)`, `mean(v)`), an exact duplicate gets `_1`, and an aggregate
#      aliased with a group key's name is computed under an internal name.
#      (mutant: the `_N` collision loop dropped)
#   3. Expressions over aggregates hoist each aggregate into a hidden output
#      (`_agg_x<n>`), one accumulator per distinct aggregate (the alias is
#      not identity, the child slots are); `/` over aggregates is typed from
#      the aggregate outputs; `%`, unary minus and ILIKE over an aggregate
#      are refused by name.
#      (mutant: `_agg_expr_dedup_key` ignores `func`, so `sum(v)` dedups onto
#      `max(v)`)
#   4. GROUP BY: ordinals (range-checked, a big literal refused), aliases
#      (an input column wins), computed keys materialised below the
#      aggregate, repeated keys merged, literal constants elided while a
#      non-constant key remains, aggregates and windows refused.
#      (mutant: the elision guard `n_other > 0` removed, so `GROUP BY 1`
#      over a constant becomes a 0-key aggregate)
#   5. HAVING binds over the group keys and the aggregate outputs, and an
#      ORDER BY a group key or an aggregate expression is carried and pruned.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters, SqlParquetFooters
from komira_sql.sql_binder import bind_statement


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

def test_grammar_aggregates() raises:
    _check(
        "SELECT k, count(*) FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*), sum(v), min(v), max(v), avg(v), count(DISTINCT s) FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(count_star()), ColRef(sum(v)), ColRef(min(v)), ColRef(max(v)), ColRef(avg(v)), ColRef(count(DISTINCT s))])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\"), SUM(ColRef(v)).alias(\"sum(v)\"), MIN(ColRef(v)).alias(\"min(v)\"), MAX(ColRef(v)).alias(\"max(v)\"), MEAN(ColRef(v)).alias(\"avg(v)\"), COUNT_DISTINCT(ColRef(s)).alias(\"count(DISTINCT s)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT count(*) FROM t",
        "Project(exprs=[ColRef(count_star())])\n"
        "  Aggregate(group_by=[], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT count(k) FROM t",
        "Project(exprs=[ColRef(count(k))])\n"
        "  Aggregate(group_by=[], aggs=[COUNT(ColRef(k)).alias(\"count(k)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT count(DISTINCT k) AS c FROM t",
        "Project(exprs=[ColRef(c)])\n"
        "  Aggregate(group_by=[], aggs=[COUNT_DISTINCT(ColRef(k)).alias(\"c\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(DISTINCT v) FROM t",
        "ERR: SQL not supported: DISTINCT is only supported on COUNT"
    )
    _check(
        "SELECT count(DISTINCT *) FROM t",
        "ERR: SQL bind error: COUNT(DISTINCT *) is not valid"
    )


def test_statistical_aggregates() raises:
    _check(
        "SELECT median(v), stddev(v), stddev_samp(v), var_samp(v), variance(v), var_pop(v), stddev_pop(v), sem(v) FROM t",
        "Project(exprs=[ColRef(median(v)), ColRef(stddev(v)), ColRef(stddev_samp(v)), ColRef(var_samp(v)), ColRef(variance(v)), ColRef(var_pop(v)), ColRef(stddev_pop(v)), ColRef(sem(v))])\n"
        "  Aggregate(group_by=[], aggs=[MEDIAN(ColRef(v)).alias(\"median(v)\"), STDDEV_SAMP(ColRef(v)).alias(\"stddev(v)\"), STDDEV_SAMP(ColRef(v)).alias(\"stddev_samp(v)\"), VAR_SAMP(ColRef(v)).alias(\"var_samp(v)\"), VAR_SAMP(ColRef(v)).alias(\"variance(v)\"), VAR_POP(ColRef(v)).alias(\"var_pop(v)\"), STDDEV_POP(ColRef(v)).alias(\"stddev_pop(v)\"), SEM(ColRef(v)).alias(\"sem(v)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT count_star(), count_if(b), countif(b), bool_and(b), bool_or(b), product(v) FROM t",
        "Project(exprs=[ColRef(count_star()), ColRef(count_if(b)), ColRef(countif(b)), ColRef(bool_and(b)), ColRef(bool_or(b)), ColRef(product(v))])\n"
        "  Aggregate(group_by=[], aggs=[COUNT(*).alias(\"count_star()\"), COUNT_IF(ColRef(b)).alias(\"count_if(b)\"), COUNT_IF(ColRef(b)).alias(\"countif(b)\"), BOOL_AND(ColRef(b)).alias(\"bool_and(b)\"), BOOL_OR(ColRef(b)).alias(\"bool_or(b)\"), PRODUCT(ColRef(v)).alias(\"product(v)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT first(v), arbitrary(v), last(v), any_value(v), fsum(v), kahan_sum(v), sumkahan(v), favg(v), skewness(v), kurtosis(v), kurtosis_pop(v) FROM t",
        "Project(exprs=[ColRef(first(v)), ColRef(arbitrary(v)), ColRef(last(v)), ColRef(any_value(v)), ColRef(fsum(v)), ColRef(kahan_sum(v)), ColRef(sumkahan(v)), ColRef(favg(v)), ColRef(skewness(v)), ColRef(kurtosis(v)), ColRef(kurtosis_pop(v))])\n"
        "  Aggregate(group_by=[], aggs=[FIRST(ColRef(v)).alias(\"first(v)\"), FIRST(ColRef(v)).alias(\"arbitrary(v)\"), LAST(ColRef(v)).alias(\"last(v)\"), ANY_VALUE(ColRef(v)).alias(\"any_value(v)\"), KAHAN_SUM(ColRef(v)).alias(\"fsum(v)\"), KAHAN_SUM(ColRef(v)).alias(\"kahan_sum(v)\"), KAHAN_SUM(ColRef(v)).alias(\"sumkahan(v)\"), KAHAN_AVG(ColRef(v)).alias(\"favg(v)\"), SKEWNESS(ColRef(v)).alias(\"skewness(v)\"), KURTOSIS(ColRef(v)).alias(\"kurtosis(v)\"), KURTOSIS_POP(ColRef(v)).alias(\"kurtosis_pop(v)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT corr(v, k), covar_pop(v, k), covar_samp(v, k), regr_slope(v, k), regr_intercept(v, k), regr_r2(v, k), regr_count(v, k), regr_avgx(v, k), regr_avgy(v, k), regr_sxx(v, k), regr_syy(v, k), regr_sxy(v, k) FROM t",
        "Project(exprs=[ColRef(corr(v, k)), ColRef(covar_pop(v, k)), ColRef(covar_samp(v, k)), ColRef(regr_slope(v, k)), ColRef(regr_intercept(v, k)), ColRef(regr_r2(v, k)), ColRef(regr_count(v, k)), ColRef(regr_avgx(v, k)), ColRef(regr_avgy(v, k)), ColRef(regr_sxx(v, k)), ColRef(regr_syy(v, k)), ColRef(regr_sxy(v, k))])\n"
        "  Aggregate(group_by=[], aggs=[CORR(ColRef(v), ColRef(k)).alias(\"corr(v, k)\"), COVAR_POP(ColRef(k), ColRef(v)).alias(\"covar_pop(v, k)\"), COVAR_SAMP(ColRef(k), ColRef(v)).alias(\"covar_samp(v, k)\"), REGR_SLOPE(ColRef(k), ColRef(v)).alias(\"regr_slope(v, k)\"), REGR_INTERCEPT(ColRef(k), ColRef(v)).alias(\"regr_intercept(v, k)\"), REGR_R2(ColRef(k), ColRef(v)).alias(\"regr_r2(v, k)\"), REGR_COUNT(ColRef(k), ColRef(v)).alias(\"regr_count(v, k)\"), REGR_AVGX(ColRef(k), ColRef(v)).alias(\"regr_avgx(v, k)\"), REGR_AVGY(ColRef(k), ColRef(v)).alias(\"regr_avgy(v, k)\"), REGR_SXX(ColRef(k), ColRef(v)).alias(\"regr_sxx(v, k)\"), REGR_SYY(ColRef(k), ColRef(v)).alias(\"regr_syy(v, k)\"), REGR_SXY(ColRef(k), ColRef(v)).alias(\"regr_sxy(v, k)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT median(v, k) FROM t",
        "ERR: SQL bind error: median() expects exactly 1 argument"
    )
    _check(
        "SELECT corr(v) FROM t",
        "ERR: SQL bind error: corr() expects exactly 2 arguments"
    )
    _check(
        "SELECT regr_slope(v) FROM t",
        "ERR: SQL bind error: regr_slope() expects exactly 2 arguments — the SQL spelling is regr_slope(y, x), the DEPENDENT variable first"
    )
    _check(
        "SELECT count_star(v) FROM t",
        "ERR: SQL bind error: count_star() expects exactly 0 arguments"
    )
    _check(
        "SELECT stddev(v, k) FROM t",
        "ERR: SQL bind error: stddev() expects exactly 1 argument"
    )


def test_unaliased_aggregate_names() raises:
    _check(
        "SELECT count(*), max(k) FROM t",
        "Project(exprs=[ColRef(count_star()), ColRef(max(k))])\n"
        "  Aggregate(group_by=[], aggs=[COUNT(*).alias(\"count_star()\"), MAX(ColRef(k)).alias(\"max(k)\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT max(k), max(k) FROM t",
        "Project(exprs=[ColRef(max(k)), ColRef(max(k)_1)])\n"
        "  Aggregate(group_by=[], aggs=[MAX(ColRef(k)).alias(\"max(k)\"), MAX(ColRef(k)).alias(\"max(k)_1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT sum(v) AS a, sum(v) AS b FROM t",
        "Project(exprs=[ColRef(a), ColRef(b)])\n"
        "  Aggregate(group_by=[], aggs=[SUM(ColRef(v)).alias(\"a\"), SUM(ColRef(v)).alias(\"b\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT median(v), median(v) FROM t",
        "Project(exprs=[ColRef(median(v)), ColRef(median(v)_1)])\n"
        "  Aggregate(group_by=[], aggs=[MEDIAN(ColRef(v)).alias(\"median(v)\"), MEDIAN(ColRef(v)).alias(\"median(v)_1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT max(k) AS k FROM t",
        "Project(exprs=[ColRef(k)])\n"
        "  Aggregate(group_by=[], aggs=[MAX(ColRef(k)).alias(\"k\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT g, max(k) AS g FROM t GROUP BY g",
        "Project(exprs=[ColRef(g), Alias(ColRef(_agg_as_1_g), \"g\")])\n"
        "  Aggregate(group_by=[ColRef(g)], aggs=[MAX(ColRef(k)).alias(\"_agg_as_1_g\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT g, max(k) AS g FROM t GROUP BY g HAVING max(k) > 2 ORDER BY g",
        "Sort(keys=[g ASC])\n"
        "  Project(exprs=[ColRef(g), Alias(ColRef(_agg_as_1_g), \"g\")])\n"
        "    Filter(predicate=BinaryOp(GT, ColRef(_agg_as_1_g), Literal(ScalarValue(int64, 2))))\n"
        "      Aggregate(group_by=[ColRef(g)], aggs=[MAX(ColRef(k)).alias(\"_agg_as_1_g\")])\n"
        "        Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT max(v) - min(v) FROM t",
        "Project(exprs=[BinaryOp(SUB, ColRef(_agg_x0), ColRef(_agg_x1))])\n"
        "  Aggregate(group_by=[], aggs=[MAX(ColRef(v)).alias(\"_agg_x0\"), MIN(ColRef(v)).alias(\"_agg_x1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_expressions_over_aggregates() raises:
    _check(
        "SELECT k, sum(v) / count(*) AS r, 100.0 * sum(v) / sum(g) AS p, max(v) - min(v) AS m FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(BinaryOp(DIV, ColRef(_agg_x0), ColRef(_agg_x1)), \"r\"), Alias(BinaryOp(DIV, BinaryOp(MUL, Literal(ScalarValue(float64, 100.0)), ColRef(_agg_x0)), ColRef(_agg_x2)), \"p\"), Alias(BinaryOp(SUB, ColRef(_agg_x3), ColRef(_agg_x4)), \"m\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"_agg_x0\"), COUNT(*).alias(\"_agg_x1\"), SUM(ColRef(g)).alias(\"_agg_x2\"), MAX(ColRef(v)).alias(\"_agg_x3\"), MIN(ColRef(v)).alias(\"_agg_x4\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(k) / count(*) AS r FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(BinaryOp(DIV, Cast(ColRef(_agg_x0), float64), ColRef(_agg_x1)), \"r\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(k)).alias(\"_agg_x0\"), COUNT(*).alias(\"_agg_x1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) / sum(k) AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(BinaryOp(DIV, ColRef(_agg_x0), ColRef(_agg_x1)), \"c\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"_agg_x0\"), SUM(ColRef(k)).alias(\"_agg_x1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) // count(*) AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(When(WHEN BinaryOp(EQ, ColRef(_agg_x1), Literal(ScalarValue(int64, 0))) THEN Literal(ScalarValue(null, float64)), ELSE BinaryOp(DIV, ColRef(_agg_x0), ColRef(_agg_x1))), \"c\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"_agg_x0\"), COUNT(*).alias(\"_agg_x1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) // 2 AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(BinaryOp(DIV, ColRef(_agg_x0), Literal(ScalarValue(int64, 2))), \"c\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"_agg_x0\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sqrt(var_samp(v)) AS sd, exp(avg(v)) AS e, abs(sum(v)) AS a, pow(corr(v, k), 2) AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(MathFn(op=2, ColRef(_agg_x0)), \"sd\"), Alias(MathFn(op=8, ColRef(_agg_x1)), \"e\"), Alias(UnaryOp(ABS, ColRef(_agg_x2)), \"a\"), Alias(MathFn2(op=1, ColRef(_agg_x3), Literal(ScalarValue(int64, 2))), \"c\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[VAR_SAMP(ColRef(v)).alias(\"_agg_x0\"), MEAN(ColRef(v)).alias(\"_agg_x1\"), SUM(ColRef(v)).alias(\"_agg_x2\"), CORR(ColRef(v), ColRef(k)).alias(\"_agg_x3\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, avg(v) + 1 AS a FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(BinaryOp(ADD, ColRef(_agg_x0), Literal(ScalarValue(int64, 1))), \"a\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[MEAN(ColRef(v)).alias(\"_agg_x0\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, CASE WHEN sum(v) > 1 THEN 1 ELSE 0 END AS c FROM t GROUP BY k",
        "ERR: SQL bind error: unsupported expression"
    )
    _check(
        "SELECT k, sum(CASE WHEN g > 1 THEN v ELSE 0 END) AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(c)])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(When(WHEN BinaryOp(GT, ColRef(g), Literal(ScalarValue(int64, 1))) THEN ColRef(v), ELSE Literal(ScalarValue(float64, 0.0)))).alias(\"c\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(k) ^ 2 AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(MathFn2(op=1, ColRef(_agg_x0), Literal(ScalarValue(int64, 2))), \"c\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(k)).alias(\"_agg_x0\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, upper(max(s)) FROM t GROUP BY k",
        "ERR: SQL not supported: scalar function 'upper' applied to an aggregate result. The aggregate itself is allowed in this position — `HAVING SUM(v) > 10` binds; what this engine cannot lower yet is a call WRAPPING one, outside the math families whose aggregate arguments it hoists"
    )
    _check(
        "SELECT k, max(s) || 'x' AS c FROM t GROUP BY k",
        "ERR: SQL not supported: the `||` string-concatenation operator. DuckDB's `||` PROPAGATES NULL (`'a' || NULL` is NULL) where this engine's only concatenation, `concat()`, SKIPS a NULL operand (`concat('a', NULL)` is 'a'), and answering one for the other would be wrong on every row with a NULL. The missing primitive is a STRING-typed NULL value in the plan (the CASE that would propagate the NULL has no string NULL to return). `concat(a, b)` is served for the NULL-skipping answer, and is EXACT wherever neither operand can be NULL."
    )
    _check(
        "SELECT k, max(s) ^@ 'a' AS c FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), Alias(StringOp(STARTS_WITH, ColRef(_agg_x0), \"a\"), \"c\")])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(s)).alias(\"_agg_x0\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) % 3 FROM t GROUP BY k",
        "ERR: SQL not supported: `%` (modulo) over a GROUP BY / aggregate result (`sum(v) % 3`, `HAVING g % 2 = 1`). The engine does not lower `%` (modulo) above an aggregate yet; the same refusal as `mod(sum(v), 3)`. For INTEGER operands `x - x // n * n` is the same value and is served."
    )
    _check(
        "SELECT k, -sum(v) FROM t GROUP BY k",
        "ERR: SQL not supported: unary minus over a GROUP BY / aggregate result (`-sum(v)`, `ORDER BY -count(*)`). The engine does not lower unary minus above an aggregate yet; `sum(v) * -1` is served."
    )
    _check(
        "SELECT k, max(18446744073709551615 = u64) FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(max((18446744073709551615 = u64)))])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[MAX(BinaryOp(EQ, Literal(ScalarValue(uint64, -1)), ColRef(u64))).alias(\"max((18446744073709551615 = u64))\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_one_accumulator_per_distinct_aggregate() raises:
    _check(
        "SELECT k, sum(v), sum(v) FROM t GROUP BY k",
        "Project(exprs=[ColRef(k), ColRef(sum(v)), ColRef(sum(v)_1)])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"sum(v)\"), SUM(ColRef(v)).alias(\"sum(v)_1\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) AS sq FROM t GROUP BY k HAVING sum(v) > 300",
        "Project(exprs=[ColRef(k), ColRef(sq)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(sq), Literal(ScalarValue(int64, 300))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"sq\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, regr_slope(v, k) FROM t GROUP BY k HAVING regr_slope(v, k) > 0 AND regr_slope(k, v) > 0",
        "Project(exprs=[ColRef(k), ColRef(regr_slope(v, k))])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(regr_slope(v, k)), Literal(ScalarValue(int64, 0))), BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 0)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[REGR_SLOPE(ColRef(k), ColRef(v)).alias(\"regr_slope(v, k)\"), REGR_SLOPE(ColRef(v), ColRef(k)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k HAVING sum(k) > 1 AND sum(k) < 9",
        "Project(exprs=[ColRef(k), ColRef(sum(v))])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 1))), BinaryOp(LT, ColRef(_agg_x0), Literal(ScalarValue(int64, 9)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"sum(v)\"), SUM(ColRef(k)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k HAVING count(*) * 2 > count(DISTINCT s)",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Filter(predicate=BinaryOp(GT, BinaryOp(MUL, ColRef(count_star()), Literal(ScalarValue(int64, 2))), ColRef(_agg_x0)))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\"), COUNT_DISTINCT(ColRef(s)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_having() raises:
    _check(
        "SELECT k, sum(v) AS s FROM t GROUP BY k HAVING sum(v) > 1",
        "Project(exprs=[ColRef(k), ColRef(s)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(s), Literal(ScalarValue(int64, 1))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"s\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) AS s FROM t GROUP BY k HAVING s > 1",
        "Project(exprs=[ColRef(k), ColRef(s)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(s), Literal(ScalarValue(int64, 1))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"s\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING count(*) > 100",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 100))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k HAVING sum(v) > 1 AND count(*) > 2",
        "Project(exprs=[ColRef(k), ColRef(sum(v))])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(sum(v)), Literal(ScalarValue(int64, 1))), BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(int64, 2)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"sum(v)\"), COUNT(*).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) AS sv FROM t GROUP BY k HAVING sum(v) > 1 OR sum(v) < 0",
        "Project(exprs=[ColRef(k), ColRef(sv)])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(GT, ColRef(sv), Literal(ScalarValue(int64, 1))), BinaryOp(LT, ColRef(sv), Literal(ScalarValue(int64, 0)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"sv\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(s) ILIKE 'a%'",
        "ERR: SQL not supported: ILIKE over a GROUP BY / aggregate result (`HAVING s ILIKE 'a%'`, `min(s) ILIKE 'a%'`). The engine does not lower ILIKE above an aggregate yet; LIKE is served in this position."
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(s) LIKE 'a%'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=StringOp(LIKE, ColRef(_agg_x0), \"a%\"))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(s)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k HAVING max(s) LIKE 'a%' AND min(s) NOT LIKE 'b%'",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Filter(predicate=BinaryOp(AND, StringOp(LIKE, ColRef(_agg_x0), \"a%\"), UnaryOp(NOT, StringOp(LIKE, ColRef(_agg_x1), \"b%\"))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\"), MAX(ColRef(s)).alias(\"_agg_x0\"), MIN(ColRef(s)).alias(\"_agg_x1\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING sum(v) IS NULL",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=UnaryOp(IS_NULL, ColRef(_agg_x0)))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING sum(v) = NULL",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(_agg_x0), Literal(ScalarValue(null, int64))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING k > 1 AND true",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))), Literal(ScalarValue(bool, true))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING d > DATE '2021-01-01'",
        "ERR: SQL bind error: column 'd' must be a GROUP BY column or an aggregate output"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(ts) > TIMESTAMP '2021-01-01'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(timestamp[us], 1609459200000000))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(ts)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(s) = 'x'",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(_agg_x0), Literal(ScalarValue(utf8, \"x\"))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(s)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(v) > 1.5",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(_agg_x0), Literal(ScalarValue(float64, 1.5))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[MAX(ColRef(v)).alias(\"_agg_x0\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING sum(k) > 18446744073709551615",
        "ERR: SQL not supported: the integer literal 18446744073709551615 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING max(u64) = 18446744073709551615",
        "ERR: SQL not supported: the integer literal 18446744073709551615 is past BIGINT (9223372036854775807). DuckDB types it HUGEINT, a type this engine has no literal or column for; it is served only as one side of a comparison (= <> < <= > >=) against a plain column, when it fits UBIGINT (<= 18446744073709551615)."
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING sqrt(sum(v), 1) > 0",
        "ERR: SQL bind error: sqrt() expects exactly 1 argument — got 2"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING pow(sum(v)) > 0",
        "ERR: SQL bind error: pow() expects exactly 2 arguments (base, exponent)"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING v > 1",
        "ERR: SQL bind error: column 'v' must be a GROUP BY column or an aggregate output"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING * > 1",
        "ERR: SQL bind error: '*' not allowed in this position"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING date_diff('day', DATE '2021-01-01', DATE '2021-01-02') > 0",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, Literal(ScalarValue(int64, 1)), Literal(ScalarValue(int64, 0))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k FROM t GROUP BY k HAVING t.k > 1",
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(GT, ColRef(k), Literal(ScalarValue(int64, 1))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, count(*) FROM t GROUP BY k HAVING k IN (1, 2)",
        "Project(exprs=[ColRef(k), ColRef(count_star())])\n"
        "  Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 2)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k HAVING sum(v) BETWEEN 1 AND 2",
        "Project(exprs=[ColRef(k), ColRef(sum(v))])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GE, ColRef(sum(v)), Literal(ScalarValue(int64, 1))), BinaryOp(LE, ColRef(sum(v)), Literal(ScalarValue(int64, 2)))))\n"
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"sum(v)\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )
    _check(
        "SELECT k, sum(v) FROM t GROUP BY k HAVING sum(v) = (SELECT max(w) FROM u)",
        "ERR: SQL bind error: unsupported expression"
    )
    _check(
        "SELECT 1 AS one, count(*) FROM t GROUP BY one HAVING one = 1",
        "ERR: SQL bind error: column 'one' must be a GROUP BY column or an aggregate output"
    )
    _check(
        "SELECT s, count(*) FROM t GROUP BY s HAVING s = 'A'",
        "Project(exprs=[ColRef(s), ColRef(count_star())])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(s), Literal(ScalarValue(utf8, \"A\"))))\n"
        "    Aggregate(group_by=[ColRef(s)], aggs=[COUNT(*).alias(\"count_star()\")])\n"
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
    )


def test_deparse_names_of_expressions() raises:
    _check(
        "SELECT count(*) + count(k), sum(v + 1), max(k IS NULL), max(s LIKE 'x%'), max(s NOT LIKE 'y%'), min(DATE '1995-03-15'), max(true), max(false), max(-k), max(@k), sum(abs(k)), count(CASE WHEN k > 1 THEN 1 ELSE 0 END), max(CAST(v AS DOUBLE)), max(TRY_CAST(k AS DOUBLE)), max(position('b' IN s)), max(k || 'x'), max(k ^ 2), max(s ^@ 'a'), max(1.5), max('x'), max(TIMESTAMP '2021-01-01 00:00:00'), max(TIMESTAMPTZ '2021-01-01 00:00:00+00'), max(NOT b), mean(v), MEAN(v), SUM(K) FROM t",
        "ERR: SQL not supported: TRY_CAST. Its contract is to answer NULL where the cast fails, so a gap in the underlying cast becomes an INVISIBLE wrong answer rather than an error. Two known ones: TRY_CAST('3.5' AS BIGINT) is 4 in DuckDB v1.5.3 and would be NULL here (`cast_string_to_int64` in komira_kernels parses an integer spelling only), and TRY_CAST(<INT64_MIN> AS INTEGER) is NULL there and would not be here (`eval_cast`, the integer cast in komira_column_kernels, has no null-on-overflow arm). Use CAST(x AS DOUBLE), which refuses loudly instead."
    )
    _check(
        "SELECT mean(v), MEAN(v), avg(v), SUM(K), max(t.k) FROM t",
        "Project(exprs=[ColRef(mean(v)), ColRef(mean(v)_1), ColRef(avg(v)), ColRef(sum(k)), ColRef(max(t.k))])\n"
        "  Aggregate(group_by=[], aggs=[MEAN(ColRef(v)).alias(\"mean(v)\"), MEAN(ColRef(v)).alias(\"mean(v)_1\"), MEAN(ColRef(v)).alias(\"avg(v)\"), SUM(ColRef(k)).alias(\"sum(k)\"), MAX(ColRef(k)).alias(\"max(t.k)\")])\n"
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
        "    Aggregate(group_by=[ColRef(k)], aggs=[SUM(Literal(ScalarValue(int64, 1))).alias(\"a\")])\n"
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
