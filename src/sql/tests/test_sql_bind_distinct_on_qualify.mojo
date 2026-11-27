# =============================================================================
# SELECT DISTINCT ON, QUALIFY and SELECT * beside a window function, bound
# through the statement binder (`plan_from_sql`)
# =============================================================================
#
# Each query binds against parquet table t(id BIGINT NOT NULL, name VARCHAR,
# o BIGINT, k BIGINT) and the test compares the plan text or the binder's
# message. The answers these plans give are held to DuckDB's by the sql_e2e
# cases distinct_on*, qualify* and window_star.
#   1. DISTINCT ON keeps one row per key: a ROW_NUMBER partitioned by the keys
#      and ordered by the WHOLE ORDER BY (its direction and NULL placement),
#      a filter on 1 and a Project dropping the row number, all over the SELECT
#      output and under the sort; with no ORDER BY the window has no order.
#   2. A DISTINCT ON key resolves to an output column: an ordinal, an ORDER BY
#      key written the same way (carried when not selected), a selected or an
#      unselected input column (carried, then pruned at the root), an alias, a
#      SELECT item's expression; a repeated key partitions once.
#   3. DISTINCT ON refusals: a key that is no output column and cannot be
#      carried, an ordinal out of range, two output columns of one name.
#   4. QUALIFY filters between the window nodes and the Project: an inline
#      window becomes a hidden PARTITION BY column, a window item's alias is
#      its column, a non-window item's alias is its expression, an input
#      column beats an alias of its name, an unselected input column is
#      visible; it sits under DISTINCT, ORDER BY and LIMIT.
#   5. QUALIFY with no window function anywhere is DuckDB's Binder Error, with
#      or without GROUP BY; a window in QUALIFY beside GROUP BY keeps the
#      window-beside-aggregation refusal.
#   6. SELECT * beside a window projects every input column in order, also
#      with QUALIFY and with DISTINCT ON.
#   7. A subquery body: DISTINCT ON / QUALIFY in an EXISTS body and in a
#      correlated scalar body are refused by name; in a derived table and an
#      IN body they bind.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder

from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_catalog import SqlCatalog
from sql.sql_frontend import plan_from_sql


comptime _SCAN = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _RN = "ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __distinct_on_rn"
comptime _KEEP1 = "Filter(predicate=BinaryOp(EQ, ColRef(__distinct_on_rn), Literal(ScalarValue(int64, 1))))\n"


def _catalog() raises -> SqlCatalog:
    """t(id BIGINT NOT NULL, name VARCHAR, o BIGINT, k BIGINT) and
    u(id BIGINT NOT NULL, k BIGINT)."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("id"), ArrowType.INT64, False))
    t.add_field(Field(String("name"), ArrowType.STRING, True))
    t.add_field(Field(String("o"), ArrowType.INT64, True))
    t.add_field(Field(String("k"), ArrowType.INT64, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("id"), ArrowType.INT64, False))
    u.add_field(Field(String("k"), ArrowType.INT64, True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    return cat^


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the binder's message."""
    var cat = _catalog()
    try:
        return String(plan_from_sql(sql, cat, NoParquetFooters()))
    except e:
        return String("ERR: ") + String(e)


def _check(sql: String, want: String) raises:
    assert_equal(_got(sql), want, sql)


# --- 1. the DISTINCT ON plan -------------------------------------------------


def test_distinct_on_one_key_keeps_the_first_row_under_order_by() raises:
    _check(
        "SELECT DISTINCT ON (name) id, name FROM t ORDER BY name, id",
        "Sort(keys=[name ASC, id ASC])\n"
        "  Project(exprs=[ColRef(id), ColRef(name)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[name], order=[name ASC, id ASC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(id), ColRef(name)])\n"
        "          " + _SCAN
    )


