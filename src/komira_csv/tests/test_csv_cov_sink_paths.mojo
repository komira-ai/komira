# =============================================================================
# CsvSink: lifecycle refusals, the partial-file cleanup, the row-native write
# (`accept_row_blocks`) and the dispatcher-backed parallel write.
# =============================================================================
#
# Every expected file text is built in this file from the fixture's values,
# never by another CsvSink path, so the parallel path is not checked against
# the serial path it shares code with. Each docstring names its mutant.
# =============================================================================

from std.io import FileHandle
from std.os.path import exists
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_collections.slab import Slab
from komira_csv.csv_sink import CsvSink, _parallel_format_columns_packed
from komira_row_format.row_block import (
    DT_F32,
    DT_F64,
    DT_I32,
    DT_I64,
    DT_STRING,
    DT_U8,
    RowBlock,
)
from komira_row_format.row_output import RowOutput, RowOutputLayout
from komira_runtime_paths import test_tmpdir


def _read(path: String) raises -> String:
    var f = FileHandle(path, "r")
    var text = f.read()
    f.close()
    return text^


def _batch(n: Int) raises -> RecordBatch:
    """Columns `k` (INT64, row i = i) and `s` (STRING, row i = `s<i>`)."""
    var ks = List[Scalar[DType.int64]]()
    var ss = List[String]()
    for i in range(n):
        ks.append(Int64(i))
        ss.append(String("s") + String(i))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    var b = RecordBatchBuilder.with_capacity(2)
    b.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ks)))
    b.add_column(Column.from_string(StringArray.from_strings(ss)))
    return b.build(sb.build())


def _one_col_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list([4, 5]))
    )
    return b.build(sb.build())


def _expected(n: Int) -> String:
    var t = String("k,s\n")
    for i in range(n):
        t += String(i) + ",s" + String(i) + "\n"
    return t^


def test_lifecycle_refusals() raises:
    """`accept_batch` and `finish` before `init_sink` are refused; a batch
    of another width is refused; a zero-row batch writes nothing; the sink
    reports itself as no text-output sink. Mutant: drop the width check
    (red: the 1-column batch is written under the 2-column header). Dropping
    the zero-row return is equivalent (the empty emit writes nothing)."""
    var path = test_tmpdir() + "/cov_sink_life.csv"
    var sink = CsvSink(path)
    assert_false(sink.is_text_output_sink(), "CsvSink is not a text sink")
    var m1 = String("")
    try:
        sink.accept_batch(_batch(1))
    except e:
        m1 = String(e)
    assert_equal(m1, "CsvSink.accept_batch: init_sink was not called")
    var m2 = String("")
    try:
        sink.finish()
    except e:
        m2 = String(e)
    assert_equal(m2, "CsvSink.finish: init_sink was not called")

    var schema = _batch(1).schema.copy()
    sink.init_sink(schema)
    var m3 = String("")
    try:
        sink.accept_batch(_one_col_batch())
    except e:
        m3 = String(e)
    assert_equal(
        m3, "CsvSink.accept_batch: batch has 1 columns, init_sink schema has 2"
    )
    sink.accept_batch(_batch(0))
    sink.accept_batch(_batch(2))
    sink.finish()
    assert_equal(_read(path), _expected(2))


def test_unfinished_sink_removes_its_partial_file() raises:
    """A sink that created its file and is destroyed before `finish()`
    removes the partial file; a finished one keeps it. Mutant: drop the
    unlink in `__deinit__` (red: the partial file survives)."""
    var path = test_tmpdir() + "/cov_sink_partial.csv"
    var kept = test_tmpdir() + "/cov_sink_kept.csv"
    if True:
        var sink = CsvSink(path)
        sink.init_sink(_batch(1).schema.copy())
        sink.accept_batch(_batch(3))
        assert_true(exists(path), "file exists while the sink is open")
        _ = sink^
    assert_false(exists(path), "the partial file is removed")
    var done = CsvSink(kept)
    done.init_sink(_batch(1).schema.copy())
    done.finish()
    _ = done^
    assert_true(exists(kept), "a finished file is kept")


comptime _STRIDE = 33
comptime _VALIDITY = 32


