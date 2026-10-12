# =============================================================================
# Direct tests of the SQL binder's entry (sql_binder.bind_statement)
# =============================================================================
#
# Every query binds against a catalog of parquet tables registered with a
# given schema (`add_parquet` opens no file) and `NoParquetFooters`, so no
# test reads a file. What each test proves, and the defect (mutant) it
# catches:
#   1. `SELECT k, sum(v) AS total FROM t GROUP BY k` binds to an aggregate
#      whose output columns are k, total, keyed on k.
#      (mutant caught: the aggregate is built with no group keys)
#   2. An unknown column raises "SQL bind error: unknown column 'zzz'".
#      (mutant caught: `_resolve_col` returns the name without checking it)
#   3. An unknown function raises the unknown-function error; `upper(s, s)`
#      raises the arity error; `coalesce(v)` binds to `v` itself.
#      (mutant caught: the arity check in `_bind_scalar_call` is deleted)
#   4. `t LEFT JOIN u ON t.k = u.k` binds to a LEFT join on k = k.
#      (mutant caught: the LEFT arm builds an INNER join)
#   5. A correlated `WHERE EXISTS` binds to a SEMI join and `WHERE NOT
#      EXISTS` to an ANTI join.
#      (mutant caught: CORR_KIND_EXISTS and CORR_KIND_NOT_EXISTS swapped)

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_ir.logical_plan import LogicalPlan

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters
from komira_sql.sql_binder import bind_statement


def _catalog() -> SqlCatalog:
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("k"), ArrowType.INT64, False))
    t.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("k"), ArrowType.INT64, False))
    u.add_field(Field(String("w"), ArrowType.INT64, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    return cat^


def _plan(sql: String) raises -> String:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    return String(plan)


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


def test_group_by_aggregate_names_its_outputs_and_keys() raises:
    assert_equal(
        _plan("SELECT k, sum(v) AS total FROM t GROUP BY k"),
        "Project(exprs=[ColRef(k), ColRef(total)])\n"
        "  Aggregate(group_by=[ColRef(k)], aggs=[SUM(ColRef(v)).alias(\"total\")])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_unknown_column_is_refused_by_name() raises:
    assert_equal(
        _err("SELECT zzz FROM t"), "SQL bind error: unknown column 'zzz'"
    )


def test_unknown_function_arity_and_coalesce() raises:
    assert_equal(
        _err("SELECT nosuchfn(k) FROM t"),
        "SQL not supported: scalar function 'nosuchfn'. No UDFs are declared"
        " on this catalog either — declare one with `catalog.declare_udf(f)`",
    )
    assert_equal(
        _err("SELECT upper(s, s) FROM t"),
        "SQL bind error: upper() expects exactly 1 argument — got 2",
    )
    # coalesce's row is FN_ARITY_OWN: one argument binds to the argument.
    assert_equal(
        _plan("SELECT coalesce(v) AS c FROM t"),
        "Project(exprs=[Alias(ColRef(v), \"c\")])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_left_join_binds_a_left_join_on_the_keys() raises:
    assert_equal(
        _plan("SELECT * FROM t LEFT JOIN u ON t.k = u.k"),
        "Project(exprs=[ColRef(k), ColRef(v), ColRef(s), Alias(ColRef(k_right),"
        " \"k\"), ColRef(w)])\n"
        "  Join(type=LEFT, on=[k=k])\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def test_exists_is_semi_and_not_exists_is_anti() raises:
    # kind=0 is CORR_KIND_EXISTS (a SEMI join), kind=1 CORR_KIND_NOT_EXISTS.
    assert_equal(
        _plan("SELECT k FROM t WHERE EXISTS (SELECT 1 FROM u WHERE u.k = t.k)"),
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=0, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    assert_equal(
        _plan(
            "SELECT k FROM t WHERE NOT EXISTS (SELECT 1 FROM u WHERE u.k = t.k)"
        ),
        "Project(exprs=[ColRef(k)])\n"
        "  Filter(predicate=CorrelatedSubquery(kind=1, outer_refs=#1, inner_tag=1))\n"
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
