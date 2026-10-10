# =============================================================================
# sql_parser: statements, clauses and the COPY / CREATE TABLE AS forms
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. A trailing `;` is accepted and anything else after the query is
#      "unexpected trailing tokens". (catches: _finalize accepting extra
#      tokens, or refusing the `;`)
#   2. `UNION ALL` chains each branch off the previous one in the subquery
#      table; bare UNION, INTERSECT and EXCEPT are refused by name.
#      (catches: every branch hung off the root; bare UNION bound as UNION ALL)
#   3. COPY: a bare table (with or without a schema qualifier) becomes
#      `SELECT * FROM t`, a parenthesised query is the source, and the
#      defaults are parquet + snappy; every malformed COPY head is refused.
#      (catches: the qualifier dropping the last component; a wrong default)
#   4. COPY options: FORMAT / COMPRESSION / CODEC / COMPRESSION_LEVEL /
#      HEADER / ARRAY in any order, each value spelled quoted or bare, every
#      codec word, every refusal of the validation pass. (catches: a codec
#      word mapped to the wrong code; a level other than the wired one
#      accepted; an option validated before FORMAT is known)
#   5. CREATE [OR REPLACE] TABLE [IF NOT EXISTS] <name> AS [(]<query>[)] and
#      its malformed spellings. (catches: `replace` not recorded)
#   6. WITH: several CTEs, WITH RECURSIVE refused, a keyword or a number as
#      a CTE name refused, an unclosed body refused. (catches: a structural
#      keyword accepted as a CTE name)
#   7. DISTINCT and the refused DISTINCT ON; a column named `on`.
#   8. A FROM-less select list ends at every clause keyword DuckDB allows
#      there, and the refused clause words are named. (catches: a missing
#      clause word, which would fail on the missing FROM instead)
#   9. GROUP BY / HAVING / ORDER BY with ASC / DESC and NULLS FIRST / LAST.
#      (catches: NULLS FIRST and LAST swapped; a bare NULLS accepted)
#  10. LIMIT / OFFSET / FETCH in either order with their noise words, each
#      duplicate refused, a non-integer refused, a literal past BIGINT
#      refused by name. (catches: an OFFSET-before-LIMIT order refused; the
#      wrapped bits of a big literal used as the limit)
#  11. Unaliased derived tables are named `unnamed_subquery`,
#      `unnamed_subquery2`, ... per SELECT level; every derived table, aliased
#      or not, is keyed apart by subquery index (`<qualifier>#<index>`), and a
#      derived qualifier that another relation of the same FROM answers to
#      (by name or alias) is refused with the exact text. (catches: the count
#      not restarted in a nested SELECT; an aliased derived table keyed by
#      its bare alias; either arm of the name-or-alias test dropped)
#  12. A derived table's column-list rename and its malformed spellings.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.write_target import (
    WFMT_PARQUET, WFMT_CSV, WFMT_JSONL,
    WCOMP_SNAPPY, WCOMP_UNCOMPRESSED, WCOMP_ZSTD, WCOMP_GZIP, WCOMP_LZ4,
)
from komira_sql.sql_token import tokenize
from komira_sql.sql_ast import (
    SqlStatement,
    FROM_LESS_RELATION,
    STMT_QUERY,
    STMT_COPY,
    STMT_CREATE_TABLE_AS,
    SUBQ_UNION_ALL,
    SUBQ_DERIVED,
    SX_COLUMN,
)
from komira_sql.sql_parser import parse_sql


def _parse(sql: String) raises -> SqlStatement:
    return parse_sql(tokenize(sql))


def _err(sql: String) raises -> String:
    try:
        _ = _parse(sql)
    except e:
        return String(e)
    raise Error("parsed, expected a refusal: " + sql)


def _refuses(sql: String, needle: String) raises:
    var m = _err(sql)
    assert_true(needle in m, "`" + sql + "` raised: " + m)


