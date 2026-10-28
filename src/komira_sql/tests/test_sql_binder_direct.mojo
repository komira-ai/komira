# =============================================================================
# Direct tests of the SQL binder's entry (sql_binder.bind_statement)
# =============================================================================
#
# Every query binds against a catalog of parquet tables registered with a
# given schema (`add_parquet` opens no file) and `NoParquetFooters`, so no
# test reads a file. What each test proves:
#   1. `SELECT k, sum(v) AS total FROM t GROUP BY k` binds to an aggregate
#      whose output columns are k, total, keyed on k.
#   2. An unknown column raises "SQL bind error: unknown column 'zzz'".
#   3. An unknown function raises the unknown-function error; `upper(s, s)`
#      raises the arity error; `coalesce(v)` binds to `v` itself.
#   4. `t LEFT JOIN u ON t.k = u.k` binds to a LEFT join on k = k.
#   5. A correlated `WHERE EXISTS` binds to a SEMI join and `WHERE NOT
#      EXISTS` to an ANTI join.
#   6. A CTE name used twice, a derived-table column list of the wrong length,
#      a UNION ALL whose branches differ in column count or type, `SELECT *`
#      with no FROM, a window beside GROUP BY, a DISTINCT over two items of
#      one name and OFFSET without LIMIT are each refused by name; a
#      derived-table column list renames the columns; LIMIT with OFFSET binds
#      a row window.
#   7. DISTINCT, ORDER BY on a selected, an output or an unselected column and
#      a result with two columns of one name bind (the unselected sort column
#      is pruned above the sort); ORDER BY an unselected column beside two
#      items of one name is refused.
#   8. A COPY with no destination and a CREATE TABLE AS with no target (built
#      by hand, the parser refuses both) are refused; a statement with no FROM
#      tables is refused.
#   8. `COPY (query) TO path (FORMAT csv)` binds the query and keeps the
#      destination, format and codec; `CREATE TABLE x AS query` binds the
#      query and keeps the target name; a plain query keeps neither.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.write_target import WFMT_CSV, WCOMP_UNCOMPRESSED
from komira_plan_ir.logical_plan import LogicalPlan

from komira_sql.sql_token import tokenize
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_bind_parquet import NoParquetFooters
from komira_sql.sql_ast import STMT_COPY, STMT_CREATE_TABLE_AS, STMT_QUERY
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


def test_copy_and_create_table_as_keep_their_targets() raises:
    var cat = _catalog()
    var copy = bind_statement(
        parse_sql(tokenize("COPY (SELECT k FROM t) TO 'out.csv' (FORMAT csv)")),
        cat, NoParquetFooters(),
    )
    assert_equal(Int(copy.kind), Int(STMT_COPY))
    assert_equal(copy.dest_path, "out.csv")
    assert_equal(Int(copy.fmt), Int(WFMT_CSV))
    assert_equal(Int(copy.codec), Int(WCOMP_UNCOMPRESSED))
    assert_equal(copy.register_as, "")
    assert_equal(
        String(copy.take_plan()),
        "Project(exprs=[ColRef(k)])\n"
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n",
    )
    var ctas = bind_statement(
        parse_sql(tokenize("CREATE TABLE x AS SELECT k FROM t")),
        cat, NoParquetFooters(),
    )
    assert_equal(Int(ctas.kind), Int(STMT_CREATE_TABLE_AS))
    assert_equal(ctas.register_as, "x")
    assert_equal(ctas.dest_path, "")
    var query = bind_statement(
        parse_sql(tokenize("SELECT k FROM t")), cat, NoParquetFooters()
    )
    assert_equal(Int(query.kind), Int(STMT_QUERY))
    assert_equal(query.register_as, "")
    assert_equal(query.dest_path, "")


def _err_starts(sql: String, prefix: String) raises:
    var msg = _err(sql)
    assert_true(msg.startswith(prefix), msg)


def test_with_and_derived_table_refusals() raises:
    assert_equal(
        _err("WITH a AS (SELECT k FROM t), a AS (SELECT k FROM u) SELECT k FROM a"),
        "SQL bind error: duplicate CTE name 'a'",
    )
    assert_equal(
        _err("SELECT * FROM (SELECT k, v FROM t) d (a)"),
        "SQL bind error: derived-table 'd' column list has 1 names but its"
        " SELECT produces 2 columns",
    )
    assert_true(
        "Alias(ColRef(k), \"a\")"
        in _plan("SELECT a FROM (SELECT k FROM t) d (a)")
    )