def test_distinct_on_two_keys_and_an_order_by_not_led_by_them() raises:
    # DuckDB keeps the first row of each (name, o) under `ORDER BY id DESC`:
    # the highest id of the key.
    _check(
        "SELECT DISTINCT ON (name, o) id, name, o FROM t ORDER BY id DESC",
        "Sort(keys=[id DESC])\n"
        "  Project(exprs=[ColRef(id), ColRef(name), ColRef(o)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[name, o], order=[id DESC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(id), ColRef(name), ColRef(o)])\n"
        "          " + _SCAN
    )


def test_distinct_on_order_by_null_placement_reaches_the_window() raises:
    _check(
        "SELECT DISTINCT ON (name) id, name FROM t ORDER BY name NULLS FIRST, id DESC",
        "Sort(keys=[name ASC NULLS FIRST, id DESC])\n"
        "  Project(exprs=[ColRef(id), ColRef(name)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[name], order=[name ASC NULLS FIRST, id DESC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(id), ColRef(name)])\n"
        "          " + _SCAN
    )


def test_distinct_on_without_order_by_has_an_unordered_window() raises:
    _check(
        "SELECT DISTINCT ON (name) name FROM t",
        "Project(exprs=[ColRef(name)])\n"
        "  " + _KEEP1
        + "    PartitionBy(partition=[name], order=[], funcs=[ROW_NUMBER(, offset=0, frame=ROWS[0:0..4:0]) AS __distinct_on_rn])\n"
        "      Project(exprs=[ColRef(name)])\n"
        "        " + _SCAN
    )


# --- 2. resolving a DISTINCT ON key ------------------------------------------


def test_distinct_on_key_not_selected_is_carried_and_pruned() raises:
    _check(
        "SELECT DISTINCT ON (name) id FROM t ORDER BY id",
        "Project(exprs=[ColRef(id)])\n"
        "  Sort(keys=[id ASC])\n"
        "    Project(exprs=[ColRef(id), ColRef(name)])\n"
        "      " + _KEEP1
        + "        PartitionBy(partition=[name], order=[id ASC], funcs=[" + _RN + "])\n"
        "          Project(exprs=[ColRef(id), ColRef(name)])\n"
        "            " + _SCAN
    )


def test_distinct_on_ordinal_alias_and_expression_keys() raises:
    # An ordinal names the SELECT output column.
    _check(
        "SELECT DISTINCT ON (2) id, name FROM t ORDER BY name, id",
        "Sort(keys=[name ASC, id ASC])\n"
        "  Project(exprs=[ColRef(id), ColRef(name)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[name], order=[name ASC, id ASC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(id), ColRef(name)])\n"
        "          " + _SCAN
    )
    # An alias names its item's output column.
    _check(
        "SELECT DISTINCT ON (nm) id, name AS nm FROM t ORDER BY nm, id",
        "Sort(keys=[nm ASC, id ASC])\n"
        "  Project(exprs=[ColRef(id), ColRef(nm)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[nm], order=[nm ASC, id ASC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(id), Alias(ColRef(name), \"nm\")])\n"
        "          " + _SCAN
    )
    # An expression written as an ORDER BY key is that key's carried column.
    _check(
        "SELECT DISTINCT ON (o % 2) id FROM t ORDER BY o % 2, id",
        "Project(exprs=[ColRef(id)])\n"
        "  Sort(keys=[__order_key_0 ASC, id ASC])\n"
        "    Project(exprs=[ColRef(id), ColRef(__order_key_0)])\n"
        "      " + _KEEP1
        + "        PartitionBy(partition=[__order_key_0], order=[__order_key_0 ASC, id ASC], funcs=[" + _RN + "])\n"
        "          Project(exprs=[ColRef(id), Alias(BinaryOp(MOD, ColRef(o), Literal(ScalarValue(int64, 2))), \"__order_key_0\")])\n"
        "            " + _SCAN
    )
    # An expression a SELECT item produces is that item's column; a repeated
    # key partitions once.
    _check(
        "SELECT DISTINCT ON (o % 2, o % 2) o % 2 AS par, id FROM t ORDER BY id",
        "Sort(keys=[id ASC])\n"
        "  Project(exprs=[ColRef(par), ColRef(id)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[par], order=[id ASC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[Alias(BinaryOp(MOD, ColRef(o), Literal(ScalarValue(int64, 2))), \"par\"), ColRef(id)])\n"
        "          " + _SCAN
    )


