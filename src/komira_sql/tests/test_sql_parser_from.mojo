# =============================================================================
# sql_parser: FROM relations, joins, table functions and replacement scans
# =============================================================================
#
# What each test proves, and the defect (mutant) it would catch:
#   1. Every join spelling binds its kind: comma / CROSS / INNER / bare JOIN
#      are JK_CROSS with each ON folded into WHERE (ANDed with each other and
#      with WHERE); LEFT / RIGHT / FULL [OUTER] keep their ON; SEMI / ANTI
#      keep ON or USING; NATURAL is keyed at any kind. (catches: an OUTER
#      keyword not consumed; RIGHT and FULL swapped; an ON folded twice)
#   2. Every malformed or unserved join is refused by name: ASOF and
#      POSITIONAL (also after NATURAL), NATURAL CROSS, NATURAL with ON or
#      USING, SEMI / ANTI without a condition, an OUTER join without ON, and
#      the USING list forms. (catches: ASOF read as a table alias, the
#      9-rows-for-2 shape)
#   3. A table reference: schema-qualified, aliased with or without AS, a
#      table called `lateral`; LATERAL (...) refused. (catches: the alias
#      grab eating a structural keyword)
#   4. read_parquet / read_csv[_auto] / read_json[_auto] / read_ndjson /
#      read_avro bind their kind, path and alias (the function name when
#      unaliased); read_avro refuses any option. (catches: avro bound as JSON
#      through the default arm; an unaliased one left without a qualifier)
#   5. Every table-function option: recorded (all_varchar, header, delim),
#      accepted as neutral (quote, escape, auto_detect, parallel, compression,
#      format) or refused by name, per kind. (catches: a CSV dialect option
#      accepted on read_parquet and dropped)
#   6. `FROM '<path>'` picks the reader by extension, names the relation
#      after the file stem unless aliased, and refuses an unmapped
#      extension. (catches: the stem keeping its directory or extension)

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_sql.sql_token import tokenize
from komira_sql.sql_ast import (
    SqlStatement,
    JK_CROSS,
    JK_LEFT,
    JK_RIGHT,
    JK_FULL,
    JK_SEMI,
    JK_ANTI,
    SXOP_AND,
    SXOP_EQ,
    SXOP_GT,
    TVF_PARQUET,
    TVF_CSV,
    TVF_JSON,
    TVF_AVRO,
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


def _join_kind(sql: String) raises -> Int:
    var st = _parse(sql)
    return Int(st.query.joins[0].kind)


def _tvf(call: String) raises -> SqlStatement:
    return _parse("SELECT * FROM " + call)


def _csv_ok(opts: String) raises:
    _ = _tvf("read_csv('f.csv', " + opts + ")")


def _json_ok(opts: String) raises:
    _ = _tvf("read_json('f.json', " + opts + ")")


def test_inner_joins_fold_their_on_into_where() raises:
    var st = _parse(
        "SELECT * FROM a, b CROSS JOIN c INNER JOIN d ON a.k = d.k"
        " JOIN e ON a.k = e.k WHERE a.v > 1"
    )
    assert_equal(len(st.query.from_tables), 5)
    assert_equal(len(st.query.joins), 4)
    for i in range(4):
        assert_equal(Int(st.query.joins[i].kind), Int(JK_CROSS))
        assert_false(Bool(st.query.joins[i].on_pred))
    # WHERE = ((d-on AND e-on) AND a.v > 1)
    ref w = st.query.where_pred.value()
    assert_equal(Int(w.op), Int(SXOP_AND))
    assert_equal(Int(w._binary.value().right[].op), Int(SXOP_GT))
    ref ons = w._binary.value().left[]
    assert_equal(Int(ons.op), Int(SXOP_AND))
    assert_equal(Int(ons._binary.value().left[].op), Int(SXOP_EQ))
    assert_equal(ons._binary.value().left[]._binary.value().right[].qualifier, "d")
    assert_equal(ons._binary.value().right[]._binary.value().right[].qualifier, "e")
    # A bare JOIN with no ON is a cross product with nothing in WHERE.
    var bare = _parse("SELECT * FROM a JOIN b")
    assert_false(Bool(bare.query.where_pred))


def test_outer_semi_anti_and_natural_joins() raises:
    assert_equal(_join_kind("SELECT * FROM a LEFT OUTER JOIN b ON a.k = b.k"), Int(JK_LEFT))
    assert_equal(_join_kind("SELECT * FROM a RIGHT JOIN b ON a.k = b.k"), Int(JK_RIGHT))
    assert_equal(_join_kind("SELECT * FROM a RIGHT OUTER JOIN b ON a.k = b.k"), Int(JK_RIGHT))
    assert_equal(_join_kind("SELECT * FROM a FULL JOIN b ON a.k = b.k"), Int(JK_FULL))
    assert_equal(_join_kind("SELECT * FROM a FULL OUTER JOIN b ON a.k = b.k"), Int(JK_FULL))
    var full = _parse("SELECT * FROM a FULL JOIN b ON a.k = b.k")
    assert_true(Bool(full.query.joins[0].on_pred))
    var anti = _parse("SELECT * FROM a ANTI JOIN b ON a.k = b.k")
    assert_equal(Int(anti.query.joins[0].kind), Int(JK_ANTI))
    assert_true(Bool(anti.query.joins[0].on_pred))
    var semi_using = _parse("SELECT * FROM a SEMI JOIN b USING (k)")
    assert_equal(Int(semi_using.query.joins[0].kind), Int(JK_SEMI))
    assert_equal(semi_using.query.joins[0].using_cols[0], "k")
    var nat = _parse("SELECT * FROM a NATURAL JOIN b")
    assert_equal(Int(nat.query.joins[0].kind), Int(JK_CROSS))
    assert_true(nat.query.joins[0].natural)
    assert_true(nat.query.joins[0].is_keyed())
    assert_false(Bool(nat.query.where_pred))
    var nat_left = _parse("SELECT * FROM a NATURAL LEFT JOIN b")
    assert_equal(Int(nat_left.query.joins[0].kind), Int(JK_LEFT))
    assert_true(nat_left.query.joins[0].natural)
    var nat_anti = _parse("SELECT * FROM a NATURAL ANTI JOIN b")
    assert_equal(Int(nat_anti.query.joins[0].kind), Int(JK_ANTI))
    assert_true(nat_anti.query.joins[0].natural)
    var nat_inner = _parse("SELECT * FROM a NATURAL INNER JOIN b")
    assert_true(nat_inner.query.joins[0].natural)
    var left_using = _parse("SELECT * FROM a LEFT JOIN b USING (k)")
    assert_equal(Int(left_using.query.joins[0].kind), Int(JK_LEFT))
    assert_false(Bool(left_using.query.joins[0].on_pred))


def test_unserved_and_malformed_joins_refuse() raises:
    _refuses("SELECT * FROM a ASOF JOIN b ON a.t >= b.t", "ASOF JOIN at the SQL door")
    _refuses("SELECT * FROM a POSITIONAL JOIN b", "POSITIONAL JOIN")
    _refuses("SELECT * FROM a NATURAL ASOF JOIN b", "ASOF JOIN at the SQL door")
    _refuses("SELECT * FROM a NATURAL POSITIONAL JOIN b", "POSITIONAL JOIN")
    _refuses("SELECT * FROM a NATURAL CROSS JOIN b", "NATURAL CROSS JOIN is not a join kind")
    _refuses("SELECT * FROM a NATURAL JOIN b ON a.k = b.k", "NATURAL JOIN takes no ON condition")
    _refuses("SELECT * FROM a NATURAL JOIN b USING (k)", "NATURAL JOIN takes no USING list")
    _refuses("SELECT * FROM a SEMI JOIN b", "SEMI JOIN requires an ON condition or a USING (...) list — it keeps the left rows that have a match")
    _refuses("SELECT * FROM a ANTI JOIN b", "ANTI JOIN requires an ON condition or a USING (...) list — it keeps the left rows that have no match")
    _refuses("SELECT * FROM a LEFT JOIN b", "OUTER JOIN requires an ON condition")
    _refuses("SELECT * FROM a LEFT b ON a.k = b.k", "expected keyword 'join'")
    _refuses("SELECT * FROM a JOIN b USING ()", "expected an unqualified column name in USING (...)")
    _refuses("SELECT * FROM a JOIN b USING k", "'(' after USING")
    _refuses("SELECT * FROM a JOIN b USING (b.k)", "')' to close USING (...)")


def test_table_references() raises:
    var st = _parse("SELECT * FROM s.t AS x, u y, v, lateral")
    assert_equal(st.query.from_tables[0].name, "t")
    assert_equal(st.query.from_tables[0].rel_alias, "x")
    assert_equal(st.query.from_tables[1].rel_alias, "y")
    assert_equal(st.query.from_tables[2].rel_alias, "")
    assert_equal(st.query.from_tables[3].name, "lateral")
    assert_false(Bool(st.query.from_tables[0].tvf_path))
    _refuses("SELECT * FROM s.", "expected identifier after '.'")
    _refuses("SELECT * FROM 5", "expected table name in FROM")
    _refuses("SELECT * FROM t AS 5", "expected alias after AS")
    _refuses("SELECT * FROM lateral (SELECT 1)", "LATERAL (a subquery")


def test_table_functions_bind_kind_path_and_alias() raises:
    var names: List[String] = [
        "read_parquet", "read_csv", "read_csv_auto", "read_json",
        "read_json_auto", "read_ndjson", "read_avro",
    ]
    var kinds: List[Int] = [
        Int(TVF_PARQUET), Int(TVF_CSV), Int(TVF_CSV), Int(TVF_JSON),
        Int(TVF_JSON), Int(TVF_JSON), Int(TVF_AVRO),
    ]
    for i in range(len(names)):
        var st = _tvf(names[i] + "('dir/f.x') AS r")
        ref rel = st.query.from_tables[0]
        assert_equal(Int(rel.tvf_kind), kinds[i], names[i])
        assert_equal(rel.tvf_path.value(), "dir/f.x")
        assert_equal(rel.rel_alias, "r")
        assert_equal(rel.name, "")
        # Unaliased, it answers to the function name (DuckDB's alias for a
        # table function). (mutant: no default alias, which leaves "")
        var bare = _tvf(names[i] + "('dir/f.x')")
        assert_equal(bare.query.from_tables[0].rel_alias, names[i])
    # Without `(` the name is an ordinary table.
    var plain = _tvf("read_csv")
    assert_equal(plain.query.from_tables[0].name, "read_csv")
    _refuses("SELECT * FROM read_avro('f.avro', x = 1)", "read_avro('f.avro', ...) takes NO options")
    _refuses("SELECT * FROM read_parquet(5)", "read_parquet expects a string path")
    _refuses("SELECT * FROM read_csv('f.csv', header = true", "expected ')'")


def test_csv_options_are_recorded() raises:
    var st = _tvf("read_csv('f.csv', header = false, delim = '|', all_varchar = true)")
    ref o = st.query.from_tables[0].tvf_opts
    assert_false(o.has_header)
    assert_equal(Int(o.delimiter), ord("|"))
    assert_true(o.all_varchar)
    var d = _tvf("read_csv('f.csv')")
    assert_true(d.query.from_tables[0].tvf_opts.has_header)
    assert_equal(Int(d.query.from_tables[0].tvf_opts.delimiter), ord(","))
    assert_false(d.query.from_tables[0].tvf_opts.all_varchar)
    var s = _tvf("read_csv('f.csv', has_header = true, sep = ';', all_varchar = false)")
    assert_equal(Int(s.query.from_tables[0].tvf_opts.delimiter), ord(";"))
    var t = _tvf("read_csv('f.csv', delimiter = '\t')")
    assert_equal(Int(t.query.from_tables[0].tvf_opts.delimiter), 9)


def test_neutral_options_are_accepted() raises:
    _csv_ok("quote = '\"', escape = '\"'")
    _csv_ok("auto_detect = true, autodetect = true, parallel = false, parallel = true")
    var codecs: List[String] = ["auto", "none", "uncompressed", "GZIP", "gz", "zstd", "zst"]
    for i in range(len(codecs)):
        _csv_ok("compression = '" + codecs[i] + "'")
        _json_ok("compression = '" + codecs[i] + "'")
    _json_ok("auto_detect = true")
    _json_ok("format = 'newline_delimited'")
    _json_ok("format = 'ND'")
    _json_ok("format = 'auto'")


def test_options_refused_by_name_and_kind() raises:
    _refuses("SELECT * FROM read_csv('f', 5)", "expected an option name inside read_csv(...)")
    _refuses("SELECT * FROM read_csv('f', header)", "read_csv option 'header' must be written name=value")
    _refuses("SELECT * FROM read_json('f', all_varchar = true)", "'all_varchar' is a read_csv option")
    _refuses("SELECT * FROM read_parquet('f', header = false)", "read_parquet option 'header' is a read_csv option and means nothing here. A parquet file is SELF-DESCRIBING")
    _refuses("SELECT * FROM read_json('f', has_header = true)", "read_json option 'has_header' is a read_csv option and means nothing here. JSONL records are SELF-DELIMITING")
    _refuses("SELECT * FROM read_parquet('f', delim = '|')", "option 'delim' is a read_csv option")
    _refuses("SELECT * FROM read_json('f', sep = '|')", "option 'sep' is a read_csv option")
    _refuses("SELECT * FROM read_parquet('f', delimiter = '|')", "option 'delimiter' is a read_csv option")
    _refuses("SELECT * FROM read_json('f', quote = '\"')", "option 'quote' is a read_csv option")
    _refuses("SELECT * FROM read_parquet('f', escape = '\"')", "option 'escape' is a read_csv option")
    _refuses("SELECT * FROM read_parquet('f', auto_detect = true)", "option 'auto_detect' is a read_csv / read_json option")
    _refuses("SELECT * FROM read_json('f', parallel = true)", "option 'parallel' is a read_csv option")
    _refuses("SELECT * FROM read_parquet('f', compression = 'gzip')", "option 'compression' is a read_csv / read_json option")
    _refuses("SELECT * FROM read_csv('f', format = 'csv')", "'format' is a read_json option")
    _refuses("SELECT * FROM read_csv('f', header = maybe)", "read_csv option 'header' expects TRUE or FALSE")
    _refuses("SELECT * FROM read_csv('f', header = 1)", "read_csv option 'header' expects TRUE or FALSE")
    _refuses("SELECT * FROM read_csv('f', delim = '||')", "'delim'='||' — only a SINGLE-byte delimiter is supported")
    _refuses("SELECT * FROM read_csv('f', delim = 5)", "read_csv option 'delim' expects a quoted string")
    _refuses("SELECT * FROM read_csv('f', quote = '''')", "read_csv quote=''' — this reader is RFC-4180")
    _refuses("SELECT * FROM read_csv('f', escape = '\\')", "read_csv escape='\\' — this reader is RFC-4180")
    _refuses("SELECT * FROM read_csv('f', autodetect = false)", "auto_detect=false requires an explicit columns={...} list")
    _refuses("SELECT * FROM read_csv('f', compression = 'brotli')", "compression='brotli' — this reader derives the codec")
    _refuses("SELECT * FROM read_json('f', format = 'array')", "read_json format='array' — this reader is newline-delimited")
    _refuses("SELECT * FROM read_csv('f', skip = 1)", "read_csv option 'skip' is not implemented")


def test_replacement_scans_by_extension() raises:
    var pq = _parse("SELECT * FROM 'dir/sub/T1.parquet'")
    ref r = pq.query.from_tables[0]
    assert_equal(Int(r.tvf_kind), Int(TVF_PARQUET))
    assert_equal(r.tvf_path.value(), "dir/sub/T1.parquet")
    assert_equal(r.rel_alias, "t1")
    var csv = _parse("SELECT * FROM 'a.b.CSV' AS x")
    assert_equal(Int(csv.query.from_tables[0].tvf_kind), Int(TVF_CSV))
    assert_equal(csv.query.from_tables[0].rel_alias, "x")
    var stem = _parse("SELECT * FROM 'a.b.csv'")
    assert_equal(stem.query.from_tables[0].rel_alias, "a.b")
    var exts: List[String] = ["f.json", "f.jsonl", "f.ndjson"]
    for i in range(len(exts)):
        var st = _parse("SELECT * FROM '" + exts[i] + "'")
        assert_equal(Int(st.query.from_tables[0].tvf_kind), Int(TVF_JSON), exts[i])
        assert_equal(st.query.from_tables[0].rel_alias, "f")
    _refuses("SELECT * FROM 'f.tsv'", "a replacement scan of `'f.tsv'`")
    _refuses("SELECT * FROM 'f.csv.gz'", "a replacement scan of `'f.csv.gz'`")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
