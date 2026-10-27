# The sub-row-group scan on a file written by komira_test_parquet_file, run on
# a 4-worker runtime, every row checked against the rows written:
#   - a dictionary INT64, a PLAIN INT32 and a PLAIN DOUBLE column come back in
#     file order, each of its own type, every row once;
#   - a WHERE predicate keeps exactly its rows, and a row group the statistics
#     disprove is never decoded (the route's streamed-row count);
#   - a dictionary string column comes back as a dictionary column; with a
#     predicate the unit aborts and comes back empty;
#   - a column with an actual null in a row group bigger than one chunk:
#     the chunks already handed over are retracted, the row group is decoded
#     whole, and every row (nulls included) comes back exactly once;
#   - columns requested out of file order come back in the requested order, on
#     the cursor route and through the whole-row-group fallback;
#   - UINT_32 / UINT_64 dictionary columns are not read through the cursors
#     (their entries would be sign-extended): the row group is decoded whole,
#     every value at or above 2^31 / 2^63 intact;
#   - a dictionary column with nulls comes back flat, every row, nulls kept;
#   - two units in one fork each come back as they would alone.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.subrg_scan_route_trace import (
    scan_fallback_count,
    scan_retracted_rows_count,
    scan_rows_streamed_count,
)
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.scan_chunk_sink import ScanCollectChunkSink
from komira_parquet_scan.subrg_agg_plan import resolve_reader_col_idx
from komira_parquet_scan.subrg_scan_executor import (
    SCAN_FLUSH_BUDGET_BYTES,
    SubrgScanPlan,
    SubrgScanUnit,
    run_subrg_scan,
    run_subrg_scan_multi,
)
from komira_plan_expr.expr import BIN_LT, Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import PT_INT32, PT_INT64, TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _RG = 50


def _noop() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop, BACKEND_MOCK)
    rt.start()
    return rt^


def _s(r: Int) -> String:
    return "k" + String(r % 3)


def _file(name: String, rgs: List[Int], null_row: Int) raises -> String:
    """Columns a (INT64 dictionary, row % 7), b (INT32 PLAIN, row),
    f (DOUBLE PLAIN, row / 4), s (string dictionary), n (OPTIONAL INT64,
    row, NULL at `null_row` when >= 0, pages of 10,000 rows, so a null past
    a row group's first chunk is met only after that chunk is out)."""
    var path = test_tmpdir() + "/" + name + ".parquet"
    var total = 0
    for i in range(len(rgs)):
        total += rgs[i]
    var a = List[Int]()
    var b = List[Int]()
    var f = List[Float64]()
    var s = List[String]()
    var n = List[Int]()
    var nn = List[Bool]()
    for r in range(total):
        a.append(r % 7)
        b.append(r)
        f.append(Float64(r) / 4.0)
        s.append(_s(r))
        n.append(r)
        nn.append(r == null_row)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^).dict_encoded())
    cols.append(TestColumn.int32("b", b^))
    cols.append(TestColumn.float64("f", f^))
    cols.append(TestColumn.string("s", s^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).with_nulls(nn^).with_page_rows(10_000))
    write_parquet_file(path, cols, TestFileLayout(rgs.copy(), 0, False))
    return path^


def _reader(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _plan(reader: ParquetReader[_FS], names: List[String], types: List[ArrowType]) -> SubrgScanPlan:
    var idx = List[Int]()
    for i in range(len(names)):
        idx.append(resolve_reader_col_idx(reader, names[i]))
    return SubrgScanPlan(names.copy(), idx^, types.copy())


def _schema(names: List[String], types: List[ArrowType]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], types[i], False))
    return sb.build()


def _rows(res: Slab[RecordBatch]) -> Int:
    var n = 0
    for i in range(len(res)):
        n += res[i].num_rows()
    return n


def _check_abf(res: Slab[RecordBatch], rows: List[Int]) raises:
    """`res` holds columns a, b, f of exactly `rows`, in order."""
    assert_equal(_rows(res), len(rows))
    var k = 0
    for i in range(len(res)):
        ref bt = res[i]
        assert_true(bt.column_at(1).arrow_type == ArrowType.INT32)
        var a = bt.column_at(0).as_primitive[DType.int64]()
        var b = bt.column_at(1).as_primitive[DType.int32]()
        var f = bt.column_at(2).as_primitive[DType.float64]()
        for j in range(bt.num_rows()):
            var r = rows[k]
            assert_equal(Int(a.get(j)), r % 7)
            assert_equal(Int(b.get(j)), r)
            assert_equal(Float64(f.get(j)), Float64(r) / 4.0)
            k += 1


def _abf() -> Tuple[List[String], List[ArrowType]]:
    var names: List[String] = ["a", "b", "f"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.INT32, ArrowType.FLOAT64]
    return (names^, types^)


def test_columns_come_back_in_file_order() raises:
    var rt = _runtime()
    var reader = _reader(_file("order", [_RG, _RG, _RG], -1))
    var nt = _abf()
    var plan = _plan(reader, nt[0], nt[1])
    var out = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
        _schema(nt[0], nt[1]), False, None, 4,
    )
    var rows = List[Int]()
    for r in range(3 * _RG):
        rows.append(r)
    _check_abf(out, rows)
    rt.shutdown()


