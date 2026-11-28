# A CSV or JSON Lines glob pattern read as one table, through register_csv,
# register_json, SQL read_csv / read_json and FROM '<pattern>'.
#
# Every file is written in a folder of the test's own under the test's scratch
# directory. Rows:
#   1. A CSV pattern reads every matching file as one table,
#      through register_csv, read_csv and FROM '<pattern>'; a file of another
#      name or suffix is not read.
#   2. `**` reads the files of the folder and of every folder below it, sorted
#      by their whole path; `?` reads a name with exactly one character there.
#   3. The files' types merge: BIGINT in one file and DOUBLE in another read
#      as DOUBLE, BIGINT and text read as VARCHAR, every value kept; with
#      all_varchar every column of every file is VARCHAR.
#   4. Files whose columns differ are refused by name, CSV_FILES_SCHEMA_MISMATCH
#      with the file and the column, by register_csv and by read_csv, and
#      nothing is registered.
#   5. A pattern matching nothing is refused by name, CSV_GLOB_NO_MATCH or
#      JSON_GLOB_NO_MATCH naming the pattern, by register_* and in SQL, and
#      nothing is registered.
#   6. A JSON Lines pattern reads every file as one table through register_json,
#      read_json and FROM '<pattern>': the keys of all files, a key a file
#      lacks NULL in its rows.
#   7. JSON Lines files giving a key two types no type holds are refused by
#      name, JSON_FILES_SCHEMA_MISMATCH.
#   8. What is not built is refused by name: a list of files `read_csv([...])`
#      names the pattern form; `filename=true` and `union_by_name=true` are
#      options refused by name.
from std.os import makedirs
from std.testing import assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult

from so import Session, register_csv, register_json, sql_result

comptime COMMA = UInt8(ord(","))


