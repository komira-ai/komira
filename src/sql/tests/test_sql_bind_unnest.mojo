# =============================================================================
# The SQL binder's `unnest(list)` SELECT item (sql_bind_unnest)
# =============================================================================
#
# Every query binds through `bind_statement` against a catalog of one parquet
# table `t(id INT64, tags LIST<STRING>, nums LIST<INT64>, s STRING)` (no file
# is opened). What each test proves:
#   test_unnest_of_a_column_binds_project_unnest_project
#       `SELECT id, unnest(tags) FROM t` binds as the list projected into
#       `__unnest` beside every input column, an Unnest of it that drops empty
#       and NULL lists (keep_empty=false), and a Project naming the item
#       `unnest(tags)` as DuckDB does.
#   test_an_alias_names_the_unnested_column
#       `unnest(nums) AS n` is named `n`, and its element type is the list's
#       (INT64); the string column's element type is STRING.
#   test_unnest_of_an_expression_binds_the_expression_below
#       `unnest(string_split(s, ','))`: the split is computed below the Unnest.
#   test_where_and_order_by_bind_around_the_unnest
#       WHERE filters the input below the unnest; ORDER BY an alias, a selected
#       column and an ordinal sort the output above it; an ORDER BY column the
#       items do not produce is carried to the sort and pruned above it.
#   test_unnest_in_an_expression_or_outside_the_select_list_is_refused
#       `unnest(tags) || 'x'` and `WHERE unnest(tags) = 'a'` are refused with
#       the not-a-SELECT-item sentence.
#   test_the_refused_shapes_name_their_reason
#       two unnest items; unnest beside an aggregate, GROUP BY and a window;
#       `*` beside unnest; an ORDER BY expression no item produces; zero and
#       two arguments; a non-list argument; an input with a column named
#       `__unnest`: each refused with its exact sentence.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder

from sql.sql_token import tokenize
from sql.sql_parser import parse_sql
from sql.sql_catalog import SqlCatalog
from sql.sql_bind_parquet import NoParquetFooters
from sql.sql_binder import bind_statement


def _catalog() -> SqlCatalog:
    var cat = SqlCatalog()
    var t = SchemaBuilder()
    t.add_field(Field(String("id"), ArrowType.INT64, False))
    t.add_field(Field.list_of_string(String("tags"), True))
    t.add_field(Field.list_of(String("nums"), ArrowType.INT64, True))
    t.add_field(Field(String("s"), ArrowType.STRING, True))
    cat.add_parquet(String("t"), String("t.parquet"), t.build())
    var u = SchemaBuilder()
    u.add_field(Field(String("__unnest"), ArrowType.INT64, True))
    u.add_field(Field.list_of_string(String("tags"), True))
    cat.add_parquet(String("u"), String("u.parquet"), u.build())
    return cat^


def _plan(sql: String) raises -> String:
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    return String(plan)


def _schema_text(sql: String) raises -> String:
    """`name:arrow type id` of each output column, comma separated."""
    var cat = _catalog()
    var bound = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    var plan = bound.take_plan()
    var out = String("")
    for c in range(plan.output_schema.num_columns()):
        if c > 0:
            out += ","
        out += String(plan.output_schema.field_name(c)) + ":" + String(
            Int(plan.output_schema.field_arrow_type(c).type_id)
        )
    return out^


def _err(sql: String) raises -> String:
    var cat = _catalog()
    try:
        _ = bind_statement(parse_sql(tokenize(sql)), cat, NoParquetFooters())
    except e:
        return String(e)
    raise Error("bound, expected a refusal: " + sql)


comptime _SCAN = "Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)\n"
comptime _BELOW = (
    "Project(exprs=[ColRef(id), ColRef(tags), ColRef(nums), ColRef(s),"
)


def test_unnest_of_a_column_binds_project_unnest_project() raises:
    assert_equal(
        _plan("SELECT id, unnest(tags) FROM t"),
        String("Project(exprs=[ColRef(id), Alias(ColRef(__unnest), \"unnest(tags)\")])\n")
        + "  Unnest(column=__unnest, keep_empty=false)\n"
        + "    " + _BELOW + " Alias(ColRef(tags), \"__unnest\")])\n"
        + "      " + _SCAN,
    )


def test_an_alias_names_the_unnested_column() raises:
    var int64 = String(Int(ArrowType.INT64.type_id))
    var string = String(Int(ArrowType.STRING.type_id))
    assert_equal(
        _schema_text("SELECT id, unnest(nums) AS n FROM t"),
        "id:" + int64 + ",n:" + int64,
    )
    assert_equal(
        _schema_text("SELECT unnest(tags) AS tag, s FROM t"),
        "tag:" + string + ",s:" + string,
    )


