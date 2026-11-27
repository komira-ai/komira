# register_csv and register_json: a CSV or JSON file bound into a session as a
# table that SQL on the session reads by name.
#
# Rows: a registered CSV file answers a filter, a sort, a string comparison
# and an aggregate with the file's values, under its name in any case; each
# dialect argument is the one the file is read with (a `|` file has its three
# columns, a file with a header loses its first line to the names,
# all_varchar makes every column a string), and for each the registered
# table has the schema and answer of `read_csv` with the same options; a file
# registered with no header reads every line as a row under DuckDB's names,
# column0, column1, as `read_csv(..., header=false)` does; a registered JSON
# file answers the same way and equals `read_json`; a missing file and an
# empty file are refused by both with nothing registered; an empty name is
# refused as TABLE_NAME_EMPTY; a name the session already holds (from either
# call, from register_parquet, or in another case) is refused as
# TABLE_ALREADY_REGISTERED word for word, and the table first registered
# under it still answers with its own rows.
from std.testing import assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult

from so import (
    Session,
    register_csv,
    register_json,
    register_parquet,
    sql_result,
)

comptime PARQUET = "src/so/tests/fixtures/two_columns.parquet"
comptime PEOPLE = "id,name,score\n1,ann,10\n2,bob,20\n3,cy,30\n"
comptime EVENTS = '{"id":1,"v":"x"}\n{"id":2,"v":"y"}\n{"id":3,"v":"y"}\n'
comptime COMMA = UInt8(ord(","))


