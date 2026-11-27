# =============================================================================
# sql.sql_tvf_files and the pattern arms of sql.sql_tvf_bind and
# sql.sql_catalog: a CSV or JSON Lines name that is a glob pattern.
# =============================================================================
#
# Every input file is written under $TEST_TMPDIR, in a folder of the test's
# own. What each test holds:
#   1. tvf_files of a name with no pattern character is that name, unlooked-up
#      (a missing file stays for the reader to refuse).
#   2. `*` matches within one folder, sorted byte-wise; a file whose name starts
#      with `.` and a file of another suffix are left out.
#   3. `?` matches exactly one character (`m?.csv` takes m1 and m2, not m10).
#   4. `**` matches no folder and any depth of folders, sorted byte-wise over
#      the whole path; `{a,b}` takes either name.
#   5. A pattern matching nothing raises `<CODE>: no file matches '<pattern>'`
#      word for word, with the code the caller names.
#   6. merge_csv_schema: equal types stay; BIGINT and DOUBLE make DOUBLE in
#      either order; BIGINT and VARCHAR, and DATE and BIGINT, make VARCHAR; a
#      column nullable in either file is nullable.
#   7. merge_csv_schema refuses another column count and another name at one
#      position, word for word.
#   8. merge_json_schema: the keys of both in first-seen order; NULL takes the
#      other type in either order; BIGINT and DOUBLE make DOUBLE; BIGINT and
#      VARCHAR are refused word for word.
#   9. tvf_relation_schema and tvf_relation_scan of a CSV pattern over three
#      files: the merged schema, and a UNION ALL of three CSV scans in sorted
#      order, each at the merged schema with the relation's dialect.
#  10. A CSV pattern matching one file is a plain scan, no union.
#  11. A JSON Lines pattern over two files: the union of keys, and a UNION ALL
#      of two JSON scans in sorted order.
#  12. A CSV and a JSON pattern matching nothing raise CSV_GLOB_NO_MATCH and
#      JSON_GLOB_NO_MATCH from both the schema and the scan.
#  13. SqlCatalog.add_sources: one source is a plain scan; two are a UNION ALL
#      whose second branch is the second source, kept by table_of; none is
#      refused.

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from libc.posix import _read_env
from scan_source.csv_source import CsvSource
from scan_source.source_variant import (
    SourceVariant,
    SOURCE_VARIANT_CSV,
    SOURCE_VARIANT_JSON,
)

from sql.sql_ast import FromRelation, TvfOptions, TVF_CSV, TVF_JSON
from sql.sql_catalog import SqlCatalog
from sql.sql_tvf_bind import tvf_relation_scan, tvf_relation_schema
from sql.sql_tvf_files import (
    CSV_GLOB_NO_MATCH,
    JSON_GLOB_NO_MATCH,
    merge_csv_schema,
    merge_json_schema,
    tvf_files,
)


# =============================================================================
# Helpers
# =============================================================================


def _dir(name: String) raises -> String:
    """A fresh folder `name` under the directory this execution may write."""
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set: the test has no scratch directory")
    var path = d + "/" + name
    makedirs(path, exist_ok=True)
    return path^


def _put(dir: String, name: String, text: String) raises -> String:
    var path = dir + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def _schema(
    names: List[String], types: List[ArrowType], nullable: Bool
) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], nullable))
    return sb.build()


def _two(a: String, ta: ArrowType, b: String, tb: ArrowType) -> Schema:
    var names: List[String] = [a, b]
    var types: List[ArrowType] = [ta, tb]
    return _schema(names, types, True)


def _one(name: String, t: ArrowType, nullable: Bool = True) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, t, nullable))
    return sb.build()


def _message_of_files(path: String, code: String) -> String:
    try:
        _ = tvf_files(path, code)
    except e:
        return String(e)
    return String()


def _message_of_csv_merge(a: Schema, b: Schema) -> String:
    try:
        _ = merge_csv_schema(a, "f1.csv", b, "f2.csv")
    except e:
        return String(e)
    return String()


def _message_of_json_merge(a: Schema, b: Schema) -> String:
    try:
        _ = merge_json_schema(a, "f1.jsonl", b, "f2.jsonl")
    except e:
        return String(e)
    return String()


def _rel(path: String, kind: UInt8) -> FromRelation:
    return FromRelation.tvf_of(path, kind, TvfOptions())


def _message_of_schema(rel: FromRelation) -> String:
    try:
        _ = tvf_relation_schema(rel)
    except e:
        return String(e)
    return String()