def _copy(opts: String) raises -> SqlStatement:
    return _parse("COPY t TO 'out' " + opts)


def _copy_pair(opts: String, fmt: UInt8, codec: UInt8) raises:
    var st = _copy(opts)
    assert_equal(Int(st.fmt), Int(fmt), opts)
    assert_equal(Int(st.codec), Int(codec), opts)


def test_trailing_semicolon_and_trailing_tokens() raises:
    var st = _parse("SELECT a FROM t;")
    assert_equal(Int(st.kind), Int(STMT_QUERY))
    _refuses("SELECT a FROM t b c", "unexpected trailing tokens after query")
    _refuses("SELECT a FROM t; x", "unexpected trailing tokens after query")


def test_union_all_chains_and_other_set_operators_refuse() raises:
    var st = _parse(
        "SELECT a FROM t UNION ALL SELECT b FROM u UNION ALL SELECT c FROM v"
    )
    assert_equal(st.query.union_all_idx, 0)
    assert_equal(len(st.query.subqueries), 2)
    assert_equal(Int(st.query.subqueries[0].kind), Int(SUBQ_UNION_ALL))
    assert_equal(st.query.subqueries[0].body.from_tables[0].name, "u")
    assert_equal(st.query.subqueries[0].body.union_all_idx, 1)
    assert_equal(st.query.subqueries[1].body.from_tables[0].name, "v")
    assert_equal(st.query.subqueries[1].body.union_all_idx, -1)
    _refuses("SELECT a FROM t UNION SELECT a FROM u", "bare UNION")
    _refuses("SELECT a FROM t INTERSECT SELECT a FROM u", "the INTERSECT set operator")
    _refuses("SELECT a FROM t EXCEPT SELECT a FROM u", "the EXCEPT set operator")


def test_copy_heads() raises:
    var st = _parse("COPY t TO 'out.parquet'")
    assert_equal(Int(st.kind), Int(STMT_COPY))
    assert_equal(st.dest_path, "out.parquet")
    assert_equal(Int(st.fmt), Int(WFMT_PARQUET))
    assert_equal(Int(st.codec), Int(WCOMP_SNAPPY))
    assert_true(st.query.select_items[0].is_star)
    assert_equal(st.query.from_tables[0].name, "t")
    var q = _parse("COPY s.t2 TO 'o'")
    assert_equal(q.query.from_tables[0].name, "t2")
    var sub = _parse("COPY (SELECT a FROM t WHERE a > 1) TO 'o.csv' (FORMAT csv);")
    assert_equal(sub.query.select_items[0].expr.text, "a")
    assert_true(Bool(sub.query.where_pred))
    assert_equal(Int(sub.fmt), Int(WFMT_CSV))
    assert_equal(Int(sub.codec), Int(WCOMP_UNCOMPRESSED))
    _refuses("COPY s.'x' TO 'o'", "expected identifier after '.'")
    _refuses("COPY (SELECT a FROM t TO 'o'", "')' to close the COPY source query")
    _refuses("COPY 5 TO 'o'", "COPY expects a table name or `(SELECT ...)`")
    _refuses("COPY t 'o'", "expected keyword 'to'")
    _refuses("COPY t TO o", "COPY ... TO expects a string path")


