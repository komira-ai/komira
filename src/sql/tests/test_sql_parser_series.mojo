# =============================================================================
# sql_parser: `generate_series(...)` / `range(...)` as a table function in FROM
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   1. Both names parse in FROM with one, two and three arguments, into a
#      `FromRelation` whose `series` carries the function name and each
#      argument's kind and value, in order. (catches: an argument dropped or
#      reordered; the call read as a table named `range`)
#   2. Every literal argument shape is read into its own kind: a negative
#      integer, NULL, a DATE, a TIMESTAMP, a TIMESTAMPTZ, an INTERVAL with its
#      count and unit (HOUR included), a string and a decimal. (catches: a
#      negative literal read as an expression; TIMESTAMPTZ read as TIMESTAMP)
#   3. A column reference and any other expression are recorded by kind so the
#      binder can refuse them: `t.x`, `x`, `1 + 2`, a cast, an integer past
#      BIGINT. (catches: a column argument read as a literal)
#   4. The relation answers to the alias when there is one (`AS t`, `t`) and to
#      the function name when there is none; its name cannot be a catalog
#      table's. (catches: an unaliased call that nothing can qualify)
#   5. An alias is followed by an optional column-name list: one name, several
#      names; none after a missing alias. (catches: the list dropped, or read
#      as the start of another relation)
#   6. The call sits among other relations: after a comma, before a join, with
#      a WHERE after it. (catches: the alias parser swallowing a clause word)
#   7. An empty argument list parses (the binder refuses its arity); a broken
#      list or column list is a syntax error; the words `range` and
#      `generate_series` stay a table name or a column without a `(`.
#      (catches: `FROM range` no longer naming a table)

from std.testing import TestSuite, assert_equal, assert_true

from sql.sql_ast import (
    FromRelation, SXIVL_DAY, SXIVL_HOUR, SXIVL_MONTH, TVF_NONE,
)
from sql.sql_parser import parse_sql
from sql.sql_series_ast import (
    SERIES_ARG_COLUMN, SERIES_ARG_DATE, SERIES_ARG_DECIMAL, SERIES_ARG_INT,
    SERIES_ARG_INTERVAL, SERIES_ARG_NULL, SERIES_ARG_OTHER, SERIES_ARG_STRING,
    SERIES_ARG_TIMESTAMP, SERIES_ARG_TIMESTAMPTZ, SERIES_RELATION_PREFIX,
)
from sql.sql_token import tokenize


def _rel(sql: String, index: Int = 0) raises -> FromRelation:
    var st = parse_sql(tokenize(sql))
    return st.query.from_tables[index].copy()


def _err(sql: String) raises -> String:
    try:
        _ = parse_sql(tokenize(sql))
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def test_both_names_parse_with_one_two_and_three_arguments() raises:
    var one = _rel("SELECT * FROM generate_series(5)")
    assert_true(Bool(one.series))
    assert_equal(one.series.value().fn_name, "generate_series")
    assert_equal(len(one.series.value().args), 1)
    assert_equal(Int(one.series.value().args[0].kind), Int(SERIES_ARG_INT))
    assert_equal(Int(one.series.value().args[0].int_val), 5)
    var two = _rel("SELECT * FROM range(2, 9)")
    assert_equal(two.series.value().fn_name, "range")
    assert_equal(len(two.series.value().args), 2)
    assert_equal(Int(two.series.value().args[0].int_val), 2)
    assert_equal(Int(two.series.value().args[1].int_val), 9)
    var three = _rel("SELECT * FROM generate_series(1, 10, 3)")
    assert_equal(len(three.series.value().args), 3)
    assert_equal(Int(three.series.value().args[2].int_val), 3)
    assert_equal(Int(three.tvf_kind), Int(TVF_NONE))
    assert_true(not three.tvf_path)


def test_each_literal_shape_is_read_into_its_kind() raises:
    var call = _rel(
        "SELECT * FROM generate_series(-4, NULL, DATE '2024-01-01')"
    ).series.value().copy()
    assert_equal(Int(call.args[0].kind), Int(SERIES_ARG_INT))
    assert_equal(Int(call.args[0].int_val), -4)
    assert_equal(Int(call.args[1].kind), Int(SERIES_ARG_NULL))
    assert_equal(Int(call.args[2].kind), Int(SERIES_ARG_DATE))
    assert_equal(call.args[2].text, "2024-01-01")
    var ts = _rel(
        "SELECT * FROM generate_series(TIMESTAMP '2024-01-01 10:00:00',"
        " TIMESTAMPTZ '2024-01-02 00:00:00+00', INTERVAL '2' HOUR)"
    ).series.value().copy()
    assert_equal(Int(ts.args[0].kind), Int(SERIES_ARG_TIMESTAMP))
    assert_equal(ts.args[0].text, "2024-01-01 10:00:00")
    assert_equal(Int(ts.args[1].kind), Int(SERIES_ARG_TIMESTAMPTZ))
    assert_equal(Int(ts.args[2].kind), Int(SERIES_ARG_INTERVAL))
    assert_equal(Int(ts.args[2].int_val), 2)
    assert_equal(Int(ts.args[2].unit), Int(SXIVL_HOUR))
    var iv = _rel(
        "SELECT * FROM range(DATE '2024-01-01', DATE '2025-01-01',"
        " INTERVAL -1 MONTH)"
    ).series.value().copy()
    assert_equal(Int(iv.args[2].int_val), -1)
    assert_equal(Int(iv.args[2].unit), Int(SXIVL_MONTH))
    var other = _rel(
        "SELECT * FROM generate_series('a', 1.5, INTERVAL '1' DAY)"
    ).series.value().copy()
    assert_equal(Int(other.args[0].kind), Int(SERIES_ARG_STRING))
    assert_equal(Int(other.args[1].kind), Int(SERIES_ARG_DECIMAL))
    assert_equal(Int(other.args[2].unit), Int(SXIVL_DAY))