def _put_le(mut rb: RowBlock, row: Int, off: Int, v: UInt64, n: Int):
    for i in range(n):
        rb.write_fixed[DType.uint8](row, off + i, UInt8((v >> UInt64(8 * i)) & 0xFF))


def _set_null(mut rb: RowBlock, row: Int, col: Int):
    var off = _VALIDITY + (col >> 3)
    var cur = rb.read_fixed[DType.uint8](row, off)
    rb.write_fixed[DType.uint8](row, off, cur | (UInt8(1) << UInt8(col & 7)))


def _row_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _row_output(last_tag: UInt8, with_null: Bool) raises -> RowOutput:
    """Two rows: (-2, 7, 2.25, -1.5, "a,b") and (5, -1, 0.5, 2.0, "z"),
    with the row-1 i64 cell and the row-0 f32 cell NULL when `with_null`."""
    var blk = RowBlock.with_capacity(2, 0, _STRIDE)
    blk.set_n_rows(2)
    for r in range(2):
        for off in range(_STRIDE):
            blk.write_fixed[DType.uint8](r, off, 0)
    _put_le(blk, 0, 0, UInt64(Int64(-2)), 8)
    _put_le(blk, 0, 8, UInt64(7), 4)
    _put_le(blk, 0, 12, 0x4002000000000000, 8)  # 2.25
    _put_le(blk, 0, 20, 0xBFC00000, 4)  # -1.5
    blk.write_var_string_cell(0, 24, String("a,b").as_bytes())
    _put_le(blk, 1, 0, UInt64(5), 8)
    _put_le(blk, 1, 8, UInt64(0xFFFFFFFF), 4)  # -1
    _put_le(blk, 1, 12, 0x3FE0000000000000, 8)  # 0.5
    _put_le(blk, 1, 20, 0x40000000, 4)  # 2.0
    blk.write_var_string_cell(1, 24, String("z").as_bytes())
    if with_null:
        _set_null(blk, 1, 0)
        _set_null(blk, 0, 3)
    var blocks = Slab[RowBlock]()
    blocks.append(blk^)
    var offs: List[Int] = [0, 8, 12, 20, 24]
    var tags: List[UInt8] = [DT_I64, DT_I32, DT_F64, DT_F32, last_tag]
    return RowOutput(
        blocks^, RowOutputLayout(offs^, tags^, _VALIDITY, with_null), _row_schema()
    )


def test_accept_row_blocks_writes_every_supported_tag() raises:
    """Row-native write of I64 / I32 / F64 / F32 / STRING cells, with nulls
    as empty fields and the delimiter-bearing string quoted. Mutants: drop
    the null check (red: the null i64 reads 5), drop the string quoting
    (red: `a,b` bare)."""
    var path = test_tmpdir() + "/cov_sink_rows.csv"
    var sink = CsvSink(path)
    sink.init_sink(_row_schema())
    sink.accept_row_blocks(_row_output(DT_STRING, True))
    sink.finish()
    assert_equal(
        _read(path), 'i64,i32,f64,f32,s\n-2,7,2.25,,"a,b"\n,-1,0.5,2.0,z\n'
    )


