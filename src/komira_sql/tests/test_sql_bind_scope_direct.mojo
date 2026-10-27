# =============================================================================
# Direct tests of the binder's name scopes (sql_bind_scope)
# =============================================================================
#
# Statements are parsed and the FROM scope is built over a catalog of small
# tables, so every answer is read off a scope the binder itself would build.
# Tables: K(k, a), M(k, b), U(u).
#   1. CteScope resolves names case-insensitively, the first definition of a
#      name wins over a later one, and a CTE name shadows the same-named
#      catalog table when a relation's schema is looked up.
#   2. `_date_to_days` counts days from 1970-01-01 (negative before it), checks
#      the day against its month's length with the Gregorian leap rule, and
#      refuses a malformed string.
#   3. A joined relation's column that collides with the left's resolves to
#      its `_right` output name; the source spelling and the output name
#      round-trip; an unknown column or qualifier raises.
#   4. An alias hides the table name behind it.
#   5. Two relations answering to one qualifier: a column only one has
#      resolves, a column both have raises "ambiguous"; `slice` drops the
#      relations outside a join's own inputs, which removes the ambiguity.
#   6. NATURAL joins coalesce the key (no second `k` in the scope); a SEMI
#      join's right relation contributes no column and no qualifier.
#   7. `_join_out_name` takes the first free `_right` / `_right_<n>` name;
#      `_dedupe_join_right` projects a right column to that name only when
#      the join node's own rename would not give it.
#   8. `_resolve_col` maps a qualified reference through the scope and checks
#      an unqualified one against the schema, case-insensitively.
#   9. The result names: `*` and a qualified column go back to their source
#      spelling, an aliased item keeps its alias, and no rename Project is
#      built when no name changes or the lengths disagree.
#  10. `_catalog_name` refuses a `#`-keyed derived relation by its alias;
#      `_schema_col_spelling` returns the schema's own spelling.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder

from komira_sql.sql_ast import FromRelation, SqlExpr
from komira_sql.sql_bind_parquet import ParquetFacts
from komira_sql.sql_bind_scope import (
    BindScope,
    CteScope,
    _build_bind_scope,
    _catalog_name,
    _date_to_days,
    _dedupe_join_right,
    _join_out_name,
    _relation_schema,
    _resolve_col,
    _result_display_names,
    _result_rename_exprs,
    _schema_col_spelling,
    _schema_has_col,
)
from komira_sql.sql_catalog import SqlCatalog
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _cols(a: String, b: String = String("")) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(a, ArrowType.INT64, True))
    if b != "":
        sb.add_field(Field(b, ArrowType.INT64, True))
    return sb.build()


def _catalog() -> SqlCatalog:
    var cat = SqlCatalog()
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    cat.add_parquet("K", "k.parquet", sb.build())
    cat.add_parquet("M", "m.parquet", _cols("k", "b"))
    cat.add_parquet("U", "u.parquet", _cols("u"))
    return cat^


def _scope(sql: String) raises -> BindScope:
    var st = parse_sql(tokenize(sql))
    return _build_bind_scope(
        st.query.from_tables, st.query.joins, _catalog(), CteScope(ParquetFacts())
    )


def _raises_with(scope: BindScope, q: String, name: String, needle: String) raises -> Bool:
    try:
        _ = scope.resolve_qualified(q, name)
    except e:
        return String(e).find(needle) >= 0
    return False


def _out_names(scope: BindScope) -> String:
    var s = String("")
    for i in range(scope.out_schema.num_columns()):
        if i > 0:
            s += ","
        s += String(scope.out_schema.field_name(i))
    return s


def test_cte_scope_names_shadowing_and_copies() raises:
    var cat = _catalog()
    var cte = CteScope(ParquetFacts())
    assert_false(cte.has("x"))
    assert_equal(cte.find("x"), -1)
    cte.add("Foo", cat.build_scan("u"))
    cte.add("FOO", cat.build_scan("m"))
    assert_true(cte.has("foo"))
    assert_equal(cte.find("fOO"), 0)
    assert_equal(cte.schema_copy(0).field_name(0), "u")
    assert_equal(cte.plan_copy(1).output_schema.num_columns(), 2)
    # A CTE named like a catalog table answers for it.
    cte.add("k", cat.build_scan("u"))
    var rel = FromRelation.named("K")
    var sch = _relation_schema(rel, cat, cte)
    assert_equal(sch.num_columns(), 1)
    assert_equal(sch.field_name(0), "u")
    var plain = _relation_schema(FromRelation.named("M"), cat, cte)
    assert_equal(plain.num_columns(), 2)


