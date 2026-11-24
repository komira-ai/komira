# register_arrow: a table already in memory (what komira_register_arrow_stream
# drains from an Arrow C stream) bound into a session as a table that SQL on
# the session reads by name.
#
# Rows: a registered table of two chunks answers a scan, a sort, a filter on a
# number and on a string, and a grouped aggregate with its own rows, under its
# name in any case; it joins a registered CSV file (an inner join with an
# aggregate, and a left join that keeps the CSV row with no match); a table of
# no chunk keeps its schema, counts no row and joins to no row; a second
# registration of a name replaces the table of that name, whether the first
# was registered from memory, from a CSV file or from a Parquet file (whose
# replacement leaves the session's other Parquet tables answering), while
# register_csv still
# refuses a name the in-memory table holds (TABLE_ALREADY_REGISTERED); a
# column of a nested type or a union is refused as TABLE_TYPE_UNSUPPORTED
# word for word and the table already under the name keeps answering; an empty name is
# refused as TABLE_NAME_EMPTY by register_arrow and check_table_name.
from std.testing import assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from arrow.table import Table
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult

from so import (
    Session,
    TABLE_TYPE_UNSUPPORTED,
    check_table_name,
    register_arrow,
    register_csv,
    register_parquet,
    sql_result,
)

comptime PARQUET = "src/so/tests/fixtures/two_columns.parquet"

comptime PEOPLE = "id,name,score\n1,ann,10\n2,bob,20\n3,cy,30\n"
comptime COMMA = UInt8(ord(","))


def _write(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def _orders_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("pid"), ArrowType.INT64, False))
    sb.add_field(Field(String("amount"), ArrowType.INT64, False))
    sb.add_field(Field(String("note"), ArrowType.STRING, False))
    return sb.build()


def _chunk(pids: List[Int64], amounts: List[Int64], notes: List[String]) raises -> RecordBatch:
    var b = RecordBatchBuilder.with_capacity(3)
    b.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(pids)))
    b.add_column(Column.from_primitive(PrimitiveArray[DType.int64].from_list(amounts)))
    b.add_column(Column.from_string(StringArray.from_strings(notes)))
    return b.build(_orders_schema())


def _orders() raises -> Table:
    """Two chunks: (1, 10, 'a'), (2, 20, 'b'), then (1, 30, 'c')."""
    var chunks = List[RecordBatch]()
    chunks.append(_chunk([Int64(1), Int64(2)], [Int64(10), Int64(20)], [String("a"), String("b")]))
    chunks.append(_chunk([Int64(1)], [Int64(30)], [String("c")]))
    return Table.from_chunks(chunks^, _orders_schema())


def _one_order() raises -> Table:
    """One chunk of one row: (3, 99, 'z')."""
    return Table.from_batch(_chunk([Int64(3)], [Int64(99)], [String("z")]))


def _people(mut s: Session, name: String) raises:
    register_csv(s, name, _write(String("people.csv"), String(PEOPLE)), COMMA, True, False)


def _ints(result: ArrowResult, column: Int = 0) raises -> List[Int64]:
    """Column `column` of every batch of `result`, as int64 values."""
    var out = List[Int64]()
    for b in range(len(result.batches)):
        var col = result.batches[b].column_at(column).as_primitive[DType.int64]()
        for i in range(result.batches[b].num_rows()):
            out.append(col.get(i))
    return out^


def _rows(result: ArrowResult) -> Int:
    var n = 0
    for b in range(len(result.batches)):
        n += result.batches[b].num_rows()
    return n