def test_distinct_on_with_limit_and_no_order_by_keeps_the_limit_on_top() raises:
    _check(
        "SELECT DISTINCT ON (name) name FROM t LIMIT 1",
        "Limit(n=1)\n"
        "  Project(exprs=[ColRef(name)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[name], order=[], funcs=[ROW_NUMBER(, offset=0, frame=ROWS[0:0..4:0]) AS __distinct_on_rn])\n"
        "        Project(exprs=[ColRef(name)])\n"
        "          " + _SCAN
    )


def test_distinct_on_after_qualify() raises:
    # QUALIFY filters first, then DISTINCT ON keeps one row per key.
    _check(
        "SELECT DISTINCT ON (k) k, id FROM t QUALIFY row_number() OVER (PARTITION BY name ORDER BY id) = 1 ORDER BY k, id",
        "Sort(keys=[k ASC, id ASC])\n"
        "  Project(exprs=[ColRef(k), ColRef(id)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[k], order=[k ASC, id ASC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(k), ColRef(id)])\n"
        "          Filter(predicate=BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))))\n"
        "            PartitionBy(partition=[name], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "              " + _SCAN
    )


def test_distinct_on_star() raises:
    _check(
        "SELECT DISTINCT ON (k) * FROM t ORDER BY k, id",
        "Sort(keys=[k ASC, id ASC])\n"
        "  Project(exprs=[ColRef(id), ColRef(name), ColRef(o), ColRef(k)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[k], order=[k ASC, id ASC], funcs=[" + _RN + "])\n"
        "        " + _SCAN
    )


# --- 3. DISTINCT ON refusals -------------------------------------------------


def test_distinct_on_refusals() raises:
    _check(
        "SELECT DISTINCT ON (o + 1) id FROM t ORDER BY id",
        "ERR: SQL not supported: the DISTINCT ON key `(o + 1)` is neither a"
        " SELECT item, an ORDER BY key nor an input column this SELECT can"
        " carry. Select it or ORDER BY it."
    )
    _check(
        "SELECT DISTINCT ON (3) id, name FROM t ORDER BY id",
        "ERR: SQL bind error: ORDER term out of range - should be between 1 and 2"
    )
    _check(
        "SELECT DISTINCT ON (99999999999999999999) id FROM t ORDER BY id",
        "ERR: SQL bind error: the DISTINCT ON ordinal 99999999999999999999 is"
        " out of range for BIGINT"
    )
    _check(
        "SELECT DISTINCT ON (a) id AS a, o AS a FROM t ORDER BY a",
        "ERR: SQL not supported: SELECT DISTINCT ON over two items both named"
        " `a`. The rows are partitioned and kept by column NAME, so the second"
        " would be answered with the first's values. Give the two items"
        " distinct aliases."
    )


def test_distinct_on_key_the_window_path_cannot_carry_is_refused() raises:
    _check(
        "SELECT DISTINCT ON (k) id, row_number() OVER (ORDER BY id) AS rn FROM t ORDER BY id",
        "ERR: SQL not supported: the DISTINCT ON key `k` is neither a SELECT"
        " item, an ORDER BY key nor an input column this SELECT can carry."
        " Select it or ORDER BY it."
    )


def test_distinct_on_over_group_by_keeps_one_group_per_key() raises:
    _check(
        "SELECT DISTINCT ON (k) k, count(*) AS c FROM t GROUP BY k, o ORDER BY k, c DESC",
        "Sort(keys=[k ASC, c DESC])\n"
        "  Project(exprs=[ColRef(k), ColRef(c)])\n"
        "    " + _KEEP1
        + "      PartitionBy(partition=[k], order=[k ASC, c DESC], funcs=[" + _RN + "])\n"
        "        Project(exprs=[ColRef(k), ColRef(c)])\n"
        "          Aggregate(group_by=[ColRef(k), ColRef(o)], aggs=[COUNT(*).alias(\"c\")])\n"
        "            " + _SCAN
    )