def _dir(name: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    makedirs(path, exist_ok=True)
    return path^


def _put(dir: String, name: String, text: String) raises:
    with open(dir + "/" + name, "w") as f:
        f.write(text)


def _ints(result: ArrowResult) raises -> List[Int64]:
    """The first column of every batch of `result`, in order, as int64."""
    var out = List[Int64]()
    for b in range(len(result.batches)):
        var col = result.batches[b].column_at(0).as_primitive[DType.int64]()
        for i in range(result.batches[b].num_rows()):
            out.append(col.get(i))
    return out^


def _assert_ints(result: ArrowResult, want: List[Int64], what: String) raises:
    var got = _ints(result)
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _message_of_sql(mut s: Session, sql: String) -> String:
    try:
        _ = sql_result(s, sql)
    except e:
        return String(e)
    return String()


def _message_of_csv(mut s: Session, name: String, path: String) -> String:
    try:
        register_csv(s, name, path, COMMA, True, False)
    except e:
        return String(e)
    return String()


def _message_of_json(mut s: Session, name: String, path: String) -> String:
    try:
        register_json(s, name, path)
    except e:
        return String(e)
    return String()


def test_csv_pattern_reads_every_file_in_order() raises:
    var d = _dir("pattern_sales")
    _put(d, "sales_feb.csv", "id,amt\n3,30\n")
    _put(d, "sales_apr.csv", "id,amt\n1,10\n2,20\n")
    _put(d, "sales_mar.csv", "id,amt\n4,40\n5,50\n")
    _put(d, "notes.csv", "other\nx\n")
    _put(d, "sales_jun.txt", "id,amt\n8,80\n")
    var pattern = d + "/sales_*.csv"
    var want: List[Int64] = [1, 2, 3, 4, 5]
    var s = Session()
    register_csv(s, String("sales"), pattern, COMMA, True, False)
    _assert_ints(
        sql_result(s, String("select id from sales order by id")), want, "register_csv"
    )
    _assert_ints(
        sql_result(s, "select id from read_csv('" + pattern + "') order by id"),
        want,
        "read_csv",
    )
    _assert_ints(
        sql_result(s, "select id from '" + pattern + "' order by id"), want, "FROM"
    )
    var counted = sql_result(s, String("select count(*) from sales"))
    assert_equal(_ints(counted)[0], Int64(5))


def test_globstar_and_question_mark() raises:
    var d = _dir("pattern_deep")
    makedirs(d + "/2026/jan", exist_ok=True)
    _put(d, "c.csv", "id\n3\n")
    _put(d + "/2026", "b.csv", "id\n1\n")
    _put(d + "/2026/jan", "a.csv", "id\n2\n")
    var s = Session()
    var deep: List[Int64] = [1, 2, 3]
    _assert_ints(
        sql_result(s, "select id from read_csv('" + d + "/**/*.csv') order by id"),
        deep,
        "**",
    )
    var m = _dir("pattern_months")
    _put(m, "m1.csv", "id\n1\n")
    _put(m, "m2.csv", "id\n2\n")
    _put(m, "m10.csv", "id\n10\n")
    register_csv(s, String("months"), m + "/m?.csv", COMMA, True, False)
    var one_char: List[Int64] = [1, 2]
    _assert_ints(
        sql_result(s, String("select id from months order by id")), one_char, "?"
    )


def test_csv_types_merge_across_files() raises:
    var d = _dir("pattern_widen")
    _put(d, "a.csv", "id,amt,tag\n1,2,7\n")
    _put(d, "b.csv", "id,amt,tag\n2,0.5,x\n")
    var s = Session()
    register_csv(s, String("w"), d + "/*.csv", COMMA, True, False)
    var all = sql_result(s, String("select amt, tag from w order by id"))
    assert_true(all.schema.field_arrow_type(0) == ArrowType.FLOAT64, "amt")
    assert_true(all.schema.field_arrow_type(1) == ArrowType.STRING, "tag")
    var amt = all.batches[0].column_at(0).as_primitive[DType.float64]()
    assert_equal(amt.get(0), Float64(2.0))
    assert_equal(amt.get(1), Float64(0.5))
    var tag = all.batches[0].column_at(1).as_string()
    assert_equal(tag.get(0), String("7"))
    assert_equal(tag.get(1), String("x"))
    register_csv(s, String("v"), d + "/*.csv", COMMA, True, True)
    var text = sql_result(s, String("select id, amt from v order by id"))
    assert_true(text.schema.field_arrow_type(0) == ArrowType.STRING, "id")
    assert_true(text.schema.field_arrow_type(1) == ArrowType.STRING, "amt")
    assert_equal(text.batches[0].column_at(1).as_string().get(1), String("0.5"))


def test_csv_files_with_other_columns_are_refused() raises:
    var d = _dir("pattern_mismatch")
    _put(d, "a.csv", "id,amt\n1,2\n")
    _put(d, "b.csv", "id,name\n2,x\n")
    var pattern = d + "/*.csv"
    var want = (
        "CSV_FILES_SCHEMA_MISMATCH: '"
        + d
        + "/b.csv' differs from '"
        + d
        + "/a.csv': column 1 is 'name', the first file has 'amt'"
    )
    var s = Session()
    assert_equal(_message_of_csv(s, String("m"), pattern), want)
    assert_false(s.engine.catalog.has("m"))
    var sql = _message_of_sql(s, "select * from read_csv('" + pattern + "')")
    assert_true(want in sql, sql)


def test_pattern_matching_nothing_is_refused() raises:
    var d = _dir("pattern_nothing")
    _put(d, "a.csv", "id\n1\n")
    var csv = d + "/none_*.csv"
    var json = d + "/*.jsonl"
    var s = Session()
    var csv_want = "CSV_GLOB_NO_MATCH: no file matches '" + csv + "'"
    var json_want = "JSON_GLOB_NO_MATCH: no file matches '" + json + "'"
    assert_equal(_message_of_csv(s, String("c"), csv), csv_want)
    assert_equal(_message_of_json(s, String("j"), json), json_want)
    assert_false(s.engine.catalog.has("c"))
    assert_false(s.engine.catalog.has("j"))
    var in_sql = _message_of_sql(s, "select * from read_csv('" + csv + "')")
    assert_true(csv_want in in_sql, in_sql)
    var in_from = _message_of_sql(s, "select * from '" + json + "'")
    assert_true(json_want in in_from, in_from)


def test_json_pattern_reads_every_file() raises:
    var d = _dir("pattern_events")
    _put(d, "e2.jsonl", '{"id":3,"w":2.5}\n')
    _put(d, "e1.jsonl", '{"id":1,"v":"x"}\n{"id":2,"v":"y"}\n')
    _put(d, "skip.json", '{"other":1}\n')
    var pattern = d + "/e*.jsonl"
    var s = Session()
    register_json(s, String("events"), pattern)
    var want: List[Int64] = [1, 2, 3]
    _assert_ints(
        sql_result(s, String("select id from events order by id")), want, "register_json"
    )
    _assert_ints(
        sql_result(s, "select id from read_json('" + pattern + "') order by id"),
        want,
        "read_json",
    )
    _assert_ints(
        sql_result(s, "select id from '" + pattern + "' order by id"), want, "FROM"
    )
    var rows = sql_result(s, String("select v, w from events order by id"))
    assert_equal(rows.schema.num_columns(), 2)
    ref v = rows.batches[0].column_at(0)
    ref w = rows.batches[0].column_at(1)
    assert_equal(v.as_string().get(1), String("y"))
    assert_true(v.is_null_at(2), "a key the second file lacks is NULL")
    assert_true(w.is_null_at(0), "a key the first file lacks is NULL")
    assert_equal(w.as_primitive[DType.float64]().get(2), Float64(2.5))


def test_json_files_with_two_types_are_refused() raises:
    var d = _dir("pattern_json_mismatch")
    _put(d, "a.jsonl", '{"id":1}\n')
    _put(d, "b.jsonl", '{"id":"one"}\n')
    var s = Session()
    var got = _message_of_json(s, String("j"), d + "/*.jsonl")
    assert_equal(
        got,
        "JSON_FILES_SCHEMA_MISMATCH: column 'id' is "
        + String(ArrowType.STRING)
        + " in '"
        + d
        + "/b.jsonl' and "
        + String(ArrowType.INT64)
        + " in the files before it, from '"
        + d
        + "/a.jsonl'",
    )
    assert_false(s.engine.catalog.has("j"))


def test_what_is_not_built_is_refused_by_name() raises:
    var d = _dir("pattern_refused")
    _put(d, "a.csv", "id\n1\n")
    var s = Session()
    var listed = _message_of_sql(
        s, "select * from read_csv(['" + d + "/a.csv'])"
    )
    assert_true(
        "SQL not supported: a list `[...]`, such as the list of files of"
        " `read_csv(['a.csv', 'b.csv'])`, is not implemented; name the"
        " files with a glob pattern, as `read_csv('dir/*.csv')`"
        in listed,
        listed,
    )
    var named = _message_of_sql(
        s, "select * from read_csv('" + d + "/*.csv', filename=true)"
    )
    assert_true("'filename' is not implemented" in named, named)
    var by_name = _message_of_sql(
        s, "select * from read_csv('" + d + "/*.csv', union_by_name=true)"
    )
    assert_true("'union_by_name' is not implemented" in by_name, by_name)


def main() raises:
    test_csv_pattern_reads_every_file_in_order()
    test_globstar_and_question_mark()
    test_csv_types_merge_across_files()
    test_csv_files_with_other_columns_are_refused()
    test_pattern_matching_nothing_is_refused()
    test_json_pattern_reads_every_file()
    test_json_files_with_two_types_are_refused()
    test_what_is_not_built_is_refused_by_name()
    print("OK")
