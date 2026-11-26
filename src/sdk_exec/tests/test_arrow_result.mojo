# =============================================================================
# arrow_result: the answer of run_sql, read through the Arrow C Stream
# Interface by a consumer written in C
# =============================================================================
#
# Covers: run_sql answers over a Parquet table with NULLs (a projection of
# INT64, INT32, VARCHAR and DECIMAL(10, 2) columns, ints, strings, NULLs and
# decimals, count and sums, a filter that keeps no row and so an empty answer)
# are read back value for value by a consumer written in C
# (src/tests/helpers/komira_test_arrow_c_consumer,
# komira_test_arrow_c_consumer) after the context is dropped; the consumer
# releases the stream before it reads the chunks and calls every release twice;
# afterwards every buffer is released and each result buffer is held by nothing
# else. A refusal raises with its step, an outcome with no batch is refused, a
# selection mask is applied, batches keep their order, and a column the export
# cannot carry is refused naming it.
#
# Each SQL test writes a Parquet table t(k INT64, i INT32, s VARCHAR,
# d DECIMAL(10, 2)) with NULLs in i, s and d, runs SQL text through `run_sql`,
# turns the outcome into an `ArrowResult`, drops the `EngineContext`, and then
# hands the batches to the C consumer of komira_test_arrow_c_consumer, which
# drives the stream through its function pointers, releases the stream before
# it reads the chunks, calls every release twice, and returns what it read as
# text. The expected texts are written out by hand from the table's values.
#
# What each test proves, and the defect it would catch:
#   * test_a_projection_reads_back_in_c: `SELECT k, i, s, d FROM t` reads back
#     every value, the NULLs where the table has them, a two-byte character
#     and an empty string, and the decimals with their scale. Catches a result
#     column the export misreads, and a result that needs the context it came
#     from (the context is dropped before the read).
#   * test_aggregates_read_back_in_c: count(*), sum(d) and sum(i) read back as
#     a non-nullable INT64 and nullable DECIMAL(38, 2) and DECIMAL(38, 0).
#   * test_an_empty_answer_reads_back_as_its_schema: a filter that keeps no
#     row gives the schema and one chunk of zero rows.
#   * test_every_buffer_is_released_after_the_read: after the C consumer is
#     done, each result column's buffer is held by the test's probe alone
#     (strong count 1). Catches a leaked stream, chunk or batch.
#   * test_a_refusal_raises_with_its_step: a query naming no such column
#     raises naming step `bind`; nothing is exported.
#   * test_an_outcome_with_no_batch_is_refused: an outcome with neither a
#     refusal nor a batch raises; there is no schema to export.
#   * test_a_selection_mask_is_applied_before_the_export: a batch whose mask
#     drops its middle row reads back without it. Catches the masked row
#     crossing the boundary.
#   * test_batches_keep_their_order: two batches read back as chunk 0 and
#     chunk 1, in the outcome's order.
#   * test_a_column_the_export_cannot_carry_is_refused_before_the_stream: a
#     STRING column with a non-zero offset is refused by arrow_result, naming
#     the column, not later by get_next.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.heap_region import HeapRegion
from byte_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_test_arrow_c_consumer.c_consumer import read_in_c
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from sdk_exec.arrow_result import ArrowResult, arrow_result
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import SqlOutcome, run_sql


def _table() raises -> RecordBatch:
    var i = PrimitiveArray[DType.int32].allocate_nullable(4)
    i.set(0, Int32(10))
    i._set_null(1)
    i.set(2, Int32(-30))
    i.set(3, Int32(40))
    var d = Decimal128Array.allocate_nullable(4, 10, 2)
    d.set_i128(0, SIMD[DType.int128, 1](125))
    d.set_null(1)
    d.set_i128(2, SIMD[DType.int128, 1](-50))
    d.set_i128(3, SIMD[DType.int128, 1](10000))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, nullable=False))
    sb.add_field(Field("i", ArrowType.INT32, nullable=True))
    sb.add_field(Field("s", ArrowType.STRING, nullable=True))
    sb.add_field(Field.decimal128("d", 10, 2, nullable=True))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(
                [Int64(1), Int64(2), Int64(3), Int64(4)]
            )
        )
    )
    rbb.add_column(Column.from_primitive[DType.int32](i))
    rbb.add_column(
        Column.from_string(
            StringArray.from_strings_with_validity(
                [String("alpha"), String("β"), String("ignored"), String("")],
                [True, True, False, True],
            )
        )
    )
    rbb.add_column(Column.from_decimal128(d))
    return rbb.build(sb.build())