def test_unnest_of_an_expression_binds_the_expression_below() raises:
    var got = _plan("SELECT id, unnest(string_split(s, ',')) AS part FROM t")
    var lines = got.split("\n")
    assert_equal(
        String(lines[0]),
        "Project(exprs=[ColRef(id), Alias(ColRef(__unnest), \"part\")])",
    )
    assert_equal(String(lines[1]), "  Unnest(column=__unnest, keep_empty=false)")
    assert_equal(String(lines[3]) + "\n", "      " + _SCAN)
    var below = String(lines[2])
    assert_true(below.startswith("    " + _BELOW), below)
    assert_true(below.endswith(", \"__unnest\")])"), below)
    assert_equal(
        _schema_text("SELECT id, unnest(string_split(s, ',')) AS part FROM t"),
        "id:" + String(Int(ArrowType.INT64.type_id))
        + ",part:" + String(Int(ArrowType.STRING.type_id)),
    )


def test_where_and_order_by_bind_around_the_unnest() raises:
    var got = _plan(
        "SELECT id, unnest(tags) AS tag FROM t WHERE id > 1 ORDER BY id, tag"
    )
    var lines = got.split("\n")
    assert_true(String(lines[0]).startswith("Sort("), got)
    assert_equal(
        String(lines[1]),
        "  Project(exprs=[ColRef(id), Alias(ColRef(__unnest), \"tag\")])",
        got,
    )
    assert_equal(String(lines[2]), "    Unnest(column=__unnest, keep_empty=false)")
    assert_true(String(lines[4]).startswith("      Filter("), got)
    # A column the items do not produce is carried to the sort and pruned.
    assert_equal(
        _schema_text("SELECT unnest(tags) AS tag FROM t ORDER BY id, tag"),
        "tag:" + String(Int(ArrowType.STRING.type_id)),
    )
    var carried = _plan("SELECT unnest(tags) AS tag FROM t ORDER BY id, tag")
    assert_true(
        "Alias(ColRef(__unnest), \"tag\"), ColRef(id)])" in carried, carried
    )
    var by_ordinal = _plan("SELECT id, unnest(tags) AS tag FROM t ORDER BY 2 DESC, 1")
    assert_true(by_ordinal.startswith("Sort("), by_ordinal)


comptime _NOT_AN_ITEM = (
    "SQL not supported: unnest(...) is served only as a whole SELECT item"
    " (`SELECT unnest(list) [AS name] FROM ...`); it cannot be nested in an"
    " expression or used outside the SELECT list"
)


def test_unnest_in_an_expression_or_outside_the_select_list_is_refused() raises:
    assert_equal(_err("SELECT id, unnest(tags) || 'x' FROM t"), _NOT_AN_ITEM)
    assert_equal(_err("SELECT id FROM t WHERE unnest(tags) = 'a'"), _NOT_AN_ITEM)


def test_the_refused_shapes_name_their_reason() raises:
    assert_equal(
        _err("SELECT unnest(tags), unnest(nums) FROM t"),
        "SQL not supported: two unnest(...) items in one SELECT (DuckDB pairs"
        " their elements row by row); unnest one list per SELECT",
    )
    var beside = String(
        "SQL not supported: unnest(...) beside an aggregate, GROUP BY or a"
        " window function in the same SELECT; unnest in a subquery and"
        " aggregate over it"
    )
    assert_equal(_err("SELECT count(*), unnest(tags) FROM t"), beside)
    assert_equal(_err("SELECT id, unnest(tags) FROM t GROUP BY id"), beside)
    assert_equal(
        _err("SELECT row_number() OVER (ORDER BY id) AS r, unnest(tags) FROM t"),
        beside,
    )
    assert_equal(
        _err("SELECT *, unnest(tags) FROM t"),
        "SQL not supported: SELECT * beside unnest(...); name the columns to keep",
    )
    assert_equal(
        _err("SELECT id, unnest(tags) FROM t ORDER BY id + 1"),
        "SQL not supported: ORDER BY an expression that no SELECT item"
        " produces, beside unnest(...); select the expression and order by"
        " its alias or position, or order by a selected column",
    )
    assert_equal(
        _err("SELECT unnest() FROM t"),
        "SQL bind error: unnest takes one argument, a list; `unnest()` has 0",
    )
    assert_equal(
        _err("SELECT unnest(tags, nums) FROM t"),
        "SQL bind error: unnest takes one argument, a list; `unnest(tags,"
        " nums)` has 2",
    )
    assert_equal(
        _err("SELECT unnest(id) FROM t"),
        "SQL bind error: unnest(...) takes a list, and the argument of"
        " `unnest(id)` is " + String(ArrowType.INT64),
    )
    assert_equal(
        _err("SELECT unnest(tags) FROM u"),
        "SQL not supported: unnest(...) over an input that has a column named"
        " `__unnest`, the name it binds its list to; rename that column",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