def test_copy_options() raises:
    _copy_pair("(FORMAT 'PARQUET', COMPRESSION zstd, COMPRESSION_LEVEL 3)", WFMT_PARQUET, WCOMP_ZSTD)
    _copy_pair("(COMPRESSION_LEVEL 6, CODEC 'gz', FORMAT json)", WFMT_JSONL, WCOMP_GZIP)
    _copy_pair("(FORMAT jsonl, COMPRESSION gzip)", WFMT_JSONL, WCOMP_GZIP)
    _copy_pair("(FORMAT ndjson, ARRAY false)", WFMT_JSONL, WCOMP_UNCOMPRESSED)
    _copy_pair("(FORMAT json, ARRAY '0', COMPRESSION lz4)", WFMT_JSONL, WCOMP_LZ4)
    _copy_pair("(FORMAT json, ARRAY off)", WFMT_JSONL, WCOMP_UNCOMPRESSED)
    _copy_pair("(COMPRESSION lz4_raw)", WFMT_PARQUET, WCOMP_LZ4)
    _copy_pair("(COMPRESSION snappy)", WFMT_PARQUET, WCOMP_SNAPPY)
    _copy_pair("(COMPRESSION none)", WFMT_PARQUET, WCOMP_UNCOMPRESSED)
    _copy_pair("(COMPRESSION uncompressed)", WFMT_PARQUET, WCOMP_UNCOMPRESSED)
    _copy_pair("(HEADER true, FORMAT 'csv')", WFMT_CSV, WCOMP_UNCOMPRESSED)
    _copy_pair("(FORMAT csv, HEADER '1', COMPRESSION zstd)", WFMT_CSV, WCOMP_ZSTD)
    _copy_pair("(FORMAT csv, HEADER on)", WFMT_CSV, WCOMP_UNCOMPRESSED)
    _refuses("COPY t TO 'o' (5)", "expected a COPY option (FORMAT")
    _refuses("COPY t TO 'o' (FOO 1)", "COPY option 'foo'")
    _refuses("COPY t TO 'o' (FORMAT 7)", "expected a COPY option value")
    _refuses("COPY t TO 'o' (FORMAT avro)", "(FORMAT 'avro')")
    _refuses("COPY t TO 'o' (COMPRESSION brotli)", "COPY compression 'brotli'")
    _refuses(
        "COPY t TO 'o' (FORMAT csv, COMPRESSION snappy)",
        "(FORMAT 'csv', COMPRESSION 'snappy') — no wired write sink",
    )
    _refuses("COPY t TO 'o' (HEADER true)", "HEADER applies to FORMAT 'csv', not 'parquet'")
    _refuses("COPY t TO 'o' (FORMAT csv, HEADER false)", "(HEADER false)")
    _refuses("COPY t TO 'o' (FORMAT csv, HEADER 'off')", "(HEADER false)")
    _refuses("COPY t TO 'o' (FORMAT csv, HEADER '0')", "(HEADER false)")
    _refuses("COPY t TO 'o' (FORMAT csv, HEADER maybe)", "HEADER expects true/false, got 'maybe'")
    _refuses("COPY t TO 'o' (FORMAT csv, ARRAY false)", "ARRAY applies to FORMAT 'json', not 'csv'")
    _refuses("COPY t TO 'o' (FORMAT json, ARRAY true)", "(ARRAY true)")
    _refuses("COPY t TO 'o' (FORMAT json, ARRAY '1')", "(ARRAY true)")
    _refuses("COPY t TO 'o' (FORMAT json, ARRAY on)", "(ARRAY true)")
    _refuses("COPY t TO 'o' (COMPRESSION_LEVEL 1)", "(COMPRESSION_LEVEL 1) — codec 'snappy' takes no level")
    _refuses("COPY t TO 'o' (FORMAT csv, COMPRESSION lz4, COMPRESSION_LEVEL 1)", "codec 'lz4' takes no level")
    _refuses(
        "COPY t TO 'o' (COMPRESSION zstd, COMPRESSION_LEVEL 9)",
        "(COMPRESSION 'zstd', COMPRESSION_LEVEL 9) — the wired sink is parameterized on level 3",
    )
    _refuses("COPY t TO 'o' (COMPRESSION gzip, COMPRESSION_LEVEL 3)", "parameterized on level 6")
    _refuses("COPY t TO 'o' (COMPRESSION_LEVEL x)", "expected an integer COPY option value")
    _refuses(
        "COPY t TO 'o' (COMPRESSION_LEVEL 99999999999999999999)",
        "the COPY option value 99999999999999999999 is out of range for BIGINT (DuckDB v1.5.3 raises a Conversion Error",
    )
    _refuses("COPY t TO 'o' (FORMAT csv", "')' to close COPY options")


