# band_producer on a 4-worker runtime, folding into a test sink that sums a
# value per string key (and counts rows), checked against sums computed from
# the rows written:
#   - SUM(v), COUNT(*) GROUP BY k over three row groups, the value column
#     PLAIN DOUBLE, a dictionary DOUBLE, and the PLAIN column read in place
#     (zero copy);
#   - with an INT32 `d <= cutoff` filter carried on the band;
#   - a row group whose value column has a null aborts the run (empty result);
#   - a plan whose key is not a dictionary string is refused;
#   - the band width: the residency bound, the floor, and that it is a
#     function of the host profile (equal profiles, equal widths).

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.band_view import BandView
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_engine_runtime.band_sink import BandSink
from komira_engine_runtime.host_profile import reference_host_profile
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.band_producer import BAND_MIN_ROWS, band_row_width, compute_band_rows, run_band_agg
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.subrg_agg_plan import SubrgAggPlan, resolve_reader_col_idx
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _ROWS = 300


struct _Sums(Movable, Deinitable):
    var keys: List[String]
    var sums: List[Float64]
    var counts: List[Int]

    def __init__(out self):
        self.keys = List[String]()
        self.sums = List[Float64]()
        self.counts = List[Int]()

    def add(mut self, key: String, v: Float64, n: Int):
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.sums[i] += v
                self.counts[i] += n
                return
        self.keys.append(key)
        self.sums.append(v)
        self.counts.append(n)


struct _SumSink(BandSink, Movable, Deinitable):
    """SUM(column 1), COUNT(*) per string key (column 0), live rows only."""

    comptime WorkerLocal = _Sums

    def __init__(out self):
        pass

    def init_worker_state(self) raises -> _Sums:
        return _Sums()

    def consume_band[o: Origin[mut=False]](self, mut local: _Sums, band: BandView[o]) raises:
        var vals = band.col_f64_span(1)
        for r in range(band.n_rows()):
            if not band.selection_live(r):
                continue
            var kb = band.resolve_string(0, r)
            var key = String()
            for i in range(kb.len()):
                key += chr(Int(kb.read_u8_at(i)))
            local.add(key, Float64(vals[r]), 1)

    def combine_workers(self, var locals: Slab[Optional[_Sums]], num_workers: Int) raises -> _Sums:
        var acc = _Sums()
        for w in range(num_workers):
            if locals[w]:
                var s = locals[w].take()
                for i in range(len(s.keys)):
                    acc.add(s.keys[i], s.sums[i], s.counts[i])
        return acc^

    def drain(self, var combined: _Sums, var output_schema: Schema) raises -> Slab[RecordBatch]:
        var sums = List[Scalar[DType.float64]]()
        var counts = List[Scalar[DType.int64]]()
        for i in range(len(combined.keys)):
            sums.append(combined.sums[i])
            counts.append(Int64(combined.counts[i]))
        var out = Slab[RecordBatch]()
        out.append(
            RecordBatch.from_typed_columns_3(
                output_schema^,
                Column.from_string(StringArray.from_strings(combined.keys)),
                Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(sums^)),
                Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(counts^)),
            )
        )
        return out^


def _noop() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _runtime() raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(4, _noop, BACKEND_MOCK)
    rt.start()
    return rt^


def _key(r: Int) -> String:
    return "g" + String(r % 4)


def _val(r: Int) -> Float64:
    return Float64(r % 9) * 0.5


def _file(name: String, null_row: Int) raises -> String:
    """Three row groups of 100: k (string dictionary), v (DOUBLE PLAIN, pages
    of 30 rows), w (DOUBLE dictionary, = v), d (INT32 PLAIN, row), n (OPTIONAL
    DOUBLE = v, NULL at `null_row`)."""
    var path = test_tmpdir() + "/" + name + ".parquet"
    var k = List[String]()
    var v = List[Float64]()
    var d = List[Int]()
    var nn = List[Bool]()
    for r in range(_ROWS):
        k.append(_key(r))
        v.append(_val(r))
        d.append(r)
        nn.append(r == null_row)
    var cols = List[TestColumn]()
    cols.append(TestColumn.string("k", k^).dict_encoded())
    cols.append(TestColumn.float64("v", v.copy()).with_page_rows(30))
    cols.append(TestColumn.float64("w", v.copy()).dict_encoded())
    cols.append(TestColumn.int32("d", d^))
    cols.append(TestColumn.float64("n", v^).with_nulls(nn^))
    write_parquet_file(path, cols, TestFileLayout([100, 100, 100], 0, False))
    return path^