def test_date_to_days() raises:
    assert_equal(Int(_date_to_days("1970-01-01")), 0)
    assert_equal(Int(_date_to_days("1969-12-31")), -1)
    assert_equal(Int(_date_to_days("1995-03-15")), 9204)
    assert_equal(Int(_date_to_days("2000-02-29")), 11016)
    assert_equal(Int(_date_to_days("2000-03-01")), 11017)
    assert_equal(Int(_date_to_days("2020-02-29")), 18321)
    for bad in ["2021-02-30", "2100-02-29", "2021-04-31", "2021-13-01", "2021-00-10", "2021-1-01", "20210101"]:
        var raised = False
        try:
            _ = _date_to_days(String(bad))
        except:
            raised = True
        assert_true(raised, bad)


def test_collision_renames_and_resolution() raises:
    var s = _scope("SELECT * FROM k JOIN m ON k.k = m.k")
    assert_equal(_out_names(s), "k,a,k_right,b")
    assert_equal(s.resolve_qualified("K", "k"), "k")
    assert_equal(s.resolve_qualified("m", "K"), "k_right")
    assert_equal(s.resolve_qualified("M", "b"), "b")
    assert_equal(s.source_name_of("m", "k"), "k")
    assert_equal(s.source_name_of_output("k_right"), "k")
    assert_equal(s.source_name_of_output("a"), "a")
    assert_equal(s.source_name_of_output("nope"), "nope")
    assert_equal(s.source_name_of("m", "zz"), "")
    assert_true(s.has_qualified("M", "B"))
    assert_false(s.has_qualified("k", "b"))
    assert_true(s.answers_to("M"))
    assert_false(s.answers_to("u"))
    assert_true(_raises_with(s, "m", "zz", "unknown column 'm.zz'"))
    assert_true(_raises_with(s, "u", "u", "unknown column 'u.u'"))


def test_alias_hides_the_table_name() raises:
    var s = _scope("SELECT * FROM k AS x")
    assert_true(s.answers_to("x"))
    assert_false(s.answers_to("k"))
    assert_equal(s.resolve_qualified("x", "a"), "a")
    assert_true(_raises_with(s, "k", "a", "unknown column 'k.a'"))
    var bare = _scope("SELECT * FROM k")
    assert_true(bare.answers_to("K"))


def test_shared_qualifier_and_slice() raises:
    var s = _scope("SELECT * FROM k AS z, m, m AS z")
    # `a` is only in the first `z`, `b` only in the second.
    assert_equal(s.resolve_qualified("z", "a"), "a")
    assert_equal(s.resolve_qualified("z", "b"), "b_right")
    assert_true(s.has_qualified("z", "k"))
    assert_true(_raises_with(s, "z", "k", "ambiguous reference to table `z`"))
    var err = String("")
    try:
        _ = s.source_name_of("z", "k")
    except e:
        err = String(e)
    assert_true(err.find("ambiguous reference to table `z`") >= 0)
    # A join's ON sees only its two inputs, so the later `z` is not in play.
    var two = s.slice(0, 2)
    assert_equal(two.resolve_qualified("z", "k"), "k")
    assert_false(two.answers_to("q"))
    assert_true(two.answers_to("m"))
    assert_equal(_out_names(two), _out_names(s))
    var last = s.slice(2, 3)
    assert_false(last.answers_to("k"))
    assert_true(last.answers_to("z"))


def test_natural_join_coalesces_and_semi_join_hides() raises:
    var nat = _scope("SELECT * FROM k NATURAL JOIN m")
    assert_equal(_out_names(nat), "k,a,b")
    assert_equal(nat.resolve_qualified("m", "k"), "k")
    assert_equal(nat.resolve_qualified("m", "b"), "b")
    var semi = _scope("SELECT * FROM k SEMI JOIN m ON k.k = m.k")
    assert_equal(_out_names(semi), "k,a")
    assert_false(semi.answers_to("m"))
    assert_true(semi.answers_to("k"))
    assert_true(_raises_with(semi, "m", "b", "unknown column 'm.b'"))


