"""`Session.register(name, obj)`: a frame or Arrow data in memory registered
as a table, and SQL over it held to DuckDB's answer to the same SQL over the
same rows, which DuckDB reads through its own `register` (`register_duckdb_test`,
CPython 3.13, the real libkomira).

- a `pyarrow.Table` and a `RecordBatch`, a komira `DataFrame` (its plan run
  on its own session, or on the session it is registered on) and a
  `komira.pl.LazyFrame`, each registered and asked a filter, a group-by
  aggregate (count, count of a column, sum, min, max, avg), a NULL test and a
  join with a second registered table: every answer equals DuckDB's;
- the rows hold a NULL in every column, which every answer keeps as NULL; a
  table of no row keeps its column names and types and counts 0 rows;
- a `pyarrow.RecordBatchReader` is read once, when it is registered: two
  queries on its name answer the same rows, and giving the reader to
  `register` again raises `KomiraError` with the exact message; a `Result`
  registers, and registering it again raises the `Result`'s own read-once
  error;
- registering a name again replaces its table, as DuckDB's `register`
  replaces the view of the name: a second table under the same name, a name
  in another case, and a name `register_csv` took first;
- a column type the engine does not hold is refused by name, and the name
  keeps the table it had: a list column (`UnsupportedOperation`,
  `TABLE_TYPE_UNSUPPORTED`, naming the column), the null type, a large list
  and a run-end encoded column (`BindError`, `UnsupportedArrowCABIType`); a stream that fails while it is
  read is refused with the producer's message, and registers nothing;
- every flat type reads back as the values it was given, NULL included, and
  as its own type, but for the large and view strings and binaries, which
  read back as `string` and `binary` (bool, every int and uint width, float32
  and float64, string, binary, date32 and date64, timestamps of every unit
  and with a zone, decimal128 and decimal256, time32, time64, duration and a
  dictionary of strings, which reads back decoded);
- a reader of several batches cut from one table, whose columns start past
  the start of their buffers, answers equal to DuckDB;
- a frame whose plan the engine refuses raises the engine's error, and the
  name keeps its table;
- argument errors: a name that is not a non-empty `str`, a name with a NUL
  byte, an object with neither a plan nor `__arrow_c_stream__`, an
  `__arrow_c_stream__` that returns no capsule, and a closed session, each
  raise before anything is read, and a reader refused so is not taken.

The test is of the `duckdb/` family (python/tests/BUCK): CPython 3.13 alone,
the minor with a pinned DuckDB, on the real libkomira, with the generated plan
modules, duckdb, protobuf and pyarrow.

    test_register_duckdb.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import datetime
import decimal
import math
import os
import sys
import tempfile

import komira
import komira.pl as kpl
from komira import BindError, KomiraError, UnsupportedOperation, _native

# ---- the rows ----------------------------------------------------------------


def sales_columns():
    """Eight rows with a NULL in every column, ties in `region` and a NULL
    region, which make a group of its own."""
    return {
        "id": [1, 2, 3, 4, 5, 6, 7, 8],
        "region": ["east", "west", "east", None, "north", "west", "east", "north"],
        "amount": [120, 80, None, 200, 45, 150, 0, -5],
        "price": [1.5, None, 2.25, 0.5, -1.0, 3.0, 2.25, 0.0],
        "ok": [True, False, None, True, True, False, True, None],
        "day": [datetime.date(2026, 9, d) for d in (1, 2, 3)] + [None] + [datetime.date(2026, 10, d) for d in (1, 2, 3, 4)],
    }


def sales_table():
    import pyarrow as pa

    c = sales_columns()
    return pa.table(
        {
            "id": pa.array(c["id"], pa.int64()),
            "region": pa.array(c["region"], pa.string()),
            "amount": pa.array(c["amount"], pa.int64()),
            "price": pa.array(c["price"], pa.float64()),
            "ok": pa.array(c["ok"], pa.bool_()),
            "day": pa.array(c["day"], pa.date32()),
        }
    )


def targets_table():
    import pyarrow as pa

    return pa.table({"region": ["east", "west", "north"], "target": pa.array([100, 100, 150], pa.int64())})


# The same SQL, run by komira over the registered `t` and `targets` and by
# DuckDB over the same rows; every query orders its rows completely.
QUERIES = (
    ("every row", "SELECT * FROM t ORDER BY id"),
    ("a filter", "SELECT id, region, amount FROM t WHERE amount > 50 ORDER BY id"),
    ("a filter on a bool", "SELECT id FROM t WHERE ok ORDER BY id"),
    ("a NULL test", "SELECT id FROM t WHERE amount IS NULL OR region IS NULL ORDER BY id"),
    (
        "a group-by aggregate",
        "SELECT region, count(*) AS n, count(amount) AS counted, sum(amount) AS total,"
        " min(price) AS lo, max(price) AS hi, avg(price) AS mean FROM t GROUP BY region ORDER BY region NULLS LAST",
    ),
    (
        "an aggregate of the whole table",
        "SELECT count(*) AS n, sum(amount) AS total, max(day) AS last_day FROM t",
    ),
    (
        "a join with a second registered table",
        "SELECT t.id AS id, t.amount AS amount, g.target AS target FROM t JOIN targets AS g"
        " ON t.region = g.region WHERE t.amount > g.target ORDER BY t.id",
    ),
)


# ---- the comparison ------------------------------------------------------------


def answer_of(table):
    """Names, Arrow type names (a large string read as a string, as DuckDB's
    VARCHAR is) and rows of `table`."""
    names = list(table.column_names)
    types = ["string" if str(t) == "large_string" else str(t) for t in table.schema.types]
    return names, types, [tuple(r[n] for n in names) for r in table.to_pylist()]


def cell_equal(a, b):
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, float) or isinstance(b, float):
        return isinstance(a, float) and isinstance(b, float) and math.isclose(a, b, rel_tol=1e-12, abs_tol=0.0)
    return type(a) is type(b) and a == b


def difference(got, want):
    """None when the two answers are equal, else the first difference."""
    if got[0] != want[0]:
        return "column names {} != {}".format(got[0], want[0])
    if got[1] != want[1]:
        return "column types {} != {}".format(got[1], want[1])
    if len(got[2]) != len(want[2]):
        return "{} rows, expected {}".format(len(got[2]), len(want[2]))
    for i, (g, w) in enumerate(zip(got[2], want[2])):
        if len(g) != len(w) or not all(cell_equal(x, y) for x, y in zip(g, w)):
            return "row {} is {}, expected {}".format(i, g, w)
    return None


def komira_answer(session, sql):
    return answer_of(session.sql(sql).to_arrow())


def duckdb_answer(con, sql):
    """DuckDB's answer. Its integer sum, a HUGEINT, reaches Arrow as
    decimal128(38, 0), the type komira's sum of an int64 answers."""
    cursor = con.execute(sql)
    fetch = getattr(cursor, "to_arrow_table", None) or getattr(cursor, "fetch_arrow_table", None)
    table = fetch() if fetch is not None else cursor.arrow()
    if hasattr(table, "read_all"):
        table = table.read_all()
    return answer_of(table)