def test_columns_and_other_expressions_are_recorded_by_kind() raises:
    var c = _rel("SELECT * FROM t, generate_series(1, t.x)", 1).series.value().copy()
    assert_equal(Int(c.args[1].kind), Int(SERIES_ARG_COLUMN))
    assert_equal(c.args[1].text, "x")
    var bare = _rel("SELECT * FROM t, generate_series(x, 3)", 1).series.value().copy()
    assert_equal(Int(bare.args[0].kind), Int(SERIES_ARG_COLUMN))
    var sum = _rel("SELECT * FROM generate_series(1 + 2, 9)").series.value().copy()
    assert_equal(Int(sum.args[0].kind), Int(SERIES_ARG_OTHER))
    var cast = _rel("SELECT * FROM generate_series(CAST(1 AS BIGINT), 9)").series.value().copy()
    assert_equal(Int(cast.args[0].kind), Int(SERIES_ARG_OTHER))
    var big = _rel("SELECT * FROM generate_series(1, 9223372036854775808)").series.value().copy()
    assert_equal(Int(big.args[1].kind), Int(SERIES_ARG_OTHER))


def test_the_relation_answers_to_its_alias_or_the_function_name() raises:
    var bare = _rel("SELECT * FROM generate_series(1, 3)")
    assert_equal(bare.rel_alias, "generate_series")
    assert_equal(bare.name, SERIES_RELATION_PREFIX + "generate_series")
    assert_true(bare.name.find(" ") >= 0)
    assert_equal(_rel("SELECT * FROM range(3)").rel_alias, "range")
    assert_equal(_rel("SELECT * FROM range(3) AS t").rel_alias, "t")
    assert_equal(_rel("SELECT * FROM range(3) t").rel_alias, "t")
    assert_equal(len(_rel("SELECT * FROM range(3) t").series.value().column_names), 0)


def test_an_alias_takes_a_column_name_list() raises:
    var one = _rel("SELECT * FROM generate_series(1, 3) AS t(d)")
    assert_equal(one.rel_alias, "t")
    assert_equal(len(one.series.value().column_names), 1)
    assert_equal(one.series.value().column_names[0], "d")
    var many = _rel("SELECT * FROM generate_series(1, 3) t(d, e, f)")
    assert_equal(len(many.series.value().column_names), 3)
    assert_equal(many.series.value().column_names[2], "f")


def test_the_call_sits_among_other_relations_and_clauses() raises:
    var st = parse_sql(tokenize(
        "SELECT * FROM generate_series(1, 3) AS a(x), range(2) AS b(y)"
        " JOIN u ON u.k = a.x WHERE a.x > 1"
    ))
    assert_equal(len(st.query.from_tables), 3)
    assert_true(Bool(st.query.from_tables[0].series))
    assert_true(Bool(st.query.from_tables[1].series))
    assert_true(not st.query.from_tables[2].series)
    assert_equal(st.query.from_tables[2].name, "u")
    var where = parse_sql(tokenize("SELECT * FROM range(4) WHERE 1 = 1 LIMIT 2"))
    assert_equal(where.query.from_tables[0].rel_alias, "range")


def test_empty_list_parses_and_broken_lists_are_syntax_errors() raises:
    assert_equal(len(_rel("SELECT * FROM range()").series.value().args), 0)
    _ = _err("SELECT * FROM range(1,")
    assert_true("')'" in _err("SELECT * FROM range(1 2)"))
    assert_true("column name" in _err("SELECT * FROM range(3) AS t(1)"))
    assert_true("')'" in _err("SELECT * FROM range(3) AS t(a b)"))


def test_the_words_stay_a_table_name_and_a_column_without_a_call() raises:
    var table = _rel("SELECT * FROM range")
    assert_true(not table.series)
    assert_equal(table.name, "range")
    var col = parse_sql(tokenize("SELECT range FROM t"))
    assert_equal(len(col.query.select_items), 1)
    var gs = _rel("SELECT * FROM generate_series")
    assert_true(not gs.series)
    assert_equal(gs.name, "generate_series")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