def test_accept_row_blocks_refusals() raises:
    """Before `init_sink`, a layout of another width, and a tag outside the
    supported subset are refused; a row output with no rows writes nothing.
    Mutant: drop the width check (red: the 5-column output is written under
    a 1-column header)."""
    var path = test_tmpdir() + "/cov_sink_rows_bad.csv"
    var sink = CsvSink(path)
    var m0 = String("")
    try:
        sink.accept_row_blocks(_row_output(DT_STRING, False))
    except e:
        m0 = String(e)
    assert_equal(m0, "CsvSink.accept_row_blocks: init_sink was not called")
    var sb = SchemaBuilder()
    sb.add_field(Field("only", ArrowType.INT64, True))
    sink.init_sink(sb.build())
    var m1 = String("")
    try:
        sink.accept_row_blocks(_row_output(DT_STRING, False))
    except e:
        m1 = String(e)
    assert_equal(
        m1,
        "CsvSink.accept_row_blocks: row output has 5 columns, init_sink"
        " schema has 1",
    )
    sink.finish()

    var p2 = test_tmpdir() + "/cov_sink_rows_tag.csv"
    var s2 = CsvSink(p2)
    s2.init_sink(_row_schema())
    var empty = RowOutput(
        Slab[RowBlock](),
        RowOutputLayout(
            [0, 8, 12, 20, 24],
            [DT_I64, DT_I32, DT_F64, DT_F32, DT_STRING],
            _VALIDITY,
            False,
        ),
        _row_schema(),
    )
    s2.accept_row_blocks(empty^)
    var m2 = String("")
    try:
        s2.accept_row_blocks(_row_output(DT_U8, False))
    except e:
        m2 = String(e)
    assert_true(
        m2.find("output DType tag 7 outside the row-streaming supported subset") >= 0,
        m2,
    )
    s2.finish()
    assert_equal(_read(p2), "i64,i32,f64,f32,s\n")


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_dispatcher_write_small_large_and_single_column() raises:
    """Through `accept_batch_with_dispatcher`: a 3-row batch (below the
    parallel row threshold: one emit buffer), a 20000-row batch (formatted
    per column and emitted per row range on the worker pool, then written
    with one pwrite per worker), and a one-column batch. Each file equals
    the closed-form text. Mutant: offset each worker's pwrite by one byte
    (red: corrupt text). A two-column batch with an unsupported column is
    refused from the pool's per-column task too."""
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()

    var path = test_tmpdir() + "/cov_sink_disp.csv"
    var sink = CsvSink(path)
    sink.init_sink(_batch(1).schema.copy())
    var ct = CancellationToken.new()
    sink.accept_batch_with_dispatcher[origin_of(disp)](
        _batch(3), Pointer(to=disp), ct.clone()
    )
    var n = 20000
    sink.accept_batch_with_dispatcher[origin_of(disp)](
        _batch(n), Pointer(to=disp), ct.clone()
    )
    sink.finish()
    var want = _expected(3)
    for i in range(n):
        want += String(i) + ",s" + String(i) + "\n"
    var got = _read(path)
    assert_equal(got.byte_length(), want.byte_length())
    assert_true(got == want, "20000-row parallel write differs from the closed form")

    var p1 = test_tmpdir() + "/cov_sink_disp1.csv"
    var s1 = CsvSink(p1)
    s1.init_sink(_one_col_batch().schema.copy())
    s1.accept_batch_with_dispatcher[origin_of(disp)](
        _one_col_batch(), Pointer(to=disp), ct.clone()
    )
    s1.finish()
    assert_equal(_read(p1), "k\n4\n5\n")

    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, True))
    sb.add_field(Field("t", ArrowType.TIMESTAMP_NS, True))
    var bb = RecordBatchBuilder.with_capacity(2)
    bb.add_column(
        Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list([1]))
    )
    bb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].from_list([2]), ArrowType.TIMESTAMP_NS
        )
    )
    var bad = bb.build(sb.build())
    var p2 = test_tmpdir() + "/cov_sink_disp_bad.csv"
    var s2 = CsvSink(p2)
    s2.init_sink(bad.schema.copy())
    var msg = String("")
    try:
        s2.accept_batch_with_dispatcher[origin_of(disp)](
            bad^, Pointer(to=disp), ct.clone()
        )
    except e:
        msg = String(e)
    s2.finish()
    assert_true(msg.find("CsvSink: column 1 format (packed) failed:") >= 0, msg)
    _ = ct^


def test_format_zero_column_batch() raises:
    """The serial packed-format entry, called directly with a zero-column
    batch (the sink itself returns before formatting one), returns no
    column. Mutant: append one column in the zero-column return (red: 1).
    Dropping the arm altogether is an equivalent mutant: the general path
    also returns an empty list for zero columns."""
    var b = RecordBatchBuilder.with_capacity(0)
    var sb = SchemaBuilder()
    var rb = b.build(sb.build())
    assert_equal(len(_parallel_format_columns_packed(rb, ",", '"')), 0)


def main() raises:
    test_lifecycle_refusals()
    test_unfinished_sink_removes_its_partial_file()
    test_accept_row_blocks_writes_every_supported_tag()
    test_accept_row_blocks_refusals()
    test_dispatcher_write_small_large_and_single_column()
    test_format_zero_column_batch()
    print("test_csv_cov_sink_paths: 6 tests PASS")