def _reader(path: String) raises -> ParquetReader[_FS]:
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _plan(reader: ParquetReader[_FS], value_col: String, with_d: Bool) -> SubrgAggPlan:
    var names: List[String] = ["k", value_col]
    var types: List[ArrowType] = [ArrowType.STRING, ArrowType.FLOAT64]
    if with_d:
        names.append("d")
        types.append(ArrowType.INT32)
    var idx = List[Int]()
    for i in range(len(names)):
        idx.append(resolve_reader_col_idx(reader, names[i]))
    return SubrgAggPlan(names^, idx^, types^, [0], True)


def _out_schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.STRING, False))
    sb.add_field(Field("sum", ArrowType.FLOAT64, False))
    sb.add_field(Field("count", ArrowType.INT64, False))
    return sb.build()


def _check(res: Slab[RecordBatch], cutoff: Int) raises:
    """`res` holds, per key, SUM(v) and COUNT(*) over rows `r <= cutoff`."""
    assert_equal(len(res), 1)
    ref b = res[0]
    assert_equal(b.num_rows(), 4)
    for i in range(4):
        var key = b.column_at(0).as_string().get(i)
        var want_sum = 0.0
        var want_n = 0
        for r in range(min(_ROWS, cutoff + 1)):
            if _key(r) == key:
                want_sum += _val(r)
                want_n += 1
        assert_equal(Float64(b.column_at(1).as_primitive[DType.float64]().get(i)), want_sum)
        assert_equal(Int(b.column_at(2).as_primitive[DType.int64]().get(i)), want_n)


def test_sums_per_key_on_every_value_arm() raises:
    var rt = _runtime()
    var host = reference_host_profile("test")
    for arm in range(3):
        var reader = _reader(_file("band" + String(arm), -1))
        var col = "w" if arm == 1 else "v"
        var plan = _plan(reader, col, False)
        var out = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0, host,
            zero_copy=(arm == 2),
        )
        _check(out, _ROWS)
    rt.shutdown()


def test_the_band_carried_filter() raises:
    var rt = _runtime()
    var reader = _reader(_file("bandf", -1))
    var plan = _plan(reader, "v", True)
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, 2, 141,
        reference_host_profile("test"),
    )
    _check(out, 141)
    rt.shutdown()


def test_a_null_aborts_and_a_non_string_key_is_refused() raises:
    var rt = _runtime()
    var reader = _reader(_file("bandn", 150))
    var plan = _plan(reader, "n", False)
    var out = run_band_agg[_FS, _SumSink](
        rt.dispatcher(), CancellationToken.never(), _SumSink(), reader^, plan^, _out_schema(), 4, -1, 0,
        reference_host_profile("test"),
    )
    assert_equal(len(out), 0)
    var reader2 = _reader(_file("bandk", -1))
    var names: List[String] = ["d", "v"]
    var types: List[ArrowType] = [ArrowType.INT32, ArrowType.FLOAT64]
    var bad = SubrgAggPlan(names^, [3, 1], types^, [0], False)
    with assert_raises(contains="dictionary string"):
        _ = run_band_agg[_FS, _SumSink](
            rt.dispatcher(), CancellationToken.never(), _SumSink(), reader2^, bad^, _out_schema(), 4, -1, 0,
            reference_host_profile("test"),
        )
    rt.shutdown()


def test_the_band_width() raises:
    var reader = _reader(_file("bandw", -1))
    var plan = _plan(reader, "v", True)
    assert_equal(band_row_width(plan), 4 + 8 + 4)
    var host = reference_host_profile("test")
    var w4 = compute_band_rows(plan, 4, host)
    assert_equal(w4, compute_band_rows(plan, 4, reference_host_profile("test")))
    assert_true(w4 >= BAND_MIN_ROWS)
    # More workers never widen the band; enough of them hit the floor.
    assert_true(compute_band_rows(plan, 64, host) <= w4)
    assert_equal(compute_band_rows(plan, 1 << 20, host), BAND_MIN_ROWS)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