def test_create_table_as() raises:
    var st = _parse("CREATE TABLE x AS SELECT a FROM t")
    assert_equal(Int(st.kind), Int(STMT_CREATE_TABLE_AS))
    assert_equal(st.target_table, "x")
    assert_false(st.replace)
    assert_equal(st.query.from_tables[0].name, "t")
    var r = _parse("CREATE OR REPLACE TABLE IF NOT EXISTS y AS (WITH c AS (SELECT 1) SELECT * FROM c)")
    assert_true(r.replace)
    assert_equal(r.target_table, "y")
    assert_equal(len(r.query.ctes), 1)
    _refuses("CREATE OR TABLE x AS SELECT 1", "expected keyword 'replace'")
    _refuses("CREATE VIEW x AS SELECT 1", "expected keyword 'table'")
    _refuses("CREATE TABLE IF EXISTS x AS SELECT 1", "expected keyword 'not'")
    _refuses("CREATE TABLE IF NOT x AS SELECT 1", "expected keyword 'exists'")
    _refuses("CREATE TABLE 5 AS SELECT 1", "expected a table name after CREATE TABLE")
    _refuses("CREATE TABLE x SELECT 1", "expected keyword 'as'")
    _refuses("CREATE TABLE x AS (SELECT 1", "')' to close the CREATE TABLE AS body")


def test_with_clause() raises:
    var st = _parse("WITH a AS (SELECT 1 AS one), b AS (SELECT 2) SELECT * FROM a, b")
    assert_equal(len(st.query.ctes), 2)
    assert_equal(st.query.ctes[0].name, "a")
    assert_equal(st.query.ctes[0].body.select_items[0].out_alias.value(), "one")
    assert_equal(st.query.ctes[1].name, "b")
    _refuses("WITH RECURSIVE r AS (SELECT 1) SELECT * FROM r", "WITH RECURSIVE")
    _refuses("WITH from AS (SELECT 1) SELECT 1", "expected CTE name after WITH")
    _refuses("WITH 5 AS (SELECT 1) SELECT 1", "expected CTE name after WITH")
    _refuses("WITH a (SELECT 1) SELECT 1", "expected keyword 'as'")
    _refuses("WITH a AS SELECT 1", "'(' after CTE name")
    _refuses("WITH a AS (SELECT 1; SELECT 1", "')' to close the CTE body")
    _refuses("WITH a AS (1) SELECT 1", "expected keyword 'select'")


def test_distinct_and_distinct_on() raises:
    var st = _parse("SELECT DISTINCT a FROM t")
    assert_true(st.query.distinct)
    assert_false(_parse("SELECT a FROM t").query.distinct)
    _refuses("SELECT DISTINCT ON (a) a FROM t", "SELECT DISTINCT ON (...)")
    # `on` not followed by `(` is a column named `on`.
    var col = _parse("SELECT DISTINCT on FROM t")
    assert_true(col.query.distinct)
    assert_equal(col.query.select_items[0].expr.text, "on")


def test_from_less_select_ends_at_every_allowed_clause() raises:
    var tails: List[String] = [
        "", ";", " WHERE 1 = 0", " GROUP BY 1", " HAVING 1 = 1", " ORDER BY 1",
        " LIMIT 1", " OFFSET 1", " FETCH FIRST 1 ROWS ONLY",
        " UNION ALL SELECT 2",
    ]
    for i in range(len(tails)):
        var st = _parse("SELECT 7 / 2 AS x" + tails[i])
        assert_equal(st.query.from_tables[0].name, String(FROM_LESS_RELATION), tails[i])
        assert_equal(len(st.query.from_tables), 1)
    var sub = _parse("SELECT (SELECT 1) AS one")
    assert_equal(sub.query.subqueries[0].body.from_tables[0].name, String(FROM_LESS_RELATION))
    _refuses("SELECT 1 WINDOW w AS (ORDER BY 1)", "a named WINDOW clause")
    _refuses("SELECT 1 QUALIFY 1 = 1", "the QUALIFY clause")
    _refuses("SELECT 1 EXCEPT SELECT 2", "the EXCEPT set operator")
    _refuses("SELECT 1 INTERSECT SELECT 2", "the INTERSECT set operator")
    _refuses("SELECT a b c", "expected keyword 'from'")