def duckdb_with(tables):
    """A DuckDB connection with each pyarrow table of `tables` registered
    under its name, through DuckDB's own `register`."""
    import duckdb

    con = duckdb.connect()
    for name, table in tables.items():
        con.register(name, table)
    return con


def assert_queries_equal_duckdb(session, what):
    con = duckdb_with({"t": sales_table(), "targets": targets_table()})
    for name, sql in QUERIES:
        found = difference(komira_answer(session, sql), duckdb_answer(con, sql))
        assert found is None, "{}, {}: {}\n{}".format(what, name, found, sql)


def refused(call, cls, message):
    """The error `call` raises, which must be of class `cls` exactly and say
    `message` exactly."""
    try:
        call()
    except KomiraError as e:
        assert type(e) is cls and str(e) == message, (type(e).__name__, str(e), cls.__name__, message)
        return e
    raise AssertionError("no {} was raised: {}".format(cls.__name__, message))


def write_sales(work):
    import pyarrow.parquet as pq

    path = os.path.join(work, "sales.parquet")
    pq.write_table(sales_table(), path)
    return path


# ---- registered Arrow data ---------------------------------------------------------


def test_a_registered_pyarrow_table_answers_equal_to_duckdb(work):
    with komira.Session() as s:
        s.register("t", sales_table())
        s.register("targets", targets_table())
        assert_queries_equal_duckdb(s, "pyarrow.Table")