# --- 4. QUALIFY --------------------------------------------------------------


def test_qualify_inline_window_is_a_hidden_column() raises:
    _check(
        "SELECT id, name FROM t QUALIFY row_number() OVER (PARTITION BY name ORDER BY id) = 1",
        "Project(exprs=[ColRef(id), ColRef(name)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))))\n"
        "    PartitionBy(partition=[name], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "      " + _SCAN
    )


def test_qualify_on_the_alias_of_a_window() raises:
    _check(
        "SELECT id, row_number() OVER (PARTITION BY name ORDER BY id) AS rn FROM t QUALIFY rn = 1",
        "Project(exprs=[ColRef(id), ColRef(rn)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(rn), Literal(ScalarValue(int64, 1))))\n"
        "    PartitionBy(partition=[name], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "      " + _SCAN
    )


def test_qualify_names_aliases_columns_and_unselected_columns() raises:
    # A non-window item's alias is its expression; `k` is not selected.
    _check(
        "SELECT id, o * 10 AS x, rank() OVER (ORDER BY id) AS r FROM t QUALIFY x > 20 AND k IS NOT NULL",
        "Project(exprs=[ColRef(id), Alias(BinaryOp(MUL, ColRef(o), Literal(ScalarValue(int64, 10))), \"x\"), ColRef(r)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, BinaryOp(MUL, ColRef(o), Literal(ScalarValue(int64, 10))), Literal(ScalarValue(int64, 20))), UnaryOp(IS_NOT_NULL, ColRef(k))))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS r])\n"
        "      " + _SCAN
    )
    # An input column beats a window alias of its name (DuckDB filters on
    # the input `o`).
    _check(
        "SELECT id, row_number() OVER (ORDER BY id) AS o FROM t QUALIFY o = 1",
        "Project(exprs=[ColRef(id), Alias(ColRef(_w_shadow_1_o), \"o\")])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(o), Literal(ScalarValue(int64, 1))))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS _w_shadow_1_o])\n"
        "      " + _SCAN
    )
    # Two inline windows inside a CASE and a call, numbered in order met.
    _check(
        "SELECT id FROM t QUALIFY CASE WHEN rank() OVER (ORDER BY o) = 1 THEN TRUE ELSE abs(lag(id) OVER (ORDER BY id)) > 2 END",
        "Project(exprs=[ColRef(id)])\n"
        "  Filter(predicate=When(WHEN BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(bool, true)), ELSE BinaryOp(GT, UnaryOp(ABS, ColRef(__qualify_w1)), Literal(ScalarValue(int64, 2)))))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[LAG(id, offset=1, frame=RANGE[0:0..2:0]) AS __qualify_w1])\n"
        "      PartitionBy(partition=[], order=[o ASC], funcs=[RANK(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "        " + _SCAN
    )


def test_qualify_sits_under_distinct_order_by_and_limit() raises:
    _check(
        "SELECT DISTINCT name FROM t QUALIFY row_number() OVER (PARTITION BY name ORDER BY id) <= 2 ORDER BY name LIMIT 2",
        "Limit(n=2)\n"
        "  Sort(keys=[name ASC])\n"
        "    Distinct(all)\n"
        "      Project(exprs=[ColRef(name)])\n"
        "        Filter(predicate=BinaryOp(LE, ColRef(__qualify_w0), Literal(ScalarValue(int64, 2))))\n"
        "          PartitionBy(partition=[name], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "            " + _SCAN
    )


def test_qualify_finds_windows_in_every_kind_of_operand() raises:
    # Under IS NOT NULL (a unary node), and only in a CASE's ELSE.
    _check(
        "SELECT id FROM t QUALIFY lag(id) OVER (ORDER BY id) IS NOT NULL",
        "Project(exprs=[ColRef(id)])\n"
        "  Filter(predicate=UnaryOp(IS_NOT_NULL, ColRef(__qualify_w0)))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[LAG(id, offset=1, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "      " + _SCAN
    )
    _check(
        "SELECT id FROM t QUALIFY abs(id) > 0 AND CASE WHEN id > 1 THEN TRUE ELSE row_number() OVER (ORDER BY id) = 1 END",
        "Project(exprs=[ColRef(id)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, UnaryOp(ABS, ColRef(id)), Literal(ScalarValue(int64, 0))), When(WHEN BinaryOp(GT, ColRef(id), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(bool, true)), ELSE BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))))))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "      " + _SCAN
    )


