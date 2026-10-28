# =============================================================================
# Direct tests of the name and key helpers of sql_bind_names
# =============================================================================
#
# test_sql_bind_names covers `_duckdb_expr_text`; this file covers the rest.
#   1. `_group_has` / `_group_spelling` match case-insensitively, and the
#      spelling answers with the list's own text ("" when absent).
#   2. `_sxop_text` / `_sxagg_text` print DuckDB's token for each code, with
#      `/` as the fallback.
#   3. `_unaliased_agg_out_name` names a bare aggregate by its source token and
#      appends `_1`, `_2`, ... while the name is a group key or already taken.
#   4. `_select_alias_index` finds the first SELECT item with an alias,
#      ignoring case; `_canon_index` compares column keys case-insensitively
#      and expression keys exactly, never across the two kinds.
#   5. `_sx_is_literal` is true for the six literal tags and false for an
#      expression over literals, a column and NULL.
#   6. `_gb_const_canon` names a GROUP BY literal constant reached directly,
#      by ordinal or by SELECT alias, and answers "" for a column, a column
#      that an input column shadows, an out-of-range or big ordinal and a
#      non-literal item; a `*` item is not a constant.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_ast import (
    SXAGG_AVG, SXAGG_COUNT, SXAGG_MAX, SXAGG_MIN, SXAGG_SUM, SXOP_ADD,
    SXOP_AND, SXOP_CONCAT, SXOP_DIV, SXOP_EQ, SXOP_GE, SXOP_GT, SXOP_IDIV,
    SXOP_LE, SXOP_LT, SXOP_MOD, SXOP_MUL, SXOP_NE, SXOP_OR, SXOP_POW,
    SXOP_STARTS_WITH, SXOP_SUB, SqlExpr, SelectStmt,
)
from komira_sql.sql_bind_names import (
    _canon_index,
    _gb_const_canon,
    _group_has,
    _group_spelling,
    _select_alias_index,
    _sx_is_literal,
    _sxagg_text,
    _sxop_text,
    _unaliased_agg_out_name,
)
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    return sb.build()


def _sx(expr: String) raises -> SqlExpr:
    var st = parse_sql(tokenize("SELECT " + expr + " FROM t"))
    return st.query.select_items[0].expr.copy()


def _names(*names: String) -> List[String]:
    var out = List[String]()
    for n in names:
        out.append(n)
    return out^


def test_group_membership_and_spelling() raises:
    var g = _names("Key", "v")
    assert_true(_group_has(g, "kEY"))
    assert_true(_group_has(g, "V"))
    assert_false(_group_has(g, "w"))
    assert_false(_group_has(List[String](), "k"))
    assert_equal(_group_spelling(g, "KEY"), "Key")
    assert_equal(_group_spelling(g, "w"), "")


def test_operator_and_aggregate_tokens() raises:
    assert_equal(_sxop_text(SXOP_EQ), "=")
    assert_equal(_sxop_text(SXOP_NE), "!=")
    assert_equal(_sxop_text(SXOP_LT), "<")
    assert_equal(_sxop_text(SXOP_LE), "<=")
    assert_equal(_sxop_text(SXOP_GT), ">")
    assert_equal(_sxop_text(SXOP_GE), ">=")
    assert_equal(_sxop_text(SXOP_AND), "AND")
    assert_equal(_sxop_text(SXOP_OR), "OR")
    assert_equal(_sxop_text(SXOP_ADD), "+")
    assert_equal(_sxop_text(SXOP_SUB), "-")
    assert_equal(_sxop_text(SXOP_MUL), "*")
    assert_equal(_sxop_text(SXOP_IDIV), "//")
    assert_equal(_sxop_text(SXOP_MOD), "%")
    assert_equal(_sxop_text(SXOP_POW), "^")
    assert_equal(_sxop_text(SXOP_CONCAT), "||")
    assert_equal(_sxop_text(SXOP_STARTS_WITH), "^@")
    assert_equal(_sxop_text(SXOP_DIV), "/")
    assert_equal(_sxagg_text(SXAGG_SUM), "sum")
    assert_equal(_sxagg_text(SXAGG_COUNT), "count")
    assert_equal(_sxagg_text(SXAGG_MIN), "min")
    assert_equal(_sxagg_text(SXAGG_MAX), "max")
    assert_equal(_sxagg_text(SXAGG_AVG), "avg")