def _assert_ints(got: List[Int64], want: List[Int64]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _message_of_arrow(mut s: Session, name: String, var table: Table) -> String:
    """The message `register_arrow` raises, or empty when it registers."""
    try:
        register_arrow(s, name, table^)
    except e:
        return String(e)
    return String()


def test_registered_table_answers_a_scan_a_filter_and_an_aggregate() raises:
    var s = Session()
    register_arrow(s, String("Orders"), _orders())
    assert_true(s.engine.catalog.has("orders"))
    var scan = sql_result(s, String("select pid, amount from ORDERS order by amount"))
    assert_equal(scan.schema.field_name(0), String("pid"))
    assert_equal(scan.schema.field_name(1), String("amount"))
    _assert_ints(_ints(scan), [Int64(1), Int64(2), Int64(1)])
    _assert_ints(_ints(scan, 1), [Int64(10), Int64(20), Int64(30)])
    var kept = sql_result(s, String("select amount from orders where amount > 15 order by amount"))
    _assert_ints(_ints(kept), [Int64(20), Int64(30)])
    var b = sql_result(s, String("select amount from orders where note = 'b'"))
    _assert_ints(_ints(b), [Int64(20)])
    var grouped = sql_result(
        s, String("select pid, count(*) as n, max(amount) as top from orders group by pid order by pid")
    )
    _assert_ints(_ints(grouped), [Int64(1), Int64(2)])
    _assert_ints(_ints(grouped, 1), [Int64(2), Int64(1)])
    _assert_ints(_ints(grouped, 2), [Int64(30), Int64(20)])
    var notes = sql_result(s, String("select note from orders order by amount desc"))
    assert_equal(notes.batches[0].column_at(0).as_string().get(0), String("c"))


def test_registered_table_joins_a_registered_csv() raises:
    var s = Session()
    register_arrow(s, String("orders"), _orders())
    _people(s, String("people"))
    var inner = sql_result(
        s,
        String(
            "select p.id, count(*) as n, max(o.amount) as top from orders o"
            " join people p on o.pid = p.id group by p.id order by p.id"
        ),
    )
    _assert_ints(_ints(inner), [Int64(1), Int64(2)])
    _assert_ints(_ints(inner, 1), [Int64(2), Int64(1)])
    _assert_ints(_ints(inner, 2), [Int64(30), Int64(20)])
    var left = sql_result(
        s,
        String(
            "select p.id, count(o.pid) as n from people p left join orders o"
            " on o.pid = p.id group by p.id order by p.id"
        ),
    )
    _assert_ints(_ints(left), [Int64(1), Int64(2), Int64(3)])
    _assert_ints(_ints(left, 1), [Int64(2), Int64(1), Int64(0)])


def test_a_table_of_no_chunk_keeps_its_schema_and_has_no_row() raises:
    var s = Session()
    register_arrow(s, String("empty_orders"), Table.from_chunks(List[RecordBatch](), _orders_schema()))
    _people(s, String("people"))
    _assert_ints(_ints(sql_result(s, String("select count(*) from empty_orders"))), [Int64(0)])
    var cols = sql_result(s, String("select pid, note from empty_orders"))
    assert_equal(cols.schema.num_columns(), 2)
    assert_equal(cols.schema.field_name(1), String("note"))
    assert_true(cols.schema.field_arrow_type(1) == ArrowType.STRING)
    assert_equal(_rows(cols), 0)
    var joined = sql_result(s, String("select count(*) from empty_orders n join people p on n.pid = p.id"))
    _assert_ints(_ints(joined), [Int64(0)])


def test_a_second_registration_replaces_the_table_of_its_name() raises:
    var s = Session()
    register_arrow(s, String("orders"), _orders())
    register_arrow(s, String("ORDERS"), _one_order())
    _assert_ints(_ints(sql_result(s, String("select amount from orders"))), [Int64(99)])
    _people(s, String("people"))
    register_arrow(s, String("People"), _orders())
    _assert_ints(_ints(sql_result(s, String("select count(*) from people"))), [Int64(3)])
    var taken = String("TABLE_ALREADY_REGISTERED: the session already has a table named 'orders'")
    var refused = String()
    try:
        _people(s, String("orders"))
    except e:
        refused = String(e)
    assert_equal(refused, taken)
    _assert_ints(_ints(sql_result(s, String("select amount from orders"))), [Int64(99)])


def test_a_replaced_parquet_table_leaves_the_other_parquet_tables_answering() raises:
    var s = Session()
    register_parquet(s, String("two"), String(PARQUET))
    register_parquet(s, String("other"), String(PARQUET))
    register_arrow(s, String("Two"), _orders())
    assert_equal(len(s.engine.tables), 1)
    assert_equal(s.engine.tables[0].name, String("other"))
    _assert_ints(_ints(sql_result(s, String("select count(*) from two"))), [Int64(3)])
    _assert_ints(_ints(sql_result(s, String("select count(*) from other"))), [Int64(0)])


def test_a_nested_column_is_refused_and_the_table_of_its_name_stays() raises:
    var s = Session()
    register_arrow(s, String("orders"), _orders())
    var sb = SchemaBuilder()
    sb.add_field(Field(String("pid"), ArrowType.INT64, False))
    sb.add_field(Field.list_of("l", ArrowType.INT64, nullable=True))
    var nested = Table.from_chunks(List[RecordBatch](), sb.build())
    assert_equal(
        _message_of_arrow(s, String("orders"), nested^),
        String(TABLE_TYPE_UNSUPPORTED)
        + ": column 'l' has type "
        + String(ArrowType.LIST)
        + "; only flat columns are registered",
    )
    _assert_ints(_ints(sql_result(s, String("select count(*) from orders"))), [Int64(3)])
    # A union, sparse or dense, is refused the same way.
    for mode in [ArrowType.UNION_SPARSE, ArrowType.UNION_DENSE]:
        var ub = SchemaBuilder()
        ub.add_field(Field(String("u"), mode, False))
        var unioned = Table.from_chunks(List[RecordBatch](), ub.build())
        assert_equal(
            _message_of_arrow(s, String("u"), unioned^),
            String(TABLE_TYPE_UNSUPPORTED)
            + ": column 'u' has type "
            + String(mode)
            + "; only flat columns are registered",
        )
    assert_false(s.engine.catalog.has("u"))


def test_an_empty_name_is_refused() raises:
    var s = Session()
    var empty = String("TABLE_NAME_EMPTY: a table name must not be empty")
    assert_equal(_message_of_arrow(s, String(""), _orders()), empty)
    var checked = String()
    try:
        check_table_name(String(""))
    except e:
        checked = String(e)
    assert_equal(checked, empty)
    check_table_name(String("t"))
    assert_false(s.engine.catalog.has(""))


def main() raises:
    test_registered_table_answers_a_scan_a_filter_and_an_aggregate()
    test_registered_table_joins_a_registered_csv()
    test_a_table_of_no_chunk_keeps_its_schema_and_has_no_row()
    test_a_second_registration_replaces_the_table_of_its_name()
    test_a_replaced_parquet_table_leaves_the_other_parquet_tables_answering()
    test_a_nested_column_is_refused_and_the_table_of_its_name_stays()
    test_an_empty_name_is_refused()
    print("OK")