def test_qualify_alias_lookup_skips_stars_and_unaliased_items() raises:
    _check(
        "SELECT *, name, id * 2 AS dbl, row_number() OVER (ORDER BY id) AS rn FROM t QUALIFY dbl > 2 AND rn = 1",
        "Project(exprs=[ColRef(id), ColRef(name), ColRef(o), ColRef(k), ColRef(name), Alias(BinaryOp(MUL, ColRef(id), Literal(ScalarValue(int64, 2))), \"dbl\"), ColRef(rn)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(GT, BinaryOp(MUL, ColRef(id), Literal(ScalarValue(int64, 2))), Literal(ScalarValue(int64, 2))), BinaryOp(EQ, ColRef(rn), Literal(ScalarValue(int64, 1)))))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "      " + _SCAN
    )
    # An alias matches in any case, as DuckDB's names do; a qualified name
    # is always the input column.
    _check(
        "SELECT id * 2 AS dbl, row_number() OVER (ORDER BY id) AS rn FROM t QUALIFY DBL > 2 AND t.id > 0 AND RN = 1",
        "Project(exprs=[Alias(BinaryOp(MUL, ColRef(id), Literal(ScalarValue(int64, 2))), \"dbl\"), ColRef(rn)])\n"
        "  Filter(predicate=BinaryOp(AND, BinaryOp(AND, BinaryOp(GT, BinaryOp(MUL, ColRef(id), Literal(ScalarValue(int64, 2))), Literal(ScalarValue(int64, 2))), BinaryOp(GT, ColRef(id), Literal(ScalarValue(int64, 0)))), BinaryOp(EQ, ColRef(rn), Literal(ScalarValue(int64, 1)))))\n"
        "    PartitionBy(partition=[], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "      " + _SCAN
    )
    # A window inside a CASE with no ELSE is rewritten, and the CASE then
    # meets the binder's own CASE rule.
    var no_else = _got(
        "SELECT id FROM t QUALIFY CASE WHEN rank() OVER (ORDER BY id) = 1 THEN TRUE END"
    )
    assert_true("ERR: SQL not supported: a CASE with no ELSE" in no_else, no_else)
    # A name that is neither an input column nor an alias.
    _check(
        "SELECT id, row_number() OVER (ORDER BY id) AS rn FROM t QUALIFY zz = 1",
        "ERR: SQL bind error: unknown column 'zz'"
    )


# --- 5. QUALIFY with no window ----------------------------------------------


def test_qualify_without_a_window_is_duckdbs_binder_error() raises:
    var want = String(
        "ERR: SQL bind error: at least one window function must appear in the"
        " SELECT column or QUALIFY clause"
    )
    _check("SELECT id FROM t QUALIFY id = 1", want)
    _check("SELECT * FROM t QUALIFY 1 = 1", want)
    # A CASE with no ELSE is searched too.
    _check("SELECT id FROM t QUALIFY CASE WHEN id > 1 THEN TRUE END", want)
    # Every kind of operand is searched for a window, and none holds one.
    _check(
        "SELECT id FROM t QUALIFY CASE WHEN id > 1 THEN abs(id) > 0 ELSE id IS NULL END",
        want,
    )
    _check("SELECT k, count(*) AS c FROM t GROUP BY k QUALIFY c > 1", want)
    _check(
        "SELECT k, count(*) AS c FROM t GROUP BY k QUALIFY row_number() OVER (ORDER BY k) = 1",
        "ERR: SQL not supported: a window function combined with GROUP BY /"
        " aggregation in the same SELECT"
    )


# --- 6. SELECT * beside a window ---------------------------------------------