def test_unaliased_aggregate_names_stay_unique() raises:
    var sx = _sx("sum(v)")
    assert_equal(_unaliased_agg_out_name(sx, List[String](), List[String]()), "sum(v)")
    assert_equal(_unaliased_agg_out_name(sx, List[String](), _names("sum(v)")), "sum(v)_1")
    assert_equal(
        _unaliased_agg_out_name(sx, List[String](), _names("sum(v)", "sum(v)_1")), "sum(v)_2"
    )
    assert_equal(_unaliased_agg_out_name(sx, _names("SUM(V)"), List[String]()), "sum(v)_1")
    assert_equal(
        _unaliased_agg_out_name(_sx("median(v)"), List[String](), List[String]()), "median(v)"
    )
    assert_equal(
        _unaliased_agg_out_name(_sx("count(*)"), List[String](), List[String]()), "count_star()"
    )


def test_alias_and_canonical_key_lookup() raises:
    var st = parse_sql(tokenize("SELECT k AS X, v AS x, v FROM t"))
    assert_equal(_select_alias_index(st.query, "x"), 0)
    assert_equal(_select_alias_index(st.query, "X"), 0)
    assert_equal(_select_alias_index(st.query, "v"), -1)

    var canons = _names("k", "(v + 1)")
    var is_col = List[Bool]()
    is_col.append(True)
    is_col.append(False)
    assert_equal(_canon_index(canons, is_col, "K", True), 0)
    assert_equal(_canon_index(canons, is_col, "(v + 1)", False), 1)
    assert_equal(_canon_index(canons, is_col, "(V + 1)", False), -1)
    assert_equal(_canon_index(canons, is_col, "k", False), -1)
    assert_equal(_canon_index(canons, is_col, "(v + 1)", True), -1)


def test_literal_tags() raises:
    for lit in ["1", "1.5", "'s'", "DATE '2020-01-01'", "TIMESTAMP '2021-01-01 00:00:00'", "true"]:
        assert_true(_sx_is_literal(_sx(String(lit))), lit)
    for non in ["1 + 1", "k", "NULL", "abs(1)"]:
        assert_false(_sx_is_literal(_sx(String(non))), non)


def _canon(sql: String) raises -> String:
    var st = parse_sql(tokenize(sql))
    return _gb_const_canon(st.query, st.query.group_by[0].copy(), _schema())


def test_group_by_constant_canonical_form() raises:
    assert_equal(_canon("SELECT 1 AS c, k FROM t GROUP BY c"), "1")
    assert_equal(_canon("SELECT 'x', k FROM t GROUP BY 1"), "'x'")
    assert_equal(_canon("SELECT k FROM t GROUP BY 'x'"), "'x'")
    assert_equal(_canon("SELECT k FROM t GROUP BY DATE '1995-03-15'"), "CAST('1995-03-15' AS \"DATE\")")
    # An ordinal names its select item, whatever its own value would be.
    assert_equal(_canon("SELECT 7, k FROM t GROUP BY 1"), "7")
    assert_equal(_canon("SELECT 7, k FROM t GROUP BY 2"), "")
    assert_equal(_canon("SELECT 7, k FROM t GROUP BY 3"), "")
    assert_equal(_canon("SELECT 7, k FROM t GROUP BY 0"), "")
    assert_equal(_canon("SELECT 7, k FROM t GROUP BY 99999999999999999999"), "")
    # An input column beats a select alias of the same name.
    assert_equal(_canon("SELECT 1 AS k, v FROM t GROUP BY k"), "")
    assert_equal(_canon("SELECT 1 AS c, v FROM t GROUP BY t.c"), "")
    assert_equal(_canon("SELECT v FROM t GROUP BY v"), "")
    assert_equal(_canon("SELECT 1 + 1 AS c, v FROM t GROUP BY c"), "")
    assert_equal(_canon("SELECT *, 1 FROM t GROUP BY 1"), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