def test_union_all_branches_must_agree() raises:
    _err_starts(
        "SELECT k FROM t UNION ALL SELECT k, w FROM u",
        "SQL bind error: UNION ALL branch 2 produces 2 column(s) but the first"
        " branch produces 1",
    )
    _err_starts(
        "SELECT k FROM t UNION ALL SELECT s FROM t",
        "SQL not supported: UNION ALL over branches whose column 1 differs in TYPE",
    )


def test_select_shape_refusals() raises:
    _err_starts("SELECT *", "SQL bind error: * expression without FROM clause")
    _err_starts(
        "SELECT k, sum(v) OVER (PARTITION BY k) FROM t GROUP BY k",
        "SQL not supported: a window function combined with GROUP BY",
    )
    _err_starts(
        "SELECT DISTINCT t.k AS k, u.k AS k FROM t, u",
        "SQL not supported: SELECT DISTINCT over two items both named `k`",
    )
    _err_starts(
        "SELECT k FROM t OFFSET 1",
        "SQL not supported: OFFSET without LIMIT",
    )


def test_limit_with_offset_binds_a_row_window() raises:
    var plan = _plan("SELECT k FROM t ORDER BY k LIMIT 3 OFFSET 2")
    assert_true("Limit(n=3, offset=2)\n" in plan, plan)
    var plain = _plan("SELECT k FROM t LIMIT 3")
    assert_true("Limit(n=3)\n" in plain, plain)


def test_distinct_and_order_by_shapes() raises:
    var distinct = _plan("SELECT DISTINCT k FROM t")
    assert_true("Distinct(" in distinct, distinct)
    var by_col = _plan("SELECT k FROM t ORDER BY k")
    assert_true("Sort(keys=[" in by_col, by_col)
    var by_out = _plan("SELECT k AS x FROM t ORDER BY x")
    assert_true("Sort(keys=[" in by_out, by_out)
    var by_hidden = _plan("SELECT k FROM t ORDER BY v")
    assert_true("Sort(keys=[" in by_hidden, by_hidden)
    assert_true(by_hidden.startswith("Project(exprs=[ColRef(k)])\n"), by_hidden)
    var by_expr = _plan("SELECT k FROM t ORDER BY k + 1")
    assert_true("Sort(keys=[" in by_expr, by_expr)
    _err_starts(
        "SELECT t.k AS k, u.k AS k FROM t, u ORDER BY w",
        "SQL not supported: two SELECT items are both named `k` and ORDER BY",
    )


def test_result_with_two_columns_of_one_name_keeps_both() raises:
    var plain = _plan("SELECT t.k, u.k FROM t, u")
    assert_true("Project(" in plain, plain)
    var limited = _plan("SELECT t.k, u.k FROM t, u LIMIT 2")
    assert_true("Limit(n=2)\n" in limited, limited)
    var sorted_hidden = _plan("SELECT t.k, u.k FROM t, u ORDER BY w")
    assert_true("Sort(keys=[" in sorted_hidden, sorted_hidden)


def test_hand_built_statements_without_a_target_are_refused() raises:
    var cat = _catalog()
    var copy = parse_sql(tokenize("COPY t TO 'o'"))
    copy.dest_path = String("")
    try:
        _ = bind_statement(copy, cat, NoParquetFooters())
        raise Error("bound a COPY with no destination")
    except e:
        assert_equal(
            String(e), "SQL bind error: COPY ... TO requires a destination path"
        )
    var ctas = parse_sql(tokenize("CREATE TABLE x AS SELECT k FROM t"))
    ctas.target_table = String("")
    try:
        _ = bind_statement(ctas, cat, NoParquetFooters())
        raise Error("bound a CREATE TABLE AS with no target")
    except e:
        assert_equal(
            String(e),
            "SQL bind error: CREATE TABLE AS requires a target table name",
        )
    var bare = parse_sql(tokenize("SELECT k FROM t"))
    bare.query.from_tables.clear()
    try:
        _ = bind_statement(bare, cat, NoParquetFooters())
        raise Error("bound a SELECT with no FROM tables")
    except e:
        assert_equal(String(e), "SQL bind error: FROM clause has no tables")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