def test_join_out_name_and_dedupe() raises:
    var left = List[String]()
    left.append("k")
    left.append("a")
    var right = List[String]()
    right.append("k")
    right.append("b")
    assert_equal(_join_out_name("b", left, right), "b")
    assert_equal(_join_out_name("k", left, right), "k_right")
    left.append("k_right")
    assert_equal(_join_out_name("k", left, right), "k_right_2")
    left.append("k_right_2")
    assert_equal(_join_out_name("k", left, right), "k_right_3")
    var right2 = List[String]()
    right2.append("k")
    right2.append("k_right")
    var left2 = List[String]()
    left2.append("k")
    assert_equal(_join_out_name("k", left2, right2), "k_right_2")

    var cat = _catalog()
    var keys = List[String]()
    # The left side already holds `k` and `k_right`: the right `k` must be
    # renamed by a Project, since the join node would produce a second `k_right`.
    var lsb = SchemaBuilder()
    lsb.add_field(Field(String("k"), ArrowType.INT64, True))
    lsb.add_field(Field(String("k_right"), ArrowType.INT64, True))
    var renamed = _dedupe_join_right(lsb.build(), cat.build_scan("m"), keys)
    assert_false(renamed.is_scan())
    assert_equal(renamed.output_schema.field_name(0), "k_right_2")
    assert_equal(renamed.output_schema.field_name(1), "b")
    # With only a plain `k` on the left the join node's own rename suffices.
    var same = _dedupe_join_right(_cols("k", "a"), cat.build_scan("m"), keys)
    assert_true(same.is_scan())
    # A coalesced key column is matched by name and never renamed.
    keys.append("K")
    var kept = _dedupe_join_right(lsb.build(), cat.build_scan("m"), keys)
    assert_true(kept.is_scan())


def test_resolve_col() raises:
    var s = _scope("SELECT * FROM k JOIN m ON k.k = m.k")
    var st = parse_sql(tokenize("SELECT m.k, a, zz, u.k FROM k"))
    ref items = st.query.select_items
    assert_equal(_resolve_col(items[0].expr, s.out_schema, s), "k_right")
    assert_equal(_resolve_col(items[1].expr, s.out_schema, s), "a")
    # A name is checked case-insensitively and returned as written.
    assert_equal(_resolve_col(SqlExpr.column(String("A")), s.out_schema, s), "A")
    var unqualified = String("")
    try:
        _ = _resolve_col(items[2].expr, s.out_schema, s)
    except e:
        unqualified = String(e)
    assert_true(unqualified.find("unknown column 'zz'") >= 0)
    var qualified = String("")
    try:
        _ = _resolve_col(items[3].expr, s.out_schema, s)
    except e:
        qualified = String(e)
    assert_true(qualified.find("unknown column 'u.k'") >= 0)


def test_result_names_and_rename_exprs() raises:
    var sql = "SELECT * FROM k JOIN m ON k.k = m.k"
    var st = parse_sql(tokenize(sql))
    var s = _scope(sql)
    var names = _result_display_names(st.query, s)
    assert_equal(len(names), 4)
    assert_equal(names[0], "k")
    assert_equal(names[2], "k")
    assert_equal(names[3], "b")
    var renames = _result_rename_exprs(s.out_schema, names, 4)
    assert_true(Bool(renames))
    assert_equal(len(renames.value()), 4)

    var q = "SELECT m.k, m.b AS bb, a FROM k JOIN m ON k.k = m.k"
    var st2 = parse_sql(tokenize(q))
    var s2 = _scope(q)
    var n2 = _result_display_names(st2.query, s2)
    assert_equal(len(n2), 3)
    assert_equal(n2[0], "k")
    assert_equal(n2[1], "")
    assert_equal(n2[2], "")

    var plain = List[String]()
    plain.append("k")
    plain.append("a")
    assert_false(Bool(_result_rename_exprs(_cols("k", "a"), plain, 2)))
    assert_false(Bool(_result_rename_exprs(_cols("k", "a"), plain, 1)))
    var blank = List[String]()
    blank.append("")
    blank.append("")
    assert_false(Bool(_result_rename_exprs(_cols("k", "a"), blank, 2)))
    var too_many = List[String]()
    too_many.append("x")
    too_many.append("y")
    too_many.append("z")
    assert_false(Bool(_result_rename_exprs(_cols("k", "a"), too_many, 3)))


def test_catalog_name_and_spelling() raises:
    assert_equal(_catalog_name(FromRelation.named("m")), "m")
    var raised = String("")
    try:
        _ = _catalog_name(FromRelation.named("d#3", "d"))
    except e:
        raised = String(e)
    assert_true(raised.find("a derived table `(SELECT ...) AS d` inside a CTE body") >= 0)
    var sch = _cols("Key", "v")
    assert_equal(_schema_col_spelling(sch, "kEY"), "Key")
    assert_equal(_schema_col_spelling(sch, "zz"), "")
    assert_true(_schema_has_col(sch, "V"))
    assert_false(_schema_has_col(sch, "w"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