def test_a_registered_record_batch_answers_equal_to_duckdb(work):
    with komira.Session() as s:
        s.register("t", sales_table().combine_chunks().to_batches()[0])
        s.register("targets", targets_table())
        assert_queries_equal_duckdb(s, "pyarrow.RecordBatch")


def test_a_reader_of_several_batches_answers_equal_to_duckdb(work):
    import pyarrow as pa

    table = sales_table()
    reader = pa.RecordBatchReader.from_batches(table.schema, table.to_batches(max_chunksize=3))
    with komira.Session() as s:
        s.register("t", reader)
        s.register("targets", targets_table())
        assert_queries_equal_duckdb(s, "pyarrow.RecordBatchReader")


def test_nulls_survive_in_every_column(work):
    with komira.Session() as s:
        s.register("t", sales_table())
        got = s.sql("SELECT * FROM t ORDER BY id").to_arrow()
    assert got.to_pylist() == sales_table().to_pylist(), got.to_pylist()
    assert [got.column(n).null_count for n in got.column_names] == [0, 1, 1, 1, 2, 1], got


def test_a_table_of_no_row_keeps_its_schema(work):
    with komira.Session() as s:
        s.register("t", sales_table().slice(0, 0))
        got = s.sql("SELECT * FROM t").to_arrow()
        assert got.num_rows == 0 and got.schema == sales_table().schema, got.schema
        count = s.sql("SELECT count(*) AS n FROM t").to_arrow().to_pylist()
    assert count == [{"n": 0}], count


# ---- registered frames ---------------------------------------------------------------


def test_a_registered_komira_frame_answers_equal_to_duckdb(work):
    path = write_sales(work)
    with komira.Session() as s:
        frame = komira.read_parquet(path, session=s)
        s.register("t", frame)
        s.register("targets", targets_table())
        assert_queries_equal_duckdb(s, "komira.DataFrame on its own session")


def test_a_frame_of_another_session_registers_its_rows(work):
    path = write_sales(work)
    with komira.Session() as other, komira.Session() as s:
        s.register("t", komira.read_parquet(path, session=other))
        s.register("targets", targets_table())
        assert_queries_equal_duckdb(s, "komira.DataFrame of another session")


def test_a_filtered_frame_registers_the_rows_its_plan_answers(work):
    path = write_sales(work)
    sql = "SELECT id, amount FROM big ORDER BY id"
    with komira.Session() as s:
        frame = komira.read_parquet(path, session=s)
        s.register("big", frame[frame["amount"] > 100])
        got = komira_answer(s, sql)
    con = duckdb_with({})
    con.execute("CREATE VIEW big AS SELECT * FROM read_parquet('{}') WHERE amount > 100".format(path))
    found = difference(got, duckdb_answer(con, sql))
    assert found is None, found


def test_a_registered_polars_shaped_frame_answers_equal_to_duckdb(work):
    path = write_sales(work)
    with komira.Session() as s:
        s.register("t", kpl.scan_parquet(path, session=s))
        s.register("targets", targets_table())
        assert_queries_equal_duckdb(s, "komira.pl.LazyFrame")
        lazy = kpl.scan_parquet(path, session=s).filter(kpl.col("amount") > 100).select("id")
        s.register("big", lazy)
        got = s.sql("SELECT id FROM big ORDER BY id").to_arrow().to_pylist()
    assert got == [{"id": 1}, {"id": 4}, {"id": 6}], got


def test_a_frame_the_engine_refuses_raises_and_registers_nothing(work):
    path = write_sales(work)
    with komira.Session() as s:
        s.register("t", targets_table())
        frame = komira.read_parquet(path, session=s)
        try:
            s.register("t", frame[["price"]].median())
        except KomiraError as e:
            # The engine's refusal of the frame's plan, which names its step.
            assert e.step is not None, repr(e)
        else:
            raise AssertionError("the engine answered a median; pick another refused frame")
        got = s.sql("SELECT count(*) AS n FROM t").to_arrow().to_pylist()
    assert got == [{"n": 3}], got


# ---- read once ---------------------------------------------------------------------