def _answer(name: String, sql: String) raises -> ArrowResult:
    """Run `sql` over t, written to a file of its own named after `name`, on a
    context of its own, which is dropped before the result is returned."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var path = test_tmpdir() + "/arrow_result_" + name + ".parquet"
    var bytes = write_record_batch_to_parquet_bytes(_table())
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, "t", path)
    var result = arrow_result(run_sql(ctx, sql))
    _ = ctx^
    return result^


def _read(var result: ArrowResult) raises -> String:
    return read_in_c(result.take_batches(), result.take_schema())


def _int_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("n", ArrowType.INT64, nullable=False))
    return sb.build()


def _int_batch(var values: List[Int64]) raises -> RecordBatch:
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(values^)
        )
    )
    return rbb.build(_int_schema())


def _refusal(var outcome: SqlOutcome) raises -> String:
    try:
        _ = arrow_result(outcome^)
    except e:
        return String(e)
    raise Error("arrow_result accepted an outcome it must refuse")


def test_a_projection_reads_back_in_c() raises:
    assert_equal(
        _read(_answer("projection", "SELECT k, i, s, d FROM t")),
        "field k l required\n"
        "field i i nullable\n"
        "field s u nullable\n"
        "field d d:10,2 nullable\n"
        "chunk 0 rows 4\n"
        "k: 1, 2, 3, 4\n"
        "i: 10, null, -30, 40\n"
        's: "alpha", "β", null, ""\n'
        "d: 1.25, null, -0.50, 100.00\n",
    )


def test_aggregates_read_back_in_c() raises:
    assert_equal(
        _read(
            _answer(
                "aggregates",
                "SELECT count(*) AS n, sum(d) AS total, sum(i) AS si FROM t",
            )
        ),
        "field n l required\n"
        "field total d:38,2 nullable\n"
        "field si d:38,0 nullable\n"
        "chunk 0 rows 1\n"
        "n: 4\n"
        "total: 100.75\n"
        "si: 20\n",
    )


def test_an_empty_answer_reads_back_as_its_schema() raises:
    assert_equal(
        _read(_answer("empty", "SELECT k, s FROM t WHERE k > 100")),
        "field k l required\nfield s u nullable\nchunk 0 rows 0\nk:\ns:\n",
    )


def test_every_buffer_is_released_after_the_read() raises:
    var result = _answer("released", "SELECT k, i, s, d FROM t")
    var probes = List[SharedAlignedBuffer[HeapRegion]]()
    for b in range(len(result.batches)):
        for c in range(result.batches[b].num_columns()):
            probes.append(result.batches[b].column_at(c)._data.share())
    assert_true(len(probes) == 4, "one probe per result column")
    _ = _read(result^)
    for p in range(len(probes)):
        assert_equal(
            Int(probes[p]._region.count()),
            1,
            "result column " + String(p) + " is still held after the read",
        )


def test_a_refusal_raises_with_its_step() raises:
    var msg: String
    try:
        _ = _answer("refusal", "SELECT nope FROM t")
        msg = String()
    except e:
        msg = String(e)
    assert_true(msg.startswith("run_sql refused at step bind: "), msg)


def test_an_outcome_with_no_batch_is_refused() raises:
    assert_equal(
        _refusal(SqlOutcome()),
        "ArrowResult: the answer has no batch, so no schema",
    )


def test_a_selection_mask_is_applied_before_the_export() raises:
    var batch = _int_batch([Int64(1), Int64(2), Int64(3)])
    var mask = BooleanArray.allocate(3)
    mask.set(0, True)
    mask.set(2, True)
    batch.set_selection_mask(mask^)
    var outcome = SqlOutcome()
    outcome.batches.append(batch^)
    assert_equal(
        _read(arrow_result(outcome^)),
        "field n l required\nchunk 0 rows 2\nn: 1, 3\n",
    )


def test_batches_keep_their_order() raises:
    var outcome = SqlOutcome()
    outcome.batches.append(_int_batch([Int64(1), Int64(2)]))
    outcome.batches.append(_int_batch([Int64(3)]))
    assert_equal(
        _read(arrow_result(outcome^)),
        "field n l required\nchunk 0 rows 2\nn: 1, 2\nchunk 1 rows 1\nn: 3\n",
    )


def test_a_column_the_export_cannot_carry_is_refused_before_the_stream() raises:
    var s = Column.from_string(
        StringArray.from_strings([String("x"), String("y"), String("z")])
    )
    s._offset = 1
    s._length = 2
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, nullable=False))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(s^)
    var outcome = SqlOutcome()
    outcome.batches.append(rbb.build(sb.build()))
    var msg = _refusal(outcome^)
    var head = (
        "ArrowCStreamExport: column 's' ("
        + String(ArrowType.STRING)
        + ") of batch 0: UnsupportedArrowCABIType: variable-length"
    )
    assert_true(msg.startswith(head), msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