def test_a_predicate_and_the_statistics_prune() raises:
    var rt = _runtime()
    var reader = _reader(_file("pred", [_RG, _RG, _RG], -1))
    var nt = _abf()
    var plan = _plan(reader, nt[0], nt[1])
    # b < 60: row group 0 whole, 10 rows of row group 1, row group 2 pruned.
    var pred = Expr.binary(BIN_LT, Expr.col_ref("b"), Expr.literal(ScalarValue.from_int(60)))
    var streamed0 = scan_rows_streamed_count()
    var out = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
        _schema(nt[0], nt[1]), True, Optional(pred^), 4,
    )
    var rows = List[Int]()
    for r in range(60):
        rows.append(r)
    _check_abf(out, rows)
    assert_equal(scan_rows_streamed_count() - streamed0, 2 * _RG)
    rt.shutdown()


def test_a_string_dictionary_column() raises:
    var rt = _runtime()
    var names: List[String] = ["s", "a"]
    var types: List[ArrowType] = [ArrowType.STRING, ArrowType.INT64]
    var reader = _reader(_file("str", [_RG, _RG], -1))
    var plan = _plan(reader, names, types)
    var out = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
        _schema(names, types), False, None, 4, True,
    )
    assert_equal(_rows(out), 2 * _RG)
    var k = 0
    for i in range(len(out)):
        ref bt = out[i]
        assert_true(bt.column_at(0).arrow_type == ArrowType.DICTIONARY)
        var d = bt.column_at(0).as_dictionary()
        for j in range(bt.num_rows()):
            assert_equal(d.get(j), _s(k))
            k += 1
    # With a predicate a string chunk cannot be filtered on the workers: the
    # unit aborts and comes back empty.
    var reader2 = _reader(_file("str2", [_RG], -1))
    var plan2 = _plan(reader2, names, types)
    var pred = Expr.binary(BIN_LT, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(3)))
    var none = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader2^, plan2^,
        _schema(names, types), True, Optional(pred^), 4, True,
    )
    assert_equal(len(none), 0)
    rt.shutdown()


def test_a_null_past_the_first_chunk_is_retracted_and_decoded_whole() raises:
    var rt = _runtime()
    # Row group 1 holds 31,000 rows (more than one 30,000-row chunk); its only
    # null is at its row 30,500.
    var rgs: List[Int] = [_RG, 31_000]
    var null_row = _RG + 30_500
    var reader = _reader(_file("nulls", rgs, null_row))
    var names: List[String] = ["a", "n"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.INT64]
    var plan = _plan(reader, names, types)
    var fb0 = scan_fallback_count()
    var rt0 = scan_retracted_rows_count()
    var out = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
        _schema(names, types), False, None, 4,
    )
    assert_equal(scan_fallback_count() - fb0, 1)
    assert_true(scan_retracted_rows_count() - rt0 > 0)
    assert_equal(_rows(out), _RG + 31_000)
    var k = 0
    for i in range(len(out)):
        ref bt = out[i]
        var a = bt.column_at(0).as_primitive[DType.int64]()
        var n = bt.column_at(1).as_primitive[DType.int64]()
        for j in range(bt.num_rows()):
            assert_equal(Int(a.get(j)), k % 7)
            if k == null_row:
                assert_true(n.is_null(j))
            else:
                assert_equal(Int(n.get(j)), k)
            k += 1
    rt.shutdown()


def test_requested_order_is_kept_on_both_routes() raises:
    var rt = _runtime()
    # Columns n, f, a, b: file order is a, b, f, n. Row 5 of the 50-row row
    # group is null in n, so the cursors refuse it and the row group is
    # decoded whole; without a null the cursors take it.
    var names: List[String] = ["n", "f", "a", "b"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.FLOAT64, ArrowType.INT64, ArrowType.INT32]
    for with_null in [False, True]:
        var reader = _reader(_file("reorder" + String(with_null), [_RG], 5 if with_null else -1))
        var plan = _plan(reader, names, types)
        var fb0 = scan_fallback_count()
        var out = run_subrg_scan[_FS](
            rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
            _schema(names, types), False, None, 4,
        )
        assert_equal(scan_fallback_count() - fb0, 1 if with_null else 0)
        assert_equal(_rows(out), _RG)
        var k = 0
        for i in range(len(out)):
            ref bt = out[i]
            assert_equal(bt.num_columns(), 4)
            assert_true(bt.column_at(1).arrow_type == ArrowType.FLOAT64)
            assert_true(bt.column_at(3).arrow_type == ArrowType.INT32)
            var n = bt.column_at(0).as_primitive[DType.int64]()
            var f = bt.column_at(1).as_primitive[DType.float64]()
            var a = bt.column_at(2).as_primitive[DType.int64]()
            var b = bt.column_at(3).as_primitive[DType.int32]()
            for j in range(bt.num_rows()):
                if with_null and k == 5:
                    assert_true(n.is_null(j))
                else:
                    assert_equal(Int(n.get(j)), k)
                assert_equal(Float64(f.get(j)), Float64(k) / 4.0)
                assert_equal(Int(a.get(j)), k % 7)
                assert_equal(Int(b.get(j)), k)
                k += 1
    rt.shutdown()