def test_group_having_order() raises:
    var st = _parse(
        "SELECT a, count(*) FROM t GROUP BY a, b HAVING count(*) > 1"
        " ORDER BY a DESC NULLS FIRST, b ASC NULLS LAST, c"
    )
    assert_equal(len(st.query.group_by), 2)
    assert_equal(st.query.group_by[1].text, "b")
    assert_true(Bool(st.query.having_pred))
    assert_equal(len(st.query.order_by), 3)
    assert_true(st.query.order_by[0].descending)
    assert_true(st.query.order_by[0].nulls_first.value())
    assert_false(st.query.order_by[1].descending)
    assert_false(st.query.order_by[1].nulls_first.value())
    assert_false(st.query.order_by[2].descending)
    assert_false(Bool(st.query.order_by[2].nulls_first))
    _refuses("SELECT a FROM t ORDER BY a NULLS", "ORDER BY ... NULLS expects FIRST or LAST")
    _refuses("SELECT a FROM t GROUP a", "expected keyword 'by'")
    _refuses("SELECT a FROM t ORDER a", "expected keyword 'by'")


def test_limit_offset_fetch() raises:
    var a = _parse("SELECT a FROM t LIMIT 10 OFFSET 5")
    assert_equal(a.query.limit.value(), 10)
    assert_equal(a.query.offset.value(), 5)
    var b = _parse("SELECT a FROM t OFFSET 5 ROWS LIMIT 10")
    assert_equal(b.query.limit.value(), 10)
    assert_equal(b.query.offset.value(), 5)
    var c = _parse("SELECT a FROM t OFFSET 2 ROW FETCH NEXT 3 ROW ONLY")
    assert_equal(c.query.limit.value(), 3)
    assert_equal(c.query.offset.value(), 2)
    var d = _parse("SELECT a FROM t FETCH 4")
    assert_equal(d.query.limit.value(), 4)
    assert_false(Bool(d.query.offset))
    var e = _parse("SELECT a FROM t FETCH FIRST 1 ROWS")
    assert_equal(e.query.limit.value(), 1)
    _refuses("SELECT a FROM t LIMIT 1 LIMIT 2", "duplicate LIMIT clause")
    _refuses("SELECT a FROM t LIMIT 1 FETCH FIRST 1 ROWS ONLY", "duplicate LIMIT/FETCH clause")
    _refuses("SELECT a FROM t OFFSET 1 OFFSET 2", "duplicate OFFSET clause")
    _refuses("SELECT a FROM t LIMIT x", "LIMIT expects an integer")
    _refuses("SELECT a FROM t FETCH FIRST x ROWS ONLY", "FETCH FIRST expects an integer")
    _refuses("SELECT a FROM t OFFSET -1", "OFFSET expects an integer")
    _refuses("SELECT a FROM t LIMIT 18446744073709551616", "the LIMIT 18446744073709551616 is out of range for BIGINT")
    _refuses("SELECT a FROM t OFFSET 18446744073709551616", "the OFFSET 18446744073709551616 is out of range")
    _refuses("SELECT a FROM t FETCH FIRST 18446744073709551616 ROWS ONLY", "the FETCH FIRST count 18446744073709551616 is out of range")
    _refuses("SELECT a FROM t LIMIT 1, 2", "unexpected trailing tokens after query")