def test_star_beside_a_window_over_a_join() raises:
    # The star projects the join's engine names (u's `id` and `k` renamed);
    # the result rename at the root restores the names DuckDB shows.
    var got = _got("SELECT *, row_number() OVER (ORDER BY o) AS rn FROM t, u")
    assert_true(
        "Project(exprs=[ColRef(id), ColRef(name), ColRef(o), ColRef(k), ColRef(id_right), ColRef(k_right), ColRef(rn)])" in got,
        got,
    )


def test_star_beside_a_window_projects_every_input_column() raises:
    _check(
        "SELECT *, row_number() OVER (ORDER BY id) AS rn FROM t",
        "Project(exprs=[ColRef(id), ColRef(name), ColRef(o), ColRef(k), ColRef(rn)])\n"
        "  PartitionBy(partition=[], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS rn])\n"
        "    " + _SCAN
    )
    _check(
        "SELECT * FROM t QUALIFY row_number() OVER (PARTITION BY k ORDER BY id) = 1",
        "Project(exprs=[ColRef(id), ColRef(name), ColRef(o), ColRef(k)])\n"
        "  Filter(predicate=BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))))\n"
        "    PartitionBy(partition=[k], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "      " + _SCAN
    )


# --- 7. subquery bodies ------------------------------------------------------


def test_subquery_bodies() raises:
    _check(
        "SELECT id FROM t WHERE EXISTS (SELECT DISTINCT ON (k) k FROM u WHERE u.id = t.id)",
        "ERR: SQL not supported: DISTINCT ON / QUALIFY inside an EXISTS subquery"
    )
    _check(
        "SELECT id FROM t WHERE NOT EXISTS (SELECT k FROM u WHERE u.id = t.id QUALIFY row_number() OVER (ORDER BY k) = 1)",
        "ERR: SQL not supported: DISTINCT ON / QUALIFY inside an EXISTS subquery"
    )
    _check(
        "SELECT id, (SELECT DISTINCT ON (u.k) u.k FROM u WHERE u.id = t.id) AS m FROM t",
        "ERR: SQL not supported: a correlated scalar subquery with DISTINCT ON"
        " or QUALIFY in its body"
    )
    _check(
        "SELECT id, (SELECT max(u.k) FROM u WHERE u.id = t.id QUALIFY row_number() OVER (ORDER BY id) = 1) AS m FROM t",
        "ERR: SQL not supported: a correlated scalar subquery with DISTINCT ON"
        " or QUALIFY in its body"
    )
    _check(
        "SELECT d.id FROM (SELECT id FROM t QUALIFY row_number() OVER (PARTITION BY k ORDER BY id) = 1) AS d",
        "Project(exprs=[ColRef(id)])\n"
        "  Project(exprs=[ColRef(id)])\n"
        "    Filter(predicate=BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))))\n"
        "      PartitionBy(partition=[k], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])\n"
        "        " + _SCAN
    )


def test_distinct_on_and_qualify_in_an_in_body_bind() raises:
    # The body is bound whole, so its plan keeps the row-number partition and
    # its filter.
    var keep = String(
        "PartitionBy(partition=[k], order=[], funcs=[ROW_NUMBER(, offset=0,"
        " frame=ROWS[0:0..4:0]) AS __distinct_on_rn])"
    )
    var got = _got("SELECT id FROM t WHERE k IN (SELECT DISTINCT ON (k) k FROM u)")
    assert_true(keep in got, got)
    assert_true(String(_KEEP1).rstrip("\n") in got, got)
    got = _got(
        "SELECT id FROM t WHERE k IN (SELECT k FROM u QUALIFY row_number() OVER (PARTITION BY k ORDER BY id) = 1)"
    )
    assert_true(
        "Filter(predicate=BinaryOp(EQ, ColRef(__qualify_w0), Literal(ScalarValue(int64, 1))))" in got,
        got,
    )
    assert_true(
        "PartitionBy(partition=[k], order=[id ASC], funcs=[ROW_NUMBER(, offset=0, frame=RANGE[0:0..2:0]) AS __qualify_w0])" in got,
        got,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