def _message_of_scan(rel: FromRelation) -> String:
    try:
        _ = tvf_relation_scan(rel)
    except e:
        return String(e)
    return String()


# =============================================================================
# tvf_files
# =============================================================================


def test_plain_name_is_itself() raises:
    var files = tvf_files("no/such/dir/f.csv", CSV_GLOB_NO_MATCH)
    assert_equal(len(files), 1)
    assert_equal(files[0], String("no/such/dir/f.csv"))


def test_star_matches_one_folder_sorted() raises:
    var d = _dir("pat_star")
    _ = _put(d, "b.csv", "x\n1\n")
    _ = _put(d, "a.csv", "x\n1\n")
    _ = _put(d, ".hidden.csv", "x\n1\n")
    _ = _put(d, "notes.txt", "x\n1\n")
    makedirs(d + "/sub", exist_ok=True)
    _ = _put(d + "/sub", "c.csv", "x\n1\n")
    var files = tvf_files(d + "/*.csv", CSV_GLOB_NO_MATCH)
    assert_equal(len(files), 2)
    assert_equal(files[0], d + "/a.csv")
    assert_equal(files[1], d + "/b.csv")


def test_question_mark_matches_one_character() raises:
    var d = _dir("pat_question")
    _ = _put(d, "m1.csv", "x\n1\n")
    _ = _put(d, "m2.csv", "x\n1\n")
    _ = _put(d, "m10.csv", "x\n1\n")
    var files = tvf_files(d + "/m?.csv", CSV_GLOB_NO_MATCH)
    assert_equal(len(files), 2)
    assert_equal(files[0], d + "/m1.csv")
    assert_equal(files[1], d + "/m2.csv")


def test_globstar_and_braces() raises:
    var d = _dir("pat_globstar")
    makedirs(d + "/2026/jan", exist_ok=True)
    _ = _put(d, "c.csv", "x\n1\n")
    _ = _put(d + "/2026", "b.csv", "x\n1\n")
    _ = _put(d + "/2026/jan", "a.csv", "x\n1\n")
    var files = tvf_files(d + "/**/*.csv", CSV_GLOB_NO_MATCH)
    assert_equal(len(files), 3)
    assert_equal(files[0], d + "/2026/b.csv")
    assert_equal(files[1], d + "/2026/jan/a.csv")
    assert_equal(files[2], d + "/c.csv")
    var either = tvf_files(d + "/{c,z}.csv", CSV_GLOB_NO_MATCH)
    assert_equal(len(either), 1)
    assert_equal(either[0], d + "/c.csv")


def test_no_match_is_named() raises:
    var d = _dir("pat_none")
    _ = _put(d, "a.csv", "x\n1\n")
    var pattern = d + "/none_*.csv"
    assert_equal(
        _message_of_files(pattern, CSV_GLOB_NO_MATCH),
        "CSV_GLOB_NO_MATCH: no file matches '" + pattern + "'",
    )
    assert_equal(
        _message_of_files(pattern, JSON_GLOB_NO_MATCH),
        "JSON_GLOB_NO_MATCH: no file matches '" + pattern + "'",
    )


# =============================================================================
# merge_csv_schema / merge_json_schema
# =============================================================================


def test_csv_merge_widens_types() raises:
    var same = merge_csv_schema(
        _one("a", ArrowType.INT64, False), "f1", _one("a", ArrowType.INT64, False), "f2"
    )
    assert_true(same.field_arrow_type(0) == ArrowType.INT64, "equal stays")
    assert_false(same.field_at_unchecked(0).nullable, "both NOT NULL stays")
    var up = merge_csv_schema(
        _one("a", ArrowType.INT64), "f1", _one("a", ArrowType.FLOAT64), "f2"
    )
    assert_true(up.field_arrow_type(0) == ArrowType.FLOAT64, "int then double")
    var down = merge_csv_schema(
        _one("a", ArrowType.FLOAT64), "f1", _one("a", ArrowType.INT64), "f2"
    )
    assert_true(down.field_arrow_type(0) == ArrowType.FLOAT64, "double then int")
    var text = merge_csv_schema(
        _one("a", ArrowType.INT64), "f1", _one("a", ArrowType.STRING), "f2"
    )
    assert_true(text.field_arrow_type(0) == ArrowType.STRING, "int then text")
    var date = merge_csv_schema(
        _one("a", ArrowType.DATE32), "f1", _one("a", ArrowType.INT64), "f2"
    )
    assert_true(date.field_arrow_type(0) == ArrowType.STRING, "date then int")
    var nullable = merge_csv_schema(
        _one("a", ArrowType.INT64, False), "f1", _one("a", ArrowType.INT64, True), "f2"
    )
    assert_true(nullable.field_at_unchecked(0).nullable, "nullable in one")
    assert_equal(nullable.field_name(0), String("a"))


