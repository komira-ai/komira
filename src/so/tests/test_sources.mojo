# The source and render operations behind the C surface, on values.
#
# Rows: register_parquet adds a table (found by name without regard to case)
# whose schema is the footer's, and a missing file or a file that is not
# Parquet is refused with nothing registered; parquet_schema_bytes carries the
# footer's column names; csv_binding_bytes names the path and the CSV kind, and
# changes with each of delimiter, header and all_varchar; json_binding_bytes
# names the path and the JSON kind; a missing file is refused by both; a
# table registered on a session is what a query on the session's engine reads
# (count(*) of a three-row file is 3, a filter keeps 2 and 3), a glob registers
# every file it matches (count(*) over two such files is 6) and a glob that
# matches nothing is refused by name with nothing registered, a name
# never registered is refused at bind, and a refused registration leaves no
# table a query could read; a plan
# is rendered as the text of its scan (the binding's name, kind and path), and bytes that are not a plan are
# refused; sql_result answers a query over a registered table with its rows
# and schema, an answer of no rows as one batch of no rows with the schema,
# an answer that is still whole after its session is dropped, and a refusal
# as `<step>: <reason>` (parse, bind; a parse refusal also names the line and
# column where the text stopped) after which the session answers again;
# a refusal is also the session's last error with its step number and code (a
# syntax error is parse and SQL_SYNTAX_ERROR, an unknown table bind and
# SQL_BIND_ERROR, INTERSECT ALL parse and SQL_NOT_SUPPORTED), and a later
# success leaves no error once the caller clears it; a call of a function
# that is neither a built-in nor declared, and of a name the engine refuses to
# lower, is refused at bind (SQL_NOT_SUPPORTED) with a message that ends by
# saying SQL cannot call a Python function, by decision, and what to do
# instead, in place of the binder's advice to call `catalog.declare_udf`,
# which no caller of the C surface can reach.
from std.os import makedirs
from std.testing import assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from parquet_footers.parquet_files import PARQUET_GLOB_NO_MATCH
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)

from runtime_paths import test_tmpdir
from sdk_exec.engine_sql import STEP_BIND, run_sql
from sql.sql_fn_table import sql_scalar_fn_spec

from so import (
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_PARSE,
    Session,
    csv_binding_bytes,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_render_text,
    register_parquet,
    sql_result,
)

comptime PARQUET = "src/so/tests/fixtures/two_columns.parquet"
# A serialized plan: one scan of "/data/orders.orc" (the plan wire's frozen
# scan example).
comptime SCAN_PLAN_HEX = "080412a903124c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500022d8020af90112f60108c0c2d2f703120a6b6f6d6972612e6f72631a066f7264657273221b0a0a6861735f666f6f74657210051a00200129000000000000000022250a047061746810011a102f646174612f6f72646572732e6f72632000290000000000000000221d0a0c7374726970655f636f756e7410021a0020072900000000000000002a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a004004500030effdb6f50d38cef5b7f70f420a0803103f180120012801500258d285d8cc04600180010068007008780010011a4c0a200a0161100518052000280030003a00400450005a04756e6974620563656e74730a130a0162100518052001280030003a00400450000a130a0173100d18002001280030003a0040045000200030004000480050015800"