def test_unsigned_dictionary_columns_are_decoded_whole() raises:
    var rt = _runtime()
    var path = test_tmpdir() + "/uint.parquet"
    var u32 = List[Int]()
    var u64 = List[Int]()
    var b = List[Int]()
    var lowest = -(1 << 62) - (1 << 62)
    for r in range(_RG):
        u32.append((1 << 31) + r % 4)
        u64.append(lowest + r % 4)
        b.append(r)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int32("b", b^))
    var c0 = TestColumn("u32", PT_INT32, 13)
    c0.ints = u32^
    cols.append(c0^.dict_encoded())
    var c1 = TestColumn("u64", PT_INT64, 14)
    c1.ints = u64^
    cols.append(c1^.dict_encoded())
    write_parquet_file(path, cols, TestFileLayout([_RG], 0, False))
    var reader = _reader(path)
    var names: List[String] = ["b", "u32", "u64"]
    var types: List[ArrowType] = [ArrowType.INT32, ArrowType.INT32, ArrowType.INT64]
    var plan = _plan(reader, names, types)
    var fb0 = scan_fallback_count()
    var out = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
        _schema(names, types), False, None, 4,
    )
    assert_equal(scan_fallback_count() - fb0, 1)
    assert_equal(_rows(out), _RG)
    var k = 0
    for i in range(len(out)):
        ref bt = out[i]
        assert_true(bt.column_at(1).arrow_type == ArrowType.UINT32)
        assert_true(bt.column_at(2).arrow_type == ArrowType.UINT64)
        var c32 = bt.column_at(1).as_primitive[DType.uint32]()
        var c64 = bt.column_at(2).as_primitive[DType.uint64]()
        for j in range(bt.num_rows()):
            assert_equal(Int(c32.get(j)), (1 << 31) + k % 4)
            assert_equal(c64.get(j), (UInt64(1) << 63) + UInt64(k % 4))
            k += 1
    rt.shutdown()


def test_a_dictionary_column_with_nulls_comes_back_flat() raises:
    var rt = _runtime()
    var path = test_tmpdir() + "/dict_nulls.parquet"
    var d = List[Int]()
    var nn = List[Bool]()
    var b = List[Int]()
    for r in range(_RG):
        d.append(r % 5)
        nn.append(r % 6 == 0)
        b.append(r)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int32("b", b^))
    cols.append(TestColumn.int64("dn", d^).with_nulls(nn^).dict_encoded())
    write_parquet_file(path, cols, TestFileLayout([_RG], 0, False))
    var reader = _reader(path)
    var names: List[String] = ["dn", "b"]
    var types: List[ArrowType] = [ArrowType.INT64, ArrowType.INT32]
    var plan = _plan(reader, names, types)
    var out = run_subrg_scan[_FS](
        rt.dispatcher(), CancellationToken.never(), ScanCollectChunkSink(SCAN_FLUSH_BUDGET_BYTES), reader^, plan^,
        _schema(names, types), False, None, 4,
    )
    assert_equal(_rows(out), _RG)
    var k = 0
    for i in range(len(out)):
        ref bt = out[i]
        var dn = bt.column_at(0).as_primitive[DType.int64]()
        var bb = bt.column_at(1).as_primitive[DType.int32]()
        for j in range(bt.num_rows()):
            assert_equal(dn.is_null(j), k % 6 == 0, "row " + String(k))
            if k % 6 != 0:
                assert_equal(Int(dn.get(j)), k % 5)
            assert_equal(Int(bb.get(j)), k)
            k += 1
    rt.shutdown()


def test_two_units_in_one_fork() raises:
    var rt = _runtime()
    var nt = _abf()
    var units = Slab[SubrgScanUnit[_FS]].create(2)
    var r1 = _reader(_file("u1", [_RG, _RG], -1))
    var p1 = _plan(r1, nt[0], nt[1])
    units.append(
        SubrgScanUnit[_FS](r1^, p1^, _schema(nt[0], nt[1]), False, None, False, ScanCollectChunkSink(1 << 20))
    )
    var r2 = _reader(_file("u2", [7], -1))
    var p2 = _plan(r2, nt[0], nt[1])
    units.append(
        SubrgScanUnit[_FS](r2^, p2^, _schema(nt[0], nt[1]), False, None, False, ScanCollectChunkSink(1 << 20))
    )
    var outs = run_subrg_scan_multi[_FS](rt.dispatcher(), CancellationToken.never(), units^, 4)
    assert_equal(len(outs), 2)
    var rows1 = List[Int]()
    for r in range(2 * _RG):
        rows1.append(r)
    _check_abf(outs[0], rows1)
    var rows2 = List[Int]()
    for r in range(7):
        rows2.append(r)
    _check_abf(outs[1], rows2)
    rt.shutdown()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