def test_csv_merge_refuses_other_columns() raises:
    var two = _two("id", ArrowType.INT64, "amt", ArrowType.INT64)
    var renamed = _two("id", ArrowType.INT64, "name", ArrowType.STRING)
    assert_equal(
        _message_of_csv_merge(two, _one("id", ArrowType.INT64)),
        "CSV_FILES_SCHEMA_MISMATCH: 'f2.csv' differs from 'f1.csv': it has 1"
        " columns, the first file has 2",
    )
    assert_equal(
        _message_of_csv_merge(two, renamed),
        "CSV_FILES_SCHEMA_MISMATCH: 'f2.csv' differs from 'f1.csv': column 1"
        " is 'name', the first file has 'amt'",
    )


def test_json_merge_unions_keys() raises:
    var a_names: List[String] = [String("id"), String("v"), String("n")]
    var a_types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.STRING, ArrowType.NULL
    ]
    var a = _schema(a_names, a_types, True)
    var b_names: List[String] = [
        String("w"), String("id"), String("n"), String("v")
    ]
    var b_types: List[ArrowType] = [
        ArrowType.FLOAT64, ArrowType.FLOAT64, ArrowType.BOOL, ArrowType.NULL
    ]
    var b = _schema(b_names, b_types, True)
    var m = merge_json_schema(a, "f1", b, "f2")
    assert_equal(m.num_columns(), 4)
    assert_equal(m.field_name(0), String("id"))
    assert_true(m.field_arrow_type(0) == ArrowType.FLOAT64, "int then double")
    assert_equal(m.field_name(1), String("v"))
    assert_true(m.field_arrow_type(1) == ArrowType.STRING, "text then null")
    assert_equal(m.field_name(2), String("n"))
    assert_true(m.field_arrow_type(2) == ArrowType.BOOL, "null then bool")
    assert_equal(m.field_name(3), String("w"))
    assert_true(m.field_arrow_type(3) == ArrowType.FLOAT64, "a new key")
    var down = merge_json_schema(
        _one("x", ArrowType.FLOAT64), "f1", _one("x", ArrowType.INT64), "f2"
    )
    assert_true(down.field_arrow_type(0) == ArrowType.FLOAT64, "double then int")


def test_json_merge_refuses_two_types() raises:
    assert_equal(
        _message_of_json_merge(
            _one("id", ArrowType.INT64), _one("id", ArrowType.STRING)
        ),
        "JSON_FILES_SCHEMA_MISMATCH: column 'id' is "
        + String(ArrowType.STRING)
        + " in 'f2.jsonl' and "
        + String(ArrowType.INT64)
        + " in the files before it, from 'f1.jsonl'",
    )


# =============================================================================
# tvf_relation_schema / tvf_relation_scan over a pattern
# =============================================================================


def test_csv_pattern_is_a_union_of_scans_in_order() raises:
    var d = _dir("pat_csv_union")
    _ = _put(d, "s_b.csv", "id;amt\n3;1.5\n")
    _ = _put(d, "s_a.csv", "id;amt\n1;2\n2;3\n")
    _ = _put(d, "s_c.csv", "id;amt\n4;7\n")
    var opts = TvfOptions()
    opts.delimiter = UInt8(ord(";"))
    var rel = FromRelation.tvf_of(d + "/s_*.csv", TVF_CSV, opts^)
    var schema = tvf_relation_schema(rel)
    assert_equal(schema.num_columns(), 2)
    assert_true(schema.field_arrow_type(0) == ArrowType.INT64, "id")
    assert_true(schema.field_arrow_type(1) == ArrowType.FLOAT64, "amt widened")
    var plan = tvf_relation_scan(rel)
    assert_true(plan.is_union(), "three files are a union")
    ref kids = plan.union_data_ref().children
    assert_equal(len(kids), 3)
    var names: List[String] = [String("s_a.csv"), String("s_b.csv"), String("s_c.csv")]
    for i in range(3):
        ref kid = kids[i][]
        assert_true(kid.is_scan(), "every branch is a scan")
        ref source = kid.scan_data_ref().source
        assert_equal(Int(source.tag), Int(SOURCE_VARIANT_CSV))
        assert_equal(source.binding_ref().name, d + "/" + names[i])
        assert_equal(source.binding_ref().params.get_i64("delimiter", 0), Int64(ord(";")))
        assert_true(
            kid.output_schema.field_arrow_type(1) == ArrowType.FLOAT64,
            "every branch reads at the merged schema",
        )
    assert_true(plan.output_schema.field_arrow_type(1) == ArrowType.FLOAT64, "union")


