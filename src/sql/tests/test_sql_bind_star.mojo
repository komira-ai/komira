# =============================================================================
# A star's EXCLUDE list and a table-qualified star (sql_parse_star,
# sql_parser, sql_bind_scope `_star_out_names`, sql_bind_aggregate, sql_binder)
# =============================================================================
#
# Each check parses one statement, or binds it against parquet tables
# registered with a given schema (no file is opened), and compares what it
# gives with an exact expected value: the parsed star item's fields, the
# refusal's whole message, or the bound plan's text. Most bound checks hold a
# star to the plan of the same query with the columns it keeps written out by
# name, which is what DuckDB answers for it; the values themselves are held
# to the pinned DuckDB in sdk_exec's test_run_sql_star_exclude.
#
#   test_a_star_carries_its_exclude_list_and_qualifier
#       `* EXCLUDE (a, b)`, `* EXCLUDE a` and `q.* EXCLUDE (...)` give the
#       star item the names (lower-folded) and the qualifier; a bare `*`
#       is the plain star.
#   test_a_malformed_exclude_list_is_a_syntax_error
#       an empty list, a trailing comma, a missing `)`, a repeated name (also
#       in another case) and `q.` with no column are syntax errors.
#   test_a_qualified_exclude_name_and_the_other_star_modifiers_are_refused
#       `EXCLUDE (c.k)`, `* REPLACE (...)` and `* RENAME (...)` (also after
#       an EXCLUDE list, and after `t.*`) are refused by name; `replace` not followed by a list,
#       or another word followed by one, is left to the rest of the grammar.
#   test_exclude_binds_as_the_kept_columns_named
#       over one table (one name, several, any case, no parentheses), under
#       DISTINCT and LIMIT, with an ORDER BY of a column it drops (carried
#       to the sort and pruned) and of an ordinal, in a derived table; over
#       a join, a name drops the column from both sides, over a USING join
#       the one coalesced key, and over a SEMI join a left column.
#   test_a_qualified_star_binds_as_its_relations_columns_named
#       `t.*` and `u.*` over a join (the right one's `k_right` named `k` in
#       the result), with an EXCLUDE list, the left relation of a USING join,
#       a derived table's alias.
#   test_a_star_that_cannot_expand_is_refused
#       a name the star does not expand to (over the scope and over one
#       relation), a list naming every column, a qualifier no relation
#       answers to, one two relations answer to, the right relation of a
#       USING or NATURAL join, the right relation of a SEMI join (which
#       contributes no column), a star under GROUP BY or beside a window, a
#       star beside another item and a star with no FROM.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from plan_ir.logical_plan import LogicalPlan

from sql.sql_ast import SqlStatement
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement
from sql.sql_catalog import SqlCatalog
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


def _catalog() -> SqlCatalog:
    """t(k, b, v) and u(k, w): parquet tables with given schemas."""
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field("k", ArrowType.INT64, False))
    t.add_field(Field("b", ArrowType.STRING, True))
    t.add_field(Field("v", ArrowType.INT64, True))
    cat.add_parquet("t", "t.parquet", t.build())
    var u = SchemaBuilder()
    u.add_field(Field("k", ArrowType.INT64, False))
    u.add_field(Field("w", ArrowType.STRING, True))
    cat.add_parquet("u", "u.parquet", u.build())
    return cat^


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _got(sql: String) raises -> String:
    """The bound plan's text, or `ERR: ` and the parser's or binder's
    message."""
    try:
        var cat = _catalog()
        var bound = bind_statement(_parse(sql), cat, NoParquetFooters())
        var plan: LogicalPlan = bound.take_plan()
        return String(plan)
    except e:
        return String("ERR: ") + String(e)


def _same(star: String, named: String) raises:
    """`star` binds to the plan `named` binds to, and that is a plan."""
    var want = _got(named)
    assert_false(want.startswith("ERR: "), named + " -> " + want)
    assert_equal(_got(star), want, star)


def _refused(sql: String, message: String) raises:
    assert_equal(_got(sql), "ERR: " + message, sql)


def _excluded(sql: String) raises -> String:
    """The first SELECT item's qualifier and EXCLUDE names, as
    `q|a,b`, and `plain` for a plain star."""
    var st = _parse(sql)
    ref it = st.query.select_items[0]
    assert_true(it.is_star, sql)
    if it.is_plain_star():
        return String("plain")
    var s = it.star_qualifier + "|"
    for i in range(len(it.star_exclude)):
        if i > 0:
            s += ","
        s += it.star_exclude[i]
    return s^