def test_unsupported_clause_words_are_named() raises:
    _refuses("SELECT * FROM t QUALIFY a = 1", "the QUALIFY clause")
    _refuses("SELECT * FROM t WINDOW w AS (ORDER BY a)", "a named WINDOW clause")
    _refuses("SELECT * FROM t PIVOT (sum(a) FOR b IN (1))", "SQL not supported: PIVOT (reshaping")
    _refuses("SELECT * FROM t UNPIVOT (a FOR b IN (c))", "SQL not supported: UNPIVOT (reshaping")
    _refuses("SELECT * FROM t TABLESAMPLE 10", "TABLESAMPLE / USING SAMPLE")
    _refuses("SELECT * FROM t USING SAMPLE 10", "TABLESAMPLE / USING SAMPLE")
    _refuses("SELECT * FROM t WHERE s GLOB 'a*'", "the GLOB pattern operator")
    _refuses("SELECT * FROM t WHERE s NOT GLOB 'a*'", "the GLOB pattern operator")
    # `using` not followed by `sample` is no clause word: a trailing token.
    _refuses("SELECT * FROM t USING x", "unexpected trailing tokens after query")


def test_no_clause_keyword_is_taken_as_a_table_alias() raises:
    # Each word of the stop list, in the table-alias position: the parse
    # either raises or leaves the table unaliased; none becomes the alias.
    var words: List[String] = [
        "from", "where", "group", "order", "limit", "offset", "having", "as",
        "and", "or", "join", "inner", "cross", "on", "left", "right", "full",
        "outer", "natural", "using", "union", "intersect", "except", "semi",
        "anti", "asof", "positional", "fetch", "qualify", "window", "pivot",
        "unpivot", "tablesample", "isnull", "notnull",
    ]
    for i in range(len(words)):
        var got = String("<none>")
        try:
            var st = _parse("SELECT * FROM t " + words[i])
            got = st.query.from_tables[0].rel_alias
        except e:
            _ = e
            got = String("")
        assert_equal(got, "", words[i])
    # A word off the list is an alias.
    assert_equal(_parse("SELECT * FROM t x").query.from_tables[0].rel_alias, "x")


def test_unaliased_derived_tables_are_named_per_level() raises:
    var st = _parse("SELECT * FROM (SELECT 1 AS a), (SELECT 2 AS b)")
    assert_equal(st.query.from_tables[0].rel_alias, "unnamed_subquery")
    assert_equal(st.query.from_tables[0].name, "unnamed_subquery#0")
    assert_equal(st.query.from_tables[1].rel_alias, "unnamed_subquery2")
    assert_equal(st.query.from_tables[1].name, "unnamed_subquery2#1")
    assert_equal(Int(st.query.subqueries[1].kind), Int(SUBQ_DERIVED))
    assert_equal(st.query.subqueries[1].derived_alias, "unnamed_subquery2#1")
    # Only the unaliased ones count.
    var mixed = _parse("SELECT * FROM (SELECT 1 AS a) x, (SELECT 2 AS b)")
    assert_equal(mixed.query.from_tables[0].name, "x#0")
    assert_equal(mixed.query.from_tables[0].rel_alias, "x")
    assert_equal(mixed.query.from_tables[1].rel_alias, "unnamed_subquery")
    # The count restarts in a nested SELECT and resumes after it.
    var nested = _parse(
        "SELECT * FROM (SELECT * FROM (SELECT 1 AS a)), (SELECT 2 AS b)"
    )
    # subqueries[0] is the innermost body; [1] is the middle one, whose
    # own unaliased table took the first index.
    assert_equal(nested.query.subqueries[1].body.from_tables[0].rel_alias, "unnamed_subquery")
    assert_equal(nested.query.subqueries[1].body.from_tables[0].name, "unnamed_subquery#0")
    assert_equal(nested.query.from_tables[0].rel_alias, "unnamed_subquery")
    assert_equal(nested.query.from_tables[0].name, "unnamed_subquery#1")
    assert_equal(nested.query.from_tables[1].rel_alias, "unnamed_subquery2")
    _refuses("SELECT * FROM (SELECT 1 AS a), unnamed_subquery", "is named `unnamed_subquery`")
    _refuses("SELECT * FROM t AS Unnamed_Subquery, (SELECT 1 AS a)", "another relation in the same FROM clause")