def test_csv_pattern_of_one_file_is_a_scan() raises:
    var d = _dir("pat_csv_one")
    _ = _put(d, "only.csv", "id\n1\n")
    var plan = tvf_relation_scan(_rel(d + "/*.csv", TVF_CSV))
    assert_true(plan.is_scan(), "one file is a plain scan")
    assert_equal(plan.scan_data_ref().source.binding_ref().name, d + "/only.csv")


def test_json_pattern_is_a_union_of_scans() raises:
    var d = _dir("pat_json_union")
    _ = _put(d, "b.jsonl", '{"id": 2, "w": 2.5}\n')
    _ = _put(d, "a.jsonl", '{"id": 1, "v": "x"}\n')
    var rel = _rel(d + "/*.jsonl", TVF_JSON)
    var schema = tvf_relation_schema(rel)
    assert_equal(schema.num_columns(), 3)
    assert_equal(schema.field_name(0), String("id"))
    assert_equal(schema.field_name(1), String("v"))
    assert_equal(schema.field_name(2), String("w"))
    var plan = tvf_relation_scan(rel)
    assert_true(plan.is_union(), "two files are a union")
    ref kids = plan.union_data_ref().children
    assert_equal(len(kids), 2)
    ref first = kids[0][].scan_data_ref().source
    assert_equal(Int(first.tag), Int(SOURCE_VARIANT_JSON))
    assert_equal(first.binding_ref().name, d + "/a.jsonl")
    assert_equal(kids[1][].scan_data_ref().source.binding_ref().name, d + "/b.jsonl")
    assert_equal(kids[1][].output_schema.num_columns(), 3)


def test_pattern_matching_nothing_is_refused() raises:
    var d = _dir("pat_rel_none")
    var csv = d + "/*.csv"
    var json = d + "/*.jsonl"
    var csv_want = "CSV_GLOB_NO_MATCH: no file matches '" + csv + "'"
    var json_want = "JSON_GLOB_NO_MATCH: no file matches '" + json + "'"
    assert_equal(_message_of_schema(_rel(csv, TVF_CSV)), csv_want)
    assert_equal(_message_of_scan(_rel(csv, TVF_CSV)), csv_want)
    assert_equal(_message_of_schema(_rel(json, TVF_JSON)), json_want)
    assert_equal(_message_of_scan(_rel(json, TVF_JSON)), json_want)


# =============================================================================
# SqlCatalog.add_sources
# =============================================================================


def _csv(path: String) -> SourceVariant:
    return SourceVariant(CsvSource(String(path), _one("id", ArrowType.INT64)))


def test_catalog_add_sources() raises:
    var cat = SqlCatalog()
    var one = List[SourceVariant]()
    one.append(_csv("one.csv"))
    cat.add_sources("One", one^)
    assert_true(cat.build_scan("one").is_scan(), "one source is a scan")
    assert_equal(len(cat.table_of("one").more_sources), 0)

    var two = List[SourceVariant]()
    two.append(_csv("a.csv"))
    two.append(_csv("b.csv"))
    cat.add_sources("two", two^)
    var plan = cat.build_scan("TWO")
    assert_true(plan.is_union(), "two sources are a union")
    ref kids = plan.union_data_ref().children
    assert_equal(len(kids), 2)
    assert_equal(kids[0][].scan_data_ref().source.binding_ref().name, String("a.csv"))
    assert_equal(kids[1][].scan_data_ref().source.binding_ref().name, String("b.csv"))
    var t = cat.table_of("two")
    assert_equal(len(t.more_sources), 1)
    assert_equal(t.more_sources[0].binding_ref().name, String("b.csv"))
    assert_equal(cat.schema_of("two").field_name(0), String("id"))

    var raised = String()
    try:
        cat.add_sources("none", List[SourceVariant]())
    except e:
        raised = String(e)
    assert_equal(raised, "SqlCatalog.add_sources: table 'none' has no source")
    assert_false(cat.has("none"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