def test_a_reader_is_read_once_when_it_is_registered(work):
    import pyarrow as pa

    table = sales_table()
    reader = pa.RecordBatchReader.from_batches(table.schema, table.to_batches(max_chunksize=3))
    with komira.Session() as s, komira.Session() as other:
        s.register("r", reader)
        first = s.sql("SELECT id FROM r ORDER BY id").to_arrow().to_pylist()
        second = s.sql("SELECT id FROM r ORDER BY id").to_arrow().to_pylist()
        assert first == second == [{"id": i} for i in range(1, 9)], (first, second)
        message = (
            "this pyarrow.RecordBatchReader was given to register before, which reads a reader once: query "
            "the name it was registered as, or register a pyarrow.Table (reader.read_all()) to register the "
            "same rows under more than one name"
        )
        refused(lambda: s.register("again", reader), KomiraError, message)
        refused(lambda: other.register("r", reader), KomiraError, message)
        # The refused registrations left the table of the name answering.
        assert s.sql("SELECT count(*) AS n FROM r").to_arrow().to_pylist() == [{"n": 8}]


def test_a_result_registers_and_is_then_read(work):
    with komira.Session() as s:
        s.register("t", sales_table())
        result = s.sql("SELECT id, amount FROM t WHERE amount > 100")
        s.register("big", result)
        got = s.sql("SELECT id FROM big ORDER BY id").to_arrow().to_pylist()
        assert got == [{"id": 1}, {"id": 4}, {"id": 6}], got
        refused(
            lambda: s.register("again", result),
            KomiraError,
            "the result was already read: run the query again to read it again",
        )


# ---- replacing a name ------------------------------------------------------------------


def test_registering_a_name_again_replaces_its_table(work):
    import pyarrow as pa

    csv = os.path.join(work, "names.csv")
    with open(csv, "w") as f:
        f.write("a\n1\n2\n")
    with komira.Session() as s:
        s.register("t", pa.table({"x": [1, 2, 3]}))
        before = s.sql("SELECT sum(x) AS total FROM t")
        s.register("t", pa.table({"y": ["a"]}))
        assert s.sql("SELECT * FROM t").to_arrow().to_pylist() == [{"y": "a"}]
        s.register("T", pa.table({"z": [7]}))
        assert s.sql("SELECT * FROM t").to_arrow().to_pylist() == [{"z": 7}]
        s.register_csv("names", csv)
        s.register("names", pa.table({"b": [5]}))
        assert s.sql("SELECT * FROM names").to_arrow().to_pylist() == [{"b": 5}]
        # A result returned before the name was replaced keeps its answer.
        assert before.to_arrow().to_pylist() == [{"total": 6}]
    # DuckDB's register replaces the view of the name the same way.
    con = duckdb_with({"t": pa.table({"x": [1, 2, 3]})})
    con.register("t", pa.table({"y": ["a"]}))
    assert duckdb_answer(con, "SELECT * FROM t")[2] == [("a",)]


# ---- refusals ----------------------------------------------------------------------------


def test_a_type_the_engine_does_not_hold_is_refused_by_name(work):
    import pyarrow as pa

    with komira.Session() as s:
        s.register("t", pa.table({"x": [1]}))
        nested = pa.table({"k": [1, 2], "v": pa.array([[1, 2], None], pa.list_(pa.int64()))})
        e = refused(
            lambda: s.register("t", nested),
            UnsupportedOperation,
            "TABLE_TYPE_UNSUPPORTED: column 'v' has type list; only flat columns are registered",
        )
        assert (e.status, e.code, e.step) == (-3, "TABLE_TYPE_UNSUPPORTED", "bind"), (e.status, e.code, e.step)
        outside = (
            ("null", pa.nulls(2)),
            ("large_list", pa.array([[1], None], pa.large_list(pa.int64()))),
            ("run_end_encoded", pa.RunEndEncodedArray.from_arrays(pa.array([2], pa.int32()), pa.array([7]))),
        )
        for label, column in outside:
            try:
                s.register("t", pa.table({"v": column}))
            except BindError as e:
                assert str(e).startswith("UnsupportedArrowCABIType: ") and e.step == "bind", (label, str(e))
            else:
                raise AssertionError("{} was registered".format(label))
        got = s.sql("SELECT * FROM t").to_arrow().to_pylist()
    assert got == [{"x": 1}], got