def _dup(q: String) -> String:
    return (
        "SQL not supported: a derived table `(SELECT ...)` is named `" + q
        + "`, and another relation in the same FROM clause also answers to `"
        + q + "`, so a column qualified by that name is ambiguous. Give the"
        + " relations distinct aliases (an unaliased derived table is named"
        + " `unnamed_subquery`, `unnamed_subquery2`, ...)."
    )


def test_aliased_derived_tables_are_keyed_by_subquery_index() raises:
    # The alias is the qualifier; the relation key adds `#<index>`, so a
    # derived `t` in an IN body is not the top FROM's catalog t.
    var st = _parse("SELECT k FROM t WHERE k IN (SELECT k FROM (SELECT b AS k FROM mm) AS t)")
    assert_equal(st.query.from_tables[0].name, "t")
    assert_equal(st.query.from_tables[0].rel_alias, "")
    assert_equal(st.query.subqueries[1].body.from_tables[0].name, "t#0")
    assert_equal(st.query.subqueries[1].body.from_tables[0].rel_alias, "t")
    assert_equal(st.query.subqueries[0].derived_alias, "t#0")
    # A derived table's qualifier that another relation of the same FROM
    # answers to is refused: by that relation's name (`t`), by its alias
    # (`d`), or by another derived table's alias. (mutants: each arm of the
    # name-or-alias test dropped; the self-skip `j == i` dropped refuses
    # every derived table)
    assert_equal(_err("SELECT * FROM t, (SELECT 1 AS a) AS t"), _dup("t"))
    assert_equal(_err("SELECT * FROM (SELECT 1 AS a) AS d, u AS d"), _dup("d"))
    assert_equal(_err("SELECT * FROM (SELECT 1 AS a) AS d, (SELECT 2 AS b) AS D"), _dup("d"))
    assert_equal(_err("SELECT * FROM (SELECT 1 AS a), unnamed_subquery"), _dup("unnamed_subquery"))
    # Distinct qualifiers parse, and the check is for derived tables only: a
    # catalog table aliased like another table's name is not refused.
    # (mutant: the `#` test dropped, which refuses `kk AS mm` against mm)
    assert_equal(len(_parse("SELECT * FROM t, (SELECT 1 AS a) AS d").query.from_tables), 2)
    assert_equal(len(_parse("SELECT * FROM kk AS mm JOIN mm AS z ON mm.k = z.k").query.from_tables), 2)


def test_derived_table_column_list() raises:
    var st = _parse("SELECT x FROM (SELECT 1, 2) AS d (x, y)")
    assert_equal(st.query.from_tables[0].name, "d#0")
    assert_equal(st.query.from_tables[0].rel_alias, "d")
    assert_equal(len(st.query.subqueries[0].col_names), 2)
    assert_equal(st.query.subqueries[0].col_names[0], "x")
    assert_equal(st.query.subqueries[0].col_names[1], "y")
    assert_equal(st.query.subqueries[0].derived_alias, "d#0")
    # No column list after an unaliased one: the `(` is a trailing token.
    _refuses("SELECT * FROM (SELECT 1) (x)", "unexpected trailing tokens after query")
    _refuses("SELECT * FROM (SELECT 1) d (5)", "expected column name in a derived-table column list")
    _refuses("SELECT * FROM (SELECT 1) d (x", "')' to close the derived-table column list")
    _refuses("SELECT * FROM (1)", "expected SELECT in a derived table")
    _refuses("SELECT * FROM (SELECT 1", "')' to close the derived table")
    assert_equal(Int(st.query.select_items[0].expr.tag), Int(SX_COLUMN))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