def test_a_star_carries_its_exclude_list_and_qualifier() raises:
    assert_equal(_excluded("SELECT * FROM t"), "plain")
    assert_equal(_excluded("SELECT * EXCLUDE (b) FROM t"), "|b")
    assert_equal(_excluded("SELECT * EXCLUDE (B, v) FROM t"), "|b,v")
    assert_equal(_excluded("SELECT * EXCLUDE b FROM t"), "|b")
    assert_equal(_excluded("SELECT o.* FROM t AS o"), "o|")
    assert_equal(_excluded("SELECT O.* EXCLUDE (b) FROM t AS o"), "o|b")
    assert_false(_parse("SELECT k").query.select_items[0].is_star)
    assert_false(_parse("SELECT t.k FROM t").query.select_items[0].is_star)


def test_a_malformed_exclude_list_is_a_syntax_error() raises:
    _refused(
        "SELECT * EXCLUDE () FROM t",
        "SQL syntax error: expected a column name in EXCLUDE",
    )
    _refused(
        "SELECT * EXCLUDE (b,) FROM t",
        "SQL syntax error: expected a column name in EXCLUDE",
    )
    _refused(
        "SELECT * EXCLUDE 1 FROM t",
        "SQL syntax error: expected a column name in EXCLUDE",
    )
    _refused(
        "SELECT * EXCLUDE (b v) FROM t",
        "SQL syntax error: expected ')' to close EXCLUDE (...)",
    )
    _refused(
        "SELECT * EXCLUDE (b, v, b) FROM t",
        "SQL syntax error: duplicate entry \"b\" in EXCLUDE list",
    )
    _refused(
        "SELECT * EXCLUDE (b, B) FROM t",
        "SQL syntax error: duplicate entry \"b\" in EXCLUDE list",
    )
    _refused(
        "SELECT * EXCLUDE (t.) FROM t",
        "SQL syntax error: expected a column name after '.' in EXCLUDE",
    )


def test_a_qualified_exclude_name_and_the_other_star_modifiers_are_refused() raises:
    _refused(
        "SELECT * EXCLUDE (u.k) FROM t JOIN u ON t.k = u.k",
        "SQL not supported: a qualified name in EXCLUDE (`u.k`). Name the"
        " column alone, `EXCLUDE (k)`, which drops every column of that name"
        " the star expands to, or name the relation's star, `u.* EXCLUDE (k)`.",
    )
    var replace = String(
        "SQL not supported: SELECT * REPLACE (...). Select the columns by name"
        " and write the replacing expression in place of its column"
        " (`SELECT a, b + 1 AS b FROM t`)."
    )
    _refused("SELECT * REPLACE (v + 1 AS v) FROM t", replace)
    _refused("SELECT * EXCLUDE (b) REPLACE (v + 1 AS v) FROM t", replace)
    _refused("SELECT t.* REPLACE (v + 1 AS v) FROM t", replace)
    _refused(
        "SELECT t.* EXCLUDE (b) RENAME (v AS w) FROM t",
        "SQL not supported: SELECT * RENAME (...). Select the columns by name"
        " and rename with AS (`SELECT a, b AS c FROM t`).",
    )
    _refused(
        "SELECT * RENAME (v AS w) FROM t",
        "SQL not supported: SELECT * RENAME (...). Select the columns by name"
        " and rename with AS (`SELECT a, b AS c FROM t`).",
    )
    # Neither word before a list is left to the rest of the grammar.
    _refused(
        "SELECT * replace FROM t",
        "SQL syntax error: expected keyword 'from'",
    )
    _refused(
        "SELECT * other (v) FROM t",
        "SQL syntax error: expected keyword 'from'",
    )


def test_exclude_binds_as_the_kept_columns_named() raises:
    _same("SELECT * EXCLUDE (b) FROM t", "SELECT k, v FROM t")
    _same("SELECT * EXCLUDE b FROM t", "SELECT k, v FROM t")
    _same("SELECT * EXCLUDE (B) FROM t", "SELECT k, v FROM t")
    _same("SELECT * EXCLUDE (k, v) FROM t", "SELECT b FROM t")
    _same("SELECT DISTINCT * EXCLUDE (b) FROM t", "SELECT DISTINCT k, v FROM t")
    _same("SELECT * EXCLUDE (b) FROM t LIMIT 2", "SELECT k, v FROM t LIMIT 2")
    _same(
        "SELECT * EXCLUDE (b) FROM t ORDER BY b DESC",
        "SELECT k, v FROM t ORDER BY b DESC",
    )
    _same(
        "SELECT * EXCLUDE (k) FROM t ORDER BY 2 LIMIT 1 OFFSET 1",
        "SELECT b, v FROM t ORDER BY 2 LIMIT 1 OFFSET 1",
    )
    _same(
        "SELECT * FROM (SELECT * EXCLUDE (b) FROM t) AS d",
        "SELECT * FROM (SELECT k, v FROM t) AS d",
    )
    _same(
        "SELECT * EXCLUDE (k) FROM t JOIN u ON t.k = u.k",
        "SELECT b, v, w FROM t JOIN u ON t.k = u.k",
    )
    _same(
        "SELECT * EXCLUDE (k) FROM t JOIN u USING (k)",
        "SELECT b, v, w FROM t JOIN u USING (k)",
    )
    _same(
        "SELECT * EXCLUDE (b) FROM t SEMI JOIN u ON t.k = u.k",
        "SELECT k, v FROM t SEMI JOIN u ON t.k = u.k",
    )
    _same(
        "SELECT * EXCLUDE (w) FROM t JOIN u ON t.k = u.k",
        "SELECT t.k, b, v, u.k FROM t JOIN u ON t.k = u.k",
    )