def _contains(haystack: List[UInt8], needle: String) -> Bool:
    var nb = needle.as_bytes()
    var n = len(nb)
    if n == 0:
        return True
    if len(haystack) < n:
        return False
    for i in range(len(haystack) - n + 1):
        var ok = True
        for j in range(n):
            if haystack[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _hex_value(c: UInt8) -> Int:
    if c >= UInt8(ord("0")) and c <= UInt8(ord("9")):
        return Int(c) - ord("0")
    return Int(c) - ord("a") + 10


def _from_hex(hex: String) -> List[UInt8]:
    var b = hex.as_bytes()
    var out = List[UInt8]()
    var i = 0
    while i + 1 < len(b):
        out.append(UInt8(_hex_value(b[i]) * 16 + _hex_value(b[i + 1])))
        i += 2
    return out^


def _write(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def test_register_parquet() raises:
    var s = Session()
    assert_false(s.engine.catalog.has("t"))
    register_parquet(s, String("Two"), String(PARQUET))
    assert_true(s.engine.catalog.has("two"))
    assert_true(s.engine.catalog.has("TWO"))
    assert_false(s.engine.catalog.has("other"))
    var schema = s.engine.catalog.schema_of("two")
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_at_unchecked(0).name, String("i64"))
    assert_equal(schema.field_at_unchecked(1).name, String("s"))


def test_register_parquet_refusals() raises:
    var s = Session()
    var raised = False
    try:
        register_parquet(s, String("gone"), String("/no/such/file.parquet"))
    except:
        raised = True
    assert_true(raised)
    assert_false(s.engine.catalog.has("gone"))
    var notpq = _write(String("not_parquet.parquet"), String("this is text"))
    raised = False
    try:
        register_parquet(s, String("text"), notpq)
    except:
        raised = True
    assert_true(raised)
    assert_false(s.engine.catalog.has("text"))


def _three_row_parquet(path: String) raises -> String:
    """A Parquet file at `path` of one INT64 column `k` holding 1, 2 and 3."""
    var arr = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        arr.set(i, Scalar[DType.int64](i + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var bytes = write_record_batch_to_parquet_bytes(rbb.build(sb.build()))
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path


def test_registered_table_runs_on_the_session_engine() raises:
    var s = Session()
    register_parquet(
        s, String("Three"), _three_row_parquet(test_tmpdir() + "/three_rows.parquet")
    )
    var counted = run_sql(s.engine, String("select count(*) as c from three"))
    assert_true(counted.ok(), "count(*) over a registered table was refused")
    assert_equal(len(counted.batches), 1)
    assert_equal(counted.batches[0].num_rows(), 1)
    assert_equal(counted.batches[0].schema.field_name(0), String("c"))
    assert_equal(
        counted.batches[0].column_at(0).as_primitive[DType.int64]().get(0),
        Int64(3),
    )
    var rows = run_sql(s.engine, String("select k from THREE where k > 1"))
    assert_true(rows.ok(), "a filtered select over a registered table was refused")
    assert_equal(len(rows.batches), 1)
    assert_equal(rows.batches[0].num_rows(), 2)
    var k = rows.batches[0].column_at(0).as_primitive[DType.int64]()
    assert_equal(k.get(0) + k.get(1), Int64(5))


def _count_of(mut s: Session, table: String) raises -> Int64:
    var out = run_sql(s.engine, String("select count(*) as c from ") + table)
    assert_true(out.ok(), "count(*) over " + table + " was refused")
    assert_equal(len(out.batches), 1)
    return out.batches[0].column_at(0).as_primitive[DType.int64]().get(0)


def test_glob_registers_every_matching_file() raises:
    var dir = test_tmpdir() + "/glob_two"
    makedirs(dir, exist_ok=True)
    _ = _three_row_parquet(dir + "/a.parquet")
    _ = _three_row_parquet(dir + "/b.parquet")
    var s = Session()
    register_parquet(s, String("both"), dir + "/*.parquet")
    assert_equal(_count_of(s, String("both")), Int64(6))
    register_parquet(s, String("one"), dir + "/a.parquet")
    assert_equal(_count_of(s, String("one")), Int64(3))


def test_glob_matching_nothing_is_refused() raises:
    var dir = test_tmpdir() + "/glob_none"
    makedirs(dir, exist_ok=True)
    var s = Session()
    var glob = dir + "/*.parquet"
    var message = String()
    try:
        register_parquet(s, String("none"), glob)
    except e:
        message = String(e)
    assert_equal(
        message,
        String(PARQUET_GLOB_NO_MATCH) + ": no file matches '" + glob + "'",
    )
    assert_false(s.engine.catalog.has("none"))


def test_unregistered_table_is_refused_at_bind() raises:
    var s = Session()
    var raised = False
    try:
        register_parquet(s, String("gone"), test_tmpdir() + "/absent.parquet")
    except:
        raised = True
    assert_true(raised, "a missing file was registered")
    for name in [String("gone"), String("other")]:
        var out = run_sql(s.engine, String("select count(*) from ") + name)
        assert_false(out.ok(), "a query named the unregistered table " + name)
        assert_equal(out.refusal.value().step, String(STEP_BIND))
        assert_true(
            name in out.refusal.value().reason,
            "the bind refusal does not name " + name,
        )


def test_parquet_schema_bytes() raises:
    var bytes = parquet_schema_bytes(String(PARQUET))
    assert_true(len(bytes) > 0)
    assert_true(_contains(bytes, String("i64")))
    var raised = False
    try:
        _ = parquet_schema_bytes(String("/no/such/file.parquet"))
    except:
        raised = True
    assert_true(raised)


def test_csv_binding() raises:
    var path = _write(String("t.csv"), String("a,b\n1,x\n2,y\n"))
    var base = csv_binding_bytes(path, UInt8(ord(",")), True, False)
    assert_true(len(base) > 0)
    assert_true(_contains(base, path))
    assert_true(_contains(base, String("komira.csv")))
    var again = csv_binding_bytes(path, UInt8(ord(",")), True, False)
    assert_true(again == base)
    # Each option changes what the cells mean, so each changes the bytes.
    assert_false(csv_binding_bytes(path, UInt8(ord(";")), True, False) == base)
    assert_false(csv_binding_bytes(path, UInt8(ord(",")), False, False) == base)
    assert_false(csv_binding_bytes(path, UInt8(ord(",")), True, True) == base)


def test_csv_binding_missing_file() raises:
    var raised = False
    try:
        _ = csv_binding_bytes(
            String("/no/such/file.csv"), UInt8(ord(",")), True, False
        )
    except:
        raised = True
    assert_true(raised)


def test_json_binding() raises:
    var path = _write(
        String("t.jsonl"), String('{"a":1,"b":"x"}\n{"a":2,"b":"y"}\n')
    )
    var bytes = json_binding_bytes(path)
    assert_true(len(bytes) > 0)
    assert_true(_contains(bytes, path))
    assert_true(_contains(bytes, String("komira.json")))
    var raised = False
    try:
        _ = json_binding_bytes(String("/no/such/file.jsonl"))
    except:
        raised = True
    assert_true(raised)


def test_plan_render() raises:
    var text = plan_render_text(_from_hex(String(SCAN_PLAN_HEX)))
    assert_true(text.startswith('Scan(path="orders"'))
    assert_true("komira.orc(orders" in text)
    assert_true("path=/data/orders.orc" in text)


def test_plan_render_refuses_garbage() raises:
    var raised = False
    var garbage = List[UInt8]()
    garbage.append(UInt8(0xFF))
    garbage.append(UInt8(0xFF))
    garbage.append(UInt8(0xFF))
    try:
        _ = plan_render_text(garbage^)
    except:
        raised = True
    assert_true(raised)


def _message_of(mut s: Session, sql: String) -> String:
    """The message `sql_result` raises for `sql`, or empty when it answers."""
    try:
        _ = sql_result(s, sql)
    except e:
        return String(e)
    return String()


def test_sql_result_answers_a_query_with_its_rows() raises:
    var s = Session()
    register_parquet(
        s, String("three"), _three_row_parquet(test_tmpdir() + "/sql_rows.parquet")
    )
    var result = sql_result(s, String("select k from three where k > 1 order by k"))
    assert_equal(result.schema.num_columns(), 1)
    assert_equal(result.schema.field_name(0), String("k"))
    assert_equal(len(result.batches), 1)
    assert_equal(result.batches[0].num_rows(), 2)
    var k = result.batches[0].column_at(0).as_primitive[DType.int64]()
    assert_equal(k.get(0), Int64(2))
    assert_equal(k.get(1), Int64(3))


def test_sql_result_of_no_rows_keeps_the_schema() raises:
    var s = Session()
    register_parquet(
        s, String("three"), _three_row_parquet(test_tmpdir() + "/sql_none.parquet")
    )
    var result = sql_result(s, String("select k from three where k > 9"))
    assert_equal(result.schema.num_columns(), 1)
    assert_equal(result.schema.field_name(0), String("k"))
    assert_equal(len(result.batches), 1)
    assert_equal(result.batches[0].num_rows(), 0)


def test_sql_result_outlives_its_session() raises:
    var s = Session()
    register_parquet(
        s, String("three"), _three_row_parquet(test_tmpdir() + "/sql_after.parquet")
    )
    var result = sql_result(s, String("select k from three order by k"))
    _ = s^
    assert_equal(result.batches[0].num_rows(), 3)
    var k = result.batches[0].column_at(0).as_primitive[DType.int64]()
    assert_equal(k.get(0) + k.get(1) + k.get(2), Int64(6))


def test_sql_result_refusal_names_its_step() raises:
    var s = Session()
    assert_equal(
        _message_of(s, String("selec 1")),
        "parse: SQL syntax error: expected keyword 'select' at line 1, column 1",
    )
    assert_equal(
        _message_of(s, String("select 1\nfrom (select 2) x group x")),
        "parse: SQL syntax error: expected keyword 'by' at line 2, column 25",
    )
    var bind = _message_of(s, String("select * from nosuch"))
    assert_true(bind.startswith("bind: "), "a bind refusal reads: " + bind)
    assert_true("nosuch" in bind, "the bind refusal does not name the table: " + bind)
    assert_false(" at line " in bind, "a bind refusal has no position: " + bind)
    # The session answers the next query.
    var result = sql_result(s, String("select 1 as n"))
    assert_equal(result.batches[0].num_rows(), 1)
    assert_equal(
        result.batches[0].column_at(0).as_primitive[DType.int32]().get(0), Int32(1)
    )


def test_sql_result_refusal_records_step_and_code() raises:
    var s = Session()
    var syntax = _message_of(s, String("selec 1"))
    assert_true(
        syntax.startswith("parse: SQL syntax error: "),
        "a parse refusal reads: " + syntax,
    )
    assert_equal(s.last_error(), syntax)
    assert_equal(s.last_error_step(), KOMIRA_STEP_PARSE)
    assert_equal(s.last_error_code(), String("SQL_SYNTAX_ERROR"))

    var bind = _message_of(s, String("select * from nosuch"))
    assert_equal(bind, String("bind: SQL bind error: unknown table 'nosuch'"))
    assert_equal(s.last_error(), bind)
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("SQL_BIND_ERROR"))

    var unsupported = _message_of(
        s, String("select 1 intersect all select 1")
    )
    assert_true(
        unsupported.startswith("parse: SQL not supported: INTERSECT ALL. "),
        "an unsupported construct reads: " + unsupported,
    )
    assert_equal(s.last_error_step(), KOMIRA_STEP_PARSE)
    assert_equal(s.last_error_code(), String("SQL_NOT_SUPPORTED"))


def test_sql_result_success_records_no_error() raises:
    var s = Session()
    _ = _message_of(s, String("selec 1"))
    assert_true(s.has_error())
    # A success itself records nothing: the caller (komira_sql_stream) clears
    # the previous error before the call, and the answer leaves none.
    s.clear_error()
    var result = sql_result(s, String("select 1 as n"))
    assert_equal(result.batches[0].num_rows(), 1)
    assert_false(s.has_error())
    assert_equal(s.last_error_step(), Int32(0))
    assert_equal(s.last_error_code(), String(""))


def test_sql_calling_an_unknown_function_says_sql_cannot_call_python() raises:
    var s = Session()
    register_parquet(
        s, String("three"), _three_row_parquet(test_tmpdir() + "/udf_refusal.parquet")
    )
    var unknown = _message_of(s, String("select score(k, k) as score from three"))
    assert_equal(
        unknown,
        String(
            "bind: SQL not supported: scalar function 'score'. It is not a"
            " built-in. SQL cannot call a Python function, by decision: write"
            " the computation with built-in SQL functions, or run the query"
            " and apply the function to its result in Python"
            " (`Result.to_pandas()`)."
        ),
    )
    assert_equal(s.last_error(), unknown)
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("SQL_NOT_SUPPORTED"))

    var refused = _message_of(s, String("select nextafter(k, 1.0) from three"))
    assert_equal(
        refused,
        "bind: " + sql_scalar_fn_spec(String("nextafter")).reason
        + " SQL cannot call a Python function, by decision: write the"
        " computation with built-in SQL functions, or run the query and apply"
        " the function to its result in Python (`Result.to_pandas()`).",
    )
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("SQL_NOT_SUPPORTED"))


def main() raises:
    test_register_parquet()
    test_register_parquet_refusals()
    test_registered_table_runs_on_the_session_engine()
    test_glob_registers_every_matching_file()
    test_glob_matching_nothing_is_refused()
    test_unregistered_table_is_refused_at_bind()
    test_parquet_schema_bytes()
    test_csv_binding()
    test_csv_binding_missing_file()
    test_json_binding()
    test_plan_render()
    test_plan_render_refuses_garbage()
    test_sql_result_answers_a_query_with_its_rows()
    test_sql_result_of_no_rows_keeps_the_schema()
    test_sql_result_outlives_its_session()
    test_sql_result_refusal_names_its_step()
    test_sql_result_refusal_records_step_and_code()
    test_sql_result_success_records_no_error()
    test_sql_calling_an_unknown_function_says_sql_cannot_call_python()
    print("OK")