def test_a_stream_that_fails_while_read_registers_nothing(work):
    import pyarrow as pa

    table = pa.table({"x": [1, 2]})

    def batches():
        yield table.to_batches()[0]
        raise RuntimeError("the producer stopped")

    with komira.Session() as s:
        s.register("t", pa.table({"x": [9]}))
        try:
            s.register("t", pa.RecordBatchReader.from_batches(table.schema, batches()))
        except BindError as e:
            assert "the producer stopped" in str(e) and "get_next failed" in str(e), str(e)
        else:
            raise AssertionError("a failing stream was registered")
        got = s.sql("SELECT * FROM t").to_arrow().to_pylist()
    assert got == [{"x": 9}], got


# The flat Arrow types the engine's import takes, one column each with a NULL.
def flat_columns():
    import pyarrow as pa

    day = datetime.date(2026, 9, 1)
    moment = datetime.datetime(2026, 9, 1, 12, 30, 15, 250000)
    return [
        ("bool", pa.array([True, None, False])),
        ("int8", pa.array([-128, None, 127], pa.int8())),
        ("int16", pa.array([-32768, None, 32767], pa.int16())),
        ("int32", pa.array([-(2**31), None, 2**31 - 1], pa.int32())),
        ("int64", pa.array([-(2**63), None, 2**63 - 1], pa.int64())),
        ("uint8", pa.array([0, None, 255], pa.uint8())),
        ("uint16", pa.array([0, None, 65535], pa.uint16())),
        ("uint32", pa.array([0, None, 2**32 - 1], pa.uint32())),
        ("uint64", pa.array([0, None, 2**64 - 1], pa.uint64())),
        ("float32", pa.array([1.5, None, -0.25], pa.float32())),
        ("float64", pa.array([1.5, None, -1e300], pa.float64())),
        ("string", pa.array(["a", None, "é"], pa.string())),
        ("large_string", pa.array(["a", None, ""], pa.large_string())),
        ("binary", pa.array([b"\x00a", None, b""], pa.binary())),
        ("large_binary", pa.array([b"\x00a", None, b""], pa.large_binary())),
        ("string_view", pa.array(["a", None, "a longer string than twelve bytes"], pa.string_view())),
        ("binary_view", pa.array([b"\x00a", None, b"a longer value than twelve bytes"], pa.binary_view())),
        ("date32", pa.array([day, None, datetime.date(1970, 1, 1)], pa.date32())),
        ("date64", pa.array([day, None, datetime.date(1970, 1, 1)], pa.date64())),
        ("timestamp[s]", pa.array([moment.replace(microsecond=0), None, moment.replace(microsecond=0)], pa.timestamp("s"))),
        ("timestamp[ms]", pa.array([moment, None, moment], pa.timestamp("ms"))),
        ("timestamp[us]", pa.array([moment, None, moment], pa.timestamp("us"))),
        ("timestamp[ns]", pa.array([moment, None, moment], pa.timestamp("ns"))),
        ("timestamp[us, UTC]", pa.array([moment, None, moment], pa.timestamp("us", tz="UTC"))),
        ("decimal128(10, 2)", pa.array([decimal.Decimal("12.34"), None, decimal.Decimal("-0.01")], pa.decimal128(10, 2))),
        ("decimal256(40, 2)", pa.array([decimal.Decimal("12.34"), None, decimal.Decimal("-0.01")], pa.decimal256(40, 2))),
        ("time32[ms]", pa.array([datetime.time(12, 30), None, datetime.time(0, 0)], pa.time32("ms"))),
        ("time64[us]", pa.array([datetime.time(12, 30, 0, 5), None, datetime.time(0, 0)], pa.time64("us"))),
        ("duration[us]", pa.array([datetime.timedelta(seconds=3), None, datetime.timedelta(0)], pa.duration("us"))),
        ("dictionary<string>", pa.array(["a", None, "a"]).dictionary_encode()),
    ]


def outcome(s, column):
    """What `SELECT * FROM x` answers for the one-column table of `column`:
    ("same", answer type) when it reads back the values it was given,
    ("refused", text) when it is refused, else ("other", the values)."""
    import pyarrow as pa

    try:
        s.register("x", pa.table({"v": column}))
        got = s.sql("SELECT * FROM x").to_arrow()
    except KomiraError as e:
        return "refused", "{}: {}".format(type(e).__name__, e)
    want = column.dictionary_decode() if pa.types.is_dictionary(column.type) else column
    if got.column(0).to_pylist() == want.to_pylist():
        return "same", str(got.schema.types[0])
    return "other", repr(got.column(0).to_pylist())