def _write(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def _ints(result: ArrowResult) raises -> List[Int64]:
    """The first column of every batch of `result`, as int64 values."""
    var out = List[Int64]()
    for b in range(len(result.batches)):
        var col = result.batches[b].column_at(0).as_primitive[DType.int64]()
        for i in range(result.batches[b].num_rows()):
            out.append(col.get(i))
    return out^


def _rows(result: ArrowResult) -> Int:
    var n = 0
    for b in range(len(result.batches)):
        n += result.batches[b].num_rows()
    return n


def _assert_same_answer(mut s: Session, registered: String, tvf: String) raises:
    """`select *` of the table `registered` has the column names, types and
    rows of `select *` from the table function call `tvf`."""
    var a = sql_result(s, String("select * from ") + registered)
    var b = sql_result(s, String("select * from ") + tvf)
    assert_equal(a.schema.num_columns(), b.schema.num_columns())
    for i in range(a.schema.num_columns()):
        var fa = a.schema.field_at_unchecked(i)
        var fb = b.schema.field_at_unchecked(i)
        assert_equal(fa.name, fb.name)
        assert_true(fa.arrow_type == fb.arrow_type, "column " + fa.name + " differs in type")
    assert_equal(_rows(a), _rows(b))


def _message_of_csv(mut s: Session, name: String, path: String) -> String:
    """The message `register_csv` raises, or empty when it registers."""
    try:
        register_csv(s, name, path, COMMA, True, False)
    except e:
        return String(e)
    return String()


def _message_of_json(mut s: Session, name: String, path: String) -> String:
    """The message `register_json` raises, or empty when it registers."""
    try:
        register_json(s, name, path)
    except e:
        return String(e)
    return String()


def test_registered_csv_answers_queries() raises:
    var s = Session()
    register_csv(s, String("People"), _write(String("people.csv"), String(PEOPLE)), COMMA, True, False)
    assert_true(s.engine.catalog.has("people"))
    var kept = sql_result(s, String("select id from PEOPLE where score >= 20 order by id"))
    assert_equal(kept.schema.field_name(0), String("id"))
    var ids = _ints(kept)
    assert_equal(len(ids), 2)
    assert_equal(ids[0], Int64(2))
    assert_equal(ids[1], Int64(3))
    var bob = _ints(sql_result(s, String("select id from people where name = 'bob'")))
    assert_equal(len(bob), 1)
    assert_equal(bob[0], Int64(2))
    var top = _ints(sql_result(s, String("select max(score) from people")))
    assert_equal(top[0], Int64(30))
    var names = sql_result(s, String("select name from people order by id"))
    assert_equal(names.batches[0].column_at(0).as_string().get(2), String("cy"))


def test_csv_dialect_is_the_one_read_csv_reads() raises:
    var s = Session()
    var people = _write(String("dialect_people.csv"), String(PEOPLE))
    var piped = _write(String("piped.csv"), String("id|name|score\n1|ann|10\n2|bob|20\n"))
    var bare = _write(String("bare.csv"), String("1,2\n3,4\n"))

    register_csv(s, String("piped"), piped, UInt8(ord("|")), True, False)
    var cols = sql_result(s, String("select * from piped"))
    assert_equal(cols.schema.num_columns(), 3)
    assert_equal(cols.schema.field_name(2), String("score"))
    _assert_same_answer(s, String("piped"), "read_csv('" + piped + "', delim='|')")

    # No header: every line is a row, and the columns are column0, column1
    # as DuckDB names them, the same as `read_csv(..., header=false)`.
    register_csv(s, String("bare"), bare, COMMA, False, False)
    assert_true(s.engine.catalog.has("bare"))
    var bare_cols = sql_result(s, String("select * from bare"))
    assert_equal(bare_cols.schema.num_columns(), 2)
    assert_equal(bare_cols.schema.field_name(0), String("column0"))
    assert_equal(bare_cols.schema.field_name(1), String("column1"))
    assert_equal(_ints(sql_result(s, String("select count(*) from bare")))[0], Int64(2))
    _assert_same_answer(s, String("bare"), "read_csv('" + bare + "', header=false)")
    # The same file with a header has one row.
    register_csv(s, String("headed"), bare, COMMA, True, False)
    assert_equal(_ints(sql_result(s, String("select count(*) from headed")))[0], Int64(1))

    register_csv(s, String("as_text"), people, COMMA, True, True)
    var text = sql_result(s, String("select * from as_text"))
    for i in range(text.schema.num_columns()):
        assert_true(
            text.schema.field_at_unchecked(i).arrow_type == ArrowType.STRING,
            "all_varchar left a column that is not a string",
        )
    assert_equal(text.batches[0].column_at(0).as_string().get(0), String("1"))
    _assert_same_answer(s, String("as_text"), "read_csv('" + people + "', all_varchar=true)")

    register_csv(s, String("typed"), people, COMMA, True, False)
    _assert_same_answer(s, String("typed"), "read_csv('" + people + "')")


def test_registered_json_answers_queries() raises:
    var s = Session()
    var path = _write(String("events.jsonl"), String(EVENTS))
    register_json(s, String("Events"), path)
    assert_true(s.engine.catalog.has("events"))
    var ys = _ints(sql_result(s, String("select id from EVENTS where v = 'y' order by id")))
    assert_equal(len(ys), 2)
    assert_equal(ys[0], Int64(2))
    assert_equal(ys[1], Int64(3))
    assert_equal(_ints(sql_result(s, String("select count(*) from events")))[0], Int64(3))
    _assert_same_answer(s, String("events"), "read_json('" + path + "')")


def test_unreadable_files_register_nothing() raises:
    var s = Session()
    var empty = _write(String("empty.txt"), String(""))
    var gone = test_tmpdir() + "/no_such_file.csv"
    assert_true(_message_of_csv(s, String("gone"), gone).byte_length() > 0)
    assert_true(_message_of_csv(s, String("empty"), empty).byte_length() > 0)
    assert_true(_message_of_json(s, String("gone_j"), gone).byte_length() > 0)
    assert_true(_message_of_json(s, String("empty_j"), empty).byte_length() > 0)
    for name in [String("gone"), String("empty"), String("gone_j"), String("empty_j")]:
        assert_false(s.engine.catalog.has(name), name + " was registered")


def test_empty_name_is_refused() raises:
    var s = Session()
    var people = _write(String("noname.csv"), String(PEOPLE))
    var events = _write(String("noname.jsonl"), String(EVENTS))
    var want = String("TABLE_NAME_EMPTY: a table name must not be empty")
    assert_equal(_message_of_csv(s, String(""), people), want)
    assert_equal(_message_of_json(s, String(""), events), want)
    assert_false(s.engine.catalog.has(""))


def test_taken_name_is_refused_and_keeps_its_table() raises:
    var s = Session()
    var people = _write(String("taken.csv"), String(PEOPLE))
    var events = _write(String("taken.jsonl"), String(EVENTS))
    var other = _write(String("other.csv"), String("id\n7\n"))
    register_csv(s, String("people"), people, COMMA, True, False)
    register_json(s, String("events"), events)
    register_parquet(s, String("two"), String(PARQUET))

    var taken = String("TABLE_ALREADY_REGISTERED: the session already has a table named '")
    assert_equal(_message_of_csv(s, String("people"), other), taken + "people'")
    assert_equal(_message_of_csv(s, String("PEOPLE"), other), taken + "PEOPLE'")
    assert_equal(_message_of_csv(s, String("events"), other), taken + "events'")
    assert_equal(_message_of_csv(s, String("two"), other), taken + "two'")
    assert_equal(_message_of_json(s, String("Events"), events), taken + "Events'")
    assert_equal(_message_of_json(s, String("people"), events), taken + "people'")

    # The first table under each name is the one a query reads.
    assert_equal(_ints(sql_result(s, String("select count(*) from people")))[0], Int64(3))
    assert_equal(_ints(sql_result(s, String("select count(*) from events")))[0], Int64(3))
    assert_equal(_ints(sql_result(s, String("select count(*) from two")))[0], Int64(0))


def main() raises:
    test_registered_csv_answers_queries()
    test_csv_dialect_is_the_one_read_csv_reads()
    test_registered_json_answers_queries()
    test_unreadable_files_register_nothing()
    test_empty_name_is_refused()
    test_taken_name_is_refused_and_keeps_its_table()
    print("OK")
