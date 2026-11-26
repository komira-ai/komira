# The source operations on a host without libzstd (the macOS wheel's host:
# macOS ships no libzstd.dylib).
#
# Before anything else in this process opens libzstd, the test fills its
# handle slot (compression.codec_libraries, keyed by `_ZSTD_SLOT_NAME`) with a
# refusal, as the slot's own init function does when the library cannot be
# loaded. Each test first checks that the slot holds that refusal, so a slot
# opened earlier fails the test instead of passing it.
#
# Rows: every operation that reads a file registers, describes and answers
# over files that need no zstd: register_parquet and parquet_schema_bytes on a
# snappy Parquet file, sql_result over it, plan_result of a plan over it,
# register_csv, csv_binding_bytes, register_json and json_binding_bytes. A
# query over a zstd Parquet file registers (the footer is not compressed) and
# its run is refused at execute with the slot's refusal word for word
# (`execute: [Processor] compression: cannot load <soname>: <reason>`); the
# session answers the next query, and a second zstd query raises the same
# refusal (the process is not ended, and the slot is not opened again).
from std.ffi import _Global
from std.testing import assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder
from compression.codec_libraries import (
    LIBZSTD_SONAME,
    _CodecLibrary,
    _ZSTD_SLOT_NAME,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from plan_wire import plan_to_bytes
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult
from sql.sql_frontend import plan_from_sql

from so import (
    Session,
    csv_binding_bytes,
    json_binding_bytes,
    parquet_schema_bytes,
    plan_result,
    register_csv,
    register_json,
    register_parquet,
    sql_result,
)

# pyarrow's file of ZSTD V2 data pages (parquet_codec's fixture): 1200 rows of
# `id` (int64, 0 .. 1199) and `label`.
comptime ZSTD_PARQUET = "parquet/pyarrow_page_crc_zstd_v2.parquet"
comptime COMMA = UInt8(ord(","))


def _refusal() -> String:
    """The refusal the slot holds: what the slot's init function keeps for a
    libzstd that cannot be loaded, with a loader reason of this test's."""
    return (
        "compression: cannot load "
        + String(LIBZSTD_SONAME)
        + ": (this test's host has no libzstd)"
    )


def _no_libzstd() -> _CodecLibrary:
    return _CodecLibrary(refusal=_refusal())


comptime _HOST_WITHOUT_LIBZSTD = _Global[_ZSTD_SLOT_NAME, _no_libzstd]


def _take_the_zstd_slot() raises:
    """Fill the libzstd slot with the refusal, or check that it holds it."""
    ref library = _HOST_WITHOUT_LIBZSTD.get_or_create_ptr()[]
    assert_false(
        Bool(library.handle), "libzstd was opened in this process first"
    )
    assert_equal(library.refusal, _refusal())


def _write(name: String, text: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    with open(path, "w") as f:
        f.write(text)
    return path^


def _three_row_parquet(name: String) raises -> String:
    """A snappy Parquet file (the writer's default codec) of one INT64 column
    `k` holding 1, 2 and 3."""
    var arr = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        arr.set(i, Scalar[DType.int64](i + 1))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var bytes = write_record_batch_to_parquet_bytes(rbb.build(sb.build()))
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _sum(result: ArrowResult) raises -> Int64:
    """The sum of the first column of every batch of `result` (int64)."""
    var total = Int64(0)
    for b in range(len(result.batches)):
        var col = result.batches[b].column_at(0).as_primitive[DType.int64]()
        for i in range(result.batches[b].num_rows()):
            total += col.get(i)
    return total


def _message_of(mut s: Session, sql: String) -> String:
    """What `sql_result` raises for `sql`, or empty when it answers."""
    try:
        _ = sql_result(s, sql)
    except e:
        return String(e)
    return String()


def test_a_snappy_parquet_file_registers_and_answers() raises:
    _take_the_zstd_slot()
    var path = _three_row_parquet("snappy.parquet")
    assert_true(len(parquet_schema_bytes(path)) > 0)
    var s = Session()
    register_parquet(s, String("three"), path)
    assert_equal(_sum(sql_result(s, String("select k from three"))), Int64(6))
    var plan = plan_from_sql(
        String("select k from three where k > 1"),
        s.engine.catalog,
        s.engine.footers,
    )
    var fresh = Session()
    assert_equal(_sum(plan_result(fresh, plan_to_bytes(plan))), Int64(5))


def test_csv_and_json_files_register_and_answer() raises:
    _take_the_zstd_slot()
    var csv = _write("people.csv", "id,name\n1,ann\n2,bob\n")
    var json = _write("events.json", '{"id":3}\n{"id":4}\n')
    assert_true(len(csv_binding_bytes(csv, COMMA, True, False)) > 0)
    assert_true(len(json_binding_bytes(json)) > 0)
    var s = Session()
    register_csv(s, String("people"), csv, COMMA, True, False)
    register_json(s, String("events"), json)
    assert_equal(
        _sum(sql_result(s, String("select cast(id as bigint) from people"))),
        Int64(3),
    )
    assert_equal(
        _sum(sql_result(s, String("select cast(id as bigint) from events"))),
        Int64(7),
    )


def test_a_zstd_parquet_file_is_refused_naming_libzstd() raises:
    _take_the_zstd_slot()
    var s = Session()
    register_parquet(s, String("z"), String(ZSTD_PARQUET))
    register_parquet(s, String("three"), _three_row_parquet("after.parquet"))
    var first = _message_of(s, String("select sum(id) from z"))
    # A raise inside an operator reaches the caller as `execute: [Processor] <reason>`.
    assert_equal(first, "execute: [Processor] " + _refusal())
    # The session answers the next query, and the next zstd query is refused
    # the same way.
    assert_equal(_sum(sql_result(s, String("select k from three"))), Int64(6))
    assert_equal(_message_of(s, String("select sum(id) from z")), first)


def main() raises:
    test_a_snappy_parquet_file_registers_and_answers()
    test_csv_and_json_files_register_and_answer()
    test_a_zstd_parquet_file_is_refused_naming_libzstd()
    print("OK")