def test_a_qualified_star_binds_as_its_relations_columns_named() raises:
    _same("SELECT t.* FROM t", "SELECT k, b, v FROM t")
    _same(
        "SELECT t.* FROM t JOIN u ON t.k = u.k",
        "SELECT t.k, t.b, t.v FROM t JOIN u ON t.k = u.k",
    )
    _same(
        "SELECT u.* FROM t JOIN u ON t.k = u.k",
        "SELECT u.k, u.w FROM t JOIN u ON t.k = u.k",
    )
    _same(
        "SELECT t.* EXCLUDE (b) FROM t JOIN u ON t.k = u.k",
        "SELECT t.k, t.v FROM t JOIN u ON t.k = u.k",
    )
    _same(
        "SELECT u.* EXCLUDE (W) FROM t JOIN u ON t.k = u.k ORDER BY v",
        "SELECT u.k FROM t JOIN u ON t.k = u.k ORDER BY v",
    )
    _same(
        "SELECT t.* FROM t JOIN u USING (k)",
        "SELECT t.k, t.b, t.v FROM t JOIN u USING (k)",
    )
    _same(
        "SELECT d.* EXCLUDE (v) FROM (SELECT k, v FROM t) AS d",
        "SELECT d.k FROM (SELECT k, v FROM t) AS d",
    )


def test_a_star_that_cannot_expand_is_refused() raises:
    _refused(
        "SELECT * EXCLUDE (b, zz) FROM t",
        "SQL bind error: column \"zz\" in EXCLUDE list not found in FROM clause",
    )
    _refused(
        "SELECT u.* EXCLUDE (b) FROM t JOIN u ON t.k = u.k",
        "SQL bind error: column \"b\" in EXCLUDE list not found in `u`",
    )
    _refused(
        "SELECT * EXCLUDE (k, b, v) FROM t",
        "SQL bind error: SELECT list is empty after resolving * expressions"
        " (the EXCLUDE list names every column the star expands to)",
    )
    _refused(
        "SELECT t.* EXCLUDE (k, w) FROM u AS t",
        "SQL bind error: SELECT list is empty after resolving * expressions"
        " (the EXCLUDE list names every column the star expands to)",
    )
    _refused(
        "SELECT x.* FROM t",
        "SQL bind error: referenced table `x` not found (in `x.*`)",
    )
    _refused(
        "SELECT t.* FROM t AS x",
        "SQL bind error: referenced table `t` not found (in `t.*`)",
    )
    _refused(
        "SELECT z.* FROM t AS z, u AS z",
        "SQL bind error: ambiguous reference to table `z` in `z.*`: more than"
        " one relation answers to `z`. Give one of them a distinct alias"
        " (`AS my_alias`).",
    )
    _refused(
        "SELECT u.* FROM t JOIN u USING (k)",
        "SQL not supported: `u.*` over a relation joined by NATURAL or USING."
        " Its key `k` is coalesced with the left's, and DuckDB answers the"
        " relation's own key there. Select its columns by name.",
    )
    _refused(
        "SELECT u.* FROM t NATURAL JOIN u",
        "SQL not supported: `u.*` over a relation joined by NATURAL or USING."
        " Its key `k` is coalesced with the left's, and DuckDB answers the"
        " relation's own key there. Select its columns by name.",
    )
    _refused(
        "SELECT u.* FROM t SEMI JOIN u ON t.k = u.k",
        "SQL bind error: referenced table `u` not found (in `u.*`)",
    )
    _refused(
        "SELECT * EXCLUDE (b) FROM t GROUP BY k",
        "SQL not supported: SELECT * with aggregation",
    )
    _refused(
        "SELECT t.* FROM t GROUP BY k",
        "SQL not supported: SELECT * with aggregation",
    )
    _refused(
        "SELECT t.* EXCLUDE (b), rank() OVER (ORDER BY k) FROM t",
        "SQL not supported: SELECT * alongside a window function",
    )
    _refused(
        "SELECT * EXCLUDE (b), k FROM t",
        "SQL not supported: '*' mixed with other SELECT items",
    )
    _refused(
        "SELECT k, t.* FROM t",
        "SQL not supported: '*' mixed with other SELECT items",
    )
    _refused(
        "SELECT * EXCLUDE (a)",
        "SQL bind error: * expression without FROM clause (a FROM-less SELECT"
        " has no columns to expand)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