# The type each flat type answers as: its own, but for the large and view
# strings and binaries, which register as string and binary.
HELD_AS = {
    "large_string": "string",
    "string_view": "string",
    "large_binary": "binary",
    "binary_view": "binary",
}


def test_every_flat_type_reads_back_its_values(work):
    with komira.Session() as s:
        found = [(label, column, outcome(s, column)) for label, column in flat_columns()]
    wrong = []
    for label, column, (kind, detail) in found:
        want = HELD_AS.get(label, str(column.type))
        if (kind, detail) != ("same", want):
            wrong.append("{}: {} ({}), expected same ({})".format(label, kind, detail, want))
    assert not wrong, "\n".join(wrong)


# ---- argument errors -------------------------------------------------------------------------


class _NoCapsule:
    def __arrow_c_stream__(self, requested_schema=None):
        return "not a capsule"


def test_arguments_are_checked_before_anything_is_read(work):
    import pyarrow as pa

    table = sales_table()
    reader = pa.RecordBatchReader.from_batches(table.schema, table.to_batches())

    def type_error(call, message):
        try:
            call()
        except TypeError as e:
            assert str(e) == message, str(e)
        else:
            raise AssertionError("no TypeError: " + message)

    def value_error(call, message):
        try:
            call()
        except ValueError as e:
            assert str(e) == message, str(e)
        else:
            raise AssertionError("no ValueError: " + message)

    with komira.Session() as s:
        type_error(lambda: s.register(1, reader), "name must be a str, not int")
        value_error(lambda: s.register("", reader), "name is empty")
        value_error(lambda: s.register("a\0b", reader), "name holds a NUL byte")
        type_error(
            lambda: s.register("t", [1, 2]),
            "register takes a komira frame or an object with the Arrow PyCapsule stream interface "
            "(__arrow_c_stream__), such as a pyarrow.Table or RecordBatchReader, not list",
        )
        type_error(
            lambda: s.register("t", _NoCapsule()),
            "__arrow_c_stream__ returned str, not a PyCapsule named arrow_array_stream",
        )
    refused(lambda: s.register("t", reader), KomiraError, "the session is closed")
    # None of those took the reader: it still registers all of its rows.
    with komira.Session() as s:
        s.register("t", reader)
        assert s.sql("SELECT count(*) AS n FROM t").to_arrow().to_pylist() == [{"n": 8}]


TESTS = [
    test_a_registered_pyarrow_table_answers_equal_to_duckdb,
    test_a_registered_record_batch_answers_equal_to_duckdb,
    test_a_reader_of_several_batches_answers_equal_to_duckdb,
    test_nulls_survive_in_every_column,
    test_a_table_of_no_row_keeps_its_schema,
    test_a_registered_komira_frame_answers_equal_to_duckdb,
    test_a_frame_of_another_session_registers_its_rows,
    test_a_filtered_frame_registers_the_rows_its_plan_answers,
    test_a_registered_polars_shaped_frame_answers_equal_to_duckdb,
    test_a_frame_the_engine_refuses_raises_and_registers_nothing,
    test_a_reader_is_read_once_when_it_is_registered,
    test_a_result_registers_and_is_then_read,
    test_registering_a_name_again_replaces_its_table,
    test_a_type_the_engine_does_not_hold_is_refused_by_name,
    test_a_stream_that_fails_while_read_registers_nothing,
    test_every_flat_type_reads_back_its_values,
    test_arguments_are_checked_before_anything_is_read,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    failed = []
    with tempfile.TemporaryDirectory() as work:
        for test in TESTS:
            try:
                test(work)
                print("ok", test.__name__)
            except Exception as e:  # every test runs, and each failure is listed
                failed.append(test.__name__)
                print("FAIL", test.__name__, "{}: {}".format(type(e).__name__, e))
    if failed:
        raise SystemExit("register: {} of {} tests failed: {}".format(len(failed), len(TESTS), ", ".join(failed)))
    print("register: {} tests over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
